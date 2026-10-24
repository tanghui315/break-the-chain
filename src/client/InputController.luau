--!strict
-- 客户端能力输入（GDB V1.1 §9.2、§9.6、§19.5）：ContextActionService 自定义绑定，不用 Tool。
-- 扑咬是“开始前摇 → 本地短冲刺 → 提交 TryBite”的意图流；命中仍由服务端复算。
-- 手机：Bite / Sprint 都带触摸按钮；Sprint 在触摸端为开关，键鼠为按住 LeftShift。

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)

local BITE_ACTION = "BTC_Bite"
local SPRINT_ACTION = "BTC_Sprint"

export type Controller = {
	getParticipantId: () -> string?,
	getCooldownUntil: () -> number,
	getState: () -> string?,
	isBiting: () -> boolean,
	isSprinting: () -> boolean,
}

local player = Players.LocalPlayer
local requestAction: RemoteEvent? = nil

local participantId: string? = nil
local currentState: string? = nil
local cooldownUntil = 0
local biteActive = false
local sprintHeld = false
local stateConnection: RBXScriptConnection? = nil
local biteBound = false
local sprintBound = false

local InputController = {}

local function sendAction(payload: { [string]: any })
	if requestAction ~= nil then
		requestAction:FireServer(payload)
	end
end

local function sendSprint(want: boolean)
	sendAction({ action = Constants.Action.SetSprint, sprint = want })
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
			if type(id) == "string" and state == "HUMAN" then
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

local function startBite()
	if biteActive or currentState ~= "INFECTED" then
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
		if not biteActive or currentState ~= "INFECTED" or player.Character ~= character then
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

		-- 本地短冲刺只负责手感；命中与位移合法性仍由服务端判定（§9.5）。
		root.AssemblyLinearVelocity = horizontal
				* (BalanceConfig.Greybox.LungeDistance / BalanceConfig.Greybox.LungeSeconds)
			+ Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)

		task.wait(BalanceConfig.Greybox.LungeSeconds)

		if not biteActive or currentState ~= "INFECTED" or player.Character ~= character then
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
	if currentState ~= "INFECTED" then
		return Enum.ContextActionResult.Pass
	end
	startBite()
	return Enum.ContextActionResult.Sink
end

local function sprintHandler(
	_actionName: string,
	inputState: Enum.UserInputState,
	inputObject: InputObject
): Enum.ContextActionResult
	if currentState ~= "HUMAN" then
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

local function updateBindings()
	local wantBite = currentState == "INFECTED"
	local wantSprint = currentState == "HUMAN"

	if wantBite and not biteBound then
		ContextActionService:BindAction(BITE_ACTION, biteHandler, true, Enum.UserInputType.MouseButton1)
		ContextActionService:SetTitle(BITE_ACTION, "BITE")
		ContextActionService:SetPosition(BITE_ACTION, UDim2.new(1, -170, 1, -210))
		biteBound = true
	elseif not wantBite and biteBound then
		ContextActionService:UnbindAction(BITE_ACTION)
		biteBound = false
	end

	if wantSprint and not sprintBound then
		ContextActionService:BindAction(SPRINT_ACTION, sprintHandler, true, Enum.KeyCode.LeftShift)
		ContextActionService:SetTitle(SPRINT_ACTION, "SPRINT")
		ContextActionService:SetPosition(SPRINT_ACTION, UDim2.new(1, -170, 1, -300))
		sprintBound = true
	elseif not wantSprint and sprintBound then
		ContextActionService:UnbindAction(SPRINT_ACTION)
		sprintBound = false
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

local function bindCharacter(character: Model)
	if stateConnection ~= nil then
		stateConnection:Disconnect()
		stateConnection = nil
	end

	setState(character:GetAttribute(Constants.Attribute.State) :: string?)
	stateConnection = character:GetAttributeChangedSignal(Constants.Attribute.State):Connect(function()
		setState(character:GetAttribute(Constants.Attribute.State) :: string?)
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
	end
end

local function handlePublicEvent(eventType: string, payload: any)
	if eventType == PublicEventTypes.Public.RoundResult then
		biteActive = false
		cooldownUntil = 0
		sprintHeld = false
	elseif eventType == PublicEventTypes.Public.RoundPhaseChanged and typeof(payload) == "table" then
		if payload.phase == "RESULT" then
			biteActive = false
			cooldownUntil = 0
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
		isBiting = function(): boolean
			return biteActive
		end,
		isSprinting = function(): boolean
			return sprintHeld
		end,
	})
end

return table.freeze(InputController)
