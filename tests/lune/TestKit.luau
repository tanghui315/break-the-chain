--!strict
-- 极简测试工具，供 Lune 下的 *.spec.luau 使用。
-- 每个 spec 文件在独立进程中运行（见 run.luau），结束时调用 finish()，有失败则以非零退出码退出。

local process = require("@lune/process")

local TestKit = {}

local passed = 0
local failed = 0
local suitePath: { string } = {}

local function fullName(name: string): string
	local parts = table.clone(suitePath)
	table.insert(parts, name)
	return table.concat(parts, " › ")
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

function TestKit.describe(name: string, body: () -> ())
	table.insert(suitePath, name)
	body()
	table.remove(suitePath)
end

function TestKit.it(name: string, body: () -> ())
	local ok, err = pcall(body)
	if ok then
		passed += 1
		print(`  ✓ {fullName(name)}`)
	else
		failed += 1
		print(`  ✗ {fullName(name)}\n      {err}`)
	end
end

function TestKit.expect(actual: any)
	local matchers = {}

	function matchers.toBe(expected: any)
		if actual ~= expected then
			error(`expected {show(expected)}, got {show(actual)}`, 2)
		end
	end

	function matchers.toEqual(expected: any)
		if not deepEqual(actual, expected) then
			error(`expected deep-equal value, got {show(actual)}`, 2)
		end
	end

	function matchers.toBeNil()
		if actual ~= nil then
			error(`expected nil, got {show(actual)}`, 2)
		end
	end

	function matchers.toBeTruthy()
		if not actual then
			error(`expected truthy value, got {show(actual)}`, 2)
		end
	end

	return matchers
end

function TestKit.finish()
	print(`  {passed} passed, {failed} failed`)
	if failed > 0 then
		process.exit(1)
	end
end

return TestKit
