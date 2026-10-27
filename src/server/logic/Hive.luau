--!strict
-- 母巢指挥（GDB V1.1 §6.4，EXP-09）：零号的源头标记与母巢集结的纯状态机。
-- 只管冷却、引导、信标与标记的时间线；射程、视线、树归属、战斗状态等由 RoundService 校验后再调用。
-- 纯模块：不引用 Roblox 全局对象，可在 Lune 中测试。

export type Vec3 = { x: number, y: number, z: number }

export type Config = {
	RootMarkSeconds: number,
	RootMarkCooldownSeconds: number,
	RootMarkConvertWindowSeconds: number,
	RootRallyChannelSeconds: number,
	RootRallyBeaconSeconds: number,
	RootRallyCooldownSeconds: number,
	RootRallyInterruptCooldownSeconds: number,
	RootRallyMinHumanDistance: number,
	RootRallyMoveTolerance: number,
	RespawnMinDistanceFromExtraction: number,
	RootRallyForwardMaxDistance: number,
}

export type Channel = {
	startedAt: number,
	endsAt: number,
	origin: Vec3,
}

export type Beacon = {
	position: Vec3,
	placedAt: number,
	endsAt: number,
}

type RootState = {
	markReadyAt: number,
	rallyReadyAt: number,
	channel: Channel?,
	beacon: Beacon?,
}

export type Mark = {
	rootId: string,
	targetId: string,
	markedAt: number,
	endsAt: number,
}

export type State = {
	config: Config,
	roots: { [string]: RootState },
	-- 以被标记者为键：同一人被再次标记时以最新一次为准。
	marks: { [string]: Mark },
}

export type EventKind = "RALLY_PLACED" | "RALLY_CANCELLED" | "BEACON_EXPIRED"

export type Event = {
	kind: EventKind,
	rootId: string,
	position: Vec3?,
}

local Reason = table.freeze({
	OK = "OK",
	COOLDOWN = "COOLDOWN",
	CHANNELING = "CHANNELING",
	TOO_CLOSE_TO_HUMAN = "TOO_CLOSE_TO_HUMAN",
	TOO_CLOSE_TO_EXTRACTION = "TOO_CLOSE_TO_EXTRACTION",
	BEACON_ACTIVE = "BEACON_ACTIVE",
})

local Hive = {}
Hive.Reason = Reason

function Hive.new(config: Config): State
	return { config = config, roots = {}, marks = {} }
end

local function rootState(state: State, rootId: string): RootState
	local existing = state.roots[rootId]
	if existing ~= nil then
		return existing
	end
	local created: RootState = { markReadyAt = -math.huge, rallyReadyAt = -math.huge, channel = nil, beacon = nil }
	state.roots[rootId] = created
	return created
end

local function horizontalDistance(a: Vec3, b: Vec3): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

function Hive.markReadyAt(state: State, rootId: string): number
	return rootState(state, rootId).markReadyAt
end

function Hive.rallyReadyAt(state: State, rootId: string): number
	return rootState(state, rootId).rallyReadyAt
end

-- 源头标记：只检查冷却。成功后进入冷却，标记持续 RootMarkSeconds。
function Hive.tryMark(state: State, rootId: string, targetId: string, now: number): (boolean, string)
	local root = rootState(state, rootId)
	if now < root.markReadyAt then
		return false, Reason.COOLDOWN
	end
	root.markReadyAt = now + state.config.RootMarkCooldownSeconds
	state.marks[targetId] = {
		rootId = rootId,
		targetId = targetId,
		markedAt = now,
		endsAt = now + state.config.RootMarkSeconds,
	}
	return true, Reason.OK
end

-- 当前仍可见的标记（now < endsAt）。
function Hive.activeMarks(state: State, now: number): { Mark }
	local out: { Mark } = {}
	for _, mark in state.marks do
		if now < mark.endsAt then
			table.insert(out, mark)
		end
	end
	table.sort(out, function(a, b)
		return a.targetId < b.targetId
	end)
	return out
end

function Hive.markOn(state: State, targetId: string, now: number): Mark?
	local mark = state.marks[targetId]
	if mark ~= nil and now < mark.endsAt then
		return mark
	end
	return nil
end

-- 被标记者被咬：在转化窗口内返回距标记的秒数，并消耗这条记录（每次标记最多计一次转化）。
function Hive.onBite(state: State, targetId: string, now: number): number?
	local mark = state.marks[targetId]
	if mark == nil then
		return nil
	end
	state.marks[targetId] = nil
	local elapsed = now - mark.markedAt
	if elapsed < 0 or elapsed > state.config.RootMarkConvertWindowSeconds then
		return nil
	end
	return elapsed
end

-- 母巢集结：开始引导。距离条件只在开始时判定（引导期间原地不动）。
function Hive.startRally(
	state: State,
	rootId: string,
	now: number,
	origin: Vec3,
	nearestHumanDistance: number,
	extractionDistance: number?
): (boolean, string)
	local root = rootState(state, rootId)
	if root.channel ~= nil then
		return false, Reason.CHANNELING
	end
	if now < root.rallyReadyAt then
		return false, Reason.COOLDOWN
	end
	if root.beacon ~= nil and now < root.beacon.endsAt then
		return false, Reason.BEACON_ACTIVE
	end
	if nearestHumanDistance < state.config.RootRallyMinHumanDistance then
		return false, Reason.TOO_CLOSE_TO_HUMAN
	end
	if extractionDistance ~= nil and extractionDistance < state.config.RespawnMinDistanceFromExtraction then
		return false, Reason.TOO_CLOSE_TO_EXTRACTION
	end
	root.channel = {
		startedAt = now,
		endsAt = now + state.config.RootRallyChannelSeconds,
		origin = { x = origin.x, y = origin.y, z = origin.z },
	}
	return true, Reason.OK
end

function Hive.channelOf(state: State, rootId: string): Channel?
	local root = state.roots[rootId]
	return if root ~= nil then root.channel else nil
end

-- 引导被打断（电击、倒地、擒抱、移动）：进入短冷却。没有引导时返回 false。
function Hive.cancelRally(state: State, rootId: string, now: number): boolean
	local root = state.roots[rootId]
	if root == nil or root.channel == nil then
		return false
	end
	root.channel = nil
	root.rallyReadyAt = math.max(root.rallyReadyAt, now + state.config.RootRallyInterruptCooldownSeconds)
	return true
end

-- 前线复活点（EXP-09 第二轮）：在候选点（地图路点，保证不压墙）中选离被标记者最近的一个，
-- 要求距被标记者 ≤ RootRallyForwardMaxDistance、距所有人类 ≥ RootRallyMinHumanDistance，
-- 撤离开启时距撤离区 ≥ RespawnMinDistanceFromExtraction。没有合格点返回 nil（调用方退回信标）。
function Hive.pickForwardSpawn(
	config: Config,
	candidates: { Vec3 },
	target: Vec3,
	humans: { Vec3 },
	extraction: Vec3?
): Vec3?
	local best: Vec3? = nil
	local bestDistance = math.huge
	for _, point in candidates do
		local toTarget = horizontalDistance(point, target)
		if toTarget <= config.RootRallyForwardMaxDistance and toTarget < bestDistance then
			local clear = extraction == nil
				or horizontalDistance(point, extraction) >= config.RespawnMinDistanceFromExtraction
			for _, human in humans do
				if horizontalDistance(point, human) < config.RootRallyMinHumanDistance then
					clear = false
					break
				end
			end
			if clear then
				best = point
				bestDistance = toTarget
			end
		end
	end
	return best
end

function Hive.beaconOf(state: State, rootId: string, now: number): Beacon?
	local root = state.roots[rootId]
	if root == nil or root.beacon == nil or now >= root.beacon.endsAt then
		return nil
	end
	return root.beacon
end

-- 零号倒地/死亡/离局时信标熄灭。
function Hive.dropBeacon(state: State, rootId: string): boolean
	local root = state.roots[rootId]
	if root == nil or root.beacon == nil then
		return false
	end
	root.beacon = nil
	return true
end

-- 推进时间线：引导完成 → 立起信标；引导中移动超出容差 → 取消；信标到期 → 熄灭；清理过期标记。
-- positionOf 返回零号当前位置（不在场返回 nil，视为打断）。
function Hive.step(state: State, now: number, positionOf: (rootId: string) -> Vec3?): { Event }
	local events: { Event } = {}
	local rootIds: { string } = {}
	for rootId in state.roots do
		table.insert(rootIds, rootId)
	end
	table.sort(rootIds)

	for _, rootId in rootIds do
		local root = state.roots[rootId]
		local channel = root.channel
		if channel ~= nil then
			local position = positionOf(rootId)
			if
				position == nil
				or horizontalDistance(position, channel.origin) > state.config.RootRallyMoveTolerance
			then
				Hive.cancelRally(state, rootId, now)
				table.insert(events, { kind = "RALLY_CANCELLED", rootId = rootId, position = nil })
			elseif now >= channel.endsAt then
				root.channel = nil
				root.rallyReadyAt = now + state.config.RootRallyCooldownSeconds
				root.beacon = {
					position = channel.origin,
					placedAt = now,
					endsAt = now + state.config.RootRallyBeaconSeconds,
				}
				table.insert(events, { kind = "RALLY_PLACED", rootId = rootId, position = channel.origin })
			end
		end
		local beacon = root.beacon
		if beacon ~= nil and now >= beacon.endsAt then
			root.beacon = nil
			table.insert(events, { kind = "BEACON_EXPIRED", rootId = rootId, position = beacon.position })
		end
	end

	for targetId, mark in state.marks do
		if now > mark.markedAt + state.config.RootMarkConvertWindowSeconds and now >= mark.endsAt then
			state.marks[targetId] = nil
		end
	end
	return events
end

return table.freeze(Hive)
