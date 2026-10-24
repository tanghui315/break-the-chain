--!strict
-- 位置历史环形缓冲（GDB V1.1 §9.5）：每个参与者 1 秒 @ 20 Hz，供延迟补偿回溯采样。
-- 纯逻辑：时间由参数传入，位置是普通表；不引用任何 Roblox 全局。

export type Vec3 = { x: number, y: number, z: number }

-- 只声明本模块用到的字段，BalanceConfig 在结构上满足它
export type Config = {
	Greybox: {
		HistorySeconds: number,
		HistoryHz: number,
	},
}

export type History = {
	capacity: number,
	windowSeconds: number,
	times: { number },
	positions: { Vec3 },
	head: number,
	count: number,
}

local PositionHistory = {}

-- 窗口外多留几个槽位，避免采样点落在窗口边缘时缺少插值邻居。
local CAPACITY_MARGIN = 4

-- 调用方须按时间单调递增地调用 record；环形缓冲按逻辑顺序 times[head .. head + count - 1] 排列。
local function physicalIndex(h: History, logical: number): number
	return ((h.head - 1 + logical - 1) % h.capacity) + 1
end

function PositionHistory.new(config: Config): History
	local capacity = math.max(2, math.ceil(config.Greybox.HistorySeconds * config.Greybox.HistoryHz) + CAPACITY_MARGIN)
	return {
		capacity = capacity,
		windowSeconds = config.Greybox.HistorySeconds,
		times = {},
		positions = {},
		head = 1,
		count = 0,
	}
end

-- 记录一个采样点，并丢弃窗口（HistorySeconds）之外的旧样本。
function PositionHistory.record(h: History, now: number, pos: Vec3)
	local cutoff = now - h.windowSeconds
	while h.count > 0 do
		local oldest = h.times[h.head]
		if oldest < cutoff then
			h.head = (h.head % h.capacity) + 1
			h.count -= 1
		else
			break
		end
	end

	local index: number
	if h.count < h.capacity then
		index = physicalIndex(h, h.count + 1)
		h.count += 1
	else
		-- 缓冲已满：覆盖最旧样本，队头后移。
		index = h.head
		h.head = (h.head % h.capacity) + 1
	end
	h.times[index] = now
	h.positions[index] = pos
end

-- 取 t 时刻的插值位置。早于最旧样本或晚于最新样本时夹取边界；缓冲为空时返回 nil。
function PositionHistory.sampleAt(h: History, t: number): Vec3?
	if h.count == 0 then
		return nil
	end

	local oldestTime = h.times[h.head]
	if t <= oldestTime then
		return h.positions[h.head]
	end

	local newestIndex = physicalIndex(h, h.count)
	local newestTime = h.times[newestIndex]
	if t >= newestTime then
		return h.positions[newestIndex]
	end

	for logical = 1, h.count - 1 do
		local i = physicalIndex(h, logical)
		local j = physicalIndex(h, logical + 1)
		local t0 = h.times[i]
		local t1 = h.times[j]
		if t >= t0 and t <= t1 then
			if t1 <= t0 then
				return h.positions[j]
			end
			local alpha = (t - t0) / (t1 - t0)
			local a = h.positions[i]
			local b = h.positions[j]
			return {
				x = a.x + (b.x - a.x) * alpha,
				y = a.y + (b.y - a.y) * alpha,
				z = a.z + (b.z - a.z) * alpha,
			}
		end
	end

	return h.positions[newestIndex]
end

return table.freeze(PositionHistory)
