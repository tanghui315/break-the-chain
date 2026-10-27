--!strict
-- MEDIUM 灰盒地图（GDB V1.1 §14、§24.4）：260×260 studs，8～15 人档使用。
-- 区域结构：西北医院（解药点，两道门）、北广场、东北控制室（两道门）、西侧庭院、中央街口（车辆掩体）、
-- 东侧停车场（柱阵）、西南/东南后巷、南侧地铁口（撤离区，三个入口）。四条 20 宽街道（x/z = ±45）
-- 把地图切成 3×3 街区，每个地标至少两路可达。
-- 纯模块：数据结构与 SMALL 相同（GreyboxLayout.Layout），GreyboxBuilder / ActiveMap 负责落地与切换。

local GreyboxLayout = require("./GreyboxLayout")

type Vec3 = GreyboxLayout.Vec3
type Block = GreyboxLayout.Block
type BlockKind = GreyboxLayout.BlockKind
type Door = GreyboxLayout.Door
type Corridor = GreyboxLayout.Corridor
type Waypoint = GreyboxLayout.Waypoint
type Edge = GreyboxLayout.Edge
type Layout = GreyboxLayout.Layout

local function freezeVec(v: Vec3): Vec3
	return table.freeze(v)
end

local function freezeBlock(item: Block): Block
	return table.freeze({
		id = item.id,
		kind = item.kind,
		center = freezeVec(item.center),
		size = freezeVec(item.size),
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

local function v(x: number, z: number): Vec3
	return { x = x, y = 0, z = z }
end

local WALL_HEIGHT = 14
local WALL_Y = WALL_HEIGHT / 2
local MAP_SIZE = 260

local walls: { Block } = {
	-- 外圈（内表面位于 ±130）
	block("OuterNorth", "Wall", 0, WALL_Y, -131, MAP_SIZE + 4, WALL_HEIGHT, 2),
	block("OuterSouth", "Wall", 0, WALL_Y, 131, MAP_SIZE + 4, WALL_HEIGHT, 2),
	block("OuterWest", "Wall", -131, WALL_Y, 0, 2, WALL_HEIGHT, MAP_SIZE + 4),
	block("OuterEast", "Wall", 131, WALL_Y, 0, 2, WALL_HEIGHT, MAP_SIZE + 4),

	-- 医院（西北，x/z ∈ [-130, -60]）：东墙门洞 z = -100..-90，南墙门洞 x = -100..-90
	block("HospitalEastA", "Wall", -60, WALL_Y, -115.5, 2, WALL_HEIGHT, 31),
	block("HospitalEastB", "Wall", -60, WALL_Y, -74.5, 2, WALL_HEIGHT, 31),
	block("HospitalSouthA", "Wall", -115.5, WALL_Y, -60, 31, WALL_HEIGHT, 2),
	block("HospitalSouthB", "Wall", -74.5, WALL_Y, -60, 31, WALL_HEIGHT, 2),

	-- 控制室（东北，与医院镜像）：西墙门洞 z = -100..-90，南墙门洞 x = 90..100
	block("ControlWestA", "Wall", 60, WALL_Y, -115.5, 2, WALL_HEIGHT, 31),
	block("ControlWestB", "Wall", 60, WALL_Y, -74.5, 2, WALL_HEIGHT, 31),
	block("ControlSouthA", "Wall", 115.5, WALL_Y, -60, 31, WALL_HEIGHT, 2),
	block("ControlSouthB", "Wall", 74.5, WALL_Y, -60, 31, WALL_HEIGHT, 2),

	-- 地铁口大厅（南侧，x ∈ [-30, 30]，z ∈ [70, 130]）：北面 16 宽主入口，东西各一道侧门（z = 100..110）
	block("SubwayNorthA", "Wall", -19.5, WALL_Y, 70, 23, WALL_HEIGHT, 2),
	block("SubwayNorthB", "Wall", 19.5, WALL_Y, 70, 23, WALL_HEIGHT, 2),
	block("SubwayWestA", "Wall", -30, WALL_Y, 84.5, 2, WALL_HEIGHT, 31),
	block("SubwayWestB", "Wall", -30, WALL_Y, 120.5, 2, WALL_HEIGHT, 21),
	block("SubwayEastA", "Wall", 30, WALL_Y, 84.5, 2, WALL_HEIGHT, 31),
	block("SubwayEastB", "Wall", 30, WALL_Y, 120.5, 2, WALL_HEIGHT, 21),
}

local obstacles: { Block } = {
	-- 医院病床 / 控制室操作台：低矮掩体，不挡门、不压解药槽
	block("HospitalBedA", "Obstacle", -124, 2, -100, 6, 4, 10),
	block("HospitalBedB", "Obstacle", -100, 2, -124, 10, 4, 6),
	block("HospitalBedC", "Obstacle", -78, 2, -78, 6, 4, 6),
	block("ControlDeskA", "Obstacle", 124, 2, -100, 6, 4, 10),
	block("ControlDeskB", "Obstacle", 100, 2, -124, 10, 4, 6),
	block("ControlDeskC", "Obstacle", 78, 2, -78, 6, 4, 6),

	-- 北广场：雕像 + 两张长椅
	block("PlazaStatue", "Obstacle", 0, 4, -100, 8, 8, 8),
	block("PlazaBenchW", "Obstacle", -20, 2, -80, 8, 4, 3),
	block("PlazaBenchE", "Obstacle", 20, 2, -80, 8, 4, 3),

	-- 西侧庭院：花坛与喷泉，留出 z = 0 的穿行线
	block("CourtPlanterA", "Obstacle", -100, 3, -20, 12, 6, 4),
	block("CourtPlanterB", "Obstacle", -100, 3, 20, 12, 6, 4),
	block("CourtPlanterC", "Obstacle", -70, 3, -10, 4, 6, 6),
	block("CourtPlanterD", "Obstacle", -70, 3, 10, 4, 6, 6),
	block("CourtFountain", "Obstacle", -115, 2, 0, 6, 4, 6),

	-- 中央街口：四辆抛锚车辆，十字轴线保持通畅
	block("JunctionCarA", "Obstacle", -18, 3, -18, 10, 6, 5),
	block("JunctionCarB", "Obstacle", 18, 3, 18, 10, 6, 5),
	block("JunctionCarC", "Obstacle", 18, 3, -18, 5, 6, 10),
	block("JunctionCarD", "Obstacle", -18, 3, 18, 5, 6, 10),

	-- 东侧停车场：3×4 柱阵，z = 0 与 x = 80 留通道
	block("ParkPillar1", "Obstacle", 70, 6, -25, 3, 12, 3),
	block("ParkPillar2", "Obstacle", 70, 6, -10, 3, 12, 3),
	block("ParkPillar3", "Obstacle", 70, 6, 10, 3, 12, 3),
	block("ParkPillar4", "Obstacle", 70, 6, 25, 3, 12, 3),
	block("ParkPillar5", "Obstacle", 90, 6, -25, 3, 12, 3),
	block("ParkPillar6", "Obstacle", 90, 6, -10, 3, 12, 3),
	block("ParkPillar7", "Obstacle", 90, 6, 10, 3, 12, 3),
	block("ParkPillar8", "Obstacle", 90, 6, 25, 3, 12, 3),
	block("ParkPillar9", "Obstacle", 110, 6, -25, 3, 12, 3),
	block("ParkPillar10", "Obstacle", 110, 6, -10, 3, 12, 3),
	block("ParkPillar11", "Obstacle", 110, 6, 10, 3, 12, 3),
	block("ParkPillar12", "Obstacle", 110, 6, 25, 3, 12, 3),

	-- 西南 / 东南后巷：两间棚屋，制造绕行和视线遮挡
	block("YardShedSW", "Obstacle", -100, 6, 85, 20, 12, 10),
	block("YardStoreSW", "Obstacle", -72, 6, 122, 10, 12, 12),
	block("YardShedSE", "Obstacle", 100, 6, 85, 20, 12, 10),
	block("YardStoreSE", "Obstacle", 72, 6, 122, 10, 12, 12),

	-- 地铁大厅四根立柱
	block("SubwayPillarNW", "Obstacle", -15, 6, 90, 3, 12, 3),
	block("SubwayPillarNE", "Obstacle", 15, 6, 90, 3, 12, 3),
	block("SubwayPillarSW", "Obstacle", -15, 6, 120, 3, 12, 3),
	block("SubwayPillarSE", "Obstacle", 15, 6, 120, 3, 12, 3),

	-- 街道路障：切断长直视线，两侧各留约 8 studs 通行
	block("BarricadeNW", "Obstacle", -110, 3, -45, 8, 6, 3),
	block("BarricadeNE", "Obstacle", 110, 3, -45, 8, 6, 3),
	block("BarricadeSW", "Obstacle", -110, 3, 45, 8, 6, 3),
	block("BarricadeSE", "Obstacle", 110, 3, 45, 8, 6, 3),
	block("BarricadeWestNorth", "Obstacle", -45, 3, -110, 3, 6, 8),
	block("BarricadeEastNorth", "Obstacle", 45, 3, -110, 3, 6, 8),
}

local doors: { Door } = {
	{
		id = "HospitalEastDoor",
		center = { x = -60, y = WALL_Y, z = -95 },
		width = 10,
		height = WALL_HEIGHT,
		axis = "Z",
	},
	{
		id = "HospitalSouthDoor",
		center = { x = -95, y = WALL_Y, z = -60 },
		width = 10,
		height = WALL_HEIGHT,
		axis = "X",
	},
	{ id = "ControlWestDoor", center = { x = 60, y = WALL_Y, z = -95 }, width = 10, height = WALL_HEIGHT, axis = "Z" },
	{ id = "ControlSouthDoor", center = { x = 95, y = WALL_Y, z = -60 }, width = 10, height = WALL_HEIGHT, axis = "X" },
	{ id = "SubwayNorthDoor", center = { x = 0, y = WALL_Y, z = 70 }, width = 16, height = WALL_HEIGHT, axis = "X" },
	{ id = "SubwayWestDoor", center = { x = -30, y = WALL_Y, z = 105 }, width = 10, height = WALL_HEIGHT, axis = "Z" },
	{ id = "SubwayEastDoor", center = { x = 30, y = WALL_Y, z = 105 }, width = 10, height = WALL_HEIGHT, axis = "Z" },
}

-- 四条街道（宽 20，x/z ∈ ±35..±55），贯穿全图。
local corridors: { Corridor } = {
	{ id = "NorthStreet", axis = "X", center = { x = 0, y = 0, z = -45 }, width = 20, length = MAP_SIZE },
	{ id = "SouthStreet", axis = "X", center = { x = 0, y = 0, z = 45 }, width = 20, length = MAP_SIZE },
	{ id = "WestStreet", axis = "Z", center = { x = -45, y = 0, z = 0 }, width = 20, length = MAP_SIZE },
	{ id = "EastStreet", axis = "Z", center = { x = 45, y = 0, z = 0 }, width = 20, length = MAP_SIZE },
}

-- 18 个人类出生点：控制室 / 北广场 / 街道 / 庭院 / 停车场 / 后巷，距撤离区 ≥ 60。
-- 医院内不放出生点：解药需要专程去取（§10.1），否则开局就被出生在旁边的人拿走。
local spawnPoints: { Vec3 } = {
	v(-100, -45),
	v(-70, -45),
	v(105, -85),
	v(75, -105),
	v(-20, -110),
	v(20, -110),
	v(-45, -20),
	v(45, -20),
	v(-20, -45),
	v(20, -45),
	v(-85, -30),
	v(-85, 30),
	v(80, -18),
	v(100, 18),
	v(-20, 45),
	v(20, 45),
	v(-110, 100),
	v(110, 100),
}

-- 丧尸复活区：北广场、庭院西缘、停车场东缘、两个后巷角落，均距撤离区 ≥ 120。
local infectionZones: { Vec3 } = {
	v(0, -122),
	v(-122, -25),
	v(122, 25),
	v(-122, 122),
	v(122, 122),
}

-- 枪械补给点 11 个：街道、庭院、停车场、医院、控制室、地铁大厅。
local supplyPoints: { Vec3 } = {
	v(-45, -70),
	v(45, -70),
	v(-70, 45),
	v(70, 45),
	v(-105, 0),
	v(100, 0),
	v(0, -65),
	v(0, 25),
	v(-110, -110),
	v(110, -110),
	v(0, 85),
}

-- 弹药箱 4 个：四个街道路口。
local ammoCratePoints: { Vec3 } = {
	v(-45, -45),
	v(45, 45),
	v(90, -45),
	v(-90, 45),
}

-- §13.2：撤离区放在地铁大厅中央，北门 / 西门 / 东门三路可达。
local extractionZone: GreyboxLayout.ExtractionZone = {
	center = v(0, 105),
	diameter = 16,
}

-- §10.1：解药补给槽全部在医院内。
local cureSlots: { Vec3 } = {
	v(-118, -118),
	v(-118, -82),
	v(-90, -118),
}

local waypoints: { Waypoint } = {
	{ id = "J", position = v(0, 0) },
	{ id = "N", position = v(0, -45) },
	{ id = "S", position = v(0, 45) },
	{ id = "Wm", position = v(-45, 0) },
	{ id = "Em", position = v(45, 0) },
	{ id = "NW", position = v(-45, -45) },
	{ id = "NE", position = v(45, -45) },
	{ id = "SW", position = v(-45, 45) },
	{ id = "SE", position = v(45, 45) },
	{ id = "Plaza", position = v(0, -80) },
	{ id = "HospEastOut", position = v(-50, -95) },
	{ id = "HospEastIn", position = v(-68, -95) },
	{ id = "HospSouthOut", position = v(-95, -50) },
	{ id = "HospSouthIn", position = v(-95, -68) },
	{ id = "Hospital", position = v(-90, -90) },
	{ id = "CtrlWestOut", position = v(50, -95) },
	{ id = "CtrlWestIn", position = v(68, -95) },
	{ id = "CtrlSouthOut", position = v(95, -50) },
	{ id = "CtrlSouthIn", position = v(95, -68) },
	{ id = "Control", position = v(90, -90) },
	{ id = "Courtyard", position = v(-95, 0) },
	{ id = "Parking", position = v(80, 0) },
	{ id = "ParkNorth", position = v(80, -45) },
	{ id = "ParkSouth", position = v(80, 45) },
	{ id = "SubwayNorth", position = v(0, 62) },
	{ id = "Extraction", position = v(0, 105) },
	{ id = "SubwayWest", position = v(-42, 105) },
	{ id = "SubwayEast", position = v(42, 105) },
	{ id = "YardSW", position = v(-95, 110) },
	{ id = "YardSE", position = v(95, 110) },
}

local function e(a: string, b: string): Edge
	return { a = a, b = b }
end

local edges: { Edge } = {
	-- 中央十字与街道环线
	e("J", "N"),
	e("J", "S"),
	e("J", "Wm"),
	e("J", "Em"),
	e("N", "NW"),
	e("N", "NE"),
	e("S", "SW"),
	e("S", "SE"),
	e("Wm", "NW"),
	e("Wm", "SW"),
	e("Em", "NE"),
	e("Em", "SE"),

	-- 北广场
	e("N", "Plaza"),
	e("Plaza", "HospEastOut"),
	e("Plaza", "CtrlWestOut"),

	-- 医院两道门
	e("NW", "HospEastOut"),
	e("HospEastOut", "HospEastIn"),
	e("HospEastIn", "Hospital"),
	e("NW", "HospSouthOut"),
	e("HospSouthOut", "HospSouthIn"),
	e("HospSouthIn", "Hospital"),

	-- 控制室两道门
	e("NE", "CtrlWestOut"),
	e("CtrlWestOut", "CtrlWestIn"),
	e("CtrlWestIn", "Control"),
	e("NE", "CtrlSouthOut"),
	e("CtrlSouthOut", "CtrlSouthIn"),
	e("CtrlSouthIn", "Control"),

	-- 庭院 / 停车场
	e("Wm", "Courtyard"),
	e("Courtyard", "NW"),
	e("Courtyard", "SW"),
	e("Em", "Parking"),
	e("Parking", "ParkNorth"),
	e("ParkNorth", "NE"),
	e("ParkNorth", "CtrlSouthOut"),
	e("Parking", "ParkSouth"),
	e("ParkSouth", "SE"),

	-- 地铁口三路
	e("S", "SubwayNorth"),
	e("SubwayNorth", "Extraction"),
	e("SW", "SubwayWest"),
	e("SubwayWest", "Extraction"),
	e("SE", "SubwayEast"),
	e("SubwayEast", "Extraction"),

	-- 后巷
	e("SW", "YardSW"),
	e("YardSW", "SubwayWest"),
	e("SE", "YardSE"),
	e("YardSE", "SubwayEast"),
}

local Layout: Layout = {
	mapSize = MAP_SIZE,
	wallHeight = WALL_HEIGHT,
	floorTopY = 0,
	characterSpawnY = 3,
	killPlaneY = -40,
	floor = freezeBlock(block("Floor", "Floor", 0, -2, 0, MAP_SIZE, 4, MAP_SIZE)),
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
	extractionZone = table.freeze({
		center = freezeVec(extractionZone.center),
		diameter = extractionZone.diameter,
	}),
	cureSlots = freezeList(cureSlots, freezeVec),
	waypoints = freezeList(waypoints, function(waypoint)
		return table.freeze({ id = waypoint.id, position = freezeVec(waypoint.position) })
	end),
	edges = freezeList(edges, function(edge)
		return table.freeze({ a = edge.a, b = edge.b })
	end),
}

return table.freeze(Layout)
