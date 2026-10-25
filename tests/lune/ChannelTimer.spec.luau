--!strict
-- ChannelTimer 测试（GDB V1.1 §21.2）：服务端累计、每 tick 复验、替换、并行完成的确定性顺序。

local TestKit = require("./TestKit")
local ChannelTimer = require("../../src/server/logic/ChannelTimer")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Kind = ChannelTimer.Kind
local Reason = ChannelTimer.Reason

local function valid(_channel: ChannelTimer.Channel): (boolean, string?)
	return true, nil
end

describe("ChannelTimer", function()
	it("completes only after the accumulated valid time reaches the duration", function()
		local state = ChannelTimer.new()
		local ok, reason = ChannelTimer.start(state, "U:1", Kind.CURE, "U:2", 0, 2)
		expect(ok).toBe(true)
		expect(reason).toBeNil()

		local first = ChannelTimer.tick(state, 1, valid)
		expect(#first.completed).toBe(0)
		expect(#first.cancelled).toBe(0)
		local progress = ChannelTimer.progress(state, "U:1", 1)
		expect(progress.elapsed).toBe(1)
		expect(progress.ratio).toBe(0.5)

		local second = ChannelTimer.tick(state, 2, valid)
		expect(#second.completed).toBe(1)
		expect(second.completed[1].actorId).toBe("U:1")
		expect(second.completed[1].kind).toBe(Kind.CURE)
		expect(second.completed[1].targetId).toBe("U:2")
		expect(ChannelTimer.get(state, "U:1")).toBeNil()
	end)

	it("cancels on the first invalid tick and discards that tick's delta", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:1", Kind.CURE, "U:2", 0, 2)
		local result = ChannelTimer.tick(state, 1, function(_channel)
			return false, "OUT_OF_RANGE"
		end)
		expect(#result.completed).toBe(0)
		expect(#result.cancelled).toBe(1)
		expect(result.cancelled[1].reason).toBe("OUT_OF_RANGE")
		expect(result.cancelled[1].channel.actorId).toBe("U:1")
		expect(ChannelTimer.count(state)).toBe(0)
	end)

	it("replaces the previous channel for the same actor", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:1", Kind.CURE, "U:2", 0, 2)
		local ok, _reason, replaced = ChannelTimer.start(state, "U:1", Kind.RELINK, "U:3", 1, 2)
		expect(ok).toBe(true)
		expect(replaced.kind).toBe(Kind.CURE)
		expect(replaced.targetId).toBe("U:2")
		expect(ChannelTimer.count(state)).toBe(1)
		expect(ChannelTimer.get(state, "U:1").kind).toBe(Kind.RELINK)

		local result = ChannelTimer.tick(state, 3, valid)
		expect(#result.completed).toBe(1)
		expect(result.completed[1].kind).toBe(Kind.RELINK)
		expect(result.completed[1].startedAt).toBe(1)
	end)

	it("rejects invalid actor, kind and duration", function()
		local state = ChannelTimer.new()
		expect(ChannelTimer.start(state, "", Kind.CURE, nil, 0, 1)).toBe(false)
		expect(ChannelTimer.start(state, "U:1", "BOGUS" :: any, nil, 0, 1)).toBe(false)
		expect(ChannelTimer.start(state, "U:1", Kind.CURE, nil, 0, -1)).toBe(false)
		expect(ChannelTimer.start(state, "U:1", Kind.CURE, nil, 0, math.huge)).toBe(false)
		local ok, reason = ChannelTimer.start(state, "U:1", Kind.CURE, nil, 0, -1)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.InvalidDuration)
	end)

	it("cancelInvolving catches both the actor and the target in start order", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:1", Kind.CURE, "U:9", 0, 5)
		ChannelTimer.start(state, "U:2", Kind.RELINK, "U:9", 0, 5)
		ChannelTimer.start(state, "U:3", Kind.EXTRACT, nil, 0, 5)

		local cancelled = ChannelTimer.cancelInvolving(state, "U:9", "LEFT")
		expect(#cancelled).toBe(2)
		expect(cancelled[1].channel.actorId).toBe("U:1")
		expect(cancelled[2].channel.actorId).toBe("U:2")
		expect(cancelled[1].reason).toBe("LEFT")
		expect(ChannelTimer.count(state)).toBe(1)
		expect(ChannelTimer.get(state, "U:3").kind).toBe(Kind.EXTRACT)
	end)

	it("orders simultaneous completions by start order, not table iteration order", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:2", Kind.CURE, nil, 0, 1)
		ChannelTimer.start(state, "U:1", Kind.EXTRACT, nil, 0, 1)
		ChannelTimer.start(state, "U:3", Kind.RELINK, nil, 0, 1)

		local result = ChannelTimer.tick(state, 1, valid)
		expect(#result.completed).toBe(3)
		expect(result.completed[1].actorId).toBe("U:2")
		expect(result.completed[2].actorId).toBe("U:1")
		expect(result.completed[3].actorId).toBe("U:3")
	end)

	it("cancel returns the channel and removes it; cancelAll drains everything", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:1", Kind.CURE, nil, 0, 1)
		ChannelTimer.start(state, "U:2", Kind.RELINK, nil, 0, 1)

		local cancelled = ChannelTimer.cancel(state, "U:1", "CANCELLED")
		expect(cancelled.actorId).toBe("U:1")
		expect(ChannelTimer.get(state, "U:1")).toBeNil()

		local rest = ChannelTimer.cancelAll(state, "ROUND_OVER")
		expect(#rest).toBe(1)
		expect(rest[1].channel.actorId).toBe("U:2")
		expect(rest[1].reason).toBe("ROUND_OVER")
		expect(ChannelTimer.count(state)).toBe(0)
	end)

	it("does not rewind accumulation when the server clock goes backwards", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:1", Kind.CURE, nil, 10, 5)
		local rewind = ChannelTimer.tick(state, 8, valid)
		expect(#rewind.completed).toBe(0)
		expect(ChannelTimer.progress(state, "U:1", 8).elapsed).toBe(0)
		local after = ChannelTimer.tick(state, 11, valid)
		expect(#after.completed).toBe(0)
		expect(ChannelTimer.progress(state, "U:1", 11).elapsed).toBe(1)
	end)

	it("exposes active channels as a snapshot without mutating state", function()
		local state = ChannelTimer.new()
		ChannelTimer.start(state, "U:1", Kind.CURE, "U:2", 0, 2)
		local active = ChannelTimer.active(state)
		expect(#active).toBe(1)
		active[1].accumulated = 99
		expect(ChannelTimer.get(state, "U:1").accumulated).toBe(0)
		expect(ChannelTimer.count(state)).toBe(1)
	end)
end)

TestKit.finish()
