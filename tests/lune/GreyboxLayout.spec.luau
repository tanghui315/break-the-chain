--!strict
-- 灰盒布局的尺寸与可达性测试（GDB V1.1 §24.4）：地图边界、走廊/门洞尺寸、出生点安全、路点图连通。

local TestKit = require("./TestKit")
local GreyboxLayout = require("../../src/server/world/GreyboxLayout")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local SPAWN_CLEARANCE = 2
local WAYPOINT_CLEARANCE = 1

local function footprintContains(block: GreyboxLayout.Block, x: number, z: number, margin: number): boolean
	return math.abs(x - block.center.x) <= block.size.x / 2 + margin
		and math.abs(z - block.center.z) <= block.size.z / 2 + margin
end

local function insideSolid(x: number, z: number, margin: number): boolean
	for _, wall in GreyboxLayout.walls do
		if footprintContains(wall, x, z, margin) then
			return true
		end
	end
	for _, obstacle in GreyboxLayout.obstacles do
		if footprintContains(obstacle, x, z, margin) then
			return true
		end
	end
	return false
end

local function edgeLength(edge: GreyboxLayout.Edge): number?
	local byId: { [string]: GreyboxLayout.Waypoint } = {}
	for _, waypoint in GreyboxLayout.waypoints do
		byId[waypoint.id] = waypoint
	end
	local a = byId[edge.a]
	local b = byId[edge.b]
	if a == nil or b == nil then
		return nil
	end
	local dx = a.position.x - b.position.x
	local dz = a.position.z - b.position.z
	return math.sqrt(dx * dx + dz * dz)
end

describe("地图边界（SMALL ≈180×180）", function()
	it("地板不超过 SMALL 尺寸，且中心在原点", function()
		local floor = GreyboxLayout.floor
		expect(floor.size.x <= 180).toBe(true)
		expect(floor.size.z <= 180).toBe(true)
		expect(floor.center.x).toBe(0)
		expect(floor.center.z).toBe(0)
		expect(GreyboxLayout.mapSize).toBe(180)
	end)

	it("所有墙体与掩体都落在地板范围内（含墙厚）", function()
		local limit = GreyboxLayout.mapSize / 2 + 2
		local blocks: { GreyboxLayout.Block } = {}
		for _, wall in GreyboxLayout.walls do
			table.insert(blocks, wall)
		end
		for _, obstacle in GreyboxLayout.obstacles do
			table.insert(blocks, obstacle)
		end
		for _, item in blocks do
			local minX = item.center.x - item.size.x / 2
			local maxX = item.center.x + item.size.x / 2
			local minZ = item.center.z - item.size.z / 2
			local maxZ = item.center.z + item.size.z / 2
			expect(minX >= -limit).toBe(true)
			expect(maxX <= limit).toBe(true)
			expect(minZ >= -limit).toBe(true)
			expect(maxZ <= limit).toBe(true)
		end
	end)

	it("地板顶面就是角色出生高度基准", function()
		expect(GreyboxLayout.floor.center.y + GreyboxLayout.floor.size.y / 2).toBe(GreyboxLayout.floorTopY)
		expect(GreyboxLayout.characterSpawnY > GreyboxLayout.floorTopY).toBe(true)
		expect(GreyboxLayout.killPlaneY < GreyboxLayout.floorTopY).toBe(true)
	end)
end)

describe("走廊与门洞尺寸", function()
	it("至少有三段走廊，宽度均 ≥ 10", function()
		expect(#GreyboxLayout.corridors >= 3).toBe(true)
		for _, corridor in GreyboxLayout.corridors do
			expect(corridor.width >= 10).toBe(true)
			expect(corridor.length > 0).toBe(true)
		end
	end)

	it("门洞宽 ≥ 6、高 ≥ 9", function()
		expect(#GreyboxLayout.doors >= 2).toBe(true)
		for _, door in GreyboxLayout.doors do
			expect(door.width >= 6).toBe(true)
			expect(door.height >= 9).toBe(true)
			expect(insideSolid(door.center.x, door.center.z, 0)).toBe(false)
		end
	end)

	it("所有墙体高度足以覆盖门洞", function()
		for _, wall in GreyboxLayout.walls do
			expect(wall.size.y >= 9).toBe(true)
		end
	end)
end)

describe("出生点", function()
	it("至少 6 个出生点且互不重叠", function()
		expect(#GreyboxLayout.spawnPoints >= 6).toBe(true)
		for i = 1, #GreyboxLayout.spawnPoints do
			for j = i + 1, #GreyboxLayout.spawnPoints do
				local a = GreyboxLayout.spawnPoints[i]
				local b = GreyboxLayout.spawnPoints[j]
				local dx = a.x - b.x
				local dz = a.z - b.z
				expect(math.sqrt(dx * dx + dz * dz) >= 10).toBe(true)
			end
		end
	end)

	it("出生点都在地图内且不压墙/掩体", function()
		local half = GreyboxLayout.mapSize / 2 - SPAWN_CLEARANCE
		for _, spawn in GreyboxLayout.spawnPoints do
			expect(spawn.x >= -half).toBe(true)
			expect(spawn.x <= half).toBe(true)
			expect(spawn.z >= -half).toBe(true)
			expect(spawn.z <= half).toBe(true)
			expect(spawn.y).toBe(GreyboxLayout.floorTopY)
			expect(insideSolid(spawn.x, spawn.z, SPAWN_CLEARANCE)).toBe(false)
		end
	end)
end)

describe("Bot 路点图", function()
	it("每条边都连接已存在的路点且长度 > 0", function()
		expect(#GreyboxLayout.edges > 0).toBe(true)
		for _, edge in GreyboxLayout.edges do
			local length = edgeLength(edge)
			assert(length, `边 {edge.a}-{edge.b} 引用了不存在的路点`)
			expect(length > 0).toBe(true)
			expect(edge.a ~= edge.b).toBe(true)
		end
	end)

	it("路点都在地图内且不压墙/掩体", function()
		local half = GreyboxLayout.mapSize / 2 - WAYPOINT_CLEARANCE
		for _, waypoint in GreyboxLayout.waypoints do
			expect(waypoint.position.x >= -half).toBe(true)
			expect(waypoint.position.x <= half).toBe(true)
			expect(waypoint.position.z >= -half).toBe(true)
			expect(waypoint.position.z <= half).toBe(true)
			expect(insideSolid(waypoint.position.x, waypoint.position.z, WAYPOINT_CLEARANCE)).toBe(false)
		end
	end)

	it("路点图连通（从任意点可达全部路点）", function()
		local adjacency: { [string]: { string } } = {}
		for _, waypoint in GreyboxLayout.waypoints do
			adjacency[waypoint.id] = {}
		end
		for _, edge in GreyboxLayout.edges do
			table.insert(adjacency[edge.a], edge.b)
			table.insert(adjacency[edge.b], edge.a)
		end

		local start = GreyboxLayout.waypoints[1].id
		local visited: { [string]: boolean } = { [start] = true }
		local queue: { string } = { start }
		local head = 1
		while head <= #queue do
			local current = queue[head]
			head += 1
			for _, neighbor in adjacency[current] do
				if not visited[neighbor] then
					visited[neighbor] = true
					table.insert(queue, neighbor)
				end
			end
		end

		for _, waypoint in GreyboxLayout.waypoints do
			expect(visited[waypoint.id] == true).toBe(true)
		end
	end)
end)

TestKit.finish()
