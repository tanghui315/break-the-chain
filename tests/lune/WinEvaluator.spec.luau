--!strict
-- WinEvaluator 规则测试（GDB V1.1 §13.3）：撤离优先于超时、防提前判输、遏制稳定窗口、绝不平局。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local WinEvaluator = require("../../src/server/logic/WinEvaluator")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = WinEvaluator.Reason
local Winner = WinEvaluator.Winner

local config = { ContainmentStableSeconds = BalanceConfig.ContainmentStableSeconds }

local function input(overrides: { [string]: any }?): WinEvaluator.Input
	local value = {
		humans = 5,
		incubating = 0,
		infected = 1,
		unstable = 0,
		extracted = 0,
		requiredExtracted = 2,
		timeUp = false,
		containedSince = nil,
	}
	if overrides ~= nil then
		for key, override in overrides do
			value[key] = override
		end
	end
	return value
end

describe("WinEvaluator", function()
	it("keeps the round running while humans and infection both remain", function()
		local verdict = WinEvaluator.evaluate(config, input(), 10)
		expect(verdict.winner).toBeNil()
		expect(verdict.reason).toBeNil()
	end)

	it("humans win on the extraction threshold even on the timeout tick", function()
		local verdict = WinEvaluator.evaluate(
			config,
			input({
				extracted = 2,
				requiredExtracted = 2,
				timeUp = true,
			}),
			100
		)
		expect(verdict.winner).toBe(Winner.HUMANS)
		expect(verdict.reason).toBe(Reason.ExtractionThreshold)
	end)

	it("infected win when time is up and the extraction threshold was missed", function()
		local verdict = WinEvaluator.evaluate(config, input({ extracted = 1, timeUp = true }), 100)
		expect(verdict.winner).toBe(Winner.INFECTED)
		expect(verdict.reason).toBe(Reason.Timeout)
	end)

	it("does not declare infected while an INCUBATING player is still pending (anti-early-loss)", function()
		local pending = WinEvaluator.evaluate(
			config,
			input({
				humans = 0,
				incubating = 1,
				infected = 2,
				unstable = 1,
			}),
			10
		)
		expect(pending.winner).toBeNil()

		local stillPending = WinEvaluator.evaluate(
			config,
			input({
				humans = 0,
				incubating = 0,
				infected = 3,
				unstable = 1,
			}),
			10
		)
		expect(stillPending.winner).toBeNil()

		local resolved = WinEvaluator.evaluate(
			config,
			input({
				humans = 0,
				incubating = 0,
				infected = 3,
				unstable = 0,
			}),
			10
		)
		expect(resolved.winner).toBe(Winner.INFECTED)
		expect(resolved.reason).toBe(Reason.NoHumans)
	end)

	it("does not declare infected while an UNSTABLE player may still recover", function()
		local pending = WinEvaluator.evaluate(
			config,
			input({
				humans = 0,
				incubating = 0,
				infected = 2,
				unstable = 1,
			}),
			10
		)
		expect(pending.winner).toBeNil()

		local recovered = WinEvaluator.evaluate(
			config,
			input({
				humans = 1,
				incubating = 0,
				infected = 2,
				unstable = 0,
			}),
			11
		)
		expect(recovered.winner).toBeNil()
	end)

	it("containment needs the full stability window", function()
		local started = WinEvaluator.evaluate(
			config,
			input({
				humans = 3,
				incubating = 0,
				infected = 0,
				unstable = 0,
			}),
			10
		)
		expect(started.winner).toBeNil()
		expect(started.containedSince).toBe(10)

		local early = WinEvaluator.evaluate(
			config,
			input({
				humans = 3,
				incubating = 0,
				infected = 0,
				unstable = 0,
				containedSince = started.containedSince,
			}),
			10 + BalanceConfig.ContainmentStableSeconds - 0.01
		)
		expect(early.winner).toBeNil()

		local stable = WinEvaluator.evaluate(
			config,
			input({
				humans = 3,
				incubating = 0,
				infected = 0,
				unstable = 0,
				containedSince = started.containedSince,
			}),
			10 + BalanceConfig.ContainmentStableSeconds
		)
		expect(stable.winner).toBe(Winner.HUMANS)
		expect(stable.reason).toBe(Reason.Containment)
	end)

	it("containment resets if infection reappears", function()
		local started = WinEvaluator.evaluate(
			config,
			input({
				humans = 3,
				infected = 0,
				containedSince = nil,
			}),
			10
		)
		expect(started.containedSince).toBe(10)

		local broken = WinEvaluator.evaluate(
			config,
			input({
				humans = 3,
				incubating = 1,
				infected = 0,
				containedSince = started.containedSince,
			}),
			11
		)
		expect(broken.winner).toBeNil()
		expect(broken.containedSince).toBeNil()

		local restarted = WinEvaluator.evaluate(
			config,
			input({
				humans = 3,
				infected = 0,
				containedSince = broken.containedSince,
			}),
			20
		)
		expect(restarted.containedSince).toBe(20)
	end)

	it("containment that already held through the timeout still favours humans", function()
		local verdict = WinEvaluator.evaluate(
			config,
			input({
				humans = 2,
				incubating = 0,
				infected = 0,
				unstable = 0,
				containedSince = 0,
				timeUp = true,
			}),
			5
		)
		expect(verdict.winner).toBe(Winner.HUMANS)
		expect(verdict.reason).toBe(Reason.Containment)
	end)

	it("containment needs at least one living human", function()
		local verdict = WinEvaluator.evaluate(
			config,
			input({
				humans = 0,
				incubating = 0,
				infected = 0,
				unstable = 0,
				extracted = 0,
				requiredExtracted = 2,
			}),
			10
		)
		expect(verdict.winner).toBe(Winner.INFECTED)
		expect(verdict.reason).toBe(Reason.NoHumans)
	end)

	it("never produces a draw", function()
		local cases = {
			{ humans = 4, infected = 1 },
			{ humans = 0, incubating = 1 },
			{ humans = 0, unstable = 1 },
			{ humans = 3, incubating = 0, infected = 0, unstable = 0, containedSince = 0, timeUp = true },
			{ humans = 0, infected = 4, timeUp = true },
		}
		for _, overrides in cases do
			local verdict = WinEvaluator.evaluate(config, input(overrides), 100)
			if verdict.winner ~= nil then
				expect(verdict.winner == Winner.HUMANS or verdict.winner == Winner.INFECTED).toBe(true)
			end
		end
		local timeout = WinEvaluator.evaluate(config, input({ timeUp = true }), 100)
		expect(timeout.winner).toBe(Winner.INFECTED)
	end)

	it("exposes the new balance keys with the agreed baseline values", function()
		expect(BalanceConfig.ContainmentStableSeconds).toBe(5)
		expect(BalanceConfig.CureRetryCooldownSeconds).toBe(1.5)
	end)
end)

TestKit.finish()
