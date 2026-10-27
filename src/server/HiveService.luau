--!strict
-- 母巢指挥（GDB V1.1 §6.4，EXP-09）的服务端胶水层：校验零号身份、射程、视线与树归属，
-- 调用纯状态机 Hive，再把结果发给相关玩家、立起/熄灭信标、提供信标复活点。
-- 指令只沿感染树传递：只有 rootSeedId 与零号相同、且当前稳定（INFECTED）的丧尸能收到。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BalanceConfig = require(ReplicatedStorage.Shared.BalanceConfig)
local PublicEventTypes = require(ReplicatedStorage.Shared.PublicEventTypes)
local VisualTokens = require(ReplicatedStorage.Shared.VisualTokens)
local Hive = require(script.Parent.logic.Hive)
local InfectionGraph = require(script.Parent.logic.InfectionGraph)
local Cleaner = require(script.Parent.util.Cleaner)
local ActiveMap = require(script.Parent.world.ActiveMap)
local GrabService = require(script.Parent.GrabService)
local ParticipantService = require(script.Parent.ParticipantService)
local ZombieCombatService = require(script.Parent.ZombieCombatService)

export type Ability = "MARK" | "RALLY"

export type Context = {
	graph: InfectionGraph.Graph,
	startedAt: number,
	telemetry: (eventName: string, fields: { [string]: any }) -> (),
	firePrivate: (participantId: string, eventType: string, payload: { [string]: any }) -> (),
	-- 能力只在 CONTEST / EXTRACTION 可用。
	inActivePhase: () -> boolean,
	-- 撤离开启后返回撤离区中心，否则 nil（§6.4：信标不能立在撤离区附近）。
	activeExtractionCenter: () -> Vector3?,
}

local HiveService = {}

local context: Context? = nil
local state: Hive.State? = nil
local beaconParts: { [string]: Instance } = {}
local folder: Folder? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

local function toVec(position: Vector3): Hive.Vec3
	return { x = position.X, y = position.Y, z = position.Z }
end

local function rootPart(participantId: string): BasePart?
	local participant = ParticipantService.getById(participantId)
	local character = if participant ~= nil then participant.character else nil
	if character == nil or character.Parent == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function horizontalDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function mapLineOfSight(from: Vector3, to: Vector3): boolean
	local map = Workspace:FindFirstChild("Map")
	if map == nil then
		return true
	end
	rayParams.FilterDescendantsInstances = { map }
	local delta = to - from
	if delta.Magnitude < 0.01 then
		return true
	end
	return Workspace:Raycast(from, delta, rayParams) == nil
end

local function isRootZombie(graph: InfectionGraph.Graph, participantId: string): boolean
	local node = InfectionGraph.getState(graph, participantId)
	return node ~= nil and node.isRoot and node.state == "INFECTED"
end

-- 该零号仍连在树上的稳定丧尸（含零号本人）。
local function treeMembers(graph: InfectionGraph.Graph, rootId: string): { string }
	local rootNode = InfectionGraph.getState(graph, rootId)
	local seed = if rootNode ~= nil then rootNode.rootSeedId else nil
	local out: { string } = {}
	if seed == nil then
		return out
	end
	for _, id in InfectionGraph.participantIds(graph) do
		local node = InfectionGraph.getState(graph, id)
		if node ~= nil and node.state == "INFECTED" and node.rootSeedId == seed then
			table.insert(out, id)
		end
	end
	return out
end

-- 丧尸所属树的零号（零号离局后为 nil：VirtualRoot 不拥有母巢能力）。
local function rootIdFor(graph: InfectionGraph.Graph, zombieId: string): string?
	local node = InfectionGraph.getState(graph, zombieId)
	if node == nil or node.state ~= "INFECTED" or node.rootSeedId == nil then
		return nil
	end
	for _, id in InfectionGraph.participantIds(graph) do
		local other = InfectionGraph.getState(graph, id)
		if other ~= nil and other.isRoot and other.rootSeedId == node.rootSeedId and other.state == "INFECTED" then
			return id
		end
	end
	return nil
end

local function ensureFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "HiveBeacons"
	created.Parent = Workspace
	folder = created
	return created
end

-- 信标是公开的（§6.4 全场可见）：发光立柱 + 地面圆环 + HIVE 标签，不碰撞、不参与射线。
local function makeBeacon(rootId: string, position: Hive.Vec3)
	local floorY = ActiveMap.get().floorTopY
	local model = Instance.new("Model")
	model.Name = `Beacon_{rootId}`

	local pillar = Instance.new("Part")
	pillar.Name = "Pillar"
	pillar.Anchored = true
	pillar.Size = Vector3.new(1.2, 12, 1.2)
	pillar.CFrame = CFrame.new(position.x, floorY + 6, position.z)
	pillar.Material = Enum.Material.Neon
	pillar.Color = VisualTokens.Color.Zombie
	pillar.Transparency = 0.25
	pillar.CanCollide = false
	pillar.CanTouch = false
	pillar.CanQuery = false
	pillar.CastShadow = false
	pillar.Parent = model

	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.Size = Vector3.new(0.12, 10, 10)
	ring.CFrame = CFrame.new(position.x, floorY + 0.06, position.z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Material = Enum.Material.Neon
	ring.Color = VisualTokens.Color.Zombie
	ring.Transparency = 0.6
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Parent = model

	local light = Instance.new("PointLight")
	light.Color = VisualTokens.Color.Zombie
	light.Brightness = 2
	light.Range = 18
	light.Parent = pillar

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(120, 32)
	billboard.StudsOffset = Vector3.new(0, 7.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 220
	billboard.Parent = pillar
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = VisualTokens.Color.Zombie
	label.TextStrokeColor3 = VisualTokens.Color.Night
	label.TextStrokeTransparency = 0.3
	label.Text = "HIVE"
	label.Parent = billboard

	model.Parent = ensureFolder()
	beaconParts[rootId] = model
end

local function removeBeacon(rootId: string)
	local model: Instance? = beaconParts[rootId]
	if model ~= nil then
		model:Destroy()
		beaconParts[rootId] = nil
	end
end

local function notifyRoot(rootId: string, ability: Ability, ok: boolean, reason: string, now: number)
	local ctx = context
	local current = state
	if ctx == nil or current == nil then
		return
	end
	ctx.firePrivate(rootId, PublicEventTypes.Private.HiveAbilityResult, {
		ability = ability,
		ok = ok,
		reason = reason,
		markReadyIn = math.max(0, Hive.markReadyAt(current, rootId) - now),
		rallyReadyIn = math.max(0, Hive.rallyReadyAt(current, rootId) - now),
	})
end

local function report(
	ability: Ability,
	rootId: string,
	ok: boolean,
	reason: string,
	now: number,
	notify: boolean,
	receivers: number?
)
	local ctx = context
	if ctx == nil then
		return
	end
	if notify then
		notifyRoot(rootId, ability, ok, reason, now)
	end
	-- Bot 的冷却/条件不满足属于高频轮询，不记埋点；真人每次按键都记。
	if ok or notify then
		ctx.telemetry("root_ability_used", {
			ability = ability,
			result = reason,
			receivers = receivers or 0,
			rootId = rootId,
			elapsedSec = string.format("%.1f", math.max(0, now - ctx.startedAt)),
		})
	end
end

function HiveService.reset()
	for rootId in beaconParts do
		removeBeacon(rootId)
	end
	local existing = folder
	if existing ~= nil then
		existing:Destroy()
	end
	folder = nil
	context = nil
	state = nil
end

-- 每局开始调用；enabled=false 时所有请求都被拒绝，复活不受影响（A 组）。
function HiveService.begin(ctx: Context, roundCleaner: Cleaner.Cleaner, enabled: boolean)
	HiveService.reset()
	if not enabled then
		return
	end
	context = ctx
	state = Hive.new(BalanceConfig)
	Cleaner.add(roundCleaner, function()
		HiveService.reset()
	end)
end

function HiveService.enabled(): boolean
	return state ~= nil
end

function HiveService.isRoot(participantId: string): boolean
	local ctx = context
	return ctx ~= nil and isRootZombie(ctx.graph, participantId)
end

local function precheck(rootId: string, now: number): (boolean, string)
	local ctx = context
	if ctx == nil or state == nil then
		return false, "DISABLED"
	end
	if not ctx.inActivePhase() then
		return false, "PHASE"
	end
	if not isRootZombie(ctx.graph, rootId) then
		return false, "NOT_ROOT"
	end
	if not ZombieCombatService.canAct(rootId, now) or GrabService.hasGrab(rootId) then
		return false, "NOT_ACTIVE"
	end
	return true, "OK"
end

-- 源头标记：射程内、地图视线畅通的最近人类（HUMAN / INCUBATING）。
function HiveService.requestMark(rootId: string, now: number, notify: boolean): (boolean, string)
	local ok, reason = precheck(rootId, now)
	local ctx = context
	local current = state
	if not ok or ctx == nil or current == nil then
		if notify then
			notifyRoot(rootId, "MARK", false, reason, now)
		end
		return false, reason
	end
	local origin = rootPart(rootId)
	if origin == nil then
		return false, "NO_CHARACTER"
	end

	local targetId: string? = nil
	local best = math.huge
	for _, id in InfectionGraph.participantIds(ctx.graph) do
		local node = InfectionGraph.getState(ctx.graph, id)
		if node ~= nil and (node.state == "HUMAN" or node.state == "INCUBATING") then
			local part = rootPart(id)
			if part ~= nil then
				local d = horizontalDistance(origin.Position, part.Position)
				if d <= BalanceConfig.RootMarkRange and d < best and mapLineOfSight(origin.Position, part.Position) then
					best = d
					targetId = id
				end
			end
		end
	end
	if targetId == nil then
		report("MARK", rootId, false, "NO_TARGET", now, notify, nil)
		return false, "NO_TARGET"
	end
	if now < Hive.markReadyAt(current, rootId) then
		report("MARK", rootId, false, Hive.Reason.COOLDOWN, now, notify, nil)
		return false, Hive.Reason.COOLDOWN
	end

	local marked, markReason = Hive.tryMark(current, rootId, targetId, now)
	if not marked then
		report("MARK", rootId, false, markReason, now, notify, nil)
		return false, markReason
	end
	local receivers = treeMembers(ctx.graph, rootId)
	for _, id in receivers do
		ctx.firePrivate(id, PublicEventTypes.Private.HiveMark, {
			targetId = targetId,
			seconds = BalanceConfig.RootMarkSeconds,
		})
	end
	ctx.firePrivate(targetId, PublicEventTypes.Private.YouAreMarked, { seconds = BalanceConfig.RootMarkSeconds })
	report("MARK", rootId, true, Hive.Reason.OK, now, notify, #receivers)
	return true, Hive.Reason.OK
end

-- 母巢集结：开始 2 秒引导；完成后在原地立起信标（由 step 推进）。
function HiveService.requestRally(rootId: string, now: number, notify: boolean): (boolean, string)
	local ok, reason = precheck(rootId, now)
	local ctx = context
	local current = state
	if not ok or ctx == nil or current == nil then
		if notify then
			notifyRoot(rootId, "RALLY", false, reason, now)
		end
		return false, reason
	end
	local origin = rootPart(rootId)
	if origin == nil then
		return false, "NO_CHARACTER"
	end
	local nearestHuman = math.huge
	for _, id in InfectionGraph.participantIds(ctx.graph) do
		local node = InfectionGraph.getState(ctx.graph, id)
		if node ~= nil and (node.state == "HUMAN" or node.state == "INCUBATING") then
			local part = rootPart(id)
			if part ~= nil then
				nearestHuman = math.min(nearestHuman, horizontalDistance(origin.Position, part.Position))
			end
		end
	end
	local exit = ctx.activeExtractionCenter()
	local exitDistance = if exit ~= nil then horizontalDistance(origin.Position, exit) else nil
	local started, startReason =
		Hive.startRally(current, rootId, now, toVec(origin.Position), nearestHuman, exitDistance)
	-- Bot 每次思考都会尝试，被拒绝是常态，只记成功；真人每次按键都记。
	local quiet = not notify and not started
	if not quiet then
		report("RALLY", rootId, started, if started then "CHANNEL" else startReason, now, notify, nil)
	end
	return started, startReason
end

-- 仅 Studio 开发钩子使用：清空零号的标记 / 集结冷却，便于强制场景复测。
function HiveService.debugResetCooldowns(rootId: string): boolean
	local current = state
	if current == nil then
		return false
	end
	local root = current.roots[rootId]
	if root ~= nil then
		root.markReadyAt = -math.huge
		root.rallyReadyAt = -math.huge
	end
	return true
end

function HiveService.isChanneling(rootId: string): boolean
	local current = state
	return current ~= nil and Hive.channelOf(current, rootId) ~= nil
end

-- Bot 用：本树当前仍可见的标记目标中离自己最近的一个。
function HiveService.markedTargetFor(zombieId: string, now: number): string?
	local ctx = context
	local current = state
	if ctx == nil or current == nil then
		return nil
	end
	local rootId = rootIdFor(ctx.graph, zombieId)
	if rootId == nil then
		return nil
	end
	local origin = rootPart(zombieId)
	local bestId: string? = nil
	local best = math.huge
	for _, mark in Hive.activeMarks(current, now) do
		local node = InfectionGraph.getState(ctx.graph, mark.targetId)
		local part = rootPart(mark.targetId)
		if
			mark.rootId == rootId
			and node ~= nil
			and (node.state == "HUMAN" or node.state == "INCUBATING")
			and part ~= nil
		then
			local d = if origin ~= nil then horizontalDistance(origin.Position, part.Position) else 0
			if d < best then
				best = d
				bestId = mark.targetId
			end
		end
	end
	return bestId
end

-- 被咬：标记转化埋点（标记后 RootMarkConvertWindowSeconds 内）。
function HiveService.onBite(targetId: string, now: number)
	local ctx = context
	local current = state
	if ctx == nil or current == nil then
		return
	end
	local seconds = Hive.onBite(current, targetId, now)
	if seconds ~= nil then
		ctx.telemetry("root_mark_converted", {
			targetId = targetId,
			secondsAfterMark = string.format("%.1f", seconds),
		})
	end
end

-- ZombieCombatService 复活覆盖：本树信标存在时在信标处复活（零号本人仍走感染区）。
function HiveService.respawnPositionFor(zombieId: string, now: number): Vector3?
	local ctx = context
	local current = state
	if ctx == nil or current == nil then
		return nil
	end
	local node = InfectionGraph.getState(ctx.graph, zombieId)
	if node == nil or node.isRoot then
		return nil
	end
	local rootId = rootIdFor(ctx.graph, zombieId)
	if rootId == nil then
		return nil
	end
	local beacon = Hive.beaconOf(current, rootId, now)
	if beacon == nil then
		return nil
	end
	local map = ActiveMap.get()
	-- 在信标旁 3 studs 处出生，避免叠在立柱里。
	local position = Vector3.new(beacon.position.x + 3, map.floorTopY + map.characterSpawnY, beacon.position.z)
	local nearest = math.huge
	for _, id in InfectionGraph.participantIds(ctx.graph) do
		local other = InfectionGraph.getState(ctx.graph, id)
		local part = rootPart(id)
		if other ~= nil and (other.state == "HUMAN" or other.state == "INCUBATING") and part ~= nil then
			nearest = math.min(nearest, horizontalDistance(position, part.Position))
		end
	end
	ctx.telemetry("rally_respawn", {
		zombieId = zombieId,
		rootId = rootId,
		nearestHumanDistance = if nearest == math.huge then "inf" else string.format("%.1f", nearest),
	})
	return position
end

function HiveService.step(now: number)
	local ctx = context
	local current = state
	if ctx == nil or current == nil then
		return
	end
	for rootId in current.roots do
		local combat = ZombieCombatService.stateOf(rootId)
		local present = isRootZombie(ctx.graph, rootId) and rootPart(rootId) ~= nil
		-- 引导被电击 / 倒地 / 擒抱人类打断。
		if
			Hive.channelOf(current, rootId) ~= nil
			and (not present or not ZombieCombatService.canAct(rootId, now) or GrabService.hasGrab(rootId))
		then
			Hive.cancelRally(current, rootId, now)
			notifyRoot(rootId, "RALLY", false, "INTERRUPTED", now)
			ctx.telemetry("root_ability_used", {
				ability = "RALLY",
				result = "INTERRUPTED",
				receivers = 0,
				rootId = rootId,
				elapsedSec = string.format("%.1f", math.max(0, now - ctx.startedAt)),
			})
		end
		-- 零号倒地 / 死亡 / 离局：信标熄灭（§6.4 反制）。
		if Hive.beaconOf(current, rootId, now) ~= nil and (not present or combat == "DOWNED" or combat == "DEAD") then
			Hive.dropBeacon(current, rootId)
			removeBeacon(rootId)
			ctx.telemetry("rally_beacon_ended", { rootId = rootId, reason = "ROOT_DOWN" })
		end
	end

	local events = Hive.step(current, now, function(rootId: string): Hive.Vec3?
		local part = rootPart(rootId)
		return if part ~= nil then toVec(part.Position) else nil
	end)
	for _, event in events do
		if event.kind == "RALLY_PLACED" and event.position ~= nil then
			makeBeacon(event.rootId, event.position)
			notifyRoot(event.rootId, "RALLY", true, "PLACED", now)
			ctx.telemetry("root_ability_used", {
				ability = "RALLY",
				result = "PLACED",
				receivers = #treeMembers(ctx.graph, event.rootId),
				rootId = event.rootId,
				elapsedSec = string.format("%.1f", math.max(0, now - ctx.startedAt)),
			})
		elseif event.kind == "RALLY_CANCELLED" then
			notifyRoot(event.rootId, "RALLY", false, "MOVED", now)
		elseif event.kind == "BEACON_EXPIRED" then
			removeBeacon(event.rootId)
			ctx.telemetry("rally_beacon_ended", { rootId = event.rootId, reason = "EXPIRED" })
		end
	end
end

return table.freeze(HiveService)
