--!strict
-- 解药的 Roblox 边界（GDB V1.1 §10.1、§10.2、§17.6）：库存唯一性、拾取、掉落与公开外观。
-- 状态与数量全部由 CureInventory（RoundStateMachine 持有）决定；本服务只做：
--   - 站在补给/掉落解药 5 studs 内的 HUMAN 自动拾取（每人最多 1 支）；
--   - 世界里的解药箱与“持有者手上的一小支”公开模型（服务端创建，所有人可见，属于公开信息）；
--   - 持有者尸变 / 离场时由 RoundStateMachine 调用 CureInventory.drop，这里把同一 itemId 重新画到地上，绝不复制。
-- 拾取只对人类生效；INCUBATING / INFECTED / UNSTABLE 不能拾取（§7.3、§9.1）。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local CureInventory = require(script.Parent.logic.CureInventory)
local RoundStateMachine = require(script.Parent.logic.RoundStateMachine)
local Cleaner = require(script.Parent.util.Cleaner)
local GreyboxLayout = require(script.Parent.world.GreyboxLayout)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)

type WorldPickup = {
	part: Part,
	label: TextLabel?,
	position: Vector3,
}

type CarriedCure = {
	itemId: string,
	carrierId: string,
	part: Part,
	weld: WeldConstraint,
}

type Runtime = {
	round: RoundStateMachine.Round,
	cleaner: Cleaner.Cleaner,
}

local PICKUP_RADIUS = 5
local PICKUP_FOLDER_NAME = "BTC_CurePickups"

local runtime: Runtime? = nil
local worldPickups: { [string]: WorldPickup } = {}
local carried: { [string]: CarriedCure } = {}
local folder: Folder? = nil

local CureService = {}

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

-- 解药位置是“不透明值”（§CureInventory 头注释）：补给槽是 GreyboxLayout.Vec3，掉落位置是 Vector3。
local function toVector3(value: unknown): Vector3?
	if typeof(value) == "Vector3" then
		return value
	end
	if type(value) == "table" then
		local x = (value :: any).x
		local y = (value :: any).y
		local z = (value :: any).z
		if type(x) == "number" and type(y) == "number" and type(z) == "number" then
			return Vector3.new(x, y, z)
		end
	end
	return nil
end

local function ensureFolder(cleaner: Cleaner.Cleaner): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = PICKUP_FOLDER_NAME
	created.Parent = Workspace
	Cleaner.add(cleaner, created)
	folder = created
	return created
end

local function destroyWorldPickup(itemId: string)
	local pickup = worldPickups[itemId]
	if pickup == nil then
		return
	end
	worldPickups[itemId] = nil
	if pickup.part.Parent ~= nil then
		pickup.part:Destroy()
	end
end

local function destroyCarried(itemId: string)
	local entry = carried[itemId]
	if entry == nil then
		return
	end
	carried[itemId] = nil
	if entry.part.Parent ~= nil then
		entry.part:Destroy()
	end
end

local function makeWorldPickup(cleaner: Cleaner.Cleaner, itemId: string, position: Vector3)
	local part = Instance.new("Part")
	part.Name = "BTC_CurePickup"
	part.Anchored = true
	part.Size = Vector3.new(0.9, 1.6, 0.9)
	part.CFrame = CFrame.new(position)
	part.Color = VisualTokens.Color.Cured
	part.Material = Enum.Material.Neon
	part.Transparency = 0.1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(120, 32)
	billboard.StudsOffset = Vector3.new(0, 1.8, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 80
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = VisualTokens.Color.Cured
	label.TextStrokeColor3 = VisualTokens.Color.Night
	label.TextStrokeTransparency = 0.3
	label.Text = "CURE"
	label.Parent = billboard

	part.Parent = ensureFolder(cleaner)
	Cleaner.add(cleaner, part)

	worldPickups[itemId] = { part = part, label = label, position = position }
	return part
end

local function handOf(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand")
	if hand == nil or not hand:IsA("BasePart") then
		hand = character:FindFirstChild("Right Arm")
	end
	if hand ~= nil and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function makeCarried(cleaner: Cleaner.Cleaner, itemId: string, carrierId: string, character: Model): boolean
	local hand = handOf(character)
	if hand == nil then
		return false
	end
	local part = Instance.new("Part")
	part.Name = "BTC_Cure"
	part.Size = Vector3.new(0.28, 0.28, 0.62)
	part.Color = VisualTokens.Color.Cured
	part.Material = Enum.Material.Neon
	part.Transparency = 0
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
	part.CFrame = hand.CFrame * CFrame.new(0.45, -0.1, -0.35) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = part
	weld.Parent = part
	Cleaner.add(cleaner, part)

	carried[itemId] = { itemId = itemId, carrierId = carrierId, part = part, weld = weld }
	return true
end

-- 把视觉外观对齐到唯一权威库存：SUPPLY/DROPPED → 地面模型；CARRIED → 手上模型；CONSUMED → 全部销毁。
function CureService.syncVisuals()
	local current = runtime
	if current == nil then
		return
	end
	local inventory = current.round.cures

	for itemId, item in inventory.items do
		if item.state == "CARRIED" then
			destroyWorldPickup(itemId)
			local carrierId = item.carrierId
			local entry: CarriedCure? = carried[itemId]
			if carrierId == nil then
				destroyCarried(itemId)
			else
				local participant = ParticipantService.getById(carrierId)
				local character = if participant ~= nil then participant.character else nil
				if
					character == nil
					or character.Parent == nil
					or (entry ~= nil and (entry.carrierId ~= carrierId or entry.part.Parent ~= character))
				then
					destroyCarried(itemId)
					entry = nil
				end
				if entry == nil and character ~= nil and character.Parent ~= nil then
					makeCarried(current.cleaner, itemId, carrierId, character)
				end
			end
		elseif item.state == "SUPPLY" or item.state == "DROPPED" then
			destroyCarried(itemId)
			local position = toVector3(item.position)
			if position == nil then
				destroyWorldPickup(itemId)
			else
				local y = math.max(position.Y, GreyboxLayout.floorTopY + 1.2)
				local target = Vector3.new(position.X, y, position.Z)
				local pickup = worldPickups[itemId]
				if pickup == nil or pickup.part.Parent == nil then
					destroyWorldPickup(itemId)
					makeWorldPickup(current.cleaner, itemId, target)
				else
					pickup.part.CFrame = CFrame.new(target)
					pickup.position = target
				end
			end
		else
			destroyWorldPickup(itemId)
			destroyCarried(itemId)
		end
	end
end

function CureService.configure(roundCleaner: Cleaner.Cleaner, round: RoundStateMachine.Round)
	CureService.reset()
	runtime = { round = round, cleaner = roundCleaner }
	CureService.syncVisuals()
end

function CureService.reset()
	local worldIds: { string } = {}
	for itemId in worldPickups do
		table.insert(worldIds, itemId)
	end
	for _, itemId in worldIds do
		destroyWorldPickup(itemId)
	end
	local carriedIds: { string } = {}
	for itemId in carried do
		table.insert(carriedIds, itemId)
	end
	for _, itemId in carriedIds do
		destroyCarried(itemId)
	end
	local existing = folder
	folder = nil
	if existing ~= nil and existing.Parent ~= nil then
		existing:Destroy()
	end
	runtime = nil
end

-- 最近的可用解药（SUPPLY / DROPPED）位置，供 Bot 在无威胁时寻路。
function CureService.nearestPickupPosition(origin: Vector3, maxDistance: number): Vector3?
	local current = runtime
	if current == nil then
		return nil
	end
	local best: Vector3? = nil
	local bestDistance = maxDistance
	for _, item in current.round.cures.items do
		if item.state == "SUPPLY" or item.state == "DROPPED" then
			local position = toVector3(item.position)
			if position ~= nil then
				local distance = (position - origin).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					best = position
				end
			end
		end
	end
	return best
end

-- 每 tick：HUMAN 走到 5 studs 内自动拾取（每人最多 1 支），然后把视觉对齐到库存。
function CureService.step(_now: number)
	local current = runtime
	if current == nil then
		return
	end
	local inventory = current.round.cures

	for participantId, record in PlayerStateService.records() do
		if record.state == "HUMAN" and CureInventory.heldBy(inventory, participantId) == nil then
			local root = rootOf(participantId)
			if root ~= nil then
				local origin = root.Position
				local bestItemId: string? = nil
				local bestDistance = PICKUP_RADIUS
				for itemId, item in inventory.items do
					if item.state == "SUPPLY" or item.state == "DROPPED" then
						local position = toVector3(item.position)
						if position ~= nil then
							local distance = (position - origin).Magnitude
							if distance <= bestDistance then
								bestDistance = distance
								bestItemId = itemId
							end
						end
					end
				end
				if bestItemId ~= nil then
					CureInventory.pickup(inventory, bestItemId, participantId)
				end
			end
		end
	end

	CureService.syncVisuals()
end

return table.freeze(CureService)
