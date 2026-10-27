--!strict
-- 回合循环（GDB V1.1 §4.1、§5、§7、§10、§11、§13、§19.1–§19.5、§20.4、§21.2、§22.2）：
-- CharacterAutoLoads 由本服务控制；每局冻结真人快照、Bot 补位到 6、驱动 RoundStateMachine、
-- 把纯逻辑事件翻译成引擎状态与公开/私有消息、处理中途加入/退出、治愈/重连/撤离、结算与清理。
--
-- 权威划分：
--   - 感染身份、断链、治愈、重连、撤离计数与胜负：RoundStateMachine 及其纯逻辑模块；
--   - 战斗生命状态：ZombieCombatService；武器：WeaponService；解药外观：CureService；
--   - 本服务只读纯逻辑状态并写引擎表现，绝不绕过任何纯逻辑提交规则。
-- 秘密信息（感染树拓扑、扫描结果、重连目标 id）只存在服务端内存；公开事件只带公开字段（§17.2、§17.6）。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local InteractTarget = require(ReplicatedStorage.Shared.InteractTarget)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)
local ChannelTimer = require(script.Parent.logic.ChannelTimer)
local CureInventory = require(script.Parent.logic.CureInventory)
local InfectionGraph = require(script.Parent.logic.InfectionGraph)
local InteractPayload = require(script.Parent.logic.InteractPayload)
local MatchConfig = require(script.Parent.logic.MatchConfig)
local RateLimiter = require(script.Parent.logic.RateLimiter)
local RoundStateMachine = require(script.Parent.logic.RoundStateMachine)
local Cleaner = require(script.Parent.util.Cleaner)
local CharacterHider = require(script.Parent.util.CharacterHider)
local GreyboxBuilder = require(script.Parent.world.GreyboxBuilder)
local ActiveMap = require(script.Parent.world.ActiveMap)
local BotService = require(script.Parent.BotService)
local CombatService = require(script.Parent.CombatService)
local CureService = require(script.Parent.CureService)
local GrabService = require(script.Parent.GrabService)
local HiveService = require(script.Parent.HiveService)
local MovementService = require(script.Parent.MovementService)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)
local WeaponService = require(script.Parent.WeaponService)
local ZombieCombatService = require(script.Parent.ZombieCombatService)

type Runtime = {
	round: RoundStateMachine.Round,
	cleaner: Cleaner.Cleaner,
	plan: MatchConfig.RoundPlan,
	spawnIndex: { [string]: number },
	respawning: { [string]: boolean },
	resultShownAt: number?,
	lastTickAt: number,
	spawnCursor: number,
	-- MatchConfig.Tier 只声明对局规则子集；实际 tier 来自 BalanceConfig，含补给与复活档位。
	tier: any,
	suppliesStarted: boolean,
	-- 已应用到引擎的感染主状态（"NEW" 表示本局新加入、尚未应用）。
	states: { [string]: string },
	seedHistory: { [string]: boolean },
	firstInfectionLogged: boolean,
	lastRelinkHintAt: number,
	lastTreeSnapshotAt: number,
	-- 遭遇采样（地图可玩性对比）：每名人类最近一次“被丧尸近距离看到”的时间。
	hiveEnabled: boolean,
	lastEncounterSampleAt: number,
	lastEngagedAt: { [string]: number },
	firstEncounterLogged: boolean,
	lastInvariantAt: number,
	exitOpen: boolean,
	-- §22.2：本局公开 infected+unstable 峰值与参与者数（round_ended 埋点用）。
	infectionPeak: number,
	participantCount: number,
}

local RESULT_DISPLAY_SECONDS = 8
local TICK_INTERVAL = 0.1
local LOOP_WAIT_SECONDS = 0.05
local ACTIONS_PER_SECOND = 15
local MAX_ACTION_BYTES = 64
local RELINK_HINT_INTERVAL = 0.5
local TREE_SNAPSHOT_INTERVAL = 30
-- encounter_sample：CONTEST/EXTRACTION 期间每 5 秒采样一次；40 studs 内且 MapStatic 视线畅通算“遭遇”。
local ENCOUNTER_SAMPLE_INTERVAL = 5
local ENCOUNTER_RADIUS = 40
local INVARIANT_CHECK_INTERVAL = 1
-- §10.2：Bot 医疗兵可以看到几乎整张灰盒地图（SMALL 约 180×180），30 studs 太小导致守着解药不救。
local BOT_CURE_SEARCH_RADIUS = 150
local DEBUG_FORCE_BOT_FILL_ATTRIBUTE = "BTC_DebugForceBotFill"
-- Studio 专用：强制地图变体（"SMALL" / "MEDIUM"），用于同人数下对比两张图。
local DEBUG_MAP_VARIANT_ATTRIBUTE = "BTC_DebugMapVariant"
-- Studio 专用：打开母巢指挥（§6.4 EXP-09），用于 A/B 对比。
local DEBUG_HIVE_ATTRIBUTE = "BTC_DebugHive"

-- BalanceConfig 是 sealed 表，纯模块的 Config 只声明自己用到的字段；在调用边界收窄一次。
local roundConfig: RoundStateMachine.Config = BalanceConfig :: any
local matchConfig: MatchConfig.Config = BalanceConfig :: any

local runtime: Runtime? = nil
local roundCounter = 0
local randomGenerator = Random.new()
local rateLimiter = RateLimiter.new(ACTIONS_PER_SECOND, ACTIONS_PER_SECOND)
-- §6.1：上一局零号在本局被优先跳过；跨局保留，清理回合时不重置。
local previousSeedIds: { string } = {}
-- §4.1 / §5.2：上一局 RESULT 时刻；nil 表示服务器还没有跑过任何一局（需要 WAITING 大厅）。
local lastRoundEndedAt: number? = nil

local requestAction: RemoteEvent? = nil
local publicEvent: RemoteEvent? = nil
local privateEvent: RemoteEvent? = nil

local RoundService = {}

-- ---------------------------------------------------------------------------
-- 基础工具
-- ---------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local Phase = RoundStateMachine.Phase

local function telemetryValue(value: any): string
	local text = tostring(value)
	return (string.gsub(text, "%s+", "_"))
end

-- §22.2：埋点只留在服务端日志；允许包含拓扑摘要（永不发给客户端）。
-- 每条自动带 roundId / serverTimestamp / buildVersion，调用方只需补业务字段。
local function telemetry(eventName: string, fields: { [string]: any }?)
	local rt = runtime
	local merged: { [string]: any } = {
		roundId = if rt ~= nil then rt.round.roundId else "none",
		serverTimestamp = math.floor(serverNow() + 0.5),
		buildVersion = BalanceConfig.Version,
	}
	if fields ~= nil then
		for key, value in fields do
			merged[key] = value
		end
	end
	local parts: { string } = { "[Telemetry]", eventName }
	local keys: { string } = {}
	for key in merged do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(parts, `{key}={telemetryValue(merged[key])}`)
	end
	print(table.concat(parts, " "))
end

local function broadcast(eventType: string, payload: { [string]: any })
	local remote = publicEvent
	if remote ~= nil then
		remote:FireAllClients(eventType, payload)
	end
end

local function firePrivate(participantId: string, eventType: string, payload: { [string]: any })
	local remote = privateEvent
	if remote == nil then
		return
	end
	local participant = ParticipantService.getById(participantId)
	local player = if participant ~= nil then participant.player else nil
	if player ~= nil then
		remote:FireClient(player, eventType, payload)
	end
end

local function displayNameFor(participantId: string): string
	local participant = ParticipantService.getById(participantId)
	if participant ~= nil then
		return participant.displayName
	end
	return participantId
end

local function rootOf(participantId: string): BasePart?
	local participant = ParticipantService.getById(participantId)
	if participant == nil or participant.character == nil or participant.character.Parent == nil then
		return nil
	end
	local root = participant.character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function rootPositionOf(participantId: string): Vector3?
	local root = rootOf(participantId)
	if root == nil then
		return nil
	end
	return root.Position
end

local function horizontalDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function extractionCenter(): Vector3
	local center = ActiveMap.get().extractionZone.center
	return Vector3.new(center.x, ActiveMap.get().floorTopY, center.z)
end

local function pivotCharacter(character: Model, position: Vector3)
	character:PivotTo(CFrame.new(position))
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function humanSpawnPosition(index: number): Vector3
	local points = ActiveMap.get().spawnPoints
	local point = points[((index - 1) % #points) + 1]
	return Vector3.new(point.x, ActiveMap.get().floorTopY + ActiveMap.get().characterSpawnY, point.z)
end

local function infectionSpawnPosition(index: number): Vector3
	local points = ActiveMap.get().infectionZones
	local point = points[((index - 1) % #points) + 1]
	return Vector3.new(point.x, ActiveMap.get().floorTopY + ActiveMap.get().characterSpawnY, point.z)
end

-- 已撤离/观战者被搬到地图外的观战位置并隐藏（§13.2）。
local function spectatorPosition(): Vector3
	return Vector3.new(0, ActiveMap.get().floorTopY + ActiveMap.get().characterSpawnY, ActiveMap.get().mapSize / 2 + 40)
end

-- ---------------------------------------------------------------------------
-- 回合阶段与撤离视觉
-- ---------------------------------------------------------------------------

local function requiredExtracted(rt: Runtime): number
	-- §5.4：可达性修正后使用活的目标值；未修正时等于 plan.tier.requiredExtracted。
	return rt.round.requiredExtracted
end

local function phaseEndsAtFor(rt: Runtime): number?
	local current = rt.round.phase
	if current == Phase.PREPARE then
		return rt.round.phaseEndsAt
	elseif current == Phase.CONTEST then
		return rt.round.roundEndsAt - roundConfig.ExtractionWindowSeconds
	elseif current == Phase.EXTRACTION then
		return rt.round.roundEndsAt
	end
	return nil
end

local function setExitOpen(rt: Runtime, open: boolean)
	if rt.exitOpen == open then
		return
	end
	rt.exitOpen = open
	GreyboxBuilder.setExitOpen(open)
	local center = ActiveMap.get().extractionZone.center
	ZombieCombatService.setExtraction({ x = center.x, y = center.y, z = center.z }, open)
end

local function broadcastPhase(rt: Runtime)
	broadcast(PublicEventTypes.Public.RoundPhaseChanged, {
		phase = rt.round.phase,
		phaseEndsAt = phaseEndsAtFor(rt),
		extracted = rt.round.extractedCount,
		requiredExtracted = requiredExtracted(rt),
	})
end

-- ---------------------------------------------------------------------------
-- 世界状态 hooks（RoundStateMachine 只通过它们读引擎状态）
-- ---------------------------------------------------------------------------

local function inRange(a: string, b: string, range: number): boolean
	local pa = rootPositionOf(a)
	local pb = rootPositionOf(b)
	if pa == nil or pb == nil then
		return false
	end
	return horizontalDistance(pa, pb) <= range
end

local function isInExtractionZone(participantId: string): boolean
	local position = rootPositionOf(participantId)
	if position == nil then
		return false
	end
	return horizontalDistance(position, extractionCenter()) <= ActiveMap.get().extractionZone.diameter / 2
end

local function canCureTarget(targetId: string): boolean
	local combatState = ZombieCombatService.stateOf(targetId)
	return combatState == "ACTIVE" or combatState == "DOWNED"
end

local function canBeRelinkTarget(targetId: string): boolean
	return PlayerStateService.stateFor(targetId) == "INFECTED" and ZombieCombatService.stateOf(targetId) == "ACTIVE"
end

local function makeHooks(): RoundStateMachine.Hooks
	return {
		canCureTarget = canCureTarget,
		inRange = inRange,
		isInExtractionZone = isInExtractionZone,
		canBeRelinkTarget = canBeRelinkTarget,
		positionOf = function(participantId: string): unknown
			return rootPositionOf(participantId)
		end,
		-- §9A.3：断联丧尸倒地/死亡/电击中不能重连。
		canRelinkActor = function(actorId: string): boolean
			return ZombieCombatService.stateOf(actorId) == "ACTIVE"
		end,
		-- §13.2：被擒抱中的人类不能撤离。
		isGrabbed = function(actorId: string): boolean
			return GrabService.isGrabbed(actorId)
		end,
	}
end

-- ---------------------------------------------------------------------------
-- 目标选取（服务端权威；客户端只是同样的公开信息再选一次）
-- ---------------------------------------------------------------------------

local function relinkCandidates(rt: Runtime): { InteractTarget.Candidate }
	local candidates: { InteractTarget.Candidate } = {}
	for _, id in InfectionGraph.participantIds(rt.round.graph) do
		local state = InfectionGraph.getState(rt.round.graph, id)
		local position = rootPositionOf(id)
		if state ~= nil and position ~= nil then
			table.insert(candidates, {
				id = id,
				x = position.X,
				z = position.Z,
				eligible = state.state == "INFECTED" and canBeRelinkTarget(id),
				isRoot = state.isRoot,
			})
		end
	end
	return candidates
end

local function nearestRelinkTargetFor(rt: Runtime, participantId: string, range: number): InteractTarget.Selection
	local origin = rootPositionOf(participantId)
	if origin == nil then
		return { id = nil, distance = nil, rootBlocked = false }
	end
	return InteractTarget.selectNearest(relinkCandidates(rt), { x = origin.X, z = origin.Z }, range, true)
end

-- §10.2 医疗兵选目标：优先已倒地/被电击的感染者（bot 能安全靠近读条），
-- 其次才是最近的 ACTIVE 感染者；零号永远不进入候选（普通解药无效，且 isRoot 是公开信息）。
-- 只使用公开战斗状态（publicStateOf）与位置，不向 Bot 暴露感染树拓扑。
local function nearestCureTargetFor(rt: Runtime, participantId: string): string?
	local origin = rootPositionOf(participantId)
	if origin == nil then
		return nil
	end
	local now = serverNow()
	local originXZ = { x = origin.X, z = origin.Z }
	local candidates: { InteractTarget.Candidate } = {}
	local priorityCandidates: { InteractTarget.Candidate } = {}
	for _, id in InfectionGraph.participantIds(rt.round.graph) do
		local state = InfectionGraph.getState(rt.round.graph, id)
		local position = rootPositionOf(id)
		if state ~= nil and position ~= nil then
			local eligible = state.state == "INFECTED" and not state.isRoot and canCureTarget(id)
			local candidate: InteractTarget.Candidate = {
				id = id,
				x = position.X,
				z = position.Z,
				eligible = eligible,
				isRoot = state.isRoot,
			}
			table.insert(candidates, candidate)
			if eligible then
				local publicState = ZombieCombatService.publicStateOf(id, now)
				if publicState == "DOWNED" or publicState == "STUNNED" then
					table.insert(priorityCandidates, candidate)
				end
			end
		end
	end
	local priority = InteractTarget.selectNearest(priorityCandidates, originXZ, BOT_CURE_SEARCH_RADIUS, false)
	if priority.id ~= nil then
		return priority.id
	end
	return InteractTarget.selectNearest(candidates, originXZ, BOT_CURE_SEARCH_RADIUS, false).id
end

-- ---------------------------------------------------------------------------
-- 状态应用：把感染图主状态映射到引擎状态与公开属性
-- ---------------------------------------------------------------------------

local function respawnAtHumanSpawn(rt: Runtime, participantId: string): boolean
	local participant = ParticipantService.getById(participantId)
	if participant == nil or participant.character == nil then
		return false
	end
	local index = rt.spawnIndex[participantId]
	if index == nil then
		rt.spawnCursor = (rt.spawnCursor % #ActiveMap.get().spawnPoints) + 1
		index = rt.spawnCursor
		rt.spawnIndex[participantId] = index
	end
	pivotCharacter(participant.character, humanSpawnPosition(index))
	local record = PlayerStateService.get(participantId)
	if record ~= nil then
		PlayerStateService.applyVisual(record)
	end
	return true
end

local function hideOutOfPlay(participantId: string)
	local participant = ParticipantService.getById(participantId)
	if participant == nil or participant.character == nil then
		return
	end
	pivotCharacter(participant.character, spectatorPosition())
	CharacterHider.hide(participant.character)
	local record = PlayerStateService.get(participantId)
	if record ~= nil then
		PlayerStateService.applySpeed(record)
	end
end

local function transitionTo(
	rt: Runtime,
	participantId: string,
	previous: string,
	desired: string,
	participant: InfectionGraph.Participant,
	now: number
)
	if desired == "HUMAN" then
		if previous == "INFECTED" or previous == "UNSTABLE" then
			local wasDead = ZombieCombatService.isDead(participantId)
			-- 断联/治愈打断擒抱，避免双方在状态切换后保持冻结（§9A.6）。
			GrabService.removeParticipant(participantId)
			ZombieCombatService.remove(participantId, true)
			PlayerStateService.setState(participantId, "HUMAN")
			PlayerStateService.setRoot(participantId, false)
			WeaponService.resetForHuman(participantId)
			-- §9A.3：断联倒计时在死亡期间到期 → 直接以人类身份回到人类出生点。
			if wasDead then
				respawnAtHumanSpawn(rt, participantId)
			end
		elseif previous == "NEW" or previous == "INCUBATING" or previous == "EXTRACTED" or previous == "SPECTATOR" then
			PlayerStateService.setState(participantId, "HUMAN")
			PlayerStateService.setRoot(participantId, false)
			WeaponService.resetForHuman(participantId)
		end
	elseif desired == "INCUBATING" then
		PlayerStateService.setState(participantId, "INCUBATING")
		PlayerStateService.setRoot(participantId, participant.isRoot == true)
	elseif desired == "INFECTED" then
		if previous ~= "INFECTED" then
			PlayerStateService.setState(participantId, "INFECTED")
			ZombieCombatService.createFor(participantId, participant.isRoot == true, now)
			if previous ~= "UNSTABLE" then
				-- §9A.5：尸变过渡结束，手持枪械掉落；解药由 RoundStateMachine 在揭示时掉落。
				WeaponService.onInfected(participantId)
			end
		elseif ZombieCombatService.get(participantId) == nil then
			ZombieCombatService.createFor(participantId, participant.isRoot == true, now)
		end
		PlayerStateService.setRoot(participantId, participant.isRoot == true)
	elseif desired == "UNSTABLE" then
		if previous ~= "UNSTABLE" then
			PlayerStateService.setState(participantId, "UNSTABLE")
			ZombieCombatService.createFor(participantId, participant.isRoot == true, now)
			GrabService.removeParticipant(participantId)
		end
		PlayerStateService.setRoot(participantId, participant.isRoot == true)
	elseif desired == "EXTRACTED" then
		-- 解药是阵营共有的稀缺资源（§10.1）：撤离者不能把它带出局，放回医院补给点供其他人类拾取。
		if CureInventory.heldBy(rt.round.cures, participantId) ~= nil then
			CureInventory.drop(rt.round.cures, participantId, ActiveMap.get().cureSlots[1])
		end
		PlayerStateService.setState(participantId, "EXTRACTED")
		PlayerStateService.setRoot(participantId, false)
		-- §13.2：撤离成功立刻解除涉及此人的擒抱，避免丧尸保持冻结或人类被锁在原地。
		GrabService.removeParticipant(participantId)
		hideOutOfPlay(participantId)
	elseif desired == "SPECTATOR" then
		PlayerStateService.setState(participantId, "SPECTATOR")
		PlayerStateService.setRoot(participantId, false)
		hideOutOfPlay(participantId)
	end
end

-- 把引擎状态对齐到感染图的唯一权威状态。所有状态切换的副作用都在这里发生：
-- 战斗记录、掉落枪械、恢复人类装备、死亡中到期的人类复活、撤离隐藏。
local function reconcile(rt: Runtime, now: number)
	local graph = rt.round.graph
	local seen: { [string]: boolean } = {}
	local expired = 0

	for _, participantId in InfectionGraph.participantIds(graph) do
		local participant = InfectionGraph.getState(graph, participantId)
		if participant ~= nil then
			seen[participantId] = true
			local record = PlayerStateService.get(participantId)
			if record ~= nil then
				-- §10.3：治愈保护直接交给 BiteRules 的目标豁免字段。
				record.curedImmuneUntil = participant.curedImmuneUntil
			end

			local previous = rt.states[participantId] or "NEW"
			if previous ~= participant.state then
				if previous == "UNSTABLE" and participant.state == "HUMAN" then
					expired += 1
				end
				transitionTo(rt, participantId, previous, participant.state, participant, now)
				rt.states[participantId] = participant.state
			end

			if record ~= nil then
				PlayerStateService.publishProtection(record, now)
			end
		end
	end

	for participantId in rt.states do
		if not seen[participantId] then
			rt.states[participantId] = nil
		end
	end

	if expired > 0 then
		telemetry("unstable_expired", { recoveredCount = expired, disconnectReason = "TIMEOUT" })
	end
end

-- ---------------------------------------------------------------------------
-- 事件翻译
-- ---------------------------------------------------------------------------

local function captureSeedHistory(rt: Runtime)
	local seeds: { string } = {}
	for participantId in rt.seedHistory do
		table.insert(seeds, participantId)
	end
	table.sort(seeds)
	previousSeedIds = seeds
end

local function onPhaseChanged(rt: Runtime, event: RoundStateMachine.RoundEvent)
	local nextPhase = event.phase
	if nextPhase == nil then
		return
	end
	broadcastPhase(rt)

	if nextPhase == Phase.PREPARE then
		setExitOpen(rt, false)
	elseif nextPhase == Phase.CONTEST then
		if not rt.suppliesStarted then
			rt.suppliesStarted = true
			WeaponService.beginContest(rt.cleaner, rt.tier, function(count: number): number
				return randomGenerator:NextInteger(1, count)
			end)
		end
	elseif nextPhase == Phase.EXTRACTION then
		setExitOpen(rt, true)
	elseif nextPhase == Phase.RESULT then
		rt.resultShownAt = nil
		-- 回合结束时擒抱立即解除，避免双方在结算横幅期间保持冻结（§9A.6）。
		GrabService.clearAll()
		captureSeedHistory(rt)
	end
end

local function onPublicEvent(rt: Runtime, event: RoundStateMachine.RoundEvent, now: number)
	local eventType = event.type

	if eventType == RoundStateMachine.EventName.RoundPhaseChanged then
		onPhaseChanged(rt, event)
	elseif eventType == RoundStateMachine.EventName.OutbreakStarted then
		local participantIds: { string } = event.seedIds or {}
		for _, participantId in participantIds do
			rt.seedHistory[participantId] = true
		end
		broadcast(PublicEventTypes.Public.OutbreakStarted, { participantIds = participantIds })
	elseif
		eventType == RoundStateMachine.EventName.InfectionTurning
		or eventType == RoundStateMachine.EventName.InfectionRevealed
	then
		local participantId = event.participantId
		if participantId ~= nil then
			broadcast(eventType, {
				participantId = participantId,
				displayName = displayNameFor(participantId),
			})
			if eventType == RoundStateMachine.EventName.InfectionRevealed and not rt.firstInfectionLogged then
				rt.firstInfectionLogged = true
				telemetry("first_infection", {
					elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
					seedMethod = BalanceConfig.SeedMethod,
				})
			end
			if eventType == RoundStateMachine.EventName.InfectionRevealed then
				local participant = InfectionGraph.getState(rt.round.graph, participantId)
				telemetry("infection_revealed", {
					participantId = participantId,
					isRoot = participant ~= nil and participant.isRoot == true,
					elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
				})
			end
		end
	elseif eventType == RoundStateMachine.EventName.ChainCutNearby then
		local count = event.count or 0
		broadcast(PublicEventTypes.Public.ChainCutNearby, { count = count })
		telemetry("branch_disconnected", {
			affectedCount = count,
			elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
		})
	elseif eventType == RoundStateMachine.EventName.ExtractionOpened then
		setExitOpen(rt, true)
		broadcast(PublicEventTypes.Public.ExtractionOpened, {})
	elseif eventType == RoundStateMachine.EventName.BreachWarning then
		broadcast(PublicEventTypes.Public.BreachWarning, {
			outbreakAt = event.at,
		})
	elseif eventType == RoundStateMachine.EventName.ExtractionTargetAdjusted then
		broadcast(PublicEventTypes.Public.ExtractionTargetAdjusted, {
			requiredExtracted = event.requiredExtracted,
			extracted = rt.round.extractedCount,
		})
		telemetry("extraction_target_adjusted", {
			requiredExtracted = event.requiredExtracted or requiredExtracted(rt),
			extracted = rt.round.extractedCount,
			elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
		})
	elseif eventType == RoundStateMachine.EventName.Extracted then
		local participantId = event.participantId
		if participantId ~= nil then
			broadcast(PublicEventTypes.Public.Extracted, {
				participantId = participantId,
				displayName = displayNameFor(participantId),
				extracted = rt.round.extractedCount,
				requiredExtracted = requiredExtracted(rt),
			})
		end
		telemetry("extraction_progress", {
			escapedCount = rt.round.extractedCount,
			requiredCount = requiredExtracted(rt),
		})
	elseif eventType == RoundStateMachine.EventName.RoundResult then
		broadcast(PublicEventTypes.Public.RoundResult, {
			winner = event.winner or rt.round.winner,
			reason = event.reason,
		})
		telemetry("round_ended", {
			winner = event.winner or rt.round.winner,
			reason = event.reason or "NONE",
			duration = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
			N = rt.participantCount,
			infectionPeak = rt.infectionPeak,
		})
	end
end

local function onPrivateEvent(_rt: Runtime, event: RoundStateMachine.RoundEvent, now: number)
	local eventType = event.type
	-- CureChannelProgress 由 sendChannelProgress 统一以 ChannelProgress 发送；这里忽略纯逻辑的旧事件名。

	if eventType == RoundStateMachine.EventName.YouAreUnstable then
		local participantId = event.participantId
		if participantId ~= nil then
			firePrivate(participantId, PublicEventTypes.Private.YouAreUnstable, {
				unstableEndsAt = event.unstableEndsAt,
			})
		end
	elseif eventType == RoundStateMachine.EventName.ChannelCancelled then
		local participantId = event.actorId or event.participantId
		if participantId ~= nil then
			firePrivate(participantId, PublicEventTypes.Private.ChannelCancelled, {
				kind = event.channelKind,
				reason = event.reason,
			})
		end
	elseif eventType == RoundStateMachine.EventName.RelinkSucceeded then
		local participantId = event.participantId or event.actorId
		local count = event.count or 0
		if participantId ~= nil then
			firePrivate(participantId, PublicEventTypes.Private.RelinkSucceeded, { count = count })
		end
		-- §22.2：secondsLeft 是断联者本人 8 秒窗口剩余，而不是回合剩余。
		local windowLeft = 0
		if event.unstableEndsAt ~= nil then
			windowLeft = math.max(0, event.unstableEndsAt - now)
		end
		telemetry("relink_committed", {
			relinkedSubtreeCount = count,
			secondsLeft = string.format("%.1f", windowLeft),
		})
	elseif eventType == RoundStateMachine.EventName.Cured then
		local actorId = event.actorId
		local targetId = event.targetId
		if actorId ~= nil then
			firePrivate(actorId, PublicEventTypes.Private.Cured, { you = "CURER" })
		end
		if targetId ~= nil and targetId ~= actorId then
			firePrivate(targetId, PublicEventTypes.Private.Cured, { you = "CURED" })
		end
		telemetry("cure_committed", {
			actor = actorId or "none",
			target = targetId or "none",
			branchImpactBefore = event.affectedInfected or 0,
			unstableCount = event.affectedInfected or 0,
		})
		-- §22.7：倒地/电击中的目标被治愈时记录战斗状态（DOWNED/STUNNED 才有意义）。
		if targetId ~= nil then
			local combatState = ZombieCombatService.publicStateOf(targetId, now)
			if combatState == "DOWNED" or combatState == "STUNNED" then
				telemetry("downed_cured", {
					target = targetId,
					targetCombatState = combatState,
					branchImpactBefore = event.affectedInfected or 0,
				})
			end
		end
	elseif eventType == RoundStateMachine.EventName.YouAreSource then
		local participantId = event.participantId
		if participantId ~= nil then
			firePrivate(participantId, PublicEventTypes.Private.YouAreSource, {})
		end
	elseif eventType == RoundStateMachine.EventName.YouAreIncubating then
		local participantId = event.participantId
		if participantId ~= nil then
			firePrivate(participantId, PublicEventTypes.Private.YouAreIncubating, {
				incubationEndsAt = event.incubationEndsAt,
			})
		end
	elseif eventType == RoundStateMachine.EventName.Anomaly then
		telemetry("round_error", {
			invariantName = event.kind or "ANOMALY",
			severity = "high",
		})
	end
end

local function applyEvents(rt: Runtime, events: { RoundStateMachine.RoundEvent }, now: number)
	for _, event in events do
		if event.scope == RoundStateMachine.Scope.PUBLIC then
			onPublicEvent(rt, event, now)
		else
			onPrivateEvent(rt, event, now)
		end
	end
	reconcile(rt, now)
end

-- ---------------------------------------------------------------------------
-- 读条进度与重连方向提示（全部服务端计算）
-- ---------------------------------------------------------------------------

local function sendChannelProgress(rt: Runtime, now: number)
	for _, channel in ChannelTimer.active(rt.round.channels) do
		local progress = ChannelTimer.progress(rt.round.channels, channel.actorId, now)
		if progress ~= nil then
			firePrivate(progress.actorId, PublicEventTypes.Private.ChannelProgress, {
				kind = progress.kind,
				ratio = progress.ratio,
				elapsed = progress.elapsed,
				duration = progress.duration,
			})
		end
	end
end

local function sendRelinkHints(rt: Runtime, now: number)
	if now - rt.lastRelinkHintAt < RELINK_HINT_INTERVAL then
		return
	end
	rt.lastRelinkHintAt = now

	for _, participantId in InfectionGraph.participantIds(rt.round.graph) do
		local participant = InfectionGraph.getState(rt.round.graph, participantId)
		if participant ~= nil and participant.state == "UNSTABLE" then
			local origin = rootPositionOf(participantId)
			if origin ~= nil then
				local selection = nearestRelinkTargetFor(rt, participantId, math.huge)
				local direction = Vector3.zero
				local distance = -1
				if selection.id ~= nil then
					local targetPosition = rootPositionOf(selection.id)
					if targetPosition ~= nil then
						local delta = Vector3.new(targetPosition.X - origin.X, 0, targetPosition.Z - origin.Z)
						distance = delta.Magnitude
						if distance > 0.001 then
							direction = delta.Unit
						end
					end
				end
				-- §17.2：只发方向与距离，绝不发目标 id 或感染树关系。
				firePrivate(participantId, PublicEventTypes.Private.RelinkHint, {
					direction = direction,
					distance = distance,
				})
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- 服务端请求入口（真人动作与 Bot 共用，全部进入 RoundStateMachine）
-- ---------------------------------------------------------------------------

local function notifyChannelFailure(participantId: string, kind: string, reason: string)
	firePrivate(participantId, PublicEventTypes.Private.ChannelCancelled, {
		kind = kind,
		reason = reason,
	})
end

local function requestCureFor(rt: Runtime, actorId: string, targetId: string, now: number, notify: boolean): boolean
	local targetState = InfectionGraph.getState(rt.round.graph, targetId)
	if
		targetState ~= nil
		and not targetState.isRoot
		and not inRange(actorId, targetId, roundConfig.Greybox.CureRange)
	then
		if notify then
			notifyChannelFailure(actorId, "CURE", "OUT_OF_RANGE")
		end
		telemetry("cure_attempted", { actor = actorId, target = targetId, ok = false, reason = "OUT_OF_RANGE" })
		return false
	end

	local result = RoundStateMachine.requestCure(rt.round, actorId, targetId, now)
	telemetry("cure_attempted", {
		actor = actorId,
		target = targetId,
		ok = result.ok,
		reason = result.reason or "OK",
	})
	if result.ok then
		applyEvents(rt, result.events, now)
	elseif notify then
		notifyChannelFailure(actorId, "CURE", result.reason or "INVALID")
	end
	return result.ok
end

local function requestRelinkFor(
	rt: Runtime,
	unstableId: string,
	targetId: string,
	now: number,
	notify: boolean
): boolean
	-- §9A.3：断联丧尸被打死/倒地期间不能重连；倒计时照常走。
	if ZombieCombatService.stateOf(unstableId) ~= "ACTIVE" then
		if notify then
			notifyChannelFailure(unstableId, "RELINK", "NOT_ACTIVE")
		end
		return false
	end
	if not inRange(unstableId, targetId, roundConfig.Greybox.RelinkRange) then
		if notify then
			notifyChannelFailure(unstableId, "RELINK", "OUT_OF_RANGE")
		end
		return false
	end
	if not canBeRelinkTarget(targetId) then
		if notify then
			notifyChannelFailure(unstableId, "RELINK", "TARGET_INVALID")
		end
		return false
	end

	local result = RoundStateMachine.requestRelink(rt.round, unstableId, targetId, now)
	if result.ok then
		applyEvents(rt, result.events, now)
	elseif notify then
		notifyChannelFailure(unstableId, "RELINK", result.reason or "INVALID")
	end
	return result.ok
end

local function makeDirector(rt: Runtime): BotService.Director
	return {
		hasCure = function(participantId: string): boolean
			return CureInventory.heldBy(rt.round.cures, participantId) ~= nil
		end,
		nearestCureTarget = function(participantId: string): string?
			return nearestCureTargetFor(rt, participantId)
		end,
		nearestRelinkTarget = function(participantId: string): string?
			return nearestRelinkTargetFor(rt, participantId, math.huge).id
		end,
		nearestCurePickup = function(origin: Vector3, maxDistance: number): Vector3?
			return CureService.nearestPickupPosition(origin, maxDistance)
		end,
		requestCure = function(participantId: string, targetId: string): boolean
			if ChannelTimer.get(rt.round.channels, participantId) ~= nil then
				return false
			end
			return requestCureFor(rt, participantId, targetId, serverNow(), false)
		end,
		requestRelink = function(participantId: string, targetId: string): boolean
			if ChannelTimer.get(rt.round.channels, participantId) ~= nil then
				return false
			end
			return requestRelinkFor(rt, participantId, targetId, serverNow(), false)
		end,
		isChanneling = function(participantId: string): boolean
			return ChannelTimer.get(rt.round.channels, participantId) ~= nil
		end,
		extractionOpen = function(): boolean
			return rt.round.phase == Phase.EXTRACTION
		end,
		hiveEnabled = function(): boolean
			return HiveService.enabled()
		end,
		isRoot = function(participantId: string): boolean
			return HiveService.isRoot(participantId)
		end,
		requestRootMark = function(participantId: string): boolean
			return (HiveService.requestMark(participantId, serverNow(), false))
		end,
		requestRally = function(participantId: string): boolean
			return (HiveService.requestRally(participantId, serverNow(), false))
		end,
		isRallyChanneling = function(participantId: string): boolean
			return HiveService.isChanneling(participantId)
		end,
		markedTargetFor = function(participantId: string): string?
			return HiveService.markedTargetFor(participantId, serverNow())
		end,
	}
end

-- ---------------------------------------------------------------------------
-- 角色生成 / 重生
-- ---------------------------------------------------------------------------

local function positionForState(rt: Runtime, participantId: string): (Vector3, boolean)
	local state = rt.states[participantId] or "HUMAN"
	if state == "INFECTED" or state == "UNSTABLE" then
		return infectionSpawnPosition(rt.spawnIndex[participantId] or 1), false
	elseif state == "EXTRACTED" or state == "SPECTATOR" then
		return spectatorPosition(), true
	end
	return humanSpawnPosition(rt.spawnIndex[participantId] or 1), false
end

local function onCharacterAdded(rt: Runtime, participant: ParticipantService.Participant, character: Model)
	if runtime ~= rt then
		return
	end
	ParticipantService.setCharacter(participant.id, character)

	local position, hidden = positionForState(rt, participant.id)
	pivotCharacter(character, position)

	local record = PlayerStateService.get(participant.id)
	if record ~= nil then
		PlayerStateService.restore(record)
		if record.state == "HUMAN" then
			-- 重生 / 中途加入后恢复手持模型与武器状态（库存不变）。
			WeaponService.syncFor(participant.id)
		end
	end
	if hidden then
		CharacterHider.hide(character)
	end

	-- 角色重新生成会取消进行中的擒抱（§19.5：重置/掉出地图取消读条类状态）。
	GrabService.removeParticipant(participant.id)
	rt.respawning[participant.id] = nil
end

local function loadCharacter(rt: Runtime, participant: ParticipantService.Participant, onAdded: (Model) -> ())
	if participant.kind ~= "Player" or participant.player == nil then
		return
	end
	local player = participant.player
	local connection = player.CharacterAdded:Connect(onAdded)
	Cleaner.add(rt.cleaner, connection)

	rt.respawning[participant.id] = true
	local ok, err = pcall(function()
		player:LoadCharacterAsync()
	end)
	if not ok then
		warn(`[BreakTheChain] character load failed for {participant.id}: {tostring(err)}`)
	end
	rt.respawning[participant.id] = nil
end

local function characterNeedsRespawn(participant: ParticipantService.Participant): boolean
	local character = participant.character
	if character == nil or character.Parent == nil then
		return true
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return true
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") and root.Position.Y < ActiveMap.get().killPlaneY then
		return true
	end
	return false
end

local function respawnParticipant(rt: Runtime, participant: ParticipantService.Participant)
	if rt.respawning[participant.id] then
		return
	end
	rt.respawning[participant.id] = true
	GrabService.removeParticipant(participant.id)

	if participant.kind == "Player" then
		local player = participant.player
		if player == nil then
			rt.respawning[participant.id] = nil
			return
		end

		-- 重生换下一个出生点，避免在同一个角落反复被堵。
		local currentIndex = rt.spawnIndex[participant.id] or 1
		rt.spawnIndex[participant.id] = (currentIndex % #ActiveMap.get().spawnPoints) + 1

		task.spawn(function()
			local ok, err = pcall(function()
				player:LoadCharacterAsync()
			end)
			if not ok then
				warn(`[BreakTheChain] respawn failed for {participant.id}: {tostring(err)}`)
			end
			if runtime == rt then
				rt.respawning[participant.id] = nil
			end
		end)
		return
	end

	local model = BotService.respawn(participant)
	rt.respawning[participant.id] = nil
	if model ~= nil then
		local record = PlayerStateService.get(participant.id)
		if record ~= nil then
			PlayerStateService.restore(record)
		end
	end
end

local function checkRespawns(rt: Runtime, now: number)
	for _, participant in ParticipantService.all() do
		local state = rt.states[participant.id] or PlayerStateService.stateFor(participant.id)
		if state == "EXTRACTED" or state == "SPECTATOR" then
			-- 已撤离 / 观战：不参与重生，也不触发掉出地图处理。
			continue
		elseif state == "INFECTED" or state == "UNSTABLE" then
			-- 擒抱中的丧尸掉出地图时先解除擒抱，避免人类被永久冻结。
			if ZombieCombatService.isBelowKillPlane(participant.id) and GrabService.hasGrab(participant.id) then
				GrabService.breakOnZombieHit(participant.id, now, "FALL")
			end
			-- 丧尸掉出地图：DEAD 忽略、DOWNED 放回最后合法位置、ACTIVE 直接死亡走完整复活（§9A.3）。
			ZombieCombatService.handleFall(participant.id, now)
		elseif not rt.respawning[participant.id] and characterNeedsRespawn(participant) then
			respawnParticipant(rt, participant)
		end
	end
end

-- ---------------------------------------------------------------------------
-- 中途加入 / 退出
-- ---------------------------------------------------------------------------

local function rollbackParticipant(participantId: string)
	WeaponService.removeParticipant(participantId)
	PlayerStateService.remove(participantId)
	ParticipantService.remove(participantId)
end

local function handlePlayerAdded(player: Player)
	local rt = runtime
	if rt == nil or rt.round.phase == Phase.RESULT then
		return
	end
	if ParticipantService.getByPlayer(player) ~= nil then
		return
	end

	local participant = ParticipantService.registerPlayer(player)
	PlayerStateService.createFor(participant)
	WeaponService.createFor(participant.id)

	local now = serverNow()
	local result = RoundStateMachine.addLateJoiner(rt.round, participant.id, now)
	if not result.ok then
		rollbackParticipant(participant.id)
		return
	end

	rt.spawnCursor = (rt.spawnCursor % #ActiveMap.get().spawnPoints) + 1
	rt.spawnIndex[participant.id] = rt.spawnCursor
	reconcile(rt, now)

	local state = InfectionGraph.getState(rt.round.graph, participant.id)
	local joinedAs = if state ~= nil then state.state else "SPECTATOR"
	telemetry("late_join", {
		elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
		joinedAs = joinedAs,
	})

	loadCharacter(rt, participant, function(character: Model)
		onCharacterAdded(rt, participant, character)
	end)

	if privateEvent ~= nil then
		privateEvent:FireClient(player, PublicEventTypes.Private.YouAre, {
			participantId = participant.id,
		})
	end
end

local function handlePlayerRemoving(player: Player)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end

	local id = participant.id
	local leavingNow = serverNow()
	RateLimiter.remove(rateLimiter, id)

	local rt = runtime
	if rt ~= nil then
		local position: unknown = rootPositionOf(id)
		local exitState = InfectionGraph.getState(rt.round.graph, id)
		local result = RoundStateMachine.removeParticipant(rt.round, id, leavingNow, position)
		if result.ok then
			applyEvents(rt, result.events, leavingNow)
		end
		-- §22.2：中途退出时的身份与方式；EXTRACTED 玩家离场不算“流失”。
		telemetry("player_round_exit", {
			participantId = id,
			state = if exitState ~= nil then exitState.state else "UNKNOWN",
			elapsedSec = string.format("%.1f", math.max(0, leavingNow - rt.round.startedAt)),
			kind = participant.kind,
		})
		rt.states[id] = nil
		rt.spawnIndex[id] = nil
		rt.respawning[id] = nil
	end

	GrabService.removeParticipant(id)
	WeaponService.removeParticipant(id)
	ZombieCombatService.remove(id, false)
	ParticipantService.remove(id)
	PlayerStateService.remove(id)
end

-- ---------------------------------------------------------------------------
-- 回合调度
-- ---------------------------------------------------------------------------

local function hasRealParticipants(): boolean
	for _, participant in ParticipantService.all() do
		if participant.kind == "Player" and participant.player ~= nil then
			return true
		end
	end
	return false
end

type TreeStat = {
	nodeId: string,
	depth: number,
}

local function rootNodeOf(graph: InfectionGraph.Graph, seedId: string): string?
	for _, participant in graph.participants do
		if participant.isRoot and participant.seedId == seedId and participant.episodeId ~= nil then
			return participant.episodeId
		end
	end
	local virtualId = InfectionGraph.virtualRootId(seedId)
	if graph.virtualRoots[virtualId] == true then
		return virtualId
	end
	return nil
end

local function subtreeStats(graph: InfectionGraph.Graph, rootNode: string): (number, number)
	local count = 0
	local maxDepth = 0
	local stack: { TreeStat } = { { nodeId = rootNode, depth = 0 } }
	while #stack > 0 do
		local item = table.remove(stack)
		if item ~= nil then
			local children = graph.children[item.nodeId]
			if children ~= nil then
				for _, childId in children do
					count += 1
					maxDepth = math.max(maxDepth, item.depth + 1)
					table.insert(stack, { nodeId = childId, depth = item.depth + 1 })
				end
			end
		end
	end
	return count, maxDepth
end

-- §22.2 tree_shape_snapshot：每 30 秒一次，只在服务端日志里记录拓扑摘要。
local function printTreeSnapshot(rt: Runtime, now: number)
	local graph = rt.round.graph
	local counts = InfectionGraph.publicCounts(graph)
	local nodes = 0
	local maxDepth = 0
	for _, seedId in graph.seeds do
		local rootNode = rootNodeOf(graph, seedId)
		if rootNode ~= nil then
			local size, depth = subtreeStats(graph, rootNode)
			nodes += size
			maxDepth = math.max(maxDepth, depth)
		end
	end
	telemetry("tree_shape_snapshot", {
		infectedCount = counts.infected,
		unstableCount = counts.unstable,
		incubatingCount = counts.incubating,
		seeds = #graph.seeds,
		nodes = nodes,
		maxDepth = maxDepth,
		elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
	})
end

local encounterRayParams = RaycastParams.new()
encounterRayParams.FilterType = Enum.RaycastFilterType.Include

-- 只用地图几何判断遮挡：Include workspace.Map，角色与道具都不挡视线。
local function mapLineOfSight(from: Vector3, to: Vector3): boolean
	local map = Workspace:FindFirstChild("Map")
	if map == nil then
		return true
	end
	encounterRayParams.FilterDescendantsInstances = { map }
	local delta = to - from
	if delta.Magnitude < 0.01 then
		return true
	end
	return Workspace:Raycast(from, delta, encounterRayParams) == nil
end

-- 地图可玩性指标：人类多久遇不到丧尸（gap = 距上次遭遇的秒数）。只读，不影响规则。
local function sampleEncounters(rt: Runtime, now: number)
	local phase = rt.round.phase
	if phase ~= Phase.CONTEST and phase ~= Phase.EXTRACTION then
		return
	end
	local zombies: { Vector3 } = {}
	local humans: { { id: string, position: Vector3 } } = {}
	for _, id in InfectionGraph.participantIds(rt.round.graph) do
		local state = InfectionGraph.getState(rt.round.graph, id)
		local position = rootPositionOf(id)
		if state ~= nil and position ~= nil then
			if state.state == "INFECTED" and ZombieCombatService.canAct(id, now) then
				table.insert(zombies, position)
			elseif state.state == "HUMAN" or state.state == "INCUBATING" then
				table.insert(humans, { id = id, position = position })
			end
		end
	end
	if #humans == 0 then
		return
	end

	local engaged = 0
	local gapSum = 0
	local maxGap = 0
	local nearestSum = 0
	for _, human in humans do
		local nearest = math.huge
		local seen = false
		for _, zombie in zombies do
			local d = horizontalDistance(human.position, zombie)
			nearest = math.min(nearest, d)
			if d <= ENCOUNTER_RADIUS and not seen and mapLineOfSight(human.position, zombie) then
				seen = true
			end
		end
		local last = rt.lastEngagedAt[human.id]
		if seen then
			rt.lastEngagedAt[human.id] = now
			engaged += 1
		elseif last == nil then
			-- 从进入 CONTEST 后第一次采样开始计时。
			rt.lastEngagedAt[human.id] = now
		end
		local gap = now - (rt.lastEngagedAt[human.id] :: number)
		gapSum += gap
		maxGap = math.max(maxGap, gap)
		nearestSum += if nearest == math.huge then ActiveMap.get().mapSize else nearest
	end

	if engaged > 0 and not rt.firstEncounterLogged then
		rt.firstEncounterLogged = true
		telemetry("first_encounter", {
			elapsedSec = string.format("%.1f", now - rt.round.startedAt),
			map = ActiveMap.getVariant(),
		})
	end
	telemetry("encounter_sample", {
		map = ActiveMap.getVariant(),
		phase = phase,
		elapsedSec = string.format("%.0f", now - rt.round.startedAt),
		humans = #humans,
		zombies = #zombies,
		engaged = engaged,
		avgGap = string.format("%.1f", gapSum / #humans),
		maxGap = string.format("%.1f", maxGap),
		avgNearest = string.format("%.1f", nearestSum / #humans),
	})
end

-- 返回 true 表示本局彻底结束，主循环可以清理并开下一局。
local function tickRuntime(rt: Runtime): boolean
	local now = serverNow()

	if rt.round.phase == Phase.RESULT then
		local shownAt = rt.resultShownAt or now
		rt.resultShownAt = shownAt
		return now - shownAt >= RESULT_DISPLAY_SECONDS
	end

	if now - rt.lastTickAt >= TICK_INTERVAL then
		rt.lastTickAt = now

		CombatService.sample(now)
		local hooks = makeHooks()
		applyEvents(rt, RoundStateMachine.tick(rt.round, now, hooks).events, now)

		-- §22.2：公开 infected+unstable 峰值（round_ended 埋点用）。
		local counts = InfectionGraph.publicCounts(rt.round.graph)
		rt.infectionPeak = math.max(rt.infectionPeak, counts.infected + counts.unstable)

		for _, grab in GrabService.tick(now) do
			local result = RoundStateMachine.onBite(rt.round, grab.zombieId, grab.humanId, now)
			if result.ok then
				HiveService.onBite(grab.humanId, now)
				telemetry("bite_committed", {
					attacker = grab.zombieId,
					target = grab.humanId,
					elapsedSec = string.format("%.1f", math.max(0, now - rt.round.startedAt)),
				})
			end
			applyEvents(rt, result.events, now)
		end

		ZombieCombatService.step(now)
		HiveService.step(now)
		MovementService.step(now)
		WeaponService.step(now)
		CureService.step(now)
		BotService.step(now)
		checkRespawns(rt, now)
		sendChannelProgress(rt, now)
		sendRelinkHints(rt, now)

		if now - rt.lastEncounterSampleAt >= ENCOUNTER_SAMPLE_INTERVAL then
			rt.lastEncounterSampleAt = now
			sampleEncounters(rt, now)
		end

		if now - rt.lastTreeSnapshotAt >= TREE_SNAPSHOT_INTERVAL then
			rt.lastTreeSnapshotAt = now
			printTreeSnapshot(rt, now)
		end

		if now - rt.lastInvariantAt >= INVARIANT_CHECK_INTERVAL then
			rt.lastInvariantAt = now
			local ok, err = pcall(function()
				return InfectionGraph.assertInvariants(rt.round.graph)
			end)
			if not ok then
				telemetry("round_error", {
					invariantName = "TREE_INVARIANT",
					severity = "critical",
					detail = tostring(err),
				})
			end
		end

		-- 最后一名真人离开后不再让 Bot 单独跑完整局。
		if not hasRealParticipants() then
			return true
		end
	end

	return false
end

local function cleanupRound()
	local rt = runtime
	runtime = nil

	GrabService.reset()
	WeaponService.reset()
	HiveService.reset()
	ZombieCombatService.reset()
	CureService.reset()
	BotService.setDirector(nil)
	BotService.destroyAll()
	CharacterHider.restoreAll()
	GreyboxBuilder.setExitOpen(false)
	ZombieCombatService.setExtraction(nil, false)

	if rt ~= nil then
		for _, participant in ParticipantService.all() do
			if participant.kind == "Player" and participant.player ~= nil then
				local character = participant.player.Character
				if character ~= nil then
					character:SetAttribute(Constants.Attribute.State, nil)
					character:SetAttribute(Constants.Attribute.Combat, nil)
					character:SetAttribute(Constants.Attribute.Health, nil)
					character:SetAttribute(Constants.Attribute.RespawnAt, nil)
					character:SetAttribute(Constants.Attribute.Protected, nil)
					character:SetAttribute(Constants.Attribute.Root, nil)
					character:SetAttribute(Constants.Attribute.Grabbed, nil)
					character:SetAttribute(Constants.Attribute.Grabbing, nil)
				end
				participant.player:SetAttribute(Constants.Attribute.Stamina, nil)
			end
		end
		Cleaner.clean(rt.cleaner)
	end

	ParticipantService.reset()
	PlayerStateService.reset()
	MovementService.reset()
	BotService.reset()
	RateLimiter.reset(rateLimiter)
end

local function startRound(snapshot: { Player })
	GrabService.reset()
	WeaponService.reset()
	HiveService.reset()
	ZombieCombatService.reset()
	CureService.reset()
	ParticipantService.reset()
	PlayerStateService.reset()
	MovementService.reset()
	BotService.reset()
	RateLimiter.reset(rateLimiter)

	-- §20.9 DebugForceBotFill：仅 Studio 读取 ServerStorage 上的属性，把参与者补到该数量（例如 8 人做 D8 玩法验证）。
	local forceBotFill: number? = nil
	if RunService:IsStudio() then
		local value = game:GetService("ServerStorage"):GetAttribute(DEBUG_FORCE_BOT_FILL_ATTRIBUTE)
		if type(value) == "number" and value > 0 then
			forceBotFill = math.clamp(math.floor(value), 1, 24)
		end
	end
	local plan = MatchConfig.planRound(matchConfig, #snapshot, forceBotFill)
	if plan == nil then
		return
	end

	-- §14：按人数档的 mapTier 选图（8～15 人 → MEDIUM）；换图时在任何角色出生前重建 workspace.Map。
	local mapVariant: ActiveMap.Variant = ActiveMap.variantForTier(plan.tier.mapTier)
	if RunService:IsStudio() then
		local override: ActiveMap.Variant? =
			ActiveMap.parseVariant(game:GetService("ServerStorage"):GetAttribute(DEBUG_MAP_VARIANT_ATTRIBUTE))
		if override ~= nil then
			mapVariant = override
		end
	end
	if ActiveMap.set(mapVariant) then
		GreyboxBuilder.build()
	end

	roundCounter += 1
	local roundId = string.format("%d-%d", os.time(), roundCounter)

	local participants: { ParticipantService.Participant } = {}
	for _, player in snapshot do
		if player.Parent ~= nil then
			table.insert(participants, ParticipantService.registerPlayer(player))
		end
	end
	if #participants == 0 then
		return
	end

	-- Bot 从真人占用的出生点之后开始排，避免开局叠模型。
	for _, bot in BotService.createBots(plan.botCount, roundId, #participants) do
		table.insert(participants, bot)
	end

	-- 生成 Bot 期间可能有人离开：只保留仍在注册表中的参与者，避免幽灵玩家卡住回合。
	local liveParticipants: { ParticipantService.Participant } = {}
	local participantIds: { string } = {}
	for _, participant in participants do
		if ParticipantService.getById(participant.id) == participant then
			table.insert(liveParticipants, participant)
			table.insert(participantIds, participant.id)
		end
	end
	if #participantIds < 2 then
		return
	end

	for _, participant in liveParticipants do
		PlayerStateService.createFor(participant)
		WeaponService.createFor(participant.id)
	end

	local startedAt = serverNow()
	local machinePlan: RoundStateMachine.Plan = { tier = plan.tier :: any }
	local round = RoundStateMachine.new(
		roundConfig,
		machinePlan,
		participantIds,
		roundId,
		startedAt,
		function(count: number): number
			return randomGenerator:NextInteger(1, count)
		end,
		ActiveMap.get().cureSlots,
		previousSeedIds
	)

	local rt: Runtime = {
		round = round,
		cleaner = Cleaner.new(),
		plan = plan,
		spawnIndex = {},
		respawning = {},
		resultShownAt = nil,
		lastTickAt = 0,
		spawnCursor = 0,
		tier = plan.tier,
		suppliesStarted = false,
		states = {},
		seedHistory = {},
		firstInfectionLogged = false,
		lastRelinkHintAt = -math.huge,
		lastTreeSnapshotAt = startedAt,
		hiveEnabled = false,
		lastEncounterSampleAt = startedAt,
		lastEngagedAt = {},
		firstEncounterLogged = false,
		lastInvariantAt = startedAt,
		exitOpen = false,
		infectionPeak = 0,
		participantCount = #participantIds,
	}
	runtime = rt

	WeaponService.configureRound(rt.cleaner)
	ZombieCombatService.configure(rt.cleaner, startedAt, (plan.tier :: any).zombieRespawnSeconds)
	CureService.configure(rt.cleaner, round)
	-- §6.4 EXP-09：母巢指挥默认关闭；Studio 下可用 BTC_DebugHive 打开做 A/B。
	local hiveEnabled = BalanceConfig.HiveAbilitiesEnabled
	if RunService:IsStudio() and game:GetService("ServerStorage"):GetAttribute(DEBUG_HIVE_ATTRIBUTE) == true then
		hiveEnabled = true
	end
	rt.hiveEnabled = hiveEnabled
	Workspace:SetAttribute(Constants.Attribute.HiveEnabled, if hiveEnabled then true else nil)
	HiveService.begin({
		graph = round.graph,
		startedAt = startedAt,
		telemetry = telemetry,
		firePrivate = firePrivate,
		inActivePhase = function(): boolean
			return round.phase == Phase.CONTEST or round.phase == Phase.EXTRACTION
		end,
		activeExtractionCenter = function(): Vector3?
			return if round.phase == Phase.EXTRACTION then extractionCenter() else nil
		end,
	}, rt.cleaner, hiveEnabled)
	BotService.setDirector(makeDirector(rt))

	telemetry("round_started", {
		N = #participantIds,
		realCount = plan.realCount,
		botCount = plan.botCount,
		isPractice = plan.isPractice,
		seedCount = plan.tier.seedCount,
		roundDuration = plan.tier.roundSeconds,
		mapVariant = mapVariant,
		hive = rt.hiveEnabled,
		-- roundId/serverTimestamp/buildVersion 由 telemetry() 自动补齐
	})
	if plan.botCount > 0 then
		telemetry("bot_fill", { realCount = plan.realCount, botCount = plan.botCount })
	end

	-- 真人出生点尽量互不重叠；Bot 在 BotService 内部使用自己的游标。
	for _, participant in liveParticipants do
		if participant.kind == "Player" then
			rt.spawnCursor = (rt.spawnCursor % #ActiveMap.get().spawnPoints) + 1
			rt.spawnIndex[participant.id] = rt.spawnCursor
		end
	end

	for _, participant in liveParticipants do
		loadCharacter(rt, participant, function(character: Model)
			onCharacterAdded(rt, participant, character)
		end)
	end

	-- 私有事件：通知本人本局的 ParticipantId，客户端据此选择交互与扑咬提示目标。
	for _, participant in liveParticipants do
		if participant.player ~= nil and privateEvent ~= nil then
			privateEvent:FireClient(participant.player, PublicEventTypes.Private.YouAre, {
				participantId = participant.id,
			})
		end
	end

	broadcastPhase(rt)

	while not tickRuntime(rt) do
		task.wait(LOOP_WAIT_SECONDS)
	end
end

-- ---------------------------------------------------------------------------
-- 输入处理（§20.4：客户端只发意图）
-- ---------------------------------------------------------------------------

local function handleAction(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local action = payload.action
	if type(action) ~= "string" then
		return
	end

	local rt = runtime
	if rt == nil or rt.round.phase == Phase.RESULT then
		return
	end

	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end

	local now = serverNow()
	if not RateLimiter.allow(rateLimiter, participant.id, now) then
		return
	end

	if action == Constants.Action.StartBite then
		CombatService.handleStartBite(player)
	elseif action == Constants.Action.TryBite then
		local targetId = payload.targetId
		local hint: string? = nil
		if type(targetId) == "string" and #targetId <= MAX_ACTION_BYTES then
			hint = targetId
		end
		CombatService.handleTryBite(player, hint)
	elseif action == Constants.Action.SetSprint then
		local sprint = payload.sprint
		if type(sprint) == "boolean" then
			MovementService.setSprintIntent(participant.id, sprint)
		end
	elseif action == Constants.Action.Fire then
		if rt.round.phase == Phase.CONTEST or rt.round.phase == Phase.EXTRACTION then
			WeaponService.handleFire(player, payload, now)
		end
	elseif action == Constants.Action.Reload then
		if rt.round.phase == Phase.CONTEST or rt.round.phase == Phase.EXTRACTION then
			WeaponService.handleReload(player)
		end
	elseif action == Constants.Action.SelectWeapon then
		WeaponService.handleSelectWeapon(player, payload)
	elseif action == Constants.Action.StartCure then
		local validated = InteractPayload.validateTarget(payload, MAX_ACTION_BYTES)
		local targetId = validated.targetId
		if not validated.ok or targetId == nil then
			notifyChannelFailure(participant.id, "CURE", validated.reason or "INVALID")
			return
		end
		requestCureFor(rt, participant.id, targetId, now, true)
	elseif action == Constants.Action.TryRelink then
		local validated = InteractPayload.validateTarget(payload, MAX_ACTION_BYTES)
		local targetId = validated.targetId
		if not validated.ok or targetId == nil then
			notifyChannelFailure(participant.id, "RELINK", validated.reason or "INVALID")
			return
		end
		requestRelinkFor(rt, participant.id, targetId, now, true)
	elseif action == Constants.Action.RootMark then
		HiveService.requestMark(participant.id, now, true)
	elseif action == Constants.Action.RootRally then
		HiveService.requestRally(participant.id, now, true)
	elseif action == Constants.Action.CancelChannel then
		local result = RoundStateMachine.cancelChannel(rt.round, participant.id, now)
		if result.ok then
			applyEvents(rt, result.events, now)
		end
	end
end

-- ---------------------------------------------------------------------------
-- 启动与主循环
-- ---------------------------------------------------------------------------

-- §17.6 QA 方法：Studio 里输入 /btcleak 切换本人客户端的泄密审计（客户端 DebugAudit 读取该公开布尔）。
local function installDevLeakToggle()
	if not RunService:IsStudio() then
		return
	end
	local function hook(player: Player)
		player.Chatted:Connect(function(message: string)
			if message == "/btcleak" then
				local current = player:GetAttribute(Constants.Attribute.DebugLeakAudit) == true
				player:SetAttribute(Constants.Attribute.DebugLeakAudit, not current)
				print(`[BreakTheChain] leak audit {if current then "off" else "on"} for {player.Name}`)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)
end

-- Studio 试玩 QA：服务端专用 BindableFunction（ServerStorage 不复制给客户端），用来强制制造
-- Bot 局里很少自然出现的治愈 / 断联 / 重连 / 撤离场景。正式服不创建。
local function installDevHook()
	if not RunService:IsStudio() then
		return
	end
	local ServerStorage = game:GetService("ServerStorage")
	local hook = Instance.new("BindableFunction")
	hook.Name = "BTC_DevHook"

	local function freeze(participantId: string, on: boolean)
		local root = rootOf(participantId)
		if root ~= nil then
			root.Anchored = on
		end
	end

	local function placeNear(participantId: string, anchorId: string)
		local participant = ParticipantService.getById(participantId)
		local anchor = rootPositionOf(anchorId)
		if participant ~= nil and participant.character ~= nil and anchor ~= nil then
			pivotCharacter(participant.character, anchor + Vector3.new(2, 0, 0))
		end
	end

	local commands: { [string]: (rt: Runtime, now: number, a: any, b: any) -> any } = {
		dump = function(rt, now)
			local lines = {
				`phase={rt.round.phase} t={string.format("%.1f", now - rt.round.startedAt)}`
					.. ` roundLeft={string.format("%.1f", rt.round.roundEndsAt - now)} exitOpen={rt.exitOpen}`
					.. ` extracted={rt.round.extractedCount}/{requiredExtracted(rt)} map={ActiveMap.getVariant()}`
					.. ` hive={rt.hiveEnabled}`,
			}
			for _, id in InfectionGraph.participantIds(rt.round.graph) do
				local state = InfectionGraph.getState(rt.round.graph, id)
				local participant = ParticipantService.getById(id)
				if state ~= nil then
					table.insert(
						lines,
						`{id} {if participant then participant.kind else "?"} {state.state}`
							.. `{if state.isRoot then " ROOT" else ""} combat={ZombieCombatService.stateOf(id) or "-"}`
							.. ` cure={CureInventory.heldBy(rt.round.cures, id) or "-"}`
							.. `{if state.unstableEndsAt
								then ` unstableLeft={string.format("%.1f", state.unstableEndsAt - now)}`
								else ""}`
					)
				end
			end
			for _, itemId in rt.round.cures.order do
				local item = rt.round.cures.items[itemId]
				table.insert(lines, `cure {itemId} {item.state} {item.carrierId or ""}`)
			end
			return table.concat(lines, "\n")
		end,
		giveCure = function(rt, _now, participantId)
			for _, itemId in rt.round.cures.order do
				local item = rt.round.cures.items[itemId]
				if item.state == "SUPPLY" or item.state == "DROPPED" then
					local ok, reason = CureInventory.pickup(rt.round.cures, itemId, participantId)
					CureService.syncVisuals()
					return `{ok} {reason or itemId}`
				end
			end
			-- 灰盒每局只有 1 支：QA 时把已消耗的放回补给再发。
			for _, itemId in rt.round.cures.order do
				local item = rt.round.cures.items[itemId]
				if item.state == "CONSUMED" then
					item.state = "SUPPLY"
					local ok, reason = CureInventory.pickup(rt.round.cures, itemId, participantId)
					CureService.syncVisuals()
					return `{ok} {reason or itemId} (recycled)`
				end
			end
			return "false NO_FREE_CURE"
		end,
		freeze = function(_rt, _now, participantId, on)
			freeze(participantId, on == true)
			return "ok"
		end,
		placeNear = function(_rt, _now, participantId, anchorId)
			placeNear(participantId, anchorId)
			return "ok"
		end,
		cure = function(rt, now, actorId, targetId)
			placeNear(actorId, targetId)
			freeze(actorId, true)
			freeze(targetId, true)
			return tostring(requestCureFor(rt, actorId, targetId, now, true))
		end,
		relink = function(rt, now, unstableId, targetId)
			placeNear(unstableId, targetId)
			freeze(unstableId, true)
			freeze(targetId, true)
			return tostring(requestRelinkFor(rt, unstableId, targetId, now, true))
		end,
		infect = function(rt, now, attackerId, targetId)
			local result = RoundStateMachine.onBite(rt.round, attackerId, targetId, now)
			if result.ok then
				applyEvents(rt, result.events, now)
			end
			return `{result.ok} {result.reason or "OK"}`
		end,
		damage = function(_rt, now, participantId, amount)
			local result = ZombieCombatService.applyDamage(participantId, tonumber(amount) or 100, now)
			return if result ~= nil then `{result.reason} downed={result.downed} hp={result.health}` else "no zombie"
		end,
		stun = function(_rt, now, participantId)
			local ok, reason = ZombieCombatService.applyStun(participantId, now)
			return `{ok} {reason}`
		end,
		toExit = function(_rt, _now, participantId)
			local participant = ParticipantService.getById(participantId)
			if participant ~= nil and participant.character ~= nil then
				pivotCharacter(participant.character, extractionCenter())
			end
			return "ok"
		end,
		botFill = function(_rt, _now, count)
			-- 下一局生效；传 0 关闭。
			local value = tonumber(count) or 0
			ServerStorage:SetAttribute(DEBUG_FORCE_BOT_FILL_ATTRIBUTE, if value > 0 then value else nil)
			return `ok next round fill={value}`
		end,
		hive = function(_rt, _now, on)
			-- 下一局生效：true 打开母巢指挥（EXP-09 B 组），其他值关闭。
			ServerStorage:SetAttribute(DEBUG_HIVE_ATTRIBUTE, if on == true then true else nil)
			return `ok next round hive={on == true}`
		end,
		rootMark = function(_rt, now, rootId)
			local ok, reason = HiveService.requestMark(rootId, now, true)
			return `{ok} {reason}`
		end,
		rally = function(_rt, now, rootId)
			local ok, reason = HiveService.requestRally(rootId, now, true)
			return `{ok} {reason}`
		end,
		mapVariant = function(_rt, _now, value)
			-- 下一局生效；传 "SMALL" / "MEDIUM"，其他值清除覆盖（回到按人数档选图）。
			local variant = ActiveMap.parseVariant(value)
			ServerStorage:SetAttribute(DEBUG_MAP_VARIANT_ATTRIBUTE, variant)
			return `ok next round map={variant or "auto"}`
		end,
		roundLeft = function(rt, now, seconds)
			rt.round.roundEndsAt = now + (tonumber(seconds) or 0)
			return "ok"
		end,
	}

	hook.OnInvoke = function(name: string, a: any, b: any): any
		local rt = runtime
		local command = commands[name]
		if rt == nil or command == nil then
			return `no runtime or unknown command {name}`
		end
		local ok, result = pcall(command, rt, serverNow(), a, b)
		return if ok then result else `error: {tostring(result)}`
	end
	hook.Parent = ServerStorage
end

-- §4.1 / §5.2 / §20.9：服务器还没有任何一局时，先让玩家在 WAITING 大厅聚齐。
-- LobbyWaitSeconds 内继续吸纳新玩家；满 24 人提前开局。正式局之间（RESULT 之后）立即重开，
-- 不再插入等待。Studio 可用 ServerStorage.BTC_DebugLobbySeconds 缩短等待。
local function lobbyWait(): { Player }
	local waitSeconds = BalanceConfig.LobbyWaitSeconds
	if RunService:IsStudio() then
		local override = game:GetService("ServerStorage"):GetAttribute("BTC_DebugLobbySeconds")
		if type(override) == "number" and override >= 0 then
			waitSeconds = override
		end
	end
	if waitSeconds <= 0 then
		return ParticipantService.onlinePlayers()
	end

	local endsAt = serverNow() + waitSeconds
	broadcast(PublicEventTypes.Public.RoundPhaseChanged, {
		phase = "WAITING",
		phaseEndsAt = endsAt,
	})
	while serverNow() < endsAt do
		task.wait(0.5)
		local online = ParticipantService.onlinePlayers()
		if #online == 0 then
			-- 最后一名真人离开：放弃本次等待，回到主循环的空转分支。
			return online
		end
		if #online >= BalanceConfig.MaxPlayers then
			break
		end
	end
	return ParticipantService.onlinePlayers()
end

local function mainLoop()
	while true do
		local snapshot = ParticipantService.onlinePlayers()
		if #snapshot == 0 then
			-- 无人：清掉所有回合残留，并把 lastRoundEndedAt 置回“未开局”，
			-- 让下一位真人进来时重新进入 WAITING 大厅。
			lastRoundEndedAt = nil
			cleanupRound()
			task.wait(1)
		else
			if lastRoundEndedAt == nil then
				snapshot = lobbyWait()
			end
			if #snapshot > 0 then
				local ok, err = pcall(function()
					startRound(snapshot)
					return nil
				end)
				if not ok then
					telemetry("round_error", {
						invariantName = "ROUND_EXCEPTION",
						severity = "critical",
						detail = tostring(err),
					})
					warn(`[BreakTheChain] round error: {tostring(err)}`)
				end
				lastRoundEndedAt = serverNow()
			end
			cleanupRound()
			task.wait(1)
		end
	end
end

function RoundService.start()
	Players.CharacterAutoLoads = false

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	requestAction = remotes:WaitForChild("RequestAction") :: RemoteEvent
	publicEvent = remotes:WaitForChild("PublicMatchEvent") :: RemoteEvent
	privateEvent = remotes:WaitForChild("PrivatePlayerEvent") :: RemoteEvent

	ZombieCombatService.setRespawnOverride(HiveService.respawnPositionFor)
	CombatService.setBiteHandler(function(attackerId: string, targetId: string, biteNow: number)
		local rt = runtime
		if rt == nil then
			return
		end
		-- §9A.6：INSTANT 立即感染；GRAB 先进入 1 秒擒抱，完成时再走同一 RoundStateMachine.onBite。
		local result = GrabService.start(attackerId, targetId, biteNow)
		if result.infect then
			local bite = RoundStateMachine.onBite(rt.round, attackerId, targetId, biteNow)
			if bite.ok then
				HiveService.onBite(targetId, biteNow)
				telemetry("bite_committed", {
					attacker = attackerId,
					target = targetId,
					elapsedSec = string.format("%.1f", math.max(0, biteNow - rt.round.startedAt)),
				})
			end
			applyEvents(rt, bite.events, biteNow)
		end
	end)

	if requestAction ~= nil then
		requestAction.OnServerEvent:Connect(handleAction)
	end
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
	Players.PlayerAdded:Connect(handlePlayerAdded)
	installDevLeakToggle()
	installDevHook()

	task.spawn(mainLoop)
	print(`[BreakTheChain] RoundService started; {BalanceConfig.Version}`)
end

return table.freeze(RoundService)
