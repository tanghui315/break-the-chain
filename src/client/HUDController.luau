--!strict
-- 灰盒 HUD（GDB V1.1 §7.5、§9.3、§9.6、§9A、§10.3、§11.2、§13.4、§17.2）：
-- 状态、阶段与倒计时、已撤离 x/y、撤离开启横幅、耐力/丧尸生命、倒地/复活/断联倒计时、
-- 擒抱横幅、武器与弹药、枪声方向、读条环、携带解药、重连方向箭头、SOURCE/PROTECTED 标签、
-- 事件条与带原因的结算横幅。
-- 所有信息来自公开属性、公开广播或本人私有事件；客户端只展示，不参与判定。尺寸用 scale/offset，手机可读。
-- 不显示全局人类/丧尸人数（§13.4）。

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
local evacuatedLabel: TextLabel
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
local exitBannerLabel: TextLabel
local noticeLabel: TextLabel
local cureLabel: TextLabel
local relinkArrow: TextLabel
local channelRing: Frame
local channelLabel: TextLabel

local inputController: InputController.Controller? = nil
local phase: string? = nil
local phaseEndsAt: number? = nil
local extractedCount = 0
local requiredExtracted = 0
local lastState: string? = nil
local resultToken = 0
local feedToken = 0
local updateAccumulator = 0

local highlights: { [Model]: Highlight? } = {}
local lastCombatStates: { [Model]: string? } = {}
local gunshotPosition: Vector3? = nil
local gunshotSeenAt = -math.huge

-- Gate A-2b 的私有信息
local unstableEndsAt: number? = nil
-- §7.3 / §6.1：本人尸变倒计时；“你是源头”用一次性 feed 通知即可。
local incubationEndsAt: number? = nil
local relinkHintDirection: Vector3? = nil
local relinkHintDistance = -1
local relinkHintAt = -math.huge
local channelKind: string? = nil
local channelRatio: number? = nil
local channelElapsed = 0
local channelDuration = 0
local channelUpdatedAt = -math.huge
local channelSegments: { Frame } = {}
local hudNoticeText: string? = nil
-- §6.4 EXP-09：源头标记。participantId → 标记结束的服务端时刻；对应角色上挂本地隔墙轮廓。
local hiveMarks: { [string]: number } = {}
local hiveHighlights: { [Model]: Highlight } = {}
local hudNoticeAt = -math.huge

-- 公开标签（客户端本地创建，§17.6）
type TagEntry = {
	gui: BillboardGui,
	label: TextLabel,
}

local tags: { [Model]: TagEntry } = {}
local exitBannerUntil = 0

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
	elseif state == "UNSTABLE" then
		return text, VisualTokens.Color.Disconnected
	elseif state == "EXTRACTED" then
		return text, VisualTokens.Color.Cured
	elseif state == "SPECTATOR" then
		return text, VisualTokens.Color.TextSecondary
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

local function showResult(winner: string?, reason: string?)
	resultToken += 1
	local token = resultToken
	local reasonText = if type(reason) == "string" then `\n{reason}` else ""

	if winner == "HUMANS" then
		resultLabel.Text = `HUMANS WIN{reasonText}`
		resultLabel.TextColor3 = VisualTokens.Color.Human
	elseif winner == "INFECTED" then
		resultLabel.Text = `INFECTED WIN{reasonText}`
		resultLabel.TextColor3 = VisualTokens.Color.Zombie
	else
		resultLabel.Text = `ROUND ENDED{reasonText}`
		resultLabel.TextColor3 = VisualTokens.Color.TextSecondary
	end

	resultLabel.Visible = true
	task.delay(8, function()
		if token == resultToken then
			resultLabel.Visible = false
		end
	end)
end

local function clearChannel()
	channelKind = nil
	channelRatio = nil
	channelElapsed = 0
	channelDuration = 0
	channelUpdatedAt = -math.huge
	channelRing.Visible = false
end

local function handlePublicEvent(eventType: string, payload: any)
	if eventType == PublicEventTypes.Public.RoundPhaseChanged and typeof(payload) == "table" then
		if type(payload.phase) == "string" then
			phase = payload.phase
		end
		phaseEndsAt = if type(payload.phaseEndsAt) == "number" then payload.phaseEndsAt else nil
		if type(payload.extracted) == "number" then
			extractedCount = math.max(0, math.floor(payload.extracted))
		end
		if type(payload.requiredExtracted) == "number" then
			requiredExtracted = math.max(0, math.floor(payload.requiredExtracted))
		end
		if phase == "PREPARE" then
			resultToken += 1
			resultLabel.Visible = false
			feedToken += 1
			feedLabel.Text = ""
			gunshotPosition = nil
			gunshotLabel.Visible = false
			unstableEndsAt = nil
			relinkHintDirection = nil
			relinkHintDistance = -1
			exitBannerUntil = 0
			clearChannel()
		elseif phase == "RESULT" then
			clearChannel()
		end
	elseif eventType == PublicEventTypes.Public.RoundResult and typeof(payload) == "table" then
		local winner = if type(payload.winner) == "string" then payload.winner else nil
		local reason = if type(payload.reason) == "string" then payload.reason else nil
		showResult(winner, reason)
	elseif eventType == PublicEventTypes.Public.OutbreakStarted and typeof(payload) == "table" then
		local count = if type(payload.participantIds) == "table" then #payload.participantIds else 0
		feed(`OUTBREAK — {count} SOURCE(S)`, VisualTokens.Color.Zombie)
	elseif eventType == PublicEventTypes.Public.InfectionTurning and typeof(payload) == "table" then
		if type(payload.displayName) == "string" then
			feed(`{payload.displayName} IS TURNING`, VisualTokens.Color.Zombie)
		end
	elseif eventType == PublicEventTypes.Public.InfectionRevealed and typeof(payload) == "table" then
		if type(payload.displayName) == "string" then
			feed(`{payload.displayName} IS INFECTED`, VisualTokens.Color.Zombie)
		end
	elseif eventType == PublicEventTypes.Public.ChainCutNearby and typeof(payload) == "table" then
		local count = if type(payload.count) == "number" then payload.count else 0
		feed(`CHAIN BROKEN — {count} DISCONNECTED`, VisualTokens.Color.Disconnected)
	elseif eventType == PublicEventTypes.Public.ExtractionOpened then
		exitBannerUntil = Workspace:GetServerTimeNow() + 6
		feed("EXTRACTION OPEN — REACH THE EXIT", VisualTokens.Color.Exit)
	elseif eventType == PublicEventTypes.Public.BreachWarning then
		-- §6.1：PREPARE 倒计时 3 秒的隔离突破预警。
		feed("QUARANTINE BREACH IN 3", VisualTokens.Color.Zombie)
	elseif eventType == PublicEventTypes.Public.ExtractionTargetAdjusted and typeof(payload) == "table" then
		-- §5.4：目标被可达性压低后，同步 HUD 的 x/y 并让玩家知道发生了什么。
		if type(payload.requiredExtracted) == "number" then
			requiredExtracted = math.max(0, math.floor(payload.requiredExtracted))
		end
		feed(string.format("EVAC TARGET ADJUSTED — %d REQUIRED", requiredExtracted), VisualTokens.Color.Exit)
	elseif eventType == PublicEventTypes.Public.Extracted and typeof(payload) == "table" then
		if type(payload.extracted) == "number" then
			extractedCount = math.max(0, math.floor(payload.extracted))
		end
		if type(payload.requiredExtracted) == "number" then
			requiredExtracted = math.max(0, math.floor(payload.requiredExtracted))
		end
		if type(payload.displayName) == "string" then
			feed(
				string.format("%s EVACUATED (%d/%d)", payload.displayName, extractedCount, requiredExtracted),
				VisualTokens.Color.Cured
			)
		end
	elseif eventType == PublicEventTypes.Public.GunshotFired and typeof(payload) == "table" then
		local position = payload.position
		if typeof(position) == "Vector3" then
			gunshotPosition = position
			gunshotSeenAt = Workspace:GetServerTimeNow()
		end
	end
end

-- 私有事件：本人断联倒计时、重连方向、读条进度/取消、治愈与重连结果。
local function handlePrivateEvent(eventType: string, payload: any)
	if eventType == PublicEventTypes.Private.YouAreUnstable and typeof(payload) == "table" then
		if type(payload.unstableEndsAt) == "number" then
			unstableEndsAt = payload.unstableEndsAt
		end
	elseif eventType == PublicEventTypes.Private.YouAreIncubating and typeof(payload) == "table" then
		-- §7.3 / §20.7：本人尸变倒计时；与 YouAreUnstable 的计时器共存。
		if type(payload.incubationEndsAt) == "number" then
			incubationEndsAt = payload.incubationEndsAt
		end
	elseif eventType == PublicEventTypes.Private.HiveMark and typeof(payload) == "table" then
		-- 本树丧尸收到：隔墙看到被标记的人类。
		if type(payload.targetId) == "string" and type(payload.seconds) == "number" then
			hiveMarks[payload.targetId] = Workspace:GetServerTimeNow() + payload.seconds
			feed("SOURCE MARKED A TARGET", VisualTokens.Color.Zombie)
		end
	elseif eventType == PublicEventTypes.Private.YouAreMarked and typeof(payload) == "table" then
		-- 被标记者：明确告知，给出反制时间（找掩体 / 靠近持枪队友）。
		feed("THE SOURCE MARKED YOU — BREAK LINE OF SIGHT", VisualTokens.Color.Zombie)
		hudNoticeText = "MARKED — zombies can see you"
		hudNoticeAt = Workspace:GetServerTimeNow()
	elseif eventType == PublicEventTypes.Private.HiveAbilityResult and typeof(payload) == "table" then
		local ability = if payload.ability == "RALLY" then "RALLY" else "MARK"
		local reason = if type(payload.reason) == "string" then payload.reason else ""
		local readyIn = if ability == "RALLY" then payload.rallyReadyIn else payload.markReadyIn
		if reason == "OK" then
			feed("TARGET MARKED", VisualTokens.Color.Zombie)
		elseif reason == "CHANNEL" then
			feed("RALLYING — HOLD STILL", VisualTokens.Color.Zombie)
		elseif reason == "PLACED" then
			feed("HIVE BEACON UP — YOUR DEAD RISE HERE", VisualTokens.Color.Zombie)
		else
			local suffix = if type(readyIn) == "number" and readyIn > 0
				then string.format(" (%ds)", math.ceil(readyIn))
				else ""
			hudNoticeText = `{ability}: {reason}{suffix}`
			hudNoticeAt = Workspace:GetServerTimeNow()
		end
	elseif eventType == PublicEventTypes.Private.YouAreSource then
		-- §6.1：公开身份但私有告知，让零号知道自己会被优先猎杀。
		feed("YOU ARE THE SOURCE", VisualTokens.Color.Zombie)
	elseif eventType == PublicEventTypes.Private.RelinkHint and typeof(payload) == "table" then
		if typeof(payload.direction) == "Vector3" and type(payload.distance) == "number" then
			relinkHintDirection = payload.direction
			relinkHintDistance = payload.distance
			relinkHintAt = Workspace:GetServerTimeNow()
		end
	elseif eventType == PublicEventTypes.Private.ChannelProgress and typeof(payload) == "table" then
		if type(payload.kind) == "string" and type(payload.ratio) == "number" then
			channelKind = payload.kind
			channelRatio = math.clamp(payload.ratio, 0, 1)
			channelElapsed = if type(payload.elapsed) == "number" then payload.elapsed else 0
			channelDuration = if type(payload.duration) == "number" then payload.duration else 0
			channelUpdatedAt = Workspace:GetServerTimeNow()
		end
	elseif eventType == PublicEventTypes.Private.ChannelCancelled and typeof(payload) == "table" then
		clearChannel()
		if payload.reason == "ROOT_IMMUNE" then
			-- §10.2：即使客户端没能提前识别零号，服务端也会明确告知“普通解药无效”。
			hudNoticeText = "SOURCE — cure has no effect"
			hudNoticeAt = Workspace:GetServerTimeNow()
		end
	elseif eventType == PublicEventTypes.Private.Cured and typeof(payload) == "table" then
		clearChannel()
		if payload.you == "CURER" then
			feed("CURE COMPLETE", VisualTokens.Color.Cured)
		elseif payload.you == "CURED" then
			feed("YOU WERE CURED", VisualTokens.Color.Cured)
		end
	elseif eventType == PublicEventTypes.Private.RelinkSucceeded and typeof(payload) == "table" then
		clearChannel()
		unstableEndsAt = nil
		relinkHintDirection = nil
		relinkHintDistance = -1
		local count = if type(payload.count) == "number" then payload.count else 0
		feed(`LINK RESTORED — {count} STABILIZED`, VisualTokens.Color.Disconnected)
	end
end

local function displayNameOf(model: Model): string
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil and humanoid.DisplayName ~= "" then
		return humanoid.DisplayName
	end
	return model.Name
end

-- 可选表现：仅客户端给感染者加轮廓（§7 UNSTABLE 用 CHAIN_AMBER），不写回服务端（§17.6）；
-- 死亡隐藏的模型不再加轮廓。
local function refreshHighlights()
	for model, highlight in highlights do
		local combat = model:GetAttribute(Constants.Attribute.Combat)
		local state = model:GetAttribute(Constants.Attribute.State)
		if
			highlight ~= nil
			and (model.Parent == nil or (state ~= "INFECTED" and state ~= "UNSTABLE") or combat == "DEAD")
		then
			highlight:Destroy()
			highlights[model] = nil
		elseif highlight ~= nil then
			local color = if state == "UNSTABLE" then VisualTokens.Color.Disconnected else VisualTokens.Color.Zombie
			highlight.FillColor = color
			highlight.OutlineColor = color
		end
	end

	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") then
			local state = child:GetAttribute(Constants.Attribute.State)
			local combat = child:GetAttribute(Constants.Attribute.Combat)
			if (state == "INFECTED" or state == "UNSTABLE") and combat ~= "DEAD" then
				if highlights[child] == nil then
					local color = if state == "UNSTABLE"
						then VisualTokens.Color.Disconnected
						else VisualTokens.Color.Zombie
					local highlight = Instance.new("Highlight")
					highlight.Name = "BTC_InfectedOutline"
					highlight.Adornee = child
					highlight.DepthMode = Enum.HighlightDepthMode.Occluded
					highlight.FillColor = color
					highlight.FillTransparency = 0.85
					highlight.OutlineColor = color
					highlight.OutlineTransparency = 0.2
					highlight.Parent = child
					highlights[child] = highlight
				end
			end
		end
	end
end

-- §6.4 EXP-09：给仍在标记期内的角色挂 AlwaysOnTop 轮廓；过期或角色消失即移除。
local function refreshHiveMarks()
	local now = Workspace:GetServerTimeNow()
	for id, endsAt in hiveMarks do
		if now >= endsAt then
			hiveMarks[id] = nil
		end
	end
	for model, highlight in hiveHighlights do
		local id = model:GetAttribute(Constants.Attribute.ParticipantId)
		if model.Parent == nil or type(id) ~= "string" or hiveMarks[id] == nil then
			highlight:Destroy()
			hiveHighlights[model] = nil
		end
	end
	if next(hiveMarks) == nil then
		return
	end
	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") and (hiveHighlights[child] :: Highlight?) == nil then
			local id = child:GetAttribute(Constants.Attribute.ParticipantId)
			if type(id) == "string" and hiveMarks[id] ~= nil then
				local highlight = Instance.new("Highlight")
				highlight.Name = "BTC_HiveMark"
				highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				highlight.FillColor = VisualTokens.Color.Zombie
				highlight.FillTransparency = 0.7
				highlight.OutlineColor = VisualTokens.Color.Zombie
				highlight.OutlineTransparency = 0
				highlight.Parent = child
				hiveHighlights[child] = highlight
			end
		end
	end
end

-- §6.1 / §10.3：客户端本地 SOURCE / PROTECTED 标签，只读取公开布尔属性。
local function refreshTags()
	for model, entry in tags do
		local root = model:GetAttribute(Constants.Attribute.Root) == true
		local protected = model:GetAttribute(Constants.Attribute.Protected) == true
		if model.Parent == nil or (not root and not protected) then
			entry.gui:Destroy()
			tags[model] = nil
		else
			local text = if root and protected then "SOURCE\nPROTECTED" elseif root then "SOURCE" else "PROTECTED"
			if entry.label.Text ~= text then
				entry.label.Text = text
				entry.label.TextColor3 = if root then VisualTokens.Color.Zombie else VisualTokens.Color.Cured
			end
		end
	end

	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") then
			local root = child:GetAttribute(Constants.Attribute.Root) == true
			local protected = child:GetAttribute(Constants.Attribute.Protected) == true
			if (root or protected) and tags[child] == nil then
				local billboard = Instance.new("BillboardGui")
				billboard.Name = "BTC_PublicTag"
				billboard.Size = UDim2.fromOffset(180, 52)
				-- §6.1：SOURCE 标签抬高到 5.2 studs，避免与撤离区门框上方的 EXIT 牌重叠。
				billboard.StudsOffset = Vector3.new(0, 5.2, 0)
				billboard.AlwaysOnTop = true
				billboard.MaxDistance = 90
				billboard.Parent = child

				local label = Instance.new("TextLabel")
				label.Name = "Text"
				label.BackgroundTransparency = 1
				label.Size = UDim2.fromScale(1, 1)
				label.Font = Enum.Font.GothamBold
				label.TextScaled = true
				label.TextWrapped = true
				label.TextColor3 = if root then VisualTokens.Color.Zombie else VisualTokens.Color.Cured
				label.TextStrokeColor3 = VisualTokens.Color.Night
				label.TextStrokeTransparency = 0.3
				label.Text = if root and protected then "SOURCE\nPROTECTED" elseif root then "SOURCE" else "PROTECTED"
				label.Parent = billboard

				tags[child] = { gui = billboard, label = label }
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

local refreshRelinkArrow: (string?, number) -> ()
local refreshChannel: (number) -> ()

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

	local now = Workspace:GetServerTimeNow()
	local text, color = stateStyle(state)
	-- §7.3：本人尸变期间给出倒计时，避免被咬后毫无反馈。
	if state == "INCUBATING" and incubationEndsAt ~= nil then
		text = string.format("INFECTED — TURNING IN %ds", math.max(0, math.ceil(incubationEndsAt - now)))
	end
	if state ~= "INCUBATING" then
		incubationEndsAt = nil
	end
	if state == "INFECTED" and combat == "DEAD" then
		local respawnAt = if character ~= nil then character:GetAttribute(Constants.Attribute.RespawnAt) else nil
		if type(respawnAt) == "number" then
			local remaining = math.max(0, respawnAt - now)
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
	elseif state == "UNSTABLE" then
		local deadline = unstableEndsAt
		if deadline ~= nil then
			text = string.format("%s %.1fs", StateLabels.UNSTABLE.en, math.max(0, deadline - now))
		else
			text = StateLabels.UNSTABLE.en
		end
		color = VisualTokens.Color.Disconnected
	elseif state == "HUMAN" and character ~= nil and character:GetAttribute(Constants.Attribute.Protected) == true then
		text = `{StateLabels.HUMAN.en} · {StateLabels.CURE_IMMUNITY.en}`
		color = VisualTokens.Color.Cured
	end

	if state ~= "UNSTABLE" then
		unstableEndsAt = nil
		relinkHintDirection = nil
		relinkHintDistance = -1
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
			-- 武器名已经是 MELEE，弹药位留空避免“MELEE MELEE”的重复显示。
			ammoLabel.Text = "—"
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

	-- 携带解药：公开的手上小支（BTC_Cure）足以让 HUD 显示图标。
	local hasCure = state == "HUMAN" and character ~= nil and character:FindFirstChild("BTC_Cure", true) ~= nil
	cureLabel.Visible = hasCure
	if hasCure then
		cureLabel.Text = "CURE — HOLD INTERACT"
	end

	-- 交互提示（例如瞄准零号时提示普通解药无效）。
	noticeLabel.Visible = false
	if hudNoticeText ~= nil and now - hudNoticeAt <= 2.5 then
		noticeLabel.Text = hudNoticeText
		noticeLabel.TextColor3 = VisualTokens.Color.Disconnected
		noticeLabel.Visible = true
	elseif controller ~= nil then
		local noticeText, noticeAt = controller.getInteractNotice()
		if noticeText ~= nil and now - noticeAt <= 2.5 then
			noticeLabel.Text = noticeText
			noticeLabel.TextColor3 = VisualTokens.Color.Disconnected
			noticeLabel.Visible = true
		end
	end

	refreshRelinkArrow(state, now)
	refreshGunshotPing(state)
end

-- §11.2：断联者只从私有 RelinkHint 得到“方向 + 距离”，客户端据此画屏幕方向箭头。
function refreshRelinkArrow(state: string?, now: number)
	local direction = relinkHintDirection
	local camera = Workspace.CurrentCamera
	if
		state ~= "UNSTABLE"
		or direction == nil
		or camera == nil
		or now - relinkHintAt > 1.2
		or relinkHintDistance < 0
	then
		relinkArrow.Visible = false
		return
	end

	local localDirection = camera.CFrame:VectorToObjectSpace(direction)
	local angle = math.deg(math.atan2(localDirection.X, -localDirection.Z))
	local rad = math.rad(angle)
	relinkArrow.Rotation = angle
	relinkArrow.Position = UDim2.fromScale(0.5 + math.sin(rad) * 0.17, 0.5 - math.cos(rad) * 0.17)
	relinkArrow.Text = "▲"
	relinkArrow.TextColor3 = VisualTokens.Color.Disconnected
	relinkArrow.Visible = true
end

local function channelColor(kind: string?): Color3
	if kind == "CURE" then
		return VisualTokens.Color.Cured
	elseif kind == "EXTRACT" then
		return VisualTokens.Color.Exit
	end
	return VisualTokens.Color.Disconnected
end

-- 读条环：24 段圆环 + 中央文字（kind / 百分比 / 剩余秒）。
function refreshChannel(now: number)
	local ratio = channelRatio
	local active = channelKind ~= nil and ratio ~= nil and now - channelUpdatedAt <= 0.6 and ratio < 0.999
	if not active then
		channelRing.Visible = false
		return
	end

	local kind = channelKind or ""
	local filled = math.floor(math.clamp(ratio :: number, 0, 1) * #channelSegments + 0.5)
	local color = channelColor(channelKind)
	for index, segment in channelSegments do
		if index <= filled then
			segment.BackgroundColor3 = color
			segment.BackgroundTransparency = 0
		else
			segment.BackgroundColor3 = VisualTokens.Color.SurfaceSlate
			segment.BackgroundTransparency = 0.45
		end
	end

	local remaining = math.max(0, channelDuration - channelElapsed)
	channelLabel.Text = string.format("%s %d%%\n%.1fs", kind, math.floor((ratio :: number) * 100), remaining)
	channelLabel.TextColor3 = color
	channelRing.Visible = true
end

local function refreshPhase()
	local now = Workspace:GetServerTimeNow()
	if phase == nil then
		phaseLabel.Text = ""
		evacuatedLabel.Text = ""
		exitBannerLabel.Visible = false
		channelRing.Visible = false
		return
	end

	local suffix = ""
	if phaseEndsAt ~= nil and phase ~= "RESULT" then
		local remaining = math.max(0, math.ceil(phaseEndsAt - now))
		suffix = ` · {remaining}s`
	end
	phaseLabel.Text = phase .. suffix
	evacuatedLabel.Text = string.format("EVACUATED %d/%d", extractedCount, requiredExtracted)

	exitBannerLabel.Visible = now < exitBannerUntil
	if exitBannerLabel.Visible then
		exitBannerLabel.Text = "EXTRACTION OPEN — REACH THE EXIT"
	end

	refreshChannel(now)
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

	evacuatedLabel = makeLabel(root, "Evacuated", 20)
	evacuatedLabel.AnchorPoint = Vector2.new(1, 0)
	evacuatedLabel.Position = UDim2.fromScale(0.97, 0.04)
	evacuatedLabel.Size = UDim2.fromScale(0.32, 0.06)
	evacuatedLabel.TextXAlignment = Enum.TextXAlignment.Right
	evacuatedLabel.TextColor3 = VisualTokens.Color.Cured

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

	-- §13.2：撤离开启横幅（公共事件，不含任何秘密信息）。
	exitBannerLabel = makeLabel(root, "ExitBanner", 24)
	exitBannerLabel.AnchorPoint = Vector2.new(0.5, 0)
	exitBannerLabel.Position = UDim2.fromScale(0.5, 0.12)
	exitBannerLabel.Size = UDim2.fromScale(0.78, 0.065)
	exitBannerLabel.TextXAlignment = Enum.TextXAlignment.Center
	exitBannerLabel.TextColor3 = VisualTokens.Color.Exit
	exitBannerLabel.Visible = false

	-- 交互提示：例如“SOURCE — cure has no effect”。
	noticeLabel = makeLabel(root, "Notice", 22)
	noticeLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	noticeLabel.Position = UDim2.fromScale(0.5, 0.71)
	noticeLabel.Size = UDim2.fromScale(0.8, 0.06)
	noticeLabel.TextXAlignment = Enum.TextXAlignment.Center
	noticeLabel.TextColor3 = VisualTokens.Color.Disconnected
	noticeLabel.Visible = false

	-- 携带解药图标（公开的手上小支，客户端本地显示）。
	cureLabel = makeLabel(root, "Cure", 20)
	cureLabel.AnchorPoint = Vector2.new(0, 1)
	cureLabel.Position = UDim2.fromScale(0.03, 0.90)
	cureLabel.Size = UDim2.fromScale(0.38, 0.055)
	cureLabel.TextXAlignment = Enum.TextXAlignment.Left
	cureLabel.TextColor3 = VisualTokens.Color.Cured
	cureLabel.Visible = false

	-- §11.2：断联方向箭头（只用私有 RelinkHint 的方向与距离）。
	relinkArrow = makeLabel(root, "RelinkArrow", 40)
	relinkArrow.Text = "▲"
	relinkArrow.AnchorPoint = Vector2.new(0.5, 0.5)
	relinkArrow.Size = UDim2.fromOffset(46, 46)
	relinkArrow.TextColor3 = VisualTokens.Color.Disconnected
	relinkArrow.TextXAlignment = Enum.TextXAlignment.Center
	relinkArrow.Visible = false

	-- §10.2 / §11.2 / §13.2：读条环（24 段）+ 中央进度文字。
	channelRing = Instance.new("Frame")
	channelRing.Name = "ChannelRing"
	channelRing.AnchorPoint = Vector2.new(0.5, 0.5)
	channelRing.Position = UDim2.fromScale(0.5, 0.62)
	channelRing.Size = UDim2.fromOffset(150, 150)
	channelRing.BackgroundTransparency = 1
	channelRing.Visible = false
	channelRing.Parent = root

	table.clear(channelSegments)
	for index = 1, 24 do
		local angle = (index - 1) / 24 * math.pi * 2
		local segment = Instance.new("Frame")
		segment.Name = `Segment{index}`
		segment.AnchorPoint = Vector2.new(0.5, 0.5)
		segment.Position = UDim2.fromScale(0.5 + math.sin(angle) * 0.40, 0.5 - math.cos(angle) * 0.40)
		segment.Size = UDim2.fromOffset(8, 24)
		segment.Rotation = math.deg(angle)
		segment.BackgroundColor3 = VisualTokens.Color.SurfaceSlate
		segment.BackgroundTransparency = 0.45
		segment.BorderSizePixel = 0
		segment.Parent = channelRing

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = segment
		table.insert(channelSegments, segment)
	end

	channelLabel = makeLabel(channelRing, "ChannelText", 18)
	channelLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	channelLabel.Position = UDim2.fromScale(0.5, 0.5)
	channelLabel.Size = UDim2.fromOffset(112, 56)
	channelLabel.TextScaled = true
	channelLabel.TextXAlignment = Enum.TextXAlignment.Center

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local publicRemote = remotes:WaitForChild("PublicMatchEvent") :: RemoteEvent
	local privateRemote = remotes:WaitForChild("PrivatePlayerEvent") :: RemoteEvent
	publicRemote.OnClientEvent:Connect(handlePublicEvent)
	privateRemote.OnClientEvent:Connect(handlePrivateEvent)

	RunService.RenderStepped:Connect(function(deltaTime: number)
		updateAccumulator += deltaTime
		if updateAccumulator < 0.1 then
			return
		end
		updateAccumulator = 0

		refreshState()
		refreshPhase()
		refreshHighlights()
		refreshTags()
		refreshHiveMarks()
		refreshCombatFeed()
	end)

	refreshState()
	refreshPhase()
	refreshTags()
end

return table.freeze(HUDController)
