--!strict
-- 路点图寻路（GDB V1.1 §20.9）：给 Bot 一条“下一跳”路线，避免直线 MoveTo 卡在内墙拐角。
-- 输入只有普通表：waypoint = { id, position = { x, z } }，edge = { a, b }；不引用任何 Roblox 全局。
-- 权重取水平面距离（Dijkstra），因此绕柱/穿门的最短路线按实际路程而不是跳数选择；
-- 同距离时按路点 id 字典序打破平局，保证每帧、每次进程重启得到相同结果。

export type Point = { x: number, z: number }

export type Waypoint = {
	id: string,
	position: Point,
}

export type Edge = {
	a: string,
	b: string,
}

local EPSILON = 1e-9

local WaypointRoute = {}

local function horizontalDistance(a: Point, b: Point): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

local function buildGraph(waypoints: { Waypoint }, edges: { Edge })
	local positions: { [string]: Point } = {}
	local ids: { string } = {}
	for _, waypoint in waypoints do
		if positions[waypoint.id] == nil then
			positions[waypoint.id] = { x = waypoint.position.x, z = waypoint.position.z }
			table.insert(ids, waypoint.id)
		end
	end
	table.sort(ids)

	local neighbors: { [string]: { string } } = {}
	local seen: { [string]: { [string]: boolean } } = {}
	for _, id in ids do
		neighbors[id] = {}
		seen[id] = {}
	end
	for _, edge in edges do
		-- 忽略自环、重复边与引用不存在路点的边：坏数据不应该让 Bot 停在原地。
		if edge.a ~= edge.b and positions[edge.a] ~= nil and positions[edge.b] ~= nil then
			if not seen[edge.a][edge.b] then
				seen[edge.a][edge.b] = true
				seen[edge.b][edge.a] = true
				table.insert(neighbors[edge.a], edge.b)
				table.insert(neighbors[edge.b], edge.a)
			end
		end
	end
	for _, id in ids do
		table.sort(neighbors[id])
	end
	return positions, ids, neighbors
end

-- 距 point 最近的路点；同距离时取 id 较小者。空图返回 nil。
function WaypointRoute.nearest(waypoints: { Waypoint }, point: Point): string?
	local bestId: string? = nil
	local bestDistance = math.huge
	for _, waypoint in waypoints do
		local distance = horizontalDistance(waypoint.position, point)
		if
			distance < bestDistance - EPSILON
			or (math.abs(distance - bestDistance) <= EPSILON and (bestId == nil or waypoint.id < bestId))
		then
			bestDistance = distance
			bestId = waypoint.id
		end
	end
	return bestId
end

-- 从 startId 走向 goalId 时应该先去的路点。同一路点返回 startId；不可达或节点未知返回 nil。
-- 相邻时返回 goalId；多跳时返回路线上的第二个节点。
function WaypointRoute.nextHop(waypoints: { Waypoint }, edges: { Edge }, startId: string, goalId: string): string?
	local positions, ids, neighbors = buildGraph(waypoints, edges)
	if positions[startId] == nil or positions[goalId] == nil then
		return nil
	end
	if startId == goalId then
		return startId
	end

	local distance: { [string]: number } = { [startId] = 0 }
	local previous: { [string]: string } = {}
	local visited: { [string]: boolean } = {}
	local current: string? = startId

	while current ~= nil do
		if current == goalId then
			break
		end
		visited[current] = true

		for _, neighbor in neighbors[current] do
			if not visited[neighbor] then
				local candidate = distance[current] + horizontalDistance(positions[current], positions[neighbor])
				local existing = distance[neighbor]
				-- 严格更短才替换；等长时保留先到者，先到者由下面的确定性选点决定。
				if existing == nil or candidate < existing - EPSILON then
					distance[neighbor] = candidate
					previous[neighbor] = current
				end
			end
		end

		-- 扫描式选点（图很小），先比距离，再比 id，保证平局可复现。
		local nextId: string? = nil
		local nextDistance = math.huge
		for _, id in ids do
			local value = distance[id]
			if value ~= nil and not visited[id] then
				if
					value < nextDistance - EPSILON
					or (math.abs(value - nextDistance) <= EPSILON and (nextId == nil or id < nextId))
				then
					nextDistance = value
					nextId = id
				end
			end
		end
		current = nextId
	end

	if previous[goalId] == nil then
		return nil
	end

	-- 从目标回溯到起点，返回起点之后的第一个节点。
	local cursor = goalId
	while previous[cursor] ~= startId do
		local parent = previous[cursor]
		if parent == nil then
			return nil
		end
		cursor = parent
	end
	return cursor
end

return table.freeze(WaypointRoute)
