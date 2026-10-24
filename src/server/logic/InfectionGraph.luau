--!strict
-- Gate A-1 感染森林纯逻辑（GDB V1.1 §5.2、§7.1–§7.4、§8.1–§8.6、§11、§19.1、§20.5–§20.6、§23.1）。
--
-- 本模块只回答“感染身份与感染树”的问题：谁是人类、谁在尸变、谁稳定感染、谁断联、
-- 谁是谁的上游。战斗生命状态（倒地/死亡/复活，§9A.3）、扫描、胜负、位移、读条全部在模块外，
-- 图不知道也不允许知道生命值。纯逻辑：无 Roblox 全局对象，配置与 now 由调用方传入，
-- 单场图只有单写者（§20.5），所有变更同步完成、无 yield。
--
-- 数据模型（§8）：
--   - 每名参与者用 ParticipantId 字符串作键（§20.9："U:<userId>" / "B:<i>:<roundId>"）。
--   - 一次有效的感染身份是一个 episode；episode 可被治愈、断联、重连或随玩家退出删除。
--   - 非根节点最多一个父节点；父节点只能是稳定感染者、断联感染者或 VirtualRoot（§19.1 根退出）。
--   - VirtualRoot 是非实体节点，id 为 "VR:<seedId>"，只存在于 children 索引中，不能作为重连目标。
--   - g.seq 单调递增；每次被接受的命令恰好追加一条事件（事件原子性，§8.2 第 7 条）。
--
-- 事件日志即命令日志：每条事件的 command 字段保存重放所需的完整参数，
-- InfectionGraph.replay() 在全新图上按序重放即可得到完全相同的最终状态（G-17 确定性）。
-- 纯模块不 require 共享枚举；对外事件名与 PublicEventTypes 的公开事件在语义上对齐，
-- 实际广播由 Gate A 的服务层完成。

export type Config = {
	IncubationSeconds: number,
	DisconnectSeconds: number,
	CuredImmunitySeconds: number,
	ReconnectHoldSeconds: number,
	RootRelinkHoldMultiplier: number,
}

export type ParticipantStateName = "HUMAN" | "INCUBATING" | "INFECTED" | "UNSTABLE" | "EXTRACTED" | "SPECTATOR"

export type LateJoinRole = "HUMAN" | "INFECTED" | "SPECTATOR"

export type Participant = {
	id: string,
	state: ParticipantStateName,
	episodeId: string?,
	version: number,
	isRoot: boolean,
	seedId: string?,
	parentEpisodeId: string?,
	rootSeedId: string?,
	incubationEndsAt: number?,
	unstableEndsAt: number?,
	curedImmuneUntil: number?,
}

-- 可重放命令：事件日志中的 command 字段。
export type Command =
	| { name: "createRoot", seedId: string, participantId: string, now: number }
	| { name: "infect", attackerId: string, targetId: string, now: number }
	| { name: "tick", now: number }
	| { name: "cure", actorId: string, targetId: string, now: number }
	| { name: "relink", unstableId: string, targetId: string, now: number }
	| { name: "removeParticipant", participantId: string, now: number }
	| { name: "addLateJoiner", participantId: string, role: LateJoinRole, now: number }
	| { name: "markExtracted", participantId: string }

export type Event = {
	seq: number,
	type: string,
	at: number,
	command: Command,
	participantId: string?,
	actorId: string?,
	targetId: string?,
	episodeId: string?,
	seedId: string?,
	parentNodeId: string?,
	virtualRootId: string?,
	affectedInfected: number?,
	affectedIncubating: number?,
	unstableEndsAt: number?,
	revealedIds: { string }?,
	expiredIds: { string }?,
	reparentedIds: { string }?,
	stabilizedIds: { string }?,
}

export type Result = {
	ok: boolean,
	reason: string?,
	events: { Event },
	episodeId: string?,
	affectedInfected: number?,
	affectedIncubating: number?,
}

-- 可选参数（§11.4、G-10）：roundId 用于拒绝旧局命令，expected* 用于拒绝过期命令。
-- expectedVersion / expectedEpisodeId 指向本次命令的主要目标
-- （infect/cure 的 target，relink 的断联者，removeParticipant/markExtracted 的本人）。
export type Options = {
	roundId: string?,
	expectedVersion: number?,
	expectedEpisodeId: string?,
}

export type PublicCounts = {
	humans: number,
	incubating: number,
	infected: number,
	unstable: number,
}

export type Graph = {
	roundId: string,
	config: Config,
	now: number,
	participants: { [string]: Participant },
	order: { string },
	episodeIndex: { [string]: string },
	children: { [string]: { string } },
	virtualRoots: { [string]: boolean },
	seeds: { string },
	seq: number,
	episodeSeq: number,
	events: { Event },
}

type EventExtra = {
	participantId: string?,
	actorId: string?,
	targetId: string?,
	episodeId: string?,
	seedId: string?,
	parentNodeId: string?,
	virtualRootId: string?,
	affectedInfected: number?,
	affectedIncubating: number?,
	unstableEndsAt: number?,
	revealedIds: { string }?,
	expiredIds: { string }?,
	reparentedIds: { string }?,
	stabilizedIds: { string }?,
}

local InfectionGraph = {}

local STATE_HUMAN: ParticipantStateName = "HUMAN"
local STATE_INCUBATING: ParticipantStateName = "INCUBATING"
local STATE_INFECTED: ParticipantStateName = "INFECTED"
local STATE_UNSTABLE: ParticipantStateName = "UNSTABLE"
local STATE_EXTRACTED: ParticipantStateName = "EXTRACTED"
local STATE_SPECTATOR: ParticipantStateName = "SPECTATOR"

local State = table.freeze({
	HUMAN = STATE_HUMAN,
	INCUBATING = STATE_INCUBATING,
	INFECTED = STATE_INFECTED,
	UNSTABLE = STATE_UNSTABLE,
	EXTRACTED = STATE_EXTRACTED,
	SPECTATOR = STATE_SPECTATOR,
})
InfectionGraph.State = State

local EventType = table.freeze({
	RootCreated = "RootCreated",
	InfectionStarted = "InfectionStarted",
	InfectionRevealed = "InfectionRevealed",
	CureApplied = "CureApplied",
	RelinkSucceeded = "RelinkSucceeded",
	ParticipantRemoved = "ParticipantRemoved",
	LateJoined = "LateJoined",
	Extracted = "Extracted",
	TickResolved = "TickResolved",
})
InfectionGraph.EventType = EventType

-- 拒绝原因码：服务层可以据此映射提示，测试不应依赖文案。
local Reason = table.freeze({
	RoundMismatch = "ROUND_MISMATCH",
	UnknownParticipant = "UNKNOWN_PARTICIPANT",
	UnknownCommand = "UNKNOWN_COMMAND",
	NotHuman = "NOT_HUMAN",
	AttackerNotInfected = "ATTACKER_NOT_INFECTED",
	TargetNotHuman = "TARGET_NOT_HUMAN",
	TargetInfected = "TARGET_INFECTED",
	TargetImmune = "TARGET_IMMUNE",
	TargetNotInfected = "TARGET_NOT_INFECTED",
	NotUnstable = "NOT_UNSTABLE",
	RootImmune = "ROOT_IMMUNE",
	SeedExists = "SEED_EXISTS",
	InvalidSeed = "INVALID_SEED",
	SameParticipant = "SAME_PARTICIPANT",
	VirtualRootTarget = "VIRTUAL_ROOT_TARGET",
	TargetDescendant = "TARGET_DESCENDANT",
	ExpectedVersionMismatch = "EXPECTED_VERSION_MISMATCH",
	ExpectedEpisodeMismatch = "EXPECTED_EPISODE_MISMATCH",
	AlreadyParticipant = "ALREADY_PARTICIPANT",
	InvalidRole = "INVALID_ROLE",
	NoTree = "NO_TREE",
})
InfectionGraph.Reason = Reason

local VIRTUAL_ROOT_PREFIX = "VR:"

local function virtualRootId(seedId: string): string
	return VIRTUAL_ROOT_PREFIX .. seedId
end
InfectionGraph.virtualRootId = virtualRootId

local function isVirtualRootId(nodeId: string): boolean
	return string.sub(nodeId, 1, #VIRTUAL_ROOT_PREFIX) == VIRTUAL_ROOT_PREFIX
end

local function rejected(reason: string): Result
	return { ok = false, reason = reason, events = {} }
end

local function pushNow(graph: Graph, now: number)
	graph.now = math.max(graph.now, now)
end

local function checkRound(graph: Graph, options: Options?): string?
	if options ~= nil and options.roundId ~= nil and options.roundId ~= graph.roundId then
		return Reason.RoundMismatch
	end
	return nil
end

local function checkExpectations(participant: Participant, options: Options?): string?
	if options == nil then
		return nil
	end
	if options.expectedVersion ~= nil and participant.version ~= options.expectedVersion then
		return Reason.ExpectedVersionMismatch
	end
	if options.expectedEpisodeId ~= nil and participant.episodeId ~= options.expectedEpisodeId then
		return Reason.ExpectedEpisodeMismatch
	end
	return nil
end

local function bump(participant: Participant)
	participant.version += 1
end

local function participantOfEpisode(graph: Graph, episodeId: string): Participant?
	local participantId = graph.episodeIndex[episodeId]
	if participantId == nil then
		return nil
	end
	return graph.participants[participantId]
end

-- 节点（episode 或 VirtualRoot）对应的参与者；VirtualRoot 没有参与者。
local function bumpNode(graph: Graph, nodeId: string)
	local participant = participantOfEpisode(graph, nodeId)
	if participant ~= nil then
		bump(participant)
	end
end

local function allocateEpisode(graph: Graph, participant: Participant): string
	graph.episodeSeq += 1
	local episodeId = `E:{graph.episodeSeq}`
	participant.episodeId = episodeId
	graph.episodeIndex[episodeId] = participant.id
	return episodeId
end

local function appendChild(graph: Graph, parentNodeId: string, childEpisodeId: string)
	local kids = graph.children[parentNodeId]
	if kids == nil then
		kids = {}
		graph.children[parentNodeId] = kids
	end
	table.insert(kids, childEpisodeId)
end

local function removeChild(graph: Graph, parentNodeId: string, childEpisodeId: string)
	local kids = graph.children[parentNodeId]
	if kids == nil then
		return
	end
	local index = table.find(kids, childEpisodeId)
	if index ~= nil then
		table.remove(kids, index)
	end
	if #kids == 0 and graph.virtualRoots[parentNodeId] ~= true then
		graph.children[parentNodeId] = nil
	end
end

local function ensureVirtualRoot(graph: Graph, seedId: string): string
	local nodeId = virtualRootId(seedId)
	if graph.virtualRoots[nodeId] ~= true then
		graph.virtualRoots[nodeId] = true
		if graph.children[nodeId] == nil then
			graph.children[nodeId] = {}
		end
	end
	return nodeId
end

local function appendEvent(graph: Graph, eventType: string, at: number, command: Command, extra: EventExtra?): Event
	local event: Event = {
		seq = graph.seq,
		type = eventType,
		at = at,
		command = command,
	}
	if extra ~= nil then
		event.participantId = extra.participantId
		event.actorId = extra.actorId
		event.targetId = extra.targetId
		event.episodeId = extra.episodeId
		event.seedId = extra.seedId
		event.parentNodeId = extra.parentNodeId
		event.virtualRootId = extra.virtualRootId
		event.affectedInfected = extra.affectedInfected
		event.affectedIncubating = extra.affectedIncubating
		event.unstableEndsAt = extra.unstableEndsAt
		event.revealedIds = extra.revealedIds
		event.expiredIds = extra.expiredIds
		event.reparentedIds = extra.reparentedIds
		event.stabilizedIds = extra.stabilizedIds
	end
	table.insert(graph.events, event)
	return event
end

-- 清空参与者的感染身份字段，恢复为 HUMAN 并获得治愈保护（§7.4、§11）。
local function resetToHuman(graph: Graph, participant: Participant, now: number)
	participant.state = State.HUMAN
	participant.episodeId = nil
	participant.isRoot = false
	participant.seedId = nil
	participant.parentEpisodeId = nil
	participant.rootSeedId = nil
	participant.incubationEndsAt = nil
	participant.unstableEndsAt = nil
	participant.curedImmuneUntil = now + graph.config.CuredImmunitySeconds
	bump(participant)
end

-- 尸变过渡中的下游立即恢复人类，取消过渡计时（§11.1、G-13）。
local function revertIncubating(graph: Graph, participant: Participant, now: number, reverted: { string })
	local episodeId = participant.episodeId
	local parentNodeId = participant.parentEpisodeId
	if parentNodeId ~= nil and episodeId ~= nil then
		removeChild(graph, parentNodeId, episodeId)
		bumpNode(graph, parentNodeId)
	end
	if episodeId ~= nil then
		graph.episodeIndex[episodeId] = nil
		graph.children[episodeId] = nil
	end
	resetToHuman(graph, participant, now)
	table.insert(reverted, episodeId or participant.id)
end

-- 收集一次断链影响的分支：稳定感染者 → UNSTABLE（共享同一截止时间），
-- 尸变过渡者 → HUMAN（卡在过渡中的叶子直接取消），已断联者保持原截止时间。
local function collectBranch(
	graph: Graph,
	rootEpisodeId: string,
	deadline: number,
	now: number,
	unstable: { string },
	reverted: { string }
)
	local stack: { string } = { rootEpisodeId }
	while #stack > 0 do
		local episodeId = table.remove(stack)
		if episodeId == nil then
			break
		end
		local participant = participantOfEpisode(graph, episodeId)
		if participant ~= nil then
			if participant.state == State.INCUBATING then
				revertIncubating(graph, participant, now, reverted)
			elseif participant.state == State.INFECTED then
				participant.state = State.UNSTABLE
				participant.unstableEndsAt = deadline
				bump(participant)
				table.insert(unstable, episodeId)
			elseif participant.state == State.UNSTABLE then
				-- 防御：正常路径不会出现“稳定节点下有已断联后代”，保留原截止时间。
				table.insert(unstable, episodeId)
			end
			local kids = graph.children[episodeId]
			if kids ~= nil then
				for index = #kids, 1, -1 do
					table.insert(stack, kids[index])
				end
			end
		end
	end
end

-- target 是否在 ancestorEpisodeId 的子树内（含自身）。VirtualRoot 只可能是链顶。
local function isDescendantOf(graph: Graph, targetEpisodeId: string?, ancestorEpisodeId: string): boolean
	local current = targetEpisodeId
	local guard = 0
	local limit = #graph.order + #graph.seeds + 8
	while current ~= nil and guard <= limit do
		if current == ancestorEpisodeId then
			return true
		end
		local participant = participantOfEpisode(graph, current)
		if participant == nil then
			return false
		end
		current = participant.parentEpisodeId
		guard += 1
	end
	return false
end

local function findRootEpisode(graph: Graph, seedId: string): string?
	for _, id in graph.order do
		local participant = graph.participants[id]
		if
			participant ~= nil
			and participant.isRoot
			and participant.seedId == seedId
			and participant.episodeId ~= nil
		then
			return participant.episodeId
		end
	end
	return nil
end

-- 中途加入的感染者挂到“仍存在的感染树”的根：VirtualRoot 优先（真根已退出），否则真根 episode。
-- 多棵树时按 seedId 创建顺序取第一棵（确定性）。
local function findTreeAnchor(graph: Graph): (string?, string?)
	for _, seedId in graph.seeds do
		local nodeId = virtualRootId(seedId)
		if graph.virtualRoots[nodeId] == true then
			return nodeId, seedId
		end
		local rootEpisodeId = findRootEpisode(graph, seedId)
		if rootEpisodeId ~= nil then
			local rootParticipant = participantOfEpisode(graph, rootEpisodeId)
			if rootParticipant ~= nil and rootParticipant.state == State.INFECTED then
				return rootEpisodeId, seedId
			end
		end
	end
	return nil, nil
end

-- 创建一局的全新感染图。参与者一律从 HUMAN 开始（§6：所有玩家先是人类）。
function InfectionGraph.new(config: Config, roundId: string, participantIds: { string }): Graph
	local participants: { [string]: Participant } = {}
	local order: { string } = {}
	for _, id in participantIds do
		if participants[id] == nil then
			participants[id] = {
				id = id,
				state = State.HUMAN,
				episodeId = nil,
				version = 0,
				isRoot = false,
				seedId = nil,
				parentEpisodeId = nil,
				rootSeedId = nil,
				incubationEndsAt = nil,
				unstableEndsAt = nil,
				curedImmuneUntil = nil,
			}
			table.insert(order, id)
		end
	end
	return {
		roundId = roundId,
		config = config,
		now = 0,
		participants = participants,
		order = order,
		episodeIndex = {},
		children = {},
		virtualRoots = {},
		seeds = {},
		seq = 0,
		episodeSeq = 0,
		events = {},
	}
end

-- 零号感染源（§6、§20.6）：建立一棵新树，根节点和其他感染一样先进入公开尸变过渡。
-- 隔离突破是开局事件，不检查治愈保护（保护针对“再次被咬”，§7.4）。
function InfectionGraph.createRoot(
	graph: Graph,
	seedId: string,
	participantId: string,
	now: number,
	options: Options?
): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	if seedId == "" then
		return rejected(Reason.InvalidSeed)
	end
	for _, existingSeedId in graph.seeds do
		if existingSeedId == seedId then
			return rejected(Reason.SeedExists)
		end
	end
	local participant = graph.participants[participantId]
	if participant == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local expectedReason = checkExpectations(participant, options)
	if expectedReason ~= nil then
		return rejected(expectedReason)
	end
	if participant.state ~= State.HUMAN then
		return rejected(Reason.NotHuman)
	end
	if participant.episodeId ~= nil then
		return rejected(Reason.TargetInfected)
	end

	pushNow(graph, now)
	graph.seq += 1
	local episodeId = allocateEpisode(graph, participant)
	participant.state = State.INCUBATING
	participant.isRoot = true
	participant.seedId = seedId
	participant.parentEpisodeId = nil
	participant.rootSeedId = seedId
	participant.incubationEndsAt = now + graph.config.IncubationSeconds
	participant.unstableEndsAt = nil
	participant.curedImmuneUntil = nil
	bump(participant)
	table.insert(graph.seeds, seedId)

	local event = appendEvent(graph, EventType.RootCreated, now, {
		name = "createRoot",
		seedId = seedId,
		participantId = participantId,
		now = now,
	}, {
		participantId = participantId,
		episodeId = episodeId,
		seedId = seedId,
	})
	return { ok = true, events = { event }, episodeId = episodeId }
end

-- 服务端确认一次扑咬（§7.2、§8.4）：稳定感染者 → 人类目标，目标进入尸变过渡叶子。
-- 攻击者必须是 INFECTED（不变量 9/10：尸变中与断联者都不能扩散）。
function InfectionGraph.infect(
	graph: Graph,
	attackerId: string,
	targetId: string,
	now: number,
	options: Options?
): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	if attackerId == targetId then
		return rejected(Reason.SameParticipant)
	end
	local attacker = graph.participants[attackerId]
	if attacker == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local target = graph.participants[targetId]
	if target == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local expectedReason = checkExpectations(target, options)
	if expectedReason ~= nil then
		return rejected(expectedReason)
	end
	if attacker.state ~= State.INFECTED then
		return rejected(Reason.AttackerNotInfected)
	end
	local attackerEpisodeId = attacker.episodeId
	if attackerEpisodeId == nil then
		return rejected(Reason.AttackerNotInfected)
	end
	if target.state ~= State.HUMAN then
		return rejected(Reason.TargetNotHuman)
	end
	if target.episodeId ~= nil then
		return rejected(Reason.TargetInfected)
	end
	if target.curedImmuneUntil ~= nil and target.curedImmuneUntil > now then
		return rejected(Reason.TargetImmune)
	end

	pushNow(graph, now)
	graph.seq += 1
	local episodeId = allocateEpisode(graph, target)
	target.state = State.INCUBATING
	target.isRoot = false
	target.seedId = nil
	target.parentEpisodeId = attackerEpisodeId
	target.rootSeedId = attacker.rootSeedId
	target.incubationEndsAt = now + graph.config.IncubationSeconds
	target.unstableEndsAt = nil
	target.curedImmuneUntil = nil
	bump(target)
	appendChild(graph, attackerEpisodeId, episodeId)
	bump(attacker)

	local event = appendEvent(graph, EventType.InfectionStarted, now, {
		name = "infect",
		attackerId = attackerId,
		targetId = targetId,
		now = now,
	}, {
		participantId = targetId,
		actorId = attackerId,
		targetId = targetId,
		episodeId = episodeId,
		parentNodeId = attackerEpisodeId,
	})
	return { ok = true, events = { event }, episodeId = episodeId }
end

-- 推进服务端计时（§11.1、§11.4、G-17）：按参与者插入顺序确定性地
-- 先公开尸变完成的节点，再结算到期的断联者。命令按提交顺序执行：
-- 同一时刻先提交的重连（UNSTABLE → INFECTED）会让随后的 tick 看不到断联节点。
function InfectionGraph.tick(graph: Graph, now: number, options: Options?): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	pushNow(graph, now)

	local revealed: { string } = {}
	local expired: { string } = {}
	for _, id in graph.order do
		local participant = graph.participants[id]
		if participant ~= nil then
			if participant.state == State.INCUBATING then
				local endsAt = participant.incubationEndsAt
				if endsAt ~= nil and endsAt <= now then
					participant.state = State.INFECTED
					participant.incubationEndsAt = nil
					bump(participant)
					table.insert(revealed, id)
				end
			elseif participant.state == State.UNSTABLE then
				local deadline = participant.unstableEndsAt
				if deadline ~= nil and deadline <= now then
					local episodeId = participant.episodeId
					if episodeId ~= nil then
						local parentNodeId = participant.parentEpisodeId
						if parentNodeId ~= nil then
							removeChild(graph, parentNodeId, episodeId)
							bumpNode(graph, parentNodeId)
						end
						-- 仍未重连的断联后代成为新的孤儿分支根，保留它们自己的截止时间。
						local kids = graph.children[episodeId]
						if kids ~= nil then
							for _, childEpisodeId in table.clone(kids) do
								local childParticipant = participantOfEpisode(graph, childEpisodeId)
								if childParticipant ~= nil then
									childParticipant.parentEpisodeId = nil
									bump(childParticipant)
								end
							end
							graph.children[episodeId] = nil
						end
						graph.episodeIndex[episodeId] = nil
						resetToHuman(graph, participant, now)
						-- resetToHuman 会把 state 置为 HUMAN；这里保留治愈保护计时。
						table.insert(expired, episodeId)
					end
				end
			end
		end
	end

	-- 即使没有任何到期效果，也记录本次 tick：它推进了图的服务端时间 g.now，
	-- 日志必须完整才能让 replay 复现同样的 at 时间戳与后续行为（G-17）。
	graph.seq += 1
	local event = appendEvent(graph, EventType.TickResolved, now, { name = "tick", now = now }, {
		revealedIds = revealed,
		expiredIds = expired,
	})
	return { ok = true, events = { event } }
end

-- 治愈一名非根稳定感染者（§10、§11、§20.6）。
-- 目标立即恢复人类并获得治愈保护；直接子节点成为孤儿分支根，
-- 其仍附属的稳定后代共享同一断联截止时间；尸变过渡中的后代立即恢复人类（G-13）。
function InfectionGraph.cure(graph: Graph, actorId: string, targetId: string, now: number, options: Options?): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	local actor = graph.participants[actorId]
	if actor == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local target = graph.participants[targetId]
	if target == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local expectedReason = checkExpectations(target, options)
	if expectedReason ~= nil then
		return rejected(expectedReason)
	end
	if actor.state ~= State.HUMAN then
		return rejected(Reason.NotHuman)
	end
	if target.state ~= State.INFECTED then
		return rejected(Reason.TargetNotInfected)
	end
	if target.isRoot then
		return rejected(Reason.RootImmune)
	end
	local targetEpisodeId = target.episodeId
	if targetEpisodeId == nil then
		return rejected(Reason.TargetNotInfected)
	end

	pushNow(graph, now)
	graph.seq += 1
	local deadline = now + graph.config.DisconnectSeconds
	local detached: { string } = {}
	local unstable: { string } = {}
	local reverted: { string } = {}

	local directKids = graph.children[targetEpisodeId]
	if directKids ~= nil then
		for _, childEpisodeId in table.clone(directKids) do
			local childParticipant = participantOfEpisode(graph, childEpisodeId)
			if childParticipant ~= nil then
				childParticipant.parentEpisodeId = nil
				if childParticipant.state == State.INCUBATING then
					revertIncubating(graph, childParticipant, now, reverted)
				else
					table.insert(detached, childEpisodeId)
					collectBranch(graph, childEpisodeId, deadline, now, unstable, reverted)
				end
			end
		end
	end
	graph.children[targetEpisodeId] = nil

	-- 治愈节点本身脱离上游；上游保持稳定（§8.1 例）。
	local upstreamNodeId = target.parentEpisodeId
	if upstreamNodeId ~= nil then
		removeChild(graph, upstreamNodeId, targetEpisodeId)
		bumpNode(graph, upstreamNodeId)
	end
	graph.episodeIndex[targetEpisodeId] = nil
	resetToHuman(graph, target, now)

	local event = appendEvent(graph, EventType.CureApplied, now, {
		name = "cure",
		actorId = actorId,
		targetId = targetId,
		now = now,
	}, {
		participantId = targetId,
		actorId = actorId,
		targetId = targetId,
		episodeId = targetEpisodeId,
		affectedInfected = #unstable,
		affectedIncubating = #reverted,
		unstableEndsAt = deadline,
		reparentedIds = detached,
	})
	return {
		ok = true,
		events = { event },
		affectedInfected = #unstable,
		affectedIncubating = #reverted,
	}
end

-- 重连读条时长（§11.2、§8.5、G-19）：目标为零号时乘以 RootRelinkHoldMultiplier。
-- 非法目标（不存在 / 不稳定 / VirtualRoot）返回 nil。
function InfectionGraph.relinkHoldSeconds(graph: Graph, unstableId: string, targetId: string): number?
	local unstable = graph.participants[unstableId]
	if unstable == nil or unstable.state ~= State.UNSTABLE then
		return nil
	end
	if isVirtualRootId(targetId) then
		return nil
	end
	local target = graph.participants[targetId]
	if target == nil or target.state ~= State.INFECTED then
		return nil
	end
	if target.isRoot then
		return graph.config.ReconnectHoldSeconds * graph.config.RootRelinkHoldMultiplier
	end
	return graph.config.ReconnectHoldSeconds
end

-- 断联者重连到稳定感染者（§11.2、§11.3、§8.5）。
-- 先原子脱离旧的断联父节点再挂到新目标；重连者及其仍附属的断联后代一起稳定，
-- rootSeedId 整支迁移到目标所在的树（G-06），旧截止时间立即失效（G-03）。
-- 检查顺序：断联者有效性 → 目标存在 → 目标不是 VirtualRoot → 目标不是自身后代 → 目标稳定。
function InfectionGraph.relink(
	graph: Graph,
	unstableId: string,
	targetId: string,
	now: number,
	options: Options?
): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	if unstableId == targetId then
		return rejected(Reason.SameParticipant)
	end
	local unstable = graph.participants[unstableId]
	if unstable == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local expectedReason = checkExpectations(unstable, options)
	if expectedReason ~= nil then
		return rejected(expectedReason)
	end
	if unstable.state ~= State.UNSTABLE then
		return rejected(Reason.NotUnstable)
	end
	local unstableEpisodeId = unstable.episodeId
	if unstableEpisodeId == nil then
		return rejected(Reason.NotUnstable)
	end
	if isVirtualRootId(targetId) then
		return rejected(Reason.VirtualRootTarget)
	end
	local target = graph.participants[targetId]
	if target == nil then
		return rejected(Reason.UnknownParticipant)
	end
	if isDescendantOf(graph, target.episodeId, unstableEpisodeId) then
		return rejected(Reason.TargetDescendant)
	end
	if target.state ~= State.INFECTED then
		return rejected(Reason.TargetNotInfected)
	end
	local targetEpisodeId = target.episodeId
	if targetEpisodeId == nil then
		return rejected(Reason.TargetNotInfected)
	end
	local targetRootSeedId = target.rootSeedId
	if targetRootSeedId == nil then
		return rejected(Reason.TargetNotInfected)
	end

	pushNow(graph, now)
	graph.seq += 1

	local oldParentNodeId = unstable.parentEpisodeId
	if oldParentNodeId ~= nil then
		removeChild(graph, oldParentNodeId, unstableEpisodeId)
		bumpNode(graph, oldParentNodeId)
	end
	unstable.parentEpisodeId = targetEpisodeId
	appendChild(graph, targetEpisodeId, unstableEpisodeId)
	bump(target)

	local stabilized: { string } = {}
	local stack: { string } = { unstableEpisodeId }
	while #stack > 0 do
		local episodeId = table.remove(stack)
		if episodeId == nil then
			break
		end
		local participant = participantOfEpisode(graph, episodeId)
		if participant ~= nil then
			if participant.state == State.UNSTABLE then
				participant.state = State.INFECTED
				participant.unstableEndsAt = nil
				bump(participant)
			end
			participant.rootSeedId = targetRootSeedId
			table.insert(stabilized, episodeId)
			local kids = graph.children[episodeId]
			if kids ~= nil then
				for index = #kids, 1, -1 do
					table.insert(stack, kids[index])
				end
			end
		end
	end

	local event = appendEvent(graph, EventType.RelinkSucceeded, now, {
		name = "relink",
		unstableId = unstableId,
		targetId = targetId,
		now = now,
	}, {
		participantId = unstableId,
		targetId = targetId,
		episodeId = unstableEpisodeId,
		parentNodeId = targetEpisodeId,
		affectedInfected = #stabilized,
		stabilizedIds = stabilized,
	})
	return { ok = true, events = { event }, affectedInfected = #stabilized }
end

-- 参与者退出/掉线（§19.1 表）。任何删除都在同一事务内完成，绝不留下悬挂 parent。
-- 退出永远不为下游重置断联计时，也不把退出当作免费解药。
function InfectionGraph.removeParticipant(graph: Graph, participantId: string, now: number, options: Options?): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	local participant = graph.participants[participantId]
	if participant == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local expectedReason = checkExpectations(participant, options)
	if expectedReason ~= nil then
		return rejected(expectedReason)
	end

	pushNow(graph, now)
	graph.seq += 1
	local priorState = participant.state
	local episodeId = participant.episodeId
	local reparented: { string } = {}
	local virtualRoot: string? = nil

	if priorState == State.INCUBATING then
		-- 尸变过渡中：删除叶子与 episode，父节点不受影响。
		if episodeId ~= nil then
			local parentNodeId = participant.parentEpisodeId
			if parentNodeId ~= nil then
				removeChild(graph, parentNodeId, episodeId)
				bumpNode(graph, parentNodeId)
			end
			graph.episodeIndex[episodeId] = nil
			graph.children[episodeId] = nil
		end
	elseif priorState == State.INFECTED then
		if episodeId ~= nil then
			local kids = graph.children[episodeId]
			local childIds: { string } = if kids ~= nil then table.clone(kids) else {}
			if participant.isRoot then
				-- 零号根退出：保留该树的非实体 VirtualRoot，直接子节点仍稳定。
				if #childIds > 0 then
					local seedId = participant.seedId
					if seedId ~= nil then
						virtualRoot = ensureVirtualRoot(graph, seedId)
					end
					for _, childEpisodeId in childIds do
						local childParticipant = participantOfEpisode(graph, childEpisodeId)
						if childParticipant ~= nil then
							childParticipant.parentEpisodeId = virtualRoot
							bump(childParticipant)
						end
						if virtualRoot ~= nil then
							appendChild(graph, virtualRoot, childEpisodeId)
						end
						table.insert(reparented, childEpisodeId)
					end
				end
			else
				-- 稳定非根退出：直接子节点继承该节点的稳定上游，下游保持稳定（G-15）。
				local upstreamNodeId = participant.parentEpisodeId
				if upstreamNodeId ~= nil then
					removeChild(graph, upstreamNodeId, episodeId)
					bumpNode(graph, upstreamNodeId)
				end
				for _, childEpisodeId in childIds do
					local childParticipant = participantOfEpisode(graph, childEpisodeId)
					if childParticipant ~= nil then
						childParticipant.parentEpisodeId = upstreamNodeId
						bump(childParticipant)
					end
					if upstreamNodeId ~= nil then
						appendChild(graph, upstreamNodeId, childEpisodeId)
					end
					table.insert(reparented, childEpisodeId)
				end
			end
			graph.children[episodeId] = nil
			graph.episodeIndex[episodeId] = nil
		end
	elseif priorState == State.UNSTABLE then
		if episodeId ~= nil then
			local kids = graph.children[episodeId]
			local childIds: { string } = if kids ~= nil then table.clone(kids) else {}
			-- 下游挂到“下一个断联祖先”（若存在），继承本次断联截止时间，不重置（G-16）。
			local nextParentNodeId: string? = nil
			local parentNodeId = participant.parentEpisodeId
			if parentNodeId ~= nil then
				local parentParticipant = participantOfEpisode(graph, parentNodeId)
				if parentParticipant ~= nil and parentParticipant.state == State.UNSTABLE then
					nextParentNodeId = parentNodeId
				end
			end
			local deadline = participant.unstableEndsAt
			for _, childEpisodeId in childIds do
				local childParticipant = participantOfEpisode(graph, childEpisodeId)
				if childParticipant ~= nil then
					childParticipant.parentEpisodeId = nextParentNodeId
					if deadline ~= nil then
						childParticipant.unstableEndsAt = deadline
					end
					bump(childParticipant)
				end
				if nextParentNodeId ~= nil then
					appendChild(graph, nextParentNodeId, childEpisodeId)
				end
				table.insert(reparented, childEpisodeId)
			end
			if parentNodeId ~= nil then
				removeChild(graph, parentNodeId, episodeId)
				bumpNode(graph, parentNodeId)
			end
			graph.children[episodeId] = nil
			graph.episodeIndex[episodeId] = nil
		end
	end
	-- HUMAN / EXTRACTED / SPECTATOR：没有图结构，离场即可（撤离进度保存在本模块之外）。

	local orderIndex = table.find(graph.order, participantId)
	if orderIndex ~= nil then
		table.remove(graph.order, orderIndex)
	end
	graph.participants[participantId] = nil

	local event = appendEvent(graph, EventType.ParticipantRemoved, now, {
		name = "removeParticipant",
		participantId = participantId,
		now = now,
	}, {
		participantId = participantId,
		episodeId = episodeId,
		seedId = participant.seedId,
		virtualRootId = virtualRoot,
		reparentedIds = reparented,
	})
	return { ok = true, events = { event } }
end

-- 对局开始后的中途加入（§5.2、G-20）：
--   HUMAN     → 获得 CuredImmunitySeconds 防感染保护；
--   INFECTED  → 作为稳定叶子直接挂到现存树的根（或 VirtualRoot）下，不触发任何断联；
--   SPECTATOR → 本局有限观战，不进入感染树。
-- 没有现存感染树时拒绝 INFECTED（调用方应降级为 HUMAN 或 SPECTATOR）。
function InfectionGraph.addLateJoiner(
	graph: Graph,
	participantId: string,
	role: LateJoinRole,
	now: number,
	options: Options?
): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	if graph.participants[participantId] ~= nil then
		return rejected(Reason.AlreadyParticipant)
	end
	if role ~= "HUMAN" and role ~= "INFECTED" and role ~= "SPECTATOR" then
		return rejected(Reason.InvalidRole)
	end
	local anchorNodeId: string? = nil
	local seedId: string? = nil
	if role == "INFECTED" then
		anchorNodeId, seedId = findTreeAnchor(graph)
		if anchorNodeId == nil or seedId == nil then
			return rejected(Reason.NoTree)
		end
	end

	pushNow(graph, now)
	graph.seq += 1

	local participant: Participant = {
		id = participantId,
		state = State.SPECTATOR,
		episodeId = nil,
		version = 0,
		isRoot = false,
		seedId = nil,
		parentEpisodeId = nil,
		rootSeedId = nil,
		incubationEndsAt = nil,
		unstableEndsAt = nil,
		curedImmuneUntil = nil,
	}
	if role == "HUMAN" then
		participant.state = State.HUMAN
		participant.curedImmuneUntil = now + graph.config.CuredImmunitySeconds
	end
	graph.participants[participantId] = participant
	table.insert(graph.order, participantId)

	local episodeId: string? = nil
	if role == "INFECTED" then
		local anchor = anchorNodeId
		local treeSeedId = seedId
		if anchor ~= nil and treeSeedId ~= nil then
			participant.state = State.INFECTED
			participant.rootSeedId = treeSeedId
			participant.parentEpisodeId = anchor
			local newEpisodeId = allocateEpisode(graph, participant)
			episodeId = newEpisodeId
			bump(participant)
			appendChild(graph, anchor, newEpisodeId)
			bumpNode(graph, anchor)
		end
	end

	local event = appendEvent(graph, EventType.LateJoined, now, {
		name = "addLateJoiner",
		participantId = participantId,
		role = role,
		now = now,
	}, {
		participantId = participantId,
		episodeId = episodeId,
		seedId = seedId,
		parentNodeId = anchorNodeId,
	})
	return { ok = true, events = { event }, episodeId = episodeId }
end

-- 合法撤离（§13、§19.1）：只有 HUMAN 能撤离；撤离进度保存在本模块之外。
function InfectionGraph.markExtracted(graph: Graph, participantId: string, options: Options?): Result
	local roundReason = checkRound(graph, options)
	if roundReason ~= nil then
		return rejected(roundReason)
	end
	local participant = graph.participants[participantId]
	if participant == nil then
		return rejected(Reason.UnknownParticipant)
	end
	local expectedReason = checkExpectations(participant, options)
	if expectedReason ~= nil then
		return rejected(expectedReason)
	end
	if participant.state ~= State.HUMAN then
		return rejected(Reason.NotHuman)
	end

	graph.seq += 1
	participant.state = State.EXTRACTED
	participant.curedImmuneUntil = nil
	bump(participant)
	local event = appendEvent(graph, EventType.Extracted, graph.now, {
		name = "markExtracted",
		participantId = participantId,
	}, {
		participantId = participantId,
	})
	return { ok = true, events = { event } }
end

local function countDescendants(graph: Graph, rootEpisodeId: string): number
	local count = 0
	local visited: { [string]: boolean } = {}
	local stack: { string } = { rootEpisodeId }
	while #stack > 0 do
		local episodeId = table.remove(stack)
		if episodeId == nil then
			break
		end
		local kids = graph.children[episodeId]
		if kids ~= nil then
			for _, childEpisodeId in kids do
				if visited[childEpisodeId] ~= true then
					visited[childEpisodeId] = true
					count += 1
					table.insert(stack, childEpisodeId)
				end
			end
		end
	end
	return count
end

-- 当前仍有效的后代数量（§8.3），不含自己。
function InfectionGraph.descendantCount(graph: Graph, participantId: string): number
	local participant = graph.participants[participantId]
	if participant == nil or participant.episodeId == nil then
		return 0
	end
	return countDescendants(graph, participant.episodeId)
end

-- branchImpact = 1 + descendantCount（§8.3）；没有感染身份时为 0。
function InfectionGraph.branchImpact(graph: Graph, participantId: string): number
	local participant = graph.participants[participantId]
	if participant == nil or participant.episodeId == nil then
		return 0
	end
	return 1 + countDescendants(graph, participant.episodeId)
end

-- 公开人数（§13.4）：只统计四个公开主状态，EXTRACTED / SPECTATOR 不在战场。
function InfectionGraph.publicCounts(graph: Graph): PublicCounts
	local counts: PublicCounts = { humans = 0, incubating = 0, infected = 0, unstable = 0 }
	for _, id in graph.order do
		local participant = graph.participants[id]
		if participant ~= nil then
			if participant.state == State.HUMAN then
				counts.humans += 1
			elseif participant.state == State.INCUBATING then
				counts.incubating += 1
			elseif participant.state == State.INFECTED then
				counts.infected += 1
			elseif participant.state == State.UNSTABLE then
				counts.unstable += 1
			end
		end
	end
	return counts
end

-- 返回参与者状态的浅拷贝；调用方不得通过返回值改写图（单写者，§20.5）。
function InfectionGraph.getState(graph: Graph, participantId: string): Participant?
	local participant = graph.participants[participantId]
	if participant == nil then
		return nil
	end
	return {
		id = participant.id,
		state = participant.state,
		episodeId = participant.episodeId,
		version = participant.version,
		isRoot = participant.isRoot,
		seedId = participant.seedId,
		parentEpisodeId = participant.parentEpisodeId,
		rootSeedId = participant.rootSeedId,
		incubationEndsAt = participant.incubationEndsAt,
		unstableEndsAt = participant.unstableEndsAt,
		curedImmuneUntil = participant.curedImmuneUntil,
	}
end

-- episode 当前归属的参与者（调试与测试用）；已失效的 episode 返回 nil。
function InfectionGraph.getEpisodeOwner(graph: Graph, episodeId: string): string?
	return graph.episodeIndex[episodeId]
end

function InfectionGraph.participantIds(graph: Graph): { string }
	return table.clone(graph.order)
end

-- 只追加事件日志的浅拷贝（事件本身不应被外部改写）。
function InfectionGraph.eventLog(graph: Graph): { Event }
	return table.clone(graph.events)
end

local function contains(list: { string }, value: string): boolean
	for _, item in list do
		if item == value then
			return true
		end
	end
	return false
end

local function invariantError(message: string): never
	error(`[InfectionGraph] 不变量失败：{message}`, 0)
end

local function requireParticipant(graph: Graph, participantId: string, context: string): Participant
	local participant = graph.participants[participantId]
	if participant == nil then
		invariantError(`{context}：参与者 {participantId} 不存在`)
	end
	return participant :: Participant
end

local function requireEpisodeParticipant(graph: Graph, episodeId: string, context: string): Participant
	local participant = participantOfEpisode(graph, episodeId)
	if participant == nil then
		invariantError(`{context}：episode {episodeId} 不存在`)
	end
	return participant :: Participant
end

local HAS_EPISODE: { [string]: boolean } = {
	HUMAN = false,
	INCUBATING = true,
	INFECTED = true,
	UNSTABLE = true,
	EXTRACTED = false,
	SPECTATOR = false,
}

-- 属性测试与每次服务端事务后必须调用的不变量检查（§8.2、§23.1）。
-- 断言清单：
--   1. order / participants 一一对应，无重复、无孤儿记录；
--   2. 每个参与者的状态与 episode、计时器字段组合合法（唯一身份）；
--   3. episodeIndex 双向一致，已治愈/离场玩家不再被 episode 引用；
--   4. 父子双向索引一致，父节点只能是稳定感染者、断联感染者或 VirtualRoot；
--   5. 尸变过渡节点没有子节点（不变量 9）；
--   6. 断联节点下不存在仍稳定/尸变中的后代，断联节点也不能挂在稳定上游下（不变量 10 的图侧）；
--   7. 非根稳定感染者/尸变者必须有父节点；零号根没有父节点；
--   8. 父子链无环，且整棵连通分量共享同一 rootSeedId；
--   9. VirtualRoot 的 seedId 属于本局，且不能与 episode 冲突；
--   10. 人数统计与 episode 数量一致，事件 seq 连续且等于事件数。
function InfectionGraph.assertInvariants(graph: Graph): boolean
	local seenOrder: { [string]: boolean } = {}
	local participantCount = 0
	for _, id in graph.order do
		if seenOrder[id] == true then
			invariantError(`order 中重复出现参与者 {id}`)
		end
		seenOrder[id] = true
		participantCount += 1
		local participant = requireParticipant(graph, id, "order")
		if participant.id ~= id then
			invariantError(`参与者记录的 id 与键不一致：{id} / {participant.id}`)
		end
	end

	local recordCount = 0
	local stateCounts: { [string]: number } = {}
	for id, participant in graph.participants do
		recordCount += 1
		if seenOrder[id] ~= true then
			invariantError(`参与者 {id} 不在 order 中`)
		end
		local state = participant.state
		if HAS_EPISODE[state] == nil then
			invariantError(`参与者 {id} 的状态非法：{state}`)
		end
		stateCounts[state] = (stateCounts[state] or 0) + 1
		if participant.version % 1 ~= 0 or participant.version < 0 then
			invariantError(`参与者 {id} 的 version 非法`)
		end
		local hasEpisode = HAS_EPISODE[state]
		if hasEpisode then
			if participant.episodeId == nil then
				invariantError(`{state} 参与者 {id} 缺少 episode`)
			end
			if participant.rootSeedId == nil then
				invariantError(`{state} 参与者 {id} 缺少 rootSeedId`)
			end
		else
			if participant.episodeId ~= nil then
				invariantError(`{state} 参与者 {id} 仍持有 episode`)
			end
			if participant.parentEpisodeId ~= nil or participant.rootSeedId ~= nil then
				invariantError(`{state} 参与者 {id} 仍残留感染树字段`)
			end
			if participant.isRoot or participant.seedId ~= nil then
				invariantError(`{state} 参与者 {id} 仍残留根标记`)
			end
			if participant.incubationEndsAt ~= nil or participant.unstableEndsAt ~= nil then
				invariantError(`{state} 参与者 {id} 仍残留计时器`)
			end
		end
		if state ~= State.HUMAN and participant.curedImmuneUntil ~= nil then
			invariantError(`非 HUMAN 参与者 {id} 仍持有治愈保护`)
		end
		if state == State.INCUBATING then
			if participant.incubationEndsAt == nil then
				invariantError(`尸变中参与者 {id} 缺少 incubationEndsAt`)
			end
			if participant.unstableEndsAt ~= nil then
				invariantError(`尸变中参与者 {id} 不应持有断联计时`)
			end
		elseif state == State.INFECTED then
			if participant.incubationEndsAt ~= nil or participant.unstableEndsAt ~= nil then
				invariantError(`稳定感染者 {id} 仍持有过渡/断联计时`)
			end
		elseif state == State.UNSTABLE then
			if participant.unstableEndsAt == nil then
				invariantError(`断联参与者 {id} 缺少 unstableEndsAt`)
			end
			if participant.incubationEndsAt ~= nil then
				invariantError(`断联参与者 {id} 不应持有尸变计时`)
			end
		end
		if participant.isRoot then
			if state ~= State.INCUBATING and state ~= State.INFECTED then
				invariantError(`零号 {id} 的状态非法：{state}`)
			end
			if participant.parentEpisodeId ~= nil then
				invariantError(`零号 {id} 不应有父节点`)
			end
			if participant.seedId == nil then
				invariantError(`零号 {id} 缺少 seedId`)
			end
			if participant.rootSeedId ~= participant.seedId then
				invariantError(`零号 {id} 的 rootSeedId 与 seedId 不一致`)
			end
		elseif hasEpisode then
			if participant.seedId ~= nil then
				invariantError(`非根参与者 {id} 不应持有 seedId`)
			end
			if participant.parentEpisodeId == nil then
				-- 只有断联的孤儿分支根可以没有父节点。
				if state ~= State.UNSTABLE then
					invariantError(`非根 {state} 参与者 {id} 缺少父节点`)
				end
			end
		end
	end

	if participantCount ~= recordCount then
		invariantError(`order 人数 {participantCount} 与参与者记录数 {recordCount} 不一致`)
	end

	local episodeCount = 0
	for episodeId, participantId in graph.episodeIndex do
		episodeCount += 1
		local participant = requireParticipant(graph, participantId, `episode {episodeId} 指向`)
		if participant.episodeId ~= episodeId then
			invariantError(`episode 索引不一致：{episodeId} / 参与者 {participantId}`)
		end
		if HAS_EPISODE[participant.state] ~= true then
			invariantError(`已恢复或离场的玩家 {participantId} 仍被 episode 索引引用`)
		end
	end
	for _, id in graph.order do
		local participant = graph.participants[id]
		if participant ~= nil and participant.episodeId ~= nil then
			if graph.episodeIndex[participant.episodeId] ~= id then
				invariantError(`参与者 {id} 的 episode 未登记在 episodeIndex`)
			end
			if HAS_EPISODE[participant.state] ~= true then
				invariantError(`参与者 {id} 的状态与 episode 不匹配`)
			end
		end
	end
	if episodeCount ~= (stateCounts.INCUBATING or 0) + (stateCounts.INFECTED or 0) + (stateCounts.UNSTABLE or 0) then
		invariantError(`episode 数量 {episodeCount} 与感染状态人数不一致`)
	end

	for parentNodeId, kids in graph.children do
		local parentIsVirtualRoot = graph.virtualRoots[parentNodeId] == true
		if parentIsVirtualRoot then
			if not isVirtualRootId(parentNodeId) then
				invariantError(`VirtualRoot 节点 id 非法：{parentNodeId}`)
			end
			local seedId = string.sub(parentNodeId, #VIRTUAL_ROOT_PREFIX + 1)
			if seedId == "" or not contains(graph.seeds, seedId) then
				invariantError(`VirtualRoot {parentNodeId} 的 seedId 不属于本局`)
			end
		else
			local parentParticipant = requireEpisodeParticipant(
				graph,
				parentNodeId,
				"children 的父节点既不是 episode 也不是 VirtualRoot"
			)
			if parentParticipant.state == State.INCUBATING then
				invariantError(`尸变中节点 {parentNodeId} 拥有子节点（不变量 9）`)
			end
			if parentParticipant.state ~= State.INFECTED and parentParticipant.state ~= State.UNSTABLE then
				invariantError(`父节点 {parentNodeId} 不是有效上游：{parentParticipant.state}`)
			end
		end
		local seenChild: { [string]: boolean } = {}
		for _, childEpisodeId in kids do
			if seenChild[childEpisodeId] == true then
				invariantError(`父节点 {parentNodeId} 重复引用子节点 {childEpisodeId}`)
			end
			seenChild[childEpisodeId] = true
			local childParticipant = requireEpisodeParticipant(
				graph,
				childEpisodeId,
				`父节点 {parentNodeId} 引用了不存在的子节点`
			)
			if childParticipant.parentEpisodeId ~= parentNodeId then
				invariantError(`父子双向索引不一致：{childEpisodeId} → {parentNodeId}`)
			end
			if parentIsVirtualRoot then
				if childParticipant.state ~= State.INFECTED and childParticipant.state ~= State.INCUBATING then
					invariantError(`VirtualRoot 下出现 {childParticipant.state} 子节点`)
				end
			else
				local parentParticipant = requireEpisodeParticipant(graph, parentNodeId, "children 的父节点")
				if parentParticipant.state == State.UNSTABLE and childParticipant.state ~= State.UNSTABLE then
					invariantError(`断联节点 {parentNodeId} 下仍有稳定后代 {childEpisodeId}`)
				end
				if parentParticipant.state == State.INFECTED and childParticipant.state == State.UNSTABLE then
					invariantError(`断联节点 {childEpisodeId} 仍挂在稳定上游 {parentNodeId} 下`)
				end
			end
		end
	end

	for _, id in graph.order do
		local participant = graph.participants[id]
		if participant ~= nil and participant.episodeId ~= nil then
			local parentNodeId = participant.parentEpisodeId
			if parentNodeId ~= nil then
				if parentNodeId == participant.episodeId then
					invariantError(`节点 {id} 自环`)
				end
				local kids = graph.children[parentNodeId]
				if kids == nil or not contains(kids, participant.episodeId) then
					invariantError(
						`子节点 {participant.episodeId} 未登记在父节点 {parentNodeId} 的 children 中`
					)
				end
				-- §11.1：同一次断链事件中的整支断联者共享同一个服务器截止时间。
				if participant.state == State.UNSTABLE then
					local parentParticipant = participantOfEpisode(graph, parentNodeId)
					if
						parentParticipant ~= nil
						and parentParticipant.state == State.UNSTABLE
						and parentParticipant.unstableEndsAt ~= participant.unstableEndsAt
					then
						invariantError(
							`同一断联分支的截止时间不一致：{id} / 上游 {parentParticipant.id}`
						)
					end
				end
			end
			local rootSeedId = participant.rootSeedId
			if rootSeedId == nil then
				invariantError(`节点 {id} 缺少 rootSeedId`)
			end
			local treeSeedId = rootSeedId :: string
			if not contains(graph.seeds, treeSeedId) then
				invariantError(`节点 {id} 的 rootSeedId 不属于本局`)
			end
			local visited: { [string]: boolean } = {}
			local currentNodeId: string? = participant.episodeId
			local steps = 0
			local limit = participantCount + #graph.seeds + 8
			local virtualRootSeedId: string? = nil
			while currentNodeId ~= nil do
				if visited[currentNodeId] == true then
					invariantError(`父子链成环：{currentNodeId}`)
				end
				visited[currentNodeId] = true
				steps += 1
				if steps > limit then
					invariantError(`父子链过长，疑似成环：{id}`)
				end
				if graph.virtualRoots[currentNodeId] == true then
					virtualRootSeedId = string.sub(currentNodeId, #VIRTUAL_ROOT_PREFIX + 1)
					currentNodeId = nil
				else
					local node = requireEpisodeParticipant(graph, currentNodeId, "父子链引用了不存在的节点")
					if node.rootSeedId ~= treeSeedId then
						invariantError(`同一棵树内 rootSeedId 不一致：{id} / 上游 {node.id}`)
					end
					currentNodeId = node.parentEpisodeId
				end
			end
			if virtualRootSeedId ~= nil and virtualRootSeedId ~= treeSeedId then
				invariantError(`VirtualRoot 的 seedId 与节点 {id} 的树不一致`)
			end
		end
	end

	for nodeId in graph.virtualRoots do
		if not isVirtualRootId(nodeId) then
			invariantError(`VirtualRoot 节点 id 非法：{nodeId}`)
		end
		local seedId = string.sub(nodeId, #VIRTUAL_ROOT_PREFIX + 1)
		if seedId == "" or not contains(graph.seeds, seedId) then
			invariantError(`VirtualRoot {nodeId} 的 seedId 不属于本局`)
		end
		if graph.episodeIndex[nodeId] ~= nil then
			invariantError(`VirtualRoot {nodeId} 与 episode 冲突`)
		end
	end

	local seedSeen: { [string]: boolean } = {}
	for _, seedId in graph.seeds do
		if seedSeen[seedId] == true then
			invariantError(`seedId 重复：{seedId}`)
		end
		seedSeen[seedId] = true
	end
	local rootBySeed: { [string]: string } = {}
	for _, id in graph.order do
		local participant = graph.participants[id]
		if participant ~= nil and participant.isRoot then
			local seedId = participant.seedId
			if seedId == nil then
				invariantError(`零号 {id} 缺少 seedId`)
			end
			local seedKey = seedId :: string
			if rootBySeed[seedKey] ~= nil then
				invariantError(`seedId {seedKey} 拥有多个零号`)
			end
			rootBySeed[seedKey] = id
		end
	end

	if graph.seq ~= #graph.events then
		invariantError(`seq {graph.seq} 与事件数 {#graph.events} 不一致`)
	end
	for index, event in graph.events do
		if event.seq ~= index then
			invariantError(`事件 seq 不连续：第 {index} 条为 {event.seq}`)
		end
	end

	return true
end

-- 从事件日志在全新图上重放，用于 G-17 确定性验证与崩溃恢复演练。
-- 日志中的 command 已去掉 expected* 防重参数（它们只影响提交时的合法性判断）。
function InfectionGraph.replay(config: Config, roundId: string, participantIds: { string }, events: { Event }): Graph
	local graph = InfectionGraph.new(config, roundId, participantIds)
	for _, event in events do
		local command = event.command
		local result: Result
		if command.name == "createRoot" then
			result = InfectionGraph.createRoot(graph, command.seedId, command.participantId, command.now)
		elseif command.name == "infect" then
			result = InfectionGraph.infect(graph, command.attackerId, command.targetId, command.now)
		elseif command.name == "tick" then
			result = InfectionGraph.tick(graph, command.now)
		elseif command.name == "cure" then
			result = InfectionGraph.cure(graph, command.actorId, command.targetId, command.now)
		elseif command.name == "relink" then
			result = InfectionGraph.relink(graph, command.unstableId, command.targetId, command.now)
		elseif command.name == "removeParticipant" then
			result = InfectionGraph.removeParticipant(graph, command.participantId, command.now)
		elseif command.name == "addLateJoiner" then
			result = InfectionGraph.addLateJoiner(graph, command.participantId, command.role, command.now)
		elseif command.name == "markExtracted" then
			result = InfectionGraph.markExtracted(graph, command.participantId)
		else
			error(`[InfectionGraph] 事件日志包含未知命令（seq={event.seq}）`, 0)
		end
		if not result.ok then
			error(`[InfectionGraph] 事件日志重放失败（seq={event.seq}, reason={result.reason or "?"}）`, 0)
		end
	end
	return graph
end

return table.freeze(InfectionGraph)
