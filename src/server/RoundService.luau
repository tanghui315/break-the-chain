--!strict
-- 回合循环（GDB V1.1 §5、§19.5、§20.4、§24.4）：CharacterAutoLoads 由本服务控制；
-- 每局冻结真人快照、Bot 补位到 6、启动 ChaseRound、广播公开事件、重生保持阵营、结算后清理。
-- A0 没有中途加入：回合进行中进来的真人观战到下一局。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)
local ChaseRound = require(script.Parent.logic.ChaseRound)
local MatchConfig = require(script.Parent.logic.MatchConfig)
local RateLimiter = require(script.Parent.logic.RateLimiter)
local Cleaner = require(script.Parent.util.Cleaner)
local GreyboxLayout = require(script.Parent.world.GreyboxLayout)
local BotService = require(script.Parent.BotService)
local CombatService = require(script.Parent.CombatService)
local MovementService = require(script.Parent.MovementService)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)

type Runtime = {
	round: ChaseRound.Round,
	cleaner: Cleaner.Cleaner,
	spawnIndex: { [string]: number },
	respawning: { [string]: boolean },
	resultShownAt: number?,
	lastTickAt: number,
	spawnCursor: number,
}

local RESULT_DISPLAY_SECONDS = 8
local TICK_INTERVAL = 0.1
local LOOP_WAIT_SECONDS = 0.05
local ACTIONS_PER_SECOND = 15
local MAX_ACTION_BYTES = 64

-- BalanceConfig 是 sealed 表，PlayerCountTiers 的元素类型与 MatchConfig 声明的子集在嵌套属性上不完全相等；
-- 在调用边界收窄一次（见 MatchConfig 头注释：该模块只声明自己用到的字段）。
local matchConfig: MatchConfig.Config = BalanceConfig :: any

local runtime: Runtime? = nil
local roundCounter = 0
local randomGenerator = Random.new()
local rateLimiter = RateLimiter.new(ACTIONS_PER_SECOND, ACTIONS_PER_SECOND)

local requestAction: RemoteEvent? = nil
local publicEvent: RemoteEvent? = nil
local privateEvent: RemoteEvent? = nil

local RoundService = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function spawnY(): number
	return GreyboxLayout.floorTopY + GreyboxLayout.characterSpawnY
end

local function humanCount(round: ChaseRound.Round): number
	local count = 0
	for _, id in round.order do
		local participant = round.participants[id]
		if participant ~= nil and participant.state == "HUMAN" then
			count += 1
		end
	end
	return count
end

local function displayNameFor(participantId: string): string
	local participant = ParticipantService.getById(participantId)
	if participant ~= nil then
		return participant.displayName
	end
	return participantId
end

local function broadcast(eventType: string, payload: { [string]: any })
	if publicEvent ~= nil then
		publicEvent:FireAllClients(eventType, payload)
	end
end

local function broadcastPhase(rt: Runtime)
	broadcast(PublicEventTypes.Public.RoundPhaseChanged, {
		phase = rt.round.phase,
		phaseEndsAt = rt.round.phaseEndsAt,
		humansLeft = humanCount(rt.round),
	})
end

-- 把 ChaseRound 的公开事件翻译成状态属性与网络广播。状态本身在应用事件时再计算。
local function applyEvents(rt: Runtime, events: ChaseRound.RoundEvents)
	local needPhaseSnapshot = false
	local needResult = false
	local phaseChanged = false

	for _, event in events.events do
		if event.type == ChaseRound.EventType.RoundPhaseChanged then
			needPhaseSnapshot = true
			phaseChanged = true
		elseif event.type == ChaseRound.EventType.RoundResult then
			needResult = true
		elseif
			event.type == ChaseRound.EventType.InfectionTurning
			or event.type == ChaseRound.EventType.InfectionRevealed
			or event.type == ChaseRound.EventType.OutbreakStarted
		then
			local participantId = event.participantId
			if participantId ~= nil then
				local state: "INCUBATING" | "INFECTED" = if event.type == ChaseRound.EventType.InfectionTurning
					then "INCUBATING"
					else "INFECTED"
				PlayerStateService.setState(participantId, state)
				broadcast(event.type, {
					participantId = participantId,
					displayName = displayNameFor(participantId),
				})
				needPhaseSnapshot = true
			end
		end
	end

	-- 状态变化会改变 humansLeft，因此在所有事件应用完之后再补一次阶段快照。
	if needPhaseSnapshot then
		broadcastPhase(rt)
	end
	if needResult then
		broadcast(PublicEventTypes.Public.RoundResult, { winner = rt.round.winner })
	end
	if phaseChanged and rt.round.phase == "RESULT" then
		rt.resultShownAt = nil
	end
end

local function pivotToSpawn(character: Model, spawnIndex: number)
	local points = GreyboxLayout.spawnPoints
	local point = points[((spawnIndex - 1) % #points) + 1]
	character:PivotTo(CFrame.new(Vector3.new(point.x, spawnY(), point.z)))
end

local function onCharacterAdded(rt: Runtime, participant: ParticipantService.Participant, character: Model)
	if runtime ~= rt then
		return
	end
	ParticipantService.setCharacter(participant.id, character)
	pivotToSpawn(character, rt.spawnIndex[participant.id] or 1)
	local record = PlayerStateService.get(participant.id)
	if record ~= nil then
		PlayerStateService.restore(record)
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
	if root ~= nil and root:IsA("BasePart") and root.Position.Y < GreyboxLayout.killPlaneY then
		return true
	end
	return false
end

local function respawnParticipant(rt: Runtime, participant: ParticipantService.Participant)
	if rt.respawning[participant.id] then
		return
	end
	rt.respawning[participant.id] = true

	if participant.kind == "Player" then
		local player = participant.player
		if player == nil then
			rt.respawning[participant.id] = nil
			return
		end

		-- 重生换下一个出生点，避免在同一个角落反复被堵。
		local currentIndex = rt.spawnIndex[participant.id] or 1
		rt.spawnIndex[participant.id] = (currentIndex % #GreyboxLayout.spawnPoints) + 1

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

local function checkRespawns(rt: Runtime)
	for _, participant in ParticipantService.all() do
		if not rt.respawning[participant.id] and characterNeedsRespawn(participant) then
			respawnParticipant(rt, participant)
		end
	end
end

local function hasRealParticipants(): boolean
	for _, participant in ParticipantService.all() do
		if participant.kind == "Player" and participant.player ~= nil then
			return true
		end
	end
	return false
end

-- 返回 true 表示本局彻底结束，主循环可以清理并开下一局。
local function tickRuntime(rt: Runtime): boolean
	local now = serverNow()

	if rt.round.phase == "RESULT" then
		local shownAt = rt.resultShownAt or now
		rt.resultShownAt = shownAt
		return now - shownAt >= RESULT_DISPLAY_SECONDS
	end

	if now - rt.lastTickAt >= TICK_INTERVAL then
		rt.lastTickAt = now

		CombatService.sample(now)
		MovementService.step(now)
		BotService.step(now)

		applyEvents(rt, ChaseRound.tick(rt.round, now))
		checkRespawns(rt)

		-- A0 没有中途加入：最后一名真人离开后不再让 Bot 单独跑完 3 分钟。
		if not hasRealParticipants() then
			return true
		end
	end

	return false
end

local function cleanupRound()
	local rt = runtime
	runtime = nil

	BotService.destroyAll()

	if rt ~= nil then
		for _, participant in ParticipantService.all() do
			if participant.kind == "Player" and participant.player ~= nil then
				local character = participant.player.Character
				if character ~= nil then
					character:SetAttribute(Constants.Attribute.State, nil)
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
	ParticipantService.reset()
	PlayerStateService.reset()
	MovementService.reset()
	BotService.reset()
	RateLimiter.reset(rateLimiter)

	local plan = MatchConfig.planRound(matchConfig, #snapshot)
	if plan == nil then
		return
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
	end

	local rt: Runtime = {
		round = ChaseRound.new(BalanceConfig, participantIds, roundId, serverNow(), function(count: number): number
			return randomGenerator:NextInteger(1, count)
		end),
		cleaner = Cleaner.new(),
		spawnIndex = {},
		respawning = {},
		resultShownAt = nil,
		lastTickAt = 0,
		spawnCursor = 0,
	}
	runtime = rt

	-- 真人出生点尽量互不重叠；Bot 在 BotService 内部使用自己的游标。
	for _, participant in liveParticipants do
		if participant.kind == "Player" then
			rt.spawnCursor = (rt.spawnCursor % #GreyboxLayout.spawnPoints) + 1
			rt.spawnIndex[participant.id] = rt.spawnCursor
		end
	end

	for _, participant in liveParticipants do
		local player = participant.player
		if participant.kind == "Player" and player ~= nil then
			local connection = player.CharacterAdded:Connect(function(character: Model)
				onCharacterAdded(rt, participant, character)
			end)
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
	end

	-- 私有事件：通知本人本局的 ParticipantId，客户端据此选择扑咬提示目标。
	for _, participant in liveParticipants do
		if participant.player ~= nil and privateEvent ~= nil then
			privateEvent:FireClient(participant.player, PublicEventTypes.Private.YouAre, {
				participantId = participant.id,
			})
		end
	end

	while not tickRuntime(rt) do
		task.wait(LOOP_WAIT_SECONDS)
	end
end

local function handlePlayerRemoving(player: Player)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end

	local id = participant.id
	RateLimiter.remove(rateLimiter, id)
	ParticipantService.remove(id)
	PlayerStateService.remove(id)

	local rt = runtime
	if rt ~= nil then
		rt.respawning[id] = nil
		rt.spawnIndex[id] = nil
		applyEvents(rt, ChaseRound.removeParticipant(rt.round, id, serverNow()))
	end
end

local function handleAction(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local action = payload.action
	if type(action) ~= "string" then
		return
	end

	local rt = runtime
	if rt == nil or rt.round.phase == "RESULT" then
		return
	end

	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end

	if not RateLimiter.allow(rateLimiter, participant.id, serverNow()) then
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
	end
	-- 其他动作名一律忽略（A0 不实现治愈/扫描/撤离等）
end

local function mainLoop()
	while true do
		local snapshot = ParticipantService.onlinePlayers()
		if #snapshot == 0 then
			cleanupRound()
			task.wait(1)
		else
			local ok, err = pcall(function()
				startRound(snapshot)
				return nil
			end)
			if not ok then
				warn(`[BreakTheChain] round error: {tostring(err)}`)
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

	CombatService.setBiteHandler(function(attackerId: string, targetId: string, biteNow: number)
		local rt = runtime
		if rt == nil then
			return
		end
		applyEvents(rt, ChaseRound.onBite(rt.round, attackerId, targetId, biteNow))
	end)

	if requestAction ~= nil then
		requestAction.OnServerEvent:Connect(handleAction)
	end
	Players.PlayerRemoving:Connect(handlePlayerRemoving)

	task.spawn(mainLoop)
	print(`[BreakTheChain] RoundService started; {BalanceConfig.Version}`)
end

return table.freeze(RoundService)
