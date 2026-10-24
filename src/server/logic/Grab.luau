--!strict
-- 扑咬的两种结算方式（GDB V1.1 §9A.6，EXP-08）：INSTANT 立即感染 / GRAB 擒抱 1 秒后感染。
-- 擒抱期间丧尸或人类受到任何武器命中、击退或电击都会解除擒抱：人类获得 1.5 秒防扑咬保护，
-- 丧尸进入扑咬冷却（冷却写回由调用方完成，本模块给出建议时刻）。
-- 纯逻辑：时间由调用方传入，状态用 ParticipantId 字符串索引；不引用 Roblox 全局。

export type Config = {
	BiteMode: "INSTANT" | "GRAB",
	GrabSeconds: number,
	GrabEscapeImmunitySeconds: number,
	BiteCooldownSeconds: number,
}

export type Grab = {
	zombieId: string,
	humanId: string,
	startedAt: number,
	completesAt: number,
}

export type State = {
	config: Config,
	-- 以丧尸为键：一只丧尸同一时间只能擒抱一名人类；人类被擒抱时可以被反查。
	grabs: { [string]: Grab },
	-- 人类 -> 防扑咬保护到期时刻（擒抱被解除后 1.5 秒）。
	biteImmuneUntil: { [string]: number },
}

export type BiteResult = {
	mode: string,
	infect: boolean,
	grabStarted: boolean,
	reason: string,
	completesAt: number?,
}

export type BreakResult = {
	broken: boolean,
	humanId: string?,
	immuneUntil: number?,
	biteCooldownUntil: number?,
}

export type CompletedGrab = {
	zombieId: string,
	humanId: string,
}

local Grab = {}

local Reason = table.freeze({
	INFECT = "INFECT",
	GRAB_STARTED = "GRAB_STARTED",
	BITE_IMMUNE = "BITE_IMMUNE",
	ALREADY_GRABBING = "ALREADY_GRABBING",
	TARGET_GRABBED = "TARGET_GRABBED",
	INVALID_TARGET = "INVALID_TARGET",
})
Grab.Reason = Reason

function Grab.new(config: Config): State
	return {
		config = config,
		grabs = {},
		biteImmuneUntil = {},
	}
end

function Grab.isBiteImmune(state: State, humanId: string, now: number): boolean
	local immuneUntil = state.biteImmuneUntil[humanId]
	return immuneUntil ~= nil and now < immuneUntil
end

-- 人类是否正被某只丧尸擒抱。
function Grab.grabTargetOf(state: State, zombieId: string): string?
	local grab = state.grabs[zombieId]
	if grab == nil then
		return nil
	end
	return grab.humanId
end

function Grab.grabOf(state: State, zombieId: string): Grab?
	return state.grabs[zombieId]
end

function Grab.isGrabbed(state: State, id: string): boolean
	for _, grab in state.grabs do
		if grab.zombieId == id or grab.humanId == id then
			return true
		end
	end
	return false
end

-- 服务端确认一次扑咬命中（§9A.6）。
-- INSTANT：立即感染。GRAB：记录擒抱，由 tick 在 GrabSeconds 后返回完成（感染）。
-- 防扑咬保护期内不能再次擒抱；同一只丧尸不能同时擒抱两人；同一人类不能被两只丧尸同时擒抱。
function Grab.onBiteHit(config: Config, state: State, attackerId: string, targetId: string, now: number): BiteResult
	if config.BiteMode == "INSTANT" then
		return {
			mode = "INSTANT",
			infect = true,
			grabStarted = false,
			reason = Reason.INFECT,
		}
	end

	if attackerId == targetId then
		return {
			mode = "GRAB",
			infect = false,
			grabStarted = false,
			reason = Reason.INVALID_TARGET,
		}
	end
	if Grab.isBiteImmune(state, targetId, now) then
		return {
			mode = "GRAB",
			infect = false,
			grabStarted = false,
			reason = Reason.BITE_IMMUNE,
		}
	end
	if state.grabs[attackerId] ~= nil then
		return {
			mode = "GRAB",
			infect = false,
			grabStarted = false,
			reason = Reason.ALREADY_GRABBING,
		}
	end
	for _, grab in state.grabs do
		if grab.humanId == targetId then
			return {
				mode = "GRAB",
				infect = false,
				grabStarted = false,
				reason = Reason.TARGET_GRABBED,
			}
		end
	end

	local grab: Grab = {
		zombieId = attackerId,
		humanId = targetId,
		startedAt = now,
		completesAt = now + config.GrabSeconds,
	}
	state.grabs[attackerId] = grab
	return {
		mode = "GRAB",
		infect = false,
		grabStarted = true,
		reason = Reason.GRAB_STARTED,
		completesAt = grab.completesAt,
	}
end

-- 擒抱中的丧尸受到任何武器命中、击退或电击：解除擒抱并给人类 1.5 秒防扑咬保护（§9A.6）。
-- 解除后这个 grab 已从状态中移除，同一 tick 的 tick() 不会再次把它当作完成。
function Grab.onZombieHit(state: State, zombieId: string, now: number): BreakResult
	local grab = state.grabs[zombieId]
	if grab == nil then
		return { broken = false }
	end

	state.grabs[zombieId] = nil
	local immuneUntil = now + state.config.GrabEscapeImmunitySeconds
	state.biteImmuneUntil[grab.humanId] = immuneUntil
	return {
		broken = true,
		humanId = grab.humanId,
		immuneUntil = immuneUntil,
		biteCooldownUntil = now + state.config.BiteCooldownSeconds,
	}
end

-- 推进擒抱：到达 completesAt 的擒抱返回给调用方（→ 感染），同时从状态移除。
-- 与 onZombieHit 的先后顺序保证“完成”和“解除”绝不双写：先到者删除 grab，后到者什么也看不到。
function Grab.tick(state: State, now: number): { CompletedGrab }
	-- 先收集再删除，避免遍历时改表；按完成时刻、再按丧尸 id 排序，保证确定性。
	local due: { Grab } = {}
	for _, grab in state.grabs do
		if grab.completesAt <= now then
			table.insert(due, grab)
		end
	end
	table.sort(due, function(a: Grab, b: Grab): boolean
		if a.completesAt ~= b.completesAt then
			return a.completesAt < b.completesAt
		end
		return a.zombieId < b.zombieId
	end)

	local completed: { CompletedGrab } = {}
	for _, grab in due do
		state.grabs[grab.zombieId] = nil
		table.insert(completed, { zombieId = grab.zombieId, humanId = grab.humanId })
	end

	-- 清理已经过期的防扑咬保护，避免长期运行时字典无限增长。
	for humanId, immuneUntil in state.biteImmuneUntil do
		if immuneUntil <= now then
			state.biteImmuneUntil[humanId] = nil
		end
	end

	return completed
end

-- 参与者离开：取消涉及他的擒抱（不产生防扑咬保护），并清掉他的保护记录。
function Grab.removeParticipant(state: State, id: string): { CompletedGrab }
	local removed: { CompletedGrab } = {}
	local zombieIds: { string } = {}
	for zombieId, grab in state.grabs do
		if grab.zombieId == id or grab.humanId == id then
			table.insert(zombieIds, zombieId)
			table.insert(removed, { zombieId = grab.zombieId, humanId = grab.humanId })
		end
	end
	for _, zombieId in zombieIds do
		state.grabs[zombieId] = nil
	end
	state.biteImmuneUntil[id] = nil
	return removed
end

return table.freeze(Grab)
