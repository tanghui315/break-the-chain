--!strict
-- Grab 的两种扑咬结算测试（GDB V1.1 §9A.6，EXP-08）：
-- INSTANT 立即感染、GRAB 1 秒擒抱、命中解除、1.5 秒防扑咬保护，以及“完成/解除绝不双写”的时序。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local Grab = require("../../src/server/logic/Grab")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = Grab.Reason

local NOW = 100
local GRAB_SECONDS = BalanceConfig.GrabSeconds
local ESCAPE_IMMUNITY = BalanceConfig.GrabEscapeImmunitySeconds

local function newState(config: any?): Grab.State
	return Grab.new(config or BalanceConfig)
end

local function instantConfig(): any
	local config = table.clone(BalanceConfig)
	config.BiteMode = "INSTANT"
	return config
end

describe("INSTANT 模式（对照组）", function()
	it("扑咬命中立即感染，不产生擒抱", function()
		local state = newState(instantConfig())
		local result = Grab.onBiteHit(instantConfig(), state, "z1", "h1", NOW)
		expect(result.mode).toBe("INSTANT")
		expect(result.infect).toBe(true)
		expect(result.grabStarted).toBe(false)
		expect(result.reason).toBe(Reason.INFECT)
		expect(Grab.isGrabbed(state, "z1")).toBe(false)
		expect(Grab.isGrabbed(state, "h1")).toBe(false)
		expect(#Grab.tick(state, NOW + 10)).toBe(0)
	end)
end)

describe("GRAB 模式（推荐）", function()
	it("默认 BiteMode 为 GRAB；命中记录 1 秒擒抱，双方都被标记为擒抱中", function()
		expect(BalanceConfig.BiteMode).toBe("GRAB")
		local state = newState()
		local result = Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		expect(result.mode).toBe("GRAB")
		expect(result.infect).toBe(false)
		expect(result.grabStarted).toBe(true)
		expect(result.reason).toBe(Reason.GRAB_STARTED)
		expect(result.completesAt).toBe(NOW + GRAB_SECONDS)
		expect(Grab.isGrabbed(state, "z1")).toBe(true)
		expect(Grab.isGrabbed(state, "h1")).toBe(true)
		expect(Grab.grabTargetOf(state, "z1")).toBe("h1")
	end)

	it("擒抱未到期不完成；到期 tick 返回完成（→ 感染）并移除", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)

		expect(#Grab.tick(state, NOW + GRAB_SECONDS - 0.01)).toBe(0)
		expect(Grab.isGrabbed(state, "h1")).toBe(true)

		local completed = Grab.tick(state, NOW + GRAB_SECONDS)
		expect(#completed).toBe(1)
		expect(completed[1].zombieId).toBe("z1")
		expect(completed[1].humanId).toBe("h1")
		expect(Grab.isGrabbed(state, "h1")).toBe(false)
		expect(#Grab.tick(state, NOW + GRAB_SECONDS + 1)).toBe(0)
	end)

	it(
		"命中擒抱中的丧尸：解除擒抱，人类获得 1.5 秒防扑咬保护，丧尸进入扑咬冷却",
		function()
			local state = newState()
			Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)

			local broken = Grab.onZombieHit(state, "z1", NOW + 0.4)
			expect(broken.broken).toBe(true)
			expect(broken.humanId).toBe("h1")
			expect(broken.immuneUntil).toBe(NOW + 0.4 + ESCAPE_IMMUNITY)
			expect(broken.biteCooldownUntil).toBe(NOW + 0.4 + BalanceConfig.BiteCooldownSeconds)
			expect(Grab.isGrabbed(state, "z1")).toBe(false)
			expect(Grab.isGrabbed(state, "h1")).toBe(false)
			expect(Grab.isBiteImmune(state, "h1", NOW + 0.4)).toBe(true)
		end
	)

	it("解除后同一时刻的 tick 不会再次完成感染（先解除后完成）", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)

		local broken = Grab.onZombieHit(state, "z1", NOW + GRAB_SECONDS)
		expect(broken.broken).toBe(true)
		expect(#Grab.tick(state, NOW + GRAB_SECONDS)).toBe(0)
		expect(#Grab.tick(state, NOW + GRAB_SECONDS + 1)).toBe(0)
	end)

	it("先完成再收到命中：tick 返回感染，解除返回 broken = false（绝不双写）", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)

		local completed = Grab.tick(state, NOW + GRAB_SECONDS)
		expect(#completed).toBe(1)
		local broken = Grab.onZombieHit(state, "z1", NOW + GRAB_SECONDS)
		expect(broken.broken).toBe(false)
		expect(broken.humanId).toBeNil()
	end)

	it("防扑咬保护期内不能再次擒抱，到期边界可以", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		Grab.onZombieHit(state, "z1", NOW)

		local blocked = Grab.onBiteHit(BalanceConfig, state, "z2", "h1", NOW + ESCAPE_IMMUNITY - 0.01)
		expect(blocked.grabStarted).toBe(false)
		expect(blocked.infect).toBe(false)
		expect(blocked.reason).toBe(Reason.BITE_IMMUNE)

		local allowed = Grab.onBiteHit(BalanceConfig, state, "z2", "h1", NOW + ESCAPE_IMMUNITY)
		expect(allowed.grabStarted).toBe(true)
		expect(Grab.isBiteImmune(state, "h1", NOW + ESCAPE_IMMUNITY)).toBe(false)
	end)

	it("同一只丧尸不能同时擒抱两人", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		local second = Grab.onBiteHit(BalanceConfig, state, "z1", "h2", NOW + 0.1)
		expect(second.grabStarted).toBe(false)
		expect(second.reason).toBe(Reason.ALREADY_GRABBING)
		expect(Grab.grabTargetOf(state, "z1")).toBe("h1")
	end)

	it("同一人类不能被两只丧尸同时擒抱", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		local second = Grab.onBiteHit(BalanceConfig, state, "z2", "h1", NOW + 0.1)
		expect(second.grabStarted).toBe(false)
		expect(second.reason).toBe(Reason.TARGET_GRABBED)
	end)

	it("不能擒抱自己", function()
		local state = newState()
		local result = Grab.onBiteHit(BalanceConfig, state, "h1", "h1", NOW)
		expect(result.grabStarted).toBe(false)
		expect(result.reason).toBe(Reason.INVALID_TARGET)
	end)

	it("没有擒抱时命中返回 broken = false", function()
		local state = newState()
		local broken = Grab.onZombieHit(state, "z1", NOW)
		expect(broken.broken).toBe(false)
		expect(broken.humanId).toBeNil()
		expect(broken.immuneUntil).toBeNil()
	end)
end)

describe("参与者离开", function()
	it("丧尸离开取消其擒抱，不产生防扑咬保护", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		local removed = Grab.removeParticipant(state, "z1")
		expect(#removed).toBe(1)
		expect(removed[1].humanId).toBe("h1")
		expect(Grab.isGrabbed(state, "h1")).toBe(false)
		expect(Grab.isBiteImmune(state, "h1", NOW)).toBe(false)
		expect(#Grab.tick(state, NOW + GRAB_SECONDS)).toBe(0)
	end)

	it("人类离开取消针对他的擒抱", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		local removed = Grab.removeParticipant(state, "h1")
		expect(#removed).toBe(1)
		expect(removed[1].zombieId).toBe("z1")
		expect(Grab.isGrabbed(state, "z1")).toBe(false)
	end)

	it("离开时清掉该参与者的防扑咬保护记录", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		Grab.onZombieHit(state, "z1", NOW)
		expect(Grab.isBiteImmune(state, "h1", NOW)).toBe(true)
		Grab.removeParticipant(state, "h1")
		expect(Grab.isBiteImmune(state, "h1", NOW)).toBe(false)
		expect(state.biteImmuneUntil["h1"]).toBeNil()
	end)
end)

describe("保护记录清理", function()
	it("tick 清理已过期的防扑咬保护条目", function()
		local state = newState()
		Grab.onBiteHit(BalanceConfig, state, "z1", "h1", NOW)
		Grab.onZombieHit(state, "z1", NOW)
		expect(state.biteImmuneUntil["h1"]).toBe(NOW + ESCAPE_IMMUNITY)
		Grab.tick(state, NOW + ESCAPE_IMMUNITY)
		expect(state.biteImmuneUntil["h1"]).toBeNil()
	end)
end)

TestKit.finish()
