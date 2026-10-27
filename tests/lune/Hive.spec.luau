--!strict
-- 母巢指挥纯状态机测试（GDB V1.1 §6.4，EXP-09）：标记冷却/持续/转化窗口，集结引导/打断/信标生命周期。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local Hive = require("../../src/server/logic/Hive")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = Hive.Reason
local C = BalanceConfig

local function v(x: number, z: number): Hive.Vec3
	return { x = x, y = 0, z = z }
end

local function at(position: Hive.Vec3?): (string) -> Hive.Vec3?
	return function(_rootId: string)
		return position
	end
end

describe("源头标记", function()
	it("默认关闭，数值与 GDB §6.4 一致", function()
		expect(C.HiveAbilitiesEnabled).toBe(false)
		expect(C.RootMarkSeconds).toBe(6)
		expect(C.RootMarkCooldownSeconds).toBe(30)
		expect(C.RootRallyBeaconSeconds).toBe(20)
		expect(C.RootRallyCooldownSeconds).toBe(60)
		-- 覆盖时间合计 ≤ 30%（各自占比之和的平均）
		local coverage = (
			C.RootMarkSeconds / C.RootMarkCooldownSeconds + C.RootRallyBeaconSeconds / C.RootRallyCooldownSeconds
		) / 2
		expect(coverage <= 0.3).toBe(true)
	end)

	it("标记持续 6 秒，冷却 30 秒内再次标记被拒", function()
		local state = Hive.new(C)
		local ok, reason = Hive.tryMark(state, "root", "h1", 10)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.OK)
		expect(Hive.markOn(state, "h1", 15.9) ~= nil).toBe(true)
		expect(Hive.markOn(state, "h1", 16) == nil).toBe(true)
		local again, againReason = Hive.tryMark(state, "root", "h2", 39.9)
		expect(again).toBe(false)
		expect(againReason).toBe(Reason.COOLDOWN)
		expect((Hive.tryMark(state, "root", "h2", 40))).toBe(true)
	end)

	it("两名零号各自独立冷却", function()
		local state = Hive.new(C)
		expect((Hive.tryMark(state, "rootA", "h1", 0))).toBe(true)
		expect((Hive.tryMark(state, "rootB", "h2", 1))).toBe(true)
		expect(#Hive.activeMarks(state, 2)).toBe(2)
		expect(Hive.activeMarks(state, 2)[1].rootId).toBe("rootA")
	end)

	it("标记后 10 秒内被咬计一次转化，之后不再重复计", function()
		local state = Hive.new(C)
		Hive.tryMark(state, "root", "h1", 0)
		expect(Hive.onBite(state, "h1", 8)).toBe(8)
		expect(Hive.onBite(state, "h1", 9) == nil).toBe(true)
	end)

	it("超过转化窗口被咬不计，step 会清理过期标记", function()
		local state = Hive.new(C)
		Hive.tryMark(state, "root", "h1", 0)
		Hive.step(state, 9, at(nil))
		expect(state.marks["h1"] ~= nil).toBe(true)
		Hive.step(state, 10.5, at(nil))
		expect(state.marks["h1"] == nil).toBe(true)
		Hive.tryMark(state, "root", "h2", 40)
		expect(Hive.onBite(state, "h2", 51) == nil).toBe(true)
	end)
end)

describe("母巢集结", function()
	it("引导 2 秒后在原地立起信标，持续 20 秒后熄灭，冷却 60 秒", function()
		local state = Hive.new(C)
		local ok = Hive.startRally(state, "root", 100, v(5, 5), 50, nil)
		expect(ok).toBe(true)
		expect(#Hive.step(state, 101, at(v(5, 5)))).toBe(0)
		local events = Hive.step(state, 102, at(v(5.5, 5)))
		expect(#events).toBe(1)
		expect(events[1].kind).toBe("RALLY_PLACED")
		local beacon = Hive.beaconOf(state, "root", 110)
		assert(beacon, "beacon")
		expect(beacon.position.x).toBe(5)
		local expired = Hive.step(state, 122, at(v(5, 5)))
		expect(expired[1].kind).toBe("BEACON_EXPIRED")
		expect(Hive.beaconOf(state, "root", 122) == nil).toBe(true)
		expect(Hive.rallyReadyAt(state, "root")).toBe(162)
		local again, reason = Hive.startRally(state, "root", 150, v(0, 0), 50, nil)
		expect(again).toBe(false)
		expect(reason).toBe(Reason.COOLDOWN)
	end)

	it("离人类太近或撤离开启时离撤离区太近，拒绝开始", function()
		local state = Hive.new(C)
		local _, near = Hive.startRally(state, "root", 0, v(0, 0), C.RootRallyMinHumanDistance - 0.1, nil)
		expect(near).toBe(Reason.TOO_CLOSE_TO_HUMAN)
		local _, exit = Hive.startRally(state, "root", 0, v(0, 0), 100, C.RespawnMinDistanceFromExtraction - 1)
		expect(exit).toBe(Reason.TOO_CLOSE_TO_EXTRACTION)
		expect((Hive.startRally(state, "root", 0, v(0, 0), 100, C.RespawnMinDistanceFromExtraction))).toBe(true)
		local _, busy = Hive.startRally(state, "root", 0.5, v(0, 0), 100, nil)
		expect(busy).toBe(Reason.CHANNELING)
	end)

	it("引导中移动超出容差或离场被打断，进入 10 秒短冷却", function()
		local state = Hive.new(C)
		Hive.startRally(state, "root", 0, v(0, 0), 100, nil)
		local events = Hive.step(state, 1, at(v(C.RootRallyMoveTolerance + 0.5, 0)))
		expect(events[1].kind).toBe("RALLY_CANCELLED")
		expect(Hive.channelOf(state, "root") == nil).toBe(true)
		expect(Hive.rallyReadyAt(state, "root")).toBe(1 + C.RootRallyInterruptCooldownSeconds)

		Hive.startRally(state, "root", 20, v(0, 0), 100, nil)
		expect(Hive.step(state, 21, at(nil))[1].kind).toBe("RALLY_CANCELLED")
	end)

	it("外部打断（电击/倒地）与零号倒地拆信标", function()
		local state = Hive.new(C)
		Hive.startRally(state, "root", 0, v(0, 0), 100, nil)
		expect(Hive.cancelRally(state, "root", 1)).toBe(true)
		expect(Hive.cancelRally(state, "root", 1)).toBe(false)

		Hive.startRally(state, "root", 20, v(0, 0), 100, nil)
		Hive.step(state, 22, at(v(0, 0)))
		expect(Hive.beaconOf(state, "root", 23) ~= nil).toBe(true)
		expect(Hive.dropBeacon(state, "root")).toBe(true)
		expect(Hive.beaconOf(state, "root", 23) == nil).toBe(true)
		expect(Hive.dropBeacon(state, "root")).toBe(false)
	end)

	it("信标存在时不能叠第二个", function()
		local state = Hive.new(C)
		Hive.startRally(state, "root", 0, v(0, 0), 100, nil)
		Hive.step(state, 2, at(v(0, 0)))
		state.roots["root"].rallyReadyAt = 0 -- 只测信标叠加，跳过冷却
		local _, reason = Hive.startRally(state, "root", 5, v(0, 0), 100, nil)
		expect(reason).toBe(Reason.BEACON_ACTIVE)
	end)
end)

TestKit.finish()
