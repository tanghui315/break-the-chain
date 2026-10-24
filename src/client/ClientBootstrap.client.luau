--!strict
-- 客户端入口。目前只做启动自检；各 Controller（GDB V1.1 §20.2）在 Gate A0 起逐个接入。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)

print(`[BreakTheChain] client boot {BalanceConfig.Version}`)
