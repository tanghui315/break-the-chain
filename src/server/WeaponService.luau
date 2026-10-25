--!strict
-- 人类武器、补给与命中扫描的 Roblox 边界（GDB V1.1 §9A.4、§9A.5、§9A.7）：
-- 纯逻辑 Weapons 决定射速/弹药/射程/锥角/遮挡；本服务负责补给点、拾取、公开武器模型、
-- 服务端候选目标（位置历史回溯）、伤害/电击/击退、公开枪声与私有开火结果。
-- 客户端只发意图，origin/direction/targetId 都由服务端重新校验；targetId 不参与最终命中。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)
local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local FirePayload = require(script.Parent.logic.FirePayload)
local PositionHistory = require(script.Parent.logic.PositionHistory)
local SupplyPlan = require(script.Parent.logic.SupplyPlan)
local Weapons = require(script.Parent.logic.Weapons)
local Cleaner = require(script.Parent.util.Cleaner)
local GreyboxLayout = require(script.Parent.world.GreyboxLayout)
local GrabService = require(script.Parent.GrabService)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)
local ZombieCombatService = require(script.Parent.ZombieCombatService)

type Entry = {
	inventory: Weapons.Inventory,
	selected: Weapons.WeaponName,
}

type PickupKind = "Pistol" | "Taser" | "Crate"

type Pickup = {
	kind: PickupKind,
	position: Vector3,
	part: Part?,
	label: TextLabel?,
	available: boolean,
	crateIndex: number?,
}

type Attachment = {
	kind: string,
	part: Part,
	weld: WeldConstraint,
}

local weaponConfig: Weapons.Config = BalanceConfig :: any
local supplyConfig: SupplyPlan.Config = BalanceConfig :: any
local MAP_FOLDER_NAME = "Map"
local PICKUP_RADIUS = 5
local SERVER_BOT_PING = 0

local entries: { [string]: Entry } = {}
local pickups: { Pickup } = {}
local cratePickupByIndex: { [number]: Pickup } = {}
local crates: SupplyPlan.CrateState? = nil
local attachments: { [string]: Attachment } = {}
local cleaner: Cleaner.Cleaner? = nil
local pickupFolder: Folder? = nil
local active = false

local publicRemote: RemoteEvent? = nil
local privateRemote: RemoteEvent? = nil

local WeaponService = {}

local function getPublicRemote(): RemoteEvent
	local cached = publicRemote
	if cached ~= nil then
		return cached
	end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PublicMatchEvent") :: RemoteEvent
	publicRemote = remote
	return remote
end

local function getPrivateRemote(): RemoteEvent
	local cached = privateRemote
	if cached ~= nil then
		return cached
	end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PrivatePlayerEvent") :: RemoteEvent
	privateRemote = remote
	return remote
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

local function headOf(participant: ParticipantService.Participant): BasePart?
	local character = participant.character
	if character == nil or character.Parent == nil then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head ~= nil and head:IsA("BasePart") then
		return head
	end
	return nil
end

local function toVec3(v: Vector3): Weapons.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function toVector3(v: FirePayload.Vec3): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

-- 客户端按规范发送 Vector3；测试里的纯校验使用普通表。这里在边界把两种形状统一成表。
local function normalizeVectorPayload(value: any): any
	if typeof(value) == "Vector3" then
		return { x = value.X, y = value.Y, z = value.Z }
	end
	return value
end

local function isLosBlocked(from: Weapons.Vec3, to: Weapons.Vec3): boolean
	local a = Vector3.new(from.x, from.y, from.z)
	local b = Vector3.new(to.x, to.y, to.z)
	local delta = b - a
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
	return Workspace:Raycast(a, delta, params) ~= nil
end

local function pingSeconds(participant: ParticipantService.Participant): number
	local player = participant.player
	if player == nil then
		return SERVER_BOT_PING
	end
	local ok, value = pcall(function()
		return player:GetNetworkPing()
	end)
	if ok and type(value) == "number" and value == value then
		return math.max(0, value)
	end
	return 0
end

local function ammoFor(entry: Entry, weapon: Weapons.WeaponName): (number, number)
	if weapon == "Pistol" then
		return entry.inventory.pistol.magazine, entry.inventory.pistol.reserve
	elseif weapon == "Taser" then
		return entry.inventory.taser.magazine, 0
	end
	return 0, 0
end

local function sendState(participantId: string)
	local entry = entries[participantId]
	local participant = ParticipantService.getById(participantId)
	if entry == nil or participant == nil or participant.player == nil then
		return
	end
	getPrivateRemote():FireClient(participant.player, PublicEventTypes.Private.WeaponState, {
		selected = entry.selected,
		pistolOwned = entry.inventory.pistol.owned,
		pistolMagazine = entry.inventory.pistol.magazine,
		pistolReserve = entry.inventory.pistol.reserve,
		pistolReloading = Weapons.isReloading(entry.inventory, "Pistol"),
		taserOwned = entry.inventory.taser.owned,
		taserCharges = entry.inventory.taser.magazine,
	})
end

local function sendFireResult(participantId: string, weapon: string, result: Weapons.FireResult, entry: Entry?)
	local participant = ParticipantService.getById(participantId)
	if participant == nil or participant.player == nil then
		return
	end
	local magazine, reserve, charges = 0, 0, 0
	if entry ~= nil then
		if weapon == "Pistol" then
			magazine, reserve = ammoFor(entry, "Pistol")
		elseif weapon == "Taser" then
			magazine, charges = ammoFor(entry, "Taser")
		end
		charges = entry.inventory.taser.magazine
	end
	getPrivateRemote():FireClient(participant.player, PublicEventTypes.Private.FireResult, {
		ok = result.ok,
		reason = result.reason,
		hit = result.hit,
		ammo = magazine,
		reserve = reserve,
		chargesLeft = charges,
		weapon = weapon,
	})
end

local function destroyAttachment(participantId: string)
	local attachment = attachments[participantId]
	if attachment == nil then
		return
	end
	attachments[participantId] = nil
	if attachment.part.Parent ~= nil then
		attachment.part:Destroy()
	end
end

local function weaponPartSpec(weapon: Weapons.WeaponName): (Vector3, Color3)
	if weapon == "Pistol" then
		return Vector3.new(0.3, 0.45, 1.1), VisualTokens.Color.SurfaceSlate
	elseif weapon == "Taser" then
		return Vector3.new(0.25, 0.35, 0.8), VisualTokens.Color.Exit
	end
	return Vector3.new(0.22, 0.22, 2.1), VisualTokens.Color.TextSecondary
end

local function syncAttachment(participantId: string)
	local entry = entries[participantId]
	local participant = ParticipantService.getById(participantId)
	local record = PlayerStateService.get(participantId)
	if
		entry == nil
		or participant == nil
		or participant.character == nil
		or record == nil
		or record.state ~= "HUMAN"
	then
		destroyAttachment(participantId)
		return
	end

	local kind = entry.selected
	local current = attachments[participantId]
	if current ~= nil and current.kind == kind and current.part.Parent ~= nil then
		return
	end
	destroyAttachment(participantId)

	local hand = participant.character:FindFirstChild("RightHand")
	if hand == nil or not hand:IsA("BasePart") then
		hand = participant.character:FindFirstChild("Right Arm")
	end
	if hand == nil or not hand:IsA("BasePart") then
		return
	end

	local size, color = weaponPartSpec(entry.selected)
	local part = Instance.new("Part")
	part.Name = "BTC_Weapon"
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
	part.CFrame = hand.CFrame * CFrame.new(0, -0.65, -0.85) * CFrame.Angles(math.rad(90), 0, 0)
	part.Parent = participant.character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = part
	weld.Parent = part

	local roundCleaner = cleaner
	if roundCleaner ~= nil then
		Cleaner.add(roundCleaner, part)
	end
	attachments[participantId] = { kind = kind, part = part, weld = weld }
end

local function pickupColor(kind: PickupKind): Color3
	if kind == "Pistol" then
		return VisualTokens.Color.Human
	elseif kind == "Taser" then
		return VisualTokens.Color.Exit
	end
	return VisualTokens.Color.Disconnected
end

local function pickupText(kind: PickupKind): string
	if kind == "Pistol" then
		return "PISTOL"
	elseif kind == "Taser" then
		return "TASER"
	end
	return "AMMO"
end

local function makePickup(kind: PickupKind, position: Vector3, crateIndex: number?): Pickup
	local part = Instance.new("Part")
	part.Name = `BTC_{kind}Pickup`
	part.Anchored = true
	part.Size = if kind == "Crate" then Vector3.new(2.8, 1.2, 2) else Vector3.new(2.2, 0.8, 2.2)
	part.CFrame = CFrame.new(position)
	part.Color = pickupColor(kind)
	part.Material = Enum.Material.Neon
	part.Transparency = 0.15
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(150, 36)
	billboard.StudsOffset = Vector3.new(0, 2.2, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 70
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextScaled = true
	label.TextColor3 = VisualTokens.Color.TextPrimary
	label.TextStrokeColor3 = VisualTokens.Color.Night
	label.TextStrokeTransparency = 0.35
	label.Text = pickupText(kind)
	label.Parent = billboard

	local folder = pickupFolder
	part.Parent = if folder ~= nil then folder else Workspace
	local roundCleaner = cleaner
	if roundCleaner ~= nil then
		Cleaner.add(roundCleaner, part)
	end

	return {
		kind = kind,
		position = position,
		part = part,
		label = label,
		available = true,
		crateIndex = crateIndex,
	}
end

local function updateCrateVisual(pickup: Pickup)
	local available = pickup.available
	local part = pickup.part
	local label = pickup.label
	if part ~= nil then
		part.Transparency = if available then 0.15 else 0.82
	end
	if label ~= nil then
		label.Text = if available then "AMMO" else "AMMO (REFRESH)"
	end
end

local function removePickup(index: number)
	local pickup = pickups[index]
	if pickup == nil then
		return
	end
	local crateIndex = pickup.crateIndex
	if crateIndex ~= nil then
		cratePickupByIndex[crateIndex] = nil
	end
	if pickup.part ~= nil then
		pickup.part:Destroy()
	end
	table.remove(pickups, index)
end

local function spawnPickup(kind: PickupKind, position: Vector3, crateIndex: number?): Pickup
	local pickup = makePickup(kind, position, crateIndex)
	table.insert(pickups, pickup)
	if crateIndex ~= nil then
		cratePickupByIndex[crateIndex] = pickup
	end
	return pickup
end

local function ensurePickupFolder()
	if pickupFolder ~= nil and pickupFolder.Parent ~= nil then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "BTC_RoundPickups"
	folder.Parent = Workspace
	pickupFolder = folder
	local roundCleaner = cleaner
	if roundCleaner ~= nil then
		Cleaner.add(roundCleaner, folder)
	end
end

local function staticPickupPosition(point: GreyboxLayout.Vec3): Vector3
	return Vector3.new(point.x, GreyboxLayout.floorTopY + 1.2, point.z)
end

local function selectWeaponInternal(participantId: string, weapon: Weapons.WeaponName, notify: boolean): boolean
	local entry = entries[participantId]
	local record = PlayerStateService.get(participantId)
	if entry == nil or record == nil or record.state ~= "HUMAN" then
		return false
	end

	local owned = weapon == "Melee"
		or (weapon == "Pistol" and entry.inventory.pistol.owned)
		or (weapon == "Taser" and entry.inventory.taser.owned)
	if not owned then
		return false
	end

	entry.selected = weapon
	syncAttachment(participantId)
	if notify then
		sendState(participantId)
	end
	return true
end

local function dropGuns(participantId: string)
	local entry = entries[participantId]
	if entry == nil then
		return
	end

	local participant = ParticipantService.getById(participantId)
	local root = if participant ~= nil then rootOf(participant) else nil
	local hadPistol = entry.inventory.pistol.owned
	local hadTaser = entry.inventory.taser.owned
	if root ~= nil and (hadPistol or hadTaser) then
		ensurePickupFolder()
		local dropPosition = root.Position + Vector3.new(0, 1.5, 0)
		if hadPistol then
			spawnPickup("Pistol", dropPosition, nil)
		end
		if hadTaser then
			spawnPickup("Taser", dropPosition + Vector3.new(2.2, 0, 0), nil)
		end
	end

	entry.inventory = Weapons.newInventory(weaponConfig)
	entry.selected = "Melee"
	destroyAttachment(participantId)
	sendState(participantId)
end

local function applyKnockback(targetId: string, direction: Weapons.Vec3, amount: number)
	if amount <= 0 then
		return
	end
	local horizontal = Vector3.new(direction.x, 0, direction.z)
	if horizontal.Magnitude < 0.01 then
		return
	end
	local impulse = horizontal.Unit * (amount * 4) + Vector3.new(0, amount, 0)
	local participant = ParticipantService.getById(targetId)
	if participant == nil then
		return
	end
	if participant.player ~= nil then
		getPrivateRemote():FireClient(participant.player, PublicEventTypes.Private.Knockback, {
			impulse = impulse,
		})
		return
	end
	local root = rootOf(participant)
	if root ~= nil then
		root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + impulse
	end
end

local function targetStateFor(targetId: string, now: number): string
	local combatState = ZombieCombatService.publicStateOf(targetId, now)
	if combatState ~= nil then
		return combatState
	end
	return PlayerStateService.stateFor(targetId) or "none"
end

-- 构造服务端候选目标：所有参与者都参与几何选择，是否可伤害由 pure Weapons 用 active 复核。
local function buildTargets(shooterId: string, now: number): { Weapons.TargetInput }
	local targets: { Weapons.TargetInput } = {}
	for otherId, otherRecord in PlayerStateService.records() do
		if otherId ~= shooterId then
			local state = otherRecord.state
			local isZombie = state == "INFECTED" or state == "UNSTABLE"
			-- 死亡中的丧尸已经从战场隐藏，不能让它的旧根位置吸收子弹（§9A.3）。
			local hiddenDead = isZombie and ZombieCombatService.isDead(otherId)
			if not hiddenDead then
				local targetActive = if isZombie then ZombieCombatService.canBeHit(otherId, now) else false
				local history = otherRecord.history
				table.insert(targets, {
					id = otherId,
					isZombie = isZombie,
					active = targetActive,
					sample = function(t: number): Weapons.Vec3?
						return PositionHistory.sampleAt(history, t)
					end,
				})
			end
		end
	end
	return targets
end

local function acceptedShotTelemetry(
	weapon: Weapons.WeaponName,
	result: Weapons.FireResult,
	targetId: string?,
	now: number,
	ping: number
)
	local targetState = if targetId ~= nil then targetStateFor(targetId, now) else "none"
	local distance = if result.distance ~= nil then string.format("%.2f", result.distance) else "n/a"
	print(
		string.format(
			"[Telemetry] shot_fired weapon=%s hit=%s targetState=%s distance=%s pingMs=%d",
			weapon,
			tostring(result.hit),
			targetState,
			distance,
			math.max(0, math.round(ping * 1000))
		)
	)
end

local function fireInternal(
	participantId: string,
	weapon: Weapons.WeaponName,
	origin: Vector3,
	direction: Vector3,
	now: number,
	ping: number,
	notifyClient: boolean
): Weapons.FireResult?
	local participant = ParticipantService.getById(participantId)
	local record = PlayerStateService.get(participantId)
	local entry = entries[participantId]
	if participant == nil or record == nil or entry == nil then
		return nil
	end

	local function reject(reason: string): Weapons.FireResult
		local result: Weapons.FireResult = {
			ok = false,
			reason = reason,
			hit = false,
			damage = 0,
			stun = 0,
			knockback = 0,
		}
		if notifyClient then
			sendFireResult(participantId, weapon, result, entry)
		end
		return result
	end

	if record.state ~= "HUMAN" then
		return reject("NOT_HUMAN")
	end
	if GrabService.isGrabbed(participantId) then
		return reject("GRABBED")
	end
	-- 玩家路径必须与 SelectWeapon 一致；Bot 内部调用不经过这条限制。
	if notifyClient and entry.selected ~= weapon then
		return reject("NOT_SELECTED")
	end

	local head = headOf(participant)
	local root = rootOf(participant)
	if head == nil or root == nil then
		return reject("NO_CHARACTER")
	end

	local directionLength = direction.Magnitude
	if directionLength <= 1e-9 then
		return reject(Weapons.Reason.INVALID_DIRECTION)
	end
	-- 客户端 origin 只用于容差校验（§9A.7）；射程与视线一律从服务端头部位置计算，
	-- 否则作弊者可以把 origin 前移 4 studs 穿过薄墙，或把短棍射程拉长到约 10 studs。
	if (origin - head.Position).Magnitude > BalanceConfig.ShotOriginToleranceStuds then
		return reject(Weapons.Reason.ORIGIN_TOO_FAR)
	end
	local directionTable = toVec3(direction.Unit)
	local input: Weapons.FireInput = {
		origin = toVec3(head.Position),
		shooterHead = toVec3(head.Position),
		direction = directionTable,
		now = now,
		ping = ping,
		targets = buildTargets(participantId, now),
		losBlocked = isLosBlocked,
	}

	local result = Weapons.validateFire(weaponConfig, entry.inventory, weapon, input)
	if not result.ok then
		if notifyClient then
			sendFireResult(participantId, weapon, result, entry)
		end
		return result
	end

	if weapon == "Pistol" then
		local shotPosition = Vector3.new(
			math.round(root.Position.X / 4) * 4,
			math.round(root.Position.Y / 4) * 4,
			math.round(root.Position.Z / 4) * 4
		)
		getPublicRemote():FireAllClients(PublicEventTypes.Public.GunshotFired, {
			position = shotPosition,
		})
	end

	local hitTargetId = result.targetId
	if result.hit and hitTargetId ~= nil then
		-- §9A.6：任何武器命中正在擒抱的丧尸都先解除擒抱，再结算伤害/电击。
		GrabService.breakOnZombieHit(hitTargetId, now, weapon)

		if weapon == "Taser" then
			ZombieCombatService.applyStun(hitTargetId, now)
		elseif result.damage > 0 then
			ZombieCombatService.applyDamage(hitTargetId, result.damage, now)
		end

		if result.knockback > 0 then
			applyKnockback(hitTargetId, directionTable, result.knockback)
		end
	end

	acceptedShotTelemetry(weapon, result, hitTargetId, now, ping)
	if notifyClient then
		sendFireResult(participantId, weapon, result, entry)
	end
	return result
end

function WeaponService.reset()
	active = false
	local attachmentIds: { string } = {}
	for participantId in attachments do
		table.insert(attachmentIds, participantId)
	end
	for _, participantId in attachmentIds do
		destroyAttachment(participantId)
	end
	table.clear(attachments)
	table.clear(entries)
	for _, pickup in pickups do
		if pickup.part ~= nil then
			pickup.part:Destroy()
		end
	end
	table.clear(pickups)
	table.clear(cratePickupByIndex)
	crates = nil

	local folder = pickupFolder
	pickupFolder = nil
	if folder ~= nil then
		folder:Destroy()
	end
	cleaner = nil
end

function WeaponService.configureRound(roundCleaner: Cleaner.Cleaner)
	cleaner = roundCleaner
end

function WeaponService.createFor(participantId: string)
	if entries[participantId] == nil then
		entries[participantId] = {
			inventory = Weapons.newInventory(weaponConfig),
			selected = "Melee",
		}
	end
end

function WeaponService.removeParticipant(participantId: string)
	destroyAttachment(participantId)
	entries[participantId] = nil
end

-- CONTEST 开始：先按人数档规划枪械（SupplyPlan），再单独规划独立的弹药箱点位。
-- SupplyPlan 的三类分配共享一次洗牌；这里枪械用 supplyPoints，弹药箱用 ammoCratePoints，
-- 因此两个 plan 的 ammoCrates / shortfall.ammoCrates 不叠加（补充箱只认第二个 plan）。
function WeaponService.beginContest(roundCleaner: Cleaner.Cleaner, tier: SupplyPlan.Tier, rng: SupplyPlan.Rng)
	if active then
		return
	end
	active = true
	cleaner = roundCleaner
	ensurePickupFolder()

	local gunPlan = SupplyPlan.plan(tier, GreyboxLayout.supplyPoints, rng)
	for _, pointIndex in gunPlan.pistols do
		local point = GreyboxLayout.supplyPoints[pointIndex]
		spawnPickup("Pistol", staticPickupPosition(point), nil)
	end
	for _, pointIndex in gunPlan.tasers do
		local point = GreyboxLayout.supplyPoints[pointIndex]
		spawnPickup("Taser", staticPickupPosition(point), nil)
	end

	local cratePlan = SupplyPlan.plan({
		pistols = 0,
		tasers = 0,
		ammoCrates = tier.ammoCrates,
	}, GreyboxLayout.ammoCratePoints, rng)
	local crateState = SupplyPlan.newCrates(supplyConfig, cratePlan)
	crates = crateState
	for crateIndex, crate in crateState.crates do
		local point = GreyboxLayout.ammoCratePoints[crate.pointIndex]
		if point ~= nil then
			local pickup = spawnPickup("Crate", staticPickupPosition(point), crateIndex)
			pickup.available = SupplyPlan.isCrateAvailable(crateState, crateIndex)
			updateCrateVisual(pickup)
		end
	end

	if gunPlan.shortfall.pistols > 0 or gunPlan.shortfall.tasers > 0 then
		warn(
			string.format(
				"[BreakTheChain] supply shortfall pistols=%d tasers=%d",
				gunPlan.shortfall.pistols,
				gunPlan.shortfall.tasers
			)
		)
	end

	for participantId in entries do
		sendState(participantId)
		syncAttachment(participantId)
	end
end

function WeaponService.onInfected(participantId: string)
	dropGuns(participantId)
end

function WeaponService.handleFire(player: Player, payload: any, now: number)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end
	local normalized = {
		weapon = if type(payload) == "table" then payload.weapon else nil,
		origin = if type(payload) == "table" then normalizeVectorPayload(payload.origin) else nil,
		direction = if type(payload) == "table" then normalizeVectorPayload(payload.direction) else nil,
		targetId = if type(payload) == "table" then payload.targetId else nil,
	}
	local validated = FirePayload.validate(normalized)
	if not validated.ok or validated.value == nil then
		local entry = entries[participant.id]
		local result: Weapons.FireResult = {
			ok = false,
			reason = validated.reason,
			hit = false,
			damage = 0,
			stun = 0,
			knockback = 0,
		}
		sendFireResult(
			participant.id,
			if type(payload) == "table" then tostring(payload.weapon) else "none",
			result,
			entry
		)
		return
	end

	local value = validated.value
	fireInternal(
		participant.id,
		value.weapon,
		toVector3(value.origin),
		toVector3(value.direction),
		now,
		pingSeconds(participant),
		true
	)
end

function WeaponService.handleReload(player: Player)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil then
		return
	end
	local record = PlayerStateService.get(participant.id)
	local entry = entries[participant.id]
	if record == nil or entry == nil or record.state ~= "HUMAN" or GrabService.isGrabbed(participant.id) then
		sendState(participant.id)
		return
	end
	Weapons.startReload(entry.inventory, Workspace:GetServerTimeNow())
	sendState(participant.id)
end

function WeaponService.handleSelectWeapon(player: Player, payload: any)
	local participant = ParticipantService.getByPlayer(player)
	if participant == nil or type(payload) ~= "table" then
		return
	end
	local weapon = payload.weapon
	if weapon == "Melee" or weapon == "Pistol" or weapon == "Taser" then
		selectWeaponInternal(participant.id, weapon, true)
	end
end

-- Bot 与真人共用同一条 validateFire 路径；Bot 的 ping 固定为 0，不发送私有 UI 事件。
function WeaponService.fireBot(
	participantId: string,
	weapon: Weapons.WeaponName,
	origin: Vector3,
	direction: Vector3,
	now: number
): Weapons.FireResult?
	return fireInternal(participantId, weapon, origin, direction, now, SERVER_BOT_PING, false)
end

-- Bot 专属：空弹匣且有备弹时自动开始换弹。走 Weapons.startReload，不绕过任何规则。
function WeaponService.reloadBotIfEmpty(participantId: string, now: number)
	local entry = entries[participantId]
	if entry == nil or not entry.inventory.pistol.owned then
		return
	end
	local pistol = entry.inventory.pistol
	if pistol.magazine <= 0 and pistol.reserve > 0 and pistol.reloadEndsAt == nil then
		Weapons.startReload(entry.inventory, now)
	end
end

function WeaponService.hasPistol(participantId: string): boolean
	local entry = entries[participantId]
	return entry ~= nil and entry.inventory.pistol.owned
end

function WeaponService.hasTaser(participantId: string): boolean
	local entry = entries[participantId]
	return entry ~= nil and entry.inventory.taser.owned
end

function WeaponService.hasGun(participantId: string): boolean
	local entry = entries[participantId]
	return entry ~= nil and (entry.inventory.pistol.owned or entry.inventory.taser.owned)
end

function WeaponService.selectedFor(participantId: string): Weapons.WeaponName?
	local entry = entries[participantId]
	return if entry ~= nil then entry.selected else nil
end

-- Bot 在“没有枪、附近没有丧尸”时找最近的枪械/电击枪补给点。
function WeaponService.nearestPickupPosition(origin: Vector3, maxDistance: number): Vector3?
	local best: Vector3? = nil
	local bestDistance = maxDistance
	for _, pickup in pickups do
		if pickup.available and pickup.kind ~= "Crate" then
			local distance = (pickup.position - origin).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = pickup.position
			end
		end
	end
	return best
end

function WeaponService.step(now: number)
	if not active then
		return
	end

	for participantId, entry in entries do
		local tickResult = Weapons.tick(entry.inventory, now)
		if tickResult.reloadCompleted then
			sendState(participantId)
		end
		syncAttachment(participantId)
	end

	local crateState = crates
	if crateState ~= nil then
		for _, crateIndex in SupplyPlan.tickCrates(crateState, now) do
			local pickup = cratePickupByIndex[crateIndex]
			if pickup ~= nil then
				pickup.available = true
				updateCrateVisual(pickup)
			end
		end
	end

	-- 拾取以服务端距离为准：只允许 HUMAN 走到 5 studs 内；枪械每名人类最多 1 把，电击枪独立槽位。
	for participantId, entry in entries do
		local record = PlayerStateService.get(participantId)
		local participant = ParticipantService.getById(participantId)
		local root = if participant ~= nil then rootOf(participant) else nil
		if record ~= nil and record.state == "HUMAN" and root ~= nil then
			local origin = root.Position
			for index = #pickups, 1, -1 do
				local pickup = pickups[index]
				if pickup.available and (pickup.position - origin).Magnitude <= PICKUP_RADIUS then
					if pickup.kind == "Pistol" then
						if Weapons.givePistol(entry.inventory) then
							removePickup(index)
							if entry.selected == "Melee" then
								entry.selected = "Pistol"
							end
							sendState(participantId)
							syncAttachment(participantId)
						end
					elseif pickup.kind == "Taser" then
						if Weapons.giveTaser(entry.inventory) then
							removePickup(index)
							if entry.selected == "Melee" then
								entry.selected = "Taser"
							end
							sendState(participantId)
							syncAttachment(participantId)
						end
					elseif pickup.kind == "Crate" then
						local crateIndex = pickup.crateIndex
						local pistol = entry.inventory.pistol
						local reserveFull = pistol.reserve >= weaponConfig.Weapons.Pistol.ReserveAmmo
						if crateIndex ~= nil and pistol.owned and not reserveFull then
							if SupplyPlan.takeCrate(crateState :: SupplyPlan.CrateState, crateIndex, now) then
								Weapons.refillAmmo(entry.inventory)
								pickup.available = false
								updateCrateVisual(pickup)
								sendState(participantId)
							end
						end
					end
				end
			end
		end
	end

	for participantId in entries do
		syncAttachment(participantId)
	end
end

return table.freeze(WeaponService)
