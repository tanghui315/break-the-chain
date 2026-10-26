--!strict
-- WaypointRoute 的下一跳、最近路点与确定性测试（GDB V1.1 §20.9）。

local TestKit = require("./TestKit")
local WaypointRoute = require("../../src/server/logic/WaypointRoute")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local function waypoint(id: string, x: number, z: number): WaypointRoute.Waypoint
	return { id = id, position = { x = x, z = z } }
end

local function chain(ids: { string }, step: number): ({ WaypointRoute.Waypoint }, { WaypointRoute.Edge })
	local waypoints: { WaypointRoute.Waypoint } = {}
	local edges: { WaypointRoute.Edge } = {}
	for index, id in ids do
		table.insert(waypoints, waypoint(id, (index - 1) * step, 0))
		if index > 1 then
			table.insert(edges, { a = ids[index - 1], b = id })
		end
	end
	return waypoints, edges
end

describe("WaypointRoute.nearest", function()
	local waypoints = {
		waypoint("W1", -70, -70),
		waypoint("W2", 0, -70),
		waypoint("W3", 70, -70),
	}

	it("返回水平距离最近的路点", function()
		expect(WaypointRoute.nearest(waypoints, { x = 64, z = -66 })).toBe("W3")
	end)

	it("忽略 y 轴（调用方只传 x/z 亦可）", function()
		expect(WaypointRoute.nearest(waypoints, { x = 2, z = -68 })).toBe("W2")
	end)

	it("等距时按 id 字典序取较小者", function()
		local tied = {
			waypoint("B", 10, 0),
			waypoint("A", -10, 0),
		}
		expect(WaypointRoute.nearest(tied, { x = 0, z = 0 })).toBe("A")
		-- 交换输入顺序仍然确定。
		local reversed = {
			waypoint("A", -10, 0),
			waypoint("B", 10, 0),
		}
		expect(WaypointRoute.nearest(reversed, { x = 0, z = 0 })).toBe("A")
	end)

	it("空图返回 nil", function()
		expect(WaypointRoute.nearest({}, { x = 0, z = 0 })).toBeNil()
	end)
end)

describe("WaypointRoute.nextHop", function()
	it("起点即终点时返回自身", function()
		local waypoints, edges = chain({ "A", "B", "C" }, 10)
		expect(WaypointRoute.nextHop(waypoints, edges, "B", "B")).toBe("B")
	end)

	it("相邻时返回目标", function()
		local waypoints, edges = chain({ "A", "B", "C" }, 10)
		expect(WaypointRoute.nextHop(waypoints, edges, "A", "B")).toBe("B")
		expect(WaypointRoute.nextHop(waypoints, edges, "C", "B")).toBe("B")
	end)

	it("多跳时返回路线上的第一跳", function()
		local waypoints, edges = chain({ "A", "B", "C", "D" }, 10)
		expect(WaypointRoute.nextHop(waypoints, edges, "A", "D")).toBe("B")
		expect(WaypointRoute.nextHop(waypoints, edges, "B", "D")).toBe("C")
	end)

	it("按路程而不是跳数选最短路", function()
		-- 2 跳的 A→B→C 约 81.6；3 跳的 A→D→E→C 只有 30，应选 D。
		local waypoints = {
			waypoint("A", 0, 0),
			waypoint("B", 0, 50),
			waypoint("C", 10, 20),
			waypoint("D", 10, 0),
			waypoint("E", 10, 10),
		}
		local edges = {
			{ a = "A", b = "B" },
			{ a = "B", b = "C" },
			{ a = "A", b = "D" },
			{ a = "D", b = "E" },
			{ a = "E", b = "C" },
		}
		expect(WaypointRoute.nextHop(waypoints, edges, "A", "C")).toBe("D")
	end)

	it("不可达返回 nil", function()
		local waypoints = {
			waypoint("A", 0, 0),
			waypoint("B", 10, 0),
			waypoint("C", 100, 100),
		}
		local edges = { { a = "A", b = "B" } }
		expect(WaypointRoute.nextHop(waypoints, edges, "A", "C")).toBeNil()
	end)

	it("未知节点返回 nil", function()
		local waypoints, edges = chain({ "A", "B" }, 10)
		expect(WaypointRoute.nextHop(waypoints, edges, "A", "Z")).toBeNil()
		expect(WaypointRoute.nextHop(waypoints, edges, "Z", "B")).toBeNil()
	end)

	it("忽略自环、重复边与悬空边", function()
		local waypoints, edges = chain({ "A", "B", "C" }, 10)
		table.insert(edges, { a = "A", b = "A" })
		table.insert(edges, { a = "B", b = "A" })
		table.insert(edges, { a = "C", b = "Z" })
		expect(WaypointRoute.nextHop(waypoints, edges, "A", "C")).toBe("B")
	end)
end)

describe("确定性", function()
	it("等长路线始终返回同一个下一跳（按 id 字典序）", function()
		local waypoints = {
			waypoint("A", 0, 0),
			waypoint("B", -5, 5),
			waypoint("C", 5, 5),
			waypoint("D", 0, 10),
		}
		local edges = {
			{ a = "A", b = "C" },
			{ a = "C", b = "D" },
			{ a = "A", b = "B" },
			{ a = "B", b = "D" },
		}
		local first = WaypointRoute.nextHop(waypoints, edges, "A", "D")
		expect(first).toBe("B")
		for _ = 1, 5 do
			expect(WaypointRoute.nextHop(waypoints, edges, "A", "D")).toBe(first)
		end

		-- 输入边顺序变化不影响结果。
		local reordered = {
			{ a = "B", b = "D" },
			{ a = "A", b = "B" },
			{ a = "C", b = "D" },
			{ a = "A", b = "C" },
		}
		expect(WaypointRoute.nextHop(waypoints, reordered, "A", "D")).toBe("B")
	end)
end)

TestKit.finish()
