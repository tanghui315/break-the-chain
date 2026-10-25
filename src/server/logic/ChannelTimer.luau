--!strict
-- Gate A-2a 服务端计时的按住交互（GDB V1.1 §10.2、§11.2、§13.2、§21.2）。
--
-- 解药、重连、撤离三种读条一律由服务端累计有效时间：客户端只发送“开始”意图，
-- 每个服务端 tick 重新校验距离 / 状态 / 视线（由调用方注入 isStillValid），
-- 只有累计有效时长 ≥ duration 才提交完成。读条不会因为客户端时间戳或 ProximityPrompt 完成事件而跳过。
--
-- 规则：
--   - 每名参与者同一时间只有一个读条；开始新读条会取消旧读条并返回它（调用方应以 REPLACED 广播）。
--   - 每个 tick 先校验后累计；校验失败立即取消，本次 tick 的 delta 不计入。
--   - 同一 tick 多个读条完成时按 seq（开始顺序）确定性输出；取消同样按 seq 排序。
--   - 时间回拨（now < lastCheckedAt）不会倒退累计。
-- 纯逻辑：无 Roblox 全局对象，状态是普通表，时间由调用方传入。

export type ChannelKind = "CURE" | "RELINK" | "EXTRACT"

export type Channel = {
	actorId: string,
	kind: ChannelKind,
	targetId: string?,
	startedAt: number,
	lastCheckedAt: number,
	accumulated: number,
	duration: number,
	seq: number,
}

export type Cancelled = {
	channel: Channel,
	reason: string,
}

export type TickResult = {
	completed: { Channel },
	cancelled: { Cancelled },
}

export type Progress = {
	actorId: string,
	kind: ChannelKind,
	targetId: string?,
	elapsed: number,
	duration: number,
	ratio: number,
}

export type State = {
	channels: { [string]: Channel },
	seq: number,
}

local ChannelTimer = {}

local KIND_CURE: ChannelKind = "CURE"
local KIND_RELINK: ChannelKind = "RELINK"
local KIND_EXTRACT: ChannelKind = "EXTRACT"

local Kind = table.freeze({
	CURE = KIND_CURE,
	RELINK = KIND_RELINK,
	EXTRACT = KIND_EXTRACT,
})
ChannelTimer.Kind = Kind

local Reason = table.freeze({
	InvalidActor = "INVALID_ACTOR",
	InvalidKind = "INVALID_KIND",
	InvalidDuration = "INVALID_DURATION",
	Invalid = "INVALID",
})
ChannelTimer.Reason = Reason

local function isKnownKind(kind: string): boolean
	return kind == KIND_CURE or kind == KIND_RELINK or kind == KIND_EXTRACT
end

local function sortedChannels(state: State): { Channel }
	local active: { Channel } = {}
	for _, channel in state.channels do
		table.insert(active, channel)
	end
	table.sort(active, function(a: Channel, b: Channel): boolean
		return a.seq < b.seq
	end)
	return active
end

local function copy(channel: Channel): Channel
	return {
		actorId = channel.actorId,
		kind = channel.kind,
		targetId = channel.targetId,
		startedAt = channel.startedAt,
		lastCheckedAt = channel.lastCheckedAt,
		accumulated = channel.accumulated,
		duration = channel.duration,
		seq = channel.seq,
	}
end

function ChannelTimer.new(): State
	return { channels = {}, seq = 0 }
end

-- 开始读条。第三返回值是被取消的旧读条（没有则为 nil），调用方据此发 ChannelCancelled(REPLACED)。
function ChannelTimer.start(
	state: State,
	actorId: string,
	kind: ChannelKind,
	targetId: string?,
	now: number,
	duration: number
): (boolean, string?, Channel?)
	if actorId == "" then
		return false, Reason.InvalidActor, nil
	end
	if not isKnownKind(kind) then
		return false, Reason.InvalidKind, nil
	end
	if duration ~= duration or duration < 0 or duration == math.huge then
		return false, Reason.InvalidDuration, nil
	end

	local replaced = state.channels[actorId]
	if replaced ~= nil then
		state.channels[actorId] = nil
	end

	state.seq += 1
	state.channels[actorId] = {
		actorId = actorId,
		kind = kind,
		targetId = targetId,
		startedAt = now,
		lastCheckedAt = now,
		accumulated = 0,
		duration = duration,
		seq = state.seq,
	}
	return true, nil, replaced
end

-- 推进所有读条。isStillValid 每个 tick 对每个读条调用一次；返回 false 时取消并携带原因。
function ChannelTimer.tick(
	state: State,
	now: number,
	isStillValid: (channel: Channel) -> (boolean, string?)
): TickResult
	local completed: { Channel } = {}
	local cancelled: { Cancelled } = {}

	for _, channel in sortedChannels(state) do
		local valid, reason = isStillValid(channel)
		if not valid then
			state.channels[channel.actorId] = nil
			table.insert(cancelled, { channel = channel, reason = reason or Reason.Invalid })
		else
			local delta = now - channel.lastCheckedAt
			if delta > 0 then
				channel.accumulated += delta
				channel.lastCheckedAt = now
			end
			if channel.accumulated >= channel.duration then
				state.channels[channel.actorId] = nil
				table.insert(completed, channel)
			end
		end
	end

	return { completed = completed, cancelled = cancelled }
end

-- 主动取消一名参与者的读条。
function ChannelTimer.cancel(state: State, actorId: string, _reason: string): Channel?
	local channel = state.channels[actorId]
	if channel == nil then
		return nil
	end
	state.channels[actorId] = nil
	return channel
end

-- 取消所有涉及该参与者的读条（本人是施放者或目标）：退出、被咬、状态变化时使用。
function ChannelTimer.cancelInvolving(state: State, participantId: string, reason: string): { Cancelled }
	local cancelled: { Cancelled } = {}
	for _, channel in sortedChannels(state) do
		if channel.actorId == participantId or channel.targetId == participantId then
			state.channels[channel.actorId] = nil
			table.insert(cancelled, { channel = channel, reason = reason })
		end
	end
	return cancelled
end

-- 取消全部读条（回合结束）。
function ChannelTimer.cancelAll(state: State, reason: string): { Cancelled }
	local cancelled: { Cancelled } = {}
	for _, channel in sortedChannels(state) do
		state.channels[channel.actorId] = nil
		table.insert(cancelled, { channel = channel, reason = reason })
	end
	return cancelled
end

-- 当前读条快照；调用方不得通过返回值改写状态。
function ChannelTimer.get(state: State, actorId: string): Channel?
	local channel = state.channels[actorId]
	if channel == nil then
		return nil
	end
	return copy(channel)
end

-- 所有活动读条的快照，按开始顺序。
function ChannelTimer.active(state: State): { Channel }
	local active: { Channel } = {}
	for _, channel in sortedChannels(state) do
		table.insert(active, copy(channel))
	end
	return active
end

function ChannelTimer.count(state: State): number
	local total = 0
	for _ in state.channels do
		total += 1
	end
	return total
end

-- 展示用进度：把“上次校验之后的时间”也计入 elapsed，但不改变内部累计。
function ChannelTimer.progress(state: State, actorId: string, now: number): Progress?
	local channel = state.channels[actorId]
	if channel == nil then
		return nil
	end
	local elapsed = channel.accumulated
	local delta = now - channel.lastCheckedAt
	if delta > 0 then
		elapsed += delta
	end
	if elapsed > channel.duration then
		elapsed = channel.duration
	end
	if elapsed < 0 then
		elapsed = 0
	end
	local ratio = if channel.duration > 0 then elapsed / channel.duration else 1
	return {
		actorId = channel.actorId,
		kind = channel.kind,
		targetId = channel.targetId,
		elapsed = elapsed,
		duration = channel.duration,
		ratio = ratio,
	}
end

return table.freeze(ChannelTimer)
