--!strict
-- 冲刺意图与耐力推进（GDB V1.1 §9.3、§24.4）。只对 HUMAN 生效；服务端权威，客户端只发意图。
-- Bot 与真人共用同一套 Stamina（§20.9），Bot 只是不发布 BTC_Stamina 属性。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local PlayerStateService = require(script.Parent.PlayerStateService)
local Stamina = require(script.Parent.logic.Stamina)

local lastStepAt = 0

local MovementService = {}

function MovementService.reset()
	lastStepAt = workspace:GetServerTimeNow()
end

function MovementService.setSprintIntent(participantId: string, wantSprint: boolean)
	local record = PlayerStateService.get(participantId)
	if record == nil then
		return
	end
	if record.state ~= "HUMAN" then
		record.sprintWanted = false
		return
	end
	record.sprintWanted = wantSprint
	Stamina.setSprintIntent(record.stamina, wantSprint)
	PlayerStateService.applySpeed(record)
	PlayerStateService.publishStamina(record, workspace:GetServerTimeNow(), true)
end

-- 每帧推进耐力。dt 上限 0.25 秒，避免服务器卡顿后一帧掏空整条耐力条。
function MovementService.step(now: number)
	local dt = math.clamp(now - lastStepAt, 0, 0.25)
	lastStepAt = now

	for _, record in PlayerStateService.records() do
		if record.state == "HUMAN" then
			-- 持续按住冲刺时，耐力恢复到起步阈值后自动续跑（Stamina 内部会检查阈值）。
			if record.sprintWanted and not record.stamina.sprinting then
				Stamina.setSprintIntent(record.stamina, true)
			end
			Stamina.step(record.stamina, dt)
			PlayerStateService.applySpeed(record)
			PlayerStateService.publishStamina(record, now, false)
		elseif record.stamina.sprinting then
			-- 尸变 / 观战等状态不允许保留冲刺意图
			Stamina.setSprintIntent(record.stamina, false)
			PlayerStateService.applySpeed(record)
		end
	end
end

-- 供 BotService 读取当前是否在冲刺（只用于移动决策，不改变规则）。
function MovementService.isSprinting(participantId: string): boolean
	local record = PlayerStateService.get(participantId)
	if record == nil then
		return false
	end
	return record.stamina.sprinting and record.stamina.value > 0
end

function MovementService.staminaRatio(participantId: string): number
	local record = PlayerStateService.get(participantId)
	if record == nil then
		return 0
	end
	local maximum = BalanceConfig.Greybox.SprintMaxSeconds
	if maximum <= 0 then
		return 0
	end
	return math.clamp(record.stamina.value / maximum, 0, 1)
end

return table.freeze(MovementService)
