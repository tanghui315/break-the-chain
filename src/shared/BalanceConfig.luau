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
	ExtractionWindowSeconds = 90,

	-- 战斗（§9）
	BiteWindupSeconds = 0.35,
	BiteCooldownSeconds = 4,
	StunDurationSeconds = 0.7,

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
			requiredExtracted = 4,
			mapTier = "LARGE",
		},
	} :: { PlayerCountTier },
}

export type BalanceConfig = typeof(BalanceConfig)

return BalanceConfig
