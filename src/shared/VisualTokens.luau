--!strict
-- 视觉 Design Tokens（视觉圣经 V1.1 §2.1、§2.4）。名称稳定，数值可以微调。
-- 状态色只用于代表其明确语义的系统；尸变中不新增颜色，使用 Zombie 的低强度版本。

local T = {}

T.Color = table.freeze({
	Night = Color3.fromRGB(21, 30, 39), -- BG_NIGHT #151E27
	SurfaceSlate = Color3.fromRGB(40, 53, 66), -- SURFACE_SLATE #283542
	SurfaceConcrete = Color3.fromRGB(102, 119, 131), -- SURFACE_CONCRETE #667783
	TextPrimary = Color3.fromRGB(242, 245, 246), -- TEXT_PRIMARY #F2F5F6
	TextSecondary = Color3.fromRGB(181, 195, 204), -- TEXT_SECONDARY #B5C3CC
	Human = Color3.fromRGB(76, 201, 217), -- HUMAN_CYAN #4CC9D9
	Zombie = Color3.fromRGB(232, 86, 100), -- ZOMBIE_RED #E85664
	Disconnected = Color3.fromRGB(242, 184, 75), -- CHAIN_AMBER #F2B84B
	Cured = Color3.fromRGB(121, 216, 166), -- CURE_MINT #79D8A6
	NeutralWhite = Color3.fromRGB(221, 230, 235), -- NEUTRAL_WHITE #DDE6EB
	Exit = Color3.fromRGB(217, 242, 255), -- EXIT_BLUEWHITE #D9F2FF
})

return table.freeze(T)
