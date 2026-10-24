--!strict
-- 服务端数据模型的类型定义（GDB V1.1 §20.3、§20.9）。
-- 这些类型描述的数据只存在于服务端内存中；客户端只能收到按权限裁剪后的视图。

export type ParticipantId = string -- "U:<userId>" 或 "B:<botIndex>:<roundId>"

export type PlayerState = "HUMAN" | "INCUBATING" | "INFECTED" | "UNSTABLE" | "EXTRACTED" | "SPECTATOR"

export type RoundPhase = "WAITING" | "PREPARE" | "OUTBREAK" | "CONTEST" | "EXTRACTION" | "RESULT"

export type LateJoinRole = "HUMAN" | "INFECTED" | "SPECTATOR"

export type PlayerRoundState = {
	participantId: ParticipantId,
	roundId: string,
	state: PlayerState,
	infectionEpisodeId: string?,
	isRoot: boolean,
	parentEpisodeId: string?,
	rootSeedId: string?,
	connectedChildren: { [string]: boolean },
	version: number,
	incubationEndsAt: number?,
	unstableEndsAt: number?,
	curedImmuneUntil: number?,
	biteCooldownUntil: number?,
	carriedCureId: string?,
	isInsideExtractionZone: boolean,
}

export type RoundContext = {
	roundId: string,
	state: RoundPhase,
	startedAt: number,
	endsAt: number,
	phaseEndsAt: number?,
	initialPlayerCount: number,
	initialSeedCount: number,
	requiredPowerRelays: number,
	requiredExtractedCount: number,
	extractedParticipantIds: { [string]: boolean },
	isPractice: boolean,
	lateJoinHumanUntil: number,
	actionSequence: number,
	winner: string?,
}

return {}
