--!strict
-- 人类冲刺耐力（GDB V1.1 §9.3、§24.4）：最多连续冲刺 SprintMaxSeconds，停止后按一半速度恢复。
-- 纯逻辑：状态是普通表，配置通过参数传入。

export type Config = {
	Greybox: {
		SprintMaxSeconds: number,
		StaminaRegenRatio: number,
		SprintMinStartSeconds: number,
		HumanWalkSpeed: number,
		HumanSprintSpeed: number,
	},
}

-- 状态同时保留创建时的配置，使 setSprintIntent / step 无需额外参数也能读取阈值与恢复速度。
export type Stamina = {
	value: number, -- 剩余可冲刺秒数，上限 SprintMaxSeconds
	sprinting: boolean,
	config: Config,
}

local Stamina = {}

local DRAIN_PER_SECOND = 1

function Stamina.new(config: Config): Stamina
	return {
		value = config.Greybox.SprintMaxSeconds,
		sprinting = false,
		config = config,
	}
end

-- 冲刺意图：耐力低于起步阈值时不能开始冲刺；已在冲刺时不会因阈值被打断。
function Stamina.setSprintIntent(s: Stamina, wantSprint: boolean)
	if wantSprint then
		if s.sprinting or s.value >= s.config.Greybox.SprintMinStartSeconds then
			s.sprinting = true
		end
	else
		s.sprinting = false
	end
end

function Stamina.step(s: Stamina, dt: number)
	local delta = math.max(0, dt)
	local greybox = s.config.Greybox
	if s.sprinting then
		s.value = math.max(0, s.value - DRAIN_PER_SECOND * delta)
		if s.value <= 0 then
			s.value = 0
			s.sprinting = false
		end
	else
		s.value = math.min(greybox.SprintMaxSeconds, s.value + greybox.StaminaRegenRatio * delta)
	end
end

function Stamina.speedFor(config: Config, s: Stamina): number
	if s.sprinting then
		return config.Greybox.HumanSprintSpeed
	end
	return config.Greybox.HumanWalkSpeed
end

return table.freeze(Stamina)
