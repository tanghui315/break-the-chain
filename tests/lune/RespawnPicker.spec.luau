--!strict
-- RespawnPicker 的复活点选择测试（GDB V1.1 §9A.3）：
-- 距最近人类 ≥ 60、距撤离区 ≥ 80（撤离开启时）、优先离人类最远、无合格点时的退化规则。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local RespawnPicker = require("../../src/server/logic/RespawnPicker")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = RespawnPicker.Reason

local MIN_HUMAN = BalanceConfig.RespawnMinDistanceFromHuman
local MIN_EXTRACTION = BalanceConfig.RespawnMinDistanceFromExtraction

local function v(x: number, y: number?, z: number?): RespawnPicker.Vec3
	return { x = x, y = y or 0, z = z or 0 }
end

describe("合格点选择", function()
	it("两个合格感染区时选离最近人类最远的一个", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(100), v(200) }, { v(0) }, nil, false)
		expect(index).toBe(2)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("距离恰好 60 合格，59.99 不合格（退化为 FALLBACK）", function()
		local qualified, qualifiedReason = RespawnPicker.pick(BalanceConfig, { v(MIN_HUMAN) }, { v(0) }, nil, false)
		expect(qualified).toBe(1)
		expect(qualifiedReason).toBe(Reason.QUALIFIED)

		local fallback, fallbackReason = RespawnPicker.pick(
			BalanceConfig,
			{ v(MIN_HUMAN - 0.01) },
			{ v(0) },
			nil,
			false
		)
		expect(fallback).toBe(1)
		expect(fallbackReason).toBe(Reason.FALLBACK)
	end)

	it("一个合格、一个不合格时只从合格点里选", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(59.99), v(61) }, { v(0) }, nil, false)
		expect(index).toBe(2)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("多个人类时使用“最近人类”的距离", function()
		local index, reason = RespawnPicker.pick(
			BalanceConfig,
			{ v(100), v(80, 0, 100) },
			{ v(0), v(0, 0, 100) },
			nil,
			false
		)
		-- zone1 距最近人类 100；zone2 距人类 (0,0,100) 为 80。
		expect(index).toBe(1)
		expect(reason).toBe(Reason.QUALIFIED)
	end)
end)

describe("撤离区规则", function()
	it("撤离开启时距撤离区 < 80 的感染区被排除", function()
		local index, reason = RespawnPicker.pick(
			BalanceConfig,
			{ v(0, 0, 220), v(0, 0, 100) },
			{ v(0) },
			v(0, 0, 200),
			true
		)
		-- zone1 距人类 220 但距撤离区只有 20 → 排除；zone2 距人类 100、距撤离区 100 → 合格。
		expect(index).toBe(2)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("撤离开启时：离人类更远但贴近撤离区的点不合格", function()
		local index, reason = RespawnPicker.pick(
			BalanceConfig,
			{ v(0, 0, 300), v(0, 0, 100) },
			{ v(0) },
			v(0, 0, 300),
			true
		)
		-- zone1 距人类 300 但距撤离区 0 → 排除；zone2 距人类 100、距撤离区 200 → 合格。
		expect(index).toBe(2)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("撤离关闭时同一场景按普通点位处理（zone1 最远胜出）", function()
		local index, reason = RespawnPicker.pick(
			BalanceConfig,
			{ v(0, 0, 300), v(0, 0, 100) },
			{ v(0) },
			v(0, 0, 300),
			false
		)
		expect(index).toBe(1)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("距撤离区恰好 80 合格，79.99 不合格", function()
		local qualified, qualifiedReason = RespawnPicker.pick(
			BalanceConfig,
			{ v(0, 0, MIN_EXTRACTION) },
			{ v(0) },
			v(0, 0, 0),
			true
		)
		expect(qualified).toBe(1)
		expect(qualifiedReason).toBe(Reason.QUALIFIED)

		local fallback, fallbackReason = RespawnPicker.pick(
			BalanceConfig,
			{ v(0, 0, MIN_EXTRACTION - 0.01) },
			{ v(0) },
			v(0, 0, 0),
			true
		)
		expect(fallback).toBe(1)
		expect(fallbackReason).toBe(Reason.FALLBACK)
	end)

	it("撤离区坐标缺失时即使 active 也不做撤离筛选", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(100), v(200) }, { v(0) }, nil, true)
		expect(index).toBe(2)
		expect(reason).toBe(Reason.QUALIFIED)
	end)
end)

describe("退化与边界", function()
	it("没有合格点时选离最近人类最远的感染区并标记 FALLBACK", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(10), v(30), v(20) }, { v(0) }, nil, false)
		expect(index).toBe(2)
		expect(reason).toBe(Reason.FALLBACK)
	end)

	it("没有感染区时返回 nil + NO_ZONES", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, {}, { v(0) }, nil, false)
		expect(index).toBeNil()
		expect(reason).toBe(Reason.NO_ZONES)
	end)

	it("没有人类时所有感染区都合格，平手取下标最小", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(10), v(20) }, {}, nil, false)
		expect(index).toBe(1)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("距离平手时取下标最小的感染区", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(100), v(-100) }, { v(0) }, nil, false)
		expect(index).toBe(1)
		expect(reason).toBe(Reason.QUALIFIED)
	end)

	it("距离只看水平面：y 不同不影响判定", function()
		local index, reason = RespawnPicker.pick(BalanceConfig, { v(0, 1000, 0), v(60, 500, 0) }, { v(0) }, nil, false)
		-- zone1 水平距离 0（不合格）；zone2 水平距离 60（合格）。
		expect(index).toBe(2)
		expect(reason).toBe(Reason.QUALIFIED)
	end)
end)

TestKit.finish()
