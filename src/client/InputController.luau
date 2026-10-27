--!strict
-- 客户端能力输入（GDB V1.1 §9.2、§9.6、§9A.4、§19.5）：ContextActionService 自定义绑定，不用 Tool。
-- HUMAN：短棍/手枪/电击枪，左键开火（手机自动生成按钮）、R 换弹、1/2/3 选武器、手机循环按钮。
-- INFECTED：保留“开始前摇 → 本地短冲刺 → 提交 TryBite”的意图流；倒地/电击/死亡/擒抱中禁止。
-- 命中与伤害全部由服务端复算；本地只做射速节流、目标提示与击退表现。

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local InteractTarget = require(ReplicatedStorage.Shared.InteractTarget)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)

local BITE_ACTION = "BTC_Bite"
local SPRINT_ACTION = "BTC_Sprint"
local FIRE_ACTION = "BTC_Fire"
local RELOAD_ACTION = "BTC_Reload"
local WEAPON_ACTION = "BTC_Weapon"
local INTERACT_ACTION = "BTC_Interact"
local HIVE_MARK_ACTION = "BTC_HiveMark"
local HIVE_RALLY_ACTION = "BTC_HiveRally"

export type Controller = {
	getParticipantId: () -> string?,
	getCooldownUntil: () -> number,
	getState: () -> string?,
	getCombat: () -> string?,
	isBiting: () -> boolean,
	isSprinting: () -> boolean,
	isGrabbed: () -> boolean,
	getWeapon: () -> string,
	getMagazine: () -> number,
	getReserve: () -> number,
	getTaserCharges: () -> number,
	isReloading: () -> boolean,
	getInteractNotice: () -> (string?, number),
}

local player = Players.LocalPlayer
local requestAction: RemoteEvent? = nil

local participantId: string? = nil
local currentState: string? = nil
local currentCombat: string? = "ACTIVE"
local grabbed = false
local grabbing = false
local cooldownUntil = 0
local biteActive = false
local sprintHeld = false
local lastFireAtByWeapon: { [string]: number } = {}
-- Gate A-2b：交互（解药 / 重连）。按住开始读条，释放发送 CancelChannel（服务端累计有效时间）。
local carryingCure = false
local interactActive = false
local interactNoticeText: string? = nil
local interactNoticeAt = -math.huge

local weapon = "Melee"
local pistolOwned = false
local pistolMagazine = 0
local pistolReserve = 0
local pistolReloading = false
local taserOwned = false
local taserCharges = 0

local stateConnection: RBXScriptConnection? = nil
local combatConnection: RBXScriptConnection? = nil
local grabbedConnection: RBXScriptConnection? = nil
local grabbingConnection: RBXScriptConnection? = nil
local rootConnection: RBXScriptConnection? = nil
-- §6.4 EXP-09：本人是否零号（公开 BTC_Root 属性），决定是否绑定母巢按键。
local isRootSelf = false

local biteBound = false
local sprintBound = false
local fireBound = false
local reloadBound = false
local weaponBound = false
local interactBound = false
local hiveBound = false

local InputController = {}

local function sendAction(payload: { [string]: any })
	if requestAction ~= nil then
		requestAction:FireServer(payload)
	end
end

local function sendSprint(want: boolean)
	sendAction({ action = Constants.Action.SetSprint, sprint = want })
end

local function canActAsZombie(): boolean
	return currentState == "INFECTED"
		and (currentCombat == "ACTIVE" or currentCombat == nil)
		and not grabbed
		and not grabbing
end

local function canUseHumanWeapons(): boolean
	return currentState == "HUMAN" and not grabbed
end

local function rangeFor(selected: string): number
	if selected == "Pistol" then
		return BalanceConfig.Weapons.Pistol.Range
	elseif selected == "Taser" then
		return BalanceConfig.Weapons.Taser.Range
	end
	return BalanceConfig.Weapons.Melee.Range
end

local function fireIntervalFor(selected: string): number
	if selected == "Pistol" then
		return BalanceConfig.Weapons.Pistol.FireIntervalSeconds
	elseif selected == "Taser" then
		return BalanceConfig.Weapons.Taser.CooldownSeconds
	end
	return BalanceConfig.Weapons.Melee.FireIntervalSeconds
end

local function findNearestHuman(origin: Vector3, forward: Vector3): string?
	local maxDistance = BalanceConfig.Greybox.BiteRange + 2 * BalanceConfig.Greybox.BiteTolerance
	local minimumDot = math.cos(math.rad(BalanceConfig.Greybox.BiteConeDegrees))
	local bestId: string? = nil
	local bestDistance = math.huge

	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") and child ~= player.Character then
			local id = child:GetAttribute(Constants.Attribute.ParticipantId)
			local state = child:GetAttribute(Constants.Attribute.State)
			if
				type(id) == "string"
				and state == "HUMAN"
				and child:GetAttribute(Constants.Attribute.Grabbed) ~= true
			then
				local root = child:FindFirstChild("HumanoidRootPart")
				if root ~= nil and root:IsA("BasePart") then
					local delta = root.Position - origin
					local horizontal = Vector3.new(delta.X, 0, delta.Z)
					local distance = horizontal.Magnitude
					if
						distance > 0.001
						and distance <= maxDistance
						and horizontal.Unit:Dot(forward) >= minimumDot
						and distance < bestDistance
					then
						bestId = id
						bestDistance = distance
					end
				end
			end
		end
	end

	return bestId
end

-- §9A.7：客户端只给 6° 辅助瞄准提示；服务端仍按同一锥角与几何独立复核。
local function findNearestZombie(origin: Vector3, forward: Vector3, maxDistance: number): string?
	local minimumDot = math.cos(math.rad(BalanceConfig.TouchAimAssistDegrees))
	local bestId: string? = nil
	local bestDistance = math.huge

	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") and child ~= player.Character then
			local id = child:GetAttribute(Constants.Attribute.ParticipantId)
			local state = child:GetAttribute(Constants.Attribute.State)
			local combat = child:GetAttribute(Constants.Attribute.Combat)
			local protected = child:GetAttribute(Constants.Attribute.Protected)
			if
				type(id) == "string"
				and (state == "INFECTED" or state == "UNSTABLE")
				and (combat == "ACTIVE" or combat == nil)
				and protected ~= true
			then
				local root = child:FindFirstChild("HumanoidRootPart")
				if root ~= nil and root:IsA("BasePart") then
					local delta = root.Position - origin
					local distance = delta.Magnitude
					if
						distance > 0.001
						and distance <= maxDistance
						and delta.Unit:Dot(forward) >= minimumDot
						and distance < bestDistance
					then
						bestId = id
						bestDistance = distance
					end
				end
			end
		end
	end

	return bestId
end

local function setInteractNotice(text: string)
	interactNoticeText = text
	interactNoticeAt = Workspace:GetServerTimeNow()
end

local function hasCarriedCure(character: Model?): boolean
	if character == nil then
		return false
	end
	return character:FindFirstChild("BTC_Cure", true) ~= nil
end

type TargetMode = "CURE" | "RELINK"

-- 只使用公开属性（状态、战斗状态、BTC_Root）挑选交互目标；服务端会重新校验一切。
local function selectInteractTarget(mode: TargetMode, range: number): InteractTarget.Selection
	local character = player.Character
	if character == nil then
		return { id = nil, distance = nil, rootBlocked = false }
	end
	local myRoot = character:FindFirstChild("HumanoidRootPart")
	if myRoot == nil or not myRoot:IsA("BasePart") then
		return { id = nil, distance = nil, rootBlocked = false }
	end

	local candidates: { InteractTarget.Candidate } = {}
	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") and child ~= character then
			local id = child:GetAttribute(Constants.Attribute.ParticipantId)
			local state = child:GetAttribute(Constants.Attribute.State)
			local combat = child:GetAttribute(Constants.Attribute.Combat)
			if type(id) == "string" and state == "INFECTED" then
				local eligible = if mode == "CURE"
					then combat == "ACTIVE" or combat == "DOWNED" or combat == "STUNNED"
					else combat == "ACTIVE" or combat == "STUNNED"
				if eligible then
					local root = child:FindFirstChild("HumanoidRootPart")
					if root ~= nil and root:IsA("BasePart") then
						table.insert(candidates, {
							id = id,
							x = root.Position.X,
							z = root.Position.Z,
							eligible = true,
							isRoot = child:GetAttribute(Constants.Attribute.Root) == true,
						})
					end
				end
			end
		end
	end

	return InteractTarget.selectNearest(
		candidates,
		{ x = myRoot.Position.X, z = myRoot.Position.Z },
		range,
		mode == "RELINK"
	)
end

-- 按住开始读条，释放取消。HUMAN + 解药 → StartCure；UNSTABLE → TryRelink。
local function interactHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		if currentState == "UNSTABLE" then
			local selection = selectInteractTarget("RELINK", BalanceConfig.Greybox.RelinkRange)
			if selection.id ~= nil then
				interactActive = true
				sendAction({ action = Constants.Action.TryRelink, targetId = selection.id })
			else
				setInteractNotice("NO RELINK TARGET")
			end
			return Enum.ContextActionResult.Sink
		elseif currentState == "HUMAN" and carryingCure then
			local selection = selectInteractTarget("CURE", BalanceConfig.Greybox.CureRange)
			if selection.id ~= nil then
				interactActive = true
				sendAction({ action = Constants.Action.StartCure, targetId = selection.id })
			elseif selection.rootBlocked then
				-- §10.2：零号源头不可治愈，提前提示，避免浪费唯一解药。
				setInteractNotice("SOURCE — cure has no effect")
			else
				setInteractNotice("NO CURE TARGET IN RANGE")
			end
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		if interactActive then
			interactActive = false
			sendAction({ action = Constants.Action.CancelChannel })
			return Enum.ContextActionResult.Sink
		end
	end
	return Enum.ContextActionResult.Pass
end

local function startBite()
	if biteActive or not canActAsZombie() then
		return
	end
	if Workspace:GetServerTimeNow() < cooldownUntil then
		return
	end

	local character = player.Character
	if character == nil then
		return
	end
	local initialRoot = character:FindFirstChild("HumanoidRootPart")
	if initialRoot == nil or not initialRoot:IsA("BasePart") then
		return
	end

	biteActive = true
	sendAction({ action = Constants.Action.StartBite })

	task.delay(BalanceConfig.BiteWindupSeconds, function()
		if not biteActive or not canActAsZombie() or player.Character ~= character then
			biteActive = false
			return
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			biteActive = false
			return
		end

		local camera = Workspace.CurrentCamera
		if camera == nil then
			biteActive = false
			return
		end
		local look = camera.CFrame.LookVector
		local horizontal = Vector3.new(look.X, 0, look.Z)
		if horizontal.Magnitude > 0.001 then
			horizontal = horizontal.Unit
		end

		root.AssemblyLinearVelocity = horizontal
				* (BalanceConfig.Greybox.LungeDistance / BalanceConfig.Greybox.LungeSeconds)
			+ Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)

		task.wait(BalanceConfig.Greybox.LungeSeconds)

		if not biteActive or not canActAsZombie() or player.Character ~= character then
			biteActive = false
			return
		end

		local currentRoot = character:FindFirstChild("HumanoidRootPart")
		local targetId: string? = nil
		if currentRoot ~= nil and currentRoot:IsA("BasePart") then
			targetId = findNearestHuman(currentRoot.Position, horizontal)
		end
		sendAction({
			action = Constants.Action.TryBite,
			targetId = targetId,
		})
		biteActive = false
	end)
end

local function biteHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not canActAsZombie() then
		return Enum.ContextActionResult.Pass
	end
	startBite()
	return Enum.ContextActionResult.Sink
end

local function fireHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not canUseHumanWeapons() then
		return Enum.ContextActionResult.Pass
	end

	local now = Workspace:GetServerTimeNow()
	local lastFireAt = lastFireAtByWeapon[weapon] or -math.huge
	if now - lastFireAt < fireIntervalFor(weapon) then
		return Enum.ContextActionResult.Sink
	end

	local character = player.Character
	local camera = Workspace.CurrentCamera
	if character == nil or camera == nil then
		return Enum.ContextActionResult.Sink
	end
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return Enum.ContextActionResult.Sink
	end

	local origin = head.Position
	local direction = camera.CFrame.LookVector
	local targetId = findNearestZombie(origin, direction, rangeFor(weapon))
	sendAction({
		action = Constants.Action.Fire,
		weapon = weapon,
		origin = origin,
		direction = direction,
		targetId = targetId,
	})
	lastFireAtByWeapon[weapon] = now
	return Enum.ContextActionResult.Sink
end

local function reloadHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not canUseHumanWeapons() then
		return Enum.ContextActionResult.Pass
	end
	sendAction({ action = Constants.Action.Reload })
	return Enum.ContextActionResult.Sink
end

local function weaponOptions(): { string }
	local options: { string } = { "Melee" }
	if pistolOwned then
		table.insert(options, "Pistol")
	end
	if taserOwned then
		table.insert(options, "Taser")
	end
	return options
end

local function chooseWeapon(nextWeapon: string)
	if not canUseHumanWeapons() then
		return
	end
	weapon = nextWeapon
	sendAction({ action = Constants.Action.SelectWeapon, weapon = nextWeapon })
end

local function cycleWeapon()
	local options = weaponOptions()
	local currentIndex = table.find(options, weapon) or 1
	chooseWeapon(options[(currentIndex % #options) + 1])
end

local function weaponHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	inputObject: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not canUseHumanWeapons() then
		return Enum.ContextActionResult.Pass
	end

	local key = inputObject.KeyCode
	if key == Enum.KeyCode.One then
		chooseWeapon("Melee")
	elseif key == Enum.KeyCode.Two then
		if pistolOwned then
			chooseWeapon("Pistol")
		end
	elseif key == Enum.KeyCode.Three then
		if taserOwned then
			chooseWeapon("Taser")
		end
	else
		cycleWeapon()
	end
	return Enum.ContextActionResult.Sink
end

local function sprintHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	inputObject: InputObject
): Enum.ContextActionResult
	if currentState ~= "HUMAN" or grabbed then
		return Enum.ContextActionResult.Pass
	end

	if inputObject.UserInputType == Enum.UserInputType.Touch then
		if inputState == Enum.UserInputState.Begin then
			sprintHeld = not sprintHeld
			sendSprint(sprintHeld)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		sprintHeld = true
		sendSprint(true)
		return Enum.ContextActionResult.Sink
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		sprintHeld = false
		sendSprint(false)
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- §6.4 EXP-09：Q 源头标记、F 母巢集结。身份、冷却与条件全部由服务端校验。
local function hiveHandler(
	actionName: string,
	inputState: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if actionName == HIVE_MARK_ACTION then
		sendAction({ action = Constants.Action.RootMark })
	elseif actionName == HIVE_RALLY_ACTION then
		sendAction({ action = Constants.Action.RootRally })
	end
	return Enum.ContextActionResult.Sink
end

local function unbind(actionName: string)
	ContextActionService:UnbindAction(actionName)
end

local function updateBindings()
	local wantHuman = currentState == "HUMAN" and not grabbed
	local wantZombie = canActAsZombie() or currentState == "INFECTED"
	local wantInteract = currentState == "UNSTABLE" or (currentState == "HUMAN" and carryingCure and not grabbed)

	if wantZombie and not biteBound then
		ContextActionService:BindAction(BITE_ACTION, biteHandler, true, Enum.UserInputType.MouseButton1)
		ContextActionService:SetTitle(BITE_ACTION, "BITE")
		ContextActionService:SetPosition(BITE_ACTION, UDim2.new(1, -170, 1, -210))
		biteBound = true
	elseif not wantZombie and biteBound then
		unbind(BITE_ACTION)
		biteBound = false
	end

	if wantHuman and not fireBound then
		ContextActionService:BindAction(FIRE_ACTION, fireHandler, true, Enum.UserInputType.MouseButton1)
		ContextActionService:SetTitle(FIRE_ACTION, "FIRE")
		ContextActionService:SetPosition(FIRE_ACTION, UDim2.new(1, -170, 1, -210))
		fireBound = true
	elseif not wantHuman and fireBound then
		unbind(FIRE_ACTION)
		fireBound = false
	end

	if wantHuman and not reloadBound then
		ContextActionService:BindAction(RELOAD_ACTION, reloadHandler, true, Enum.KeyCode.R)
		ContextActionService:SetTitle(RELOAD_ACTION, "RELOAD")
		ContextActionService:SetPosition(RELOAD_ACTION, UDim2.new(1, -170, 1, -280))
		reloadBound = true
	elseif not wantHuman and reloadBound then
		unbind(RELOAD_ACTION)
		reloadBound = false
	end

	if wantHuman and not weaponBound then
		ContextActionService:BindAction(
			WEAPON_ACTION,
			weaponHandler,
			true,
			Enum.KeyCode.One,
			Enum.KeyCode.Two,
			Enum.KeyCode.Three
		)
		ContextActionService:SetTitle(WEAPON_ACTION, "WEAPON")
		ContextActionService:SetPosition(WEAPON_ACTION, UDim2.new(1, -170, 1, -350))
		weaponBound = true
	elseif not wantHuman and weaponBound then
		unbind(WEAPON_ACTION)
		weaponBound = false
	end

	if wantHuman and not grabbed and not sprintBound then
		ContextActionService:BindAction(SPRINT_ACTION, sprintHandler, true, Enum.KeyCode.LeftShift)
		ContextActionService:SetTitle(SPRINT_ACTION, "SPRINT")
		ContextActionService:SetPosition(SPRINT_ACTION, UDim2.new(0, 20, 1, -210))
		sprintBound = true
	elseif (not wantHuman or grabbed) and sprintBound then
		unbind(SPRINT_ACTION)
		sprintBound = false
	end

	local wantHive = currentState == "INFECTED"
		and isRootSelf
		and Workspace:GetAttribute(Constants.Attribute.HiveEnabled) == true
	if wantHive and not hiveBound then
		ContextActionService:BindAction(HIVE_MARK_ACTION, hiveHandler, true, Enum.KeyCode.Q)
		ContextActionService:SetTitle(HIVE_MARK_ACTION, "MARK")
		ContextActionService:SetPosition(HIVE_MARK_ACTION, UDim2.new(1, -240, 1, -210))
		ContextActionService:BindAction(HIVE_RALLY_ACTION, hiveHandler, true, Enum.KeyCode.F)
		ContextActionService:SetTitle(HIVE_RALLY_ACTION, "RALLY")
		ContextActionService:SetPosition(HIVE_RALLY_ACTION, UDim2.new(1, -240, 1, -280))
		hiveBound = true
	elseif not wantHive and hiveBound then
		unbind(HIVE_MARK_ACTION)
		unbind(HIVE_RALLY_ACTION)
		hiveBound = false
	end

	-- §10.2 / §11.2：按住交互（PC E / 手机自动按钮）。松开即 CancelChannel，由服务端判定是否保留读条。
	if wantInteract and not interactBound then
		ContextActionService:BindAction(INTERACT_ACTION, interactHandler, true, Enum.KeyCode.E)
		ContextActionService:SetTitle(INTERACT_ACTION, "INTERACT")
		ContextActionService:SetPosition(INTERACT_ACTION, UDim2.new(1, -170, 1, -140))
		interactBound = true
	elseif not wantInteract and interactBound then
		unbind(INTERACT_ACTION)
		interactBound = false
		interactActive = false
	end
end

local function setState(newState: string?)
	if newState == currentState then
		return
	end
	currentState = newState

	if currentState ~= "INFECTED" then
		biteActive = false
	end
	if currentState ~= "HUMAN" and sprintHeld then
		sprintHeld = false
		sendSprint(false)
	end
	updateBindings()
end

local function setCombat(newCombat: string?)
	currentCombat = newCombat
	if currentCombat ~= "ACTIVE" and currentCombat ~= nil then
		biteActive = false
	end
	updateBindings()
end

local function setGrabbed(newGrabbed: boolean)
	if grabbed == newGrabbed then
		return
	end
	grabbed = newGrabbed
	if grabbed then
		biteActive = false
		if sprintHeld then
			sprintHeld = false
			sendSprint(false)
		end
	end
	updateBindings()
end

-- 丧尸自己正在擒抱人类时也不能再起咬/前冲；服务端已冻结，客户端同步关掉本地意图。
local function setGrabbing(newGrabbing: boolean)
	if grabbing == newGrabbing then
		return
	end
	grabbing = newGrabbing
	if grabbing then
		biteActive = false
	end
end

local function bindCharacter(character: Model)
	if stateConnection ~= nil then
		stateConnection:Disconnect()
		stateConnection = nil
	end
	if combatConnection ~= nil then
		combatConnection:Disconnect()
		combatConnection = nil
	end
	if grabbedConnection ~= nil then
		grabbedConnection:Disconnect()
		grabbedConnection = nil
	end
	if grabbingConnection ~= nil then
		grabbingConnection:Disconnect()
		grabbingConnection = nil
	end
	if rootConnection ~= nil then
		rootConnection:Disconnect()
		rootConnection = nil
	end
	isRootSelf = character:GetAttribute(Constants.Attribute.Root) == true

	carryingCure = hasCarriedCure(character)
	setState(character:GetAttribute(Constants.Attribute.State) :: string?)
	setCombat(character:GetAttribute(Constants.Attribute.Combat) :: string?)
	setGrabbed(character:GetAttribute(Constants.Attribute.Grabbed) == true)
	setGrabbing(character:GetAttribute(Constants.Attribute.Grabbing) == true)
	updateBindings()

	stateConnection = character:GetAttributeChangedSignal(Constants.Attribute.State):Connect(function()
		setState(character:GetAttribute(Constants.Attribute.State) :: string?)
	end)
	combatConnection = character:GetAttributeChangedSignal(Constants.Attribute.Combat):Connect(function()
		setCombat(character:GetAttribute(Constants.Attribute.Combat) :: string?)
	end)
	grabbedConnection = character:GetAttributeChangedSignal(Constants.Attribute.Grabbed):Connect(function()
		setGrabbed(character:GetAttribute(Constants.Attribute.Grabbed) == true)
	end)
	grabbingConnection = character:GetAttributeChangedSignal(Constants.Attribute.Grabbing):Connect(function()
		setGrabbing(character:GetAttribute(Constants.Attribute.Grabbing) == true)
	end)
	rootConnection = character:GetAttributeChangedSignal(Constants.Attribute.Root):Connect(function()
		isRootSelf = character:GetAttribute(Constants.Attribute.Root) == true
		updateBindings()
	end)
end

local function handlePrivateEvent(eventType: string, payload: any)
	if eventType == PublicEventTypes.Private.YouAre and typeof(payload) == "table" then
		local id = payload.participantId
		if type(id) == "string" then
			participantId = id
		end
	elseif eventType == PublicEventTypes.Private.BiteResult and typeof(payload) == "table" then
		local serverCooldown = payload.cooldownUntil
		if type(serverCooldown) == "number" then
			cooldownUntil = serverCooldown
		end
		if payload.reason == "STARTED" then
			cooldownUntil = 0
		end
	elseif eventType == PublicEventTypes.Private.FireResult and typeof(payload) == "table" then
		if type(payload.ammo) == "number" then
			if payload.weapon == "Pistol" then
				pistolMagazine = payload.ammo
			elseif payload.weapon == "Taser" then
				taserCharges = payload.ammo
			end
		end
		if type(payload.reserve) == "number" then
			pistolReserve = payload.reserve
		end
		if type(payload.chargesLeft) == "number" then
			taserCharges = payload.chargesLeft
		end
	elseif eventType == PublicEventTypes.Private.WeaponState and typeof(payload) == "table" then
		if type(payload.selected) == "string" then
			weapon = payload.selected
		end
		if type(payload.pistolOwned) == "boolean" then
			pistolOwned = payload.pistolOwned
		end
		if type(payload.pistolMagazine) == "number" then
			pistolMagazine = payload.pistolMagazine
		end
		if type(payload.pistolReserve) == "number" then
			pistolReserve = payload.pistolReserve
		end
		if type(payload.pistolReloading) == "boolean" then
			pistolReloading = payload.pistolReloading
		end
		if type(payload.taserOwned) == "boolean" then
			taserOwned = payload.taserOwned
		end
		if type(payload.taserCharges) == "number" then
			taserCharges = payload.taserCharges
		end
		updateBindings()
	elseif eventType == PublicEventTypes.Private.Knockback and typeof(payload) == "table" then
		local impulse = payload.impulse
		if typeof(impulse) == "Vector3" and currentState == "INFECTED" then
			local character = player.Character
			local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
			if root ~= nil and root:IsA("BasePart") then
				root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + impulse
			end
		end
	elseif eventType == PublicEventTypes.Private.ChannelProgress then
		interactActive = true
	elseif
		eventType == PublicEventTypes.Private.ChannelCancelled
		or eventType == PublicEventTypes.Private.Cured
		or eventType == PublicEventTypes.Private.RelinkSucceeded
	then
		interactActive = false
	end
end

local function handlePublicEvent(eventType: string, payload: any)
	if eventType == PublicEventTypes.Public.RoundResult then
		biteActive = false
		cooldownUntil = 0
		sprintHeld = false
		interactActive = false
		lastFireAtByWeapon = {}
	elseif eventType == PublicEventTypes.Public.RoundPhaseChanged and typeof(payload) == "table" then
		if payload.phase == "RESULT" then
			biteActive = false
			cooldownUntil = 0
			interactActive = false
			lastFireAtByWeapon = {}
		elseif payload.phase == "PREPARE" then
			interactActive = false
			weapon = "Melee"
			pistolOwned = false
			pistolMagazine = 0
			pistolReserve = 0
			pistolReloading = false
			taserOwned = false
			taserCharges = 0
			lastFireAtByWeapon = {}
			updateBindings()
		end
	end
end

function InputController.init(): Controller
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local requestRemote = remotes:WaitForChild("RequestAction") :: RemoteEvent
	local privateRemote = remotes:WaitForChild("PrivatePlayerEvent") :: RemoteEvent
	local publicRemote = remotes:WaitForChild("PublicMatchEvent") :: RemoteEvent
	requestAction = requestRemote

	privateRemote.OnClientEvent:Connect(handlePrivateEvent)
	publicRemote.OnClientEvent:Connect(handlePublicEvent)

	player.CharacterAdded:Connect(bindCharacter)
	Workspace:GetAttributeChangedSignal(Constants.Attribute.HiveEnabled):Connect(updateBindings)
	if player.Character ~= nil then
		bindCharacter(player.Character)
	end

	-- 禁用菜单里的“重置角色”（§19.5）；Core 可能尚未就绪，失败就重试。
	task.spawn(function()
		while true do
			local ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", false)
			end)
			if ok then
				break
			end
			task.wait(0.5)
		end
	end)

	-- 解药的“手上小支”是公开模型（BTC_Cure）；客户端只据此显示图标与交互按钮。
	task.spawn(function()
		while true do
			task.wait(0.25)
			local has = hasCarriedCure(player.Character)
			if has ~= carryingCure then
				carryingCure = has
				if not has then
					interactActive = false
				end
				updateBindings()
			end
		end
	end)

	updateBindings()

	return table.freeze({
		getParticipantId = function(): string?
			return participantId
		end,
		getCooldownUntil = function(): number
			return cooldownUntil
		end,
		getState = function(): string?
			return currentState
		end,
		getCombat = function(): string?
			return currentCombat
		end,
		isBiting = function(): boolean
			return biteActive
		end,
		isSprinting = function(): boolean
			return sprintHeld
		end,
		isGrabbed = function(): boolean
			return grabbed
		end,
		getWeapon = function(): string
			return weapon
		end,
		getMagazine = function(): number
			return pistolMagazine
		end,
		getReserve = function(): number
			return pistolReserve
		end,
		getTaserCharges = function(): number
			return taserCharges
		end,
		isReloading = function(): boolean
			return pistolReloading
		end,
		getInteractNotice = function(): (string?, number)
			return interactNoticeText, interactNoticeAt
		end,
	})
end

return table.freeze(InputController)
