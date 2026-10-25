--!strict
-- 灰盒 HUD（GDB V1.1 §7.5、§9.3、§9.6、§9A）：状态、阶段、存活人数、耐力、丧尸生命、
-- 倒地/复活倒计时、擒抱横幅、武器与弹药、枪声方向提示、事件条与结算横幅。
-- 所有信息来自公开属性、公开广播或本人私有事件；客户端只展示，不参与判定。尺寸用 scale，手机可读。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local Constants = require(ReplicatedStorage.Shared.Constants)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)
local StateLabels = require(ReplicatedStorage.Shared.StateLabels)
local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local InputController = require(script.Parent.InputController)

local player = Players.LocalPlayer

local stateLabel: TextLabel
local phaseLabel: TextLabel
local humansLabel: TextLabel
local staminaFrame: Frame
local staminaFill: Frame
local healthFrame: Frame
local healthFill: Frame
local biteLabel: TextLabel
local weaponLabel: TextLabel
local ammoLabel: TextLabel
local effectLabel: TextLabel
local gunshotLabel: TextLabel
local resultLabel: TextLabel
local feedLabel: TextLabel

local inputController: InputController.Controller? = nil
local phase: string? = nil
local phaseEndsAt: number? = nil
local humansLeft = 0
local lastState: string? = nil
local resultToken = 0
local feedToken = 0
local updateAccumulator = 0

local highlights: { [Model]: Highlight? } = {}
local lastCombatStates: { [Model]: string? } = {}
local gunshotPosition: Vector3? = nil
local gunshotSeenAt = -math.huge

local HUDController = {}

local function makeLabel(parent: Instance, name: string, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = textSize
	label.TextColor3 = VisualTokens.Color.TextPrimary
	label.Text = ""
	label.TextStrokeTransparency = 0.5
	label.TextStrokeColor3 = VisualTokens.Color.Night
	label.Parent = parent
	return label
end

local function stateStyle(state: string): (string, Color3)
	local label = StateLabels[state]
	local text = if label ~= nil then label.en else state
	if state == "HUMAN" then
		return text, VisualTokens.Color.Human
	elseif state == "INFECTED" then
		return text, VisualTokens.Color.Zombie
	elseif state == "INCUBATING" then
		return text, VisualTokens.Color.Zombie:Lerp(VisualTokens.Color.Night, 0.55)
	elseif state == "DOWNED" then
		return text, VisualTokens.Color.Zombie
	elseif state == "DEAD" then
		return text, VisualTokens.Color.TextSecondary
	elseif state == "STUNNED" then
		return text, VisualTokens.Color.Disconnected
	elseif state == "GRABBED" then
		return text, VisualTokens.Color.Zombie
	end
	return text, VisualTokens.Color.TextSecondary
end

local function feed(text: string, color: Color3)
	feedToken += 1
	local token = feedToken
	feedLabel.Text = text
	feedLabel.TextColor3 = color
	task.delay(4, function()
		if token == feedToken then
			feedLabel.Text = ""
		end
	end)
end

local function showResult(winner: string?)
	resultToken += 1
	local token = resultToken

	if winner == "HUMANS" then
		resultLabel.Text = "HUMANS WIN"
		resultLabel.TextColor3 = VisualTokens.Color.Human
	elseif winner == "INFECTED" then
		resultLabel.Text = "INFECTED WIN"
		resultLabel.TextColor3 = VisualTokens.Color.Zombie
	else
		resultLabel.Text = "ROUND ENDED"
		resultLabel.TextColor3 = VisualTokens.Color.TextSecondary
	end

	resultLabel.Visible = true
	task.delay(8, function()
		if token == resultToken then
			resultLabel.Visible = false
		end
	end)
end

local function handlePublicEvent(eventType: string, payload: any)
	if eventType == PublicEventTypes.Public.RoundPhaseChanged and typeof(payload) == "table" then
		if type(payload.phase) == "string" then
			phase = payload.phase
		end
		phaseEndsAt = if type(payload.phaseEndsAt) == "number" then payload.phaseEndsAt else nil
		if type(payload.humansLeft) == "number" then
			humansLeft = math.max(0, math.floor(payload.humansLeft))
		end
		if phase == "PREPARE" then
			resultToken += 1
			resultLabel.Visible = false
			feedToken += 1
			feedLabel.Text = ""
			gunshotPosition = nil
			gunshotLabel.Visible = false
		end
	elseif eventType == PublicEventTypes.Public.RoundResult and typeof(payload) == "table" then
		local winner = if type(payload.winner) == "string" then payload.winner else nil
		showResult(winner)
	elseif eventType == PublicEventTypes.Public.OutbreakStarted and typeof(payload) == "table" then
		if type(payload.displayName) == "string" then
			feed(`{payload.displayName} IS THE SOURCE`, VisualTokens.Color.Zombie)
		end
	elseif eventType == PublicEventTypes.Public.InfectionTurning and typeof(payload) == "table" then
		if type(payload.displayName) == "string" then
			feed(`{payload.displayName} IS TURNING`, VisualTokens.Color.Zombie)
		end
	elseif eventType == PublicEventTypes.Public.InfectionRevealed and typeof(payload) == "table" then
		if type(payload.displayName) == "string" then
			feed(`{payload.displayName} IS INFECTED`, VisualTokens.Color.Zombie)
		end
	elseif eventType == PublicEventTypes.Public.GunshotFired and typeof(payload) == "table" then
		local position = payload.position
		if typeof(position) == "Vector3" then
			gunshotPosition = position
			gunshotSeenAt = Workspace:GetServerTimeNow()
		end
	end
end

local function displayNameOf(model: Model): string
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil and humanoid.DisplayName ~= "" then
		return humanoid.DisplayName
	end
	return model.Name
end

-- 可选表现：仅客户端给感染者加轮廓，不写回服务端（§17.6）；死亡隐藏的模型不再加轮廓。
local function refreshHighlights()
	for model, highlight in highlights do
		local combat = model:GetAttribute(Constants.Attribute.Combat)
		if
			highlight ~= nil
			and (model.Parent == nil or model:GetAttribute(Constants.Attribute.State) ~= "INFECTED" or combat == "DEAD")
		then
			highlight:Destroy()
			highlights[model] = nil
		end
	end

	for _, child in Workspace:GetChildren() do
		if
			child:IsA("Model")
			and child:GetAttribute(Constants.Attribute.State) == "INFECTED"
			and child:GetAttribute(Constants.Attribute.Combat) ~= "DEAD"
		then
			if highlights[child] == nil then
				local highlight = Instance.new("Highlight")
				highlight.Name = "BTC_InfectedOutline"
				highlight.Adornee = child
				highlight.DepthMode = Enum.HighlightDepthMode.Occluded
				highlight.FillColor = VisualTokens.Color.Zombie
				highlight.FillTransparency = 0.85
				highlight.OutlineColor = VisualTokens.Color.Zombie
				highlight.OutlineTransparency = 0.2
				highlight.Parent = child
				highlights[child] = highlight
			end
		end
	end
end

-- 倒地/死亡事件条：客户端从公开的 BTC_Combat 变化推导，不额外广播。
local function refreshCombatFeed()
	for model, _previous in lastCombatStates do
		if model.Parent == nil or model:GetAttribute(Constants.Attribute.State) ~= "INFECTED" then
			lastCombatStates[model] = nil
		end
	end

	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(Constants.Attribute.State) == "INFECTED" then
			local combat = child:GetAttribute(Constants.Attribute.Combat)
			local combatText = if type(combat) == "string" then combat else "ACTIVE"
			local previous: string? = lastCombatStates[child]
			if previous ~= nil and combatText ~= previous then
				if combatText == "DOWNED" then
					feed(`{displayNameOf(child)} DOWN`, VisualTokens.Color.Zombie)
				elseif combatText == "DEAD" then
					feed(`{displayNameOf(child)} KILLED`, VisualTokens.Color.TextSecondary)
				end
			end
			lastCombatStates[child] = combatText
		end
	end
end

local function refreshGunshotPing(state: string?)
	local position = gunshotPosition
	local now = Workspace:GetServerTimeNow()
	if state ~= "INFECTED" or position == nil or now - gunshotSeenAt > BalanceConfig.GunshotPingSeconds then
		gunshotLabel.Visible = false
		return
	end

	local camera = Workspace.CurrentCamera
	if camera == nil then
		gunshotLabel.Visible = false
		return
	end

	local localPosition = camera.CFrame:PointToObjectSpace(position)
	local onLeft = localPosition.X < 0
	local vertical = math.clamp(0.5 - localPosition.Y / 40, 0.18, 0.82)
	gunshotLabel.Text = if onLeft then "< GUNSHOT" else "GUNSHOT >"
	gunshotLabel.TextColor3 = VisualTokens.Color.Zombie
	gunshotLabel.TextXAlignment = if onLeft then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right
	gunshotLabel.AnchorPoint = Vector2.new(if onLeft then 0 else 1, 0.5)
	gunshotLabel.Position = UDim2.fromScale(if onLeft then 0.03 else 0.97, vertical)
	gunshotLabel.Visible = true
end

local function healthRatio(character: Model): number
	local value = character:GetAttribute(Constants.Attribute.Health)
	if type(value) == "number" then
		return math.clamp(value, 0, 1)
	end
	return 0
end

local function refreshState()
	local character = player.Character
	local state: string? = nil
	local combat: string? = nil
	local grabbed = false
	local grabbing = false
	if character ~= nil then
		state = character:GetAttribute(Constants.Attribute.State) :: string?
		combat = character:GetAttribute(Constants.Attribute.Combat) :: string?
		grabbed = character:GetAttribute(Constants.Attribute.Grabbed) == true
		grabbing = character:GetAttribute(Constants.Attribute.Grabbing) == true
	end

	local controller = inputController
	if state == nil then
		if controller == nil or controller.getParticipantId() == nil then
			state = "SPECTATOR"
		else
			state = lastState
		end
	end

	if state == nil then
		return
	end
	lastState = state

	local text, color = stateStyle(state)
	if state == "INFECTED" and combat == "DEAD" then
		local respawnAt = if character ~= nil then character:GetAttribute(Constants.Attribute.RespawnAt) else nil
		if type(respawnAt) == "number" then
			local remaining = math.max(0, respawnAt - Workspace:GetServerTimeNow())
			text = string.format("%s %.1fs", StateLabels.DEAD.en, remaining)
		else
			text = StateLabels.DEAD.en
		end
		color = VisualTokens.Color.TextSecondary
	elseif state == "INFECTED" and combat == "DOWNED" then
		text = StateLabels.DOWNED.en
		color = VisualTokens.Color.Zombie
	elseif state == "INFECTED" and combat == "STUNNED" then
		text = StateLabels.STUNNED.en
		color = VisualTokens.Color.Disconnected
	end

	stateLabel.Text = text
	stateLabel.TextColor3 = color

	if state == "HUMAN" then
		staminaFrame.Visible = true
		local ratio = player:GetAttribute(Constants.Attribute.Stamina)
		local value = if type(ratio) == "number" then math.clamp(ratio, 0, 1) else 1
		staminaFill.Size = UDim2.fromScale(value, 1)
		staminaFill.BackgroundColor3 = if value < 0.3 then VisualTokens.Color.Zombie else VisualTokens.Color.Human
	else
		staminaFrame.Visible = false
	end

	if state == "INFECTED" and combat ~= "DEAD" and character ~= nil then
		healthFrame.Visible = true
		local ratio = healthRatio(character)
		healthFill.Size = UDim2.fromScale(ratio, 1)
		healthFill.BackgroundColor3 = VisualTokens.Color.Zombie
	else
		healthFrame.Visible = false
	end

	if state == "HUMAN" and controller ~= nil then
		weaponLabel.Visible = true
		ammoLabel.Visible = true
		local selected = controller.getWeapon()
		weaponLabel.Text = string.upper(selected)
		if selected == "Pistol" then
			if controller.isReloading() then
				ammoLabel.Text = "RELOADING..."
			else
				ammoLabel.Text = string.format("%d / %d", controller.getMagazine(), controller.getReserve())
			end
		elseif selected == "Taser" then
			ammoLabel.Text = string.format("CHARGES %d", controller.getTaserCharges())
		else
			ammoLabel.Text = "MELEE"
		end
	else
		weaponLabel.Visible = false
		ammoLabel.Visible = false
	end

	if state == "INFECTED" and combat ~= "DOWNED" and combat ~= "DEAD" and combat ~= "STUNNED" and not grabbing then
		if controller == nil then
			biteLabel.Visible = false
		else
			biteLabel.Visible = true
			if controller.isBiting() then
				biteLabel.Text = "BITING..."
				biteLabel.TextColor3 = VisualTokens.Color.Zombie
			else
				local remaining = controller.getCooldownUntil() - Workspace:GetServerTimeNow()
				if remaining > 0 then
					biteLabel.Text = string.format("BITE %.1fs", remaining)
					biteLabel.TextColor3 = VisualTokens.Color.TextSecondary
				else
					biteLabel.Text = "BITE READY"
					biteLabel.TextColor3 = VisualTokens.Color.Zombie
				end
			end
		end
	else
		biteLabel.Visible = false
	end

	effectLabel.Visible = grabbed or grabbing
	effectLabel.Text = if grabbing then StateLabels.GRABBING.en else StateLabels.GRABBED.en
	refreshGunshotPing(state)
end

local function refreshPhase()
	if phase == nil then
		phaseLabel.Text = ""
		humansLabel.Text = ""
		return
	end

	local suffix = ""
	if phaseEndsAt ~= nil and phase ~= "RESULT" then
		local remaining = math.max(0, math.ceil(phaseEndsAt - Workspace:GetServerTimeNow()))
		suffix = ` · {remaining}s`
	end
	phaseLabel.Text = phase .. suffix
	humansLabel.Text = string.format("%d HUMANS LEFT", humansLeft)
end

function HUDController.init(controller: InputController.Controller)
	inputController = controller

	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "BTCHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui

	stateLabel = makeLabel(root, "State", 24)
	stateLabel.AnchorPoint = Vector2.new(0, 0)
	stateLabel.Position = UDim2.fromScale(0.03, 0.04)
	stateLabel.Size = UDim2.fromScale(0.34, 0.07)
	stateLabel.TextXAlignment = Enum.TextXAlignment.Left

	phaseLabel = makeLabel(root, "Phase", 20)
	phaseLabel.AnchorPoint = Vector2.new(0.5, 0)
	phaseLabel.Position = UDim2.fromScale(0.5, 0.04)
	phaseLabel.Size = UDim2.fromScale(0.4, 0.06)
	phaseLabel.TextXAlignment = Enum.TextXAlignment.Center

	humansLabel = makeLabel(root, "Humans", 20)
	humansLabel.AnchorPoint = Vector2.new(1, 0)
	humansLabel.Position = UDim2.fromScale(0.97, 0.04)
	humansLabel.Size = UDim2.fromScale(0.3, 0.06)
	humansLabel.TextXAlignment = Enum.TextXAlignment.Right
	humansLabel.TextColor3 = VisualTokens.Color.Human

	staminaFrame = Instance.new("Frame")
	staminaFrame.Name = "Stamina"
	staminaFrame.AnchorPoint = Vector2.new(0.5, 1)
	staminaFrame.Position = UDim2.fromScale(0.5, 0.93)
	staminaFrame.Size = UDim2.fromScale(0.36, 0.022)
	staminaFrame.BackgroundColor3 = VisualTokens.Color.SurfaceSlate
	staminaFrame.BackgroundTransparency = 0.25
	staminaFrame.BorderSizePixel = 0
	staminaFrame.Visible = false
	staminaFrame.Parent = root

	local staminaCorner = Instance.new("UICorner")
	staminaCorner.CornerRadius = UDim.new(1, 0)
	staminaCorner.Parent = staminaFrame

	staminaFill = Instance.new("Frame")
	staminaFill.Name = "Fill"
	staminaFill.Size = UDim2.fromScale(1, 1)
	staminaFill.BackgroundColor3 = VisualTokens.Color.Human
	staminaFill.BorderSizePixel = 0
	staminaFill.Parent = staminaFrame

	local staminaFillCorner = Instance.new("UICorner")
	staminaFillCorner.CornerRadius = UDim.new(1, 0)
	staminaFillCorner.Parent = staminaFill

	healthFrame = Instance.new("Frame")
	healthFrame.Name = "ZombieHealth"
	healthFrame.AnchorPoint = Vector2.new(0.5, 1)
	healthFrame.Position = UDim2.fromScale(0.5, 0.93)
	healthFrame.Size = UDim2.fromScale(0.36, 0.026)
	healthFrame.BackgroundColor3 = VisualTokens.Color.SurfaceSlate
	healthFrame.BackgroundTransparency = 0.25
	healthFrame.BorderSizePixel = 0
	healthFrame.Visible = false
	healthFrame.Parent = root

	local healthCorner = Instance.new("UICorner")
	healthCorner.CornerRadius = UDim.new(1, 0)
	healthCorner.Parent = healthFrame

	healthFill = Instance.new("Frame")
	healthFill.Name = "Fill"
	healthFill.Size = UDim2.fromScale(1, 1)
	healthFill.BackgroundColor3 = VisualTokens.Color.Zombie
	healthFill.BorderSizePixel = 0
	healthFill.Parent = healthFrame

	local healthFillCorner = Instance.new("UICorner")
	healthFillCorner.CornerRadius = UDim.new(1, 0)
	healthFillCorner.Parent = healthFill

	biteLabel = makeLabel(root, "Bite", 20)
	biteLabel.AnchorPoint = Vector2.new(1, 1)
	biteLabel.Position = UDim2.fromScale(0.97, 0.90)
	biteLabel.Size = UDim2.fromScale(0.3, 0.06)
	biteLabel.TextXAlignment = Enum.TextXAlignment.Right
	biteLabel.Visible = false

	weaponLabel = makeLabel(root, "Weapon", 22)
	weaponLabel.AnchorPoint = Vector2.new(1, 1)
	weaponLabel.Position = UDim2.fromScale(0.97, 0.78)
	weaponLabel.Size = UDim2.fromScale(0.3, 0.05)
	weaponLabel.TextXAlignment = Enum.TextXAlignment.Right
	weaponLabel.Visible = false

	ammoLabel = makeLabel(root, "Ammo", 20)
	ammoLabel.AnchorPoint = Vector2.new(1, 1)
	ammoLabel.Position = UDim2.fromScale(0.97, 0.83)
	ammoLabel.Size = UDim2.fromScale(0.3, 0.05)
	ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
	ammoLabel.Visible = false

	effectLabel = makeLabel(root, "Effect", 28)
	effectLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	effectLabel.Position = UDim2.fromScale(0.5, 0.64)
	effectLabel.Size = UDim2.fromScale(0.5, 0.08)
	effectLabel.TextXAlignment = Enum.TextXAlignment.Center
	effectLabel.TextColor3 = VisualTokens.Color.Zombie
	effectLabel.Visible = false

	gunshotLabel = makeLabel(root, "GunshotPing", 18)
	gunshotLabel.AnchorPoint = Vector2.new(0, 0.5)
	gunshotLabel.Position = UDim2.fromScale(0.03, 0.5)
	gunshotLabel.Size = UDim2.fromScale(0.34, 0.05)
	gunshotLabel.TextXAlignment = Enum.TextXAlignment.Left
	gunshotLabel.Visible = false

	feedLabel = makeLabel(root, "Feed", 18)
	feedLabel.AnchorPoint = Vector2.new(0, 1)
	feedLabel.Position = UDim2.fromScale(0.03, 0.74)
	feedLabel.Size = UDim2.fromScale(0.7, 0.06)
	feedLabel.TextXAlignment = Enum.TextXAlignment.Left

	resultLabel = makeLabel(root, "Result", 36)
	resultLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	resultLabel.Position = UDim2.fromScale(0.5, 0.4)
	resultLabel.Size = UDim2.fromScale(0.86, 0.14)
	resultLabel.TextXAlignment = Enum.TextXAlignment.Center
	resultLabel.BackgroundColor3 = VisualTokens.Color.Night
	resultLabel.BackgroundTransparency = 0.45
	resultLabel.Visible = false

	local resultCorner = Instance.new("UICorner")
	resultCorner.CornerRadius = UDim.new(0, 12)
	resultCorner.Parent = resultLabel

	local publicRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PublicMatchEvent") :: RemoteEvent
	publicRemote.OnClientEvent:Connect(handlePublicEvent)

	RunService.RenderStepped:Connect(function(deltaTime: number)
		updateAccumulator += deltaTime
		if updateAccumulator < 0.1 then
			return
		end
		updateAccumulator = 0

		refreshState()
		refreshPhase()
		refreshHighlights()
		refreshCombatFeed()
	end)

	refreshState()
	refreshPhase()
end

return table.freeze(HUDController)
