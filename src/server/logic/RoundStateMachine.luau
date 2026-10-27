--!strict
-- Gate A-2a 正式局回合计时驱动（GDB V1.1 §4.1、§5.1–§5.2、§6.1、§7.3、§10、§11、§13.2–§13.3、§19.1、§21.2）。
--
-- 本模块拥有：一个 InfectionGraph、一个 ChannelTimer 状态、本局 CureInventory、
-- 撤离读条进度、阶段计时与唯一的胜负判定。它只做纯逻辑编排，所有世界信息通过 hooks 注入：
--   canCureTarget(targetId)  —— 服务端战斗生命状态（ACTIVE / DOWNED 可为目标，DEAD 不行）；
--   inRange(a, b, range)     —— 服务端距离校验；
--   isInExtractionZone(id)   —— 服务端撤离区判定；
--   canBeRelinkTarget(id)    —— 目标稳定、战斗状态允许；
--   positionOf(id)（可选）   —— 掉落解药时的世界位置。
--
-- 阶段：PREPARE（PrepareSeconds）→ 用注入 RNG 从 HUMAN 中公开选出 tier.seedCount 名零号并 createRoot
-- （优先上一局未当过零号者）→ OUTBREAK（所有零号完成公开尸变）→ CONTEST
-- → 剩余时间 ≤ ExtractionWindowSeconds 时 EXTRACTION → WinEvaluator 给出唯一判定后 RESULT。
-- §6.1 失败处理：零号在尸变过渡中离场时，每个原始槽位可用注入 RNG 补选一次；
-- 补选也离场或已无人类可选时，本局以 HUMANS / OUTBREAK_FAILED 结束并发私有 Anomaly 事件。
--
-- Gate A 简化（Gate B 补电力节点）：没有电力继电器、没有扫描；EXTRACTION 开始时出口直接开启。
-- 任何图变更都只通过 InfectionGraph 的公开 API 完成；公共事件绝不携带父子拓扑。
-- 读条全部服务端计时（§21.2）：客户端只发意图，完成以本模块累计的有效时间为准。

local InfectionGraph = require("./InfectionGraph")
local ChannelTimer = require("./ChannelTimer")
local CureInventory = require("./CureInventory")
local WinEvaluator = require("./WinEvaluator")
local MatchConfig = require("./MatchConfig")

-- 只声明本模块用到的字段；BalanceConfig / MatchConfig.RoundPlan 在结构上满足它们。
export type Config = {
	PrepareSeconds: number,
	IncubationSeconds: number,
	DisconnectSeconds: number,
	CuredImmunitySeconds: number,
	ReconnectHoldSeconds: number,
	RootRelinkHoldMultiplier: number,
	CureChannelSeconds: number,
	CureRetryCooldownSeconds: number,
	ContainmentStableSeconds: number,
	ExtractionWindowSeconds: number,
	LateJoinHumanWindowSeconds: number,
	Greybox: {
		CureRange: number,
		RelinkRange: number,
		ExtractHoldSeconds: number,
	},
}

export type Tier = {
	roundSeconds: number,
	seedCount: number,
	cures: number,
	requiredExtracted: number,
}

export type Plan = {
	tier: Tier,
}

export type Rng = (count: number) -> number

export type SeedSlotStatus = "TURNING" | "STABLE"

-- 一个零号槽位：初始选中的零号 + 至多一次替补。
-- TURNING 表示仍在公开尸变过渡；STABLE 表示已完成尸变（不再参与补选）。
export type SeedSlot = {
	slotIndex: number,
	seedId: string,
	participantId: string,
	replacementUsed: boolean,
	status: SeedSlotStatus,
}

export type Phase = "PREPARE" | "OUTBREAK" | "CONTEST" | "EXTRACTION" | "RESULT"

export type Winner = "HUMANS" | "INFECTED"

export type EventScope = "PUBLIC" | "PRIVATE"

export type RoundEvent = {
	type: string,
	scope: EventScope,
	at: number,
	participantId: string?,
	actorId: string?,
	targetId: string?,
	count: number?,
	affectedInfected: number?,
	affectedIncubating: number?,
	unstableEndsAt: number?,
	phase: string?,
	winner: string?,
	reason: string?,
	channelKind: string?,
	elapsed: number?,
	duration: number?,
	ratio: number?,
	seedIds: { string }?,
	kind: string?,
	requiredExtracted: number?,
	incubationEndsAt: number?,
}

export type TickResult = {
	events: { RoundEvent },
}

export type CommandResult = {
	ok: boolean,
	reason: string?,
	events: { RoundEvent },
}

export type Hooks = {
	canCureTarget: (targetId: string) -> boolean,
	inRange: (a: string, b: string, range: number) -> boolean,
	isInExtractionZone: (id: string) -> boolean,
	canBeRelinkTarget: (id: string) -> boolean,
	positionOf: ((id: string) -> unknown)?,
	-- §9A.3：断联丧尸倒地/死亡期间不能重连；每个 tick 校验，不再是 ACTIVE 立即取消。
	canRelinkActor: ((actorId: string) -> boolean)?,
	-- §13.2：被擒抱中的人类不能进行撤离读条（“无感染打断”的镜像约束）。
	isGrabbed: ((actorId: string) -> boolean)?,
}

type CureMeta = {
	itemId: string,
	targetId: string,
	expectedEpisodeId: string,
}

type RelinkMeta = {
	targetId: string,
	expectedEpisodeId: string,
}

export type Round = {
	roundId: string,
	config: Config,
	plan: Plan,
	graph: InfectionGraph.Graph,
	channels: ChannelTimer.State,
	cures: CureInventory.Inventory,
	phase: Phase,
	startedAt: number,
	now: number,
	phaseEndsAt: number?,
	roundEndsAt: number,
	-- 撤离进度与图状态分开保存：已撤离玩家离场后仍保留本局撤离计数（§19.1）。
	extracted: { [string]: boolean },
	extractedCount: number,
	containedSince: number?,
	winner: Winner?,
	verdictReason: string?,
	rng: Rng,
	cureMeta: { [string]: CureMeta },
	relinkMeta: { [string]: RelinkMeta },
	unstableNotified: { [string]: number },
	seedSlots: { SeedSlot },
	previousSeeds: { [string]: boolean },
	-- §5.4：撤离目标可达性修正后的活目标；初始等于 plan.tier.requiredExtracted。
	requiredExtracted: number,
	-- 可达性修正每局最多执行一次。
	extractTargetAdjusted: boolean,
	-- §6.1：PREPARE 结束前 3 秒的隔离突破预警只广播一次。
	breachWarned: boolean,
}

local RoundStateMachine = {}

local PHASE_PREPARE: Phase = "PREPARE"
local PHASE_OUTBREAK: Phase = "OUTBREAK"
local PHASE_CONTEST: Phase = "CONTEST"
local PHASE_EXTRACTION: Phase = "EXTRACTION"
local PHASE_RESULT: Phase = "RESULT"

local Phase = table.freeze({
	PREPARE = PHASE_PREPARE,
	OUTBREAK = PHASE_OUTBREAK,
	CONTEST = PHASE_CONTEST,
	EXTRACTION = PHASE_EXTRACTION,
	RESULT = PHASE_RESULT,
})
RoundStateMachine.Phase = Phase

local SCOPE_PUBLIC: EventScope = "PUBLIC"
local SCOPE_PRIVATE: EventScope = "PRIVATE"

local Scope = table.freeze({
	PUBLIC = SCOPE_PUBLIC,
	PRIVATE = SCOPE_PRIVATE,
})
RoundStateMachine.Scope = Scope

-- 事件名与 PublicEventTypes.Public / Private 对齐；纯逻辑模块不跨 Rojo 树 require 共享枚举。
local EventName = table.freeze({
	InfectionTurning = "InfectionTurning",
	InfectionRevealed = "InfectionRevealed",
	OutbreakStarted = "OutbreakStarted",
	ChainCutNearby = "ChainCutNearby",
	ExtractionOpened = "ExtractionOpened",
	Extracted = "Extracted",
	RoundPhaseChanged = "RoundPhaseChanged",
	RoundResult = "RoundResult",
	YouAreUnstable = "YouAreUnstable",
	CureChannelProgress = "CureChannelProgress",
	ChannelCancelled = "ChannelCancelled",
	RelinkSucceeded = "RelinkSucceeded",
	Cured = "Cured",
	Anomaly = "Anomaly",
	BreachWarning = "BreachWarning",
	ExtractionTargetAdjusted = "ExtractionTargetAdjusted",
	YouAreIncubating = "YouAreIncubating",
	YouAreSource = "YouAreSource",
})
RoundStateMachine.EventName = EventName

local Reason = table.freeze({
	RoundOver = "ROUND_OVER",
	PhaseNotActive = "PHASE_NOT_ACTIVE",
	UnknownParticipant = "UNKNOWN_PARTICIPANT",
	UnknownTarget = "UNKNOWN_TARGET",
	NotHuman = "NOT_HUMAN",
	NoCure = "NO_CURE",
	CureCooldown = "CURE_COOLDOWN",
	TargetNotInfected = "TARGET_NOT_INFECTED",
	RootImmune = "ROOT_IMMUNE",
	NotUnstable = "NOT_UNSTABLE",
	TargetChanged = "TARGET_CHANGED",
	ActorChanged = "ACTOR_CHANGED",
	TargetInvalid = "TARGET_INVALID",
	OutOfRange = "OUT_OF_RANGE",
	Replaced = "REPLACED",
	Bitten = "BITTEN",
	Left = "LEFT",
	Cancelled = "CANCELLED",
	Invalid = "INVALID",
	OutbreakFailed = "OUTBREAK_FAILED",
})
RoundStateMachine.Reason = Reason

local WINNER_HUMANS: Winner = "HUMANS"

local SEED_TURNING: SeedSlotStatus = "TURNING"
local SEED_STABLE: SeedSlotStatus = "STABLE"

local KIND_CURE: ChannelTimer.ChannelKind = "CURE"
local KIND_RELINK: ChannelTimer.ChannelKind = "RELINK"
local KIND_EXTRACT: ChannelTimer.ChannelKind = "EXTRACT"

local function newEvent(eventType: string, scope: EventScope, at: number): RoundEvent
	return { type = eventType, scope = scope, at = at }
end

local function rejected(reason: string): CommandResult
	return { ok = false, reason = reason, events = {} }
end

local function currentTime(round: Round, now: number): number
	if now > round.now then
		return now
	end
	return round.now
end

local function stateOf(round: Round, participantId: string): InfectionGraph.Participant?
	return InfectionGraph.getState(round.graph, participantId)
end

local function participantList(round: Round): { string }
	return InfectionGraph.participantIds(round.graph)
end

local function setPhase(round: Round, phase: Phase, at: number, events: { RoundEvent })
	round.phase = phase
	round.phaseEndsAt = nil
	local event = newEvent(EventName.RoundPhaseChanged, SCOPE_PUBLIC, at)
	event.phase = phase
	table.insert(events, event)
end

local function positionOf(hooks: Hooks, participantId: string): unknown
	local getter = hooks.positionOf
	if getter == nil then
		return nil
	end
	return getter(participantId)
end

local function dropCure(round: Round, participantId: string, hooks: Hooks)
	if CureInventory.heldBy(round.cures, participantId) == nil then
		return
	end
	CureInventory.drop(round.cures, participantId, positionOf(hooks, participantId))
end

local function emitCancellation(events: { RoundEvent }, channel: ChannelTimer.Channel, reason: string, at: number)
	local event = newEvent(EventName.ChannelCancelled, SCOPE_PRIVATE, at)
	event.participantId = channel.actorId
	event.actorId = channel.actorId
	event.targetId = channel.targetId
	event.channelKind = channel.kind
	event.reason = reason
	table.insert(events, event)
end

-- 读条取消统一处理：清除元数据，治愈读条进入短冷却（§10.1），并发出私有 ChannelCancelled。
local function handleCancelled(round: Round, cancelled: { ChannelTimer.Cancelled }, at: number, events: { RoundEvent })
	for _, item in cancelled do
		local channel = item.channel
		if channel.kind == KIND_CURE then
			round.cureMeta[channel.actorId] = nil
			CureInventory.onFailedAttempt(round.cures, channel.actorId, at)
		elseif channel.kind == KIND_RELINK then
			round.relinkMeta[channel.actorId] = nil
		end
		emitCancellation(events, channel, item.reason, at)
	end
end

local function startChannel(
	round: Round,
	actorId: string,
	kind: ChannelTimer.ChannelKind,
	targetId: string?,
	at: number,
	duration: number,
	events: { RoundEvent }
): boolean
	local ok, _reason, replaced = ChannelTimer.start(round.channels, actorId, kind, targetId, at, duration)
	if not ok then
		return false
	end
	if replaced ~= nil then
		handleCancelled(round, { { channel = replaced, reason = Reason.Replaced } }, at, events)
	end
	return true
end

-- §6.1：零号候选必须排除处于治愈保护期的参与者（受保护者不应被选为零号）。
local function humanCandidates(round: Round, now: number): { string }
	local candidates: { string } = {}
	for _, id in participantList(round) do
		local participant = InfectionGraph.getState(round.graph, id)
		local immuneUntil = if participant ~= nil then participant.curedImmuneUntil else nil
		if
			participant ~= nil
			and participant.state == InfectionGraph.State.HUMAN
			and not (immuneUntil ~= nil and immuneUntil > now)
		then
			table.insert(candidates, id)
		end
	end
	return candidates
end

-- 从候选里抽一个：优先非“上一局零号”，只有在没有非上一局候选时才回退到全集（§6.1）。
-- 返回 (participantId, 候选数组下标)；没有候选时返回 (nil, nil)。
local function pickCandidate(candidates: { string }, previousSeeds: { [string]: boolean }, rng: Rng): (string?, number?)
	local preferred: { number } = {}
	local all: { number } = {}
	for index, id in candidates do
		table.insert(all, index)
		if previousSeeds[id] ~= true then
			table.insert(preferred, index)
		end
	end

	local pool = if #preferred > 0 then preferred else all
	if #pool == 0 then
		return nil, nil
	end
	local pick = rng(#pool)
	if pick ~= pick or pick % 1 ~= 0 or pick < 1 or pick > #pool then
		pick = 1
	end
	local candidateIndex = pool[pick]
	return candidates[candidateIndex], candidateIndex
end

-- §6.1 / §7.3：公开选出零号时给本人发私有提示。
-- YouAreSource 告知“你是源头”，YouAreIncubating 附带尸变倒计时截止时刻。
local function emitOutbreakStarted(round: Round, events: { RoundEvent }, at: number, seedIds: { string })
	local started = newEvent(EventName.OutbreakStarted, SCOPE_PUBLIC, at)
	started.count = #seedIds
	started.seedIds = seedIds
	table.insert(events, started)
	for _, id in seedIds do
		local turning = newEvent(EventName.InfectionTurning, SCOPE_PUBLIC, at)
		turning.participantId = id
		table.insert(events, turning)

		local participant = InfectionGraph.getState(round.graph, id)
		local source = newEvent(EventName.YouAreSource, SCOPE_PRIVATE, at)
		source.participantId = id
		table.insert(events, source)

		local incubating = newEvent(EventName.YouAreIncubating, SCOPE_PRIVATE, at)
		incubating.participantId = id
		incubating.incubationEndsAt = if participant ~= nil then participant.incubationEndsAt else nil
		table.insert(events, incubating)
	end
end

-- PREPARE 结束时公开选零号（§6.1）。零号先进入公开尸变过渡（INCUBATING），不是立即丧尸。
-- 返回 true 表示“应该有零号却一个也建不出来”，由 tick 以 OUTBREAK_FAILED 收尾。
local function pickSeeds(round: Round, at: number, events: { RoundEvent }): boolean
	local candidates = humanCandidates(round, at)
	local wanted = math.max(0, math.floor(round.plan.tier.seedCount))
	local picked: { string } = {}

	for slotIndex = 1, math.min(wanted, #candidates) do
		local id, candidatesIndex = pickCandidate(candidates, round.previousSeeds, round.rng)
		if id == nil or candidatesIndex == nil then
			break
		end
		table.remove(candidates, candidatesIndex)
		local seedId = `seed-{slotIndex}`
		local result = InfectionGraph.createRoot(round.graph, seedId, id, at, { roundId = round.roundId })
		if result.ok then
			table.insert(round.seedSlots, {
				slotIndex = slotIndex,
				seedId = seedId,
				participantId = id,
				replacementUsed = false,
				status = SEED_TURNING,
			})
			table.insert(picked, id)
		end
	end

	if #picked > 0 then
		emitOutbreakStarted(round, events, at, picked)
	end
	return wanted > 0 and #picked == 0
end

local function startOutbreak(round: Round, at: number, events: { RoundEvent }): boolean
	if round.phase ~= PHASE_PREPARE then
		return false
	end
	local phaseEndsAt = round.phaseEndsAt
	if phaseEndsAt == nil or at < phaseEndsAt then
		return false
	end
	setPhase(round, PHASE_OUTBREAK, at, events)
	return pickSeeds(round, at, events)
end

-- 某个零号槽位的零号在尸变过渡中离场：用同一槽位补选一名仍为 HUMAN 的参与者（§6.1）。
-- 每个原始槽位只允许一次补选；补选也离场时由调用方以 OUTBREAK_FAILED 收尾。
local function reselectSlot(round: Round, slot: SeedSlot, at: number, events: { RoundEvent }): boolean
	local candidates = humanCandidates(round, at)
	local id = pickCandidate(candidates, round.previousSeeds, round.rng)
	if id == nil then
		return false
	end

	local seedId = `seed-{slot.slotIndex}-r1`
	local result = InfectionGraph.createRoot(round.graph, seedId, id, at, { roundId = round.roundId })
	if not result.ok then
		return false
	end

	slot.seedId = seedId
	slot.participantId = id
	slot.replacementUsed = true
	slot.status = SEED_TURNING
	emitOutbreakStarted(round, events, at, { id })
	return true
end

-- OUTBREAK 期间维护零号槽位：已公开的槽位标记 STABLE；离场的槽位补选一次。
-- 补选失败时若已另有零号完成公开尸变（爆发实际已经发生），只丢弃该槽位而不判 OUTBREAK_FAILED；
-- 全部槽位都无法维持爆发才返回 true，由 tick 以 OUTBREAK_FAILED 结束本局。
local function serviceSeedSlots(round: Round, at: number, events: { RoundEvent }): boolean
	if round.phase ~= PHASE_OUTBREAK then
		return false
	end

	local failed: { number } = {}
	for index, slot in round.seedSlots do
		if slot.status == SEED_TURNING then
			local participant = InfectionGraph.getState(round.graph, slot.participantId)
			local alive = participant ~= nil and participant.isRoot and participant.seedId == slot.seedId
			if participant ~= nil and alive and participant.state == InfectionGraph.State.INFECTED then
				slot.status = SEED_STABLE
			elseif
				(participant == nil or not alive or participant.state ~= InfectionGraph.State.INCUBATING)
				-- §6.1：每个槽位只重新选择一次。
				and (slot.replacementUsed or not reselectSlot(round, slot, at, events))
			then
				table.insert(failed, index)
			end
		end
	end

	if #failed == 0 then
		return false
	end

	-- 爆发已经发生（至少一个槽位的零号稳定感染）：丢弃失败槽位，回合继续。
	local anyStable = false
	for _, slot in round.seedSlots do
		if slot.status == SEED_STABLE then
			anyStable = true
			break
		end
	end
	if anyStable then
		for index = #failed, 1, -1 do
			table.remove(round.seedSlots, failed[index])
		end
		return false
	end
	return true
end

-- 阶段推进：OUTBREAK 在所有零号完成公开尸变后进入 CONTEST；
-- CONTEST 在剩余时间 ≤ ExtractionWindowSeconds 时开启撤离（Gate A 直接开门）。
local function advancePhases(round: Round, at: number, events: { RoundEvent })
	if round.phase == PHASE_OUTBREAK then
		local publicCounts = InfectionGraph.publicCounts(round.graph)
		if publicCounts.incubating == 0 then
			setPhase(round, PHASE_CONTEST, at, events)
		end
	end

	if round.phase == PHASE_CONTEST and at >= round.roundEndsAt - round.config.ExtractionWindowSeconds then
		setPhase(round, PHASE_EXTRACTION, at, events)
		table.insert(events, newEvent(EventName.ExtractionOpened, SCOPE_PUBLIC, at))
	end
end

-- 图 tick 后的公开揭示：INCUBATING → INFECTED 公开，并处理持有者解药掉落（§10.1）。
local function applyReveals(round: Round, at: number, hooks: Hooks, events: { RoundEvent })
	local result = InfectionGraph.tick(round.graph, at, { roundId = round.roundId })
	if not result.ok then
		return
	end
	local graphEvents = result.events
	if #graphEvents == 0 then
		return
	end
	local tickEvent = graphEvents[1]
	local revealed = tickEvent.revealedIds
	if revealed == nil then
		return
	end
	for _, id in revealed do
		local event = newEvent(EventName.InfectionRevealed, SCOPE_PUBLIC, at)
		event.participantId = id
		table.insert(events, event)
		dropCure(round, id, hooks)
	end
end

local function commitCure(round: Round, channel: ChannelTimer.Channel, at: number, hooks: Hooks, events: { RoundEvent })
	local meta = round.cureMeta[channel.actorId]
	round.cureMeta[channel.actorId] = nil

	local function fail(reason: string, cooldown: boolean)
		if cooldown then
			CureInventory.onFailedAttempt(round.cures, channel.actorId, at)
		end
		emitCancellation(events, channel, reason, at)
	end

	if meta == nil then
		fail(Reason.Invalid, true)
		return
	end
	if CureInventory.heldBy(round.cures, channel.actorId) ~= meta.itemId then
		fail(Reason.NoCure, true)
		return
	end

	local actor = InfectionGraph.getState(round.graph, channel.actorId)
	if actor == nil or actor.state ~= InfectionGraph.State.HUMAN then
		fail(Reason.ActorChanged, true)
		return
	end

	local target = InfectionGraph.getState(round.graph, meta.targetId)
	if target == nil then
		fail(Reason.TargetChanged, true)
		return
	end
	if target.state ~= InfectionGraph.State.INFECTED or target.episodeId ~= meta.expectedEpisodeId then
		fail(Reason.TargetChanged, true)
		return
	end
	if target.isRoot then
		fail(Reason.RootImmune, false)
		return
	end
	if not hooks.canCureTarget(meta.targetId) then
		fail(Reason.TargetInvalid, true)
		return
	end
	if not hooks.inRange(channel.actorId, meta.targetId, round.config.Greybox.CureRange) then
		fail(Reason.OutOfRange, true)
		return
	end

	local result = InfectionGraph.cure(round.graph, channel.actorId, meta.targetId, at, {
		roundId = round.roundId,
		expectedEpisodeId = meta.expectedEpisodeId,
	})
	if not result.ok then
		fail(result.reason or Reason.Invalid, result.reason ~= InfectionGraph.Reason.RootImmune)
		return
	end

	CureInventory.consume(round.cures, channel.actorId)

	-- 私有结算给施放者与目标；公开侧只发“附近有链断裂 + 受影响人数”，不含任何拓扑。
	local cured = newEvent(EventName.Cured, SCOPE_PRIVATE, at)
	cured.participantId = meta.targetId
	cured.actorId = channel.actorId
	cured.targetId = meta.targetId
	cured.affectedInfected = result.affectedInfected or 0
	cured.affectedIncubating = result.affectedIncubating or 0
	table.insert(events, cured)

	local cut = newEvent(EventName.ChainCutNearby, SCOPE_PUBLIC, at)
	cut.count = result.affectedInfected or 0
	table.insert(events, cut)
end

local function commitRelink(
	round: Round,
	channel: ChannelTimer.Channel,
	at: number,
	_hooks: Hooks,
	events: { RoundEvent }
)
	local meta = round.relinkMeta[channel.actorId]
	round.relinkMeta[channel.actorId] = nil

	local function fail(reason: string)
		emitCancellation(events, channel, reason, at)
	end

	if meta == nil then
		fail(Reason.Invalid)
		return
	end
	local unstable = InfectionGraph.getState(round.graph, channel.actorId)
	if unstable == nil or unstable.state ~= InfectionGraph.State.UNSTABLE then
		fail(Reason.TargetChanged)
		return
	end
	if unstable.episodeId ~= meta.expectedEpisodeId then
		fail(Reason.TargetChanged)
		return
	end
	local unstableEndsAtBefore = unstable.unstableEndsAt

	local result = InfectionGraph.relink(round.graph, channel.actorId, meta.targetId, at, {
		roundId = round.roundId,
		expectedEpisodeId = meta.expectedEpisodeId,
	})
	if not result.ok then
		fail(result.reason or Reason.Invalid)
		return
	end

	local event = newEvent(EventName.RelinkSucceeded, SCOPE_PRIVATE, at)
	event.participantId = channel.actorId
	event.actorId = channel.actorId
	event.targetId = meta.targetId
	event.count = result.affectedInfected or 0
	-- §22.2：relink_committed 的 secondsLeft 是断联窗口剩余，不是回合剩余；
	-- 携带原截止时间供服务层换算（relink 后字段已被清空）。
	event.unstableEndsAt = unstableEndsAtBefore
	table.insert(events, event)
end

-- 前向声明：settleDueRelinks 需要在 ChannelTimer.tick 之前复用逐 tick 校验。
local buildValidity: (round: Round, hooks: Hooks) -> (ChannelTimer.Channel) -> (boolean, string?)

-- §11.4 同 tick 竞态：断联截止时间 <= 本 tick 且重连读条同时到期时，重连优先于过期结算。
-- 在图 tick（过期处理）之前先把“本 tick 将累计满”的 RELINK 读条提交掉：
-- 提交后断联者立即恢复 INFECTED，随后的过期扫描自然看不到他们。
-- 有效性走与逐 tick 校验同一条 buildValidity；无效读条留给正常 ChannelTimer.tick 取消。
local function settleDueRelinks(round: Round, at: number, hooks: Hooks, events: { RoundEvent })
	local due: { ChannelTimer.Channel } = {}
	for _, channel in ChannelTimer.active(round.channels) do
		if channel.kind == KIND_RELINK then
			local projected = channel.accumulated + math.max(0, at - channel.lastCheckedAt)
			if projected >= channel.duration then
				table.insert(due, channel)
			end
		end
	end
	if #due == 0 then
		return
	end

	local isValid = buildValidity(round, hooks)
	for _, channel in due do
		local valid = isValid(channel)
		if valid then
			local removed = ChannelTimer.cancel(round.channels, channel.actorId, "COMPLETED")
			if removed ~= nil then
				commitRelink(round, removed, at, hooks, events)
			end
		end
	end
end

local function commitExtract(round: Round, channel: ChannelTimer.Channel, at: number, events: { RoundEvent })
	local actor = InfectionGraph.getState(round.graph, channel.actorId)
	if actor == nil or actor.state ~= InfectionGraph.State.HUMAN then
		emitCancellation(events, channel, Reason.ActorChanged, at)
		return
	end
	local result = InfectionGraph.markExtracted(round.graph, channel.actorId, { roundId = round.roundId })
	if not result.ok then
		emitCancellation(events, channel, result.reason or Reason.Invalid, at)
		return
	end

	if not round.extracted[channel.actorId] then
		round.extracted[channel.actorId] = true
		round.extractedCount += 1
	end
	local event = newEvent(EventName.Extracted, SCOPE_PUBLIC, at)
	event.participantId = channel.actorId
	table.insert(events, event)
end

local function handleCompleted(
	round: Round,
	completed: { ChannelTimer.Channel },
	at: number,
	hooks: Hooks,
	events: { RoundEvent }
)
	for _, channel in completed do
		if channel.kind == KIND_CURE then
			commitCure(round, channel, at, hooks, events)
		elseif channel.kind == KIND_RELINK then
			commitRelink(round, channel, at, hooks, events)
		elseif channel.kind == KIND_EXTRACT then
			commitExtract(round, channel, at, events)
		end
	end
end

-- 每 tick 的服务端校验。读条元数据里保存开始时的 episode，任何身份漂移都按 TARGET_CHANGED 取消（§11.4）。
function buildValidity(round: Round, hooks: Hooks): (ChannelTimer.Channel) -> (boolean, string?)
	return function(channel: ChannelTimer.Channel): (boolean, string?)
		if round.phase == PHASE_RESULT then
			return false, Reason.RoundOver
		end

		if channel.kind == KIND_CURE then
			local meta = round.cureMeta[channel.actorId]
			if meta == nil then
				return false, Reason.Invalid
			end
			local actor = InfectionGraph.getState(round.graph, channel.actorId)
			if actor == nil or actor.state ~= InfectionGraph.State.HUMAN then
				return false, Reason.ActorChanged
			end
			if CureInventory.heldBy(round.cures, channel.actorId) ~= meta.itemId then
				return false, Reason.NoCure
			end
			local target = InfectionGraph.getState(round.graph, meta.targetId)
			if target == nil or target.state ~= InfectionGraph.State.INFECTED then
				return false, Reason.TargetChanged
			end
			if target.episodeId ~= meta.expectedEpisodeId then
				return false, Reason.TargetChanged
			end
			if target.isRoot then
				return false, Reason.RootImmune
			end
			if not hooks.canCureTarget(meta.targetId) then
				return false, Reason.TargetInvalid
			end
			if not hooks.inRange(channel.actorId, meta.targetId, round.config.Greybox.CureRange) then
				return false, Reason.OutOfRange
			end
			return true, nil
		elseif channel.kind == KIND_RELINK then
			local meta = round.relinkMeta[channel.actorId]
			if meta == nil then
				return false, Reason.Invalid
			end
			local unstable = InfectionGraph.getState(round.graph, channel.actorId)
			if unstable == nil or unstable.state ~= InfectionGraph.State.UNSTABLE then
				return false, Reason.TargetChanged
			end
			if unstable.episodeId ~= meta.expectedEpisodeId then
				return false, Reason.TargetChanged
			end
			local target = InfectionGraph.getState(round.graph, meta.targetId)
			if target == nil or target.state ~= InfectionGraph.State.INFECTED then
				return false, Reason.TargetChanged
			end
			if not hooks.canBeRelinkTarget(meta.targetId) then
				return false, Reason.TargetInvalid
			end
			-- §9A.3：断联丧尸倒地/死亡期间不能重连；不再 ACTIVE 立即取消。
			local canRelink = hooks.canRelinkActor
			if canRelink ~= nil and not canRelink(channel.actorId) then
				return false, "NOT_ACTIVE"
			end
			if not hooks.inRange(channel.actorId, meta.targetId, round.config.Greybox.RelinkRange) then
				return false, Reason.OutOfRange
			end
			return true, nil
		elseif channel.kind == KIND_EXTRACT then
			if round.phase ~= PHASE_EXTRACTION then
				return false, Reason.PhaseNotActive
			end
			local actor = InfectionGraph.getState(round.graph, channel.actorId)
			if actor == nil or actor.state ~= InfectionGraph.State.HUMAN then
				return false, Reason.ActorChanged
			end
			-- §13.2：被擒抱中的人类不能撤离（与“无感染打断”一致）。
			local isGrabbed = hooks.isGrabbed
			if isGrabbed ~= nil and isGrabbed(channel.actorId) then
				return false, "GRABBED"
			end
			if not hooks.isInExtractionZone(channel.actorId) then
				return false, Reason.OutOfRange
			end
			return true, nil
		end

		return false, Reason.Invalid
	end
end

-- EXTRACTION 期间，身处撤离区且没有其他读条的人类自动开始撤离读条（§13.2）。
-- 已在治疗/其他读条中的人不会因为踏入撤离区被打断；显式 requestExtract 才会替换。
local function autoStartExtraction(round: Round, at: number, hooks: Hooks)
	if round.phase ~= PHASE_EXTRACTION then
		return
	end
	local isGrabbed = hooks.isGrabbed
	for _, id in participantList(round) do
		local participant = InfectionGraph.getState(round.graph, id)
		if
			participant ~= nil
			and participant.state == InfectionGraph.State.HUMAN
			and hooks.isInExtractionZone(id)
			and ChannelTimer.get(round.channels, id) == nil
			and not (isGrabbed ~= nil and isGrabbed(id))
		then
			ChannelTimer.start(round.channels, id, KIND_EXTRACT, nil, at, round.config.Greybox.ExtractHoldSeconds)
		end
	end
end

-- 断联者的私有倒计时：同一截止时间只通知一次；状态离开 UNSTABLE 后重新武装。
local function emitUnstableNotices(round: Round, at: number, events: { RoundEvent })
	for _, id in participantList(round) do
		local participant = InfectionGraph.getState(round.graph, id)
		if participant ~= nil and participant.state == InfectionGraph.State.UNSTABLE then
			local deadline = participant.unstableEndsAt
			if deadline ~= nil and round.unstableNotified[id] ~= deadline then
				round.unstableNotified[id] = deadline
				local event = newEvent(EventName.YouAreUnstable, SCOPE_PRIVATE, at)
				event.participantId = id
				event.unstableEndsAt = deadline
				table.insert(events, event)
			end
		else
			round.unstableNotified[id] = nil
		end
	end
end

local function emitCureProgress(round: Round, at: number, events: { RoundEvent })
	for _, channel in ChannelTimer.active(round.channels) do
		if channel.kind == KIND_CURE then
			local progress = ChannelTimer.progress(round.channels, channel.actorId, at)
			if progress ~= nil then
				local event = newEvent(EventName.CureChannelProgress, SCOPE_PRIVATE, at)
				event.participantId = progress.actorId
				event.actorId = progress.actorId
				event.targetId = progress.targetId
				event.channelKind = progress.kind
				event.elapsed = progress.elapsed
				event.duration = progress.duration
				event.ratio = progress.ratio
				table.insert(events, event)
			end
		end
	end
end

local function finish(round: Round, winner: Winner, reason: string?, at: number, events: { RoundEvent })
	if round.phase == PHASE_RESULT then
		return
	end
	handleCancelled(round, ChannelTimer.cancelAll(round.channels, Reason.RoundOver), at, events)
	round.phase = PHASE_RESULT
	round.phaseEndsAt = nil
	round.winner = winner
	round.verdictReason = reason

	local phaseEvent = newEvent(EventName.RoundPhaseChanged, SCOPE_PUBLIC, at)
	phaseEvent.phase = PHASE_RESULT
	table.insert(events, phaseEvent)

	local resultEvent = newEvent(EventName.RoundResult, SCOPE_PUBLIC, at)
	resultEvent.winner = winner
	resultEvent.reason = reason
	table.insert(events, resultEvent)
end

-- §6.1 失败处理：零号槽位补选后仍无法维持爆发（替补也离场或已无可选人类）。
-- 本局按“感染未爆发，人类存活”的短局结果结束，并发出私有 Anomaly 供遥测。
local function finishOutbreakFailed(round: Round, at: number, events: { RoundEvent })
	local anomaly = newEvent(EventName.Anomaly, SCOPE_PRIVATE, at)
	anomaly.kind = Reason.OutbreakFailed
	table.insert(events, anomaly)
	finish(round, WINNER_HUMANS, Reason.OutbreakFailed, at, events)
end

local function lateJoinRoleFor(config: Config, elapsedSeconds: number, roundSeconds: number): MatchConfig.LateJoinRole
	-- MatchConfig.lateJoinRole 只读取两个窗口字段；其余字段对本规则无意义，填占位值以复用同一份实现。
	local tiers: { MatchConfig.Tier } = {}
	local adapter: MatchConfig.Config = {
		MaxPlayers = 0,
		MinPlayersRanked = 0,
		BotFillTarget = 0,
		LateJoinHumanWindowSeconds = config.LateJoinHumanWindowSeconds,
		ExtractionWindowSeconds = config.ExtractionWindowSeconds,
		HubMinImpact = 0,
		HubRelativeShare = 0,
		PlayerCountTiers = tiers,
	}
	return MatchConfig.lateJoinRole(adapter, elapsedSeconds, roundSeconds)
end

function RoundStateMachine.new(
	config: Config,
	plan: Plan,
	participantIds: { string },
	roundId: string,
	now: number,
	rng: Rng,
	cureSlots: { unknown }?,
	previousSeedIds: { string }?
): Round
	local graph = InfectionGraph.new(config, roundId, participantIds)
	local cures = CureInventory.new(config, plan.tier, cureSlots or {}, rng)
	local previousSeeds: { [string]: boolean } = {}
	if previousSeedIds ~= nil then
		for _, id in previousSeedIds do
			previousSeeds[id] = true
		end
	end
	return {
		roundId = roundId,
		config = config,
		plan = plan,
		graph = graph,
		channels = ChannelTimer.new(),
		cures = cures,
		phase = PHASE_PREPARE,
		startedAt = now,
		now = now,
		phaseEndsAt = now + config.PrepareSeconds,
		roundEndsAt = now + plan.tier.roundSeconds,
		extracted = {},
		extractedCount = 0,
		containedSince = nil,
		winner = nil,
		verdictReason = nil,
		rng = rng,
		cureMeta = {},
		relinkMeta = {},
		unstableNotified = {},
		seedSlots = {},
		previousSeeds = previousSeeds,
		requiredExtracted = plan.tier.requiredExtracted,
		extractTargetAdjusted = false,
		breachWarned = false,
	}
end

-- 推进服务器时间、图计时、阶段、读条、撤离与胜负。hooks 每个 tick 注入最新的世界状态。
function RoundStateMachine.tick(round: Round, now: number, hooks: Hooks): TickResult
	local events: { RoundEvent } = {}
	if round.phase == PHASE_RESULT then
		return { events = events }
	end

	local at = currentTime(round, now)
	round.now = at

	-- §6.1：PREPARE 结束前 3 秒广播一次“隔离突破”预警（公开，只带爆发开始时刻）。
	if round.phase == PHASE_PREPARE and not round.breachWarned then
		local phaseEndsAt = round.phaseEndsAt
		if phaseEndsAt ~= nil and at >= phaseEndsAt - 3 then
			round.breachWarned = true
			local warning = newEvent(EventName.BreachWarning, SCOPE_PUBLIC, at)
			warning.phase = PHASE_OUTBREAK
			table.insert(events, warning)
		end
	end

	local outbreakFailed = startOutbreak(round, at, events)
	if not outbreakFailed then
		-- §11.4：先提交本 tick 到期的重连，再做断联过期结算，同 tick 竞态由重连胜出。
		settleDueRelinks(round, at, hooks, events)
		applyReveals(round, at, hooks, events)
		outbreakFailed = serviceSeedSlots(round, at, events)
	end
	if outbreakFailed then
		finishOutbreakFailed(round, at, events)
		return { events = events }
	end

	-- PREPARE 期间还没有零号，“无感染者”是常态而不是遏制；不做读条与胜负判定，
	-- 否则遏制复核会在准备期内直接判人类胜。
	if round.phase == PHASE_PREPARE then
		round.containedSince = nil
		return { events = events }
	end

	advancePhases(round, at, events)
	autoStartExtraction(round, at, hooks)

	local channelResult = ChannelTimer.tick(round.channels, at, buildValidity(round, hooks))
	handleCancelled(round, channelResult.cancelled, at, events)
	handleCompleted(round, channelResult.completed, at, hooks, events)

	emitUnstableNotices(round, at, events)
	emitCureProgress(round, at, events)

	-- §5.4 撤离目标可达性修正：还能撤离的人数已不足以达成原目标时，把目标降到可达值。
	-- 每局最多执行一次；目标只降不升，且至少为 1。可撤离人数 = 仍在局内的人类、尸变中、断联
	-- 以及可被治愈的普通丧尸（零号不可治愈）。感染本身不减少这个数，只有离局会触发修正。
	if not round.extractTargetAdjusted then
		local remainingCapacity = 0
		for _, id in participantList(round) do
			local participant = InfectionGraph.getState(round.graph, id)
			if participant ~= nil then
				local state = participant.state
				if
					state == InfectionGraph.State.HUMAN
					or state == InfectionGraph.State.INCUBATING
					or state == InfectionGraph.State.UNSTABLE
					or (state == InfectionGraph.State.INFECTED and not participant.isRoot)
				then
					remainingCapacity += 1
				end
			end
		end
		if round.requiredExtracted - round.extractedCount > remainingCapacity then
			round.extractTargetAdjusted = true
			local adjusted =
				math.max(1, math.min(round.plan.tier.requiredExtracted, round.extractedCount + remainingCapacity))
			if adjusted < round.requiredExtracted then
				round.requiredExtracted = adjusted
				local event = newEvent(EventName.ExtractionTargetAdjusted, SCOPE_PUBLIC, at)
				event.requiredExtracted = adjusted
				table.insert(events, event)
			end
		end
	end

	local publicCounts = InfectionGraph.publicCounts(round.graph)
	local verdict = WinEvaluator.evaluate(round.config, {
		humans = publicCounts.humans,
		incubating = publicCounts.incubating,
		infected = publicCounts.infected,
		unstable = publicCounts.unstable,
		extracted = round.extractedCount,
		requiredExtracted = round.requiredExtracted,
		timeUp = at >= round.roundEndsAt,
		-- 遏制复核只在 CONTEST / EXTRACTION 累计：OUTBREAK 的结局由零号选择/补选流程决定，
		-- 否则零号离场后的空窗会让人类在开局白拿遏制胜利。
		containedSince = if round.phase == PHASE_OUTBREAK then nil else round.containedSince,
	}, at)
	round.containedSince = verdict.containedSince

	if verdict.winner ~= nil then
		finish(round, verdict.winner, verdict.reason, at, events)
	end

	return { events = events }
end

-- 服务端确认扑咬后调用。被咬者正在进行的撤离读条立即中断（§13.2）。
function RoundStateMachine.onBite(round: Round, attackerId: string, targetId: string, now: number): CommandResult
	if round.phase == PHASE_RESULT then
		return rejected(Reason.RoundOver)
	end
	if round.phase == PHASE_PREPARE then
		return rejected(Reason.PhaseNotActive)
	end

	local at = currentTime(round, now)
	local result = InfectionGraph.infect(round.graph, attackerId, targetId, at, { roundId = round.roundId })
	if not result.ok then
		return { ok = false, reason = result.reason, events = {} }
	end
	round.now = at

	local events: { RoundEvent } = {}
	handleCancelled(round, ChannelTimer.cancelInvolving(round.channels, targetId, Reason.Bitten), at, events)

	local event = newEvent(EventName.InfectionTurning, SCOPE_PUBLIC, at)
	event.participantId = targetId
	table.insert(events, event)

	-- §7.3 / §20.7：本人收到私有尸变倒计时提示。
	local target = InfectionGraph.getState(round.graph, targetId)
	local incubating = newEvent(EventName.YouAreIncubating, SCOPE_PRIVATE, at)
	incubating.participantId = targetId
	incubating.incubationEndsAt = if target ~= nil then target.incubationEndsAt else nil
	table.insert(events, incubating)
	return { ok = true, events = events }
end

-- 请求治愈：校验施放者持有解药、目标为公开稳定非根感染者，然后开始 2 秒服务端读条。
-- 零号目标直接拒绝 ROOT_IMMUNE，不扣道具、不进冷却（§6.2、§10.2）。
function RoundStateMachine.requestCure(round: Round, actorId: string, targetId: string, now: number): CommandResult
	if round.phase == PHASE_RESULT then
		return rejected(Reason.RoundOver)
	end
	if round.phase == PHASE_PREPARE then
		return rejected(Reason.PhaseNotActive)
	end

	local at = currentTime(round, now)
	local actor = stateOf(round, actorId)
	if actor == nil then
		return rejected(Reason.UnknownParticipant)
	end
	if actor.state ~= InfectionGraph.State.HUMAN then
		return rejected(Reason.NotHuman)
	end
	local itemId = CureInventory.heldBy(round.cures, actorId)
	if itemId == nil then
		return rejected(Reason.NoCure)
	end
	if not CureInventory.canAttempt(round.cures, actorId, at) then
		return rejected(Reason.CureCooldown)
	end
	local target = stateOf(round, targetId)
	if target == nil then
		-- §10.1：目标无效不扣道具，但进入短冷却，防止刷交互。
		CureInventory.onFailedAttempt(round.cures, actorId, at)
		return rejected(Reason.UnknownTarget)
	end
	if target.isRoot then
		-- §6.2 / §10.2：零号提示“普通解药无效”，不扣道具也不惩罚。
		return rejected(Reason.RootImmune)
	end
	if target.state ~= InfectionGraph.State.INFECTED then
		CureInventory.onFailedAttempt(round.cures, actorId, at)
		return rejected(Reason.TargetNotInfected)
	end
	local episodeId = target.episodeId
	if episodeId == nil then
		CureInventory.onFailedAttempt(round.cures, actorId, at)
		return rejected(Reason.TargetNotInfected)
	end

	local events: { RoundEvent } = {}
	if not startChannel(round, actorId, KIND_CURE, targetId, at, round.config.CureChannelSeconds, events) then
		return rejected(Reason.Invalid)
	end
	round.now = at
	round.cureMeta[actorId] = { itemId = itemId, targetId = targetId, expectedEpisodeId = episodeId }

	local progress = newEvent(EventName.CureChannelProgress, SCOPE_PRIVATE, at)
	progress.participantId = actorId
	progress.actorId = actorId
	progress.targetId = targetId
	progress.channelKind = KIND_CURE
	progress.elapsed = 0
	progress.duration = round.config.CureChannelSeconds
	progress.ratio = 0
	table.insert(events, progress)

	return { ok = true, events = events }
end

-- 请求重连：断联者向稳定感染者读条；以零号为目标时读条时长乘以 RootRelinkHoldMultiplier。
function RoundStateMachine.requestRelink(round: Round, unstableId: string, targetId: string, now: number): CommandResult
	if round.phase == PHASE_RESULT then
		return rejected(Reason.RoundOver)
	end
	if round.phase == PHASE_PREPARE then
		return rejected(Reason.PhaseNotActive)
	end

	local at = currentTime(round, now)
	local unstable = stateOf(round, unstableId)
	if unstable == nil then
		return rejected(Reason.UnknownParticipant)
	end
	if unstable.state ~= InfectionGraph.State.UNSTABLE then
		return rejected(Reason.NotUnstable)
	end
	local episodeId = unstable.episodeId
	if episodeId == nil then
		return rejected(Reason.NotUnstable)
	end
	local target = stateOf(round, targetId)
	if target == nil then
		return rejected(Reason.UnknownTarget)
	end
	if target.state ~= InfectionGraph.State.INFECTED then
		return rejected(Reason.TargetNotInfected)
	end
	local hold = InfectionGraph.relinkHoldSeconds(round.graph, unstableId, targetId)
	if hold == nil then
		return rejected(Reason.TargetNotInfected)
	end

	local events: { RoundEvent } = {}
	if not startChannel(round, unstableId, KIND_RELINK, targetId, at, hold, events) then
		return rejected(Reason.Invalid)
	end
	round.now = at
	round.relinkMeta[unstableId] = { targetId = targetId, expectedEpisodeId = episodeId }
	return { ok = true, events = events }
end

-- 显式请求撤离。是否在撤离区由下一 tick 的 isInExtractionZone 校验；不在区内会立即被取消。
function RoundStateMachine.requestExtract(round: Round, actorId: string, now: number): CommandResult
	if round.phase == PHASE_RESULT then
		return rejected(Reason.RoundOver)
	end
	if round.phase ~= PHASE_EXTRACTION then
		return rejected(Reason.PhaseNotActive)
	end

	local at = currentTime(round, now)
	local actor = stateOf(round, actorId)
	if actor == nil then
		return rejected(Reason.UnknownParticipant)
	end
	if actor.state ~= InfectionGraph.State.HUMAN then
		return rejected(Reason.NotHuman)
	end

	local events: { RoundEvent } = {}
	if not startChannel(round, actorId, KIND_EXTRACT, nil, at, round.config.Greybox.ExtractHoldSeconds, events) then
		return rejected(Reason.Invalid)
	end
	round.now = at
	return { ok = true, events = events }
end

-- 主动取消读条（§10.1、§21.2）：客户端释放交互键时调用，服务端按同一套取消规则清理。
-- 治愈读条取消会进入短冷却并保留解药；重连/撤离取消只清元数据。没有读条时返回 INVALID。
function RoundStateMachine.cancelChannel(round: Round, actorId: string, now: number, reason: string?): CommandResult
	local at = currentTime(round, now)
	local cancelReason = reason or Reason.Cancelled
	local channel = ChannelTimer.cancel(round.channels, actorId, cancelReason)
	if channel == nil then
		return rejected(Reason.Invalid)
	end
	round.now = at

	local events: { RoundEvent } = {}
	handleCancelled(round, { { channel = channel, reason = cancelReason } }, at, events)
	return { ok = true, events = events }
end

-- 参与者退出（§19.1）：取消其相关读条、掉落手持解药、再在感染图同一事务内删除。
-- position 是该玩家最后位置（不透明值）；已撤离者的撤离计数继续保留。
function RoundStateMachine.removeParticipant(
	round: Round,
	participantId: string,
	now: number,
	position: unknown?
): CommandResult
	local at = currentTime(round, now)
	if stateOf(round, participantId) == nil then
		return rejected(Reason.UnknownParticipant)
	end

	local result = InfectionGraph.removeParticipant(round.graph, participantId, at, { roundId = round.roundId })
	if not result.ok then
		return { ok = false, reason = result.reason, events = {} }
	end
	round.now = at

	local events: { RoundEvent } = {}
	handleCancelled(round, ChannelTimer.cancelInvolving(round.channels, participantId, Reason.Left), at, events)
	round.cureMeta[participantId] = nil
	round.relinkMeta[participantId] = nil
	round.unstableNotified[participantId] = nil
	if CureInventory.heldBy(round.cures, participantId) ~= nil then
		CureInventory.drop(round.cures, participantId, position)
	end
	-- 不清空 round.extracted：§19.1 已撤离玩家离场不撤销本局撤离进度。
	return { ok = true, events = events }
end

-- 开局后的中途加入（§5.2、D5）：角色由已进行时间决定；INFECTED 找不到现存感染树时降级为 HUMAN。
function RoundStateMachine.addLateJoiner(round: Round, participantId: string, now: number): CommandResult
	if round.phase == PHASE_RESULT then
		return rejected(Reason.RoundOver)
	end

	local at = currentTime(round, now)
	local elapsed = math.max(0, at - round.startedAt)
	local role: InfectionGraph.LateJoinRole = lateJoinRoleFor(round.config, elapsed, round.plan.tier.roundSeconds)
	local options: InfectionGraph.Options = { roundId = round.roundId }

	local result = InfectionGraph.addLateJoiner(round.graph, participantId, role, at, options)
	if not result.ok and role == "INFECTED" and result.reason == InfectionGraph.Reason.NoTree then
		result = InfectionGraph.addLateJoiner(round.graph, participantId, "HUMAN", at, options)
	end
	if not result.ok then
		return { ok = false, reason = result.reason, events = {} }
	end
	round.now = at
	return { ok = true, events = {} }
end

return table.freeze(RoundStateMachine)
