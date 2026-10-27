--!strict
-- §17.2 / §17.6 公开事件字段白名单测试。
-- 跑一局脚本化回合（爆发 → 咬 → 治愈断链 → 重连 → 断联到期 → 撤离 → 人类胜），
-- 断言每一条 PUBLIC 事件：
--   1. 字段只出现在该事件的白名单里（type/scope/at 是元数据）；
--   2. 任何字段名都不含 episode / parent / child / descendant / ancestor / subtree / virtualRoot 等拓扑字样；
--   3. 事件名存在于 PublicEventTypes.Public（服务层不会广播未注册的公开事件）。
-- 这不能替代引擎层泄密审计（客户端 DebugAudit），但能防止纯逻辑新增公共事件时夹带秘密字段。

local TestKit = require("./TestKit")
local CureInventory = require("../../src/server/logic/CureInventory")
local InfectionGraph = require("../../src/server/logic/InfectionGraph")
local RoundStateMachine = require("../../src/server/logic/RoundStateMachine")
local PublicEventTypes = require("../../src/shared/PublicEventTypes")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

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

local PLAN: RoundStateMachine.Plan = {
	tier = {
		roundSeconds = 30,
		seedCount = 1,
		cures = 1,
		requiredExtracted = 1,
	},
}

local SLOTS = { "slot-1", "slot-2", "slot-3" }

local META_KEYS: { [string]: boolean } = {
	type = true,
	scope = true,
	at = true,
}

-- 每个公开事件允许出现的业务字段。新增公开字段必须同时更新这里和 PublicEventTypes。
local ALLOWED_KEYS: { [string]: { [string]: boolean } } = {
	RoundPhaseChanged = { phase = true },
	OutbreakStarted = { seedIds = true, count = true, participantIds = true },
	InfectionTurning = { participantId = true },
	InfectionRevealed = { participantId = true },
	ChainCutNearby = { count = true },
	ExtractionOpened = {},
	Extracted = { participantId = true },
	RoundResult = { winner = true, reason = true },
	-- §6.1：隔离突破预警只带即将进入的阶段名，不含任何拓扑。
	BreachWarning = { phase = true },
	-- §5.4：撤离目标可达性修正只带新阈值。
	ExtractionTargetAdjusted = { requiredExtracted = true },
}

local FORBIDDEN_KEY_PARTS = {
	"episode",
	"parent",
	"child",
	"descend",
	"ancestor",
	"subtree",
	"virtualroot",
	"rootseed",
}

local function makeHooks(): RoundStateMachine.Hooks
	local zone: { [string]: boolean } = {}
	return {
		canCureTarget = function(): boolean
			return true
		end,
		inRange = function(): boolean
			return true
		end,
		isInExtractionZone = function(id: string): boolean
			return zone[id] == true
		end,
		canBeRelinkTarget = function(): boolean
			return true
		end,
		positionOf = function(): unknown
			return nil
		end,
	}
end

local function collectInto(log: { RoundStateMachine.RoundEvent }, events: { RoundStateMachine.RoundEvent })
	for _, event in events do
		table.insert(log, event)
	end
end

local function runScriptedRound(): { RoundStateMachine.RoundEvent }
	local ids = { "U:1", "U:2", "U:3", "U:4", "U:5" }
	local round = RoundStateMachine.new(BASE_CONFIG, PLAN, ids, "allowlist-round", 0, function(): number
		return 1
	end, SLOTS)
	local hooks = makeHooks()
	local log: { RoundStateMachine.RoundEvent } = {}

	local function tickAt(now: number)
		collectInto(log, RoundStateMachine.tick(round, now, hooks).events)
	end

	tickAt(0)
	tickAt(1)
	tickAt(2)
	collectInto(log, RoundStateMachine.onBite(round, "U:1", "U:2", 2.5).events)
	tickAt(3.5)
	collectInto(log, RoundStateMachine.onBite(round, "U:2", "U:3", 4).events)
	collectInto(log, RoundStateMachine.onBite(round, "U:2", "U:4", 4.5).events)
	tickAt(5)
	tickAt(5.5)

	CureInventory.pickup(round.cures, "C:1", "U:5")
	collectInto(log, RoundStateMachine.requestCure(round, "U:5", "U:2", 6).events)
	tickAt(7)
	collectInto(log, RoundStateMachine.requestRelink(round, "U:3", "U:1", 7).events)
	tickAt(7.75)
	tickAt(15)

	-- 把撤离区的 hook 状态打开后推进到 EXTRACTION 并完成撤离。
	local zoneHooks = hooks
	zoneHooks.isInExtractionZone = function(id: string): boolean
		return id == "U:5"
	end
	collectInto(log, RoundStateMachine.tick(round, 20, zoneHooks).events)
	collectInto(log, RoundStateMachine.tick(round, 21, zoneHooks).events)

	InfectionGraph.assertInvariants(round.graph)
	return log
end

describe("公开事件字段白名单（§17.2、§17.6）", function()
	it("脚本回合覆盖全部公开事件，且每个字段都在白名单内", function()
		local log = runScriptedRound()
		local seenPublic: { [string]: number } = {}

		for _, event in log do
			if event.scope == RoundStateMachine.Scope.PUBLIC then
				seenPublic[event.type] = (seenPublic[event.type] or 0) + 1

				local allowed = ALLOWED_KEYS[event.type]
				if allowed == nil then
					error(`公开事件 {event.type} 没有字段白名单`, 2)
				end
				local registry = PublicEventTypes.Public
				expect(registry[event.type] ~= nil).toBe(true)

				local fields = event :: any
				for key, _value in fields do
					local keyName = tostring(key)
					if META_KEYS[keyName] ~= true then
						expect(allowed[keyName] == true).toBe(true)
						local lowered = string.lower(keyName)
						for _, forbidden in FORBIDDEN_KEY_PARTS do
							expect(string.find(lowered, forbidden, 1, true)).toBeNil()
						end
					end
				end
			end
		end

		for _, eventType in
			{
				"OutbreakStarted",
				"InfectionTurning",
				"InfectionRevealed",
				"ChainCutNearby",
				"ExtractionOpened",
				"Extracted",
				"RoundPhaseChanged",
				"RoundResult",
			}
		do
			expect(seenPublic[eventType] ~= nil).toBe(true)
		end
	end)

	it("公开事件不携带 actorId / targetId（这些只属于私有结算）", function()
		local log = runScriptedRound()
		for _, event in log do
			if event.scope == RoundStateMachine.Scope.PUBLIC then
				local fields = event :: any
				expect(fields.actorId).toBeNil()
				expect(fields.targetId).toBeNil()
				expect(fields.episodeId).toBeNil()
				expect(fields.parentEpisodeId).toBeNil()
				expect(fields.unstableEndsAt).toBeNil()
			end
		end
	end)
end)

TestKit.finish()
