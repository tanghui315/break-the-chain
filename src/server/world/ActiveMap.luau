--!strict
-- 当前对局使用的灰盒地图（GDB V1.1 §14、§24.4）。按人数档的 mapTier 选图：SMALL → 180×180，
-- MEDIUM / LARGE → 260×260（LARGE 图未做，暂退回 MEDIUM）。所有服务在调用时读取 get()，不缓存布局。
-- 纯模块：只持有选择状态，建图由 GreyboxBuilder 负责。

local GreyboxLayout = require("./GreyboxLayout")
local GreyboxLayoutMedium = require("./GreyboxLayoutMedium")

export type Variant = "GREYBOX_SMALL" | "GREYBOX_MEDIUM"

local layouts: { [Variant]: GreyboxLayout.Layout } = {
	GREYBOX_SMALL = GreyboxLayout,
	GREYBOX_MEDIUM = GreyboxLayoutMedium,
}

local current: Variant = "GREYBOX_SMALL"

local ActiveMap = {}

function ActiveMap.get(): GreyboxLayout.Layout
	return layouts[current]
end

function ActiveMap.getVariant(): Variant
	return current
end

function ActiveMap.layoutFor(variant: Variant): GreyboxLayout.Layout
	return layouts[variant]
end

-- 人数档 mapTier → 地图变体。
function ActiveMap.variantForTier(mapTier: string): Variant
	if mapTier == "SMALL" then
		return "GREYBOX_SMALL"
	end
	return "GREYBOX_MEDIUM"
end

-- 解析 Studio 调试覆盖值（"SMALL" / "MEDIUM" / 完整变体名），无法识别返回 nil。
function ActiveMap.parseVariant(value: unknown): Variant?
	if value == "SMALL" or value == "GREYBOX_SMALL" then
		return "GREYBOX_SMALL"
	elseif value == "MEDIUM" or value == "GREYBOX_MEDIUM" then
		return "GREYBOX_MEDIUM"
	end
	return nil
end

-- 返回是否发生切换（调用方据此重建 workspace.Map）。
function ActiveMap.set(variant: Variant): boolean
	if variant == current then
		return false
	end
	current = variant
	return true
end

return ActiveMap
