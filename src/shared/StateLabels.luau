--!strict
-- 状态枚举 → 显示文案映射（GDB V1.1 §7.5）。
-- 正式文案走 LocalizationTable；这里的 en / zh 是默认值与本地化键的来源。首发主语言为英文（§17.5）。

export type Label = { key: string, en: string, zh: string }

local StateLabels: { [string]: Label } = {
	-- 主状态
	HUMAN = { key = "State.Human", en = "HUMAN", zh = "人类" },
	INCUBATING = { key = "State.Turning", en = "TURNING", zh = "尸变中" },
	INFECTED = { key = "State.Infected", en = "INFECTED", zh = "感染者" },
	UNSTABLE = { key = "State.Disconnected", en = "DISCONNECTED", zh = "断联" },
	EXTRACTED = { key = "State.Evacuated", en = "EVACUATED", zh = "已撤离" },
	SPECTATOR = { key = "State.Spectating", en = "SPECTATING", zh = "观战" },

	-- 标签与定时效果
	ROOT = { key = "Tag.Source", en = "SOURCE", zh = "零号源头" },
	CURE_IMMUNITY = { key = "Effect.Protected", en = "PROTECTED", zh = "受保护" },

	-- §9A 丧尸战斗生命状态与擒抱效果（GDB §7.5）
	DOWNED = { key = "State.Downed", en = "DOWNED", zh = "倒地" },
	DEAD = { key = "State.Respawn", en = "RESPAWNING", zh = "复活中" },
	STUNNED = { key = "State.Stunned", en = "STUNNED", zh = "电击中" },
	GRABBED = { key = "Effect.Grabbed", en = "GRABBED", zh = "被抓住" },
	GRABBING = { key = "Effect.Grabbing", en = "GRABBING", zh = "抓住中" },

	-- 事件（不是状态）
	CURE = { key = "Event.Cured", en = "CURED", zh = "已治愈" },
	RELINK = { key = "Event.LinkRestored", en = "LINK RESTORED", zh = "重连成功" },
	CHAIN_CUT = { key = "Event.ChainBroken", en = "CHAIN BROKEN", zh = "感染链断裂" },
}

return table.freeze(StateLabels)
