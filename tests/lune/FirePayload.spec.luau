--!strict
-- FirePayload 的字段校验（GDB V1.1 §9A.7、§20.4）：武器枚举、有限三维向量、方向长度与 targetId 上限。

local TestKit = require("./TestKit")
local FirePayload = require("../../src/server/logic/FirePayload")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = FirePayload.Reason

local function payload(overrides: any?): any
	local value: any = {
		weapon = "Pistol",
		origin = { x = 0, y = 5, z = 0 },
		direction = { x = 0, y = 0, z = -1 },
		targetId = "U:1",
	}
	if overrides ~= nil then
		for key, item in overrides do
			value[key] = item
		end
	end
	return value
end

describe("FirePayload.validate", function()
	it("接受 Melee / Pistol / Taser 与完整载荷", function()
		for _, weapon in { "Melee", "Pistol", "Taser" } do
			local result = FirePayload.validate(payload({ weapon = weapon }))
			expect(result.ok).toBe(true)
			expect(result.reason).toBe(Reason.OK)
			expect(result.value ~= nil).toBe(true)
			if result.value ~= nil then
				expect(result.value.weapon).toBe(weapon)
				expect(result.value.targetId).toBe("U:1")
			end
		end
	end)

	it("targetId 可省略或为空字符串", function()
		local without = payload()
		without.targetId = nil
		local result = FirePayload.validate(without)
		expect(result.ok).toBe(true)
		if result.value ~= nil then
			expect(result.value.targetId).toBeNil()
		end

		local empty = FirePayload.validate(payload({ targetId = "" }))
		expect(empty.ok).toBe(true)
		if empty.value ~= nil then
			expect(empty.value.targetId).toBeNil()
		end
	end)

	it("拒绝非表、未知武器、缺字段与超长 targetId", function()
		expect(FirePayload.validate(nil).reason).toBe(Reason.INVALID_PAYLOAD)
		expect(FirePayload.validate({}).reason).toBe(Reason.INVALID_WEAPON)
		expect(FirePayload.validate(payload({ weapon = "Shotgun" })).reason).toBe(Reason.INVALID_WEAPON)
		local missingOrigin = payload()
		missingOrigin.origin = nil
		expect(FirePayload.validate(missingOrigin).reason).toBe(Reason.INVALID_ORIGIN)
		expect(FirePayload.validate(payload({ targetId = string.rep("x", 65) })).reason).toBe(Reason.INVALID_TARGET)
	end)

	it("拒绝 NaN / 无限 / 非数字的 origin 与 direction", function()
		expect(FirePayload.validate(payload({ origin = { x = 0 / 0, y = 0, z = 0 } })).reason).toBe(
			Reason.INVALID_ORIGIN
		)
		expect(FirePayload.validate(payload({ origin = { x = math.huge, y = 0, z = 0 } })).reason).toBe(
			Reason.INVALID_ORIGIN
		)
		expect(FirePayload.validate(payload({ direction = { x = "1", y = 0, z = 0 } })).reason).toBe(
			Reason.INVALID_DIRECTION
		)
	end)

	it("方向不能是零向量或畸形大向量", function()
		expect(FirePayload.validate(payload({ direction = { x = 0, y = 0, z = 0 } })).reason).toBe(
			Reason.INVALID_DIRECTION
		)
		expect(FirePayload.validate(payload({ direction = { x = 0, y = 0, z = 3 } })).reason).toBe(
			Reason.INVALID_DIRECTION
		)
	end)

	it("方向无需严格单位化，Weapons 会在服务端归一化", function()
		local result = FirePayload.validate(payload({ direction = { x = 0, y = 0, z = -0.5 } }))
		expect(result.ok).toBe(true)
	end)
end)

TestKit.finish()
