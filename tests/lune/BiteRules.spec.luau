--!strict
-- BiteRules 的前摇、提交窗口、回溯判定、锥角、遮挡与冷却测试（GDB V1.1 §9.2、§9.5）。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local PositionHistory = require("../../src/server/logic/PositionHistory")
local BiteRules = require("../../src/server/logic/BiteRules")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

local Reason = BiteRules.Reason
local Greybox = BalanceConfig.Greybox
local Windup = BalanceConfig.BiteWindupSeconds
local LatestCommit = BalanceConfig.BiteWindupSeconds + Greybox.LungeSeconds + Greybox.BiteCommitSlackSeconds

local NOW = 10
local ORIGIN = { x = 0, y = 0, z = 0 }
local FACING_X = { x = 1, y = 0, z = 0 }

local function makeAttacker(
	state: BiteRules.PlayerState,
	windupStartedAt: number?,
	consumed: boolean?
): BiteRules.AttackerRecord
	return {
		state = state,
		biteCooldownUntil = nil,
		windupStartedAt = windupStartedAt,
		windupConsumed = consumed or false,
	}
end

local function windingAttacker(now: number): BiteRules.AttackerRecord
	local attacker = makeAttacker("INFECTED")
	local ok, reason = BiteRules.startBite(BalanceConfig, attacker, now - Windup)
	assert(ok, reason)
	return attacker
end

local function target(overrides: any?): BiteRules.TargetRecord
	local options = overrides or {}
	return {
		id = options.id or "target",
		state = options.state or "HUMAN",
		curedImmuneUntil = options.curedImmuneUntil,
	}
end

local function historyFrom(samples: { { t: number, pos: BiteRules.Vec3 } }): PositionHistory.History
	local history = PositionHistory.new(BalanceConfig)
	for _, sample in samples do
		PositionHistory.record(history, sample.t, sample.pos)
	end
	return history
end

-- 服务端会这样把 PositionHistory 注入 BiteRules；测试用真实 History 以覆盖插值。
local function samplerFrom(history: PositionHistory.History): (t: number) -> BiteRules.Vec3?
	return function(t: number): BiteRules.Vec3?
		return PositionHistory.sampleAt(history, t)
	end
end

local function stillSampler(t: number, position: BiteRules.Vec3): (t: number) -> BiteRules.Vec3?
	return samplerFrom(historyFrom({ { t = t, pos = position } }))
end

local function commitWith(
	attacker: BiteRules.AttackerRecord,
	targetRecord: BiteRules.TargetRecord,
	sampleTarget: (t: number) -> BiteRules.Vec3?,
	options: any?
): BiteRules.CommitResult
	local opts = options or {}
	local now = if opts.now ~= nil then opts.now else NOW
	return BiteRules.commitBite(
		BalanceConfig,
		{
			attacker = attacker,
			attackerPos = opts.attackerPos or ORIGIN,
			attackerFacing = opts.attackerFacing or FACING_X,
			now = now,
			attackerPingSeconds = if opts.ping ~= nil then opts.ping else 0,
			target = targetRecord,
			sampleTarget = sampleTarget,
			losBlocked = opts.losBlocked == true,
		} :: BiteRules.CommitInput
	)
end

local function validCommit(
	attacker: BiteRules.AttackerRecord,
	position: BiteRules.Vec3,
	options: any?
): BiteRules.CommitResult
	return commitWith(attacker, target(), stillSampler(NOW, position), options)
end

describe("startBite", function()
	it("只有 INFECTED 能开始前摇", function()
		local states: { BiteRules.PlayerState } = { "HUMAN", "INCUBATING", "UNSTABLE", "EXTRACTED", "SPECTATOR" }
		for _, state in states do
			local ok, reason = BiteRules.startBite(BalanceConfig, makeAttacker(state), NOW)
			expect(ok).toBe(false)
			expect(reason).toBe(Reason.NOT_INFECTED)
		end
	end)

	it("INFECTED 开始前摇并返回 STARTED", function()
		local attacker = makeAttacker("INFECTED")
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STARTED)
		expect(attacker.windupStartedAt).toBe(NOW)
		expect(attacker.windupConsumed).toBe(false)
	end)

	it("冷却中拒绝，冷却边界可以重新开始", function()
		local attacker = makeAttacker("INFECTED")
		attacker.biteCooldownUntil = NOW + 1
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.COOLDOWN)

		ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW + 1)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STARTED)
	end)

	it("已有未提交的前摇时拒绝", function()
		local attacker = makeAttacker("INFECTED", NOW - 0.1, false)
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.WINDUP_ACTIVE)
	end)

	it("窗口结束前新的 StartBite 仍返回 WINDUP_ACTIVE", function()
		local attacker = makeAttacker("INFECTED", NOW - LatestCommit + 0.01, false)
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.WINDUP_ACTIVE)
	end)

	it("被放弃的前摇触发按窗口结束时刻计算的冷却", function()
		local startedAt = NOW - LatestCommit - 0.01
		local attacker = makeAttacker("INFECTED", startedAt, false)
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.COOLDOWN)
		expect(attacker.biteCooldownUntil).toBe(startedAt + LatestCommit + BalanceConfig.BiteCooldownSeconds)
		expect(attacker.windupStartedAt).toBeNil()
		expect(attacker.windupConsumed).toBe(true)
	end)

	it("被放弃的前摇过期且冷却结束后允许新的前摇", function()
		local startedAt = NOW - LatestCommit - BalanceConfig.BiteCooldownSeconds - 0.01
		local attacker = makeAttacker("INFECTED", startedAt, false)
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STARTED)
		expect(attacker.windupStartedAt).toBe(NOW)
		expect(attacker.windupConsumed).toBe(false)
	end)

	it("上一次前摇已提交后可以开始新前摇", function()
		local attacker = makeAttacker("INFECTED", NOW - 5, true)
		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STARTED)
		expect(attacker.windupStartedAt).toBe(NOW)
		expect(attacker.windupConsumed).toBe(false)
	end)
end)

describe("commitBite 校验", function()
	it("非 INFECTED 无法提交", function()
		local result = validCommit(makeAttacker("HUMAN", NOW - Windup), { x = 4, y = 0, z = 0 })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.NOT_INFECTED)
	end)

	it("没有前摇时拒绝", function()
		local result = validCommit(makeAttacker("INFECTED"), { x = 4, y = 0, z = 0 })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.NO_WINDUP)
	end)

	it("同一次前摇已提交后拒绝", function()
		local result = validCommit(makeAttacker("INFECTED", NOW - Windup, true), { x = 4, y = 0, z = 0 })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.ALREADY_COMMITTED)
	end)

	it("前摇尚未结束返回 TOO_EARLY", function()
		local attacker = makeAttacker("INFECTED", NOW - Windup + 0.05, false)
		local result = validCommit(attacker, { x = 4, y = 0, z = 0 })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.TOO_EARLY)
	end)

	it("超过前摇 + 扑击 + 宽限窗口返回 TOO_LATE", function()
		local attacker = makeAttacker("INFECTED", NOW - LatestCommit - 0.01, false)
		local result = validCommit(attacker, { x = 4, y = 0, z = 0 })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.TOO_LATE)
	end)

	it("窗口两端边界均可提交", function()
		local earliest = validCommit(makeAttacker("INFECTED", NOW - Windup, false), { x = 4, y = 0, z = 0 })
		expect(earliest.reason).toBe(Reason.HIT)
		local latest = validCommit(makeAttacker("INFECTED", NOW - LatestCommit, false), { x = 4, y = 0, z = 0 })
		expect(latest.reason).toBe(Reason.HIT)
	end)

	it("校验失败的提交不写冷却、不消耗前摇", function()
		local attacker = makeAttacker("INFECTED", NOW - Windup + 0.05, false)
		validCommit(attacker, { x = 4, y = 0, z = 0 })
		expect(attacker.biteCooldownUntil).toBeNil()
		expect(attacker.windupConsumed).toBe(false)
	end)
end)

describe("commitBite 几何判定", function()
	it("范围内、朝向内且无遮挡时命中", function()
		local attacker = windingAttacker(NOW)
		local result = validCommit(attacker, { x = 4, y = 0, z = 0 })
		expect(result.hit).toBe(true)
		expect(result.reason).toBe(Reason.HIT)
		expect(result.distance).toBe(4)
		expect(result.nearMiss).toBe(false)
		expect(attacker.windupConsumed).toBe(true)
		expect(attacker.biteCooldownUntil).toBe(NOW + BalanceConfig.BiteCooldownSeconds)
		expect(result.recoverUntil).toBeNil()
	end)

	it("超出 BiteRange + BiteTolerance 返回 OUT_OF_RANGE 并标记近失", function()
		local result =
			validCommit(windingAttacker(NOW), { x = Greybox.BiteRange + Greybox.BiteTolerance + 0.1, y = 0, z = 0 })
		expect(result.reason).toBe(Reason.OUT_OF_RANGE)
		expect(result.nearMiss).toBe(true)
	end)

	it("距离远于 BiteRange + 2 × BiteTolerance 时不算近失", function()
		local far = Greybox.BiteRange + 2 * Greybox.BiteTolerance + 0.1
		local result = validCommit(windingAttacker(NOW), { x = far, y = 0, z = 0 })
		expect(result.reason).toBe(Reason.OUT_OF_RANGE)
		expect(result.nearMiss).toBe(false)
	end)

	it("锥角边界内命中、边界外返回 OUT_OF_CONE", function()
		local insideAngle = math.rad(Greybox.BiteConeDegrees - 0.01)
		local inside = {
			x = 4 * math.cos(insideAngle),
			y = 0,
			z = 4 * math.sin(insideAngle),
		}
		expect(validCommit(windingAttacker(NOW), inside).reason).toBe(Reason.HIT)

		local outsideAngle = math.rad(Greybox.BiteConeDegrees + 0.01)
		local outside = {
			x = 4 * math.cos(outsideAngle),
			y = 0,
			z = 4 * math.sin(outsideAngle),
		}
		local result = validCommit(windingAttacker(NOW), outside)
		expect(result.reason).toBe(Reason.OUT_OF_CONE)
		expect(result.nearMiss).toBe(true)
	end)

	it("射线被静态遮挡时返回 BLOCKED", function()
		local result = validCommit(windingAttacker(NOW), { x = 4, y = 0, z = 0 }, { losBlocked = true })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.BLOCKED)
		expect(result.nearMiss).toBe(true)
	end)

	it("非 HUMAN 目标不能作为新感染目标", function()
		local states: { BiteRules.PlayerState } = { "INCUBATING", "INFECTED", "UNSTABLE", "EXTRACTED", "SPECTATOR" }
		for _, state in states do
			local result =
				commitWith(windingAttacker(NOW), target({ state = state }), stillSampler(NOW, { x = 4, y = 0, z = 0 }))
			expect(result.reason).toBe(Reason.TARGET_INELIGIBLE)
			expect(result.nearMiss).toBe(false)
		end
	end)

	it("治愈保护期内的 HUMAN 不可再次感染，保护到期后可命中", function()
		local immune = commitWith(
			windingAttacker(NOW),
			target({ curedImmuneUntil = NOW + 1 }),
			stillSampler(NOW, { x = 4, y = 0, z = 0 })
		)
		expect(immune.reason).toBe(Reason.TARGET_INELIGIBLE)
		expect(immune.nearMiss).toBe(false)

		local expired = commitWith(
			windingAttacker(NOW),
			target({ curedImmuneUntil = NOW }),
			stillSampler(NOW, { x = 4, y = 0, z = 0 })
		)
		expect(expired.reason).toBe(Reason.HIT)
	end)

	it("采样器返回 nil 时按未命中处理并进入冷却", function()
		local attacker = windingAttacker(NOW)
		local result = commitWith(attacker, target(), samplerFrom(PositionHistory.new(BalanceConfig)))
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.OUT_OF_RANGE)
		expect(result.distance).toBeNil()
		expect(result.nearMiss).toBe(false)
		expect(attacker.biteCooldownUntil).toBe(NOW + BalanceConfig.BiteCooldownSeconds)
	end)
end)

describe("延迟补偿回溯", function()
	it("回溯位置命中而当前位置会脱靶", function()
		local history = historyFrom({
			{ t = NOW - 0.5, pos = { x = 4, y = 0, z = 0 } },
			{ t = NOW, pos = { x = 8, y = 0, z = 0 } },
		})

		local sampleTarget = samplerFrom(history)
		local rewound = commitWith(windingAttacker(NOW), target(), sampleTarget, { ping = Greybox.MaxRewindSeconds })
		expect(rewound.hit).toBe(true)
		expect(rewound.reason).toBe(Reason.HIT)
		expect(rewound.distance).toBe(6)

		local current = commitWith(windingAttacker(NOW), target(), sampleTarget, { ping = 0 })
		expect(current.reason).toBe(Reason.OUT_OF_RANGE)
	end)

	it("回溯时间夹取到 MaxRewindSeconds", function()
		local history = historyFrom({
			{ t = NOW - 0.5, pos = { x = 4, y = 0, z = 0 } },
			{ t = NOW, pos = { x = 8, y = 0, z = 0 } },
		})
		local clamped = commitWith(windingAttacker(NOW), target(), samplerFrom(history), { ping = 10 })
		expect(clamped.hit).toBe(true)
		expect(clamped.distance).toBe(6)
	end)

	it("负延迟夹取到 0，使用当前位置", function()
		local history = historyFrom({
			{ t = NOW - 0.5, pos = { x = 4, y = 0, z = 0 } },
			{ t = NOW, pos = { x = 8, y = 0, z = 0 } },
		})
		local result = commitWith(windingAttacker(NOW), target(), samplerFrom(history), { ping = -3 })
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.OUT_OF_RANGE)
	end)
end)

describe("一次前摇只提交一次与冷却", function()
	it("提交后再次提交返回 ALREADY_COMMITTED，冷却不被重复刷新", function()
		local attacker = windingAttacker(NOW)
		local first = validCommit(attacker, { x = 4, y = 0, z = 0 })
		expect(first.reason).toBe(Reason.HIT)
		local cooldownUntil = attacker.biteCooldownUntil

		local second = validCommit(attacker, { x = 4, y = 0, z = 0 })
		expect(second.reason).toBe(Reason.ALREADY_COMMITTED)
		expect(attacker.biteCooldownUntil).toBe(cooldownUntil)
	end)

	it("未命中同样进入冷却并返回后摇时间", function()
		local attacker = windingAttacker(NOW)
		local result = validCommit(attacker, { x = 20, y = 0, z = 0 })
		expect(result.hit).toBe(false)
		expect(result.recoverUntil).toBe(NOW + Greybox.BiteMissRecoverySeconds)
		expect(attacker.biteCooldownUntil).toBe(NOW + BalanceConfig.BiteCooldownSeconds)
	end)

	it("冷却期间无法开始新前摇，冷却结束后可以", function()
		local attacker = windingAttacker(NOW)
		validCommit(attacker, { x = 4, y = 0, z = 0 })

		local ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW + 0.1)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.COOLDOWN)

		ok, reason = BiteRules.startBite(BalanceConfig, attacker, NOW + BalanceConfig.BiteCooldownSeconds)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STARTED)
	end)
end)

TestKit.finish()
