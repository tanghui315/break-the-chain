--!strict
-- Vec 的纯向量工具测试（GDB V1.1 §9.5）。

local TestKit = require("./TestKit")
local Vec = require("../../src/server/logic/Vec")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local function close(actual: number, expected: number): boolean
	return math.abs(actual - expected) < 1e-9
end

describe("Vec.sub / length / dot", function()
	it("逐分量相减并求长度", function()
		local delta = Vec.sub({ x = 4, y = 3, z = 0 }, { x = 1, y = 1, z = 0 })
		expect(delta).toEqual({ x = 3, y = 2, z = 0 })
		expect(close(Vec.length(delta), math.sqrt(13))).toBe(true)
	end)

	it("点积", function()
		expect(Vec.dot({ x = 1, y = 2, z = 3 }, { x = 4, y = 5, z = 6 })).toBe(32)
	end)
end)

describe("Vec.lerp", function()
	it("在两点之间线性插值", function()
		local mid = Vec.lerp({ x = 0, y = 0, z = 0 }, { x = 10, y = 20, z = -4 }, 0.25)
		expect(close(mid.x, 2.5)).toBe(true)
		expect(close(mid.y, 5)).toBe(true)
		expect(close(mid.z, -1)).toBe(true)
	end)

	it("t = 0 与 t = 1 返回端点", function()
		local a = { x = 1, y = 2, z = 3 }
		local b = { x = 4, y = 5, z = 6 }
		expect(Vec.lerp(a, b, 0)).toEqual(a)
		expect(Vec.lerp(a, b, 1)).toEqual(b)
	end)
end)

describe("Vec.horizontal", function()
	it("压平 y 并归一化", function()
		local dir = Vec.horizontal({ x = 3, y = 99, z = 4 })
		expect(dir.y).toBe(0)
		expect(close(dir.x, 0.6)).toBe(true)
		expect(close(dir.z, 0.8)).toBe(true)
		expect(close(Vec.length(dir), 1)).toBe(true)
	end)

	it("水平长度为零时返回零向量", function()
		expect(Vec.horizontal({ x = 0, y = 12, z = 0 })).toEqual({ x = 0, y = 0, z = 0 })
	end)
end)

describe("Vec.horizontalDistance", function()
	it("忽略 y 轴距离", function()
		expect(Vec.horizontalDistance({ x = 0, y = 0, z = 0 }, { x = 3, y = 50, z = 4 })).toBe(5)
	end)
end)

describe("Vec.angleBetweenHorizontalDegrees", function()
	it("同向为 0 度、垂直为 90 度、反向为 180 度", function()
		local x = { x = 1, y = 0, z = 0 }
		local z = { x = 0, y = 0, z = 1 }
		expect(close(Vec.angleBetweenHorizontalDegrees(x, x), 0)).toBe(true)
		expect(close(Vec.angleBetweenHorizontalDegrees(x, z), 90)).toBe(true)
		expect(close(Vec.angleBetweenHorizontalDegrees(x, { x = -1, y = 0, z = 0 }), 180)).toBe(true)
	end)

	it("忽略 y 分量", function()
		local a = { x = 1, y = 100, z = 0 }
		local b = { x = 2, y = -100, z = 0 }
		expect(close(Vec.angleBetweenHorizontalDegrees(a, b), 0)).toBe(true)
	end)

	it("任一向量水平长度为零时视为 180 度", function()
		local zero = { x = 0, y = 5, z = 0 }
		local x = { x = 1, y = 0, z = 0 }
		expect(Vec.angleBetweenHorizontalDegrees(zero, x)).toBe(180)
		expect(Vec.angleBetweenHorizontalDegrees(x, zero)).toBe(180)
	end)
end)

TestKit.finish()
