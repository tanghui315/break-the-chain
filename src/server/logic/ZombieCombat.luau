--!strict
-- 丧尸的战斗生命状态机（GDB V1.1 §9A.1、§9A.3、§9A.4）：ACTIVE → DOWNED → DEAD → ACTIVE（复活）。
-- 战斗生命状态与感染身份（主状态、感染树节点、isRoot、断联截止）分开存储：本模块的任何变化都不改写感染身份。
-- 纯逻辑：单只丧尸一条记录，时间与人数档参数由调用方传入；不引用 Roblox 全局，也不 require 其他纯模块。

export type Config = {
	BiteWindupSeconds: number,
	BiteCooldownSeconds: number,
	-- §6.2 / D2：零号前摇被打断时的冷却倍率（与普通扑咬冷却一致）。
	RootBiteCooldownMultiplier: number,
	ZombieMaxHealth: number,
	ZombieRegenDelaySeconds: number,
	ZombieRegenPerSecond: number,
	RootHealthMultiplier: number,
	DownedSeconds: number,
	DownedMoveSpeed: number,
	LastZombieRespawnCapSeconds: number,
	RespawnProtectionSeconds: number,
	ControlImmunitySeconds: number,
	StunSeconds: number,
}

export type LifeState = "ACTIVE" | "DOWNED" | "DEAD"

export type CombatEvent = { type: string }

export type Zombie = {
	config: Config,
	isRoot: boolean,
	maxHealth: number,
	health: number,
	state: LifeState,
	lastDamageAt: number,
	lastTickAt: number,
	downedUntil: number?,
	deadUntil: number?,
	-- 已经发过 RESPAWN_READY，等服务端选好复活点后调用 respawn()；避免每个 tick 重复发事件。
	respawnReady: boolean,
	respawnProtectionUntil: number?,
	stunUntil: number,
	-- 电击结束后 ControlImmunitySeconds 内不能再被电击（§9A.3）。
	controlImmuneUntil: number,
	-- 扑咬前摇镜像：服务端在 BiteRules.startBite 成功后调用 beginWindup，提交/取消时调用 cancelWindup。
	-- 只在 BiteWindupSeconds 窗口内被武器命中或电击才构成“打断前摇”（§9A.4）。
	windupStartedAt: number?,
}

export type DamageResult = {
	applied: boolean,
	reason: string,
	downed: boolean,
	interruptedWindup: boolean,
	biteCooldownUntil: number?,
	health: number,
	events: { CombatEvent },
}

export type StunDetail = {
	interruptedWindup: boolean?,
	biteCooldownUntil: number?,
	stunUntil: number?,
}

export type TickContext = {
	-- PlayerCountTiers[].zombieRespawnSeconds：4～7 人 6 秒、8～15 人 8 秒、16～24 人 10 秒。
	respawnSeconds: number,
	-- 场上已没有任何可行动的丧尸（全部倒地、死亡或尸变中）时，剩余复活时间最多 LastZombieRespawnCapSeconds。
	noZombieCanAct: boolean,
}

local ZombieCombat = {}

local Reason = table.freeze({
	APPLIED = "APPLIED",
	IGNORED = "IGNORED",
	IMMUNE_DOWNED = "IMMUNE_DOWNED",
	IMMUNE_DEAD = "IMMUNE_DEAD",
	PROTECTED = "PROTECTED",
	STUNNED = "STUNNED",
	NOT_ACTIVE = "NOT_ACTIVE",
	CONTROL_IMMUNE = "CONTROL_IMMUNE",
	ALREADY_STUNNED = "ALREADY_STUNNED",
})
ZombieCombat.Reason = Reason

local EventType = table.freeze({
	DOWNED = "DOWNED",
	DIED = "DIED",
	RESPAWN_READY = "RESPAWN_READY",
})
ZombieCombat.EventType = EventType

local EPSILON = 1e-9

-- 零号生命值 ×RootHealthMultiplier（§9A.3，延续 D2 的零号保护）。生命值取整，避免浮点尾差影响 HUD 与命中计数：
-- 起点 100 × 1.25 = 125，手枪每发 25，第 5 发倒地（比普通丧尸多一发）。
local function maxHealthFor(config: Config, isRoot: boolean): number
	local base = config.ZombieMaxHealth
	if isRoot then
		base *= config.RootHealthMultiplier
	end
	return math.round(base)
end

-- 前摇窗口内的命中/电击打断前摇，并把丧尸放进正常扑咬冷却（§9A.4）。
-- 窗口外（已进入扑击/提交阶段）的命中不构成打断。
local function interruptWindup(z: Zombie, now: number): (boolean, number?)
	local startedAt = z.windupStartedAt
	if startedAt == nil then
		return false, nil
	end
	z.windupStartedAt = nil
	if now - startedAt > z.config.BiteWindupSeconds + EPSILON then
		return false, nil
	end
	-- §6.2 / D2：被打断的零号同样按倍率收取扑咬冷却。
	local cooldown = z.config.BiteCooldownSeconds
	if z.isRoot then
		cooldown *= z.config.RootBiteCooldownMultiplier
	end
	return true, now + cooldown
end

function ZombieCombat.new(config: Config, isRoot: boolean, now: number): Zombie
	local maxHealth = maxHealthFor(config, isRoot)
	return {
		config = config,
		isRoot = isRoot,
		maxHealth = maxHealth,
		health = maxHealth,
		state = "ACTIVE",
		-- -math.huge 表示从未受伤：满血时不会触发回复。
		lastDamageAt = -math.huge,
		lastTickAt = now,
		downedUntil = nil,
		deadUntil = nil,
		respawnReady = false,
		respawnProtectionUntil = nil,
		stunUntil = now,
		controlImmuneUntil = now,
		windupStartedAt = nil,
	}
end

-- 武器命中。倒地/死亡/复活保护期内完全不受伤害；伤害为 0 或非有限值时忽略。
-- health 归零立即倒地（DOWNED），不走 DEAD；死亡只由 tick 在倒地结束时推进。
function ZombieCombat.applyDamage(z: Zombie, amount: number, now: number): DamageResult
	local events: { CombatEvent } = {}
	if z.state == "DOWNED" then
		return {
			applied = false,
			reason = Reason.IMMUNE_DOWNED,
			downed = false,
			interruptedWindup = false,
			health = z.health,
			events = events,
		}
	end
	if z.state == "DEAD" then
		return {
			applied = false,
			reason = Reason.IMMUNE_DEAD,
			downed = false,
			interruptedWindup = false,
			health = z.health,
			events = events,
		}
	end

	local protectionUntil = z.respawnProtectionUntil
	if protectionUntil ~= nil and now < protectionUntil then
		return {
			applied = false,
			reason = Reason.PROTECTED,
			downed = false,
			interruptedWindup = false,
			health = z.health,
			events = events,
		}
	end

	if amount <= 0 or amount ~= amount then
		return {
			applied = false,
			reason = Reason.IGNORED,
			downed = false,
			interruptedWindup = false,
			health = z.health,
			events = events,
		}
	end

	z.lastDamageAt = now
	z.health = math.max(0, z.health - amount)
	local interruptedWindup, biteCooldownUntil = interruptWindup(z, now)

	if z.health <= 0 then
		z.health = 0
		z.state = "DOWNED"
		z.downedUntil = now + z.config.DownedSeconds
		z.stunUntil = now
		table.insert(events, { type = EventType.DOWNED })
		return {
			applied = true,
			reason = Reason.APPLIED,
			downed = true,
			interruptedWindup = interruptedWindup,
			biteCooldownUntil = biteCooldownUntil,
			health = 0,
			events = events,
		}
	end

	return {
		applied = true,
		reason = Reason.APPLIED,
		downed = false,
		interruptedWindup = interruptedWindup,
		biteCooldownUntil = biteCooldownUntil,
		health = z.health,
		events = events,
	}
end

-- 电击控制（§9A.3）：1.5 秒不能行动；结束后 5 秒内免疫再次电击；倒地/死亡中不能被电击。
-- 前摇期间的电击同样打断前摇（§9A.4）。复活保护只挡伤害，不挡控制。
function ZombieCombat.applyStun(z: Zombie, now: number): (boolean, string, StunDetail)
	if z.state ~= "ACTIVE" then
		return false, Reason.NOT_ACTIVE, {}
	end
	if now < z.stunUntil then
		return false, Reason.ALREADY_STUNNED, {}
	end
	if now < z.controlImmuneUntil then
		return false, Reason.CONTROL_IMMUNE, {}
	end

	z.stunUntil = now + z.config.StunSeconds
	z.controlImmuneUntil = z.stunUntil + z.config.ControlImmunitySeconds
	local interruptedWindup, biteCooldownUntil = interruptWindup(z, now)
	return true,
		Reason.STUNNED,
		{
			interruptedWindup = interruptedWindup,
			biteCooldownUntil = biteCooldownUntil,
			stunUntil = z.stunUntil,
		}
end

function ZombieCombat.isStunned(z: Zombie, now: number): boolean
	return z.state == "ACTIVE" and now < z.stunUntil
end

-- 可行动 = ACTIVE 且不在电击中。复活保护不阻止行动；主动攻击时会由 onAttack 立即结束保护。
function ZombieCombat.canAct(z: Zombie, now: number): boolean
	return z.state == "ACTIVE" and now >= z.stunUntil
end

-- 服务端确认丧尸发起攻击（扑咬命中/开始前摇等）：立即结束复活保护（§9A.3）。
-- 返回是否真的结束了保护。
function ZombieCombat.onAttack(z: Zombie, now: number): boolean
	local protectionUntil = z.respawnProtectionUntil
	if protectionUntil ~= nil and now < protectionUntil then
		z.respawnProtectionUntil = nil
		return true
	end
	return false
end

-- 扑咬前摇镜像：BiteRules.startBite 成功后调用。不能行动时拒绝，避免倒地/电击中的丧尸保留前摇状态。
function ZombieCombat.beginWindup(z: Zombie, now: number): boolean
	if not ZombieCombat.canAct(z, now) then
		return false
	end
	z.windupStartedAt = now
	return true
end

function ZombieCombat.cancelWindup(z: Zombie)
	z.windupStartedAt = nil
end

function ZombieCombat.hasWindup(z: Zombie): boolean
	return z.windupStartedAt ~= nil
end

-- 每帧推进：回复、倒地→死亡、死亡→复活就绪。
-- 回复只计算真正进入“4 秒未受伤”之后的时间，稀疏 tick 也不会把延迟前的空档算成回复。
function ZombieCombat.tick(z: Zombie, now: number, ctx: TickContext): { CombatEvent }
	local events: { CombatEvent } = {}
	local config = z.config
	local previousTickAt = z.lastTickAt
	z.lastTickAt = now

	if z.state == "ACTIVE" then
		if z.health < z.maxHealth then
			local regenStart = math.max(previousTickAt, z.lastDamageAt + config.ZombieRegenDelaySeconds)
			local regenSeconds = math.max(0, now - regenStart)
			if regenSeconds > 0 then
				z.health = math.min(z.maxHealth, z.health + config.ZombieRegenPerSecond * regenSeconds)
			end
		end
		return events
	end

	if z.state == "DOWNED" then
		local downedUntil = z.downedUntil
		if downedUntil ~= nil and now >= downedUntil then
			z.state = "DEAD"
			z.downedUntil = nil
			z.respawnReady = false
			-- 复活时间从倒地结束时刻起算，而不是从这一次 tick 起算，避免 tick 抖动拉长死亡时间。
			z.deadUntil = downedUntil + math.max(0, ctx.respawnSeconds)
			z.windupStartedAt = nil
			table.insert(events, { type = EventType.DIED })
		end
	end

	if z.state == "DEAD" then
		local deadUntil = z.deadUntil
		if deadUntil ~= nil and ctx.noZombieCanAct then
			-- 最后一只丧尸：把剩余时间压到上限。缩短后不再延长（即使场上重新出现可行动丧尸）。
			local capped = now + config.LastZombieRespawnCapSeconds
			if capped < deadUntil then
				deadUntil = capped
				z.deadUntil = capped
			end
		end
		if deadUntil ~= nil and now >= deadUntil and not z.respawnReady then
			z.respawnReady = true
			table.insert(events, { type = EventType.RESPAWN_READY })
		end
	end

	return events
end

-- 掉出地图 / 异常死亡：可行动丧尸按正常死亡处理，直接进入 DEAD 并走完整复活时间（§9A.3、§19.5）。
-- 与 applyDamage 不同，这条路径不经过 DOWNED；倒地中的丧尸掉出地图不走这里（服务端放回最后合法位置）。
-- 已经死亡时幂等返回空事件。respawnSeconds 非法时按 0 处理，避免 deadly 计时器变成 NaN 后永远不复活。
function ZombieCombat.forceDeath(z: Zombie, now: number, respawnSeconds: number): { CombatEvent }
	local events: { CombatEvent } = {}
	if z.state == "DEAD" then
		return events
	end

	local seconds = respawnSeconds
	if seconds ~= seconds or seconds < 0 then
		seconds = 0
	end

	z.state = "DEAD"
	z.health = 0
	z.downedUntil = nil
	z.deadUntil = now + seconds
	z.respawnReady = false
	z.stunUntil = now
	z.windupStartedAt = nil
	table.insert(events, { type = EventType.DIED })
	return events
end

-- 服务端选好感染区复活点后调用：恢复满血并给 2 秒复活保护（主动攻击时由 onAttack 立即结束）。
-- 只有 DEAD 状态可以复活；电击与控制免疫在复活时清空。
function ZombieCombat.respawn(z: Zombie, now: number): boolean
	if z.state ~= "DEAD" then
		return false
	end
	z.state = "ACTIVE"
	z.health = z.maxHealth
	z.lastDamageAt = -math.huge
	z.lastTickAt = now
	z.downedUntil = nil
	z.deadUntil = nil
	z.respawnReady = false
	z.respawnProtectionUntil = now + z.config.RespawnProtectionSeconds
	z.stunUntil = now
	z.controlImmuneUntil = now
	z.windupStartedAt = nil
	return true
end

-- 移动速度（studs/s）：死亡 0；倒地 4；电击 0；其余用调用方的正常速度（稳定/断联丧尸不同）。
function ZombieCombat.moveSpeedFor(config: Config, z: Zombie, now: number, normalSpeed: number): number
	if z.state == "DEAD" then
		return 0
	end
	if z.state == "DOWNED" then
		return config.DownedMoveSpeed
	end
	if ZombieCombat.isStunned(z, now) then
		return 0
	end
	return normalSpeed
end

function ZombieCombat.isRespawnProtected(z: Zombie, now: number): boolean
	local protectionUntil = z.respawnProtectionUntil
	return protectionUntil ~= nil and now < protectionUntil
end

function ZombieCombat.isRespawnReady(z: Zombie): boolean
	return z.respawnReady
end

function ZombieCombat.healthOf(z: Zombie): number
	return z.health
end

function ZombieCombat.maxHealthOf(z: Zombie): number
	return z.maxHealth
end

function ZombieCombat.stateOf(z: Zombie): LifeState
	return z.state
end

function ZombieCombat.controlImmuneUntil(z: Zombie): number
	return z.controlImmuneUntil
end

return table.freeze(ZombieCombat)
