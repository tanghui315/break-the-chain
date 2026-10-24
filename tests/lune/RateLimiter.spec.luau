--!strict
-- 动作频率限制测试（GDB V1.1 §20.4、§21.2）：令牌桶容量、补充速率、独立键与显式移除。

local TestKit = require("./TestKit")
local RateLimiter = require("../../src/server/logic/RateLimiter")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local function newLimiter(): RateLimiter.Limiter
	return RateLimiter.new(15, 15)
end

describe("RateLimiter.allow", function()
	it("新键按容量放行，第 capacity + 1 次被丢弃", function()
		local limiter = newLimiter()
		for _ = 1, 15 do
			expect(RateLimiter.allow(limiter, "U:1", 0)).toBe(true)
		end
		expect(RateLimiter.allow(limiter, "U:1", 0)).toBe(false)
	end)

	it("按 refillPerSecond 补充，且不超过容量", function()
		local limiter = newLimiter()
		for _ = 1, 15 do
			RateLimiter.allow(limiter, "U:1", 0)
		end
		expect(RateLimiter.allow(limiter, "U:1", 0)).toBe(false)

		-- 0.5 秒后补回 7.5 个令牌，足以再放行一次
		expect(RateLimiter.allow(limiter, "U:1", 0.5)).toBe(true)

		-- 长时间空闲后封顶在容量 15（1 次先放行 + 14 次用尽 + 第 16 次拒绝）
		expect(RateLimiter.allow(limiter, "U:1", 100)).toBe(true)
		for _ = 1, 14 do
			expect(RateLimiter.allow(limiter, "U:1", 100)).toBe(true)
		end
		expect(RateLimiter.allow(limiter, "U:1", 100)).toBe(false)
	end)

	it("不同参与者互不影响", function()
		local limiter = newLimiter()
		for _ = 1, 15 do
			RateLimiter.allow(limiter, "U:1", 0)
		end
		expect(RateLimiter.allow(limiter, "U:1", 0)).toBe(false)
		expect(RateLimiter.allow(limiter, "U:2", 0)).toBe(true)
	end)

	it("时间不会倒流时按 0 补充", function()
		local limiter = newLimiter()
		RateLimiter.allow(limiter, "U:1", 10)
		expect(RateLimiter.allow(limiter, "U:1", 5)).toBe(true)
	end)

	it("cost 大于 1 时一次性扣除对应令牌", function()
		local limiter = newLimiter()
		expect(RateLimiter.allow(limiter, "U:1", 0, 10)).toBe(true)
		expect(RateLimiter.allow(limiter, "U:1", 0, 6)).toBe(false)
		expect(RateLimiter.allow(limiter, "U:1", 0, 5)).toBe(true)
	end)

	it("remove / reset 后恢复满桶", function()
		local limiter = newLimiter()
		for _ = 1, 15 do
			RateLimiter.allow(limiter, "U:1", 0)
		end
		RateLimiter.remove(limiter, "U:1")
		expect(RateLimiter.allow(limiter, "U:1", 0)).toBe(true)

		for _ = 1, 15 do
			RateLimiter.allow(limiter, "U:2", 0)
		end
		RateLimiter.reset(limiter)
		expect(RateLimiter.allow(limiter, "U:2", 0)).toBe(true)
	end)
end)

TestKit.finish()
