--!strict
-- CureInventory 测试（GDB V1.1 §10.1、§19.1）：按人数档发放、每人 ≤1、掉落不复制、提交才消耗、失败冷却。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local CureInventory = require("../../src/server/logic/CureInventory")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = CureInventory.Reason

local config = { CureRetryCooldownSeconds = BalanceConfig.CureRetryCooldownSeconds }

local function constantRng(value: number): (number) -> number
	return function(_count: number): number
		return value
	end
end

local function newInventory(cures: number, slots: { unknown }?, rng: ((number) -> number)?)
	return CureInventory.new(
		config,
		{ cures = cures },
		slots or { "slot-1", "slot-2", "slot-3" },
		rng or constantRng(1)
	)
end

describe("CureInventory", function()
	it("creates tier.cures items on distinct supply slots", function()
		local inv = newInventory(2)
		expect(#inv.order).toBe(2)
		expect(inv.shortfall).toBe(0)
		expect(CureInventory.countByState(inv, CureInventory.State.SUPPLY)).toBe(2)
		local first = CureInventory.getItem(inv, inv.order[1])
		local second = CureInventory.getItem(inv, inv.order[2])
		expect(first.slotIndex == second.slotIndex).toBe(false)
		expect(first.position == nil).toBe(false)
	end)

	it("reports a shortfall when the map has fewer supply slots than the tier", function()
		local inv = newInventory(3, { "only-slot" })
		expect(#inv.order).toBe(1)
		expect(inv.shortfall).toBe(2)
	end)

	it("is deterministic for the same injected RNG", function()
		local first = newInventory(3, { "a", "b", "c" }, constantRng(2))
		local second = newInventory(3, { "a", "b", "c" }, constantRng(2))
		for index, itemId in first.order do
			local left = CureInventory.getItem(first, itemId)
			local right = CureInventory.getItem(second, second.order[index])
			expect(left.slotIndex).toBe(right.slotIndex)
			expect(left.position).toBe(right.position)
		end
	end)

	it("allows at most one item per participant", function()
		local inv = newInventory(2)
		local firstId = inv.order[1]
		local secondId = inv.order[2]

		local ok, reason = CureInventory.pickup(inv, firstId, "U:1")
		expect(ok).toBe(true)
		expect(reason).toBeNil()
		expect(CureInventory.heldBy(inv, "U:1")).toBe(firstId)
		expect(CureInventory.holderOf(inv, firstId)).toBe("U:1")

		local blocked, blockedReason = CureInventory.pickup(inv, secondId, "U:1")
		expect(blocked).toBe(false)
		expect(blockedReason).toBe(Reason.AlreadyCarried)

		local other, otherReason = CureInventory.pickup(inv, secondId, "U:2")
		expect(other).toBe(true)
		expect(otherReason).toBeNil()
	end)

	it("drops the same unique item without duplicating it", function()
		local inv = newInventory(1)
		local itemId = inv.order[1]
		CureInventory.pickup(inv, itemId, "U:1")

		local position = { x = 10, y = 0, z = -4 }
		local ok = CureInventory.drop(inv, "U:1", position)
		expect(ok).toBe(true)
		expect(CureInventory.heldBy(inv, "U:1")).toBeNil()
		expect(CureInventory.holderOf(inv, itemId)).toBeNil()

		local item = CureInventory.getItem(inv, itemId)
		expect(item.state).toBe(CureInventory.State.DROPPED)
		expect(item.position).toBe(position)
		expect(#inv.order).toBe(1)
		expect(CureInventory.countByState(inv, CureInventory.State.DROPPED)).toBe(1)
		expect(CureInventory.countByState(inv, CureInventory.State.SUPPLY)).toBe(0)

		local picked = CureInventory.pickup(inv, itemId, "U:2")
		expect(picked).toBe(true)
		expect(CureInventory.holderOf(inv, itemId)).toBe("U:2")
		expect(#inv.order).toBe(1)
	end)

	it("consumes only the carried item and never twice", function()
		local inv = newInventory(1)
		local itemId = inv.order[1]
		CureInventory.pickup(inv, itemId, "U:1")

		local ok, consumedId = CureInventory.consume(inv, "U:1")
		expect(ok).toBe(true)
		expect(consumedId).toBe(itemId)
		expect(CureInventory.getItem(inv, itemId).state).toBe(CureInventory.State.CONSUMED)
		expect(CureInventory.countByState(inv, CureInventory.State.CONSUMED)).toBe(1)

		local again, reason = CureInventory.consume(inv, "U:1")
		expect(again).toBe(false)
		expect(reason).toBe(Reason.NotHolding)

		local unavailable, unavailableReason = CureInventory.pickup(inv, itemId, "U:2")
		expect(unavailable).toBe(false)
		expect(unavailableReason).toBe(Reason.ItemUnavailable)
	end)

	it("applies a short retry cooldown after a failed attempt", function()
		local inv = newInventory(1)
		expect(CureInventory.canAttempt(inv, "U:1", 100)).toBe(true)
		CureInventory.onFailedAttempt(inv, "U:1", 100)
		expect(CureInventory.canAttempt(inv, "U:1", 100)).toBe(false)
		expect(CureInventory.canAttempt(inv, "U:1", 100 + BalanceConfig.CureRetryCooldownSeconds - 0.01)).toBe(false)
		expect(CureInventory.canAttempt(inv, "U:1", 100 + BalanceConfig.CureRetryCooldownSeconds)).toBe(true)
		expect(CureInventory.retryReadyAt(inv, "U:1")).toBe(101.5)
	end)

	it("drops a leaving holder's item at the last position for someone else to take", function()
		local inv = newInventory(1)
		local itemId = inv.order[1]
		CureInventory.pickup(inv, itemId, "U:1")

		local lastPosition = { x = 1, y = 2, z = 3 }
		CureInventory.drop(inv, "U:1", lastPosition)

		local taken = CureInventory.pickup(inv, itemId, "U:2")
		expect(taken).toBe(true)
		expect(CureInventory.getItem(inv, itemId).position).toBeNil()
		expect(CureInventory.holderOf(inv, itemId)).toBe("U:2")
	end)

	it("rejects unknown item ids and drops by a non-holder", function()
		local inv = newInventory(1)
		local ok, reason = CureInventory.pickup(inv, "C:999", "U:1")
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.UnknownItem)

		local dropped, dropReason = CureInventory.drop(inv, "U:1", nil)
		expect(dropped).toBe(false)
		expect(dropReason).toBe(Reason.NotHolding)
	end)
end)

TestKit.finish()
