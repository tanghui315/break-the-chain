--!strict
-- 每参与者动作频率限制（GDB V1.1 §20.4、§21.2）：令牌桶，容量 = 每秒允许量，超出即丢弃。
-- 纯逻辑：时间由调用方传入（服务端时钟），可在 Lune 中测试；不引用任何 Roblox 全局。

export type Bucket = {
	tokens: number,
	updatedAt: number,
}

export type Limiter = {
	capacity: number,
	refillPerSecond: number,
	buckets: { [string]: Bucket },
}

local RateLimiter = {}

-- capacity 同时作为桶上限与初始令牌数；refillPerSecond 为持续补充速率。
function RateLimiter.new(capacity: number, refillPerSecond: number): Limiter
	assert(capacity > 0, "capacity must be positive")
	assert(refillPerSecond >= 0, "refillPerSecond must be non-negative")
	return {
		capacity = capacity,
		refillPerSecond = refillPerSecond,
		buckets = {},
	}
end

function RateLimiter.allow(limiter: Limiter, key: string, now: number, cost: number?): boolean
	local spend = cost or 1
	if spend <= 0 then
		return true
	end

	local bucket = limiter.buckets[key]
	if bucket == nil then
		bucket = { tokens = limiter.capacity, updatedAt = now }
		limiter.buckets[key] = bucket
	else
		local elapsed = math.max(0, now - bucket.updatedAt)
		bucket.tokens = math.min(limiter.capacity, bucket.tokens + elapsed * limiter.refillPerSecond)
		bucket.updatedAt = now
	end

	if bucket.tokens < spend then
		return false
	end
	bucket.tokens -= spend
	return true
end

-- 参与者离开时丢弃其桶，避免长期运行后字典无限增长。
function RateLimiter.remove(limiter: Limiter, key: string)
	limiter.buckets[key] = nil
end

function RateLimiter.reset(limiter: Limiter)
	table.clear(limiter.buckets)
end

return table.freeze(RateLimiter)
