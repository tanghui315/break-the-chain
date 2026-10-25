--!strict
-- Gate A-2a 胜负判定纯逻辑（GDB V1.1 §5.1、§11.1、§13.3、§19.3、§23.1）。
--
-- 每 tick 只回答一个问题：本局是否已经产生唯一胜方。裁决顺序固定，绝不平局：
--   1. 累计成功撤离人数 ≥ 本局阈值 → 人类胜。撤离先于超时判定，
--      因此同一服务器 tick 内“最后一人撤离”与“倒计时归零”同时发生时为人类胜（§13.3 注）。
--   2. 感染被完全遏制（无 INCUBATING / INFECTED / UNSTABLE）且仍有存活人类，
--      且该状态已连续保持 ContainmentStableSeconds → 人类胜（§13.3 条件 2 的“短暂稳定性复核”）。
--      零号不可治愈，所以这一条实际只在零号全部离场后触发，是边界兜底条件。
--   3. 没有任何 HUMAN / INCUBATING / UNSTABLE → 丧尸胜（§13.3 丧尸条件 1）。
--      防提前判输：只要仍有人处于尸变过渡或断联，就绝不判负，等这些状态结算完再判。
--   4. 倒计时归零且撤离阈值未达成 → 丧尸胜（§13.3 丧尸条件 2）。
--
-- 遏制计时器由调用方持有：input.containedSince 传入上一 tick 的值，
-- 返回值的 containedSince 是下一次应保存的值（条件中断时自动清空）。
-- 纯逻辑：无 Roblox 全局对象，配置与 now 由调用方传入，可在 Lune 中直接测试。

export type Config = {
	ContainmentStableSeconds: number,
}

export type Input = {
	humans: number,
	incubating: number,
	infected: number,
	unstable: number,
	extracted: number,
	requiredExtracted: number,
	timeUp: boolean,
	containedSince: number?,
}

export type Winner = "HUMANS" | "INFECTED"

export type Verdict = {
	winner: Winner?,
	reason: string?,
	containedSince: number?,
}

local WinEvaluator = {}

local WINNER_HUMANS: Winner = "HUMANS"
local WINNER_INFECTED: Winner = "INFECTED"

local Winner = table.freeze({
	HUMANS = WINNER_HUMANS,
	INFECTED = WINNER_INFECTED,
})
WinEvaluator.Winner = Winner

-- 判定原因码：RoundResult 直接携带，测试不应依赖文案。
local Reason = table.freeze({
	ExtractionThreshold = "EXTRACTION_THRESHOLD",
	Containment = "CONTAINMENT",
	NoHumans = "NO_HUMANS",
	Timeout = "TIMEOUT",
	-- 由 RoundStateMachine 在 §6.1 零号补选失败时直接判定，不由本模块产生。
	OutbreakFailed = "OUTBREAK_FAILED",
})
WinEvaluator.Reason = Reason

local function count(value: number): number
	if value ~= value or value < 0 then
		return 0
	end
	return math.floor(value)
end

-- 判定当前状态。now 是服务器时间；containedSince 是遏制条件首次成立的时刻。
function WinEvaluator.evaluate(config: Config, input: Input, now: number): Verdict
	local humans = count(input.humans)
	local incubating = count(input.incubating)
	local infected = count(input.infected)
	local unstable = count(input.unstable)
	local extracted = count(input.extracted)
	local required = count(input.requiredExtracted)

	-- 1. 撤离阈值：同 tick 与超时竞争时人类优先（§13.3 注）。
	if extracted >= required then
		return { winner = WINNER_HUMANS, reason = Reason.ExtractionThreshold, containedSince = nil }
	end

	-- 2. 遏制：感染侧全部消失且仍有存活人类，需要连续稳定窗口。
	local containedSince: number? = nil
	if humans > 0 and incubating == 0 and infected == 0 and unstable == 0 then
		local since: number = if input.containedSince ~= nil then input.containedSince else now
		containedSince = since
		if now - since >= config.ContainmentStableSeconds then
			return { winner = WINNER_HUMANS, reason = Reason.Containment, containedSince = containedSince }
		end
	end

	-- 3. 防提前判输：只有 HUMANS / INCUBATING / UNSTABLE 全部为 0 才判丧尸胜。
	if humans == 0 and incubating == 0 and unstable == 0 then
		return { winner = WINNER_INFECTED, reason = Reason.NoHumans, containedSince = containedSince }
	end

	-- 4. 倒计时归零。
	if input.timeUp then
		return { winner = WINNER_INFECTED, reason = Reason.Timeout, containedSince = containedSince }
	end

	return { winner = nil, reason = nil, containedSince = containedSince }
end

return table.freeze(WinEvaluator)
