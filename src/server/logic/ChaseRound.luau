--!strict
-- Gate A0 纯追逐回合状态机（GDB V1.1 §5、§7.3、§19.5、§24.4）：WAITING → PREPARE → CONTEST → RESULT。
-- A0 没有治愈、感染树、扫描或撤离；只保留人类/丧尸、尸变过渡与两个胜负条件。
-- 纯逻辑：全部状态是普通表，时间由参数传入，种子选择由调用方注入以便测试确定性。
--
-- Gate A-2b 起 RoundService 改由 RoundStateMachine 驱动（完整感染森林 / 解药 / 断联 / 重连 / 撤离）；
-- 本模块保留作为 A0 的对照基线与回归测试对象，不再被运行中的回合循环 require。

export type Config = {
	IncubationSeconds: number,
	A0: {
		PrepareSeconds: number,
		RoundSeconds: number,
		SeedCount: number,
	},
}

export type RoundPhase = "WAITING" | "PREPARE" | "CONTEST" | "RESULT"

export type Winner = "INFECTED" | "HUMANS"

export type ParticipantRoundState = {
	id: string,
	state: "HUMAN" | "INCUBATING" | "INFECTED",
	isRoot: boolean,
	incubationEndsAt: number?,
}

export type PublicEvent = {
	type: string,
	participantId: string?,
}

export type RoundEvents = {
	events: { PublicEvent },
}

export type Round = {
	roundId: string,
	config: Config,
	phase: RoundPhase,
	phaseEndsAt: number?,
	contestEndsAt: number?,
	winner: Winner?,
	startedAt: number,
	participants: { [string]: ParticipantRoundState },
	order: { string },
	pickSeed: (count: number) -> number,
}

local ChaseRound = {}

-- 与 Constants.RoundPhase / PublicEventTypes.Public 保持一致（纯模块不能跨 Rojo 树 require 共享模块）。
local Phase = table.freeze({
	WAITING = "WAITING",
	PREPARE = "PREPARE",
	CONTEST = "CONTEST",
	RESULT = "RESULT",
})
ChaseRound.Phase = Phase

local EventType = table.freeze({
	RoundPhaseChanged = "RoundPhaseChanged",
	OutbreakStarted = "OutbreakStarted",
	InfectionTurning = "InfectionTurning",
	InfectionRevealed = "InfectionRevealed",
	RoundResult = "RoundResult",
})
ChaseRound.EventType = EventType

local function counts(round: Round): (number, number, number)
	local humans, incubating, infected = 0, 0, 0
	for _, id in round.order do
		local participant = round.participants[id]
		if participant ~= nil then
			if participant.state == "HUMAN" then
				humans += 1
			elseif participant.state == "INCUBATING" then
				incubating += 1
			elseif participant.state == "INFECTED" then
				infected += 1
			end
		end
	end
	return humans, incubating, infected
end

local function humanCandidates(round: Round): { string }
	local candidates: { string } = {}
	for _, id in round.order do
		local participant = round.participants[id]
		if participant ~= nil and participant.state == "HUMAN" then
			table.insert(candidates, id)
		end
	end
	return candidates
end

local function setPhase(round: Round, phase: RoundPhase, phaseEndsAt: number?, events: { PublicEvent })
	round.phase = phase
	round.phaseEndsAt = phaseEndsAt
	table.insert(events, { type = EventType.RoundPhaseChanged })
end

local function finish(round: Round, winner: Winner?, events: { PublicEvent })
	if round.phase == "RESULT" then
		return
	end
	round.phase = "RESULT"
	round.phaseEndsAt = nil
	round.winner = winner
	table.insert(events, { type = EventType.RoundPhaseChanged })
	table.insert(events, { type = EventType.RoundResult })
end

-- 从当前 HUMAN 中选出 SeedCount 个零号；pickSeed 返回 1-based 序号，非法返回值回退到第一个候选。
local function selectSeeds(round: Round, events: { PublicEvent }, count: number)
	local candidates = humanCandidates(round)
	local seedsToPick = math.min(math.max(0, math.floor(count)), #candidates)
	for _ = 1, seedsToPick do
		local index = round.pickSeed(#candidates)
		if index % 1 ~= 0 or index < 1 or index > #candidates then
			index = 1
		end
		local id = candidates[index]
		table.remove(candidates, index)
		local participant = round.participants[id]
		if participant ~= nil then
			participant.state = "INFECTED"
			participant.isRoot = true
			participant.incubationEndsAt = nil
			table.insert(events, { type = EventType.OutbreakStarted, participantId = id })
		end
	end
end

-- 尸变过渡到期：INCUBATING → INFECTED（公开事件，D1）。
local function promoteDue(round: Round, now: number, events: { PublicEvent })
	for _, id in round.order do
		local participant = round.participants[id]
		if participant ~= nil and participant.state == "INCUBATING" then
			local endsAt = participant.incubationEndsAt
			if endsAt ~= nil and endsAt <= now then
				participant.state = "INFECTED"
				participant.incubationEndsAt = nil
				table.insert(events, { type = EventType.InfectionRevealed, participantId = id })
			end
		end
	end
end

function ChaseRound.new(
	config: Config,
	participantIds: { string },
	roundId: string,
	now: number,
	pickSeed: (count: number) -> number
): Round
	local participants: { [string]: ParticipantRoundState } = {}
	local order: { string } = {}
	for _, id in participantIds do
		if participants[id] == nil then
			participants[id] = { id = id, state = "HUMAN", isRoot = false, incubationEndsAt = nil }
			table.insert(order, id)
		end
	end

	return {
		roundId = roundId,
		config = config,
		phase = "WAITING",
		phaseEndsAt = nil,
		contestEndsAt = nil,
		winner = nil,
		startedAt = now,
		participants = participants,
		order = order,
		pickSeed = pickSeed,
	}
end

-- 推进计时器与尸变过渡。首次 tick 把 WAITING 推进到 PREPARE。
function ChaseRound.tick(round: Round, now: number): RoundEvents
	local events: { PublicEvent } = {}
	if round.phase == "RESULT" then
		return { events = events }
	end

	if #round.order < 2 then
		finish(round, nil, events)
		return { events = events }
	end

	if round.phase == "WAITING" then
		setPhase(round, "PREPARE", now + round.config.A0.PrepareSeconds, events)
	elseif round.phase == "PREPARE" then
		local phaseEndsAt = round.phaseEndsAt
		if phaseEndsAt ~= nil and now >= phaseEndsAt then
			local contestEndsAt = now + round.config.A0.RoundSeconds
			round.contestEndsAt = contestEndsAt
			setPhase(round, "CONTEST", contestEndsAt, events)
			selectSeeds(round, events, round.config.A0.SeedCount)

			local humans = counts(round)
			if humans == 0 then
				finish(round, "INFECTED", events)
			end
		end
	elseif round.phase == "CONTEST" then
		promoteDue(round, now, events)

		local humans = counts(round)
		local contestEndsAt = round.contestEndsAt
		if humans == 0 then
			-- INCUBATING 已经计入人类失败，因此只要没有 HUMAN 就是丧尸胜。
			finish(round, "INFECTED", events)
		elseif contestEndsAt ~= nil and now >= contestEndsAt then
			finish(round, "HUMANS", events)
		end
	end

	return { events = events }
end

-- 服务端确认一次扑咬：HUMAN → INCUBATING。A0 不建感染树，只记录尸变倒计时。
function ChaseRound.onBite(round: Round, attackerId: string, targetId: string, now: number): RoundEvents
	local events: { PublicEvent } = {}
	if round.phase ~= "CONTEST" then
		return { events = events }
	end

	local attacker = round.participants[attackerId]
	local target = round.participants[targetId]
	if attacker == nil or attacker.state ~= "INFECTED" then
		return { events = events }
	end
	if target == nil or target.state ~= "HUMAN" then
		return { events = events }
	end

	target.state = "INCUBATING"
	target.isRoot = false
	target.incubationEndsAt = now + round.config.IncubationSeconds
	table.insert(events, { type = EventType.InfectionTurning, participantId = targetId })

	local humans = counts(round)
	if humans == 0 then
		finish(round, "INFECTED", events)
	end

	return { events = events }
end

-- 参与者离开。CONTEST 中最后一只丧尸离开时从剩余人类里补选零号，避免回合死锁。
-- 人数不足 2 人则中止（winner = nil）；其余情况下若已无 HUMAN，丧尸立即获胜。
function ChaseRound.removeParticipant(round: Round, id: string, _now: number): RoundEvents
	local events: { PublicEvent } = {}
	if round.participants[id] == nil then
		return { events = events }
	end

	local index = table.find(round.order, id)
	if index ~= nil then
		table.remove(round.order, index)
	end
	round.participants[id] = nil

	if round.phase == "RESULT" then
		return { events = events }
	end

	if #round.order < 2 then
		finish(round, nil, events)
		return { events = events }
	end

	if round.phase == "CONTEST" then
		local humans, incubating, infected = counts(round)
		if humans == 0 then
			finish(round, "INFECTED", events)
		elseif incubating + infected == 0 then
			selectSeeds(round, events, 1)
			local humansAfterReseed = counts(round)
			if humansAfterReseed == 0 then
				finish(round, "INFECTED", events)
			end
		end
	end

	return { events = events }
end

return table.freeze(ChaseRound)
