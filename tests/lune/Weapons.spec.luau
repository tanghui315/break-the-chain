--!strict
-- Weapons 的命中扫描、弹药、换弹、射速、origin 校验、射程、辅助瞄准锥、遮挡与武器数值测试
-- （GDB V1.1 §9A.4、§9A.7）。霰弹枪只测 EXP-07 的衰减函数与命中伤害。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local Weapons = require("../../src/server/logic/Weapons")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = Weapons.Reason

local NOW = 100
local HEAD = { x = 0, y = 5, z = 0 }
local ORIGIN = { x = 0, y = 5, z = 0 }
local DIRECTION_X = { x = 1, y = 0, z = 0 }

local function newInventory(): Weapons.Inventory
	return Weapons.newInventory(BalanceConfig)
end

local function pistolInventory(): Weapons.Inventory
	local inv = newInventory()
	Weapons.givePistol(inv)
	return inv
end

local function target(id: string, position: Weapons.Vec3, options: any?): Weapons.TargetInput
	local opts = options or {}
	return {
		id = id,
		isZombie = if opts.isZombie ~= nil then opts.isZombie else true,
		active = if opts.active ~= nil then opts.active else true,
		sample = opts.sample or function(_t: number): Weapons.Vec3?
			return position
		end,
	}
end

local function makeInput(targets: { Weapons.TargetInput }, options: any?): Weapons.FireInput
	local opts = options or {}
	return {
		origin = opts.origin or ORIGIN,
		shooterHead = opts.shooterHead or HEAD,
		direction = opts.direction or DIRECTION_X,
		now = if opts.now ~= nil then opts.now else NOW,
		ping = if opts.ping ~= nil then opts.ping else 0,
		targets = targets,
		losBlocked = opts.losBlocked or function(_from: Weapons.Vec3, _to: Weapons.Vec3): boolean
			return false
		end,
	}
end

local function fire(
	inv: Weapons.Inventory,
	weapon: Weapons.WeaponName,
	targets: { Weapons.TargetInput },
	options: any?
): Weapons.FireResult
	return Weapons.validateFire(BalanceConfig, inv, weapon, makeInput(targets, options))
end

local function stillTarget(id: string, x: number, z: number?, options: any?): Weapons.TargetInput
	return target(id, { x = x, y = 5, z = z or 0 }, options)
end

describe("手枪基础", function()
	it("新背包自带短棍，没有枪械", function()
		local inv = newInventory()
		expect(inv.melee.owned).toBe(true)
		expect(inv.pistol.owned).toBe(false)
		expect(inv.taser.owned).toBe(false)
	end)

	it("拾取手枪获得 6 发弹匣 + 6 发备弹，重复拾取不重置", function()
		local inv = newInventory()
		expect(Weapons.givePistol(inv)).toBe(true)
		expect(inv.pistol.magazine).toBe(6)
		expect(inv.pistol.reserve).toBe(6)

		fire(inv, "Pistol", { stillTarget("z1", 10) })
		expect(inv.pistol.magazine).toBe(5)
		expect(Weapons.givePistol(inv)).toBe(false)
		expect(inv.pistol.magazine).toBe(5)
		expect(inv.pistol.reserve).toBe(6)
	end)

	it("命中丧尸：25 伤害、0 击退、距离与目标 id 正确", function()
		local inv = pistolInventory()
		local result = fire(inv, "Pistol", { stillTarget("z1", 10) })
		expect(result.ok).toBe(true)
		expect(result.hit).toBe(true)
		expect(result.reason).toBe(Reason.HIT)
		expect(result.targetId).toBe("z1")
		expect(result.damage).toBe(25)
		expect(result.stun).toBe(0)
		expect(result.knockback).toBe(0)
		expect(result.distance).toBe(10)
		expect(inv.pistol.magazine).toBe(5)
	end)

	it("没有枪时不能开火", function()
		local result = fire(newInventory(), "Pistol", { stillTarget("z1", 10) })
		expect(result.ok).toBe(false)
		expect(result.reason).toBe(Reason.NOT_OWNED)
		expect(result.hit).toBe(false)
	end)
end)

describe("手枪射速、弹药与换弹", function()
	it("0.35 秒射击间隔：边界内拒绝且不消耗弹药，边界可开火", function()
		local inv = pistolInventory()
		local targets = { stillTarget("z1", 10) }

		expect(fire(inv, "Pistol", targets, { now = NOW }).hit).toBe(true)
		expect(inv.pistol.magazine).toBe(5)

		local early = fire(inv, "Pistol", targets, { now = NOW + 0.34 })
		expect(early.ok).toBe(false)
		expect(early.reason).toBe(Reason.COOLDOWN)
		expect(inv.pistol.magazine).toBe(5)

		local boundary = fire(inv, "Pistol", targets, { now = NOW + 0.35 })
		expect(boundary.ok).toBe(true)
		expect(inv.pistol.magazine).toBe(4)
	end)

	it("6 发打空后第 7 发返回 EMPTY，不消耗备弹", function()
		local inv = pistolInventory()
		local targets = { stillTarget("z1", 10) }
		for shot = 0, 5 do
			local result = fire(inv, "Pistol", targets, { now = NOW + shot * 0.35 })
			expect(result.ok).toBe(true)
		end
		expect(inv.pistol.magazine).toBe(0)
		expect(inv.pistol.reserve).toBe(6)

		local empty = fire(inv, "Pistol", targets, { now = NOW + 6 * 0.35 })
		expect(empty.ok).toBe(false)
		expect(empty.reason).toBe(Reason.EMPTY)
		expect(inv.pistol.reserve).toBe(6)
	end)

	it("换弹 1.5 秒，完成时从备弹填满弹匣", function()
		local inv = pistolInventory()
		local targets = { stillTarget("z1", 10) }
		for shot = 0, 5 do
			fire(inv, "Pistol", targets, { now = NOW + shot * 0.35 })
		end

		local startedAt = NOW + 10
		local ok, reason = Weapons.startReload(inv, startedAt)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.RELOAD_STARTED)

		local during = fire(inv, "Pistol", targets, { now = startedAt + 0.1 })
		expect(during.ok).toBe(false)
		expect(during.reason).toBe(Reason.RELOADING)

		expect(Weapons.tick(inv, startedAt + 1.49).reloadCompleted).toBe(false)
		expect(inv.pistol.magazine).toBe(0)
		expect(Weapons.tick(inv, startedAt + 1.5).reloadCompleted).toBe(true)
		expect(inv.pistol.magazine).toBe(6)
		expect(inv.pistol.reserve).toBe(0)

		local after = fire(inv, "Pistol", targets, { now = startedAt + 1.5 })
		expect(after.ok).toBe(true)
		expect(inv.pistol.magazine).toBe(5)
	end)

	it("换弹前置条件：满弹匣、无备弹、未持枪都被拒绝", function()
		local full = pistolInventory()
		local ok, reason = Weapons.startReload(full, NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.MAGAZINE_FULL)

		local emptyReserve = pistolInventory()
		local targets = { stillTarget("z1", 10) }
		for shot = 0, 5 do
			fire(emptyReserve, "Pistol", targets, { now = NOW + shot * 0.35 })
		end
		Weapons.startReload(emptyReserve, NOW + 10)
		Weapons.tick(emptyReserve, NOW + 11.5)
		fire(emptyReserve, "Pistol", targets, { now = NOW + 12 })
		expect(emptyReserve.pistol.magazine).toBe(5)
		expect(emptyReserve.pistol.reserve).toBe(0)
		ok, reason = Weapons.startReload(emptyReserve, NOW + 13)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.NO_RESERVE)

		ok, reason = Weapons.startReload(newInventory(), NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.NOT_OWNED)
	end)

	it("弹药箱补满备弹但不补弹匣", function()
		local inv = newInventory()
		expect(Weapons.refillAmmo(inv)).toBe(false)

		Weapons.givePistol(inv)
		local targets = { stillTarget("z1", 10) }
		for shot = 0, 5 do
			fire(inv, "Pistol", targets, { now = NOW + shot * 0.35 })
		end
		Weapons.startReload(inv, NOW + 10)
		Weapons.tick(inv, NOW + 11.5)
		fire(inv, "Pistol", targets, { now = NOW + 12 })
		expect(inv.pistol.magazine).toBe(5)
		expect(inv.pistol.reserve).toBe(0)

		expect(Weapons.refillAmmo(inv)).toBe(true)
		expect(inv.pistol.reserve).toBe(6)
		expect(inv.pistol.magazine).toBe(5)
	end)
end)

describe("手枪命中校验", function()
	it("origin 距本人头部 ≤ 4 studs，超过 4 拒绝", function()
		local inv = pistolInventory()
		local targets = { stillTarget("z1", 10) }

		local atLimit = fire(inv, "Pistol", targets, { origin = { x = 4, y = 5, z = 0 } })
		expect(atLimit.ok).toBe(true)
		expect(atLimit.hit).toBe(true)

		local tooFar = fire(inv, "Pistol", targets, {
			origin = { x = 4.01, y = 5, z = 0 },
			now = NOW + 1,
		})
		expect(tooFar.ok).toBe(false)
		expect(tooFar.reason).toBe(Reason.ORIGIN_TOO_FAR)
		expect(inv.pistol.magazine).toBe(5)
	end)

	it("射程 80 studs：80 命中，80.01 视为没有目标（开火仍被接受）", function()
		local inv = pistolInventory()
		local hit = fire(inv, "Pistol", { stillTarget("z1", 80) })
		expect(hit.hit).toBe(true)
		expect(hit.distance).toBe(80)

		local miss = fire(inv, "Pistol", { stillTarget("z1", 80.01) }, { now = NOW + 1 })
		expect(miss.ok).toBe(true)
		expect(miss.hit).toBe(false)
		expect(miss.reason).toBe(Reason.NO_TARGET)
		expect(inv.pistol.magazine).toBe(4)
	end)

	it("6° 辅助瞄准锥：5.9° 命中，6.1° 脱靶", function()
		local inv = pistolInventory()
		local insideAngle = math.rad(5.9)
		local inside = stillTarget("z1", 10 * math.cos(insideAngle), 10 * math.sin(insideAngle))
		local hit = fire(inv, "Pistol", { inside })
		expect(hit.hit).toBe(true)

		local outsideAngle = math.rad(6.1)
		local outside = stillTarget("z1", 10 * math.cos(outsideAngle), 10 * math.sin(outsideAngle))
		local miss = fire(inv, "Pistol", { outside }, { now = NOW + 1 })
		expect(miss.hit).toBe(false)
		expect(miss.reason).toBe(Reason.NO_TARGET)
	end)

	it("静态遮挡：BLOCKED、不造成伤害，但开火与弹药照常结算", function()
		local inv = pistolInventory()
		local result = fire(inv, "Pistol", { stillTarget("z1", 10) }, {
			losBlocked = function(): boolean
				return true
			end,
		})
		expect(result.ok).toBe(true)
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.BLOCKED)
		expect(result.damage).toBe(0)
		expect(result.distance).toBe(10)
		expect(inv.pistol.magazine).toBe(5)
	end)

	it("不伤友军：人类与尸变中的目标都返回 FRIENDLY_FIRE", function()
		local inv = pistolInventory()
		local human = fire(inv, "Pistol", { stillTarget("h1", 10, nil, { isZombie = false }) })
		expect(human.ok).toBe(true)
		expect(human.hit).toBe(false)
		expect(human.reason).toBe(Reason.FRIENDLY_FIRE)
		expect(human.damage).toBe(0)
		expect(human.targetId).toBe("h1")

		local incubating = fire(inv, "Pistol", { stillTarget("h2", 10, nil, { isZombie = false }) }, { now = NOW + 1 })
		expect(incubating.reason).toBe(Reason.FRIENDLY_FIRE)
	end)

	it("倒地/死亡/保护中的丧尸返回 TARGET_INACTIVE，不造成伤害", function()
		local inv = pistolInventory()
		local result = fire(inv, "Pistol", { stillTarget("z1", 10, nil, { active = false }) })
		expect(result.ok).toBe(true)
		expect(result.hit).toBe(false)
		expect(result.reason).toBe(Reason.TARGET_INACTIVE)
		expect(result.damage).toBe(0)
	end)

	it("锥内多个目标时选沿射线最近的一个；友军挡在前面时命中友军判定", function()
		local inv = pistolInventory()
		local nearest = fire(inv, "Pistol", { stillTarget("far", 20), stillTarget("near", 10) })
		expect(nearest.targetId).toBe("near")

		local blockedByHuman = fire(
			inv,
			"Pistol",
			{ stillTarget("z1", 20), stillTarget("h1", 10, nil, { isZombie = false }) },
			{ now = NOW + 1 }
		)
		expect(blockedByHuman.targetId).toBe("h1")
		expect(blockedByHuman.reason).toBe(Reason.FRIENDLY_FIRE)
	end)

	it("回溯位置取自 now - clamp(ping, 0, 0.25)，位置历史用回溯点判定", function()
		local inv = pistolInventory()
		local function rewoundSample(t: number): Weapons.Vec3?
			if t <= NOW - 0.25 then
				return { x = 10, y = 5, z = 0 }
			end
			return { x = 200, y = 5, z = 0 }
		end
		local moving = target("z1", { x = 0, y = 0, z = 0 }, { sample = rewoundSample })

		local rewound = fire(inv, "Pistol", { moving }, { ping = 10 })
		expect(rewound.hit).toBe(true)
		expect(rewound.distance).toBe(10)

		local current = fire(inv, "Pistol", { moving }, { now = NOW + 1, ping = 0 })
		expect(current.hit).toBe(false)
		expect(current.reason).toBe(Reason.NO_TARGET)

		local negative = fire(inv, "Pistol", { moving }, { now = NOW + 2, ping = -3 })
		expect(negative.hit).toBe(false)
	end)

	it("方向为零向量、未知武器、全局关闭都拒绝", function()
		local inv = pistolInventory()
		local zero = fire(inv, "Pistol", { stillTarget("z1", 10) }, { direction = { x = 0, y = 0, z = 0 } })
		expect(zero.ok).toBe(false)
		expect(zero.reason).toBe(Reason.INVALID_DIRECTION)

		local unknown = Weapons.validateFire(BalanceConfig, inv, "Laser" :: any, makeInput({ stillTarget("z1", 10) }))
		expect(unknown.ok).toBe(false)
		expect(unknown.reason).toBe(Reason.UNKNOWN_WEAPON)

		local disabledConfig = table.clone(BalanceConfig)
		disabledConfig.WeaponsEnabled = false
		local disabled = Weapons.validateFire(disabledConfig, inv, "Pistol", makeInput({ stillTarget("z1", 10) }))
		expect(disabled.ok).toBe(false)
		expect(disabled.reason).toBe(Reason.WEAPONS_DISABLED)
	end)
end)

describe("短棍", function()
	it("射程 6、±60°、间隔 0.9、20 伤害、6 击退", function()
		local inv = newInventory()
		local hit = fire(inv, "Melee", { stillTarget("z1", 5) })
		expect(hit.ok).toBe(true)
		expect(hit.hit).toBe(true)
		expect(hit.damage).toBe(20)
		expect(hit.knockback).toBe(6)
		expect(hit.stun).toBe(0)
		expect(hit.distance).toBe(5)

		local outOfRange = fire(inv, "Melee", { stillTarget("z1", 6.01) }, { now = NOW + 1 })
		expect(outOfRange.reason).toBe(Reason.NO_TARGET)

		local at59 = math.rad(59)
		expect(fire(inv, "Melee", { stillTarget("z1", 5 * math.cos(at59), 5 * math.sin(at59)) }, { now = NOW + 2 }).hit).toBe(
			true
		)
		local at61 = math.rad(61)
		expect(fire(inv, "Melee", { stillTarget("z1", 5 * math.cos(at61), 5 * math.sin(at61)) }, { now = NOW + 3 }).hit).toBe(
			false
		)
	end)

	it("0.9 秒间隔，短棍没有弹药消耗", function()
		local inv = newInventory()
		local targets = { stillTarget("z1", 5) }
		expect(fire(inv, "Melee", targets, { now = NOW }).hit).toBe(true)
		local early = fire(inv, "Melee", targets, { now = NOW + 0.89 })
		expect(early.ok).toBe(false)
		expect(early.reason).toBe(Reason.COOLDOWN)
		expect(fire(inv, "Melee", targets, { now = NOW + 0.9 }).hit).toBe(true)
		expect(inv.melee.magazine).toBe(0)
	end)
end)

describe("电击枪", function()
	it("2 发、12 studs、0 伤害、1.5 秒电击", function()
		local inv = newInventory()
		expect(Weapons.giveTaser(inv)).toBe(true)
		expect(inv.taser.magazine).toBe(2)

		local hit = fire(inv, "Taser", { stillTarget("z1", 10) })
		expect(hit.ok).toBe(true)
		expect(hit.hit).toBe(true)
		expect(hit.damage).toBe(0)
		expect(hit.stun).toBe(1.5)
		expect(hit.knockback).toBe(0)
		expect(inv.taser.magazine).toBe(1)
	end)

	it("8 秒冷却：7.99 秒拒绝且不消耗次数，8 秒可再射", function()
		local inv = newInventory()
		Weapons.giveTaser(inv)
		local targets = { stillTarget("z1", 10) }

		expect(fire(inv, "Taser", targets, { now = NOW }).hit).toBe(true)
		local early = fire(inv, "Taser", targets, { now = NOW + 7.99 })
		expect(early.ok).toBe(false)
		expect(early.reason).toBe(Reason.COOLDOWN)
		expect(inv.taser.magazine).toBe(1)

		expect(fire(inv, "Taser", targets, { now = NOW + 8 }).hit).toBe(true)
		expect(inv.taser.magazine).toBe(0)

		local empty = fire(inv, "Taser", targets, { now = NOW + 16 })
		expect(empty.ok).toBe(false)
		expect(empty.reason).toBe(Reason.EMPTY)
	end)

	it("射程 12 studs；没有电击枪时不能开火", function()
		local inv = newInventory()
		Weapons.giveTaser(inv)
		expect(fire(inv, "Taser", { stillTarget("z1", 12) }).hit).toBe(true)
		local miss = fire(inv, "Taser", { stillTarget("z1", 12.01) }, { now = NOW + 8 })
		expect(miss.ok).toBe(true)
		expect(miss.hit).toBe(false)
		expect(miss.reason).toBe(Reason.NO_TARGET)

		local noTaser = fire(newInventory(), "Taser", { stillTarget("z1", 10) })
		expect(noTaser.ok).toBe(false)
		expect(noTaser.reason).toBe(Reason.NOT_OWNED)
	end)
end)

describe("霰弹枪（EXP-07）", function()
	it("伤害衰减：8 studs 内 60，14 studs 30，20 studs 0，更远 0", function()
		expect(Weapons.shotgunDamageAt(BalanceConfig, 0)).toBe(60)
		expect(Weapons.shotgunDamageAt(BalanceConfig, 8)).toBe(60)
		expect(Weapons.shotgunDamageAt(BalanceConfig, 14)).toBe(30)
		expect(Weapons.shotgunDamageAt(BalanceConfig, 20)).toBe(0)
		expect(Weapons.shotgunDamageAt(BalanceConfig, 25)).toBe(0)
	end)

	it("命中伤害按距离衰减，击退 10", function()
		local inv = newInventory()
		Weapons.giveShotgun(inv)

		local close = fire(inv, "Shotgun", { stillTarget("z1", 5) })
		expect(close.hit).toBe(true)
		expect(close.damage).toBe(60)
		expect(close.knockback).toBe(10)

		local mid = fire(inv, "Shotgun", { stillTarget("z1", 10) }, { now = NOW + 1 })
		expect(mid.damage).toBe(50)
	end)
end)

TestKit.finish()
