--!strict
-- Server → Client 事件名（GDB V1.1 §20.7）。
-- Public 事件经 PublicMatchEvent 广播，只携带公开字段；Private 事件经 PrivatePlayerEvent 用 FireClient 定向发送。

local PublicEventTypes = {}

PublicEventTypes.Public = table.freeze({
	OutbreakStarted = "OutbreakStarted",
	InfectionTurning = "InfectionTurning",
	InfectionRevealed = "InfectionRevealed",
	ChainCutNearby = "ChainCutNearby",
	ExtractionOpened = "ExtractionOpened",
	RoundResult = "RoundResult",
})

PublicEventTypes.Private = table.freeze({
	YouAreIncubating = "YouAreIncubating",
	YouAreUnstable = "YouAreUnstable",
	ScannerResults = "ScannerResults",
	CureChannelProgress = "CureChannelProgress",
	BranchWarning = "BranchWarning",
})

return table.freeze(PublicEventTypes)
