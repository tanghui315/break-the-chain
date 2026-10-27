--!strict
-- 灰盒布局的尺寸与可达性测试（GDB V1.1 §14、§24.4）：SMALL 与 MEDIUM 两张图跑同一套几何检查——
-- 地图边界、走廊/门洞尺寸、出生点安全、点位不压墙、路点图连通且连线不穿墙；MEDIUM 另查 §14 区域结构。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local GreyboxLayout = require("../../src/server/world/GreyboxLayout")
local GreyboxLayoutMedium = require("../../src/server/world/GreyboxLayoutMedium")
local ActiveMap = require("../../src/server/world/ActiveMap")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

type Layout = GreyboxLayout.Layout

local SPAWN_CLEARANCE = 2
local WAYPOINT_CLEARANCE = 1
-- 路点连线离墙/掩体至少 1.5 studs（角色半宽约 1），Bot 直线走不会蹭墙卡住。
local EDGE_CLEARANCE = 1.5
local MAX_ROUTE_LENGTH = 400

local function footprintContains(block: GreyboxLayout.Block, x: number, z: number, margin: number): boolean
	return math.abs(x - block.center.x) <= block.size.x / 2 + margin
		and math.abs(z - block.center.z) <= block.size.z / 2 + margin
end

local function insideSolid(L: Layout, x: number, z: number, margin: number): boolean
	for _, wall in L.walls do
		if footprintContains(wall, x, z, margin) then
			return true
		end
	end
	for _, obstacle in L.obstacles do
		if footprintContains(obstacle, x, z, margin) then
			return true
		end
	end
	return false
end

local function distance(a: GreyboxLayout.Vec3, b: GreyboxLayout.Vec3): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

local function waypointMap(L: Layout): { [string]: GreyboxLayout.Waypoint }
	local byId: { [string]: GreyboxLayout.Waypoint } = {}
	for _, waypoint in L.waypoints do
		byId[waypoint.id] = waypoint
	end
	return byId
end

local function adjacencyOf(L: Layout): { [string]: { string } }
	local adjacency: { [string]: { string } } = {}
	for _, waypoint in L.waypoints do
		adjacency[waypoint.id] = {}
	end
	for _, edge in L.edges do
		table.insert(adjacency[edge.a], edge.b)
		table.insert(adjacency[edge.b], edge.a)
	end
	return adjacency
end

local function nearestWaypoint(L: Layout, point: GreyboxLayout.Vec3): GreyboxLayout.Waypoint
	local best = L.waypoints[1]
	for _, waypoint in L.waypoints do
		if distance(waypoint.position, point) < distance(best.position, point) then
			best = waypoint
		end
	end
	return best
end

-- 单源最短路（路点数量很少，O(n²) Dijkstra 足够）。
local function shortestFrom(L: Layout, start: string): { [string]: number }
	local byId = waypointMap(L)
	local adjacency = adjacencyOf(L)
	local dist: { [string]: number } = { [start] = 0 }
	local done: { [string]: boolean } = {}
	while true do
		local current: string? = nil
		for id, d in dist do
			if not done[id] and (current == nil or d < dist[current :: string]) then
				current = id
			end
		end
		if current == nil then
			break
		end
		local id = current :: string
		done[id] = true
		for _, neighbor in adjacency[id] do
			local nd = dist[id] + distance(byId[id].position, byId[neighbor].position)
			if dist[neighbor] == nil or nd < dist[neighbor] then
				dist[neighbor] = nd
			end
		end
	end
	return dist
end

local function pointsClearOfSolid(L: Layout, points: { GreyboxLayout.Vec3 }, margin: number): boolean
	local half = L.mapSize / 2 - margin
	for _, point in points do
		if math.abs(point.x) > half or math.abs(point.z) > half then
			return false
		end
		if point.y ~= L.floorTopY then
			return false
		end
		if insideSolid(L, point.x, point.z, margin) then
			return false
		end
	end
	return true
end

local function geometrySuite(mapName: string, L: Layout, maxMapSize: number)
	describe(`{mapName} 地图边界`, function()
		it("地板不超过档位尺寸，且中心在原点", function()
			expect(L.floor.size.x <= maxMapSize).toBe(true)
			expect(L.floor.size.z <= maxMapSize).toBe(true)
			expect(L.floor.center.x).toBe(0)
			expect(L.floor.center.z).toBe(0)
			expect(L.mapSize).toBe(maxMapSize)
		end)

		it("所有墙体与掩体都落在地板范围内（含墙厚）", function()
			local limit = L.mapSize / 2 + 2
			local blocks: { GreyboxLayout.Block } = {}
			for _, wall in L.walls do
				table.insert(blocks, wall)
			end
			for _, obstacle in L.obstacles do
				table.insert(blocks, obstacle)
			end
			for _, item in blocks do
				expect(item.center.x - item.size.x / 2 >= -limit).toBe(true)
				expect(item.center.x + item.size.x / 2 <= limit).toBe(true)
				expect(item.center.z - item.size.z / 2 >= -limit).toBe(true)
				expect(item.center.z + item.size.z / 2 <= limit).toBe(true)
			end
		end)

		it("地板顶面就是角色出生高度基准", function()
			expect(L.floor.center.y + L.floor.size.y / 2).toBe(L.floorTopY)
			expect(L.characterSpawnY > L.floorTopY).toBe(true)
			expect(L.killPlaneY < L.floorTopY).toBe(true)
		end)
	end)

	describe(`{mapName} 走廊与门洞尺寸`, function()
		it("至少有三段走廊，宽度均 ≥ 10", function()
			expect(#L.corridors >= 3).toBe(true)
			for _, corridor in L.corridors do
				expect(corridor.width >= 10).toBe(true)
				expect(corridor.length > 0).toBe(true)
			end
		end)

		it("门洞宽 ≥ 6、高 ≥ 9，且门洞中心不压墙", function()
			expect(#L.doors >= 2).toBe(true)
			for _, door in L.doors do
				expect(door.width >= 6).toBe(true)
				expect(door.height >= 9).toBe(true)
				expect(insideSolid(L, door.center.x, door.center.z, 0)).toBe(false)
			end
		end)

		it("所有墙体高度足以覆盖门洞", function()
			for _, wall in L.walls do
				expect(wall.size.y >= 9).toBe(true)
			end
		end)
	end)

	describe(`{mapName} 出生点`, function()
		it("至少 6 个出生点且互不重叠", function()
			expect(#L.spawnPoints >= 6).toBe(true)
			for i = 1, #L.spawnPoints do
				for j = i + 1, #L.spawnPoints do
					expect(distance(L.spawnPoints[i], L.spawnPoints[j]) >= 10).toBe(true)
				end
			end
		end)

		it("出生点都在地图内且不压墙/掩体", function()
			expect(pointsClearOfSolid(L, L.spawnPoints, SPAWN_CLEARANCE)).toBe(true)
		end)
	end)

	describe(`{mapName} 战斗地图点位（§9A.3、§9A.5）`, function()
		it("至少 3 个感染区，四角/边缘展开且不压墙", function()
			expect(#L.infectionZones >= 3).toBe(true)
			expect(pointsClearOfSolid(L, L.infectionZones, 2)).toBe(true)
			local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
			for _, point in L.infectionZones do
				minX = math.min(minX, point.x)
				maxX = math.max(maxX, point.x)
				minZ = math.min(minZ, point.z)
				maxZ = math.max(maxZ, point.z)
			end
			expect(maxX - minX >= L.mapSize * 0.6).toBe(true)
			expect(maxZ - minZ >= L.mapSize * 0.6).toBe(true)
		end)

		it("至少 8 个枪械补给点（LARGE 需要 7），且互不重叠、不压墙", function()
			expect(#L.supplyPoints >= 8).toBe(true)
			expect(pointsClearOfSolid(L, L.supplyPoints, 2)).toBe(true)
			for i = 1, #L.supplyPoints do
				for j = i + 1, #L.supplyPoints do
					expect(distance(L.supplyPoints[i], L.supplyPoints[j]) >= 6).toBe(true)
				end
			end
		end)

		it("至少 3 个弹药箱点位，且与枪械补给点分开", function()
			expect(#L.ammoCratePoints >= 3).toBe(true)
			expect(pointsClearOfSolid(L, L.ammoCratePoints, 2)).toBe(true)
			for _, crate in L.ammoCratePoints do
				for _, supply in L.supplyPoints do
					expect(distance(crate, supply) > 2).toBe(true)
				end
			end
		end)
	end)

	describe(`{mapName} 撤离区与医院解药槽（§10.1、§13.2）`, function()
		it("撤离区直径 16，不压墙，且远离人类出生点", function()
			local zone = L.extractionZone
			expect(zone.diameter).toBe(16)
			-- 与平衡配置的撤离判定直径保持一致，避免地图与规则漂移。
			expect(zone.diameter).toBe((BalanceConfig :: any).Greybox.ExtractZoneDiameter)
			expect(zone.center.y).toBe(L.floorTopY)
			expect(insideSolid(L, zone.center.x, zone.center.z, zone.diameter / 2)).toBe(false)
			expect(math.abs(zone.center.x) <= L.mapSize / 2).toBe(true)
			expect(math.abs(zone.center.z) <= L.mapSize / 2).toBe(true)
			local nearest = math.huge
			for _, spawnPoint in L.spawnPoints do
				nearest = math.min(nearest, distance(spawnPoint, zone.center))
			end
			expect(nearest >= 40).toBe(true)
		end)

		it("撤离区与感染区保持距离（§9A.3 复活点离撤离区足够远）", function()
			for _, infectionZone in L.infectionZones do
				expect(distance(infectionZone, L.extractionZone.center) >= 80).toBe(true)
			end
		end)

		it("撤离区至少两路可达（最近路点有 ≥ 2 条连线）", function()
			local exitWaypoint = nearestWaypoint(L, L.extractionZone.center)
			expect(#adjacencyOf(L)[exitWaypoint.id] >= 2).toBe(true)
		end)

		it("至少 3 个解药槽，都在医院端（西侧）且不压墙、互不重叠", function()
			local slots = L.cureSlots
			expect(#slots >= 3).toBe(true)
			expect(pointsClearOfSolid(L, slots, 2)).toBe(true)
			for _, slot in slots do
				expect(slot.x < -L.mapSize / 3).toBe(true)
			end
			for i = 1, #slots do
				for j = i + 1, #slots do
					expect(distance(slots[i], slots[j]) >= 8).toBe(true)
				end
			end
		end)

		it("解药槽不与枪械补给点/弹药箱点位重叠", function()
			for _, slot in L.cureSlots do
				for _, supply in L.supplyPoints do
					expect(distance(slot, supply) > 4).toBe(true)
				end
				for _, crate in L.ammoCratePoints do
					expect(distance(slot, crate) > 4).toBe(true)
				end
			end
		end)
	end)

	describe(`{mapName} Bot 路点图`, function()
		it("每条边都连接已存在的路点且长度 > 0", function()
			local byId = waypointMap(L)
			expect(#L.edges > 0).toBe(true)
			for _, edge in L.edges do
				local a = byId[edge.a]
				local b = byId[edge.b]
				assert(a and b, `边 {edge.a}-{edge.b} 引用了不存在的路点`)
				expect(distance(a.position, b.position) > 0).toBe(true)
				expect(edge.a ~= edge.b).toBe(true)
			end
		end)

		it("路点 id 不重复，且都在地图内、不压墙/掩体", function()
			local seen: { [string]: boolean } = {}
			for _, waypoint in L.waypoints do
				expect(seen[waypoint.id] == nil).toBe(true)
				seen[waypoint.id] = true
			end
			local positions: { GreyboxLayout.Vec3 } = {}
			for _, waypoint in L.waypoints do
				table.insert(positions, waypoint.position)
			end
			expect(pointsClearOfSolid(L, positions, WAYPOINT_CLEARANCE)).toBe(true)
		end)

		it("路点连线不穿墙/掩体（离实体 ≥ 1.5 studs）", function()
			local byId = waypointMap(L)
			for _, edge in L.edges do
				local a = byId[edge.a].position
				local b = byId[edge.b].position
				local steps = math.max(1, math.ceil(distance(a, b)))
				for step = 0, steps do
					local t = step / steps
					local x = a.x + (b.x - a.x) * t
					local z = a.z + (b.z - a.z) * t
					assert(not insideSolid(L, x, z, EDGE_CLEARANCE), `边 {edge.a}-{edge.b} 在 ({x}, {z}) 处贴墙`)
				end
			end
		end)

		it(`路点图连通，任意两点最短路 ≤ {MAX_ROUTE_LENGTH} studs`, function()
			for _, waypoint in L.waypoints do
				local dist = shortestFrom(L, waypoint.id)
				for _, other in L.waypoints do
					local d = dist[other.id]
					assert(d ~= nil, `{waypoint.id} 无法到达 {other.id}`)
					expect(d <= MAX_ROUTE_LENGTH).toBe(true)
				end
			end
		end)
	end)
end

geometrySuite("SMALL", GreyboxLayout, 180)
geometrySuite("MEDIUM", GreyboxLayoutMedium, 260)

describe("MEDIUM 区域结构（§14）", function()
	local L = GreyboxLayoutMedium

	local function doorsWithPrefix(prefix: string): number
		local count = 0
		for _, door in L.doors do
			if string.sub(door.id, 1, #prefix) == prefix then
				count += 1
			end
		end
		return count
	end

	it("8～15 人档有 ≥ 15 个人类出生点，掩体数量是 SMALL 的数倍", function()
		expect(#L.spawnPoints >= 15).toBe(true)
		expect(#L.obstacles >= #GreyboxLayout.obstacles * 3).toBe(true)
		expect(#L.infectionZones >= 4).toBe(true)
	end)

	it("医院与地铁口都有 ≥ 2 个入口", function()
		expect(doorsWithPrefix("Hospital") >= 2).toBe(true)
		expect(doorsWithPrefix("Subway") >= 2).toBe(true)
	end)

	it("医院路点至少两条独立入口路线", function()
		expect(#adjacencyOf(L)["Hospital"] >= 2).toBe(true)
	end)

	it("解药槽都在医院围墙之内", function()
		for _, slot in L.cureSlots do
			expect(slot.x > -130 and slot.x < -60).toBe(true)
			expect(slot.z > -130 and slot.z < -60).toBe(true)
		end
	end)

	it("中央街口是开阔十字，四条轴线通往街道", function()
		local adjacency = adjacencyOf(L)
		expect(#adjacency["J"]).toBe(4)
		expect(insideSolid(L, 0, 0, 8)).toBe(false)
	end)
end)

describe("ActiveMap 选图", function()
	it("人数档映射：SMALL → 180 图，MEDIUM/LARGE → 260 图", function()
		expect(ActiveMap.variantForTier("SMALL")).toBe("GREYBOX_SMALL")
		expect(ActiveMap.variantForTier("MEDIUM")).toBe("GREYBOX_MEDIUM")
		expect(ActiveMap.variantForTier("LARGE")).toBe("GREYBOX_MEDIUM")
		for _, tier in BalanceConfig.PlayerCountTiers do
			local layout = ActiveMap.layoutFor(ActiveMap.variantForTier(tier.mapTier))
			if tier.min >= 8 then
				expect(layout.mapSize).toBe(260)
			else
				expect(layout.mapSize).toBe(180)
			end
		end
	end)

	it("调试覆盖值解析", function()
		expect(ActiveMap.parseVariant("MEDIUM")).toBe("GREYBOX_MEDIUM")
		expect(ActiveMap.parseVariant("GREYBOX_SMALL")).toBe("GREYBOX_SMALL")
		expect(ActiveMap.parseVariant("") == nil).toBe(true)
		expect(ActiveMap.parseVariant(nil) == nil).toBe(true)
	end)

	it("set 返回是否切换，get 跟随切换", function()
		expect(ActiveMap.getVariant()).toBe("GREYBOX_SMALL")
		expect(ActiveMap.set("GREYBOX_SMALL")).toBe(false)
		expect(ActiveMap.set("GREYBOX_MEDIUM")).toBe(true)
		expect(ActiveMap.get().mapSize).toBe(260)
		expect(ActiveMap.set("GREYBOX_SMALL")).toBe(true)
		expect(ActiveMap.get().mapSize).toBe(180)
	end)
end)

TestKit.finish()
