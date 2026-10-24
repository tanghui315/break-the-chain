--!strict
-- ZombieCombat 的战斗生命状态机测试（GDB V1.1 §9A.3、§9A.4）：
-- 生命值、4 发手枪倒地、回复、倒地→死亡→复活、最后一只丧尸上限、复活保护、电击免疫与前摇打断。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local ZombieCombat = require("../../src/server/logic/ZombieCombat")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = ZombieCombat.Reason
local EventType = ZombieCombat.EventType

local NOW = 100
local PISTOL_DAMAGE = BalanceConfig.Weapons.Pistol.Damage
local MELEE_DAMAGE = BalanceConfig.Weapons.Melee.Damage

local function newZombie(isRoot: boolean?, now: number?): ZombieCombat.Zombie
	return ZombieCombat.new(BalanceConfig, isRoot == true, now or NOW)
end

local function hasEvent(events: { ZombieCombat.CombatEvent }, eventType: string): boolean
	for _, event in events do
		if event.type == eventType then
			return true
		end
	end
	return false
end

-- 把丧尸打到倒地，返回倒地发生的时刻。
local function knockDown(z: ZombieCombat.Zombie, now: number): number
	ZombieCombat.applyDamage(z, ZombieCombat.maxHealthOf(z), now)
	return now
end

describe("生命值与倒地阈值", function()
	it("普通丧尸满血 100、ACTIVE、可行动且不受保护", function()
		local z = newZombie()
		expect(ZombieCombat.maxHealthOf(z)).toBe(100)
		expect(ZombieCombat.healthOf(z)).toBe(100)
		expect(ZombieCombat.stateOf(z)).toBe("ACTIVE")
		expect(ZombieCombat.canAct(z, NOW)).toBe(true)
		expect(ZombieCombat.isRespawnProtected(z, NOW)).toBe(false)
	end)

	it("零号生命值 ×1.25 = 125", function()
		local z = newZombie(true)
		expect(ZombieCombat.maxHealthOf(z)).toBe(100 * BalanceConfig.RootHealthMultiplier)
		expect(ZombieCombat.maxHealthOf(z)).toBe(125)
	end)

	it("普通丧尸恰好 4 发手枪（4 × 25 = 100）倒地", function()
		local z = newZombie()
		for _ = 1, 3 do
			local result = ZombieCombat.applyDamage(z, PISTOL_DAMAGE, NOW)
			expect(result.downed).toBe(false)
			expect(ZombieCombat.stateOf(z)).toBe("ACTIVE")
		end
		expect(ZombieCombat.healthOf(z)).toBe(25)

		local result = ZombieCombat.applyDamage(z, PISTOL_DAMAGE, NOW)
		expect(result.applied).toBe(true)
		expect(result.downed).toBe(true)
		expect(result.health).toBe(0)
		expect(ZombieCombat.stateOf(z)).toBe("DOWNED")
		expect(ZombieCombat.healthOf(z)).toBe(0)
		expect(hasEvent(result.events, EventType.DOWNED)).toBe(true)
	end)

	it("零号 125 生命需要 5 发手枪：4 发后剩 25 点仍 ACTIVE", function()
		local z = newZombie(true)
		for _ = 1, 4 do
			ZombieCombat.applyDamage(z, PISTOL_DAMAGE, NOW)
		end
		expect(ZombieCombat.healthOf(z)).toBe(25)
		expect(ZombieCombat.stateOf(z)).toBe("ACTIVE")

		local result = ZombieCombat.applyDamage(z, PISTOL_DAMAGE, NOW)
		expect(result.downed).toBe(true)
	end)

	it("短棍 5 × 20 = 100 倒地", function()
		local z = newZombie()
		for _ = 1, 4 do
			ZombieCombat.applyDamage(z, MELEE_DAMAGE, NOW)
		end
		expect(ZombieCombat.healthOf(z)).toBe(20)
		local result = ZombieCombat.applyDamage(z, MELEE_DAMAGE, NOW)
		expect(result.downed).toBe(true)
	end)

	it("0 或负数伤害被忽略", function()
		local z = newZombie()
		local result = ZombieCombat.applyDamage(z, 0, NOW)
		expect(result.applied).toBe(false)
		expect(result.reason).toBe(Reason.IGNORED)
		expect(ZombieCombat.healthOf(z)).toBe(100)
	end)
end)

describe("生命回复", function()
	it("受伤后 4 秒内不回复，之后每秒回复 25", function()
		local z = newZombie(false, 0)
		ZombieCombat.applyDamage(z, 25, 0)
		expect(ZombieCombat.healthOf(z)).toBe(75)

		ZombieCombat.tick(z, 3.9, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(75)

		ZombieCombat.tick(z, 4.0, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(75)

		ZombieCombat.tick(z, 5.0, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(100)
	end)

	it("稀疏 tick 也不会把 4 秒延迟前的空档算成回复", function()
		local z = newZombie(false, 0)
		ZombieCombat.applyDamage(z, 50, 0)
		ZombieCombat.tick(z, 6.0, { respawnSeconds = 6, noZombieCanAct = false })
		-- 只有 4.0 到 6.0 这两秒算回复：50 + 50 = 100。
		expect(ZombieCombat.healthOf(z)).toBe(100)
	end)

	it("回复不超过最大生命", function()
		local z = newZombie(false, 0)
		ZombieCombat.applyDamage(z, 10, 0)
		ZombieCombat.tick(z, 100, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(100)
	end)

	it("再次受伤会重置 4 秒延迟", function()
		local z = newZombie(false, 0)
		ZombieCombat.applyDamage(z, 25, 0)
		ZombieCombat.applyDamage(z, 25, 3)
		ZombieCombat.tick(z, 6.9, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(50)
		ZombieCombat.tick(z, 7.0, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(50)
		ZombieCombat.tick(z, 8.0, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.healthOf(z)).toBe(75)
	end)
end)

describe("倒地", function()
	it("倒地持续 4 秒，期间无视伤害且不能被电击", function()
		local z = newZombie()
		knockDown(z, NOW)
		expect(z.downedUntil).toBe(NOW + BalanceConfig.DownedSeconds)

		local damage = ZombieCombat.applyDamage(z, 25, NOW + 1)
		expect(damage.applied).toBe(false)
		expect(damage.reason).toBe(Reason.IMMUNE_DOWNED)
		expect(ZombieCombat.healthOf(z)).toBe(0)

		local ok, reason = ZombieCombat.applyStun(z, NOW + 1)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.NOT_ACTIVE)
	end)

	it("倒地时不能行动、不能攻击，只能以 4 studs/s 爬行", function()
		local z = newZombie()
		knockDown(z, NOW)
		expect(ZombieCombat.canAct(z, NOW)).toBe(false)
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW, 18)).toBe(4)
		expect(ZombieCombat.beginWindup(z, NOW)).toBe(false)
	end)

	it("倒地结束进入 DEAD，复活时间按人数档（6 / 8 / 10 秒）", function()
		local tiers = { 6, 8, 10 }
		for _, respawnSeconds in tiers do
			local z = newZombie()
			local downedAt = knockDown(z, NOW)
			ZombieCombat.tick(z, downedAt + 4 - 0.01, { respawnSeconds = respawnSeconds, noZombieCanAct = false })
			expect(ZombieCombat.stateOf(z)).toBe("DOWNED")

			local events =
				ZombieCombat.tick(z, downedAt + 4, { respawnSeconds = respawnSeconds, noZombieCanAct = false })
			expect(ZombieCombat.stateOf(z)).toBe("DEAD")
			expect(hasEvent(events, EventType.DIED)).toBe(true)
			expect(z.deadUntil).toBe(downedAt + 4 + respawnSeconds)
		end
	end)

	it("倒地期间免疫普通武器伤害，但死亡后同样免疫", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 6, noZombieCanAct = false })
		local result = ZombieCombat.applyDamage(z, 25, NOW + 5)
		expect(result.applied).toBe(false)
		expect(result.reason).toBe(Reason.IMMUNE_DEAD)
	end)
end)

describe("最后一只丧尸", function()
	it("没有可行动丧尸时，剩余复活时间缩短到最多 3 秒", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 10, noZombieCanAct = false })
		expect(z.deadUntil).toBe(NOW + 14)

		local capAt = NOW + 5
		ZombieCombat.tick(z, capAt, { respawnSeconds = 10, noZombieCanAct = true })
		expect(z.deadUntil).toBe(capAt + BalanceConfig.LastZombieRespawnCapSeconds)
		expect((z.deadUntil :: number) - capAt).toBe(3)
	end)

	it("重新出现可行动丧尸后，已缩短的复活时间不会被延长", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 10, noZombieCanAct = false })
		ZombieCombat.tick(z, NOW + 5, { respawnSeconds = 10, noZombieCanAct = true })
		ZombieCombat.tick(z, NOW + 6, { respawnSeconds = 10, noZombieCanAct = false })
		expect(z.deadUntil).toBe(NOW + 8)
	end)

	it("没有最后一只丧尸条件时不缩短", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 10, noZombieCanAct = false })
		ZombieCombat.tick(z, NOW + 5, { respawnSeconds = 10, noZombieCanAct = false })
		expect(z.deadUntil).toBe(NOW + 14)
	end)

	it("RESPAWN_READY 只发一次，respawn() 后恢复满血与 2 秒保护", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 6, noZombieCanAct = false })

		local events = ZombieCombat.tick(z, NOW + 10, { respawnSeconds = 6, noZombieCanAct = false })
		expect(hasEvent(events, EventType.RESPAWN_READY)).toBe(true)
		expect(ZombieCombat.isRespawnReady(z)).toBe(true)
		expect(ZombieCombat.stateOf(z)).toBe("DEAD")

		local again = ZombieCombat.tick(z, NOW + 11, { respawnSeconds = 6, noZombieCanAct = false })
		expect(hasEvent(again, EventType.RESPAWN_READY)).toBe(false)

		expect(ZombieCombat.respawn(z, NOW + 10)).toBe(true)
		expect(ZombieCombat.stateOf(z)).toBe("ACTIVE")
		expect(ZombieCombat.healthOf(z)).toBe(100)
		expect(ZombieCombat.isRespawnReady(z)).toBe(false)
		expect(ZombieCombat.isRespawnProtected(z, NOW + 10)).toBe(true)
		expect(ZombieCombat.isRespawnProtected(z, NOW + 12)).toBe(false)
		expect(ZombieCombat.respawn(z, NOW + 12)).toBe(false)
	end)
end)

describe("复活保护", function()
	it("保护期内免疫伤害，2 秒后自动失效", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 6, noZombieCanAct = false })
		ZombieCombat.tick(z, NOW + 10, { respawnSeconds = 6, noZombieCanAct = false })
		ZombieCombat.respawn(z, NOW + 10)

		local blocked = ZombieCombat.applyDamage(z, 25, NOW + 10.5)
		expect(blocked.applied).toBe(false)
		expect(blocked.reason).toBe(Reason.PROTECTED)
		expect(ZombieCombat.healthOf(z)).toBe(100)

		local allowed = ZombieCombat.applyDamage(z, 25, NOW + 12)
		expect(allowed.applied).toBe(true)
		expect(ZombieCombat.healthOf(z)).toBe(75)
	end)

	it("主动攻击立即结束保护", function()
		local z = newZombie()
		knockDown(z, NOW)
		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 6, noZombieCanAct = false })
		ZombieCombat.tick(z, NOW + 10, { respawnSeconds = 6, noZombieCanAct = false })
		ZombieCombat.respawn(z, NOW + 10)

		expect(ZombieCombat.onAttack(z, NOW + 10.5)).toBe(true)
		expect(ZombieCombat.isRespawnProtected(z, NOW + 10.5)).toBe(false)
		expect(ZombieCombat.onAttack(z, NOW + 10.6)).toBe(false)

		local damage = ZombieCombat.applyDamage(z, 25, NOW + 10.6)
		expect(damage.applied).toBe(true)
		expect(ZombieCombat.healthOf(z)).toBe(75)
	end)
end)

describe("电击控制", function()
	it("电击 1.5 秒，结束后 5 秒内不能再被电击", function()
		local z = newZombie()
		local ok, reason, detail = ZombieCombat.applyStun(z, NOW)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STUNNED)
		expect(detail.stunUntil).toBe(NOW + 1.5)
		expect(ZombieCombat.controlImmuneUntil(z)).toBe(NOW + 1.5 + 5)

		expect(ZombieCombat.isStunned(z, NOW)).toBe(true)
		expect(ZombieCombat.isStunned(z, NOW + 1.49)).toBe(true)
		expect(ZombieCombat.isStunned(z, NOW + 1.5)).toBe(false)
		expect(ZombieCombat.canAct(z, NOW + 1.49)).toBe(false)
		expect(ZombieCombat.canAct(z, NOW + 1.5)).toBe(true)
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW + 0.5, 18)).toBe(0)
	end)

	it("电击期间和免疫期内重复电击都被拒绝", function()
		local z = newZombie()
		ZombieCombat.applyStun(z, NOW)

		local ok, reason = ZombieCombat.applyStun(z, NOW + 1)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.ALREADY_STUNNED)

		ok, reason = ZombieCombat.applyStun(z, NOW + 6.49)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.CONTROL_IMMUNE)

		ok, reason = ZombieCombat.applyStun(z, NOW + 6.5)
		expect(ok).toBe(true)
		expect(reason).toBe(Reason.STUNNED)
	end)

	it("倒地中不能电击，死亡中也不能电击", function()
		local z = newZombie()
		knockDown(z, NOW)
		local ok, reason = ZombieCombat.applyStun(z, NOW)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.NOT_ACTIVE)

		ZombieCombat.tick(z, NOW + 4, { respawnSeconds = 6, noZombieCanAct = false })
		ok, reason = ZombieCombat.applyStun(z, NOW + 5)
		expect(ok).toBe(false)
		expect(reason).toBe(Reason.NOT_ACTIVE)
	end)
end)

describe("扑咬前摇打断", function()
	it("前摇窗口内被武器命中：打断并进入正常扑咬冷却", function()
		local z = newZombie()
		expect(ZombieCombat.beginWindup(z, NOW)).toBe(true)
		local result = ZombieCombat.applyDamage(z, PISTOL_DAMAGE, NOW + 0.3)
		expect(result.interruptedWindup).toBe(true)
		expect(result.biteCooldownUntil).toBe(NOW + 0.3 + BalanceConfig.BiteCooldownSeconds)
		expect(ZombieCombat.hasWindup(z)).toBe(false)
	end)

	it("前摇窗口内被电击：同样打断", function()
		local z = newZombie()
		ZombieCombat.beginWindup(z, NOW)
		local ok, _, detail = ZombieCombat.applyStun(z, NOW + 0.1)
		expect(ok).toBe(true)
		expect(detail.interruptedWindup).toBe(true)
		expect(detail.biteCooldownUntil).toBe(NOW + 0.1 + BalanceConfig.BiteCooldownSeconds)
		expect(ZombieCombat.hasWindup(z)).toBe(false)
	end)

	it("前摇窗口结束后的命中不打断", function()
		local z = newZombie()
		ZombieCombat.beginWindup(z, NOW)
		local result = ZombieCombat.applyDamage(z, PISTOL_DAMAGE, NOW + BalanceConfig.BiteWindupSeconds + 0.01)
		expect(result.interruptedWindup).toBe(false)
		expect(result.biteCooldownUntil).toBeNil()
	end)

	it("倒地/电击中的丧尸不能开始前摇，cancelWindup 可主动清除", function()
		local z = newZombie()
		ZombieCombat.applyStun(z, NOW)
		expect(ZombieCombat.beginWindup(z, NOW + 0.1)).toBe(false)

		local other = newZombie()
		expect(ZombieCombat.beginWindup(other, NOW)).toBe(true)
		expect(ZombieCombat.hasWindup(other)).toBe(true)
		ZombieCombat.cancelWindup(other)
		expect(ZombieCombat.hasWindup(other)).toBe(false)
	end)
end)

describe("移动速度", function()
	it("ACTIVE 使用调用方速度，倒地 4，死亡 0，电击 0", function()
		local z = newZombie()
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW, 18)).toBe(18)

		ZombieCombat.applyStun(z, NOW)
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW, 18)).toBe(0)
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW + 1.5, 18)).toBe(18)

		knockDown(z, NOW + 2)
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW + 2, 18)).toBe(4)

		ZombieCombat.tick(z, NOW + 6, { respawnSeconds = 6, noZombieCanAct = false })
		expect(ZombieCombat.moveSpeedFor(BalanceConfig, z, NOW + 6, 18)).toBe(0)
	end)
end)

TestKit.finish()
