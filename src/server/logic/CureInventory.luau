--!strict
-- Gate A-2a 本局解药库存（GDB V1.1 §10.1、§10.2、§19.1）。
--
-- 解药是阵营共有的稀缺资源：每局数量由人数档 tier.cures 决定，开局用注入 RNG 分配到互不重复的补给槽。
--   - 同一名人类最多持有 1 支；拾取 / 消耗 / 掉落都由本模块维护唯一道具记录，绝不复制。
--   - 只有服务端确认治愈提交后才调用 consume；目标无效或读条取消不扣道具。
--   - 持有者尸变公开成为 INFECTED 时由调用方调用 drop，把同一件道具放回世界。
--   - 持有者离场同理 drop 在其最后位置（位置由调用方提供，本模块不解释坐标）。
--   - 失败 / 取消的治愈尝试进入 CureRetryCooldownSeconds 短冷却，防止刷交互（§10.1）。
-- 纯逻辑：无 Roblox 全局对象，RNG 与位置都由调用方注入，可在 Lune 中测试。

export type Config = {
	CureRetryCooldownSeconds: number,
}

-- 只声明本模块用到的字段，BalanceConfig 的人数档在结构上满足它
export type Tier = {
	cures: number,
}

export type Rng = (count: number) -> number

export type ItemState = "SUPPLY" | "CARRIED" | "DROPPED" | "CONSUMED"

export type Item = {
	id: string,
	state: ItemState,
	carrierId: string?,
	-- 世界位置：不透明值，通常是 Roblox Vector3 或测试里的普通表；由调用方解释。
	position: unknown,
	slotIndex: number?,
}

export type Inventory = {
	config: Config,
	items: { [string]: Item },
	order: { string },
	byCarrier: { [string]: string },
	retryUntil: { [string]: number },
	shortfall: number,
}

local CureInventory = {}

local STATE_SUPPLY: ItemState = "SUPPLY"
local STATE_CARRIED: ItemState = "CARRIED"
local STATE_DROPPED: ItemState = "DROPPED"
local STATE_CONSUMED: ItemState = "CONSUMED"

local State = table.freeze({
	SUPPLY = STATE_SUPPLY,
	CARRIED = STATE_CARRIED,
	DROPPED = STATE_DROPPED,
	CONSUMED = STATE_CONSUMED,
})
CureInventory.State = State

local Reason = table.freeze({
	UnknownItem = "UNKNOWN_ITEM",
	AlreadyCarried = "ALREADY_CARRIED",
	ItemUnavailable = "ITEM_UNAVAILABLE",
	NotHolding = "NOT_HOLDING",
})
CureInventory.Reason = Reason

local function wantedCount(value: number): number
	if value ~= value or value < 0 then
		return 0
	end
	return math.floor(value)
end

-- Fisher–Yates；每个槽位消耗一次 RNG，同样的 RNG 序列得到同样的补给分配。
local function shuffledIndices(count: number, rng: Rng): { number }
	local indices: { number } = {}
	for index = 1, count do
		indices[index] = index
	end
	for index = count, 2, -1 do
		local pick = rng(index)
		if type(pick) ~= "number" or pick ~= pick or pick % 1 ~= 0 or pick < 1 or pick > index then
			pick = index
		end
		indices[index], indices[pick] = indices[pick], indices[index]
	end
	return indices
end

-- 建立本局库存：从 slots 中随机挑 min(tier.cures, #slots) 个互不重复的补给槽。
-- 槽位不足时按实际槽数发放，shortfall 记录缺口（人数档要求但地图放不下的数量）。
function CureInventory.new(config: Config, tier: Tier, slots: { unknown }, rng: Rng): Inventory
	local wanted = wantedCount(tier.cures)
	local indices = shuffledIndices(#slots, rng)
	local itemCount = math.min(wanted, #slots)

	local items: { [string]: Item } = {}
	local order: { string } = {}
	for index = 1, itemCount do
		local slotIndex = indices[index]
		local itemId = `C:{index}`
		items[itemId] = {
			id = itemId,
			state = STATE_SUPPLY,
			carrierId = nil,
			position = slots[slotIndex],
			slotIndex = slotIndex,
		}
		table.insert(order, itemId)
	end

	return {
		config = config,
		items = items,
		order = order,
		byCarrier = {},
		retryUntil = {},
		shortfall = wanted - itemCount,
	}
end

function CureInventory.holderOf(inv: Inventory, itemId: string): string?
	local item = inv.items[itemId]
	if item == nil then
		return nil
	end
	return item.carrierId
end

function CureInventory.heldBy(inv: Inventory, participantId: string): string?
	return inv.byCarrier[participantId]
end

function CureInventory.getItem(inv: Inventory, itemId: string): Item?
	local item = inv.items[itemId]
	if item == nil then
		return nil
	end
	return {
		id = item.id,
		state = item.state,
		carrierId = item.carrierId,
		position = item.position,
		slotIndex = item.slotIndex,
	}
end

-- 拾取：只能拿 SUPPLY 或 DROPPED 的道具；每人最多 1 支（是否为 HUMAN 由调用方校验）。
function CureInventory.pickup(inv: Inventory, itemId: string, participantId: string): (boolean, string?)
	local item = inv.items[itemId]
	if item == nil then
		return false, Reason.UnknownItem
	end
	if inv.byCarrier[participantId] ~= nil then
		return false, Reason.AlreadyCarried
	end
	if item.state ~= STATE_SUPPLY and item.state ~= STATE_DROPPED then
		return false, Reason.ItemUnavailable
	end

	item.state = STATE_CARRIED
	item.carrierId = participantId
	item.position = nil
	item.slotIndex = nil
	inv.byCarrier[participantId] = itemId
	return true, nil
end

-- 消耗：只在服务端确认治愈提交后调用。道具进入 CONSUMED，不再可拾取。
function CureInventory.consume(inv: Inventory, participantId: string): (boolean, string?)
	local itemId = inv.byCarrier[participantId]
	if itemId == nil then
		return false, Reason.NotHolding
	end
	local item = inv.items[itemId]
	inv.byCarrier[participantId] = nil
	if item ~= nil then
		item.state = STATE_CONSUMED
		item.carrierId = nil
		item.position = nil
		item.slotIndex = nil
	end
	return true, itemId
end

-- 掉落：持有者尸变 / 离场时调用。道具保持同一个 itemId，只改变状态与位置，绝不复制。
function CureInventory.drop(inv: Inventory, participantId: string, position: unknown): (boolean, string?)
	local itemId = inv.byCarrier[participantId]
	if itemId == nil then
		return false, Reason.NotHolding
	end
	local item = inv.items[itemId]
	inv.byCarrier[participantId] = nil
	if item ~= nil then
		item.state = STATE_DROPPED
		item.carrierId = nil
		item.position = position
		item.slotIndex = nil
	end
	return true, itemId
end

-- 失败 / 取消的治愈尝试：进入短冷却（§10.1）。
function CureInventory.onFailedAttempt(inv: Inventory, participantId: string, now: number)
	local cooldown = inv.config.CureRetryCooldownSeconds
	if cooldown ~= cooldown or cooldown < 0 then
		cooldown = 0
	end
	inv.retryUntil[participantId] = now + cooldown
end

function CureInventory.canAttempt(inv: Inventory, participantId: string, now: number): boolean
	local readyAt = inv.retryUntil[participantId]
	return readyAt == nil or now >= readyAt
end

function CureInventory.retryReadyAt(inv: Inventory, participantId: string): number?
	return inv.retryUntil[participantId]
end

function CureInventory.countByState(inv: Inventory, state: ItemState): number
	local total = 0
	for _, item in inv.items do
		if item.state == state then
			total += 1
		end
	end
	return total
end

return table.freeze(CureInventory)
