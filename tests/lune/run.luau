--!strict
-- 运行 tests/lune 下所有 *.spec.luau，每个文件一个独立的 Lune 进程。
-- 用法（在仓库根目录）：lune run tests/lune/run

local fs = require("@lune/fs")
local process = require("@lune/process")

local ROOT = "tests/lune"

local function collectSpecs(dir: string, out: { string })
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			collectSpecs(path, out)
		elseif string.sub(name, -#".spec.luau") == ".spec.luau" then
			table.insert(out, path)
		end
	end
end

local specs: { string } = {}
collectSpecs(ROOT, specs)
table.sort(specs)

if #specs == 0 then
	print(`no *.spec.luau found under {ROOT}`)
	process.exit(1)
end

local failedSpecs: { string } = {}
for _, spec in specs do
	print(`\n▶ {spec}`)
	local result = process.exec("lune", { "run", spec }, { stdio = "inherit" })
	if not result.ok then
		table.insert(failedSpecs, spec)
	end
end

print(`\n{#specs - #failedSpecs}/{#specs} spec files passed`)
if #failedSpecs > 0 then
	print(`failed: {table.concat(failedSpecs, ", ")}`)
	process.exit(1)
end
