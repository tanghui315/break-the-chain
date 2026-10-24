--!strict
-- SupplyPlan 的补给分配与弹药箱刷新测试（GDB V1.1 §9A.5、§9A.9）：
-- 按人数档分配手枪/电击枪/弹药箱、点位互不重复、注入 RNG 决定顺序、弹药箱 90 秒刷新。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local SupplyPlan = require("../../src/server/logic/SupplyPlan")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local NOW = 500
local REFRESH = BalanceConfig.AmmoCrateRefreshSeconds

local function points(count: number): { unknown }
	local out: { unknown } = {}
	for index = 1, count do
		out[index] = { x = index, y = 0, z = 0 }
	end
	return out
end

-- 不交换的 RNG：分配顺序完全等于下标顺序，便于断言。
local function identity(_count: number): number
	return _count
end

local function tierAt(index: number): SupplyPlan.Tier
	return BalanceConfig.PlayerCountTiers[index]
end

local function allAssigned(plan: SupplyPlan.Plan): { number }
	local out: { number } = {}
	for _, index in plan.pistols do
		table.insert(out, index)
	end
	for _, index in plan.tasers do
		table.insert(out, index)
	end
	for _, index in plan.ammoCrates do
		table.insert(out, index)
	end
	return out
end

local function isDistinct(indices: { number }): boolean
	local seen: { [number]: boolean } = {}
	for _, index in indices do
		if seen[index] then
			return false
		end
		seen[index] = true
	end
	return true
end

describe("按人数档分配", function()
	it("4～7 人：1 手枪、1 电击枪、1 弹药箱", function()
		local plan = SupplyPlan.plan(tierAt(1), points(10), identity)
		expect(plan.pistols).toEqual({ 1 })
		expect(plan.tasers).toEqual({ 2 })
		expect(plan.ammoCrates).toEqual({ 3 })
		expect(plan.shortfall).toEqual({ pistols = 0, tasers = 0, ammoCrates = 0 })
	end)

	it("8～15 人：3 手枪、1 电击枪、2 弹药箱", function()
		local plan = SupplyPlan.plan(tierAt(2), points(10), identity)
		expect(plan.pistols).toEqual({ 1, 2, 3 })
		expect(plan.tasers).toEqual({ 4 })
		expect(plan.ammoCrates).toEqual({ 5, 6 })
	end)

	it("16～24 人：5 手枪、2 电击枪、3 弹药箱", function()
		local plan = SupplyPlan.plan(tierAt(3), points(10), identity)
		expect(plan.pistols).toEqual({ 1, 2, 3, 4, 5 })
		expect(plan.tasers).toEqual({ 6, 7 })
		expect(plan.ammoCrates).toEqual({ 8, 9, 10 })
		expect(plan.shortfall).toEqual({ pistols = 0, tasers = 0, ammoCrates = 0 })
	end)

	it("三类补给点互不重复", function()
		for tierIndex = 1, #BalanceConfig.PlayerCountTiers do
			local plan = SupplyPlan.plan(tierAt(tierIndex), points(10), identity)
			expect(isDistinct(allAssigned(plan))).toBe(true)
		end
	end)

	it("点位不足时按 手枪 → 电击枪 → 弹药箱 顺序保证前者，并报告 shortfall", function()
		local plan = SupplyPlan.plan(tierAt(3), points(3), identity)
		expect(plan.pistols).toEqual({ 1, 2, 3 })
		expect(plan.tasers).toEqual({})
		expect(plan.ammoCrates).toEqual({})
		expect(plan.shortfall).toEqual({ pistols = 2, tasers = 2, ammoCrates = 3 })
	end)
end)

describe("注入 RNG 的确定性", function()
	it("同一 RNG 序列得到同样的分配", function()
		local sequence = { 3, 1, 2, 2, 1, 1, 1, 1, 1, 1 }

		local function scripted(): SupplyPlan.Rng
			local cursor = 0
			return function(count: number): number
				cursor += 1
				local value = sequence[cursor]
				if value == nil or value < 1 or value > count then
					return count
				end
				return value
			end
		end

		local first = SupplyPlan.plan(tierAt(3), points(10), scripted())
		local second = SupplyPlan.plan(tierAt(3), points(10), scripted())
		expect(first.pistols).toEqual(second.pistols)
		expect(first.tasers).toEqual(second.tasers)
		expect(first.ammoCrates).toEqual(second.ammoCrates)
		expect(isDistinct(allAssigned(first))).toBe(true)
	end)

	it("非法 RNG 返回值被夹取，仍然得到互不重复的合法分配", function()
		local function broken(count: number): number
			if count <= 2 then
				return 0
			end
			return count + 100
		end
		local plan = SupplyPlan.plan(tierAt(3), points(10), broken)
		local assigned = allAssigned(plan)
		expect(#assigned).toBe(10)
		expect(isDistinct(assigned)).toBe(true)
		for _, index in assigned do
			expect(index >= 1 and index <= 10).toBe(true)
		end
	end)
end)

describe("弹药箱刷新", function()
	it("建立与 plan.ammoCrates 一一对应的运行时状态", function()
		local plan = SupplyPlan.plan(tierAt(3), points(10), identity)
		local state = SupplyPlan.newCrates(BalanceConfig, plan)
		expect(#state.crates).toBe(3)
		expect(state.crates[1].pointIndex).toBe(8)
		expect(state.crates[3].pointIndex).toBe(10)
		expect(state.crates[1].available).toBe(true)
	end)

	it("取用后 90 秒在同一位置刷新；刷新前不能重复取用", function()
		expect(REFRESH).toBe(90)
		local plan = SupplyPlan.plan(tierAt(1), points(10), identity)
		local state = SupplyPlan.newCrates(BalanceConfig, plan)

		expect(SupplyPlan.takeCrate(state, 1, NOW)).toBe(true)
		expect(SupplyPlan.isCrateAvailable(state, 1)).toBe(false)
		expect(SupplyPlan.takeCrate(state, 1, NOW + 1)).toBe(false)
		expect(state.crates[1].readyAt).toBe(NOW + REFRESH)

		expect(#SupplyPlan.tickCrates(state, NOW + REFRESH - 0.01)).toBe(0)
		expect(SupplyPlan.isCrateAvailable(state, 1)).toBe(false)

		local refreshed = SupplyPlan.tickCrates(state, NOW + REFRESH)
		expect(refreshed).toEqual({ 1 })
		expect(SupplyPlan.isCrateAvailable(state, 1)).toBe(true)
		expect(SupplyPlan.takeCrate(state, 1, NOW + REFRESH)).toBe(true)
	end)

	it("越界下标不能取用或刷新", function()
		local plan = SupplyPlan.plan(tierAt(1), points(10), identity)
		local state = SupplyPlan.newCrates(BalanceConfig, plan)
		expect(SupplyPlan.takeCrate(state, 0, NOW)).toBe(false)
		expect(SupplyPlan.takeCrate(state, 2, NOW)).toBe(false)
		expect(SupplyPlan.isCrateAvailable(state, 2)).toBe(false)
	end)

	it("多个箱子各自计时，只刷新到期的", function()
		local plan = SupplyPlan.plan(tierAt(3), points(10), identity)
		local state = SupplyPlan.newCrates(BalanceConfig, plan)
		SupplyPlan.takeCrate(state, 1, NOW)
		SupplyPlan.takeCrate(state, 2, NOW + 10)
		SupplyPlan.takeCrate(state, 3, NOW + 20)

		expect(SupplyPlan.tickCrates(state, NOW + REFRESH)).toEqual({ 1 })
		expect(SupplyPlan.isCrateAvailable(state, 2)).toBe(false)
		expect(SupplyPlan.tickCrates(state, NOW + 10 + REFRESH)).toEqual({ 2 })
		expect(SupplyPlan.tickCrates(state, NOW + 20 + REFRESH)).toEqual({ 3 })
	end)
end)

TestKit.finish()
