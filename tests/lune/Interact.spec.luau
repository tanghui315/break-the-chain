--!strict
-- Gate A-2b 交互纯逻辑：目标选择（零号提示）与 targetId 载荷校验（§10.2、§17.3、§20.4）。

local TestKit = require("./TestKit")
local InteractPayload = require("../../src/server/logic/InteractPayload")
local InteractTarget = require("../../src/shared/InteractTarget")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local PayloadReason = InteractPayload.Reason

local ORIGIN = { x = 0, z = 0 }

local function candidate(id: string, x: number, z: number, eligible: boolean, isRoot: boolean): InteractTarget.Candidate
	return { id = id, x = x, z = z, eligible = eligible, isRoot = isRoot }
end

describe("InteractTarget.selectNearest", function()
	it("returns the nearest eligible target", function()
		local selection = InteractTarget.selectNearest({
			candidate("far", 7, 0, true, false),
			candidate("near", 3, 4, true, false),
			candidate("out", 20, 0, true, false),
			candidate("ineligible", 1, 0, false, false),
		}, ORIGIN, 8, false)
		expect(selection.id).toBe("near")
		expect(selection.distance).toBe(5)
		expect(selection.rootBlocked).toBe(false)
	end)

	it("blocks a nearest SOURCE when roots are not accepted (cure)", function()
		local selection = InteractTarget.selectNearest({
			candidate("root", 2, 0, true, true),
			candidate("child", 6, 0, true, false),
		}, ORIGIN, 8, false)
		expect(selection.id).toBeNil()
		expect(selection.rootBlocked).toBe(true)
		expect(selection.distance).toBe(2)
	end)

	it("accepts a SOURCE as a relink target", function()
		local selection = InteractTarget.selectNearest({
			candidate("root", 2, 0, true, true),
			candidate("child", 6, 0, true, false),
		}, ORIGIN, 8, true)
		expect(selection.id).toBe("root")
		expect(selection.rootBlocked).toBe(false)
	end)

	it("ignores a SOURCE just outside the range and picks the in-range non-root", function()
		local selection = InteractTarget.selectNearest({
			candidate("root", 9, 0, true, true),
			candidate("child", 6, 0, true, false),
		}, ORIGIN, 8, false)
		expect(selection.id).toBe("child")
		expect(selection.rootBlocked).toBe(false)
	end)

	it("returns an empty selection when nothing is in range", function()
		local selection = InteractTarget.selectNearest({
			candidate("far", 30, 0, true, false),
		}, ORIGIN, 8, false)
		expect(selection.id).toBeNil()
		expect(selection.distance).toBeNil()
		expect(selection.rootBlocked).toBe(false)
	end)
end)

describe("InteractPayload.validateTarget", function()
	it("rejects non-table / missing / non-string / empty targets", function()
		expect(InteractPayload.validateTarget(nil, 64).reason).toBe(PayloadReason.NotTable)
		expect(InteractPayload.validateTarget("U:1", 64).reason).toBe(PayloadReason.NotTable)
		expect(InteractPayload.validateTarget({}, 64).reason).toBe(PayloadReason.MissingTarget)
		expect(InteractPayload.validateTarget({ targetId = "" }, 64).reason).toBe(PayloadReason.MissingTarget)
		expect(InteractPayload.validateTarget({ targetId = 12 }, 64).reason).toBe(PayloadReason.MissingTarget)
	end)

	it("rejects oversized target ids", function()
		local long = string.rep("U", 65)
		expect(InteractPayload.validateTarget({ targetId = long }, 64).reason).toBe(PayloadReason.TargetTooLong)
	end)

	it("accepts a normal ParticipantId", function()
		local result = InteractPayload.validateTarget({ targetId = "U:12345" }, 64)
		expect(result.ok).toBe(true)
		expect(result.targetId).toBe("U:12345")
		expect(result.reason).toBeNil()
	end)
end)

TestKit.finish()
