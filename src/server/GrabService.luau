--!strict
-- 擒抱感染的服务端边界（GDB V1.1 §9A.6，EXP-08 方案 B）：
-- 纯逻辑 Grab 决定开始/完成/解除；本服务只负责冻结双方、公开属性、写回扑咬冷却与埋点。
-- “完成”和“解除”都由 Grab 的单写者状态保证不会双触发。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Grab = require(script.Parent.logic.Grab)
local ParticipantService = require(script.Parent.ParticipantService)
local PlayerStateService = require(script.Parent.PlayerStateService)
local ZombieCombatService = require(script.Parent.ZombieCombatService)

local config: Grab.Config = BalanceConfig :: any
local state = Grab.new(config)
local startedAtByZombie: { [string]: number } = {}

local GrabService = {}

local function characterOf(participantId: string): Model?
	local participant = ParticipantService.getById(participantId)
	if participant == nil then
		return nil
	end
	return participant.character
end

local function rootOf(participantId: string): BasePart?
	local character = characterOf(participantId)
	if character == nil or character.Parent == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function stopVelocity(participantId: string)
	local root = rootOf(participantId)
	if root ~= nil then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function setPairAttributes(humanId: string, zombieId: string, active: boolean)
	local human = characterOf(humanId)
	if human ~= nil then
		human:SetAttribute(Constants.Attribute.Grabbed, if active then true else nil)
	end
	local zombie = characterOf(zombieId)
	if zombie ~= nil then
		zombie:SetAttribute(Constants.Attribute.Grabbing, if active then true else nil)
	end
end

local function freezePair(humanId: string, zombieId: string)
	PlayerStateService.setMovementLocked(humanId, true)
	PlayerStateService.setMovementLocked(zombieId, true)
	stopVelocity(humanId)
	stopVelocity(zombieId)

	for _, id in { humanId, zombieId } do
		local character = characterOf(id)
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid ~= nil then
			humanoid:Move(Vector3.zero, false)
		end
	end
end

local function releasePair(humanId: string, zombieId: string)
	setPairAttributes(humanId, zombieId, false)
	PlayerStateService.setMovementLocked(humanId, false)
	PlayerStateService.setMovementLocked(zombieId, false)
end

local function printResolved(result: string, breakWeapon: string, holdSeconds: number)
	print(
		string.format(
			"[Telemetry] grab_resolved result=%s breakWeapon=%s holdSeconds=%.2f",
			result,
			breakWeapon,
			math.max(0, holdSeconds)
		)
	)
end

function GrabService.reset()
	for zombieId, grab in state.grabs do
		releasePair(grab.humanId, zombieId)
		printResolved("BROKEN", "ROUND_END", 0)
	end
	state = Grab.new(config)
	table.clear(startedAtByZombie)
end

function GrabService.start(attackerId: string, targetId: string, now: number): Grab.BiteResult
	local result = Grab.onBiteHit(config, state, attackerId, targetId, now)
	if result.grabStarted then
		startedAtByZombie[attackerId] = now
		setPairAttributes(targetId, attackerId, true)
		freezePair(targetId, attackerId)
	end
	return result
end

-- 返回本 tick 完成的擒抱；调用方负责把它们送入 ChaseRound.onBite（感染）。
function GrabService.tick(now: number): { Grab.CompletedGrab }
	local completed = Grab.tick(state, now)
	for _, grab in completed do
		local startedAt = startedAtByZombie[grab.zombieId]
		startedAtByZombie[grab.zombieId] = nil
		releasePair(grab.humanId, grab.zombieId)
		printResolved("INFECTED", "none", if startedAt ~= nil then now - startedAt else config.GrabSeconds)
	end
	return completed
end

-- 枪械/近战/电击命中正在擒抱的丧尸：立即解除，人类获得防扑咬保护，丧尸进入扑咬冷却（§9A.6）。
function GrabService.breakOnZombieHit(zombieId: string, now: number, breakWeapon: string): Grab.BreakResult
	local startedAt = startedAtByZombie[zombieId]
	-- §6.2 / D2：零号擒抱被解除后按倍率收取扑咬冷却。
	local zombieRecord = PlayerStateService.get(zombieId)
	local result = Grab.onZombieHit(state, zombieId, now, zombieRecord ~= nil and zombieRecord.isRoot == true)
	if not result.broken then
		return result
	end

	startedAtByZombie[zombieId] = nil
	local humanId = result.humanId
	if humanId ~= nil then
		releasePair(humanId, zombieId)
	end
	printResolved("BROKEN", breakWeapon, if startedAt ~= nil then now - startedAt else 0)

	local record = PlayerStateService.get(zombieId)
	if record ~= nil then
		if result.biteCooldownUntil ~= nil then
			record.biteCooldownUntil = result.biteCooldownUntil
		end
		record.windupStartedAt = nil
		record.windupConsumed = true
	end
	ZombieCombatService.cancelWindup(zombieId)
	return result
end

function GrabService.removeParticipant(participantId: string)
	local removed = Grab.removeParticipant(state, participantId)
	for _, grab in removed do
		startedAtByZombie[grab.zombieId] = nil
		releasePair(grab.humanId, grab.zombieId)
		printResolved("BROKEN", "LEAVE", 0)
	end
end

function GrabService.clearAll()
	for zombieId, grab in state.grabs do
		releasePair(grab.humanId, zombieId)
		printResolved("BROKEN", "ROUND_END", 0)
	end
	state = Grab.new(config)
	table.clear(startedAtByZombie)
end

function GrabService.isGrabbed(participantId: string): boolean
	return Grab.isGrabbed(state, participantId)
end

function GrabService.isBiteImmune(participantId: string, now: number): boolean
	return Grab.isBiteImmune(state, participantId, now)
end

function GrabService.grabTargetOf(zombieId: string): string?
	return Grab.grabTargetOf(state, zombieId)
end

function GrabService.hasGrab(zombieId: string): boolean
	return state.grabs[zombieId] ~= nil
end

return table.freeze(GrabService)
