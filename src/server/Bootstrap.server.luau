--!strict
-- 服务端入口。目前只做启动自检，确认 Rojo 同步与模块路径正确；各 Service 在 Gate A0 起逐个接入。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local MatchConfig = require(script.Parent.logic.MatchConfig)

local plan = MatchConfig.planRound(BalanceConfig, 1)
assert(plan, "MatchConfig.planRound 无法为 1 名真人生成练习局")

print(
	`[BreakTheChain] server boot {BalanceConfig.Version}; 1 名真人 → {plan.participantCount} 名参与者`
		.. `（Bot {plan.botCount}，练习局 {plan.isPractice}，{plan.tier.mapTier}）`
)
