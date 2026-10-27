--!strict
-- 把当前地图（ActiveMap.get()）的纯数据建成 workspace.Map 下的锚定 Part（GDB V1.1 §24.4）。
-- 所有地图 Part 进入 MapStatic 碰撞组：扑咬视线射线只检测该组，角色互相之间不遮挡判定。

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local ActiveMap = require(script.Parent.ActiveMap)
local GreyboxLayout = require(script.Parent.GreyboxLayout)

export type BuildResult = {
	folder: Folder,
	killPlaneY: number,
}

type ExitGate = {
	pad: Part,
	frameParts: { Part },
	light: PointLight,
	label: TextLabel,
	open: boolean,
}

local MAP_COLLISION_GROUP = "MapStatic"

local GreyboxBuilder = {}

local currentExit: ExitGate? = nil

local function ensureCollisionGroup()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(MAP_COLLISION_GROUP)
	end)
end

local function setGroup(part: BasePart)
	part.CollisionGroup = MAP_COLLISION_GROUP
end

local function colorFor(block: GreyboxLayout.Block, index: number): Color3
	if block.kind == "Floor" then
		return VisualTokens.Color.SurfaceSlate
	elseif block.kind == "Obstacle" then
		return VisualTokens.Color.SurfaceConcrete
	elseif index % 2 == 0 then
		return VisualTokens.Color.SurfaceSlate
	end
	return VisualTokens.Color.SurfaceConcrete
end

local function makeBlock(folder: Folder, block: GreyboxLayout.Block, index: number): Part
	local part = Instance.new("Part")
	part.Name = block.id
	part.Anchored = true
	part.Size = Vector3.new(block.size.x, block.size.y, block.size.z)
	part.CFrame = CFrame.new(block.center.x, block.center.y, block.center.z)
	part.Material = Enum.Material.Concrete
	part.Color = colorFor(block, index)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = false
	part.Parent = folder
	setGroup(part)
	return part
end

-- 掉出地图的兜底平面。RoundService 用 Y 坐标判定，Part 只作为场景里的可见下限。
local function makeKillPlane(folder: Folder): Part
	local part = Instance.new("Part")
	part.Name = "KillPlane"
	part.Anchored = true
	part.Size = Vector3.new(ActiveMap.get().mapSize * 2, 4, ActiveMap.get().mapSize * 2)
	part.CFrame = CFrame.new(0, ActiveMap.get().killPlaneY - 2, 0)
	part.Color = VisualTokens.Color.Night
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = true
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = folder
	return part
end

-- 地图标记只做可读的灰盒提示，不参与碰撞与射线（§9A.3、§9A.5）：
-- 感染区是暗红平垫；枪械补给点与弹药箱点位是不同颜色的小方垫。
local function makeMarker(
	folder: Folder,
	name: string,
	position: GreyboxLayout.Vec3,
	size: number,
	color: Color3,
	transparency: number
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = Vector3.new(size, 0.12, size)
	part.CFrame = CFrame.new(position.x, ActiveMap.get().floorTopY + 0.06, position.z)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = folder
	return part
end

-- §10.1：医院端的解药补给槽用薄荷色小垫 + CURE 标签标记（实际道具由 CureService 生成）。
local function makeMarkerLabel(part: Part, text: string, color: Color3, maxDistance: number)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(120, 32)
	billboard.StudsOffset = Vector3.new(0, 2.4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = maxDistance
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeColor3 = VisualTokens.Color.Night
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = billboard
	return label
end

local function makeMarkers(folder: Folder)
	for index, point in ActiveMap.get().infectionZones do
		makeMarker(folder, `InfectionZone{index}`, point, 14, VisualTokens.Color.Zombie, 0.72)
	end
	for index, point in ActiveMap.get().supplyPoints do
		makeMarker(folder, `SupplyPoint{index}`, point, 5, VisualTokens.Color.Human, 0.45)
	end
	for index, point in ActiveMap.get().ammoCratePoints do
		makeMarker(folder, `AmmoCratePoint{index}`, point, 4, VisualTokens.Color.Disconnected, 0.45)
	end
	for index, point in ActiveMap.get().cureSlots do
		local pad = makeMarker(folder, `CureSlot{index}`, point, 5, VisualTokens.Color.Cured, 0.42)
		makeMarkerLabel(pad, "CURE", VisualTokens.Color.Cured, 60)
	end
end

-- §13.2：撤离区 = 非碰撞的蓝白发光垫 + 一个简单门框 + 顶部 EXIT 指示。
-- 门框同样不碰撞，避免 16 studs 的判定区被几何挤成单路；视觉在 EXTRACTION 阶段点亮。
local function makeExitGate(folder: Folder): ExitGate
	local zone = ActiveMap.get().extractionZone
	local center = zone.center
	local y = ActiveMap.get().floorTopY

	local pad = Instance.new("Part")
	pad.Name = "ExitZone"
	pad.Anchored = true
	pad.Size = Vector3.new(zone.diameter, 0.12, zone.diameter)
	pad.CFrame = CFrame.new(center.x, y + 0.06, center.z)
	pad.Material = Enum.Material.Neon
	pad.Color = VisualTokens.Color.Exit
	pad.Transparency = 0.7
	pad.CanCollide = false
	pad.CanTouch = false
	pad.CanQuery = false
	pad.CastShadow = false
	pad.Parent = folder

	local frameParts: { Part } = {}
	local postOffset = zone.diameter / 2 + 1
	local postHeight = 10
	for _, side in { -1, 1 } do
		local post = Instance.new("Part")
		post.Name = `ExitPost{side}`
		post.Anchored = true
		post.Size = Vector3.new(1, postHeight, 1)
		post.CFrame = CFrame.new(center.x + side * postOffset, y + postHeight / 2, center.z - postOffset)
		post.Material = Enum.Material.SmoothPlastic
		post.Color = VisualTokens.Color.SurfaceConcrete
		post.Transparency = 0.2
		post.CanCollide = false
		post.CanTouch = false
		post.CanQuery = false
		post.CastShadow = false
		post.Parent = folder
		table.insert(frameParts, post)
	end

	local lintel = Instance.new("Part")
	lintel.Name = "ExitLintel"
	lintel.Anchored = true
	lintel.Size = Vector3.new(postOffset * 2 + 1, 1, 1)
	lintel.CFrame = CFrame.new(center.x, y + postHeight + 0.5, center.z - postOffset)
	lintel.Material = Enum.Material.SmoothPlastic
	lintel.Color = VisualTokens.Color.SurfaceConcrete
	lintel.Transparency = 0.2
	lintel.CanCollide = false
	lintel.CanTouch = false
	lintel.CanQuery = false
	lintel.CastShadow = false
	lintel.Parent = folder
	table.insert(frameParts, lintel)

	local light = Instance.new("PointLight")
	light.Name = "ExitGlow"
	light.Color = VisualTokens.Color.Exit
	light.Brightness = 0
	light.Range = zone.diameter
	light.Enabled = false
	light.Parent = pad

	local label = makeMarkerLabel(pad, "EXIT — CLOSED", VisualTokens.Color.TextSecondary, 140)

	return {
		pad = pad,
		frameParts = frameParts,
		light = light,
		label = label,
		open = false,
	}
end

local function applyExitVisual(gate: ExitGate, open: boolean)
	gate.open = open
	gate.pad.Transparency = if open then 0.28 else 0.72
	gate.pad.Color = if open then VisualTokens.Color.Exit else VisualTokens.Color.SurfaceConcrete
	gate.light.Enabled = open
	gate.light.Brightness = if open then 2.4 else 0
	gate.label.Text = if open then "EXIT — OPEN" else "EXIT — CLOSED"
	gate.label.TextColor3 = if open then VisualTokens.Color.Exit else VisualTokens.Color.TextSecondary
	for _, part in gate.frameParts do
		part.Color = if open then VisualTokens.Color.Exit else VisualTokens.Color.SurfaceConcrete
		part.Material = if open then Enum.Material.Neon else Enum.Material.SmoothPlastic
	end
end

-- EXTRACTION 阶段点亮；回合开始/清理时关闭。重复调用幂等。
function GreyboxBuilder.setExitOpen(open: boolean)
	local gate = currentExit
	if gate == nil or gate.open == open then
		return
	end
	applyExitVisual(gate, open)
end

local function makeFallbackSpawn(folder: Folder): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "FallbackSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, ActiveMap.get().floorTopY + 0.5, -70)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false -- 不参与扑咬视线射线（视线只应被 MapStatic 墙体遮挡）
	spawn.Neutral = true
	spawn.AllowTeamChangeOnTouch = false
	spawn.Duration = 0
	spawn.Parent = folder
	return spawn
end

-- 重建整张地图。Bootstrap 启动时调用一次，RoundService 换图时再调用；销毁旧 Map 保证不会叠加几何。
function GreyboxBuilder.build(): BuildResult
	ensureCollisionGroup()

	local previous = Workspace:FindFirstChild("Map")
	if previous ~= nil then
		previous:Destroy()
	end

	currentExit = nil

	local folder = Instance.new("Folder")
	folder.Name = "Map"

	makeBlock(folder, ActiveMap.get().floor, 0)
	for index, wall in ActiveMap.get().walls do
		makeBlock(folder, wall, index)
	end
	for index, obstacle in ActiveMap.get().obstacles do
		makeBlock(folder, obstacle, index)
	end
	makeMarkers(folder)
	local exitGate = makeExitGate(folder)
	currentExit = exitGate
	applyExitVisual(exitGate, false)
	makeKillPlane(folder)
	makeFallbackSpawn(folder)

	folder.Parent = Workspace
	return {
		folder = folder,
		killPlaneY = ActiveMap.get().killPlaneY,
	}
end

return table.freeze(GreyboxBuilder)
