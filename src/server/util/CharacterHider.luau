--!strict
-- 已撤离 / 观战角色的隐藏与恢复（GDB V1.1 §7.1、§13.2、§19.5）。
-- 只改本局角色实例的可见性与碰撞，不写回任何感染状态；客户端仍能读到公开的 BTC_State。
-- 与 ZombieCombatService 的死亡隐藏分开：这里服务的是 EXTRACTED / SPECTATOR，不涉及战斗。

type SavedPart = {
	anchored: boolean,
	transparency: number,
	canCollide: boolean,
	canQuery: boolean,
	canTouch: boolean,
	castShadow: boolean,
}

type SavedHumanoid = {
	displayDistanceType: Enum.HumanoidDisplayDistanceType,
	nameDisplayDistance: number,
	healthDisplayDistance: number,
}

type SavedCharacter = {
	parts: { [BasePart]: SavedPart },
	humanoid: SavedHumanoid?,
}

local saved: { [Model]: SavedCharacter } = {}

local CharacterHider = {}

function CharacterHider.hide(character: Model)
	if saved[character] ~= nil then
		return
	end
	local entry: SavedCharacter = { parts = {}, humanoid = nil }

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			entry.parts[descendant] = {
				anchored = descendant.Anchored,
				transparency = descendant.Transparency,
				canCollide = descendant.CanCollide,
				canQuery = descendant.CanQuery,
				canTouch = descendant.CanTouch,
				castShadow = descendant.CastShadow,
			}
			descendant.Anchored = true
			descendant.Transparency = 1
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		entry.humanoid = {
			displayDistanceType = humanoid.DisplayDistanceType,
			nameDisplayDistance = humanoid.NameDisplayDistance,
			healthDisplayDistance = humanoid.HealthDisplayDistance,
		}
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
		humanoid:Move(Vector3.zero, false)
	end

	saved[character] = entry
end

function CharacterHider.restore(character: Model)
	local entry = saved[character]
	if entry == nil then
		return
	end
	saved[character] = nil

	for part, values in entry.parts do
		if part.Parent ~= nil then
			part.Transparency = values.transparency
			part.CanCollide = values.canCollide
			part.CanQuery = values.canQuery
			part.CanTouch = values.canTouch
			part.CastShadow = values.castShadow
			part.Anchored = values.anchored
		end
	end

	local humanoid = entry.humanoid
	if humanoid ~= nil then
		local instance = character:FindFirstChildOfClass("Humanoid")
		if instance ~= nil then
			instance.DisplayDistanceType = humanoid.displayDistanceType
			instance.NameDisplayDistance = humanoid.nameDisplayDistance
			instance.HealthDisplayDistance = humanoid.healthDisplayDistance
		end
	end
end

-- 回合结束统一恢复，避免下一个回合仍沿用隐藏状态（角色通常会被重新生成）。
function CharacterHider.restoreAll()
	local models: { Model } = {}
	for model in saved do
		table.insert(models, model)
	end
	for _, model in models do
		CharacterHider.restore(model)
	end
end

return table.freeze(CharacterHider)
