--!strict
-- RoundStateMachine.cancelChannel（Gate A-2b）：客户端释放交互键时服务端主动取消读条。
-- 覆盖：治愈读条取消 → 保留解药 + 短冷却；无读条 → INVALID；重连读条取消 → 清除元数据，可立即重试。

local TestKit = require("./TestKit")
local CureInventory = require("../../src/server/logic/CureInventory")
local ChannelTimer = require("../../src/server/logic/ChannelTimer")
local InfectionGraph = require("../../src/server/logic/InfectionGraph")
local RoundStateMachine = require("../../src/server/logic/RoundStateMachine")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = RoundStateMachine.Reason

local CONFIG: RoundStateMachine.Config = {
	PrepareSeconds = 1,
	IncubationSeconds = 1,
	DisconnectSeconds = 8,
	CuredImmunitySeconds = 2,
	ReconnectHoldSeconds = 0.5,
	RootRelinkHoldMultiplier = 1.5,
	CureChannelSeconds = 2,
	CureRetryCooldownSeconds = 1.5,
	ContainmentStableSeconds = 1,
	ExtractionWindowSeconds = 10,
	LateJoinHumanWindowSeconds = 2,
	Greybox = {
		CureRange = 8,
		RelinkRange = 8,
		ExtractHoldSeconds = 1,
	},
}

local PLAN: RoundStateMachine.Plan = {
	tier = {
		roundSeconds = 60,
		seedCount = 1,
		cures = 2,
		requiredExtracted = 1,
	},
}

local function makeHooks(): RoundStateMachine.Hooks
	return {
		canCureTarget = function(): boolean
			return true
		end,
		inRange = function(): boolean
			return true
		end,
		isInExtractionZone = function(): boolean
			return false
		end,
		canBeRelinkTarget = function(): boolean
			return true
		end,
		positionOf = function(): unknown
			return nil
		end,
	}
end

local function newRound(ids: { string }): RoundStateMachine.Round
	local round = RoundStateMachine.new(CONFIG, PLAN, ids, "commands-round", 0, function(): number
		return 1
	end, { "slot-1", "slot-2", "slot-3" })
	InfectionGraph.assertInvariants(round.graph)
	return round
end

local function toContest(round: RoundStateMachine.Round, hooks: RoundStateMachine.Hooks)
	RoundStateMachine.tick(round, 0, hooks)
	RoundStateMachine.tick(round, 1, hooks)
	RoundStateMachine.tick(round, 2, hooks)
end

local function expectState(round: RoundStateMachine.Round, id: string, expected: string)
	local participant = InfectionGraph.getState(round.graph, id)
	assert(participant, `参与者 {id} 不存在`)
	expect(participant.state).toBe(expected)
end

describe("cancelChannel", function()
	it("cancels a cure channel, keeps the cure and starts the retry cooldown", function()
		local ids = { "U:1", "U:2", "U:3" }
		local round = newRound(ids)
		local hooks = makeHooks()
		toContest(round, hooks)

		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		RoundStateMachine.tick(round, 3.5, hooks)
		expectState(round, "U:2", "INFECTED")

		CureInventory.pickup(round.cures, "C:1", "U:3")
		expect(RoundStateMachine.requestCure(round, "U:3", "U:2", 5).ok).toBe(true)
		expect(ChannelTimer.get(round.channels, "U:3").kind).toBe("CURE")

		local result = RoundStateMachine.cancelChannel(round, "U:3", 5.5)
		expect(result.ok).toBe(true)
		expect(ChannelTimer.get(round.channels, "U:3")).toBeNil()
		expect(CureInventory.heldBy(round.cures, "U:3")).toBe("C:1")
		expect(CureInventory.canAttempt(round.cures, "U:3", 5.5)).toBe(false)
		expect(CureInventory.canAttempt(round.cures, "U:3", 7.0)).toBe(true)

		local cancellation = nil
		for _, event in result.events do
			if event.type == RoundStateMachine.EventName.ChannelCancelled then
				cancellation = event
			end
		end
		assert(cancellation, "expected a ChannelCancelled event")
		expect(cancellation.reason).toBe(Reason.Cancelled)
		expect(cancellation.channelKind).toBe("CURE")
		expectState(round, "U:2", "INFECTED")
	end)

	it("returns INVALID when there is no active channel", function()
		local round = newRound({ "U:1", "U:2" })
		local result = RoundStateMachine.cancelChannel(round, "U:1", 5)
		expect(result.ok).toBe(false)
		expect(result.reason).toBe(Reason.Invalid)
		expect(#result.events).toBe(0)
	end)

	it("cancels a relink channel and clears its metadata so a retry can start", function()
		local ids = { "U:1", "U:2", "U:3", "U:4" }
		local round = newRound(ids)
		local hooks = makeHooks()
		toContest(round, hooks)

		-- A -> B -> C, D; cure B so C/D go UNSTABLE, then cancel C's relink.
		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		RoundStateMachine.tick(round, 3.5, hooks)
		expect(RoundStateMachine.onBite(round, "U:2", "U:3", 4).ok).toBe(true)
		RoundStateMachine.tick(round, 5, hooks)
		expectState(round, "U:3", "INFECTED")

		CureInventory.pickup(round.cures, "C:1", "U:4")
		expect(RoundStateMachine.requestCure(round, "U:4", "U:2", 6).ok).toBe(true)
		RoundStateMachine.tick(round, 8, hooks)
		expectState(round, "U:3", "UNSTABLE")

		expect(RoundStateMachine.requestRelink(round, "U:3", "U:1", 8.5).ok).toBe(true)
		expect(ChannelTimer.get(round.channels, "U:3").kind).toBe("RELINK")

		local result = RoundStateMachine.cancelChannel(round, "U:3", 9)
		expect(result.ok).toBe(true)
		expect(ChannelTimer.get(round.channels, "U:3")).toBeNil()

		-- 取消后立即可重新请求（重连没有失败冷却）。
		expect(RoundStateMachine.requestRelink(round, "U:3", "U:1", 9.1).ok).toBe(true)
	end)
end)

TestKit.finish()
