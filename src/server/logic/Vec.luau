--!strict
-- 纯向量工具（GDB V1.1 §9.5）。位置统一用普通表 { x, y, z } 表示。
-- 不引用 Vector3 等 Roblox 类型，保证可在 Lune 中测试。

export type Vec3 = { x: number, y: number, z: number }

local Vec = {}

local EPSILON = 1e-9

function Vec.sub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function Vec.length(v: Vec3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function Vec.dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function Vec.lerp(a: Vec3, b: Vec3, t: number): Vec3
	return {
		x = a.x + (b.x - a.x) * t,
		y = a.y + (b.y - a.y) * t,
		z = a.z + (b.z - a.z) * t,
	}
end

-- 压平到水平面（y = 0）并归一化；水平长度为 0 时返回零向量。
function Vec.horizontal(v: Vec3): Vec3
	local length = math.sqrt(v.x * v.x + v.z * v.z)
	if length <= EPSILON then
		return { x = 0, y = 0, z = 0 }
	end
	return { x = v.x / length, y = 0, z = v.z / length }
end

function Vec.horizontalDistance(a: Vec3, b: Vec3): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

-- 水平面上的夹角（度），忽略 y。任一向量水平长度为 0 时返回 180，视为无法对准。
function Vec.angleBetweenHorizontalDegrees(a: Vec3, b: Vec3): number
	local aLength = math.sqrt(a.x * a.x + a.z * a.z)
	local bLength = math.sqrt(b.x * b.x + b.z * b.z)
	if aLength <= EPSILON or bLength <= EPSILON then
		return 180
	end
	local cosine = (a.x * b.x + a.z * b.z) / (aLength * bLength)
	cosine = math.clamp(cosine, -1, 1)
	return math.deg(math.acos(cosine))
end

return table.freeze(Vec)
