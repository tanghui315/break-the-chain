--!strict
-- Gate A0 灰盒地图的纯数据布局（GDB V1.1 §24.4）：SMALL 约 180×180 studs，走廊宽 ≥ 10，门宽 ≥ 6、高 ≥ 9。
-- 纯模块：不引用任何 Roblox 全局对象，可在 Lune 中测试；GreyboxBuilder 只负责把数据变成 Part。

export type Vec3 = { x: number, y: number, z: number }

export type BlockKind = "Floor" | "Wall" | "Obstacle" | "KillPlane"

export type Block = {
	id: string,
	kind: BlockKind,
	center: Vec3,
	size: Vec3,
}

export type Door = {
	id: string,
	center: Vec3,
	width: number,
	height: number,
	-- 门洞所在的墙体走向：X 表示墙沿 X 展开、通行方向为 Z。
	axis: "X" | "Z",
}

export type Corridor = {
	id: string,
	axis: "X" | "Z",
	center: Vec3,
	width: number,
	length: number,
}

export type Waypoint = {
	id: string,
	position: Vec3,
}

export type Edge = {
	a: string,
	b: string,
}

export type Layout = {
	mapSize: number,
	wallHeight: number,
	floorTopY: number,
	characterSpawnY: number,
	killPlaneY: number,
	floor: Block,
	walls: { Block },
	obstacles: { Block },
	doors: { Door },
	corridors: { Corridor },
	spawnPoints: { Vec3 },
	-- §9A.3：丧尸复活点，每张图至少 2 处；A0.5 灰盒取四角，远离中部交火区。
	infectionZones: { Vec3 },
	-- §9A.5：开局补给点。手枪与电击枪从这里按人数档生成，LARGE 需要 7 个（5 手枪 + 2 电击枪）。
	supplyPoints: { Vec3 },
	-- §9A.5：弹药箱独立点位，不与枪械补给点复用，保证 LARGE 档 3 个箱子都有位置。
	ammoCratePoints: { Vec3 },
	waypoints: { Waypoint },
	edges: { Edge },
}

local function freezeVec(v: Vec3): Vec3
	return table.freeze(v)
end

local function freezeBlock(block: Block): Block
	return table.freeze({
		id = block.id,
		kind = block.kind,
		center = freezeVec(block.center),
		size = freezeVec(block.size),
	})
end

local function freezeList<T>(items: { T }, freezeItem: (T) -> T): { T }
	local out = {}
	for _, item in items do
		table.insert(out, freezeItem(item))
	end
	return table.freeze(out)
end

local function block(
	id: string,
	kind: BlockKind,
	cx: number,
	cy: number,
	cz: number,
	sx: number,
	sy: number,
	sz: number
): Block
	return { id = id, kind = kind, center = { x = cx, y = cy, z = cz }, size = { x = sx, y = sy, z = sz } }
end

local WALL_HEIGHT = 14
local WALL_Y = WALL_HEIGHT / 2
local MAP_SIZE = 180

-- 墙体中心线取 ±40 / ±91：中央大厅 80×80（含墙），四边各留一条外圈走廊。
-- 中央大厅四面各有一个 8 studs 宽、通高 14 的门洞；外圈由北/南/东三条走廊记录。
local walls: { Block } = {
	-- 外圈（内表面位于 ±90）
	block("OuterNorth", "Wall", 0, WALL_Y, -91, MAP_SIZE + 4, WALL_HEIGHT, 2),
	block("OuterSouth", "Wall", 0, WALL_Y, 91, MAP_SIZE + 4, WALL_HEIGHT, 2),
	block("OuterWest", "Wall", -91, WALL_Y, 0, 2, WALL_HEIGHT, MAP_SIZE + 4),
	block("OuterEast", "Wall", 91, WALL_Y, 0, 2, WALL_HEIGHT, MAP_SIZE + 4),

	-- 中央大厅北墙 / 南墙：中间留 8 宽门洞（x = -4 .. 4）
	block("DividerNorthA", "Wall", -47, WALL_Y, -40, 86, WALL_HEIGHT, 2),
	block("DividerNorthB", "Wall", 47, WALL_Y, -40, 86, WALL_HEIGHT, 2),
	block("DividerSouthA", "Wall", -47, WALL_Y, 40, 86, WALL_HEIGHT, 2),
	block("DividerSouthB", "Wall", 47, WALL_Y, 40, 86, WALL_HEIGHT, 2),

	-- 中央大厅西墙 / 东墙：中间留 8 宽门洞（z = -4 .. 4），只覆盖大厅高度范围
	block("DividerWestA", "Wall", -40, WALL_Y, -22, 2, WALL_HEIGHT, 36),
	block("DividerWestB", "Wall", -40, WALL_Y, 22, 2, WALL_HEIGHT, 36),
	block("DividerEastA", "Wall", 40, WALL_Y, -22, 2, WALL_HEIGHT, 36),
	block("DividerEastB", "Wall", 40, WALL_Y, 22, 2, WALL_HEIGHT, 36),
}

local obstacles: { Block } = {
	-- 中央大厅四根柱子：绕柱转向是灰盒阶段唯一的“假动作”道具
	block("PillarNW", "Obstacle", -22, 6, -22, 4, 12, 4),
	block("PillarNE", "Obstacle", 22, 6, -22, 4, 12, 4),
	block("PillarSW", "Obstacle", -22, 6, 22, 4, 12, 4),
	block("PillarSE", "Obstacle", 22, 6, 22, 4, 12, 4),

	-- 外圈掩体，给长走廊制造视线遮挡
	block("CoverNW", "Obstacle", -60, 6, -60, 5, 12, 5),
	block("CoverNE", "Obstacle", 60, 6, -60, 5, 12, 5),
	block("CoverSW", "Obstacle", -60, 6, 60, 5, 12, 5),
	block("CoverSE", "Obstacle", 60, 6, 60, 5, 12, 5),
}

local doors: { Door } = {
	{ id = "DoorNorth", center = { x = 0, y = WALL_Y, z = -40 }, width = 8, height = WALL_HEIGHT, axis = "X" },
	{ id = "DoorSouth", center = { x = 0, y = WALL_Y, z = 40 }, width = 8, height = WALL_HEIGHT, axis = "X" },
	{ id = "DoorWest", center = { x = -40, y = WALL_Y, z = 0 }, width = 8, height = WALL_HEIGHT, axis = "Z" },
	{ id = "DoorEast", center = { x = 40, y = WALL_Y, z = 0 }, width = 8, height = WALL_HEIGHT, axis = "Z" },
}

-- 走廊宽度按两侧墙面净距计算：北/南为 z 从 -90 到 -41 / 41 到 90，东为 x 从 41 到 90。
local corridors: { Corridor } = {
	{ id = "NorthCorridor", axis = "X", center = { x = 0, y = 0, z = -65.5 }, width = 49, length = MAP_SIZE },
	{ id = "SouthCorridor", axis = "X", center = { x = 0, y = 0, z = 65.5 }, width = 49, length = MAP_SIZE },
	{ id = "EastCorridor", axis = "Z", center = { x = 65.5, y = 0, z = 0 }, width = 49, length = MAP_SIZE },
}

-- 8 个出生点：四角 + 四边中点，均避开墙体与掩体。
local spawnPoints: { Vec3 } = {
	{ x = -70, y = 0, z = -70 },
	{ x = 0, y = 0, z = -70 },
	{ x = 70, y = 0, z = -70 },
	{ x = 70, y = 0, z = 0 },
	{ x = 70, y = 0, z = 70 },
	{ x = 0, y = 0, z = 70 },
	{ x = -70, y = 0, z = 70 },
	{ x = -70, y = 0, z = 0 },
}

-- 丧尸复活区：四角内侧。距外圈出生点约 17 studs，RespawnPicker 会优先选离人类最远的一处；
-- 灰盒地图不大，没有合格点时会走 FALLBACK，这符合 §9A.3 的退化规则。
local infectionZones: { Vec3 } = {
	{ x = -82, y = 0, z = -82 },
	{ x = 82, y = 0, z = -82 },
	{ x = 82, y = 0, z = 82 },
	{ x = -82, y = 0, z = 82 },
}

-- 枪械补给点：外圈走廊与大厅边角，避开柱子/掩体和出生点。共 10 个，满足 LARGE 档 7 把枪。
local supplyPoints: { Vec3 } = {
	{ x = -70, y = 0, z = -45 },
	{ x = 0, y = 0, z = -58 },
	{ x = 70, y = 0, z = -45 },
	{ x = 55, y = 0, z = 0 },
	{ x = 70, y = 0, z = 45 },
	{ x = 0, y = 0, z = 58 },
	{ x = -70, y = 0, z = 45 },
	{ x = -55, y = 0, z = 0 },
	{ x = -14, y = 0, z = -14 },
	{ x = 14, y = 0, z = 14 },
}

-- 弹药箱点位：大厅四象限边缘，取用后 90 秒原地刷新（§9A.5）。
local ammoCratePoints: { Vec3 } = {
	{ x = 0, y = 0, z = -22 },
	{ x = 22, y = 0, z = 0 },
	{ x = 0, y = 0, z = 22 },
	{ x = -22, y = 0, z = 0 },
}

-- 路点图：外圈环线 + 中央大厅轴线，所有连线都从门洞穿过或沿开阔走廊。
local waypoints: { Waypoint } = {
	{ id = "W1", position = { x = -70, y = 0, z = -70 } },
	{ id = "W2", position = { x = 0, y = 0, z = -70 } },
	{ id = "W3", position = { x = 70, y = 0, z = -70 } },
	{ id = "W4", position = { x = 70, y = 0, z = 0 } },
	{ id = "W5", position = { x = 70, y = 0, z = 70 } },
	{ id = "W6", position = { x = 0, y = 0, z = 70 } },
	{ id = "W7", position = { x = -70, y = 0, z = 70 } },
	{ id = "W8", position = { x = -70, y = 0, z = 0 } },
	{ id = "W9", position = { x = 0, y = 0, z = 0 } },
	{ id = "W10", position = { x = 0, y = 0, z = -40 } },
	{ id = "W11", position = { x = 0, y = 0, z = 40 } },
	{ id = "W12", position = { x = -40, y = 0, z = 0 } },
	{ id = "W13", position = { x = 40, y = 0, z = 0 } },
}

local edges: { Edge } = {
	-- 外圈环线
	{ a = "W1", b = "W2" },
	{ a = "W2", b = "W3" },
	{ a = "W3", b = "W4" },
	{ a = "W4", b = "W5" },
	{ a = "W5", b = "W6" },
	{ a = "W6", b = "W7" },
	{ a = "W7", b = "W8" },
	{ a = "W8", b = "W1" },

	-- 四条门洞轴线
	{ a = "W2", b = "W10" },
	{ a = "W10", b = "W9" },
	{ a = "W6", b = "W11" },
	{ a = "W11", b = "W9" },
	{ a = "W8", b = "W12" },
	{ a = "W12", b = "W9" },
	{ a = "W4", b = "W13" },
	{ a = "W13", b = "W9" },
}

local Layout: Layout = {
	mapSize = MAP_SIZE,
	wallHeight = WALL_HEIGHT,
	floorTopY = 0,
	characterSpawnY = 3,
	killPlaneY = -40,
	floor = block("Floor", "Floor", 0, -2, 0, MAP_SIZE, 4, MAP_SIZE),
	walls = freezeList(walls, freezeBlock),
	obstacles = freezeList(obstacles, freezeBlock),
	doors = freezeList(doors, function(door)
		return table.freeze({
			id = door.id,
			center = freezeVec(door.center),
			width = door.width,
			height = door.height,
			axis = door.axis,
		})
	end),
	corridors = freezeList(corridors, function(corridor)
		return table.freeze({
			id = corridor.id,
			axis = corridor.axis,
			center = freezeVec(corridor.center),
			width = corridor.width,
			length = corridor.length,
		})
	end),
	spawnPoints = freezeList(spawnPoints, freezeVec),
	infectionZones = freezeList(infectionZones, freezeVec),
	supplyPoints = freezeList(supplyPoints, freezeVec),
	ammoCratePoints = freezeList(ammoCratePoints, freezeVec),
	waypoints = freezeList(waypoints, function(waypoint)
		return table.freeze({ id = waypoint.id, position = freezeVec(waypoint.position) })
	end),
	edges = freezeList(edges, function(edge)
		return table.freeze({ a = edge.a, b = edge.b })
	end),
}

return table.freeze(Layout)
