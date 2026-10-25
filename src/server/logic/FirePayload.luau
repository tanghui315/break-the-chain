--!strict
-- Fire 请求的纯校验（GDB V1.1 §9A.7、§20.4）：客户端只发意图，服务端先校验字段类型与数值有限性，
-- 再由 Weapons.validateFire 校验开火间隔、弹药、origin 偏移、射程、回溯、锥角与遮挡。
-- 纯逻辑：不引用 Roblox 全局；Vector3 由服务端在边界转换成普通 {x,y,z} 表后传入。

export type Vec3 = { x: number, y: number, z: number }
export type WeaponName = "Melee" | "Pistol" | "Taser"

export type Validated = {
	weapon: WeaponName,
	origin: Vec3,
	direction: Vec3,
	targetId: string?,
}

export type Result = {
	ok: boolean,
	reason: string,
	value: Validated?,
}

local FirePayload = {}

local Reason = table.freeze({
	OK = "OK",
	INVALID_PAYLOAD = "INVALID_PAYLOAD",
	INVALID_WEAPON = "INVALID_WEAPON",
	INVALID_ORIGIN = "INVALID_ORIGIN",
	INVALID_DIRECTION = "INVALID_DIRECTION",
	INVALID_TARGET = "INVALID_TARGET",
})
FirePayload.Reason = Reason

local MAX_TARGET_ID_BYTES = 64
-- 客户端相机方向应为单位向量；允许轻微误差和压缩误差，但拒绝明显不是方向的畸形值。
local MAX_DIRECTION_LENGTH = 2
local EPSILON = 1e-9

local function rejected(reason: string): Result
	return { ok = false, reason = reason, value = nil }
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function finiteVec3(value: any): Vec3?
	if type(value) ~= "table" then
		return nil
	end
	local x, y, z = value.x, value.y, value.z
	if not finite(x) or not finite(y) or not finite(z) then
		return nil
	end
	return { x = x, y = y, z = z }
end

local function lengthOf(v: Vec3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

-- 校验动作载荷。weapon 只允许 A0.5 接入的三种；origin/direction 必须是有限三维向量；
-- targetId 只是提示，服务端仍按几何重新选目标，但仍限制长度避免把任意长字符串带进日志。
function FirePayload.validate(payload: any): Result
	if type(payload) ~= "table" then
		return rejected(Reason.INVALID_PAYLOAD)
	end

	local weapon = payload.weapon
	if weapon ~= "Melee" and weapon ~= "Pistol" and weapon ~= "Taser" then
		return rejected(Reason.INVALID_WEAPON)
	end

	local origin = finiteVec3(payload.origin)
	if origin == nil then
		return rejected(Reason.INVALID_ORIGIN)
	end

	local direction = finiteVec3(payload.direction)
	if direction == nil then
		return rejected(Reason.INVALID_DIRECTION)
	end
	local directionLength = lengthOf(direction)
	if directionLength <= EPSILON or directionLength > MAX_DIRECTION_LENGTH then
		return rejected(Reason.INVALID_DIRECTION)
	end

	local targetId = payload.targetId
	if targetId ~= nil then
		if type(targetId) ~= "string" or #targetId > MAX_TARGET_ID_BYTES then
			return rejected(Reason.INVALID_TARGET)
		end
		if targetId == "" then
			targetId = nil
		end
	end

	return {
		ok = true,
		reason = Reason.OK,
		value = {
			weapon = weapon,
			origin = origin,
			direction = direction,
			targetId = targetId,
		},
	}
end

return table.freeze(FirePayload)
