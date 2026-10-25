--!strict
-- RoundStateMachine 集成测试（GDB V1.1 §4.1、§5.2、§6.1、§10、§11、§13.2–§13.3、§19.1、§21.2）：
-- 完整脚本回合、并行治愈裁决、零号拒绝、读条中断、撤离与中断、防提前判输、中途加入、200 局随机 soak。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local MatchConfig = require("../../src/server/logic/MatchConfig")
local InfectionGraph = require("../../src/server/logic/InfectionGraph")
local ChannelTimer = require("../../src/server/logic/ChannelTimer")
local CureInventory = require("../../src/server/logic/CureInventory")
local RoundStateMachine = require("../../src/server/logic/RoundStateMachine")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local EventName = RoundStateMachine.EventName
local Phase = RoundStateMachine.Phase
local Reason = RoundStateMachine.Reason

local BASE_CONFIG: RoundStateMachine.Config = {
	PrepareSeconds = 1,
	IncubationSeconds = 1,
	DisconnectSeconds = 8,
	CuredImmunitySeconds = 2,
	ReconnectHoldSeconds = 0.5,
	RootRelinkHoldMultiplier = 1.5,
	CureChannelSeconds = 1,
	CureRetryCooldownSeconds = 0.5,
	ContainmentStableSeconds = 1,
	ExtractionWindowSeconds = 10,
	LateJoinHumanWindowSeconds = 2,
	Greybox = {
		CureRange = 8,
		RelinkRange = 8,
		ExtractHoldSeconds = 1,
	},
}

local SLOTS = { "slot-1", "slot-2", "slot-3" }

local function makeConfig(overrides: { [string]: any }?): RoundStateMachine.Config
	local config = {
		PrepareSeconds = BASE_CONFIG.PrepareSeconds,
		IncubationSeconds = BASE_CONFIG.IncubationSeconds,
		DisconnectSeconds = BASE_CONFIG.DisconnectSeconds,
		CuredImmunitySeconds = BASE_CONFIG.CuredImmunitySeconds,
		ReconnectHoldSeconds = BASE_CONFIG.ReconnectHoldSeconds,
		RootRelinkHoldMultiplier = BASE_CONFIG.RootRelinkHoldMultiplier,
		CureChannelSeconds = BASE_CONFIG.CureChannelSeconds,
		CureRetryCooldownSeconds = BASE_CONFIG.CureRetryCooldownSeconds,
		ContainmentStableSeconds = BASE_CONFIG.ContainmentStableSeconds,
		ExtractionWindowSeconds = BASE_CONFIG.ExtractionWindowSeconds,
		LateJoinHumanWindowSeconds = BASE_CONFIG.LateJoinHumanWindowSeconds,
		Greybox = {
			CureRange = BASE_CONFIG.Greybox.CureRange,
			RelinkRange = BASE_CONFIG.Greybox.RelinkRange,
			ExtractHoldSeconds = BASE_CONFIG.Greybox.ExtractHoldSeconds,
		},
	}
	if overrides ~= nil then
		for key, value in overrides do
			if key == "Greybox" then
				for nestedKey, nestedValue in value do
					config.Greybox[nestedKey] = nestedValue
				end
			else
				config[key] = value
			end
		end
	end
	return config
end

local function makePlan(overrides: { [string]: any }?): RoundStateMachine.Plan
	local tier = {
		roundSeconds = 30,
		seedCount = 1,
		cures = 1,
		requiredExtracted = 1,
	}
	if overrides ~= nil then
		for key, value in overrides do
			tier[key] = value
		end
	end
	return { tier = tier }
end

local function constantRng(value: number?): RoundStateMachine.Rng
	local chosen = value or 1
	return function(_count: number): number
		return chosen
	end
end

type HookState = {
	zone: { [string]: boolean },
	dead: { [string]: boolean },
	far: { [string]: boolean },
	invalidRelink: { [string]: boolean },
	positions: { [string]: any },
}

local function makeHooks(): (HookState, RoundStateMachine.Hooks)
	local state: HookState = {
		zone = {},
		dead = {},
		far = {},
		invalidRelink = {},
		positions = {},
	}
	local hooks: RoundStateMachine.Hooks = {
		canCureTarget = function(targetId: string): boolean
			return not state.dead[targetId]
		end,
		inRange = function(a: string, b: string, _range: number): boolean
			return not state.far[`{a}|{b}`] and not state.far[`{b}|{a}`]
		end,
		isInExtractionZone = function(id: string): boolean
			return state.zone[id] == true
		end,
		canBeRelinkTarget = function(id: string): boolean
			return not state.invalidRelink[id]
		end,
		positionOf = function(id: string): any
			return state.positions[id]
		end,
	}
	return state, hooks
end

local function newRound(
	ids: { string },
	options: {
		config: RoundStateMachine.Config?,
		plan: RoundStateMachine.Plan?,
		roundId: string?,
		rng: RoundStateMachine.Rng?,
		slots: { unknown }?,
		previousSeedIds: { string }?,
	}?
): RoundStateMachine.Round
	local opts = options or {}
	local round = RoundStateMachine.new(
		opts.config or makeConfig(),
		opts.plan or makePlan(),
		ids,
		opts.roundId or "round-test",
		0,
		opts.rng or constantRng(1),
		opts.slots or SLOTS,
		opts.previousSeedIds
	)
	InfectionGraph.assertInvariants(round.graph)
	return round
end

local function tick(round: RoundStateMachine.Round, now: number, hooks: RoundStateMachine.Hooks)
	local result = RoundStateMachine.tick(round, now, hooks)
	InfectionGraph.assertInvariants(round.graph)
	return result
end

local function tickInto(log: { any }, round: RoundStateMachine.Round, now: number, hooks: RoundStateMachine.Hooks)
	local result = tick(round, now, hooks)
	for _, event in result.events do
		table.insert(log, event)
	end
	return result.events
end

local function collect(...: { any }): { any }
	local events: { any } = {}
	for _, batch in { ... } do
		for _, event in batch do
			table.insert(events, event)
		end
	end
	return events
end

local function filterType(events: { any }, eventType: string): { any }
	local found = {}
	for _, event in events do
		if event.type == eventType then
			table.insert(found, event)
		end
	end
	return found
end

local function countType(events: { any }, eventType: string): number
	return #filterType(events, eventType)
end

local function stateOf(round: RoundStateMachine.Round, id: string): InfectionGraph.Participant
	local participant = InfectionGraph.getState(round.graph, id)
	if participant == nil then
		error(`参与者 {id} 不存在`, 2)
	end
	return participant
end

local function expectState(round: RoundStateMachine.Round, id: string, expected: string)
	expect(stateOf(round, id).state).toBe(expected)
end

-- 推进到 CONTEST：t=1 爆发，t=2 零号公开尸变。
local function toContest(round: RoundStateMachine.Round, hooks: RoundStateMachine.Hooks): { any }
	return collect(tick(round, 1, hooks).events, tick(round, 2, hooks).events)
end

local function pickUp(round: RoundStateMachine.Round, itemId: string, participantId: string)
	local ok, reason = CureInventory.pickup(round.cures, itemId, participantId)
	if not ok then
		error(`拾取 {itemId} 失败：{reason}`, 2)
	end
end

describe("RoundStateMachine", function()
	it("runs a scripted round through every phase: cure a hub, one relink, one expiry, then extraction", function()
		local ids = { "U:1", "U:2", "U:3", "U:4", "U:5" }
		local round = newRound(ids)
		local hookState, hooks = makeHooks()
		hookState.positions["U:5"] = "extraction-zone"
		local log: { any } = {}

		tickInto(log, round, 0, hooks)
		expect(round.phase).toBe(Phase.PREPARE)

		local outbreakEvents = tickInto(log, round, 1, hooks)
		expect(round.phase).toBe(Phase.OUTBREAK)
		expect(countType(outbreakEvents, EventName.RoundPhaseChanged)).toBe(1)
		expect(countType(outbreakEvents, EventName.OutbreakStarted)).toBe(1)
		expect(countType(outbreakEvents, EventName.InfectionTurning)).toBe(1)
		expect(outbreakEvents[2].seedIds[1]).toBe("U:1")
		expectState(round, "U:1", InfectionGraph.State.INCUBATING)

		local revealEvents = tickInto(log, round, 2, hooks)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(countType(revealEvents, EventName.InfectionRevealed)).toBe(1)
		expectState(round, "U:1", InfectionGraph.State.INFECTED)

		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		tickInto(log, round, 3.5, hooks)
		expectState(round, "U:2", InfectionGraph.State.INFECTED)

		expect(RoundStateMachine.onBite(round, "U:2", "U:3", 4).ok).toBe(true)
		expect(RoundStateMachine.onBite(round, "U:2", "U:4", 4.5).ok).toBe(true)
		tickInto(log, round, 5, hooks)
		tickInto(log, round, 5.5, hooks)
		expectState(round, "U:3", InfectionGraph.State.INFECTED)
		expectState(round, "U:4", InfectionGraph.State.INFECTED)

		pickUp(round, "C:1", "U:5")
		local cureRequest = RoundStateMachine.requestCure(round, "U:5", "U:2", 6)
		expect(cureRequest.ok).toBe(true)
		expect(ChannelTimer.get(round.channels, "U:5").kind).toBe("CURE")

		local cureEvents = tickInto(log, round, 7, hooks)
		expectState(round, "U:2", InfectionGraph.State.HUMAN)
		expectState(round, "U:3", InfectionGraph.State.UNSTABLE)
		expectState(round, "U:4", InfectionGraph.State.UNSTABLE)
		expect(stateOf(round, "U:3").unstableEndsAt).toBe(15)
		expect(CureInventory.countByState(round.cures, "CONSUMED")).toBe(1)
		expect(countType(cureEvents, EventName.Cured)).toBe(1)
		expect(countType(cureEvents, EventName.ChainCutNearby)).toBe(1)
		expect(filterType(cureEvents, EventName.ChainCutNearby)[1].count).toBe(2)
		expect(countType(cureEvents, EventName.YouAreUnstable)).toBe(2)

		local relinkRequest = RoundStateMachine.requestRelink(round, "U:3", "U:1", 7)
		expect(relinkRequest.ok).toBe(true)
		local relinkEvents = tickInto(log, round, 7.75, hooks)
		expectState(round, "U:3", InfectionGraph.State.INFECTED)
		expectState(round, "U:4", InfectionGraph.State.UNSTABLE)
		expect(countType(relinkEvents, EventName.RelinkSucceeded)).toBe(1)

		tickInto(log, round, 15, hooks)
		expectState(round, "U:4", InfectionGraph.State.HUMAN)
		expect(round.phase).toBe(Phase.CONTEST)

		hookState.zone["U:5"] = true
		local extractionOpen = tickInto(log, round, 20, hooks)
		expect(round.phase).toBe(Phase.EXTRACTION)
		expect(countType(extractionOpen, EventName.ExtractionOpened)).toBe(1)

		local extractionDone = tickInto(log, round, 21, hooks)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(round.verdictReason).toBe("EXTRACTION_THRESHOLD")
		expect(round.extractedCount).toBe(1)
		expectState(round, "U:5", InfectionGraph.State.EXTRACTED)
		expect(countType(extractionDone, EventName.Extracted)).toBe(1)
		expect(countType(extractionDone, EventName.RoundResult)).toBe(1)

		-- 所有阶段都在事件里出现过，且最终只有一个判定。
		local phases: { [string]: boolean } = {}
		for _, event in log do
			if event.type == EventName.RoundPhaseChanged then
				phases[event.phase] = true
			end
		end
		for _, phase in { Phase.OUTBREAK, Phase.CONTEST, Phase.EXTRACTION, Phase.RESULT } do
			expect(phases[phase]).toBe(true)
		end
		expect(countType(log, EventName.RoundResult)).toBe(1)

		-- 公共事件不允许携带感染拓扑。
		for _, event in log do
			if event.scope == "PUBLIC" then
				expect(event.parentEpisodeId).toBeNil()
				expect(event.episodeId).toBeNil()
			end
		end
	end)

	it("two simultaneous cure channels on one target: one consumes, the other gets TARGET_CHANGED", function()
		local ids = { "U:1", "U:2", "U:3", "U:4", "U:5", "U:6" }
		local round = newRound(ids, { plan = makePlan({ cures = 2 }) })
		local _hookState, hooks = makeHooks()
		toContest(round, hooks)

		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		tick(round, 3.5, hooks)
		expectState(round, "U:2", InfectionGraph.State.INFECTED)

		pickUp(round, "C:1", "U:3")
		pickUp(round, "C:2", "U:4")
		expect(RoundStateMachine.requestCure(round, "U:3", "U:2", 5).ok).toBe(true)
		expect(RoundStateMachine.requestCure(round, "U:4", "U:2", 5).ok).toBe(true)

		local events = tick(round, 6, hooks).events
		expectState(round, "U:2", InfectionGraph.State.HUMAN)
		expect(countType(events, EventName.Cured)).toBe(1)
		local cancellations = filterType(events, EventName.ChannelCancelled)
		expect(#cancellations).toBe(1)
		expect(cancellations[1].reason).toBe(Reason.TargetChanged)
		expect(CureInventory.countByState(round.cures, "CONSUMED")).toBe(1)
		expect(CureInventory.countByState(round.cures, "CARRIED")).toBe(1)
		expect(CureInventory.heldBy(round.cures, "U:3")).toBeNil()
		expect(CureInventory.heldBy(round.cures, "U:4")).toBe("C:2")
	end)

	it("rejects a root cure without consuming the item or applying a cooldown", function()
		local round = newRound({ "U:1", "U:2" })
		local _hookState, hooks = makeHooks()
		toContest(round, hooks)
		pickUp(round, "C:1", "U:2")

		local result = RoundStateMachine.requestCure(round, "U:2", "U:1", 5)
		expect(result.ok).toBe(false)
		expect(result.reason).toBe(Reason.RootImmune)
		expect(#result.events).toBe(0)
		expect(CureInventory.heldBy(round.cures, "U:2")).toBe("C:1")
		expect(CureInventory.canAttempt(round.cures, "U:2", 5)).toBe(true)
		expect(ChannelTimer.get(round.channels, "U:2")).toBeNil()

		tick(round, 10, hooks)
		expectState(round, "U:1", InfectionGraph.State.INFECTED)
		expect(CureInventory.countByState(round.cures, "CONSUMED")).toBe(0)
	end)

	it("an invalid cure target starts no channel but applies the short retry cooldown", function()
		local round = newRound({ "U:1", "U:2", "U:3" })
		local _hookState, hooks = makeHooks()
		toContest(round, hooks)
		pickUp(round, "C:1", "U:2")

		local result = RoundStateMachine.requestCure(round, "U:2", "U:3", 5)
		expect(result.ok).toBe(false)
		expect(result.reason).toBe(Reason.TargetNotInfected)
		expect(ChannelTimer.get(round.channels, "U:2")).toBeNil()
		expect(CureInventory.heldBy(round.cures, "U:2")).toBe("C:1")
		expect(CureInventory.canAttempt(round.cures, "U:2", 5)).toBe(false)
		expect(CureInventory.canAttempt(round.cures, "U:2", 5.5)).toBe(true)

		local unknown = RoundStateMachine.requestCure(round, "U:2", "U:404", 6)
		expect(unknown.ok).toBe(false)
		expect(unknown.reason).toBe(Reason.UnknownTarget)
		expect(CureInventory.canAttempt(round.cures, "U:2", 6)).toBe(false)
	end)

	it("cancels a cure channel when the target leaves range or becomes DEAD", function()
		local round = newRound({ "U:1", "U:2", "U:3" })
		local hookState, hooks = makeHooks()
		toContest(round, hooks)
		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		tick(round, 3.5, hooks)
		pickUp(round, "C:1", "U:3")

		expect(RoundStateMachine.requestCure(round, "U:3", "U:2", 5).ok).toBe(true)
		hookState.far["U:3|U:2"] = true
		local outOfRange = tick(round, 5.5, hooks).events
		expect(countType(outOfRange, EventName.ChannelCancelled)).toBe(1)
		expect(filterType(outOfRange, EventName.ChannelCancelled)[1].reason).toBe(Reason.OutOfRange)
		expectState(round, "U:2", InfectionGraph.State.INFECTED)
		expect(CureInventory.heldBy(round.cures, "U:3")).toBe("C:1")
		expect(CureInventory.canAttempt(round.cures, "U:3", 5.5)).toBe(false)

		hookState.far = {}
		hookState.dead["U:2"] = true
		expect(RoundStateMachine.requestCure(round, "U:3", "U:2", 6).ok).toBe(true)
		local deadTarget = tick(round, 6.5, hooks).events
		expect(filterType(deadTarget, EventName.ChannelCancelled)[1].reason).toBe(Reason.TargetInvalid)
		expectState(round, "U:2", InfectionGraph.State.INFECTED)
		expect(CureInventory.countByState(round.cures, "CONSUMED")).toBe(0)
	end)

	it("interrupts an extraction hold when the human is bitten", function()
		local round = newRound({ "U:1", "U:2" })
		local hookState, hooks = makeHooks()
		toContest(round, hooks)
		hookState.zone["U:2"] = true

		tick(round, 20, hooks)
		expect(round.phase).toBe(Phase.EXTRACTION)
		tick(round, 20.5, hooks)
		expect(ChannelTimer.get(round.channels, "U:2").kind).toBe("EXTRACT")

		local bite = RoundStateMachine.onBite(round, "U:1", "U:2", 20.6)
		expect(bite.ok).toBe(true)
		expect(countType(bite.events, EventName.ChannelCancelled)).toBe(1)
		expect(filterType(bite.events, EventName.ChannelCancelled)[1].reason).toBe(Reason.Bitten)

		local after = tick(round, 21, hooks).events
		expect(round.extractedCount).toBe(0)
		expect(countType(after, EventName.Extracted)).toBe(0)
		expectState(round, "U:2", InfectionGraph.State.INCUBATING)
	end)

	it("humans win when the required number of independent humans extracts", function()
		local ids = { "U:1", "U:2", "U:3" }
		local round = newRound(ids, { plan = makePlan({ requiredExtracted = 2 }) })
		local hookState, hooks = makeHooks()
		toContest(round, hooks)
		hookState.zone["U:2"] = true
		hookState.zone["U:3"] = true

		tick(round, 20, hooks)
		local events = tick(round, 21, hooks).events
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(round.verdictReason).toBe("EXTRACTION_THRESHOLD")
		expect(round.extractedCount).toBe(2)
		expect(countType(events, EventName.Extracted)).toBe(2)
		expect(countType(events, EventName.RoundResult)).toBe(1)
	end)

	it("drops a held cure when the holder is revealed as INFECTED and when a holder leaves", function()
		local round = newRound({ "U:1", "U:2", "U:3" }, { plan = makePlan({ cures = 2 }) })
		local hookState, hooks = makeHooks()
		toContest(round, hooks)

		pickUp(round, "C:1", "U:2")
		pickUp(round, "C:2", "U:3")
		hookState.positions["U:2"] = "pos:U:2"
		hookState.positions["U:3"] = "pos:U:3"

		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		tick(round, 3.5, hooks)
		expectState(round, "U:2", InfectionGraph.State.INFECTED)
		local droppedOnReveal = CureInventory.getItem(round.cures, "C:1")
		expect(droppedOnReveal.state).toBe(CureInventory.State.DROPPED)
		expect(droppedOnReveal.position).toBe("pos:U:2")
		expect(CureInventory.holderOf(round.cures, "C:1")).toBeNil()

		local removed = RoundStateMachine.removeParticipant(round, "U:3", 4, "pos:U:3")
		expect(removed.ok).toBe(true)
		local droppedOnLeave = CureInventory.getItem(round.cures, "C:2")
		expect(droppedOnLeave.state).toBe(CureInventory.State.DROPPED)
		expect(droppedOnLeave.position).toBe("pos:U:3")
		expect(#round.cures.order).toBe(2)
		expect(CureInventory.countByState(round.cures, CureInventory.State.CARRIED)).toBe(0)
	end)

	it("resets an extraction hold when the human leaves the zone (no bite needed)", function()
		local round = newRound({ "U:1", "U:2" })
		local hookState, hooks = makeHooks()
		toContest(round, hooks)
		hookState.zone["U:2"] = true

		tick(round, 20, hooks)
		tick(round, 20.5, hooks)
		hookState.zone["U:2"] = false
		local left = tick(round, 20.6, hooks).events
		expect(filterType(left, EventName.ChannelCancelled)[1].reason).toBe(Reason.OutOfRange)
		expect(round.extractedCount).toBe(0)

		hookState.zone["U:2"] = true
		tick(round, 20.7, hooks)
		local partial = tick(round, 21.2, hooks).events
		expect(round.extractedCount).toBe(0)
		expect(countType(partial, EventName.Extracted)).toBe(0)

		local completed = tick(round, 21.7, hooks).events
		expect(round.extractedCount).toBe(1)
		expect(countType(completed, EventName.Extracted)).toBe(1)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
	end)

	it("an extraction finishing on the timeout tick still wins for humans", function()
		local config = makeConfig({ Greybox = { ExtractHoldSeconds = 10 } })
		local round = newRound({ "U:1", "U:2" }, { config = config })
		local hookState, hooks = makeHooks()
		toContest(round, hooks)
		hookState.zone["U:2"] = true

		tick(round, 20, hooks)
		expect(round.extractedCount).toBe(0)
		local events = tick(round, 30, hooks).events
		expect(round.extractedCount).toBe(1)
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(round.verdictReason).toBe("EXTRACTION_THRESHOLD")
		expect(countType(events, EventName.Extracted)).toBe(1)
	end)

	it("does not decide while an UNSTABLE player may still recover (anti-early-loss)", function()
		local config = makeConfig({ CuredImmunitySeconds = 0 })
		local round = newRound({ "U:1", "U:2", "U:3", "U:4" }, { config = config })
		local _hookState, hooks = makeHooks()
		toContest(round, hooks)

		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).ok).toBe(true)
		tick(round, 3.5, hooks)
		expect(RoundStateMachine.onBite(round, "U:2", "U:3", 4).ok).toBe(true)
		tick(round, 5, hooks)
		expectState(round, "U:3", InfectionGraph.State.INFECTED)

		pickUp(round, "C:1", "U:4")
		expect(RoundStateMachine.requestCure(round, "U:4", "U:2", 6).ok).toBe(true)
		tick(round, 7, hooks)
		expectState(round, "U:2", InfectionGraph.State.HUMAN)
		expectState(round, "U:3", InfectionGraph.State.UNSTABLE)

		expect(RoundStateMachine.onBite(round, "U:1", "U:2", 7.5).ok).toBe(true)
		expect(RoundStateMachine.onBite(round, "U:1", "U:4", 7.6).ok).toBe(true)

		local pending = tick(round, 8.6, hooks).events
		expect(round.phase == Phase.RESULT).toBe(false)
		expect(countType(pending, EventName.RoundResult)).toBe(0)
		expectState(round, "U:2", InfectionGraph.State.INFECTED)
		expectState(round, "U:3", InfectionGraph.State.UNSTABLE)

		local recovered = tick(round, 15, hooks).events
		expect(round.phase == Phase.RESULT).toBe(false)
		expect(countType(recovered, EventName.RoundResult)).toBe(0)
		expectState(round, "U:3", InfectionGraph.State.HUMAN)

		local timeout = tick(round, 30, hooks).events
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("INFECTED")
		expect(round.verdictReason).toBe("TIMEOUT")
		expect(countType(timeout, EventName.RoundResult)).toBe(1)
	end)

	it("infected win at time up when the extraction threshold was missed", function()
		local round = newRound({ "U:1", "U:2" })
		local _hookState, hooks = makeHooks()
		toContest(round, hooks)
		tick(round, 20, hooks)
		expect(round.phase).toBe(Phase.EXTRACTION)

		local events = tick(round, 30, hooks).events
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("INFECTED")
		expect(round.verdictReason).toBe("TIMEOUT")
		expect(countType(events, EventName.RoundResult)).toBe(1)

		local after = RoundStateMachine.tick(round, 31, hooks)
		expect(#after.events).toBe(0)
		expect(countType(events, EventName.RoundResult)).toBe(1)
	end)

	it("a seed leaving during turning is replaced once and the round continues", function()
		local round = newRound({ "U:1", "U:2", "U:3" })
		local _hookState, hooks = makeHooks()
		local outbreak = tick(round, 1, hooks).events
		expect(filterType(outbreak, EventName.OutbreakStarted)[1].seedIds[1]).toBe("U:1")
		expectState(round, "U:1", InfectionGraph.State.INCUBATING)

		expect(RoundStateMachine.removeParticipant(round, "U:1", 1.2, "pos").ok).toBe(true)
		local replacement = tick(round, 1.2, hooks).events
		local replacements = filterType(replacement, EventName.OutbreakStarted)
		expect(#replacements).toBe(1)
		expect(replacements[1].count).toBe(1)
		expect(replacements[1].seedIds[1]).toBe("U:2")
		expect(countType(replacement, EventName.InfectionTurning)).toBe(1)
		expect(round.phase).toBe(Phase.OUTBREAK)
		expect(round.winner).toBeNil()
		expectState(round, "U:2", InfectionGraph.State.INCUBATING)
		expect(#round.seedSlots).toBe(1)
		expect(round.seedSlots[1].replacementUsed).toBe(true)

		-- 替补仍在尸变中：遏制不得在 OUTBREAK 期间抢跑。
		tick(round, 1.5, hooks)
		expect(round.phase).toBe(Phase.OUTBREAK)
		expect(round.winner).toBeNil()

		local revealed = tick(round, 2.2, hooks).events
		expectState(round, "U:2", InfectionGraph.State.INFECTED)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(countType(revealed, EventName.RoundResult)).toBe(0)

		tick(round, 3.5, hooks)
		expect(round.winner).toBeNil()
	end)

	it("a replacement seed leaving during turning ends with HUMANS / OUTBREAK_FAILED", function()
		local round = newRound({ "U:1", "U:2", "U:3" })
		local _hookState, hooks = makeHooks()
		tick(round, 1, hooks)
		RoundStateMachine.removeParticipant(round, "U:1", 1.2, "pos")
		tick(round, 1.2, hooks)
		expectState(round, "U:2", InfectionGraph.State.INCUBATING)
		expect(round.seedSlots[1].replacementUsed).toBe(true)

		expect(RoundStateMachine.removeParticipant(round, "U:2", 1.3, "pos").ok).toBe(true)
		local events = tick(round, 1.3, hooks).events
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(round.verdictReason).toBe(Reason.OutbreakFailed)

		local anomalies = filterType(events, EventName.Anomaly)
		expect(#anomalies).toBe(1)
		expect(anomalies[1].scope).toBe("PRIVATE")
		expect(anomalies[1].kind).toBe(Reason.OutbreakFailed)
		local results = filterType(events, EventName.RoundResult)
		expect(#results).toBe(1)
		expect(results[1].winner).toBe("HUMANS")
		expect(results[1].reason).toBe(Reason.OutbreakFailed)
	end)

	it("no eligible human at reselection ends with HUMANS / OUTBREAK_FAILED", function()
		local round = newRound({ "U:1" })
		local _hookState, hooks = makeHooks()
		tick(round, 1, hooks)
		expectState(round, "U:1", InfectionGraph.State.INCUBATING)

		RoundStateMachine.removeParticipant(round, "U:1", 1.2, nil)
		local events = tick(round, 1.2, hooks).events
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(round.verdictReason).toBe(Reason.OutbreakFailed)
		expect(countType(events, EventName.Anomaly)).toBe(1)
	end)

	it("a two-seed tier reselects only the slot whose seed left", function()
		local round = newRound({ "U:1", "U:2", "U:3", "U:4", "U:5" }, { plan = makePlan({ seedCount = 2 }) })
		local _hookState, hooks = makeHooks()
		local outbreak = tick(round, 1, hooks).events
		local started = filterType(outbreak, EventName.OutbreakStarted)[1]
		expect(started.count).toBe(2)
		expect(started.seedIds[1]).toBe("U:1")
		expect(started.seedIds[2]).toBe("U:2")
		expect(#round.seedSlots).toBe(2)
		expect(round.seedSlots[1].seedId).toBe("seed-1")
		expect(round.seedSlots[2].seedId).toBe("seed-2")

		RoundStateMachine.removeParticipant(round, "U:1", 1.2, "pos")
		local events = tick(round, 1.2, hooks).events
		local replacements = filterType(events, EventName.OutbreakStarted)
		expect(#replacements).toBe(1)
		expect(replacements[1].count).toBe(1)
		expect(replacements[1].seedIds[1]).toBe("U:3")
		expectState(round, "U:2", InfectionGraph.State.INCUBATING)
		expectState(round, "U:3", InfectionGraph.State.INCUBATING)
		expect(round.seedSlots[1].replacementUsed).toBe(true)
		expect(round.seedSlots[2].replacementUsed).toBe(false)
		expect(stateOf(round, "U:3").seedId).toBe("seed-1-r1")
		expect(stateOf(round, "U:2").seedId).toBe("seed-2")
	end)

	it("prefers participants who were not seeds last round and falls back when needed", function()
		local _hookState, hooks = makeHooks()
		local preferred = newRound({ "U:1", "U:2", "U:3" }, {
			roundId = "prev-1",
			previousSeedIds = { "U:1", "U:2" },
		})
		local preferredEvents = tick(preferred, 1, hooks).events
		expect(filterType(preferredEvents, EventName.OutbreakStarted)[1].seedIds[1]).toBe("U:3")
		expectState(preferred, "U:3", InfectionGraph.State.INCUBATING)

		local fallback = newRound({ "U:1", "U:2", "U:3" }, {
			roundId = "prev-2",
			previousSeedIds = { "U:1", "U:2", "U:3" },
		})
		local fallbackEvents = tick(fallback, 1, hooks).events
		expect(filterType(fallbackEvents, EventName.OutbreakStarted)[1].seedIds[1]).toBe("U:1")
		expectState(fallback, "U:1", InfectionGraph.State.INCUBATING)
	end)

	it("humans win by containment after the stability window once the tree is gone in CONTEST", function()
		local round = newRound({ "U:1", "U:2", "U:3" })
		local _hookState, hooks = makeHooks()
		tick(round, 1, hooks)
		tick(round, 2, hooks)
		expectState(round, "U:1", InfectionGraph.State.INFECTED)
		expect(round.phase).toBe(Phase.CONTEST)

		local removed = RoundStateMachine.removeParticipant(round, "U:1", 2.2, "last-position")
		expect(removed.ok).toBe(true)
		tick(round, 2.2, hooks)
		expect(round.phase).toBe(Phase.CONTEST)
		expect(round.containedSince).toBe(2.2)
		expect(round.winner).toBeNil()

		local events = tick(round, 3.2, hooks).events
		expect(round.phase).toBe(Phase.RESULT)
		expect(round.winner).toBe("HUMANS")
		expect(round.verdictReason).toBe("CONTAINMENT")
		expect(countType(events, EventName.RoundResult)).toBe(1)
	end)

	it("assigns late joiner roles by elapsed time and degrades INFECTED to HUMAN without a tree", function()
		local round = newRound({ "U:1", "U:2" })
		local _hookState, hooks = makeHooks()
		tick(round, 1, hooks)

		expect(RoundStateMachine.addLateJoiner(round, "L:1", 1.5).ok).toBe(true)
		expectState(round, "L:1", InfectionGraph.State.HUMAN)

		tick(round, 2, hooks)
		expect(RoundStateMachine.addLateJoiner(round, "L:2", 5).ok).toBe(true)
		expectState(round, "L:2", InfectionGraph.State.INFECTED)

		expect(RoundStateMachine.addLateJoiner(round, "L:3", 21).ok).toBe(true)
		expectState(round, "L:3", InfectionGraph.State.SPECTATOR)

		local duplicate = RoundStateMachine.addLateJoiner(round, "L:1", 22)
		expect(duplicate.ok).toBe(false)
		expect(duplicate.reason).toBe(InfectionGraph.Reason.AlreadyParticipant)

		-- 感染树在 CONTEST 后消失（不是零号在尸变中离场，因此不会触发补选）。
		local empty = newRound({ "U:1", "U:2" }, { roundId = "round-empty" })
		tick(empty, 1, hooks)
		tick(empty, 2, hooks)
		RoundStateMachine.removeParticipant(empty, "U:1", 2.1, nil)
		tick(empty, 2.1, hooks)
		expect(RoundStateMachine.addLateJoiner(empty, "L:4", 2.5).ok).toBe(true)
		expectState(empty, "L:4", InfectionGraph.State.HUMAN)
	end)

	it("plugs directly into BalanceConfig and MatchConfig.planRound", function()
		local plan = MatchConfig.planRound(BalanceConfig, 8)
		expect(plan == nil).toBe(false)
		local ids = { "U:1", "U:2", "U:3", "U:4", "U:5", "U:6", "U:7", "U:8" }
		local round = RoundStateMachine.new(BalanceConfig, plan, ids, "real-config", 0, constantRng(1), SLOTS)
		InfectionGraph.assertInvariants(round.graph)
		expect(round.plan.tier.roundSeconds).toBe(420)
		expect(round.plan.tier.cures).toBe(2)
		expect(round.plan.tier.requiredExtracted).toBe(2)
		expect(round.cures.shortfall).toBe(0)
		expect(round.phase).toBe(Phase.PREPARE)

		local _hookState, hooks = makeHooks()
		tick(round, 0, hooks)
		expect(round.phase).toBe(Phase.PREPARE)
		expect(round.phaseEndsAt).toBe(BalanceConfig.PrepareSeconds)
	end)

	it("a seeded randomised soak ends every round with exactly one verdict", function()
		local seed = 20261025
		local function nextRandom(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local function randomInt(count: number): number
			if count <= 0 then
				return 1
			end
			return math.floor(nextRandom() * count) + 1
		end

		local soakConfig = makeConfig({
			PrepareSeconds = 0.5,
			IncubationSeconds = 0.5,
			DisconnectSeconds = 2,
			CureChannelSeconds = 0.5,
			CureRetryCooldownSeconds = 0.25,
			ContainmentStableSeconds = 0.5,
			ExtractionWindowSeconds = 3,
			LateJoinHumanWindowSeconds = 1,
			Greybox = { CureRange = 8, RelinkRange = 8, ExtractHoldSeconds = 0.5 },
		})
		local soakPlan = makePlan({
			roundSeconds = 8,
			seedCount = 1,
			cures = 2,
			requiredExtracted = 1,
		})

		local accepted = 0
		local rejected = 0

		for roundIndex = 1, 200 do
			local ids = { "U:1", "U:2", "U:3", "U:4", "U:5", "U:6" }
			local round = newRound(ids, {
				config = soakConfig,
				plan = soakPlan,
				roundId = `soak-{roundIndex}`,
				rng = randomInt,
				slots = { "a", "b", "c" },
			})
			local hookState, hooks = makeHooks()
			local now = 0
			local verdicts = 0
			local lateSeq = 0
			local steps = 0

			while round.phase ~= Phase.RESULT and steps < 400 do
				steps += 1
				now += 0.25

				for _, id in InfectionGraph.participantIds(round.graph) do
					hookState.zone[id] = nextRandom() < 0.5
					hookState.dead[id] = nextRandom() < 0.1
					hookState.invalidRelink[id] = nextRandom() < 0.1
					hookState.positions[id] = `pos:{id}`
				end
				hookState.far = {}
				local participants = InfectionGraph.participantIds(round.graph)
				if #participants >= 2 and nextRandom() < 0.2 then
					hookState.far[`{participants[randomInt(#participants)]}|{participants[randomInt(#participants)]}`] =
						true
				end

				local action = nextRandom()
				if #participants > 0 then
					local candidate = participants[randomInt(#participants)]
					if action < 0.25 then
						local others = InfectionGraph.participantIds(round.graph)
						if #others >= 2 then
							local attacker = others[randomInt(#others)]
							local target = others[randomInt(#others)]
							local result = RoundStateMachine.onBite(round, attacker, target, now)
							if result.ok then
								accepted += 1
							else
								rejected += 1
							end
						end
					elseif action < 0.5 then
						if InfectionGraph.getState(round.graph, candidate).state == InfectionGraph.State.HUMAN then
							if CureInventory.heldBy(round.cures, candidate) == nil then
								for _, itemId in round.cures.order do
									local item = CureInventory.getItem(round.cures, itemId)
									if item.state == "SUPPLY" or item.state == "DROPPED" then
										CureInventory.pickup(round.cures, itemId, candidate)
										break
									end
								end
							end
							local targets = InfectionGraph.participantIds(round.graph)
							if #targets > 0 then
								local target = targets[randomInt(#targets)]
								local result = RoundStateMachine.requestCure(round, candidate, target, now)
								if result.ok then
									accepted += 1
								else
									rejected += 1
								end
							end
						end
					elseif action < 0.7 then
						if InfectionGraph.getState(round.graph, candidate).state == InfectionGraph.State.UNSTABLE then
							local targets = InfectionGraph.participantIds(round.graph)
							if #targets > 0 then
								local target = targets[randomInt(#targets)]
								local result = RoundStateMachine.requestRelink(round, candidate, target, now)
								if result.ok then
									accepted += 1
								else
									rejected += 1
								end
							end
						end
					elseif action < 0.82 then
						local result = RoundStateMachine.requestExtract(round, candidate, now)
						if result.ok then
							accepted += 1
						else
							rejected += 1
						end
					elseif action < 0.88 then
						local result = RoundStateMachine.removeParticipant(round, candidate, now, `pos:{candidate}`)
						if result.ok then
							accepted += 1
						else
							rejected += 1
						end
					else
						lateSeq += 1
						local result = RoundStateMachine.addLateJoiner(round, `L:{roundIndex}:{lateSeq}`, now)
						if result.ok then
							accepted += 1
						else
							rejected += 1
						end
					end
				end

				local events = tick(round, now, hooks).events
				verdicts += countType(events, EventName.RoundResult)
				InfectionGraph.assertInvariants(round.graph)
			end

			expect(round.phase).toBe(Phase.RESULT)
			expect(round.winner ~= nil).toBe(true)
			expect(verdicts).toBe(1)
			expect(#tick(round, now + 1, hooks).events).toBe(0)
		end

		expect(accepted > 0).toBe(true)
		expect(rejected > 0).toBe(true)
	end)
end)

TestKit.finish()
