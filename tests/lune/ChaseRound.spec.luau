--!strict
-- ChaseRound 的 A0 回合状态机测试：阶段计时、零号选择、尸变、胜负与退出补选（GDB V1.1 §7.3、§19.5、§24.4）。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local Constants = require("../../src/shared/Constants")
local PublicEventTypes = require("../../src/shared/PublicEventTypes")
local ChaseRound = require("../../src/server/logic/ChaseRound")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local Phase = ChaseRound.Phase
local EventType = ChaseRound.EventType
local ContestStart = BalanceConfig.A0.PrepareSeconds
local ContestEnd = ContestStart + BalanceConfig.A0.RoundSeconds

local function firstSeed(_count: number): number
	return 1
end

local function secondSeed(_count: number): number
	return 2
end

local function newRound(ids: { string }, pickSeed: ((count: number) -> number)?): ChaseRound.Round
	return ChaseRound.new(BalanceConfig, ids, "round-test", 0, pickSeed or firstSeed)
end

local function startContest(round: ChaseRound.Round): number
	ChaseRound.tick(round, 0)
	ChaseRound.tick(round, ContestStart)
	return ContestStart
end

local function hasEvent(events: { ChaseRound.PublicEvent }, eventType: string, participantId: string?): boolean
	for _, event in events do
		if event.type == eventType and (participantId == nil or event.participantId == participantId) then
			return true
		end
	end
	return false
end

local function countState(round: ChaseRound.Round, state: string): number
	local count = 0
	for _, id in round.order do
		local participant = round.participants[id]
		if participant ~= nil and participant.state == state then
			count += 1
		end
	end
	return count
end

describe("共享枚举与配置一致性", function()
	it("阶段名与 Constants.RoundPhase 一致", function()
		expect(Phase.WAITING).toBe(Constants.RoundPhase.WAITING)
		expect(Phase.PREPARE).toBe(Constants.RoundPhase.PREPARE)
		expect(Phase.CONTEST).toBe(Constants.RoundPhase.CONTEST)
		expect(Phase.RESULT).toBe(Constants.RoundPhase.RESULT)
	end)

	it("事件名与 PublicEventTypes.Public 一致", function()
		expect(EventType.RoundPhaseChanged).toBe(PublicEventTypes.Public.RoundPhaseChanged)
		expect(EventType.OutbreakStarted).toBe(PublicEventTypes.Public.OutbreakStarted)
		expect(EventType.InfectionTurning).toBe(PublicEventTypes.Public.InfectionTurning)
		expect(EventType.InfectionRevealed).toBe(PublicEventTypes.Public.InfectionRevealed)
		expect(EventType.RoundResult).toBe(PublicEventTypes.Public.RoundResult)
	end)

	it("A0.PrepareSeconds 与顶层 PrepareSeconds 一致", function()
		expect(BalanceConfig.A0.PrepareSeconds).toBe(BalanceConfig.PrepareSeconds)
	end)
end)

describe("new / 阶段推进", function()
	it("初始为 WAITING，首次 tick 进入 PREPARE", function()
		local round = newRound({ "p1", "p2" })
		expect(round.phase).toBe(Phase.WAITING)
		expect(#round.order).toBe(2)

		local first = ChaseRound.tick(round, 0)
		expect(round.phase).toBe(Phase.PREPARE)
		expect(round.phaseEndsAt).toBe(ContestStart)
		expect(hasEvent(first.events, EventType.RoundPhaseChanged)).toBe(true)
	end)

	it("PREPARE 到期进入 CONTEST，CONTEST 到期人类获胜", function()
		local round = newRound({ "p1", "p2" })
		startContest(round)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(round.contestEndsAt).toBe(ContestEnd)

		ChaseRound.tick(round, ContestEnd - 0.1)
		expect(round.phase).toBe(Phase.CONTEST)

		local result = ChaseRound.tick(round, ContestEnd)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(hasEvent(result.events, EventType.RoundResult)).toBe(true)
	end)

	it("重复参与者 ID 只保留一次", function()
		local round = newRound({ "p1", "p1", "p2" })
		expect(#round.order).toBe(2)
	end)

	it("少于 2 名参与者时直接中止", function()
		local round = newRound({ "p1" })
		local result = ChaseRound.tick(round, 0)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBeNil()
		expect(hasEvent(result.events, EventType.RoundResult)).toBe(true)
	end)

	it("RESULT 是终态，后续 tick 不产生事件", function()
		local round = newRound({ "p1", "p2" })
		startContest(round)
		ChaseRound.tick(round, ContestEnd)
		local after = ChaseRound.tick(round, ContestEnd + 100)
		expect(#after.events).toBe(0)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
	end)
end)

describe("零号选择", function()
	it("CONTEST 开始时按注入的 pickSeed 选择零号并广播 OutbreakStarted", function()
		local round = newRound({ "p1", "p2", "p3" })
		local startEvents = ChaseRound.tick(round, 0)
		local contestEvents = ChaseRound.tick(round, ContestStart)
		expect(hasEvent(startEvents.events, EventType.OutbreakStarted)).toBe(false)
		expect(hasEvent(contestEvents.events, EventType.OutbreakStarted, "p1")).toBe(true)
		expect(round.participants.p1.state).toBe("INFECTED")
		expect(round.participants.p1.isRoot).toBe(true)
		expect(countState(round, "INFECTED")).toBe(BalanceConfig.A0.SeedCount)
		expect(countState(round, "HUMAN")).toBe(2)
	end)

	it("pickSeed 返回值决定零号", function()
		local round = newRound({ "p1", "p2", "p3" }, secondSeed)
		startContest(round)
		expect(round.participants.p2.state).toBe("INFECTED")
		expect(round.participants.p2.isRoot).toBe(true)
		expect(round.participants.p1.state).toBe("HUMAN")
	end)

	it("SeedCount 来自配置，可一次选出多个零号", function()
		local twoSeedConfig = {
			IncubationSeconds = BalanceConfig.IncubationSeconds,
			A0 = {
				PrepareSeconds = BalanceConfig.A0.PrepareSeconds,
				RoundSeconds = BalanceConfig.A0.RoundSeconds,
				SeedCount = 2,
			},
		}
		local round = ChaseRound.new(twoSeedConfig, { "p1", "p2", "p3" }, "round-test", 0, firstSeed)
		ChaseRound.tick(round, 0)
		ChaseRound.tick(round, BalanceConfig.A0.PrepareSeconds)
		expect(countState(round, "INFECTED")).toBe(2)
		expect(countState(round, "HUMAN")).toBe(1)
	end)
end)

describe("扑咬与尸变", function()
	it("扑咬把 HUMAN 变为 INCUBATING，到期后公开变为 INFECTED", function()
		local round = newRound({ "p1", "p2", "p3" })
		startContest(round)

		local turnAt = 30
		local turning = ChaseRound.onBite(round, "p1", "p2", turnAt)
		expect(round.participants.p2.state).toBe("INCUBATING")
		expect(round.participants.p2.incubationEndsAt).toBe(turnAt + BalanceConfig.IncubationSeconds)
		expect(hasEvent(turning.events, EventType.InfectionTurning, "p2")).toBe(true)

		ChaseRound.tick(round, turnAt + BalanceConfig.IncubationSeconds - 0.1)
		expect(round.participants.p2.state).toBe("INCUBATING")

		local revealed = ChaseRound.tick(round, turnAt + BalanceConfig.IncubationSeconds)
		expect(round.participants.p2.state).toBe("INFECTED")
		expect(hasEvent(revealed.events, EventType.InfectionRevealed, "p2")).toBe(true)
	end)

	it("无效扑咬被忽略", function()
		local round = newRound({ "p1", "p2", "p3" })
		local beforeContest = ChaseRound.onBite(round, "p1", "p2", 1)
		expect(#beforeContest.events).toBe(0)
		expect(round.participants.p2.state).toBe("HUMAN")

		startContest(round)
		local humanAttacker = ChaseRound.onBite(round, "p2", "p3", 30)
		expect(#humanAttacker.events).toBe(0)
		expect(round.participants.p3.state).toBe("HUMAN")

		local selfBite = ChaseRound.onBite(round, "p1", "p1", 30)
		expect(#selfBite.events).toBe(0)
	end)
end)

describe("胜负", function()
	it("最后一名 HUMAN 被咬后丧尸立即获胜（INCUBATING 已计入失败）", function()
		local round = newRound({ "p1", "p2", "p3" })
		startContest(round)

		ChaseRound.onBite(round, "p1", "p2", 30)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(round.participants.p2.state).toBe("INCUBATING")

		local win = ChaseRound.onBite(round, "p1", "p3", 31)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("INFECTED")
		expect(hasEvent(win.events, EventType.RoundResult)).toBe(true)
	end)

	it("人类退出导致场上没有 HUMAN 时丧尸获胜", function()
		local round = newRound({ "p1", "p2", "p3", "p4" })
		startContest(round)
		ChaseRound.onBite(round, "p1", "p2", 30)
		ChaseRound.removeParticipant(round, "p3", 31)
		expect(round.phase).toBe(Phase.CONTEST)

		local result = ChaseRound.removeParticipant(round, "p4", 32)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("INFECTED")
		expect(hasEvent(result.events, EventType.RoundResult)).toBe(true)
	end)
end)

describe("退出与补选", function()
	it("最后一只丧尸离开后从剩余人类中补选零号", function()
		local round = newRound({ "p1", "p2", "p3" })
		startContest(round)
		expect(round.participants.p1.state).toBe("INFECTED")

		local result = ChaseRound.removeParticipant(round, "p1", 30)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(round.winner).toBeNil()
		expect(round.participants.p2.state).toBe("INFECTED")
		expect(round.participants.p2.isRoot).toBe(true)
		expect(round.participants.p3.state).toBe("HUMAN")
		expect(hasEvent(result.events, EventType.OutbreakStarted, "p2")).toBe(true)
	end)

	it("退出后不足 2 人时中止且不再补选", function()
		local round = newRound({ "p1", "p2", "p3" })
		startContest(round)

		ChaseRound.removeParticipant(round, "p3", 30)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(#round.order).toBe(2)

		local result = ChaseRound.removeParticipant(round, "p2", 31)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBeNil()
		expect(hasEvent(result.events, EventType.RoundResult)).toBe(true)
		expect(hasEvent(result.events, EventType.OutbreakStarted)).toBe(false)
	end)

	it("移除不存在的参与者不产生任何变化", function()
		local round = newRound({ "p1", "p2" })
		startContest(round)
		local result = ChaseRound.removeParticipant(round, "missing", 30)
		expect(#result.events).toBe(0)
		expect(#round.order).toBe(2)
		expect(round.phase).toBe(Phase.CONTEST)
	end)
end)

TestKit.finish()
