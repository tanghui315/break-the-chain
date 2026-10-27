--!strict
-- 丧尸战斗生命状态的 Roblox 边界（GDB V1.1 §9A.1、§9A.3、§19.5）：
-- 每个 INFECTED 参与者一条 ZombieCombat 记录；状态机、伤害、电击、复活选点全部复用纯逻辑。
-- 本服务只负责：公开属性、速度覆盖、死亡隐藏/复活复位、掉落兜底、粒子与埋点。
-- 战斗状态与感染身份分离：这里绝不修改 ChaseRound / 感染树。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local RespawnPicker = require(script.Parent.logic.RespawnPicker)
local ZombieCombat = require(script.Parent.logic.ZombieCombat)
local Cleaner = require(script.Parent.util.Cleaner)
local GreyboxLayout = require(script.Parent.world.GreyboxLayout)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)

type HiddenPart = {
	anchored: boolean,
	transparency: number,
	canCollide: boolean,
	canQuery: boolean,
	canTouch: boolean,
	castShadow: boolean,
}

type Runtime = {
	id: string,
	combat: ZombieCombat.Zombie,
	isRoot: boolean,
	hidden: boolean,
	hiddenParts: { [BasePart]: HiddenPart },
	lastLegalCFrame: CFrame?,
	diedAt: number?,
	fullDeadSeconds: number,
	displayDistanceType: Enum.HumanoidDisplayDistanceType?,
	nameDisplayDistance: number?,
	healthDisplayDistance: number?,
}

local combatConfig: ZombieCombat.Config = BalanceConfig :: any
local respawnConfig: RespawnPicker.Config = BalanceConfig :: any

local zombies: { [string]: Runtime } = {}
local cleaner: Cleaner.Cleaner? = nil
local roundStartedAt = 0
local respawnSeconds = 6
-- §9A.3：撤离期复活点须距撤离区 ≥ RespawnMinDistanceFromExtraction。
local extractionPoint: RespawnPicker.Vec3? = nil
local extractionActive = false

local ZombieCombatService = {}

local function nowServer(): number
	return Workspace:GetServerTimeNow()
end

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

local function elapsedSec(now: number): string
	return string.format("%.1f", math.max(0, now - roundStartedAt))
end

local function addToCleaner(instance: Instance)
	local roundCleaner = cleaner
	if roundCleaner ~= nil then
		Cleaner.add(roundCleaner, instance)
	end
end

-- §9A.3：死亡表现只用红色感染粒子，不表现血液/肢解。
local function emitDeathBurst(position: Vector3)
	local part = Instance.new("Part")
	part.Name = "BTC_DeathBurst"
	part.Anchored = true
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.CFrame = CFrame.new(position)

	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "InfectionBurst"
	emitter.Color = ColorSequence.new(VisualTokens.Color.Zombie)
	emitter.LightEmission = 0.8
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -10, 0)
	emitter.Rate = 0
	emitter.Parent = attachment

	part.Parent = Workspace
	addToCleaner(part)
	emitter:Emit(24)
	task.delay(1.2, function()
		part:Destroy()
	end)
end

local function syncAttributes(rt: Runtime, now: number)
	local participant = ParticipantService.getById(rt.id)
	if participant == nil or participant.character == nil then
		return
	end
	local character = participant.character

	local combatState: string = ZombieCombat.stateOf(rt.combat)
	if ZombieCombat.isStunned(rt.combat, now) then
		combatState = "STUNNED"
	end
	character:SetAttribute(Constants.Attribute.Combat, combatState)

	local maximum = ZombieCombat.maxHealthOf(rt.combat)
	local ratio = if maximum > 0 then math.clamp(ZombieCombat.healthOf(rt.combat) / maximum, 0, 1) else 0
	character:SetAttribute(Constants.Attribute.Health, ratio)
	character:SetAttribute(Constants.Attribute.Protected, ZombieCombat.isRespawnProtected(rt.combat, now))

	local deadUntil = rt.combat.deadUntil
	if ZombieCombat.stateOf(rt.combat) == "DEAD" and deadUntil ~= nil then
		character:SetAttribute(Constants.Attribute.RespawnAt, deadUntil)
	else
		character:SetAttribute(Constants.Attribute.RespawnAt, nil)
	end
end

local function applyCombatSpeed(rt: Runtime, now: number)
	local record = PlayerStateService.get(rt.id)
	if record == nil then
		return
	end
	if rt.hidden or ZombieCombat.stateOf(rt.combat) == "DEAD" then
		PlayerStateService.setCombatSpeed(rt.id, 0)
		return
	end
	local normalSpeed = PlayerStateService.baseSpeedFor(record)
	PlayerStateService.setCombatSpeed(rt.id, ZombieCombat.moveSpeedFor(combatConfig, rt.combat, now, normalSpeed))
end

local function clearBiteRecord(id: string)
	local record = PlayerStateService.get(id)
	if record ~= nil then
		record.windupStartedAt = nil
		record.windupConsumed = true
	end
end

local function hideCharacter(rt: Runtime)
	if rt.hidden then
		return
	end
	local participant = ParticipantService.getById(rt.id)
	if participant == nil or participant.character == nil then
		return
	end

	local root = rootOf(participant)
	if root ~= nil then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end

	for _, descendant in participant.character:GetDescendants() do
		if descendant:IsA("BasePart") then
			if rt.hiddenParts[descendant] == nil then
				rt.hiddenParts[descendant] = {
					anchored = descendant.Anchored,
					transparency = descendant.Transparency,
					canCollide = descendant.CanCollide,
					canQuery = descendant.CanQuery,
					canTouch = descendant.CanTouch,
					castShadow = descendant.CastShadow,
				}
			end
			descendant.Anchored = true
			descendant.Transparency = 1
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
		end
	end

	local humanoid = participant.character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		rt.displayDistanceType = humanoid.DisplayDistanceType
		rt.nameDisplayDistance = humanoid.NameDisplayDistance
		rt.healthDisplayDistance = humanoid.HealthDisplayDistance
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
		humanoid:Move(Vector3.zero, false)
		humanoid.WalkSpeed = 0
	end
	rt.hidden = true
end

local function restoreCharacter(rt: Runtime)
	local participant = ParticipantService.getById(rt.id)
	if participant == nil or participant.character == nil then
		rt.hiddenParts = {}
		rt.hidden = false
		return
	end

	-- 先恢复碰撞与可见性，最后恢复锚定；角色此时已经 Pivot 到感染区。
	for part, saved in rt.hiddenParts do
		if part.Parent ~= nil then
			part.Transparency = saved.transparency
			part.CanCollide = saved.canCollide
			part.CanQuery = saved.canQuery
			part.CanTouch = saved.canTouch
			part.CastShadow = saved.castShadow
			part.Anchored = saved.anchored
		end
	end
	rt.hiddenParts = {}
	rt.hidden = false

	PlayerStateService.prepareCharacter(participant.character)
	local humanoid = participant.character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local displayDistanceType = rt.displayDistanceType
		if displayDistanceType ~= nil then
			humanoid.DisplayDistanceType = displayDistanceType
		end
		if rt.nameDisplayDistance ~= nil then
			humanoid.NameDisplayDistance = rt.nameDisplayDistance
		end
		if rt.healthDisplayDistance ~= nil then
			humanoid.HealthDisplayDistance = rt.healthDisplayDistance
		end
		rt.displayDistanceType = nil
		rt.nameDisplayDistance = nil
		rt.healthDisplayDistance = nil
		humanoid.WalkSpeed = 0
	end
end

local function humanRootPositions(): { RespawnPicker.Vec3 }
	local out: { RespawnPicker.Vec3 } = {}
	for id, record in PlayerStateService.records() do
		if record.state == "HUMAN" then
			local participant = ParticipantService.getById(id)
			local root = if participant ~= nil then rootOf(participant) else nil
			if root ~= nil then
				table.insert(out, { x = root.Position.X, y = root.Position.Y, z = root.Position.Z })
			end
		end
	end
	return out
end

local function nearestHumanDistance(zone: RespawnPicker.Vec3, humans: { RespawnPicker.Vec3 }): number
	local best = math.huge
	for _, human in humans do
		local dx = zone.x - human.x
		local dz = zone.z - human.z
		best = math.min(best, math.sqrt(dx * dx + dz * dz))
	end
	return best
end

local function spawnCFrameFor(index: number): CFrame
	local points = GreyboxLayout.infectionZones
	local point = points[((index - 1) % #points) + 1]
	return CFrame.new(point.x, GreyboxLayout.floorTopY + GreyboxLayout.characterSpawnY, point.z)
end

-- §22.2：isUnstable 报的是感染身份（PlayerStateService UNSTABLE），不是战斗状态。
local function isUnstable(participantId: string): boolean
	return PlayerStateService.stateFor(participantId) == "UNSTABLE"
end

local function onDowned(rt: Runtime, now: number)
	clearBiteRecord(rt.id)
	print(
		string.format(
			"[Telemetry] zombie_downed isRoot=%s isUnstable=%s downedByWeapon=true elapsedSec=%s",
			tostring(rt.isRoot),
			tostring(isUnstable(rt.id)),
			elapsedSec(now)
		)
	)
end

local function onDied(rt: Runtime, now: number)
	local root = nil
	local participant = ParticipantService.getById(rt.id)
	if participant ~= nil then
		root = rootOf(participant)
	end
	if root ~= nil then
		emitDeathBurst(root.Position)
	end

	rt.diedAt = now
	-- 名义死亡时长用于判断“最后一只丧尸”是否缩短过复活时间；实际 deadUntil 由纯逻辑给出。
	rt.fullDeadSeconds = respawnSeconds
	hideCharacter(rt)
	clearBiteRecord(rt.id)
	print(
		string.format(
			"[Telemetry] zombie_killed isRoot=%s isUnstable=%s respawnSeconds=%s",
			tostring(rt.isRoot),
			tostring(isUnstable(rt.id)),
			tostring(respawnSeconds)
		)
	)
end

local function respawn(rt: Runtime, now: number)
	local participant = ParticipantService.getById(rt.id)
	if participant == nil or participant.character == nil then
		return
	end

	local humans = humanRootPositions()
	local pickedIndex =
		RespawnPicker.pick(respawnConfig, GreyboxLayout.infectionZones, humans, extractionPoint, extractionActive)
	local index: number = pickedIndex or 1

	local deadUntilBefore = rt.combat.deadUntil
	if not ZombieCombat.respawn(rt.combat, now) then
		return
	end

	participant.character:PivotTo(spawnCFrameFor(index))
	restoreCharacter(rt)

	local root = rootOf(participant)
	if root ~= nil then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	clearBiteRecord(rt.id)

	local capsApplied = false
	if deadUntilBefore ~= nil and rt.diedAt ~= nil then
		-- 允许 0.25 秒的 tick 抖动；小于名义复活时间超过该值视为触发了最后一只丧尸上限。
		capsApplied = deadUntilBefore < rt.diedAt + rt.fullDeadSeconds - 0.25
	end
	local deadSeconds = if rt.diedAt ~= nil then math.max(0, now - rt.diedAt) else 0
	local zone = GreyboxLayout.infectionZones[index]
	local nearest = nearestHumanDistance(zone, humans)
	print(
		string.format(
			"[Telemetry] zombie_respawned spawnZone=%s nearestHumanDistance=%s deadSeconds=%s lastZombieCapApplied=%s isUnstable=%s",
			tostring(index),
			if nearest == math.huge then "inf" else string.format("%.1f", nearest),
			string.format("%.1f", deadSeconds),
			tostring(capsApplied),
			tostring(isUnstable(rt.id))
		)
	)
	rt.diedAt = nil
	rt.fullDeadSeconds = 0
end

local function newRuntime(participantId: string, isRoot: boolean, now: number): Runtime
	local participant = ParticipantService.getById(participantId)
	local root = if participant ~= nil then rootOf(participant) else nil
	return {
		id = participantId,
		combat = ZombieCombat.new(combatConfig, isRoot, now),
		isRoot = isRoot,
		hidden = false,
		hiddenParts = {},
		lastLegalCFrame = if root ~= nil then root.CFrame else nil,
		diedAt = nil,
		fullDeadSeconds = 0,
		displayDistanceType = nil,
		nameDisplayDistance = nil,
		healthDisplayDistance = nil,
	}
end

function ZombieCombatService.configure(roundCleaner: Cleaner.Cleaner, startedAt: number, tierRespawnSeconds: number)
	cleaner = roundCleaner
	roundStartedAt = startedAt
	respawnSeconds = if tierRespawnSeconds ~= tierRespawnSeconds or tierRespawnSeconds <= 0
		then 6
		else tierRespawnSeconds
end

-- §9A.3：撤离阶段把撤离区坐标交给复活选点；撤离未开启时不参与筛选。
function ZombieCombatService.setExtraction(point: RespawnPicker.Vec3?, activePhase: boolean)
	extractionPoint = point
	extractionActive = activePhase
end

function ZombieCombatService.reset()
	table.clear(zombies)
	cleaner = nil
	roundStartedAt = 0
	respawnSeconds = 6
	extractionPoint = nil
	extractionActive = false
end

-- 感染身份为 INFECTED 或 UNSTABLE 时都需要战斗记录（断联丧尸仍可被打倒/复活）。
function ZombieCombatService.createFor(participantId: string, isRoot: boolean, now: number)
	if zombies[participantId] ~= nil then
		return
	end
	local record = PlayerStateService.get(participantId)
	if record == nil or (record.state ~= "INFECTED" and record.state ~= "UNSTABLE") then
		return
	end
	local rt = newRuntime(participantId, isRoot, now)
	zombies[participantId] = rt
	syncAttributes(rt, now)
	applyCombatSpeed(rt, now)
end

-- restore 用于“治愈 / 断联到期”把死亡隐藏的角色交还给人形状态；
-- 玩家离场时角色本就会被销毁，保留默认 false 即可。
function ZombieCombatService.remove(participantId: string, restore: boolean?)
	local rt = zombies[participantId]
	if rt == nil then
		return
	end
	if restore == true then
		restoreCharacter(rt)
	end
	local participant = ParticipantService.getById(participantId)
	if participant ~= nil and participant.character ~= nil then
		participant.character:SetAttribute(Constants.Attribute.Combat, nil)
		participant.character:SetAttribute(Constants.Attribute.Health, nil)
		participant.character:SetAttribute(Constants.Attribute.RespawnAt, nil)
		participant.character:SetAttribute(Constants.Attribute.Protected, nil)
	end
	zombies[participantId] = nil
end

function ZombieCombatService.get(participantId: string): ZombieCombat.Zombie?
	local rt = zombies[participantId]
	return if rt ~= nil then rt.combat else nil
end

function ZombieCombatService.stateOf(participantId: string): string?
	local rt = zombies[participantId]
	if rt == nil then
		return nil
	end
	return ZombieCombat.stateOf(rt.combat)
end

function ZombieCombatService.publicStateOf(participantId: string, now: number): string?
	local rt = zombies[participantId]
	if rt == nil then
		return nil
	end
	if ZombieCombat.isStunned(rt.combat, now) then
		return "STUNNED"
	end
	return ZombieCombat.stateOf(rt.combat)
end

function ZombieCombatService.canAct(participantId: string, now: number): boolean
	local rt = zombies[participantId]
	return rt ~= nil and ZombieCombat.canAct(rt.combat, now)
end

-- 可被武器命中与“可行动”不同：电击中的丧尸仍处于 ACTIVE，纯逻辑允许它继续受伤；
-- 只有倒地 / 死亡 / 复活保护才是免疫（§9A.3）。
function ZombieCombatService.canBeHit(participantId: string, now: number): boolean
	local rt = zombies[participantId]
	if rt == nil or ZombieCombat.stateOf(rt.combat) ~= "ACTIVE" then
		return false
	end
	return not ZombieCombat.isRespawnProtected(rt.combat, now)
end

function ZombieCombatService.isProtected(participantId: string, now: number): boolean
	local rt = zombies[participantId]
	return rt ~= nil and ZombieCombat.isRespawnProtected(rt.combat, now)
end

function ZombieCombatService.isDead(participantId: string): boolean
	local rt = zombies[participantId]
	return rt ~= nil and ZombieCombat.stateOf(rt.combat) == "DEAD"
end

function ZombieCombatService.isBelowKillPlane(participantId: string): boolean
	local participant = ParticipantService.getById(participantId)
	local root = if participant ~= nil then rootOf(participant) else nil
	return root ~= nil and root.Position.Y < GreyboxLayout.killPlaneY
end

function ZombieCombatService.hasWindup(participantId: string): boolean
	local rt = zombies[participantId]
	return rt ~= nil and ZombieCombat.hasWindup(rt.combat)
end

function ZombieCombatService.beginWindup(participantId: string, now: number): boolean
	local rt = zombies[participantId]
	if rt == nil then
		return false
	end
	local started = ZombieCombat.beginWindup(rt.combat, now)
	if started then
		syncAttributes(rt, now)
	end
	return started
end

function ZombieCombatService.cancelWindup(participantId: string)
	local rt = zombies[participantId]
	if rt ~= nil then
		ZombieCombat.cancelWindup(rt.combat)
		syncAttributes(rt, nowServer())
	end
end

function ZombieCombatService.onAttack(participantId: string, now: number): boolean
	local rt = zombies[participantId]
	if rt == nil then
		return false
	end
	local ended = ZombieCombat.onAttack(rt.combat, now)
	if ended then
		syncAttributes(rt, now)
	end
	return ended
end

-- 武器命中造成的打断：把纯逻辑给出的扑咬冷却写回 BiteRules 的攻击者记录（§9A.4）。
local function syncBiteInterrupt(participantId: string, biteCooldownUntil: number?)
	local record = PlayerStateService.get(participantId)
	if record ~= nil then
		if biteCooldownUntil ~= nil then
			record.biteCooldownUntil = biteCooldownUntil
		end
		record.windupStartedAt = nil
		record.windupConsumed = true
	end
end

function ZombieCombatService.applyDamage(participantId: string, amount: number, now: number): ZombieCombat.DamageResult?
	local rt = zombies[participantId]
	if rt == nil then
		return nil
	end
	local result = ZombieCombat.applyDamage(rt.combat, amount, now)
	if result.interruptedWindup then
		syncBiteInterrupt(participantId, result.biteCooldownUntil)
	end
	if result.downed then
		onDowned(rt, now)
	end
	syncAttributes(rt, now)
	applyCombatSpeed(rt, now)
	return result
end

function ZombieCombatService.applyStun(participantId: string, now: number): (boolean, string, ZombieCombat.StunDetail)
	local rt = zombies[participantId]
	if rt == nil then
		return false, "NO_ZOMBIE", {}
	end
	local ok, reason, detail = ZombieCombat.applyStun(rt.combat, now)
	if detail.interruptedWindup then
		syncBiteInterrupt(participantId, detail.biteCooldownUntil)
	end
	syncAttributes(rt, now)
	applyCombatSpeed(rt, now)
	return ok, reason, detail
end

-- 掉出地图（§9A.3、§19.5）：DEAD 忽略；DOWNED 放回最后合法位置；ACTIVE 直接死亡并走完整复活时间。
-- 返回 true 表示该参与者由本服务接手，RoundService 不应再走人类重生路径。
function ZombieCombatService.handleFall(participantId: string, now: number): boolean
	local rt = zombies[participantId]
	if rt == nil then
		return false
	end
	local participant = ParticipantService.getById(participantId)
	local root = if participant ~= nil then rootOf(participant) else nil
	if root == nil or root.Position.Y >= GreyboxLayout.killPlaneY then
		return false
	end

	if ZombieCombat.stateOf(rt.combat) == "DEAD" then
		return true
	end

	if ZombieCombat.stateOf(rt.combat) == "DOWNED" then
		local target = rt.lastLegalCFrame
		if target == nil and participant ~= nil and participant.character ~= nil then
			target = spawnCFrameFor(1)
		end
		if participant ~= nil and participant.character ~= nil and target ~= nil then
			participant.character:PivotTo(target)
			local newRoot = rootOf(participant)
			if newRoot ~= nil then
				newRoot.AssemblyLinearVelocity = Vector3.zero
				newRoot.AssemblyAngularVelocity = Vector3.zero
			end
		end
		syncAttributes(rt, now)
		applyCombatSpeed(rt, now)
		return true
	end

	ZombieCombat.forceDeath(rt.combat, now, respawnSeconds)
	onDied(rt, now)
	syncAttributes(rt, now)
	applyCombatSpeed(rt, now)
	return true
end

-- 每 tick 推进所有丧尸。先算 noZombieCanAct，再让纯逻辑推进倒地/死亡/复活与生命回复。
function ZombieCombatService.step(now: number)
	local noZombieCanAct = true
	for _, rt in zombies do
		if ZombieCombat.canAct(rt.combat, now) then
			noZombieCanAct = false
			break
		end
	end

	for _, rt in zombies do
		local participant = ParticipantService.getById(rt.id)
		local root = if participant ~= nil then rootOf(participant) else nil
		if root ~= nil and not rt.hidden then
			local half = GreyboxLayout.mapSize / 2 - 2
			local position = root.Position
			if
				position.Y >= GreyboxLayout.killPlaneY
				and math.abs(position.X) <= half
				and math.abs(position.Z) <= half
			then
				rt.lastLegalCFrame = root.CFrame
			end
		end

		local events = ZombieCombat.tick(rt.combat, now, {
			respawnSeconds = respawnSeconds,
			noZombieCanAct = noZombieCanAct,
		})
		for _, event in events do
			if event.type == ZombieCombat.EventType.DOWNED then
				onDowned(rt, now)
			elseif event.type == ZombieCombat.EventType.DIED then
				onDied(rt, now)
			end
		end

		if ZombieCombat.isRespawnReady(rt.combat) then
			respawn(rt, now)
		end
		syncAttributes(rt, now)
		applyCombatSpeed(rt, now)
	end
end

return table.freeze(ZombieCombatService)
