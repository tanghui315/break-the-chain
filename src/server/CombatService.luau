--!strict
-- 扑咬的服务端边界（GDB V1.1 §9.2、§9.5、§20.4）：位置采样、目标解析、视线、延迟补偿与私有结果。
-- 纯判定全部走 logic/BiteRules；玩家与 Bot 走同一条 startBite / tryBite 路径。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)
local BiteRules = require(script.Parent.logic.BiteRules)
local PositionHistory = require(script.Parent.logic.PositionHistory)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)

export type BiteOutcome = {
	hit: boolean,
	reason: string,
	cooldownUntil: number?,
	nearMiss: boolean,
	distance: number?,
}

export type BiteResultPayload = {
	hit: boolean,
	reason: string,
	cooldownUntil: number?,
}

local MAP_FOLDER_NAME = "Map"

-- BalanceConfig 是 sealed 表且字段是 BiteRules.Config 的超集；在调用边界收窄一次（见 BiteRules 头注释）。
local biteConfig: BiteRules.Config = BalanceConfig :: any

local onBite: ((attackerId: string, targetId: string, now: number) -> ())? = nil
local privateEvent: RemoteEvent? = nil

local CombatService = {}

local function toVec3(v: Vector3): BiteRules.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function rootOf(participant: ParticipantService.Participant): BasePart?
	local character = participant.character
	if character == nil or character.Parent == nil then
		return nil
	end
	local part = character:FindFirstChild("HumanoidRootPart")
	if part ~= nil and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function isAlive(participant: ParticipantService.Participant): boolean
	local character = participant.character
	if character == nil or character.Parent == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false
	end
	return humanoid.Health > 0 and rootOf(participant) ~= nil
end

local function pingSeconds(participant: ParticipantService.Participant): number
	local player = participant.player
	if player == nil then
		return 0
	end
	local ok, value = pcall(function()
		return player:GetNetworkPing()
	end)
	if ok and type(value) == "number" then
		return value
	end
	return 0
end

local function privateRemote(): RemoteEvent
	local cached = privateEvent
	if cached ~= nil then
		return cached
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:WaitForChild("PrivatePlayerEvent") :: RemoteEvent
	privateEvent = remote
	return remote
end

local function fireBiteResult(player: Player, payload: BiteResultPayload)
	privateRemote():FireClient(player, PublicEventTypes.Private.BiteResult, payload)
end

-- 只检测静态地图的视线遮挡（§9.5）：射线只包含 workspace.Map，其他角色站在中间不算遮挡。
local function isLosBlocked(from: Vector3, to: Vector3): boolean
	local delta = to - from
	if delta.Magnitude < 0.01 then
		return false
	end
	local map = Workspace:FindFirstChild(MAP_FOLDER_NAME)
	if map == nil then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	return Workspace:Raycast(from, delta, params) ~= nil
end

-- 在水平面上找最近的人类目标。coneOnly = true 时同时要求位于扑咬锥内、可选范围限制内。
function CombatService.nearestHuman(
	attackerId: string,
	maxDistance: number,
	coneOnly: boolean
): ParticipantService.Participant?
	local attacker = ParticipantService.getById(attackerId)
	if attacker == nil then
		return nil
	end
	local attackerRoot = rootOf(attacker)
	if attackerRoot == nil then
		return nil
	end

	local origin = attackerRoot.Position
	local facing = attackerRoot.CFrame.LookVector

	local best: ParticipantService.Participant? = nil
	local bestDistance = math.huge
	for id, participant in ParticipantService.all() do
		if id ~= attackerId then
			local state = PlayerStateService.stateFor(id)
			local root = rootOf(participant)
			if state == "HUMAN" and root ~= nil then
				local delta = root.Position - origin
				local horizontal = Vector3.new(delta.X, 0, delta.Z)
				local distance = horizontal.Magnitude
				if distance <= maxDistance and distance < bestDistance then
					local flatFacing = Vector3.new(facing.X, 0, facing.Z)
					local inCone = distance < 0.01
						or (
							flatFacing.Magnitude > 0.01
							and flatFacing.Unit:Dot(horizontal.Unit)
								>= math.cos(math.rad(BalanceConfig.Greybox.BiteConeDegrees))
						)
					if inCone or not coneOnly then
						best = participant
						bestDistance = distance
					end
				end
			end
		end
	end
	return best
end

-- 目标解析：优先相信客户端/ Bot 的 targetId 提示，但只把它当作候选；非法提示回退到最近合法人类。
local function resolveTarget(
	attackerId: string,
	targetIdHint: string?
): (ParticipantService.Participant?, PlayerStateService.Record?, BasePart?)
	if targetIdHint ~= nil and targetIdHint ~= attackerId then
		local participant = ParticipantService.getById(targetIdHint)
		if participant ~= nil and PlayerStateService.stateFor(targetIdHint) == "HUMAN" then
			return participant, PlayerStateService.get(targetIdHint), rootOf(participant)
		end
	end

	local searchRadius = BalanceConfig.Greybox.BiteRange + 2 * BalanceConfig.Greybox.BiteTolerance
	local nearest = CombatService.nearestHuman(attackerId, searchRadius, true)
		or CombatService.nearestHuman(attackerId, searchRadius, false)
	if nearest == nil then
		return nil, nil, nil
	end
	return nearest, PlayerStateService.get(nearest.id), rootOf(nearest)
end

-- 客户端 / Bot 请求开始前摇。返回 (成功, 原因码)；冷却与状态校验全部在 BiteRules 内。
function CombatService.startBite(attackerId: string, now: number): (boolean, string)
	local participant = ParticipantService.getById(attackerId)
	local record = PlayerStateService.get(attackerId)
	if participant == nil or record == nil then
		return false, "NO_PARTICIPANT"
	end
	if not isAlive(participant) then
		return false, "NO_CHARACTER"
	end
	return BiteRules.startBite(biteConfig, record, now)
end

-- 提交一次扑咬。targetIdHint 只用于选择被检验的目标，几何/视线/回溯仍由服务端重新计算。
function CombatService.tryBite(attackerId: string, targetIdHint: string?, now: number): BiteOutcome?
	local attacker = ParticipantService.getById(attackerId)
	local attackerRecord = PlayerStateService.get(attackerId)
	if attacker == nil or attackerRecord == nil then
		return nil
	end
	local attackerRoot = rootOf(attacker)
	if attackerRoot == nil or not isAlive(attacker) then
		return nil
	end

	local target, targetRecord = resolveTarget(attackerId, targetIdHint)
	local ping = pingSeconds(attacker)

	local sampleTarget: (number) -> BiteRules.Vec3? = function(t: number): BiteRules.Vec3?
		if targetRecord == nil then
			return nil
		end
		return PositionHistory.sampleAt(targetRecord.history, t)
	end

	-- 视线检测与距离判定使用同一个回溯位置，避免高延迟下两者看的是不同的点。
	local losBlocked = false
	local rewind = math.clamp(ping, 0, BalanceConfig.Greybox.MaxRewindSeconds)
	local rewound = sampleTarget(now - rewind)
	if rewound ~= nil then
		local to = Vector3.new(rewound.x, attackerRoot.Position.Y, rewound.z)
		losBlocked = isLosBlocked(attackerRoot.Position, to)
	end

	local result = BiteRules.commitBite(biteConfig, {
		attacker = attackerRecord,
		attackerPos = toVec3(attackerRoot.Position),
		attackerFacing = toVec3(attackerRoot.CFrame.LookVector),
		now = now,
		attackerPingSeconds = ping,
		target = {
			id = if target ~= nil then target.id else "",
			state = if targetRecord ~= nil then targetRecord.state else "HUMAN",
			curedImmuneUntil = if targetRecord ~= nil then targetRecord.curedImmuneUntil else nil,
		},
		sampleTarget = sampleTarget,
		losBlocked = losBlocked,
	})

	if result.hit and target ~= nil and onBite ~= nil then
		onBite(attackerId, target.id, now)
	end

	if result.nearMiss then
		print(
			string.format(
				"[Telemetry] bite_near_miss attacker=%s target=%s distance=%s reason=%s rewindMax=%s",
				attackerId,
				if target ~= nil then target.id else "none",
				if result.distance ~= nil then string.format("%.2f", result.distance) else "n/a",
				result.reason,
				tostring(BalanceConfig.Greybox.MaxRewindSeconds)
			)
		)
	end

	return {
		hit = result.hit,
		reason = result.reason,
		cooldownUntil = attackerRecord.biteCooldownUntil,
		nearMiss = result.nearMiss,
		distance = result.distance,
	}
end

-- 20 Hz 位置历史采样。只在记录存在且角色有 HumanoidRootPart 时记录。
function CombatService.sample(now: number)
	local interval = 1 / BalanceConfig.Greybox.HistoryHz
	for id, record in PlayerStateService.records() do
		local participant = ParticipantService.getById(id)
		local root = if participant ~= nil then rootOf(participant) else nil
		if root ~= nil and now - record.lastHistoryAt >= interval then
			record.lastHistoryAt = now
			PositionHistory.record(record.history, now, toVec3(root.Position))
		end
	end
end

function CombatService.setBiteHandler(handler: (attackerId: string, targetId: string, now: number) -> ())
	onBite = handler
end

-- 真人 StartBite：结果用私有事件返回；cooldownUntil 使用服务端时间。
function CombatService.handleStartBite(player: Player)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local _, reason = CombatService.startBite(participant.id, now)
	local record = PlayerStateService.get(participant.id)
	fireBiteResult(player, {
		hit = false,
		reason = reason,
		cooldownUntil = if record ~= nil then record.biteCooldownUntil else nil,
	})
end

function CombatService.handleTryBite(player: Player, targetIdHint: string?)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local outcome = CombatService.tryBite(participant.id, targetIdHint, now)
	if outcome == nil then
		fireBiteResult(player, { hit = false, reason = "NO_CHARACTER", cooldownUntil = nil })
		return
	end

	fireBiteResult(player, {
		hit = outcome.hit,
		reason = outcome.reason,
		cooldownUntil = outcome.cooldownUntil,
	})
end

return table.freeze(CombatService)
