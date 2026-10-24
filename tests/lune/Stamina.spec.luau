--!strict
-- Stamina 的冲刺消耗、恢复、起步阈值与自动停止测试（GDB V1.1 §9.3、§24.4）。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local Stamina = require("../../src/server/logic/Stamina")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local Greybox = BalanceConfig.Greybox

local function newStamina(): Stamina.Stamina
	return Stamina.new(BalanceConfig)
end

describe("Stamina.new / speedFor", function()
	it("初始为满耐力、未冲刺、步行速度", function()
		local stamina = newStamina()
		expect(stamina.value).toBe(Greybox.SprintMaxSeconds)
		expect(stamina.sprinting).toBe(false)
		expect(Stamina.speedFor(BalanceConfig, stamina)).toBe(Greybox.HumanWalkSpeed)
	end)

	it("冲刺时使用冲刺速度", function()
		local stamina = newStamina()
		Stamina.setSprintIntent(stamina, true)
		expect(Stamina.speedFor(BalanceConfig, stamina)).toBe(Greybox.HumanSprintSpeed)
	end)
end)

describe("Stamina.step", function()
	it("冲刺每秒消耗 1 秒耐力", function()
		local stamina = newStamina()
		Stamina.setSprintIntent(stamina, true)
		Stamina.step(stamina, 2)
		expect(stamina.value).toBe(Greybox.SprintMaxSeconds - 2)
		expect(stamina.sprinting).toBe(true)
	end)

	it("耐力耗尽时自动停止冲刺并回到步行速度", function()
		local stamina = newStamina()
		Stamina.setSprintIntent(stamina, true)
		Stamina.step(stamina, Greybox.SprintMaxSeconds + 10)
		expect(stamina.value).toBe(0)
		expect(stamina.sprinting).toBe(false)
		expect(Stamina.speedFor(BalanceConfig, stamina)).toBe(Greybox.HumanWalkSpeed)
	end)

	it("停止冲刺后按 StaminaRegenRatio 恢复", function()
		local stamina = newStamina()
		Stamina.setSprintIntent(stamina, true)
		Stamina.step(stamina, 3)
		Stamina.setSprintIntent(stamina, false)
		Stamina.step(stamina, 1)
		expect(stamina.value).toBe(Greybox.SprintMaxSeconds - 3 + Greybox.StaminaRegenRatio)
	end)

	it("恢复不超过上限", function()
		local stamina = newStamina()
		stamina.value = Greybox.SprintMaxSeconds - Greybox.StaminaRegenRatio / 2
		Stamina.step(stamina, 1)
		expect(stamina.value).toBe(Greybox.SprintMaxSeconds)
	end)

	it("负 dt 不改变状态", function()
		local stamina = newStamina()
		stamina.value = 2
		Stamina.step(stamina, -5)
		expect(stamina.value).toBe(2)
		expect(stamina.sprinting).toBe(false)
	end)
end)

describe("Stamina.setSprintIntent", function()
	it("耐力低于 SprintMinStartSeconds 时无法开始冲刺", function()
		local stamina = newStamina()
		stamina.value = Greybox.SprintMinStartSeconds - 0.01
		Stamina.setSprintIntent(stamina, true)
		expect(stamina.sprinting).toBe(false)
		expect(Stamina.speedFor(BalanceConfig, stamina)).toBe(Greybox.HumanWalkSpeed)
	end)

	it("恰好在阈值上可以开始冲刺", function()
		local stamina = newStamina()
		stamina.value = Greybox.SprintMinStartSeconds
		Stamina.setSprintIntent(stamina, true)
		expect(stamina.sprinting).toBe(true)
	end)

	it("已经开始冲刺时不会因低于阈值被打断", function()
		local stamina = newStamina()
		stamina.sprinting = true
		stamina.value = 0.1
		Stamina.setSprintIntent(stamina, true)
		expect(stamina.sprinting).toBe(true)
	end)

	it("松开冲刺意图立即停止", function()
		local stamina = newStamina()
		Stamina.setSprintIntent(stamina, true)
		Stamina.setSprintIntent(stamina, false)
		expect(stamina.sprinting).toBe(false)
	end)
end)

TestKit.finish()
