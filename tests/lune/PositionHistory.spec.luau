--!strict
-- PositionHistory 的环形缓冲、插值、夹取与裁剪测试（GDB V1.1 §9.5）。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local PositionHistory = require("../../src/server/logic/PositionHistory")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local function pos(x: number, y: number, z: number): PositionHistory.Vec3
	return { x = x, y = y, z = z }
end

local function close(actual: number, expected: number): boolean
	return math.abs(actual - expected) < 1e-9
end

local function newHistory(): PositionHistory.History
	return PositionHistory.new(BalanceConfig)
end

describe("PositionHistory.new", function()
	it("容量由 HistorySeconds × HistoryHz 加余量推导", function()
		local history = newHistory()
		local minimum = math.ceil(BalanceConfig.Greybox.HistorySeconds * BalanceConfig.Greybox.HistoryHz)
		expect(history.capacity >= minimum).toBe(true)
		expect(history.count).toBe(0)
		expect(history.windowSeconds).toBe(BalanceConfig.Greybox.HistorySeconds)
	end)

	it("空缓冲采样返回 nil", function()
		expect(PositionHistory.sampleAt(newHistory(), 0)).toBeNil()
	end)
end)

describe("record / sampleAt", function()
	it("采样点本身原样返回", function()
		local history = newHistory()
		local sample = pos(1, 2, 3)
		PositionHistory.record(history, 10, sample)
		expect(PositionHistory.sampleAt(history, 10)).toEqual(sample)
	end)

	it("相邻样本之间线性插值", function()
		local history = newHistory()
		PositionHistory.record(history, 0, pos(0, 0, 0))
		PositionHistory.record(history, 1, pos(10, 20, -4))

		local mid = PositionHistory.sampleAt(history, 0.25)
		assert(mid, "应能采样到插值位置")
		expect(close(mid.x, 2.5)).toBe(true)
		expect(close(mid.y, 5)).toBe(true)
		expect(close(mid.z, -1)).toBe(true)
	end)

	it("早于最旧样本夹取到最旧位置", function()
		local history = newHistory()
		PositionHistory.record(history, 1, pos(1, 0, 0))
		PositionHistory.record(history, 2, pos(2, 0, 0))
		expect(PositionHistory.sampleAt(history, -100)).toEqual(pos(1, 0, 0))
	end)

	it("晚于最新样本夹取到最新位置", function()
		local history = newHistory()
		PositionHistory.record(history, 1, pos(1, 0, 0))
		PositionHistory.record(history, 2, pos(2, 0, 0))
		expect(PositionHistory.sampleAt(history, 100)).toEqual(pos(2, 0, 0))
	end)

	it("恰好在样本时刻返回该样本", function()
		local history = newHistory()
		PositionHistory.record(history, 1, pos(1, 0, 0))
		PositionHistory.record(history, 1.5, pos(2, 0, 0))
		PositionHistory.record(history, 2, pos(3, 0, 0))
		expect(PositionHistory.sampleAt(history, 1.5)).toEqual(pos(2, 0, 0))
	end)
end)

describe("窗口裁剪与环形覆盖", function()
	it("丢弃 HistorySeconds 之外的旧样本", function()
		local history = newHistory()
		local window = BalanceConfig.Greybox.HistorySeconds
		PositionHistory.record(history, 0, pos(0, 0, 0))
		PositionHistory.record(history, window + 0.5, pos(1, 0, 0))

		-- t = 0 已被裁剪，采样被夹取到当前最旧样本。
		expect(PositionHistory.sampleAt(history, 0)).toEqual(pos(1, 0, 0))
	end)

	it("缓冲写满后覆盖最旧样本且保留最新值", function()
		local history = newHistory()
		for index = 1, 200 do
			local t = index * 0.01
			PositionHistory.record(history, t, pos(t, 0, 0))
		end
		expect(history.count).toBe(history.capacity)
		local newest = PositionHistory.sampleAt(history, 2)
		assert(newest, "应保留最新样本")
		expect(close(newest.x, 2)).toBe(true)
	end)
end)

TestKit.finish()
