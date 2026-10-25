--!strict
-- 交互目标选择（GDB V1.1 §10.2、§11.2、§17.3、§20.4）：纯逻辑，服务端与客户端共用。
--
-- 客户端只用它把“离我最近、可以交互的公开目标”选出来，然后发送 targetId 意图；
-- 服务端永远重新校验状态、距离与持有道具（RoundStateMachine / hooks），从不相信客户端选中的结果。
-- 零号（isRoot）的处理：普通解药无效（§10.2），当最近目标是零号时返回 rootBlocked，
-- 客户端据此提示“SOURCE — cure has no effect”，不浪费唯一解药。
--
-- 纯模块：只处理普通表，不引用 Roblox 全局对象，可在 Lune 中测试。

export type Candidate = {
	id: string,
	x: number,
	z: number,
	-- 调用方已完成状态筛选（例如 INFECTED + 战斗状态允许）
	eligible: boolean,
	-- 零号源头：解药无效，但仍可作为重连目标
	isRoot: boolean,
}

export type Origin = {
	x: number,
	z: number,
}

export type Selection = {
	id: string?,
	distance: number?,
	-- 最近的可交互目标是零号且调用方不接受零号：客户端应提示 SOURCE，而不是发送请求。
	rootBlocked: boolean,
}

local InteractTarget = {}

local NONE: Selection = table.freeze({ id = nil, distance = nil, rootBlocked = false })

-- 在水平面上选取范围内最近的目标。范围 ≤ 0 或没有候选时返回空选择。
-- acceptRoot 为 false 时，最近目标是零号会返回 rootBlocked 且不返回 id（避免误注射到零号）。
function InteractTarget.selectNearest(
	candidates: { Candidate },
	origin: Origin,
	range: number,
	acceptRoot: boolean
): Selection
	if range <= 0 or range ~= range then
		return NONE
	end

	local best: Candidate? = nil
	local bestDistance = math.huge
	for _, candidate in candidates do
		if candidate.eligible then
			local dx = candidate.x - origin.x
			local dz = candidate.z - origin.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance <= range and distance < bestDistance then
				best = candidate
				bestDistance = distance
			end
		end
	end

	if best == nil then
		return NONE
	end
	if best.isRoot and not acceptRoot then
		return { id = nil, distance = bestDistance, rootBlocked = true }
	end
	return { id = best.id, distance = bestDistance, rootBlocked = false }
end

return table.freeze(InteractTarget)
