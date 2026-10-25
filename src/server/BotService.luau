--!strict
-- Bot 补位与灰盒行为（GDB V1.1 §20.9）。Bot 只认 ParticipantId，所有扑咬/冲刺都走与真人相同的服务端路径：
-- CombatService.startBite / tryBite 与 MovementService.setSprintIntent，绝不绕过 BiteRules 或 Stamina。
-- 行为保持简单：丧尸追可见人类并在范围内起咬；人类 Bot 见丧尸就沿路点逃并冲刺，否则在路点间游荡。

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local GreyboxLayout = require(script.Parent.world.GreyboxLayout)
local CombatService = require(script.Parent.CombatService)
local GrabService = require(script.Parent.GrabService)
local MovementService = require(script.Parent.MovementService)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)
local WeaponService = require(script.Parent.WeaponService)
local ZombieCombatService = require(script.Parent.ZombieCombatService)

type BotAI = {
	botIndex: number,
	waypointId: string?,
	nextThinkAt: number,
	biteTargetId: string?,
	windupEndsAt: number?,
	wanderAt: number,
	shootTargetId: string?,
	shootReadyAt: number,
}

local THINK_INTERVAL = 0.25
local WANDER_INTERVAL = 3
local THREAT_RADIUS = 40
local ZOMBIE_SIGHT_RADIUS = 80
local PICKUP_PATH_RADIUS = 80
local SHOOT_REACTION_SECONDS = 0.4
local MAP_COLLISION_GROUP = "MapStatic"

local ais: { [string]: BotAI } = {}
local spawnCursor = 0

local waypointById: { [string]: GreyboxLayout.Waypoint } = {}
local adjacency: { [string]: { string } } = {}
for _, waypoint in GreyboxLayout.waypoints do
	waypointById[waypoint.id] = waypoint
	adjacency[waypoint.id] = {}
end
for _, edge in GreyboxLayout.edges do
	table.insert(adjacency[edge.a], edge.b)
	table.insert(adjacency[edge.b], edge.a)
end

local BotService = {}

local function rootOf(participant: ParticipantService.Participant): BasePart?
	local character = participant.character
	if character == nil or character.Parent == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function humanoidOf(participant: ParticipantService.Participant): Humanoid?
	local character = participant.character
	if character == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function headOf(participant: ParticipantService.Participant): BasePart?
	local character = participant.character
	if character == nil then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head ~= nil and head:IsA("BasePart") then
		return head
	end
	return nil
end

local function isActiveZombie(id: string, now: number): boolean
	return PlayerStateService.stateFor(id) == "INFECTED" and ZombieCombatService.canAct(id, now)
end

local function isHittableZombie(id: string, now: number): boolean
	return PlayerStateService.stateFor(id) == "INFECTED" and ZombieCombatService.canBeHit(id, now)
end

local function spawnPosition(spawnIndex: number): Vector3
	local points = GreyboxLayout.spawnPoints
	local point = points[((spawnIndex - 1) % #points) + 1]
	return Vector3.new(point.x, GreyboxLayout.floorTopY + GreyboxLayout.characterSpawnY, point.z)
end

local function hasLineOfSight(observer: Model?, target: Model?, from: Vector3, to: Vector3): boolean
	local delta = to - from
	if delta.Magnitude < 0.01 then
		return true
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if observer ~= nil then
		table.insert(ignore, observer)
	end
	if target ~= nil then
		table.insert(ignore, target)
	end
	params.FilterDescendantsInstances = ignore
	params.CollisionGroup = MAP_COLLISION_GROUP
	return Workspace:Raycast(from, delta, params) == nil
end

local function createCharacter(
	participant: ParticipantService.Participant,
	botIndex: number,
	spawnIndex: number
): Model?
	local description = Instance.new("HumanoidDescription")
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	description:Destroy()
	if not ok or model == nil then
		warn(`[BreakTheChain] bot character creation failed: {tostring(model)}`)
		return nil
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		model:Destroy()
		return nil
	end

	model.Name = participant.id
	model.PrimaryPart = root
	humanoid.DisplayName = string.format("Bot %d", botIndex)
	model.Parent = Workspace

	ParticipantService.setCharacter(participant.id, model)
	model:PivotTo(CFrame.new(spawnPosition(spawnIndex)))

	local record = PlayerStateService.get(participant.id)
	if record ~= nil then
		PlayerStateService.restore(record)
	end
	return model
end

function BotService.reset()
	table.clear(ais)
	spawnCursor = 0
end

-- 注册并生成 Bot。spawnOffset 为真人已占用的出生点数量，避免 Bot 与真人叠在同一点。
-- 返回成功创建的 Participant 列表；失败的不进入本局。
function BotService.createBots(count: number, roundId: string, spawnOffset: number): { ParticipantService.Participant }
	local created: { ParticipantService.Participant } = {}
	spawnCursor = spawnOffset % #GreyboxLayout.spawnPoints
	for botIndex = 1, count do
		local id = ParticipantService.botId(botIndex, roundId)
		local participant = ParticipantService.registerBot(botIndex, id)
		spawnCursor = (spawnCursor % #GreyboxLayout.spawnPoints) + 1
		local model = createCharacter(participant, botIndex, spawnCursor)
		if model ~= nil then
			ais[id] = {
				botIndex = botIndex,
				waypointId = nil,
				nextThinkAt = 0,
				biteTargetId = nil,
				windupEndsAt = nil,
				wanderAt = 0,
				shootTargetId = nil,
				shootReadyAt = 0,
			}
			table.insert(created, participant)
		else
			ParticipantService.remove(id)
			PlayerStateService.remove(id)
		end
	end
	return created
end

-- 掉出地图 / 死亡后用相同 ParticipantId 重建角色，阵营与耐力记录保持不变（§19.5）。
function BotService.respawn(participant: ParticipantService.Participant): Model?
	local ai = ais[participant.id]
	local botIndex = if ai ~= nil then ai.botIndex else 1

	local old = participant.character
	if old ~= nil then
		old:Destroy()
	end

	spawnCursor = (spawnCursor % #GreyboxLayout.spawnPoints) + 1
	local model = createCharacter(participant, botIndex, spawnCursor)
	if model ~= nil and ai ~= nil then
		ai.waypointId = nil
		ai.biteTargetId = nil
		ai.windupEndsAt = nil
		ai.nextThinkAt = 0
		ai.shootTargetId = nil
		ai.shootReadyAt = 0
	end
	return model
end

function BotService.destroyAll()
	local botIds: { string } = {}
	for id, participant in ParticipantService.all() do
		if participant.kind == "Bot" then
			table.insert(botIds, id)
		end
	end

	for _, id in botIds do
		local participant = ParticipantService.getById(id)
		if participant ~= nil and participant.character ~= nil then
			participant.character:Destroy()
		end
		ParticipantService.remove(id)
		PlayerStateService.remove(id)
		ais[id] = nil
	end
	table.clear(ais)
end

local function nearestWaypoint(position: Vector3): string?
	local bestId: string? = nil
	local bestDistance = math.huge
	for id, waypoint in waypointById do
		local dx = waypoint.position.x - position.X
		local dz = waypoint.position.z - position.Z
		local distance = dx * dx + dz * dz
		if distance < bestDistance then
			bestDistance = distance
			bestId = id
		end
	end
	return bestId
end

local function moveToWaypoint(participant: ParticipantService.Participant, ai: BotAI, waypointId: string)
	local waypoint = waypointById[waypointId]
	local humanoid = humanoidOf(participant)
	if waypoint == nil or humanoid == nil then
		return
	end
	ai.waypointId = waypointId
	humanoid:MoveTo(Vector3.new(waypoint.position.x, waypoint.position.y, waypoint.position.z))
end

-- 丧尸：找人 → 追到判定距离内 → 起前摇 → 前摇结束冲刺并提交（与真人同一 tryBite）。
local function stepZombie(id: string, participant: ParticipantService.Participant, ai: BotAI, now: number)
	local root = rootOf(participant)
	if root == nil then
		return
	end

	-- §9A.3 / §9A.6：倒地/电击/死亡/擒抱中的 Bot 丧尸完全不动，也不保留前摇。
	if not ZombieCombatService.canAct(id, now) or GrabService.isGrabbed(id) then
		ai.windupEndsAt = nil
		ai.biteTargetId = nil
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		return
	end

	-- 前摇到期：短冲刺后提交，不等待下一次思考 tick。
	if ai.windupEndsAt ~= nil then
		if now >= ai.windupEndsAt then
			local targetId = ai.biteTargetId
			ai.windupEndsAt = nil
			ai.biteTargetId = nil

			if targetId ~= nil then
				local target = ParticipantService.getById(targetId)
				local targetRoot = if target ~= nil then rootOf(target) else nil
				if targetRoot ~= nil then
					local delta = targetRoot.Position - root.Position
					local horizontal = Vector3.new(delta.X, 0, delta.Z)
					if horizontal.Magnitude > 0.01 then
						root.AssemblyLinearVelocity = horizontal.Unit
							* (BalanceConfig.Greybox.LungeDistance / BalanceConfig.Greybox.LungeSeconds)
					end
				end
				CombatService.tryBite(id, targetId, now)
			end
			ai.nextThinkAt = now + THINK_INTERVAL
		end
		return
	end

	if now < ai.nextThinkAt then
		return
	end
	ai.nextThinkAt = now + THINK_INTERVAL

	local origin = root.Position
	local best: ParticipantService.Participant? = nil
	local bestDistance = math.huge
	for otherId, other in ParticipantService.all() do
		if otherId ~= id and PlayerStateService.stateFor(otherId) == "HUMAN" then
			local otherRoot = rootOf(other)
			if otherRoot ~= nil then
				local delta = otherRoot.Position - origin
				local horizontal = Vector3.new(delta.X, 0, delta.Z)
				local distance = horizontal.Magnitude
				if
					distance <= ZOMBIE_SIGHT_RADIUS
					and distance < bestDistance
					and hasLineOfSight(participant.character, other.character, origin, otherRoot.Position)
				then
					best = other
					bestDistance = distance
				end
			end
		end
	end

	if best == nil then
		-- 没看见人时沿路点游荡，避免全部 Bot 挤在出生点
		local humanoid = humanoidOf(participant)
		if humanoid ~= nil and now >= ai.wanderAt then
			ai.wanderAt = now + WANDER_INTERVAL
			local current = nearestWaypoint(origin)
			local options: { string } = {}
			if current ~= nil then
				options = adjacency[current]
			end
			if #options > 0 then
				moveToWaypoint(participant, ai, options[math.random(#options)])
			end
		end
		return
	end

	local biteReach = BalanceConfig.Greybox.BiteRange + BalanceConfig.Greybox.LungeDistance
	if bestDistance <= biteReach then
		local record = PlayerStateService.get(id)
		local cooldownUntil = if record ~= nil then record.biteCooldownUntil else nil
		if cooldownUntil ~= nil and now < cooldownUntil then
			return
		end

		local started = CombatService.startBite(id, now)
		if started then
			ai.biteTargetId = best.id
			ai.windupEndsAt = now + BalanceConfig.BiteWindupSeconds
		end
		return
	end

	local humanoid = humanoidOf(participant)
	local bestRoot = rootOf(best)
	if humanoid ~= nil and bestRoot ~= nil then
		humanoid:MoveTo(bestRoot.Position)
	end
end

-- 人类 / 尸变中 Bot：有枪打最近的可见 ACTIVE 丧尸，近战打断前摇/擒抱；有丧尸就逃离，
-- 没枪且附近没有丧尸时走向附近补给点；否则在路点间慢慢游荡（§9A.4、§9A.5）。
local function stepHuman(id: string, participant: ParticipantService.Participant, ai: BotAI, now: number)
	local root = rootOf(participant)
	local humanoid = humanoidOf(participant)
	local record = PlayerStateService.get(id)
	if root == nil or humanoid == nil or record == nil then
		return
	end

	if GrabService.isGrabbed(id) then
		MovementService.setSprintIntent(id, false)
		humanoid:Move(Vector3.zero, false)
		return
	end

	if now < ai.nextThinkAt then
		return
	end
	ai.nextThinkAt = now + THINK_INTERVAL

	local origin = root.Position
	local head = headOf(participant)
	local humanActions = record.state == "HUMAN"
	if humanActions then
		WeaponService.reloadBotIfEmpty(id, now)
	end

	local threatPosition: Vector3? = nil
	local nearbyZombie = false
	local shootTarget: ParticipantService.Participant? = nil
	local shootDistance = math.huge
	local meleeTarget: ParticipantService.Participant? = nil
	local meleeDistance = math.huge
	local pistolRange = BalanceConfig.Weapons.Pistol.Range
	local meleeRange = BalanceConfig.Weapons.Melee.Range
	local hasPistol = humanActions and WeaponService.hasPistol(id)

	for otherId, other in ParticipantService.all() do
		if otherId ~= id and PlayerStateService.stateFor(otherId) == "INFECTED" then
			local otherRoot = rootOf(other)
			if otherRoot ~= nil then
				local delta = otherRoot.Position - origin
				local horizontal = Vector3.new(delta.X, 0, delta.Z)
				local distance = horizontal.Magnitude
				local active = isActiveZombie(otherId, now)
				if active and distance <= THREAT_RADIUS then
					nearbyZombie = true
					if threatPosition == nil then
						threatPosition = otherRoot.Position
					end
				end

				-- 射击目标按“可命中”而不是“可行动”筛选：电击中的丧尸仍是 ACTIVE，可以继续被打。
				if
					hasPistol
					and head ~= nil
					and distance <= pistolRange
					and distance < shootDistance
					and isHittableZombie(otherId, now)
				then
					if hasLineOfSight(participant.character, other.character, head.Position, otherRoot.Position) then
						shootTarget = other
						shootDistance = distance
					end
				end

				local grabTarget = GrabService.grabTargetOf(otherId)
				local dangerous = active
					and (ZombieCombatService.hasWindup(otherId) or (grabTarget ~= nil and grabTarget ~= id))
				local headDistance = if head ~= nil then (otherRoot.Position - head.Position).Magnitude else distance
				if humanActions and dangerous and headDistance <= meleeRange and headDistance < meleeDistance then
					meleeTarget = other
					meleeDistance = headDistance
				end
			end
		end
	end

	-- 近战优先：前摇或擒抱中的丧尸值得立刻打断，哪怕 Bot 手上还有手枪。
	if meleeTarget ~= nil and head ~= nil then
		local zombieRoot = rootOf(meleeTarget)
		if zombieRoot ~= nil then
			WeaponService.fireBot(id, "Melee", head.Position, zombieRoot.Position - head.Position, now)
		end
	end

	if shootTarget ~= nil and head ~= nil then
		if ai.shootTargetId ~= shootTarget.id then
			ai.shootTargetId = shootTarget.id
			ai.shootReadyAt = now + SHOOT_REACTION_SECONDS
		end
		if now >= ai.shootReadyAt then
			local zombieRoot = rootOf(shootTarget)
			if zombieRoot ~= nil then
				WeaponService.fireBot(id, "Pistol", head.Position, zombieRoot.Position - head.Position, now)
			end
		end
	else
		ai.shootTargetId = nil
	end

	if threatPosition ~= nil then
		MovementService.setSprintIntent(id, true)
		local current = nearestWaypoint(origin)
		local options: { string } = {}
		if current ~= nil then
			options = adjacency[current]
		end
		local bestId: string? = nil
		local bestDistance = -math.huge
		for _, option in options do
			local waypoint = waypointById[option]
			if waypoint ~= nil then
				local dx = waypoint.position.x - threatPosition.X
				local dz = waypoint.position.z - threatPosition.Z
				local distance = dx * dx + dz * dz
				if distance > bestDistance then
					bestDistance = distance
					bestId = option
				end
			end
		end
		if bestId ~= nil then
			moveToWaypoint(participant, ai, bestId)
		else
			local delta = origin - threatPosition
			local horizontal = Vector3.new(delta.X, 0, delta.Z)
			if horizontal.Magnitude > 0.01 then
				humanoid:MoveTo(origin + horizontal.Unit * 12)
			end
		end
		return
	end

	MovementService.setSprintIntent(id, false)
	-- 没枪且附近没有丧尸：走向最近的枪械/电击枪补给点，拾取由 WeaponService 的服务端距离判定完成。
	if humanActions and not nearbyZombie and not WeaponService.hasGun(id) then
		local pickup = WeaponService.nearestPickupPosition(origin, PICKUP_PATH_RADIUS)
		if pickup ~= nil then
			ai.waypointId = nil
			humanoid:MoveTo(Vector3.new(pickup.X, GreyboxLayout.floorTopY, pickup.Z))
			return
		end
	end

	if now < ai.wanderAt then
		return
	end
	ai.wanderAt = now + WANDER_INTERVAL

	local current = nearestWaypoint(origin)
	local options: { string } = {}
	if current ~= nil then
		options = adjacency[current]
	end
	if #options > 0 then
		moveToWaypoint(participant, ai, options[math.random(#options)])
	end
end

function BotService.step(now: number)
	for id, participant in ParticipantService.all() do
		if participant.kind == "Bot" then
			local ai = ais[id]
			local record = PlayerStateService.get(id)
			if ai ~= nil and record ~= nil then
				if record.state == "INFECTED" then
					stepZombie(id, participant, ai, now)
				elseif record.state == "HUMAN" or record.state == "INCUBATING" then
					stepHuman(id, participant, ai, now)
				end
			end
		end
	end
end

return table.freeze(BotService)
