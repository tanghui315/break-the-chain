--!strict
-- 客户端入口（GDB V1.1 §20.2）：依次启动输入与 HUD。状态与命中结果全部以服务端下发为准。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local InputController = require(script.Parent.InputController)
local HUDController = require(script.Parent.HUDController)

local controller = InputController.init()
HUDController.init(controller)

print(`[BreakTheChain] client boot {BalanceConfig.Version}`)
