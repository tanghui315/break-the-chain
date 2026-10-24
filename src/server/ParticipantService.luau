--!strict
-- ParticipantId 注册表（GDB V1.1 §20.9）：所有对局服务只认 ParticipantId，不直接依赖 Player。
-- Player 的 ParticipantId 为 "U:<userId>"；Bot 为 "B:<botIndex>:<roundId>"（Types.ParticipantId）。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(ReplicatedStorage.Shared.Constants)

export type ParticipantKind = "Player" | "Bot"

export type Participant = {
	id: string,
	kind: ParticipantKind,
	displayName: string,
	player: Player?,
	character: Model?,
}

type Registry = {
	byId: { [string]: Participant },
	byUserId: { [number]: Participant },
	byCharacter: { [Model]: Participant },
}

local registry: Registry = {
	byId = {},
	byUserId = {},
	byCharacter = {},
}

local ParticipantService = {}

function ParticipantService.playId(player: Player): string
	return string.format("U:%d", player.UserId)
end

function ParticipantService.botId(botIndex: number, roundId: string): string
	return string.format("B:%d:%s", botIndex, roundId)
end

-- 每局开始前清空注册表；旧 Participant 对象不应跨局存活。
function ParticipantService.reset()
	table.clear(registry.byId)
	table.clear(registry.byUserId)
	table.clear(registry.byCharacter)
end

function ParticipantService.registerPlayer(player: Player): Participant
	local id = ParticipantService.playId(player)
	local existing = registry.byId[id]
	if existing ~= nil then
		return existing
	end

	local participant: Participant = {
		id = id,
		kind = "Player",
		displayName = player.DisplayName,
		player = player,
		character = nil,
	}
	registry.byId[id] = participant
	registry.byUserId[player.UserId] = participant
	return participant
end

function ParticipantService.registerBot(botIndex: number, id: string): Participant
	local participant: Participant = {
		id = id,
		kind = "Bot",
		displayName = string.format("Bot %d", botIndex),
		player = nil,
		character = nil,
	}
	registry.byId[id] = participant
	return participant
end

-- 角色生成 / 重生 / Bot 重建后调用；同时写入公开的 ParticipantId 属性，供客户端选择扑咬提示目标。
function ParticipantService.setCharacter(id: string, character: Model?)
	local participant = registry.byId[id]
	if participant == nil then
		return
	end

	local previous = participant.character
	if previous ~= nil and previous ~= character and previous.Parent ~= nil then
		registry.byCharacter[previous] = nil
	end

	participant.character = character
	if character ~= nil then
		registry.byCharacter[character] = participant
		character:SetAttribute(Constants.Attribute.ParticipantId, id)
	end
end

function ParticipantService.getById(id: string): Participant?
	return registry.byId[id]
end

function ParticipantService.getByPlayer(player: Player): Participant?
	return registry.byUserId[player.UserId]
end

function ParticipantService.getByCharacter(character: Model): Participant?
	return registry.byCharacter[character]
end

function ParticipantService.all(): { [string]: Participant }
	return registry.byId
end

function ParticipantService.remove(id: string)
	local participant = registry.byId[id]
	if participant == nil then
		return
	end

	registry.byId[id] = nil
	if participant.player ~= nil then
		registry.byUserId[participant.player.UserId] = nil
	end
	if participant.character ~= nil then
		registry.byCharacter[participant.character] = nil
	end
end

function ParticipantService.removeByPlayer(player: Player)
	ParticipantService.remove(ParticipantService.playId(player))
end

-- 真人在线且能参与本局的快照（A0 不处理中途加入，回合开始时冻结）。
function ParticipantService.onlinePlayers(): { Player }
	local players: { Player } = {}
	for _, player in Players:GetPlayers() do
		table.insert(players, player)
	end
	return players
end

return table.freeze(ParticipantService)
