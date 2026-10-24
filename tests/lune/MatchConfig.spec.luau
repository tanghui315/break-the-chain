--!strict
-- MatchConfig 的人数规则测试，对应 GDB V1.1 §23.2 的 R-01～R-05、R-13，以及 D3、D5。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local MatchConfig = require("../../src/server/logic/MatchConfig")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local function planFor(realCount: number, forceBotFill: number?): MatchConfig.RoundPlan
	local plan = MatchConfig.planRound(BalanceConfig, realCount, forceBotFill)
	assert(plan, `planRound 应为 {realCount} 名真人返回开局方案`)
	return plan
end

describe("planRound", function()
	it("R-01 2 名真人：Bot 补位到 6 名参与者的练习局", function()
		local plan = planFor(2)
		expect(plan.botCount).toBe(4)
		expect(plan.participantCount).toBe(6)
		expect(plan.isPractice).toBe(true)
		expect(plan.tier.mapTier).toBe("SMALL")
	end)

	it("1 名真人也能开局", function()
		local plan = planFor(1)
		expect(plan.participantCount).toBe(BalanceConfig.BotFillTarget)
		expect(plan.isPractice).toBe(true)
	end)

	it("R-02 / R-13 4 名真人：正式局，不补 Bot，6 分钟、1 零号、1 电力点、撤离 1 人", function()
		local plan = planFor(4)
		expect(plan.botCount).toBe(0)
		expect(plan.isPractice).toBe(false)
		expect(plan.tier.roundSeconds).toBe(360)
		expect(plan.tier.seedCount).toBe(1)
		expect(plan.tier.powerRelays).toBe(1)
		expect(plan.tier.requiredExtracted).toBe(1)
	end)

	it("R-03 8 名真人：7 分钟、1 零号、2 电力点、撤离 2 人", function()
		local plan = planFor(8)
		expect(plan.tier.roundSeconds).toBe(420)
		expect(plan.tier.seedCount).toBe(1)
		expect(plan.tier.powerRelays).toBe(2)
		expect(plan.tier.requiredExtracted).toBe(2)
	end)

	it("R-04 16 名真人：8 分钟、2 零号、3 电力点、撤离 4 人", function()
		local plan = planFor(16)
		expect(plan.tier.roundSeconds).toBe(480)
		expect(plan.tier.seedCount).toBe(2)
		expect(plan.tier.powerRelays).toBe(3)
		expect(plan.tier.requiredExtracted).toBe(4)
	end)

	it("R-05 24 人是上限，第 25 人无法成为正式参与者", function()
		expect(MatchConfig.planRound(BalanceConfig, 24)).toBeTruthy()
		expect(MatchConfig.planRound(BalanceConfig, 25)).toBeNil()
	end)

	it("0 名或非整数真人数被拒绝", function()
		expect(MatchConfig.planRound(BalanceConfig, 0)).toBeNil()
		expect(MatchConfig.planRound(BalanceConfig, 2.5)).toBeNil()
	end)

	it("开发压测可强制补到 24 人，该局按练习局处理", function()
		local plan = planFor(8, 24)
		expect(plan.botCount).toBe(16)
		expect(plan.tier.mapTier).toBe("LARGE")
		expect(plan.isPractice).toBe(true)
	end)
end)

describe("lateJoinRole（D5）", function()
	local roundSeconds = 420

	it("开局 60 秒内以人类加入", function()
		expect(MatchConfig.lateJoinRole(BalanceConfig, 0, roundSeconds)).toBe("HUMAN")
		expect(MatchConfig.lateJoinRole(BalanceConfig, 59.9, roundSeconds)).toBe("HUMAN")
	end)

	it("60 秒后、撤离期之前以丧尸叶子加入", function()
		expect(MatchConfig.lateJoinRole(BalanceConfig, 60, roundSeconds)).toBe("INFECTED")
		expect(MatchConfig.lateJoinRole(BalanceConfig, 329.9, roundSeconds)).toBe("INFECTED")
	end)

	it("最后 90 秒撤离期观战", function()
		expect(MatchConfig.lateJoinRole(BalanceConfig, 330, roundSeconds)).toBe("SPECTATOR")
	end)
end)

describe("hubThreshold（D3）", function()
	it("感染者较少时下限为 3", function()
		expect(MatchConfig.hubThreshold(BalanceConfig, 0)).toBe(3)
		expect(MatchConfig.hubThreshold(BalanceConfig, 10)).toBe(3)
	end)

	it("感染者较多时按 20% 向上取整", function()
		expect(MatchConfig.hubThreshold(BalanceConfig, 16)).toBe(4)
		expect(MatchConfig.hubThreshold(BalanceConfig, 22)).toBe(5)
	end)
end)

TestKit.finish()
