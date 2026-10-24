--!strict
-- 把 GreyboxLayout 的纯数据建成 workspace.Map 下的锚定 Part（GDB V1.1 §24.4）。
-- 所有地图 Part 进入 MapStatic 碰撞组：扑咬视线射线只检测该组，角色互相之间不遮挡判定。

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local GreyboxLayout = require(script.Parent.GreyboxLayout)

export type BuildResult = {
	folder: Folder,
	killPlaneY: number,
}

local MAP_COLLISION_GROUP = "MapStatic"

local GreyboxBuilder = {}

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
	part.Size = Vector3.new(GreyboxLayout.mapSize * 2, 4, GreyboxLayout.mapSize * 2)
	part.CFrame = CFrame.new(0, GreyboxLayout.killPlaneY - 2, 0)
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

local function makeFallbackSpawn(folder: Folder): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "FallbackSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, GreyboxLayout.floorTopY + 0.5, -70)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false -- 不参与扑咬视线射线（视线只应被 MapStatic 墙体遮挡）
	spawn.Neutral = true
	spawn.AllowTeamChangeOnTouch = false
	spawn.Duration = 0
	spawn.Parent = folder
	return spawn
end

-- 重建整张地图。Bootstrap 在服务初始化时调用一次；销毁旧 Map 保证重复启动不会叠加几何。
function GreyboxBuilder.build(): BuildResult
	ensureCollisionGroup()

	local previous = Workspace:FindFirstChild("Map")
	if previous ~= nil then
		previous:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Map"

	makeBlock(folder, GreyboxLayout.floor, 0)
	for index, wall in GreyboxLayout.walls do
		makeBlock(folder, wall, index)
	end
	for index, obstacle in GreyboxLayout.obstacles do
		makeBlock(folder, obstacle, index)
	end
	makeKillPlane(folder)
	makeFallbackSpawn(folder)

	folder.Parent = Workspace
	return {
		folder = folder,
		killPlaneY = GreyboxLayout.killPlaneY,
	}
end

return table.freeze(GreyboxBuilder)
