--!strict
-- 开局规划与人数相关规则（GDB V1.1 §5.1、§5.2、§12.3）。
-- 纯逻辑：不引用任何 Roblox 全局对象，配置通过参数传入，可在 Lune 中测试。

export type Tier = {
	min: number,
	max: number,
	roundSeconds: number,
	seedCount: number,
	powerRelays: number,
	cures: number,
	requiredExtracted: number,
	mapTier: string,
}

-- 只声明本模块用到的字段，BalanceConfig 在结构上满足它
export type Config = {
	MaxPlayers: number,
	MinPlayersRanked: number,
	BotFillTarget: number,
	LateJoinHumanWindowSeconds: number,
	ExtractionWindowSeconds: number,
	HubMinImpact: number,
	HubRelativeShare: number,
	PlayerCountTiers: { Tier },
}

export type RoundPlan = {
	realCount: number,
	botCount: number,
	participantCount: number,
	isPractice: boolean,
	tier: Tier,
}

export type LateJoinRole = "HUMAN" | "INFECTED" | "SPECTATOR"

local MatchConfig = {}

local function findTier(config: Config, participantCount: number): Tier?
	for _, tier in config.PlayerCountTiers do
		if participantCount >= tier.min and participantCount <= tier.max then
			return tier
		end
	end
	return nil
end

-- 根据开局时的真人数冻结一局的人数参数。
-- 真人 ≥ MinPlayersRanked 为正式局，不补 Bot；真人 1～3 名时 Bot 补位到 BotFillTarget，进行练习局（D4）。
-- forceBotFill 仅供开发压测使用（§20.9 DebugForceBotFill），把参与者补到该数量。
function MatchConfig.planRound(config: Config, realCount: number, forceBotFill: number?): RoundPlan?
	if realCount < 1 or realCount > config.MaxPlayers or realCount % 1 ~= 0 then
		return nil
	end

	local isPractice = realCount < config.MinPlayersRanked
	local target = if isPractice then config.BotFillTarget else realCount
	if forceBotFill then
		target = math.max(target, forceBotFill)
	end
	target = math.min(target, config.MaxPlayers)

	local botCount = math.max(0, target - realCount)
	local participantCount = realCount + botCount
	local tier = findTier(config, participantCount)
	if not tier then
		return nil
	end

	return {
		realCount = realCount,
		botCount = botCount,
		participantCount = participantCount,
		-- 有 Bot 参与的局一律不计正式战绩（§5.2）
		isPractice = isPractice or botCount > 0,
		tier = tier,
	}
end

-- 对局开始后加入的真人以什么身份进入（D5）。
function MatchConfig.lateJoinRole(config: Config, elapsedSeconds: number, roundSeconds: number): LateJoinRole
	if elapsedSeconds < config.LateJoinHumanWindowSeconds then
		return "HUMAN"
	elseif elapsedSeconds < roundSeconds - config.ExtractionWindowSeconds then
		return "INFECTED"
	end
	return "SPECTATOR"
end

-- 扫描中“关键枢纽”的 branchImpact 阈值（D3）。
function MatchConfig.hubThreshold(config: Config, publicInfectedCount: number): number
	return math.max(config.HubMinImpact, math.ceil(config.HubRelativeShare * publicInfectedCount))
end

return MatchConfig
