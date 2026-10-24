--!strict
-- 开局补给分配与弹药箱刷新（GDB V1.1 §9A.5、§9A.9）。
-- 给定人数档与固定补给点列表，用注入的 RNG 把 pistols / tasers / ammoCrates 分配到互不重复的补给点。
-- 分配顺序固定为 手枪 → 电击枪 → 弹药箱；点位数不足时按这个顺序优先保证前者，剩余的记入 shortfall。
-- 弹药箱被取用后 AmmoCrateRefreshSeconds 在同一位置刷新（§9A.5）。
-- 纯逻辑：不引用 Roblox 全局，RNG 由调用方注入（返回 1..n 的整数），保证可重放。

export type Tier = {
	pistols: number,
	tasers: number,
	ammoCrates: number,
}

-- 只声明本模块用到的字段，BalanceConfig 在结构上满足它
export type Config = {
	AmmoCrateRefreshSeconds: number,
}

-- 注入的随机数发生器：给定 n，返回 1..n 的整数；非法返回值会被夹取。
export type Rng = (count: number) -> number

export type Shortfall = {
	pistols: number,
	tasers: number,
	ammoCrates: number,
}

export type Plan = {
	-- 每一项是补给点列表的 1-based 下标，三类之间互不重复。
	pistols: { number },
	tasers: { number },
	ammoCrates: { number },
	shortfall: Shortfall,
}

export type Crate = {
	pointIndex: number,
	available: boolean,
	readyAt: number?,
}

export type CrateState = {
	config: Config,
	crates: { Crate },
}

local SupplyPlan = {}

local function wanted(count: number): number
	if count ~= count or count < 0 then
		return 0
	end
	return math.floor(count)
end

-- Fisher–Yates；每个槽位消耗一次 RNG，同样的 RNG 序列得到同样的分配。
local function shuffledIndices(count: number, rng: Rng): { number }
	local indices: { number } = {}
	for index = 1, count do
		indices[index] = index
	end
	for index = count, 2, -1 do
		local pick = rng(index)
		if type(pick) ~= "number" or pick ~= pick or pick % 1 ~= 0 or pick < 1 or pick > index then
			pick = index
		end
		indices[index], indices[pick] = indices[pick], indices[index]
	end
	return indices
end

-- 分配补给。points 只使用数量（#points），元素内容由调用方映射（地图点位、交互对象等）。
function SupplyPlan.plan(tier: Tier, points: { unknown }, rng: Rng): Plan
	local indices = shuffledIndices(#points, rng)
	local cursor = 1

	local function take(count: number): { number }
		local assigned: { number } = {}
		for _ = 1, count do
			if cursor > #indices then
				break
			end
			table.insert(assigned, indices[cursor])
			cursor += 1
		end
		return assigned
	end

	local pistolCount = wanted(tier.pistols)
	local taserCount = wanted(tier.tasers)
	local crateCount = wanted(tier.ammoCrates)

	local pistols = take(pistolCount)
	local tasers = take(taserCount)
	local ammoCrates = take(crateCount)

	return {
		pistols = pistols,
		tasers = tasers,
		ammoCrates = ammoCrates,
		shortfall = {
			pistols = pistolCount - #pistols,
			tasers = taserCount - #tasers,
			ammoCrates = crateCount - #ammoCrates,
		},
	}
end

-- 回合开始时建立弹药箱运行时状态；crate 下标与 plan.ammoCrates 一致。
function SupplyPlan.newCrates(config: Config, plan: Plan): CrateState
	local crates: { Crate } = {}
	for _, pointIndex in plan.ammoCrates do
		table.insert(crates, { pointIndex = pointIndex, available = true, readyAt = nil })
	end
	return { config = config, crates = crates }
end

function SupplyPlan.isCrateAvailable(state: CrateState, index: number): boolean
	local crate = state.crates[index]
	return crate ~= nil and crate.available
end

-- 取用弹药箱：成功则立即不可用，并在 now + AmmoCrateRefreshSeconds 刷新；重复取用或下标非法返回 false。
function SupplyPlan.takeCrate(state: CrateState, index: number, now: number): boolean
	local crate = state.crates[index]
	if crate == nil or not crate.available then
		return false
	end
	crate.available = false
	crate.readyAt = now + state.config.AmmoCrateRefreshSeconds
	return true
end

-- 推进刷新，返回本次刷新的弹药箱下标（升序）。
function SupplyPlan.tickCrates(state: CrateState, now: number): { number }
	local refreshed: { number } = {}
	for index, crate in state.crates do
		if not crate.available and crate.readyAt ~= nil and now >= crate.readyAt then
			crate.available = true
			crate.readyAt = nil
			table.insert(refreshed, index)
		end
	end
	table.sort(refreshed)
	return refreshed
end

return table.freeze(SupplyPlan)
