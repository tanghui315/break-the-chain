--!strict
-- 回合级清理器（GDB V1.1 §19.5）：每局创建的连接、实例、函数与线程在回合结束时统一释放。
-- 用法：RoundService 每局 new() 一个，把该局创建的资源 add() 进去，结算后 clean()。

export type Cleaner = {
	_items: { any },
	_cleaned: boolean,
}

local Cleaner = {}

function Cleaner.new(): Cleaner
	return {
		_items = {},
		_cleaned = false,
	}
end

function Cleaner._release(item: any)
	local itemType = typeof(item)
	if itemType == "RBXScriptConnection" then
		item:Disconnect()
	elseif itemType == "Instance" then
		item:Destroy()
	elseif itemType == "thread" then
		task.cancel(item)
	elseif type(item) == "function" then
		item()
	end
end

-- 重复 clean 是安全的；clean 之后再 add 的资源会立即释放，避免异步任务在回合后继续持有资源。
function Cleaner.add(self: Cleaner, item: any): any
	if self._cleaned then
		Cleaner._release(item)
	else
		table.insert(self._items, item)
	end
	return item
end

function Cleaner.clean(self: Cleaner)
	if self._cleaned then
		return
	end
	self._cleaned = true
	for index = #self._items, 1, -1 do
		local item = self._items[index]
		self._items[index] = nil
		Cleaner._release(item)
	end
end

return table.freeze(Cleaner)
