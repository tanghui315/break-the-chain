--!strict
-- 人类武器与命中判定（GDB V1.1 §9A.2、§9A.4、§9A.7）。
-- 短棍是随身武器；手枪、电击枪来自补给点；霰弹枪为 EXP-07，只有配置与衰减函数，A0.5 不接入玩法。
-- 纯逻辑：时间、玩家位置、候选目标与射线遮挡全部由服务端注入；不引用 Roblox 全局。

export type Vec3 = { x: number, y: number, z: number }

export type WeaponName = "Melee" | "Pistol" | "Taser" | "Shotgun"

-- 只声明本模块用到的字段，BalanceConfig 在结构上满足它
export type Config = {
	WeaponsEnabled: boolean,
	TouchAimAssistDegrees: number,
	ShotOriginToleranceStuds: number,
	Greybox: {
		MaxRewindSeconds: number,
	},
	Weapons: {
		Melee: {
			Damage: number,
			Range: number,
			ConeDegrees: number,
			FireIntervalSeconds: number,
			KnockbackStuds: number,
		},
		Pistol: {
			Damage: number,
			Range: number,
			FireIntervalSeconds: number,
			MagazineSize: number,
			ReserveAmmo: number,
			ReloadSeconds: number,
			KnockbackStuds: number,
		},
		Taser: {
			Damage: number,
			Range: number,
			Charges: number,
			CooldownSeconds: number,
			StunSeconds: number,
			KnockbackStuds: number,
		},
		Shotgun: {
			Damage: number,
			Range: number,
			FullDamageRangeStuds: number,
			FireIntervalSeconds: number,
			MagazineSize: number,
			ReserveAmmo: number,
			ReloadSeconds: number,
			KnockbackStuds: number,
		},
	},
}

-- 一把武器的运行时状态。弹匣与电击次数共用 magazine；reserve 只对手枪/霰弹枪有意义。
export type Slot = {
	owned: boolean,
	magazine: number,
	reserve: number,
	lastFireAt: number?,
	reloadStartedAt: number?,
	reloadEndsAt: number?,
}

export type Inventory = {
	config: Config,
	melee: Slot,
	pistol: Slot,
	taser: Slot,
	shotgun: Slot,
}

export type TargetInput = {
	id: string,
	-- INFECTED 或 UNSTABLE；人类与尸变中的目标 isZombie = false。
	isZombie: boolean,
	-- 战斗生命状态可被伤害：ACTIVE，且不在复活保护期内。
	active: boolean,
	-- 服务端注入：function(t) return PositionHistory.sampleAt(history, t) end
	sample: (t: number) -> Vec3?,
}

export type FireInput = {
	origin: Vec3,
	shooterHead: Vec3,
	direction: Vec3,
	now: number,
	-- attacker:GetNetworkPing()，秒；回溯时夹取到 [0, Greybox.MaxRewindSeconds]。
	ping: number,
	targets: { TargetInput },
	-- 服务端注入的静态遮挡检测；参数已经是回溯后的目标位置（§9A.7）。
	losBlocked: (from: Vec3, to: Vec3) -> boolean,
}

export type FireResult = {
	-- ok = 这次开火请求被接受并消耗弹药/次数；ok = false 表示请求被拒绝。
	ok: boolean,
	reason: string,
	hit: boolean,
	targetId: string?,
	damage: number,
	stun: number,
	knockback: number,
	distance: number?,
}

export type TickResult = {
	reloadCompleted: boolean,
}

local Weapons = {}

local Reason = table.freeze({
	HIT = "HIT",
	NO_TARGET = "NO_TARGET",
	BLOCKED = "BLOCKED",
	FRIENDLY_FIRE = "FRIENDLY_FIRE",
	TARGET_INACTIVE = "TARGET_INACTIVE",
	WEAPONS_DISABLED = "WEAPONS_DISABLED",
	UNKNOWN_WEAPON = "UNKNOWN_WEAPON",
	NOT_OWNED = "NOT_OWNED",
	RELOADING = "RELOADING",
	EMPTY = "EMPTY",
	COOLDOWN = "COOLDOWN",
	ORIGIN_TOO_FAR = "ORIGIN_TOO_FAR",
	INVALID_DIRECTION = "INVALID_DIRECTION",
	RELOAD_STARTED = "RELOAD_STARTED",
	MAGAZINE_FULL = "MAGAZINE_FULL",
	NO_RESERVE = "NO_RESERVE",
})
Weapons.Reason = Reason

local EPSILON = 1e-9

type WeaponProfile = {
	range: number,
	interval: number,
	coneDegrees: number,
	damage: number,
	stun: number,
	knockback: number,
	consumesAmmo: boolean,
}

local function emptySlot(): Slot
	return {
		owned = false,
		magazine = 0,
		reserve = 0,
		lastFireAt = nil,
		reloadStartedAt = nil,
		reloadEndsAt = nil,
	}
end

-- 手枪始终占 1 个武器位；短棍随身携带，不占位（§9A.4、§9A.5）。
function Weapons.newInventory(config: Config): Inventory
	local melee = emptySlot()
	melee.owned = true
	return {
		config = config,
		melee = melee,
		pistol = emptySlot(),
		taser = emptySlot(),
		shotgun = emptySlot(),
	}
end

function Weapons.givePistol(inv: Inventory): boolean
	if inv.pistol.owned then
		return false
	end
	inv.pistol.owned = true
	inv.pistol.magazine = inv.config.Weapons.Pistol.MagazineSize
	inv.pistol.reserve = inv.config.Weapons.Pistol.ReserveAmmo
	return true
end

function Weapons.giveTaser(inv: Inventory): boolean
	if inv.taser.owned then
		return false
	end
	inv.taser.owned = true
	inv.taser.magazine = inv.config.Weapons.Taser.Charges
	return true
end

-- EXP-07 预留：A0.5 的补给计划不生成霰弹枪。
function Weapons.giveShotgun(inv: Inventory): boolean
	if inv.shotgun.owned then
		return false
	end
	inv.shotgun.owned = true
	inv.shotgun.magazine = inv.config.Weapons.Shotgun.MagazineSize
	inv.shotgun.reserve = inv.config.Weapons.Shotgun.ReserveAmmo
	return true
end

-- 弹药补给箱：把一把手枪的备弹补满（§9A.5），不补充弹匣。
function Weapons.refillAmmo(inv: Inventory): boolean
	if not inv.pistol.owned then
		return false
	end
	inv.pistol.reserve = inv.config.Weapons.Pistol.ReserveAmmo
	return true
end

function Weapons.startReload(inv: Inventory, now: number): (boolean, string)
	local pistol = inv.pistol
	if not pistol.owned then
		return false, Reason.NOT_OWNED
	end
	if pistol.reloadEndsAt ~= nil then
		return false, Reason.RELOADING
	end
	if pistol.magazine >= inv.config.Weapons.Pistol.MagazineSize then
		return false, Reason.MAGAZINE_FULL
	end
	if pistol.reserve <= 0 then
		return false, Reason.NO_RESERVE
	end
	pistol.reloadStartedAt = now
	pistol.reloadEndsAt = now + inv.config.Weapons.Pistol.ReloadSeconds
	return true, Reason.RELOAD_STARTED
end

local function completeReload(slot: Slot, magazineSize: number, now: number): boolean
	local endsAt = slot.reloadEndsAt
	if endsAt == nil or now < endsAt then
		return false
	end
	local needed = math.max(0, magazineSize - slot.magazine)
	local moved = math.min(needed, slot.reserve)
	slot.magazine += moved
	slot.reserve -= moved
	slot.reloadStartedAt = nil
	slot.reloadEndsAt = nil
	return true
end

-- 推进换弹。服务端每帧调用；换弹在 endsAt 时刻完成，同一时刻可以开始下一次开火。
function Weapons.tick(inv: Inventory, now: number): TickResult
	local pistolCompleted = completeReload(inv.pistol, inv.config.Weapons.Pistol.MagazineSize, now)
	local shotgunCompleted = completeReload(inv.shotgun, inv.config.Weapons.Shotgun.MagazineSize, now)
	return { reloadCompleted = pistolCompleted or shotgunCompleted }
end

function Weapons.isReloading(inv: Inventory, weapon: WeaponName): boolean
	local slot = if weapon == "Pistol" then inv.pistol elseif weapon == "Shotgun" then inv.shotgun else nil
	return slot ~= nil and slot.reloadEndsAt ~= nil
end

local function slotFor(inv: Inventory, weapon: WeaponName): Slot?
	if weapon == "Melee" then
		return inv.melee
	elseif weapon == "Pistol" then
		return inv.pistol
	elseif weapon == "Taser" then
		return inv.taser
	elseif weapon == "Shotgun" then
		return inv.shotgun
	end
	return nil
end

-- 霰弹枪伤害衰减（EXP-07）：8 studs 内 60，8～20 studs 线性衰减到 0，20 以外 0。
function Weapons.shotgunDamageAt(config: Config, distance: number): number
	local shotgun = config.Weapons.Shotgun
	if distance <= shotgun.FullDamageRangeStuds then
		return shotgun.Damage
	end
	if distance >= shotgun.Range or shotgun.Range <= shotgun.FullDamageRangeStuds then
		return 0
	end
	local alpha = (distance - shotgun.FullDamageRangeStuds) / (shotgun.Range - shotgun.FullDamageRangeStuds)
	return shotgun.Damage * (1 - alpha)
end

-- 枪械与电击枪都用 6° 辅助瞄准锥复核（§9A.7）；短棍用 ±60°（§9A.4）。
-- 命中扫描不做弹道：候选目标必须位于射线的锥内、在射程内，按沿射线方向最近者优先。
local function profileFor(config: Config, weapon: WeaponName): WeaponProfile?
	if weapon == "Melee" then
		local melee = config.Weapons.Melee
		return {
			range = melee.Range,
			interval = melee.FireIntervalSeconds,
			coneDegrees = melee.ConeDegrees,
			damage = melee.Damage,
			stun = 0,
			knockback = melee.KnockbackStuds,
			consumesAmmo = false,
		}
	elseif weapon == "Pistol" then
		local pistol = config.Weapons.Pistol
		return {
			range = pistol.Range,
			interval = pistol.FireIntervalSeconds,
			coneDegrees = config.TouchAimAssistDegrees,
			damage = pistol.Damage,
			stun = 0,
			knockback = pistol.KnockbackStuds,
			consumesAmmo = true,
		}
	elseif weapon == "Taser" then
		local taser = config.Weapons.Taser
		return {
			range = taser.Range,
			interval = taser.CooldownSeconds,
			coneDegrees = config.TouchAimAssistDegrees,
			damage = taser.Damage,
			stun = taser.StunSeconds,
			knockback = taser.KnockbackStuds,
			consumesAmmo = true,
		}
	elseif weapon == "Shotgun" then
		local shotgun = config.Weapons.Shotgun
		return {
			range = shotgun.Range,
			interval = shotgun.FireIntervalSeconds,
			coneDegrees = config.TouchAimAssistDegrees,
			damage = shotgun.Damage,
			stun = 0,
			knockback = shotgun.KnockbackStuds,
			consumesAmmo = true,
		}
	end
	return nil
end

local function sub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function length(v: Vec3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function distanceBetween(a: Vec3, b: Vec3): number
	return length(sub(a, b))
end

type Candidate = {
	target: TargetInput,
	point: Vec3,
	distance: number,
	along: number,
}

local function rejected(reason: string): FireResult
	return { ok = false, reason = reason, hit = false, damage = 0, stun = 0, knockback = 0 }
end

-- 服务端开火校验（§9A.7）：开火间隔、弹药、origin 距本人头部 ≤ 4 studs、射程、回溯位置、
-- 辅助瞄准锥、静态遮挡与目标阵营。
--
-- “接受/拒绝”与“命中/未命中”分离：通过开火间隔、弹药、origin、方向的请求会被接受并消耗弹药，
-- 即使打空、被墙挡住或目标不合法；被拒绝的请求（连点、空弹匣、origin 偏移）不消耗任何资源。
--
-- 目标选择：只考虑锥内、射程内且在射线前方的候选；沿射线方向最近者优先（同距离时按输入顺序）。
-- 最近候选若是人类/尸变中，返回 FRIENDLY_FIRE；若是倒地/死亡/保护中的丧尸，返回 TARGET_INACTIVE。
function Weapons.validateFire(config: Config, inv: Inventory, weapon: WeaponName, input: FireInput): FireResult
	if not config.WeaponsEnabled then
		return rejected(Reason.WEAPONS_DISABLED)
	end

	local profile = profileFor(config, weapon)
	local slot = slotFor(inv, weapon)
	if profile == nil or slot == nil then
		return rejected(Reason.UNKNOWN_WEAPON)
	end
	if not slot.owned then
		return rejected(Reason.NOT_OWNED)
	end
	if slot.reloadEndsAt ~= nil then
		return rejected(Reason.RELOADING)
	end
	if profile.consumesAmmo and slot.magazine <= 0 then
		return rejected(Reason.EMPTY)
	end

	local lastFireAt = slot.lastFireAt
	if lastFireAt ~= nil and input.now < lastFireAt + profile.interval then
		return rejected(Reason.COOLDOWN)
	end

	if distanceBetween(input.origin, input.shooterHead) > config.ShotOriginToleranceStuds then
		return rejected(Reason.ORIGIN_TOO_FAR)
	end

	local directionLength = length(input.direction)
	if directionLength <= EPSILON then
		return rejected(Reason.INVALID_DIRECTION)
	end
	local direction = {
		x = input.direction.x / directionLength,
		y = input.direction.y / directionLength,
		z = input.direction.z / directionLength,
	}

	-- 通过全部请求校验：开火发生，消耗弹药并记录间隔。
	if profile.consumesAmmo then
		slot.magazine -= 1
	end
	slot.lastFireAt = input.now

	local rewind = math.clamp(input.ping, 0, config.Greybox.MaxRewindSeconds)
	local sampleTime = input.now - rewind

	-- 选最近的合法几何候选（目标是否可伤害、是否友军稍后再判，保证原因码可解释）。
	local best: Candidate? = nil
	for _, target in input.targets do
		local point = target.sample(sampleTime)
		if point ~= nil then
			local delta = sub(point, input.origin)
			local distance = length(delta)
			if distance <= profile.range then
				local along = dot(delta, direction)
				local inCone = distance <= EPSILON
					or (along > 0 and math.deg(math.acos(math.clamp(along / distance, -1, 1))) <= profile.coneDegrees)
				if inCone and (best == nil or along < best.along) then
					best = { target = target, point = point, distance = distance, along = along }
				end
			end
		end
	end

	if best == nil then
		return { ok = true, reason = Reason.NO_TARGET, hit = false, damage = 0, stun = 0, knockback = 0 }
	end

	if not best.target.isZombie then
		return {
			ok = true,
			reason = Reason.FRIENDLY_FIRE,
			hit = false,
			targetId = best.target.id,
			damage = 0,
			stun = 0,
			knockback = 0,
			distance = best.distance,
		}
	end

	if not best.target.active then
		return {
			ok = true,
			reason = Reason.TARGET_INACTIVE,
			hit = false,
			targetId = best.target.id,
			damage = 0,
			stun = 0,
			knockback = 0,
			distance = best.distance,
		}
	end

	if input.losBlocked(input.origin, best.point) then
		return {
			ok = true,
			reason = Reason.BLOCKED,
			hit = false,
			targetId = best.target.id,
			damage = 0,
			stun = 0,
			knockback = 0,
			distance = best.distance,
		}
	end

	local damage = profile.damage
	if weapon == "Shotgun" then
		damage = Weapons.shotgunDamageAt(config, best.distance)
	end

	return {
		ok = true,
		reason = Reason.HIT,
		hit = true,
		targetId = best.target.id,
		damage = damage,
		stun = profile.stun,
		knockback = profile.knockback,
		distance = best.distance,
	}
end

return table.freeze(Weapons)
