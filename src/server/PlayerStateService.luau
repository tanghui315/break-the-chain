--!strict
-- 每参与者的服务端运行时记录（GDB V1.1 §7.3、§9.5、§20.9）：阵营、扑咬前摇/冷却、耐力、位置历史。
-- 只发布公开状态：角色属性 BTC_State（A0 中 HUMAN / INCUBATING / INFECTED 全部公开）。
-- 角色重生 / 阵营转换都不重建角色；转换只改属性与 WalkSpeed（§19.5）。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local PositionHistory = require(script.Parent.logic.PositionHistory)
local Stamina = require(script.Parent.logic.Stamina)
local ParticipantService = require(script.Parent.ParticipantService)

export type Record = {
	id: string,
	kind: ParticipantService.ParticipantKind,
	state: Types.PlayerState,
	-- 以下三个字段结构与 BiteRules.AttackerRecord 对齐
	biteCooldownUntil: number?,
	windupStartedAt: number?,
	windupConsumed: boolean,
	-- A0 没有解药，保留字段是为了直接复用 BiteRules 的目标豁免逻辑
	curedImmuneUntil: number?,
	stamina: Stamina.Stamina,
	-- 客户端按住冲刺时持续保留意图：耐力耗尽后恢复过起步阈值会自动续跑。
	sprintWanted: boolean,
	-- §9A.6：擒抱双方速度归零；由 GrabService 写入，优先级高于战斗速度。
	movementLocked: boolean,
	-- §9A.3：丧尸战斗生命状态给出的速度覆盖（倒地 4 / 电击 0 / 死亡 0）；ACTIVE 时为 nil。
	combatSpeed: number?,
	history: PositionHistory.History,
	lastHistoryAt: number,
	lastStaminaPublishAt: number,
}

-- BalanceConfig 是 sealed 表且字段是纯模块声明类型的超集；在调用边界收窄一次即可。
-- （纯模块的 Config 只声明“本模块用到的字段”，见各模块头注释。）
local staminaConfig: Stamina.Config = BalanceConfig :: any
local historyConfig: PositionHistory.Config = BalanceConfig :: any

local records: { [string]: Record } = {}

local PlayerStateService = {}

local STAMINA_PUBLISH_INTERVAL = 1 / 10

function PlayerStateService.reset()
	table.clear(records)
end

function PlayerStateService.createFor(participant: ParticipantService.Participant): Record
	local record: Record = {
		id = participant.id,
		kind = participant.kind,
		state = "HUMAN",
		biteCooldownUntil = nil,
		windupStartedAt = nil,
		windupConsumed = true,
		curedImmuneUntil = nil,
		stamina = Stamina.new(staminaConfig),
		sprintWanted = false,
		movementLocked = false,
		combatSpeed = nil,
		history = PositionHistory.new(historyConfig),
		lastHistoryAt = -math.huge,
		lastStaminaPublishAt = -math.huge,
	}
	records[participant.id] = record
	PlayerStateService.applyVisual(record)
	return record
end

function PlayerStateService.get(id: string): Record?
	return records[id]
end

function PlayerStateService.records(): { [string]: Record }
	return records
end

function PlayerStateService.remove(id: string)
	records[id] = nil
end

function PlayerStateService.stateFor(id: string): Types.PlayerState?
	local record = records[id]
	if record == nil then
		return nil
	end
	return record.state
end

-- 公共移动速度（性别/耐力/断联档位），不含战斗覆盖与擒抱锁。
function PlayerStateService.baseSpeedFor(record: Record): number
	if record.state == "HUMAN" then
		return Stamina.speedFor(staminaConfig, record.stamina)
	elseif record.state == "INFECTED" then
		return BalanceConfig.Greybox.ZombieRunSpeed
	elseif record.state == "UNSTABLE" then
		return BalanceConfig.Greybox.UnstableRunSpeed
	end
	return BalanceConfig.Greybox.HumanWalkSpeed
end

-- HUMAN 用耐力速度；INCUBATING 在公开尸变过渡期间仍按人类步行；INFECTED 用丧尸奔跑速度。
-- 战斗状态与擒抱覆盖优先：DEAD / STUNNED / 擒抱 → 0，DOWNED → 4（§9A.3、§9A.6）。
function PlayerStateService.speedFor(record: Record): number
	if record.movementLocked then
		return 0
	end
	local combatSpeed = record.combatSpeed
	if combatSpeed ~= nil then
		return combatSpeed
	end
	return PlayerStateService.baseSpeedFor(record)
end

-- 锁定引擎死亡（§9A.3、§9A.5）：生命值只存在于 ZombieCombat，不使用 Humanoid.Health；
-- 同时禁止引擎把角色拆成布娃娃（BreakJointsOnDeath）。
function PlayerStateService.prepareCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	humanoid.BreakJointsOnDeath = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
end

-- 倒地只能爬行、电击/死亡不能移动，因此这些战斗状态也禁用跳跃；擒抱锁优先。
local function applyJumpLock(record: Record, humanoid: Humanoid)
	local locked = record.movementLocked
	if not locked then
		local combatSpeed = record.combatSpeed
		locked = combatSpeed ~= nil and combatSpeed <= BalanceConfig.DownedMoveSpeed
	end
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not locked)
end

-- 把公开状态与速度应用到当前角色。角色尚未生成（或刚被销毁）时静默跳过，等 CharacterAdded 再调用。
function PlayerStateService.applyVisual(record: Record)
	local participant = ParticipantService.getById(record.id)
	if participant == nil or participant.character == nil then
		return
	end

	local character = participant.character
	PlayerStateService.prepareCharacter(character)
	character:SetAttribute(Constants.Attribute.State, record.state)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		applyJumpLock(record, humanoid)
		humanoid.WalkSpeed = PlayerStateService.speedFor(record)
	end
end

function PlayerStateService.applySpeed(record: Record)
	local participant = ParticipantService.getById(record.id)
	if participant == nil or participant.character == nil then
		return
	end
	local humanoid = participant.character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoid.WalkSpeed = PlayerStateService.speedFor(record)
	end
end

-- §9A.6：擒抱期间双方不能移动（服务端速度权威；客户端仅表现为按键无位移）。
function PlayerStateService.setMovementLocked(id: string, locked: boolean)
	local record = records[id]
	if record == nil or record.movementLocked == locked then
		return
	end
	record.movementLocked = locked
	if locked then
		record.sprintWanted = false
		Stamina.setSprintIntent(record.stamina, false)
	end
	local participant = ParticipantService.getById(id)
	if participant ~= nil and participant.character ~= nil then
		local humanoid = participant.character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			if locked then
				humanoid:Move(Vector3.zero, false)
			end
			applyJumpLock(record, humanoid)
			humanoid.WalkSpeed = PlayerStateService.speedFor(record)
		end
	end
end

-- §9A.3：由 ZombieCombatService 每 tick 写入；nil 表示恢复 baseSpeedFor。
function PlayerStateService.setCombatSpeed(id: string, speed: number?)
	local record = records[id]
	if record == nil or record.combatSpeed == speed then
		return
	end
	record.combatSpeed = speed
	local participant = ParticipantService.getById(id)
	if participant ~= nil and participant.character ~= nil then
		local humanoid = participant.character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			applyJumpLock(record, humanoid)
		end
	end
	PlayerStateService.applySpeed(record)
end

-- 状态只由服务端状态机写入。非 HUMAN 立即取消冲刺意图并重设速度。
function PlayerStateService.setState(id: string, state: Types.PlayerState)
	local record = records[id]
	if record == nil or record.state == state then
		return
	end

	record.state = state
	-- 战斗覆盖只属于丧尸生命状态；主状态改变时交给 ZombieCombatService 下一次同步重建。
	record.combatSpeed = nil
	if state ~= "HUMAN" then
		record.sprintWanted = false
		Stamina.setSprintIntent(record.stamina, false)
	end
	if state == "INFECTED" then
		-- 尸变完成后旧的未提交前摇没有意义，清掉避免冷却补收逻辑误判。
		record.windupStartedAt = nil
		record.windupConsumed = true
	end
	PlayerStateService.applyVisual(record)
	PlayerStateService.publishStamina(record, workspace:GetServerTimeNow(), true)
end

-- 耐力是公开信息（冲刺本来就能被看见），以 ≤10 Hz 写入真人玩家的 BTC_Stamina（0..1）。
function PlayerStateService.publishStamina(record: Record, now: number, force: boolean)
	local participant = ParticipantService.getById(record.id)
	if participant == nil or participant.player == nil then
		return
	end
	if not force and now - record.lastStaminaPublishAt < STAMINA_PUBLISH_INTERVAL then
		return
	end
	record.lastStaminaPublishAt = now

	local maximum = BalanceConfig.Greybox.SprintMaxSeconds
	local ratio = if maximum > 0 then math.clamp(record.stamina.value / maximum, 0, 1) else 0
	participant.player:SetAttribute(Constants.Attribute.Stamina, ratio)
end

-- 重生 / 重新生成后重新发布公开状态与耐力，并让客户端重新拿到 ParticipantId。
function PlayerStateService.restore(record: Record)
	PlayerStateService.applyVisual(record)
	PlayerStateService.publishStamina(record, workspace:GetServerTimeNow(), true)
end

return table.freeze(PlayerStateService)
