--!strict
-- 丧尸复活点选择（GDB V1.1 §9A.3）：感染区中距最近人类 ≥ 60 studs、距撤离区 ≥ 80 studs，
-- 优先选离人类最远的一处；没有合格点时退化为“离最近人类最远”的感染区，绝不返回 nil（只要存在感染区）。
-- 距离使用水平面距离（忽略 y），与 §9.5 的扑咬判定一致；灰盒地图是平的，两层楼不会因为高度差被当成很远。
-- 纯逻辑：位置是普通表，不引用 Roblox 全局。

export type Vec3 = { x: number, y: number, z: number }

-- 只声明本模块用到的字段，BalanceConfig 在结构上满足它
export type Config = {
	RespawnMinDistanceFromHuman: number,
	RespawnMinDistanceFromExtraction: number,
}

local RespawnPicker = {}

local Reason = table.freeze({
	QUALIFIED = "QUALIFIED",
	FALLBACK = "FALLBACK",
	NO_ZONES = "NO_ZONES",
})
RespawnPicker.Reason = Reason

local function horizontalDistance(a: Vec3, b: Vec3): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

-- 与最近人类的水平距离；没有人类时视为无穷远（任何感染区都可以复活）。
local function nearestHumanDistance(zone: Vec3, humans: { Vec3 }): number
	local best = math.huge
	for _, human in humans do
		local distance = horizontalDistance(zone, human)
		if distance < best then
			best = distance
		end
	end
	return best
end

-- 返回 (感染区下标, 原因码)。zones 为空时返回 (nil, "NO_ZONES")。
-- extractionActive 为 true 且给了撤离区坐标时，额外要求距撤离区 ≥ RespawnMinDistanceFromExtraction；
-- 撤离尚未开启时，撤离区只是普通地图位置，不参与筛选（§9A.3“撤离期不在撤离区附近复活”）。
function RespawnPicker.pick(
	config: Config,
	zones: { Vec3 },
	humans: { Vec3 },
	extraction: Vec3?,
	extractionActive: boolean
): (number?, string)
	if #zones == 0 then
		return nil, Reason.NO_ZONES
	end

	local bestQualifiedIndex: number? = nil
	local bestQualifiedDistance = -math.huge
	local bestFallbackIndex: number? = nil
	local bestFallbackDistance = -math.huge

	for index, zone in zones do
		local humanDistance = nearestHumanDistance(zone, humans)

		-- 平手时保留下标更小的感染区，保证结果确定。
		if humanDistance > bestFallbackDistance then
			bestFallbackDistance = humanDistance
			bestFallbackIndex = index
		end

		local qualifies = humanDistance >= config.RespawnMinDistanceFromHuman
		if qualifies and extractionActive and extraction ~= nil then
			qualifies = horizontalDistance(zone, extraction) >= config.RespawnMinDistanceFromExtraction
		end
		if qualifies and humanDistance > bestQualifiedDistance then
			bestQualifiedDistance = humanDistance
			bestQualifiedIndex = index
		end
	end

	if bestQualifiedIndex ~= nil then
		return bestQualifiedIndex, Reason.QUALIFIED
	end
	return bestFallbackIndex, Reason.FALLBACK
end

return table.freeze(RespawnPicker)
