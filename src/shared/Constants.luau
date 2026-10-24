--!strict
-- 枚举常量（GDB V1.1 §4.1、§7.1、§7.5）。代码中只使用这些枚举，显示文案见 StateLabels。

local Constants = {}

Constants.PlayerState = table.freeze({
	HUMAN = "HUMAN",
	INCUBATING = "INCUBATING",
	INFECTED = "INFECTED",
	UNSTABLE = "UNSTABLE",
	EXTRACTED = "EXTRACTED",
	SPECTATOR = "SPECTATOR",
})

Constants.RoundPhase = table.freeze({
	WAITING = "WAITING",
	PREPARE = "PREPARE",
	OUTBREAK = "OUTBREAK",
	CONTEST = "CONTEST",
	EXTRACTION = "EXTRACTION",
	RESULT = "RESULT",
})

-- 客户端通过 RequestAction 只能发送这些意图（§20.4）
Constants.Action = table.freeze({
	TryBite = "TryBite",
	StartCure = "StartCure",
	TryRelink = "TryRelink",
	StartRelay = "StartRelay",
	StartScan = "StartScan",
	StartExtract = "StartExtract",
	CancelChannel = "CancelChannel",
})

return table.freeze(Constants)
