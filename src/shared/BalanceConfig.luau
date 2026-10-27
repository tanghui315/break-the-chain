--!strict
-- 可公开的平衡参数（GDB V1.1 §24.2、§24.4）。
-- 这里的值会复制给所有客户端：秘密身份、反作弊阈值、感染树一律不得放进 Shared。
-- 本文件是参数键名的唯一来源，GDB §0.3 表格须与之保持一致。

export type PlayerCountTier = {
	min: number,
	max: number,
	roundSeconds: number,
	seedCount: number,
	powerRelays: number,
	cures: number,
	pistols: number,
	tasers: number,
	ammoCrates: number,
	zombieRespawnSeconds: number,
	requiredExtracted: number,
	mapTier: "SMALL" | "MEDIUM" | "LARGE",
}

local BalanceConfig = {
	Version = "GDB-1.1.0",

	-- 人数与开局（§5）
	MaxPlayers = 24,
	MinPlayersRanked = 4,
	BotFillTarget = 6,
	LateJoinHumanWindowSeconds = 60,
	LobbyWaitSeconds = 30,
	PrepareSeconds = 20,

	-- 感染与零号（§6、§7）
	IncubationSeconds = 5,
	IncubationSecret = false,
	SeedMethod = "RANDOM_BREACH" :: "RANDOM_BREACH" | "NPC",
	MaxOutbreakNPCs = 2,
	RootBiteCooldownMultiplier = 1.5,
	RootRelinkHoldMultiplier = 1.5,

	-- 断联、治愈、撤离（§10、§11、§13）
	DisconnectSeconds = 8,
	ReconnectHoldSeconds = 1.0,
	CureChannelSeconds = 2.0,
	CuredImmunitySeconds = 7,
	CureRetryCooldownSeconds = 1.5, -- §10.1：失败/取消的治愈尝试后的短冷却，防止刷交互
	ExtractionWindowSeconds = 90,
	ContainmentStableSeconds = 5, -- §6.3：遏制胜利前的 5 秒稳定性复核窗口

	-- 战斗（§9）
	BiteWindupSeconds = 0.35,
	BiteCooldownSeconds = 4,
	StunDurationSeconds = 0.7,

	-- 轻射击对抗层（§9A.9）。全部为 BASELINE / EXPERIMENT 起点，进入实测后按 §9A.5 的检查项调整。
	WeaponsEnabled = true,
	ZombieMaxHealth = 100,
	ZombieRegenDelaySeconds = 4,
	ZombieRegenPerSecond = 25,
	RootHealthMultiplier = 1.25, -- 零号 125 生命：手枪 5 发（普通丧尸 4 发），只多一发
	DownedSeconds = 4,
	DownedMoveSpeed = 4,
	LastZombieRespawnCapSeconds = 3,
	RespawnMinDistanceFromHuman = 60,
	RespawnMinDistanceFromExtraction = 80,
	RespawnProtectionSeconds = 2,
	ControlImmunitySeconds = 5,
	StunSeconds = 1.5,
	BiteMode = "GRAB" :: "INSTANT" | "GRAB",
	GrabSeconds = 1.0,
	GrabEscapeImmunitySeconds = 1.5,
	GunshotPingSeconds = 2.5,
	TouchAimAssistDegrees = 6,
	ShotOriginToleranceStuds = 4,
	AmmoCrateRefreshSeconds = 90,

	-- 武器数值（§9A.4）。Melee.ConeDegrees 是“前方 ±”的半角；枪械全部为命中扫描，伤害按单发计算。
	Weapons = {
		Melee = {
			Damage = 20,
			Range = 6,
			ConeDegrees = 60,
			FireIntervalSeconds = 0.9,
			KnockbackStuds = 6,
		},
		Pistol = {
			Damage = 25,
			Range = 80,
			FireIntervalSeconds = 0.35,
			MagazineSize = 6,
			ReserveAmmo = 6,
			ReloadSeconds = 1.5,
			KnockbackStuds = 0, -- GDB §9A.4 未给手枪击退，按 0 落地
		},
		Taser = {
			Damage = 0,
			Range = 12,
			Charges = 2,
			CooldownSeconds = 8, -- 两发之间的冷却
			StunSeconds = 1.5,
			KnockbackStuds = 0,
		},
		-- EXP-07：8 studs 内 60，20 studs 线性衰减到 0，击退 10，4 发。
		-- GDB 未给霰弹枪射击间隔与备弹，取 1.0 秒 / 无备弹（A0.5 不接入玩法）。
		Shotgun = {
			Damage = 60,
			Range = 20,
			FullDamageRangeStuds = 8,
			FireIntervalSeconds = 1,
			MagazineSize = 4,
			ReserveAmmo = 0,
			ReloadSeconds = 1.5,
			KnockbackStuds = 10,
		},
	},

	-- 扫描（§12）
	ScanActiveSeconds = 10,
	ScanCooldownSeconds = 45,
	HubMinImpact = 3,
	HubRelativeShare = 0.2,

	DefaultPerspective = "ThirdPerson",

	-- 灰盒起步数值（§24.4、§9.5），不是平衡结论
	Greybox = {
		HumanWalkSpeed = 16,
		HumanSprintSpeed = 23,
		SprintMaxSeconds = 5,
		StaminaRegenRatio = 0.5,
		SprintMinStartSeconds = 0.5,
		ZombieRunSpeed = 18,
		UnstableRunSpeed = 17,
		LungeDistance = 9,
		LungeSeconds = 0.25,
		BiteMissRecoverySeconds = 0.6,
		-- §9.2：扑空后的后摇期间丧尸移动速度减半。
		BiteMissRecoverySpeedMultiplier = 0.5,
		BiteCommitSlackSeconds = 0.15,
		BiteRange = 5.5,
		BiteTolerance = 1.5,
		BiteConeDegrees = 70,
		HistorySeconds = 1,
		HistoryHz = 20,
		MaxRewindSeconds = 0.25,
		CureRange = 8,
		RelinkRange = 8,
		RelayRange = 7,
		ExtractZoneDiameter = 16,
		ExtractHoldSeconds = 2,
		ScanRadius = 50,
	},

	-- Gate A0 纯追逐原型（无治愈/感染树）的回合参数
	A0 = {
		PrepareSeconds = 20, -- 与顶层 PrepareSeconds 保持一致
		RoundSeconds = 180,
		SeedCount = 1,
	},

	PlayerCountTiers = {
		{
			min = 4,
			max = 7,
			roundSeconds = 360,
			seedCount = 1,
			powerRelays = 1,
			cures = 1,
			pistols = 1,
			tasers = 1,
			ammoCrates = 1,
			zombieRespawnSeconds = 6,
			requiredExtracted = 1,
			mapTier = "SMALL",
		},
		{
			min = 8,
			max = 15,
			roundSeconds = 420,
			seedCount = 1,
			powerRelays = 2,
			cures = 2,
			pistols = 3,
			tasers = 1,
			ammoCrates = 2,
			zombieRespawnSeconds = 8,
			requiredExtracted = 2,
			mapTier = "MEDIUM",
		},
		{
			min = 16,
			max = 24,
			roundSeconds = 480,
			seedCount = 2,
			powerRelays = 3,
			cures = 3,
			pistols = 5,
			tasers = 2,
			ammoCrates = 3,
			zombieRespawnSeconds = 10,
			requiredExtracted = 4,
			mapTier = "LARGE",
		},
	} :: { PlayerCountTier },
}

export type BalanceConfig = typeof(BalanceConfig)

return BalanceConfig
