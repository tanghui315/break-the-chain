--!strict
-- §17.6 QA：客户端泄密审计。Studio 里在聊天输入 /btcleak（服务端切换 BTC_DebugLeakAudit 属性）后，
-- 本模块会把“这个客户端实际能读到的全部 Player/Character 属性”和“最近 20 条 Remote 载荷”打印出来。
-- 它只读取客户端本来就能拿到的数据，用于和 §17.2 权限矩阵逐项比对；审计失败属于 release blocker。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Constants)

type Entry = {
	channel: string,
	eventType: string,
	payload: any,
	at: number,
}

local MAX_ENTRIES = 20
local entries: { Entry } = {}
local armed = false

local DebugAudit = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function describe(value: any): string
	if typeof(value) == "Vector3" then
		return string.format("Vector3(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
	end
	if type(value) == "table" then
		local keys: { string } = {}
		for key in value do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		return "{" .. table.concat(keys, ",") .. "}"
	end
	return `{tostring(value)}`
end

local function record(channel: string, eventType: string, payload: any)
	table.insert(entries, {
		channel = channel,
		eventType = eventType,
		payload = payload,
		at = serverNow(),
	})
	while #entries > MAX_ENTRIES do
		table.remove(entries, 1)
	end
end

local function printAttributes()
	print("[LeakAudit] ===== Player attributes (all clients can read) =====")
	for _, player in Players:GetPlayers() do
		local parts: { string } = {}
		for key, value in player:GetAttributes() do
			table.insert(parts, `{key}={describe(value)}`)
		end
		table.sort(parts)
		print(`[LeakAudit] Player {player.Name}: {table.concat(parts, " ")}`)
	end

	print("[LeakAudit] ===== Character / Workspace model attributes =====")
	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") then
			local parts: { string } = {}
			for key, value in child:GetAttributes() do
				table.insert(parts, `{key}={describe(value)}`)
			end
			if #parts > 0 then
				table.sort(parts)
				print(`[LeakAudit] Model {child:GetFullName()}: {table.concat(parts, " ")}`)
			end
		end
	end
end

local function printPayloads()
	print(`[LeakAudit] ===== Last {#entries} remote payloads this client received =====`)
	for index, entry in entries do
		local payload = entry.payload
		local fields = ""
		if type(payload) == "table" then
			local parts: { string } = {}
			for key, value in payload do
				table.insert(parts, `{tostring(key)}={describe(value)}`)
			end
			table.sort(parts)
			fields = table.concat(parts, " ")
		else
			fields = describe(payload)
		end
		print(`[LeakAudit] #{index} {entry.channel} {entry.eventType} {fields}`)
	end
end

local function dump()
	printAttributes()
	printPayloads()
end

local function setArmed(value: boolean)
	armed = value
	print(`[LeakAudit] armed={value}`)
	if armed then
		dump()
	end
end

function DebugAudit.init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local publicRemote = remotes:WaitForChild("PublicMatchEvent") :: RemoteEvent
	local privateRemote = remotes:WaitForChild("PrivatePlayerEvent") :: RemoteEvent

	publicRemote.OnClientEvent:Connect(function(eventType: string, payload: any)
		record("PUBLIC", eventType, payload)
	end)
	privateRemote.OnClientEvent:Connect(function(eventType: string, payload: any)
		record("PRIVATE", eventType, payload)
	end)

	local player = Players.LocalPlayer
	player:GetAttributeChangedSignal(Constants.Attribute.DebugLeakAudit):Connect(function()
		setArmed(player:GetAttribute(Constants.Attribute.DebugLeakAudit) == true)
	end)
	setArmed(player:GetAttribute(Constants.Attribute.DebugLeakAudit) == true)

	-- 审计开启期间每 10 秒刷新一次，便于边玩边看属性/载荷变化。
	task.spawn(function()
		while true do
			task.wait(10)
			if armed then
				dump()
			end
		end
	end)
end

return table.freeze(DebugAudit)
