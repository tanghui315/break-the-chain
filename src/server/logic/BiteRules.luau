--!strict
-- 扑咬启动、提交与延迟补偿判定（GDB V1.1 §9.2、§9.5、§7.3）。
-- 纯逻辑：位置是普通表，时间、网络延迟与射线遮挡由调用方传入；不引用任何 Roblox 全局。

export type Vec3 = { x: number, y: number, z: number }

export type PlayerState = "HUMAN" | "INCUBATING" | "INFECTED" | "UNSTABLE" | "EXTRACTED" | "SPECTATOR"

-- 只声明本模块用到的字段，BalanceConfig 在结构上满足它
export type Config = {
	BiteWindupSeconds: number,
	BiteCooldownSeconds: number,
	Greybox: {
		BiteMissRecoverySeconds: number,
		LungeSeconds: number,
		BiteCommitSlackSeconds: number,
		MaxRewindSeconds: number,
		BiteRange: number,
		BiteTolerance: number,
		BiteConeDegrees: number,
	},
}

-- 攻击者记录由服务端的 PlayerRoundState 子集提供，本模块直接改写其中的前摇与冷却字段。
export type AttackerRecord = {
	state: PlayerState,
	biteCooldownUntil: number?,
	windupStartedAt: number?,
	windupConsumed: boolean,
}

export type TargetRecord = {
	id: string,
	state: PlayerState,
	curedImmuneUntil: number?,
}

export type CommitInput = {
	attacker: AttackerRecord,
	attackerPos: Vec3,
	attackerFacing: Vec3,
	now: number,
	attackerPingSeconds: number,
	target: TargetRecord,
	-- 服务端传入 function(t) return PositionHistory.sampleAt(history, t) end；纯模块不持有历史结构。
	sampleTarget: (t: number) -> Vec3?,
	losBlocked: boolean,
}

export type CommitResult = {
	hit: boolean,
	reason: string,
	distance: number?,
	nearMiss: boolean,
	recoverUntil: number?,
}

local BiteRules = {}

-- 判定结果码。STARTED 用于前摇成功开始，WINDUP_ACTIVE 表示已有未提交的前摇。
local Reason = table.freeze({
	STARTED = "STARTED",
	NOT_INFECTED = "NOT_INFECTED",
	COOLDOWN = "COOLDOWN",
	WINDUP_ACTIVE = "WINDUP_ACTIVE",
	NO_WINDUP = "NO_WINDUP",
	ALREADY_COMMITTED = "ALREADY_COMMITTED",
	TOO_EARLY = "TOO_EARLY",
	TOO_LATE = "TOO_LATE",
	OUT_OF_RANGE = "OUT_OF_RANGE",
	OUT_OF_CONE = "OUT_OF_CONE",
	BLOCKED = "BLOCKED",
	TARGET_INELIGIBLE = "TARGET_INELIGIBLE",
	HIT = "HIT",
})
BiteRules.Reason = Reason

local EPSILON = 1e-9

local function horizontalDistance(a: Vec3, b: Vec3): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

local function horizontalDelta(from: Vec3, to: Vec3): Vec3
	return { x = to.x - from.x, y = 0, z = to.z - from.z }
end

local function angleBetweenHorizontalDegrees(a: Vec3, b: Vec3): number
	local aLength = math.sqrt(a.x * a.x + a.z * a.z)
	local bLength = math.sqrt(b.x * b.x + b.z * b.z)
	if aLength <= EPSILON or bLength <= EPSILON then
		return 180
	end
	local cosine = (a.x * b.x + a.z * b.z) / (aLength * bLength)
	cosine = math.clamp(cosine, -1, 1)
	return math.deg(math.acos(cosine))
end

-- 开始一次前摇。只有 INFECTED 能咬；冷却中或有未提交且尚未过期的前摇时拒绝。
function BiteRules.startBite(config: Config, attacker: AttackerRecord, now: number): (boolean, string)
	if attacker.state ~= "INFECTED" then
		return false, Reason.NOT_INFECTED
	end

	local latest = config.BiteWindupSeconds + config.Greybox.LungeSeconds + config.Greybox.BiteCommitSlackSeconds
	local windupStartedAt = attacker.windupStartedAt
	if windupStartedAt ~= nil and not attacker.windupConsumed then
		if now - windupStartedAt <= latest + EPSILON then
			return false, Reason.WINDUP_ACTIVE
		end
		-- 过期且从未提交的前摇（丢包/取消/目标离开）：按窗口结束时刻补收冷却，避免无成本重试。
		attacker.biteCooldownUntil = windupStartedAt + latest + config.BiteCooldownSeconds
		attacker.windupStartedAt = nil
		attacker.windupConsumed = true
	end

	local cooldownUntil = attacker.biteCooldownUntil
	if cooldownUntil ~= nil and now < cooldownUntil then
		return false, Reason.COOLDOWN
	end

	attacker.windupStartedAt = now
	attacker.windupConsumed = false
	return true, Reason.STARTED
end

-- 提交一次扑咬。输入已经由服务端完成射线遮挡检测（losBlocked）。
-- 前摇时间窗、一次前摇只提交一次、回溯判定均在此完成；命中与未命中都会进入冷却。
function BiteRules.commitBite(config: Config, input: CommitInput): CommitResult
	local attacker = input.attacker
	if attacker.state ~= "INFECTED" then
		return { hit = false, reason = Reason.NOT_INFECTED, nearMiss = false }
	end

	local windupStartedAt = attacker.windupStartedAt
	if windupStartedAt == nil then
		return { hit = false, reason = Reason.NO_WINDUP, nearMiss = false }
	end
	if attacker.windupConsumed then
		return { hit = false, reason = Reason.ALREADY_COMMITTED, nearMiss = false }
	end

	-- 时间窗两端留 EPSILON：浮点减法会让恰好落在边界的请求差出 1e-16。
	local elapsed = input.now - windupStartedAt
	local latest = config.BiteWindupSeconds + config.Greybox.LungeSeconds + config.Greybox.BiteCommitSlackSeconds
	if elapsed < config.BiteWindupSeconds - EPSILON then
		return { hit = false, reason = Reason.TOO_EARLY, nearMiss = false }
	end
	if elapsed > latest + EPSILON then
		return { hit = false, reason = Reason.TOO_LATE, nearMiss = false }
	end

	local rewind = math.clamp(input.attackerPingSeconds, 0, config.Greybox.MaxRewindSeconds)
	local sampled = input.sampleTarget(input.now - rewind)
	local cooldownUntil = input.now + config.BiteCooldownSeconds
	local recoverUntil = input.now + config.Greybox.BiteMissRecoverySeconds

	-- 采样器返回 nil 时无法验证回溯位置，按未命中处理并正常进入冷却。
	if sampled == nil then
		attacker.biteCooldownUntil = cooldownUntil
		attacker.windupConsumed = true
		return {
			hit = false,
			reason = Reason.OUT_OF_RANGE,
			nearMiss = false,
			recoverUntil = recoverUntil,
		}
	end

	local distance = horizontalDistance(input.attackerPos, sampled)
	local maxDistance = config.Greybox.BiteRange + config.Greybox.BiteTolerance
	local nearMissDistance = config.Greybox.BiteRange + 2 * config.Greybox.BiteTolerance

	local immuneUntil = input.target.curedImmuneUntil
	local isImmune = immuneUntil ~= nil and immuneUntil > input.now
	local isLegalTarget = input.target.state == "HUMAN" and not isImmune

	local hit = false
	local reason: string
	if not isLegalTarget then
		reason = Reason.TARGET_INELIGIBLE
	elseif distance > maxDistance then
		reason = Reason.OUT_OF_RANGE
	elseif
		distance > EPSILON
		and angleBetweenHorizontalDegrees(input.attackerFacing, horizontalDelta(input.attackerPos, sampled))
			> config.Greybox.BiteConeDegrees
	then
		reason = Reason.OUT_OF_CONE
	elseif input.losBlocked then
		reason = Reason.BLOCKED
	else
		hit = true
		reason = Reason.HIT
	end

	-- nearMiss 只服务 §9.5 的 bite_near_miss 调参埋点：目标必须本来合法，且失败原因属于瞄准类。
	local aimingMiss = reason == Reason.OUT_OF_RANGE or reason == Reason.OUT_OF_CONE or reason == Reason.BLOCKED
	local result: CommitResult = {
		hit = hit,
		reason = reason,
		distance = distance,
		nearMiss = not hit and isLegalTarget and aimingMiss and distance <= nearMissDistance,
	}
	if not hit then
		result.recoverUntil = recoverUntil
	end

	attacker.biteCooldownUntil = cooldownUntil
	attacker.windupConsumed = true
	return result
end

return table.freeze(BiteRules)
