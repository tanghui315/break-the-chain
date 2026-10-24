--!strict
-- 服务端入口（GDB V1.1 §20.2）：先建灰盒地图，再按依赖顺序启动回合循环。
-- CharacterAutoLoads、Remote 校验与每局清理都在 RoundService 内完成。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local GreyboxBuilder = require(script.Parent.world.GreyboxBuilder)
local RoundService = require(script.Parent.RoundService)

GreyboxBuilder.build()
RoundService.start()

print(`[BreakTheChain] server boot {BalanceConfig.Version}; greybox ready, waiting for players`)
