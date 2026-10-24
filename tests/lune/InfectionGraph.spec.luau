--!strict
-- InfectionGraph 属性测试（GDB V1.1 §8.2、§8.6、§11、§19.1、§23.1）：
-- G-01 ～ G-20 每条一个 it，外加 500 局 × 200 次随机操作的可重放属性测试。
-- 每一步（包括被拒绝的命令）之后都调用 assertInvariants；事件日志必须能在全新图上重放。

local TestKit = require("./TestKit")
local BalanceConfig = require("../../src/shared/BalanceConfig")
local InfectionGraph = require("../../src/server/logic/InfectionGraph")

local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Reason = InfectionGraph.Reason
local State = InfectionGraph.State

local Incubation = BalanceConfig.IncubationSeconds
local Disconnect = BalanceConfig.DisconnectSeconds
local Immunity = BalanceConfig.CuredImmunitySeconds
local BaseHold = BalanceConfig.ReconnectHoldSeconds
local RootHold = BaseHold * BalanceConfig.RootRelinkHoldMultiplier

local function check(graph: InfectionGraph.Graph)
	expect(InfectionGraph.assertInvariants(graph)).toBe(true)
end

local function newGraph(ids: { string }, roundId: string?): InfectionGraph.Graph
	local graph = InfectionGraph.new(BalanceConfig, roundId or "round-test", ids)
	check(graph)
	return graph
end

local function getState(graph: InfectionGraph.Graph, id: string): InfectionGraph.Participant?
	return InfectionGraph.getState(graph, id)
end

local function mustState(graph: InfectionGraph.Graph, id: string): InfectionGraph.Participant
	local participant = InfectionGraph.getState(graph, id)
	if participant == nil then
		error(`参与者 {id} 不存在`, 2)
	end
	return participant
end

local function ok(graph: InfectionGraph.Graph, result: InfectionGraph.Result): InfectionGraph.Result
	if not result.ok then
		error(`预期命令成功，实际被拒绝：{result.reason or "?"}`, 2)
	end
	check(graph)
	return result
end

local function rejected(
	graph: InfectionGraph.Graph,
	result: InfectionGraph.Result,
	reason: string
): InfectionGraph.Result
	expect(result.ok).toBe(false)
	expect(result.reason).toBe(reason)
	expect(#result.events).toBe(0)
	check(graph)
	return result
end

local function createRoot(graph: InfectionGraph.Graph, seedId: string, id: string, now: number)
	return ok(graph, InfectionGraph.createRoot(graph, seedId, id, now))
end

local function infect(graph: InfectionGraph.Graph, attackerId: string, targetId: string, now: number)
	return ok(graph, InfectionGraph.infect(graph, attackerId, targetId, now))
end

local function tick(graph: InfectionGraph.Graph, now: number)
	return ok(graph, InfectionGraph.tick(graph, now))
end

local function cure(graph: InfectionGraph.Graph, actorId: string, targetId: string, now: number)
	return ok(graph, InfectionGraph.cure(graph, actorId, targetId, now))
end

local function relink(graph: InfectionGraph.Graph, unstableId: string, targetId: string, now: number)
	return ok(graph, InfectionGraph.relink(graph, unstableId, targetId, now))
end

-- 便于比较“图未变化”的快照。按 id 排序，nil 字段自然缺席。
local function snapshot(graph: InfectionGraph.Graph): { [string]: any }
	local ids = InfectionGraph.participantIds(graph)
	table.sort(ids)
	local result: { [string]: any } = {}
	for _, id in ids do
		local participant = InfectionGraph.getState(graph, id)
		if participant ~= nil then
			result[id] = {
				state = participant.state,
				version = participant.version,
				episodeId = participant.episodeId,
				isRoot = participant.isRoot,
				seedId = participant.seedId,
				parentEpisodeId = participant.parentEpisodeId,
				rootSeedId = participant.rootSeedId,
				incubationEndsAt = participant.incubationEndsAt,
				unstableEndsAt = participant.unstableEndsAt,
				curedImmuneUntil = participant.curedImmuneUntil,
			}
		end
	end
	return result
end

local function expectSameGraph(actual: InfectionGraph.Graph, expected: InfectionGraph.Graph)
	expect(snapshot(actual)).toEqual(snapshot(expected))
	expect(InfectionGraph.publicCounts(actual)).toEqual(InfectionGraph.publicCounts(expected))
	expect(InfectionGraph.eventLog(actual)).toEqual(InfectionGraph.eventLog(expected))
end

-- 标准三节点链：A(U:1) → B(U:2) → C(U:3)，U:4 始终是人类施救者。
local function buildChain(ids: { string }?, doneAt: number): InfectionGraph.Graph
	local graph = newGraph(ids or { "U:1", "U:2", "U:3", "U:4" })
	createRoot(graph, "seed-a", "U:1", 0)
	tick(graph, doneAt - Incubation * 3 + Incubation)
	infect(graph, "U:1", "U:2", doneAt - Incubation * 2)
	tick(graph, doneAt - Incubation)
	infect(graph, "U:2", "U:3", doneAt - Incubation)
	tick(graph, doneAt)
	return graph
end

describe("G-01 感染链 A→B→C", function()
	it("A 感染 B、B 感染 C 后子树规模正确，尸变中的节点不能扩散", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		expect(mustState(graph, "U:1").state).toBe(State.INFECTED)

		infect(graph, "U:1", "U:2", 6)
		-- 不变量 9：尸变过渡中的节点不能继续感染。
		rejected(graph, InfectionGraph.infect(graph, "U:2", "U:3", 6), Reason.AttackerNotInfected)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		rejected(graph, InfectionGraph.infect(graph, "U:2", "U:3", 12), Reason.TargetNotHuman)
		tick(graph, 17)

		expect(mustState(graph, "U:3").state).toBe(State.INFECTED)
		expect(InfectionGraph.descendantCount(graph, "U:1")).toBe(2)
		expect(InfectionGraph.branchImpact(graph, "U:1")).toBe(3)
		expect(InfectionGraph.descendantCount(graph, "U:2")).toBe(1)
		expect(InfectionGraph.branchImpact(graph, "U:2")).toBe(2)
		expect(InfectionGraph.branchImpact(graph, "U:3")).toBe(1)
		expect(InfectionGraph.branchImpact(graph, "U:4")).toBe(0)
		local first = mustState(graph, "U:1")
		local second = mustState(graph, "U:2")
		local third = mustState(graph, "U:3")
		expect(first.isRoot).toBe(true)
		expect(second.parentEpisodeId).toBe(first.episodeId)
		expect(third.parentEpisodeId).toBe(second.episodeId)
		expect(third.rootSeedId).toBe("seed-a")
	end)
end)

describe("G-02 治愈 B", function()
	it("B 变回人类，C 进入 8 秒断联，A 保持稳定", function()
		local graph = buildChain(nil, 17)
		local result = cure(graph, "U:4", "U:2", 18)
		expect(result.affectedInfected).toBe(1)
		expect(result.affectedIncubating).toBe(0)

		local cleared = mustState(graph, "U:2")
		local unstable = mustState(graph, "U:3")
		expect(cleared.state).toBe(State.HUMAN)
		expect(cleared.episodeId).toBeNil()
		expect(cleared.curedImmuneUntil).toBe(18 + Immunity)
		expect(unstable.state).toBe(State.UNSTABLE)
		expect(unstable.unstableEndsAt).toBe(18 + Disconnect)
		expect(unstable.parentEpisodeId).toBeNil()
		expect(mustState(graph, "U:1").state).toBe(State.INFECTED)
		expect(InfectionGraph.publicCounts(graph)).toEqual({ humans = 2, incubating = 0, infected = 1, unstable = 1 })
		expect(InfectionGraph.descendantCount(graph, "U:1")).toBe(0)
	end)
end)

describe("G-03 断联第 7 秒重连", function()
	it("C 连回 A 后立即稳定，旧截止时间不再治愈它", function()
		local graph = buildChain(nil, 17)
		cure(graph, "U:4", "U:2", 18)
		expect(mustState(graph, "U:3").unstableEndsAt).toBe(26)

		relink(graph, "U:3", "U:1", 25)
		local relinked = mustState(graph, "U:3")
		expect(relinked.state).toBe(State.INFECTED)
		expect(relinked.unstableEndsAt).toBeNil()
		expect(relinked.parentEpisodeId).toBe(mustState(graph, "U:1").episodeId)

		tick(graph, 26)
		expect(mustState(graph, "U:3").state).toBe(State.INFECTED)
		expect(InfectionGraph.publicCounts(graph).unstable).toBe(0)
	end)
end)

describe("G-04 断联到期", function()
	it("C 恢复人类并获得 7 秒保护，保护期内不能被再次感染", function()
		local graph = buildChain(nil, 17)
		cure(graph, "U:4", "U:2", 18)
		tick(graph, 26)
		local recovered = mustState(graph, "U:3")
		expect(recovered.state).toBe(State.HUMAN)
		expect(recovered.episodeId).toBeNil()
		expect(recovered.curedImmuneUntil).toBe(26 + Immunity)

		rejected(graph, InfectionGraph.infect(graph, "U:1", "U:3", 27), Reason.TargetImmune)
		tick(graph, 33)
		infect(graph, "U:1", "U:3", 33)
		expect(mustState(graph, "U:3").state).toBe(State.INCUBATING)
	end)
end)

describe("G-05 父节点失效但子树已重连", function()
	it("H 先重连后稳定，D 到期不会影响 H", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4", "U:5" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		tick(graph, 17)
		infect(graph, "U:3", "U:4", 18)
		tick(graph, 23)

		cure(graph, "U:5", "U:2", 24)
		expect(mustState(graph, "U:3").state).toBe(State.UNSTABLE)
		expect(mustState(graph, "U:4").state).toBe(State.UNSTABLE)
		expect(mustState(graph, "U:4").parentEpisodeId).toBe(mustState(graph, "U:3").episodeId)

		relink(graph, "U:4", "U:1", 25)
		expect(mustState(graph, "U:3").state).toBe(State.UNSTABLE)
		expect(mustState(graph, "U:4").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:4").parentEpisodeId).toBe(mustState(graph, "U:1").episodeId)

		tick(graph, 32)
		expect(mustState(graph, "U:3").state).toBe(State.HUMAN)
		expect(mustState(graph, "U:4").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:4").rootSeedId).toBe("seed-a")
		expect(InfectionGraph.descendantCount(graph, "U:4")).toBe(0)
	end)
end)

describe("G-06 跨树重连", function()
	it("D 从 A 树连到 X 树，rootSeedId 与整支连接关系准确迁移", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4", "U:5", "U:6" })
		createRoot(graph, "seed-a", "U:1", 0)
		createRoot(graph, "seed-x", "U:2", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:3", 6)
		tick(graph, 11)
		infect(graph, "U:3", "U:4", 12)
		tick(graph, 17)
		infect(graph, "U:4", "U:5", 18)
		tick(graph, 23)

		cure(graph, "U:6", "U:3", 24)
		expect(mustState(graph, "U:4").rootSeedId).toBe("seed-a")
		expect(mustState(graph, "U:5").rootSeedId).toBe("seed-a")

		relink(graph, "U:4", "U:2", 25)
		expect(mustState(graph, "U:4").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:4").rootSeedId).toBe("seed-x")
		expect(mustState(graph, "U:5").rootSeedId).toBe("seed-x")
		expect(mustState(graph, "U:5").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:5").parentEpisodeId).toBe(mustState(graph, "U:4").episodeId)
		expect(mustState(graph, "U:4").parentEpisodeId).toBe(mustState(graph, "U:2").episodeId)
		expect(InfectionGraph.descendantCount(graph, "U:2")).toBe(2)
	end)
end)

describe("G-07 不能连到自己的下游", function()
	it("目标是自己后代时拒绝且原图完全不变", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4", "U:5" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		tick(graph, 17)
		infect(graph, "U:3", "U:4", 18)
		tick(graph, 23)
		cure(graph, "U:5", "U:2", 24)

		local before = snapshot(graph)
		local eventsBefore = InfectionGraph.eventLog(graph)
		rejected(graph, InfectionGraph.relink(graph, "U:3", "U:4", 25), Reason.TargetDescendant)
		expect(snapshot(graph)).toEqual(before)
		expect(InfectionGraph.eventLog(graph)).toEqual(eventsBefore)
		rejected(graph, InfectionGraph.relink(graph, "U:3", "U:3", 25), Reason.SameParticipant)
	end)
end)

describe("G-08 恢复后再次被感染", function()
	it("创建新的 episode，旧 episode 与旧事件不能影响新节点", function()
		local graph = newGraph({ "U:1", "U:2", "U:3" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		local oldEpisode = mustState(graph, "U:2").episodeId
		expect(oldEpisode).toBeTruthy()

		cure(graph, "U:3", "U:2", 12)
		tick(graph, 12 + Immunity)
		infect(graph, "U:1", "U:2", 12 + Immunity)
		local newEpisode = mustState(graph, "U:2").episodeId
		expect(newEpisode).toBeTruthy()
		expect(newEpisode ~= oldEpisode).toBe(true)
		expect(InfectionGraph.getEpisodeOwner(graph, oldEpisode :: string)).toBeNil()
		expect(InfectionGraph.getEpisodeOwner(graph, newEpisode :: string)).toBe("U:2")

		rejected(
			graph,
			InfectionGraph.cure(graph, "U:3", "U:2", 20, { expectedEpisodeId = oldEpisode }),
			Reason.ExpectedEpisodeMismatch
		)
	end)
end)

describe("G-09 治愈过程中目标掉线", function()
	it("退出按 §19.1 修复树，后续治愈干净失败、不重复生效", function()
		local graph = buildChain(nil, 17)
		local eventsBefore = #InfectionGraph.eventLog(graph)
		ok(graph, InfectionGraph.removeParticipant(graph, "U:2", 18))
		expect(getState(graph, "U:2")).toBeNil()
		expect(mustState(graph, "U:3").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:3").parentEpisodeId).toBe(mustState(graph, "U:1").episodeId)
		expect(#InfectionGraph.eventLog(graph)).toBe(eventsBefore + 1)

		local before = snapshot(graph)
		rejected(graph, InfectionGraph.cure(graph, "U:4", "U:2", 18), Reason.UnknownParticipant)
		expect(snapshot(graph)).toEqual(before)
		expect(#InfectionGraph.eventLog(graph)).toBe(eventsBefore + 1)
	end)
end)

describe("G-10 旧扑咬消息晚到", function()
	it("过期 version / episode 被拒绝，不能强行转阵营", function()
		local graph = newGraph({ "U:1", "U:2", "U:3" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		local staleVersion = mustState(graph, "U:2").version
		expect(staleVersion).toBe(0)

		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		local staleEpisode = mustState(graph, "U:2").episodeId
		cure(graph, "U:3", "U:2", 12)
		expect(mustState(graph, "U:2").state).toBe(State.HUMAN)

		-- 保护期已过，旧的扑咬消息只剩版本不合法。
		rejected(
			graph,
			InfectionGraph.infect(graph, "U:1", "U:2", 20, { expectedVersion = staleVersion }),
			Reason.ExpectedVersionMismatch
		)
		rejected(
			graph,
			InfectionGraph.infect(graph, "U:1", "U:2", 20, { expectedEpisodeId = staleEpisode }),
			Reason.ExpectedEpisodeMismatch
		)
		expect(mustState(graph, "U:2").state).toBe(State.HUMAN)
		infect(graph, "U:1", "U:2", 20)
		expect(mustState(graph, "U:2").state).toBe(State.INCUBATING)
	end)
end)

describe("G-11 两人同时注射", function()
	it("只有第一次治愈成功，第二次被告知目标已失效", function()
		local graph = buildChain(nil, 17)
		cure(graph, "U:4", "U:2", 18)
		local eventsAfterFirst = #InfectionGraph.eventLog(graph)
		local versionAfterFirst = mustState(graph, "U:2").version
		rejected(graph, InfectionGraph.cure(graph, "U:4", "U:2", 18), Reason.TargetNotInfected)
		expect(#InfectionGraph.eventLog(graph)).toBe(eventsAfterFirst)
		expect(mustState(graph, "U:2").version).toBe(versionAfterFirst)
	end)
end)

describe("G-12 含 15 个子孙的枢纽被治愈", function()
	it("全部断联状态一致，且耗时远低于交互预算", function()
		local ids: { string } = { "U:1", "U:2" }
		for index = 3, 17 do
			table.insert(ids, `U:{index}`)
		end
		table.insert(ids, "U:18")
		local graph = newGraph(ids)
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		for index = 3, 17 do
			infect(graph, "U:2", `U:{index}`, 12)
		end
		tick(graph, 17)
		expect(InfectionGraph.descendantCount(graph, "U:2")).toBe(15)
		expect(InfectionGraph.branchImpact(graph, "U:2")).toBe(16)

		local started = os.clock()
		local result = InfectionGraph.cure(graph, "U:18", "U:2", 18)
		local elapsed = os.clock() - started
		expect(result.ok).toBe(true)
		expect(result.affectedInfected).toBe(15)
		expect(elapsed < 0.25).toBe(true)
		check(graph)

		expect(InfectionGraph.publicCounts(graph).unstable).toBe(15)
		expect(InfectionGraph.publicCounts(graph).humans).toBe(2)
		for index = 3, 17 do
			local participant = mustState(graph, `U:{index}`)
			expect(participant.state).toBe(State.UNSTABLE)
			expect(participant.unstableEndsAt).toBe(18 + Disconnect)
			expect(participant.parentEpisodeId).toBeNil()
		end
		expect(InfectionGraph.descendantCount(graph, "U:1")).toBe(0)
	end)
end)

describe("G-13 尸变过渡中的 C 的父亲被治愈", function()
	it("C 立即恢复人类、取消过渡计时并获得治愈保护", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		expect(mustState(graph, "U:3").state).toBe(State.INCUBATING)

		local result = cure(graph, "U:4", "U:2", 13)
		expect(result.affectedIncubating).toBe(1)
		expect(result.affectedInfected).toBe(0)
		local reverted = mustState(graph, "U:3")
		expect(reverted.state).toBe(State.HUMAN)
		expect(reverted.episodeId).toBeNil()
		expect(reverted.incubationEndsAt).toBeNil()
		expect(reverted.curedImmuneUntil).toBe(13 + Immunity)
		expect(mustState(graph, "U:1").state).toBe(State.INFECTED)
		-- 过渡计时被取消：即使到了原定尸变时刻也不会变成感染者。
		tick(graph, 17)
		expect(mustState(graph, "U:3").state).toBe(State.HUMAN)
	end)
end)

describe("G-14 零号根退出", function()
	it("挂到 VirtualRoot，直接子节点保持稳定", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		infect(graph, "U:1", "U:3", 6)
		tick(graph, 11)

		ok(graph, InfectionGraph.removeParticipant(graph, "U:1", 12))
		local virtualRoot = InfectionGraph.virtualRootId("seed-a")
		expect(getState(graph, "U:1")).toBeNil()
		expect(mustState(graph, "U:2").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:3").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:2").parentEpisodeId).toBe(virtualRoot)
		expect(mustState(graph, "U:3").parentEpisodeId).toBe(virtualRoot)
		expect(mustState(graph, "U:2").rootSeedId).toBe("seed-a")
		expect(InfectionGraph.descendantCount(graph, "U:2")).toBe(0)
	end)
end)

describe("G-15 稳定非根退出", function()
	it("子节点继承稳定上游，不触发免费断链", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		infect(graph, "U:2", "U:4", 12)
		tick(graph, 17)

		local humansBefore = InfectionGraph.publicCounts(graph).humans
		ok(graph, InfectionGraph.removeParticipant(graph, "U:2", 18))
		expect(getState(graph, "U:2")).toBeNil()
		local upstream = mustState(graph, "U:1").episodeId
		expect(mustState(graph, "U:3").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:4").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:3").parentEpisodeId).toBe(upstream)
		expect(mustState(graph, "U:4").parentEpisodeId).toBe(upstream)
		expect(InfectionGraph.publicCounts(graph).humans).toBe(humansBefore)
		expect(InfectionGraph.publicCounts(graph).unstable).toBe(0)
	end)
end)

describe("G-16 断联者自己退出", function()
	it("下游继承截止时间并挂到下一个断联祖先，不重置 8 秒", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4", "U:5", "U:6", "U:7" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		tick(graph, 17)
		infect(graph, "U:3", "U:4", 18)
		tick(graph, 23)
		infect(graph, "U:4", "U:5", 24)
		tick(graph, 29)

		cure(graph, "U:7", "U:2", 30)
		expect(mustState(graph, "U:3").unstableEndsAt).toBe(38)
		expect(mustState(graph, "U:4").unstableEndsAt).toBe(38)
		expect(mustState(graph, "U:5").unstableEndsAt).toBe(38)
		expect(mustState(graph, "U:4").parentEpisodeId).toBe(mustState(graph, "U:3").episodeId)

		local humansBefore = InfectionGraph.publicCounts(graph).humans
		ok(graph, InfectionGraph.removeParticipant(graph, "U:4", 31))
		expect(mustState(graph, "U:5").state).toBe(State.UNSTABLE)
		expect(mustState(graph, "U:5").parentEpisodeId).toBe(mustState(graph, "U:3").episodeId)
		expect(mustState(graph, "U:5").unstableEndsAt).toBe(38)
		expect(InfectionGraph.publicCounts(graph).humans).toBe(humansBefore)

		tick(graph, 38)
		expect(mustState(graph, "U:5").state).toBe(State.HUMAN)
		expect(mustState(graph, "U:5").curedImmuneUntil).toBe(38 + Immunity)
		expect(mustState(graph, "U:3").state).toBe(State.HUMAN)
	end)
end)

describe("G-17 断联最后一帧与重连同时到达", function()
	it("先提交的重连获胜；同一事件日志重放的最终状态完全一致", function()
		local ids = { "U:1", "U:2", "U:3", "U:4" }

		-- 情况 A：重连先提交（截止前 1 秒），tick 后到。
		local graphA = buildChain(ids, 17)
		cure(graphA, "U:4", "U:2", 18)
		relink(graphA, "U:3", "U:1", 25)
		tick(graphA, 26)
		expect(mustState(graphA, "U:3").state).toBe(State.INFECTED)

		local eventLogA = InfectionGraph.eventLog(graphA)
		local replayedA = InfectionGraph.replay(BalanceConfig, graphA.roundId, ids, eventLogA)
		check(replayedA)
		expectSameGraph(replayedA, graphA)

		-- 情况 B：tick 先提交，重连晚到即失败。
		local graphB = buildChain(ids, 17)
		cure(graphB, "U:4", "U:2", 18)
		tick(graphB, 26)
		rejected(graphB, InfectionGraph.relink(graphB, "U:3", "U:1", 26), Reason.NotUnstable)
		expect(mustState(graphB, "U:3").state).toBe(State.HUMAN)

		local eventLogB = InfectionGraph.eventLog(graphB)
		local replayedB = InfectionGraph.replay(BalanceConfig, graphB.roundId, ids, eventLogB)
		check(replayedB)
		expectSameGraph(replayedB, graphB)

		-- 两次独立重放必须给出同一结果（无隐藏随机性）。
		local replayA2 = InfectionGraph.replay(BalanceConfig, graphA.roundId, ids, eventLogA)
		expectSameGraph(replayA2, replayedA)
	end)
end)

describe("G-18 旧局定时器", function()
	it("旧 roundId 的命令与计时器全部被丢弃，不修改任何一局", function()
		local ids = { "U:1", "U:2" }
		local graph = newGraph(ids, "round-1")
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		local before = snapshot(graph)
		local eventsBefore = InfectionGraph.eventLog(graph)

		rejected(graph, InfectionGraph.tick(graph, 100, { roundId = "round-2" }), Reason.RoundMismatch)
		rejected(graph, InfectionGraph.infect(graph, "U:1", "U:2", 100, { roundId = "round-0" }), Reason.RoundMismatch)
		expect(snapshot(graph)).toEqual(before)
		expect(InfectionGraph.eventLog(graph)).toEqual(eventsBefore)

		local nextRound = newGraph(ids, "round-2")
		rejected(nextRound, InfectionGraph.tick(nextRound, 100, { roundId = "round-1" }), Reason.RoundMismatch)
		expect(InfectionGraph.publicCounts(nextRound).humans).toBe(2)
		expect(#InfectionGraph.eventLog(nextRound)).toBe(0)
	end)
end)

describe("G-19 以零号为重连目标", function()
	it("读条按 RootRelinkHoldMultiplier 计算，VirtualRoot 目标被拒绝", function()
		local graph = newGraph({ "U:1", "U:2", "U:3", "U:4", "U:5" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)
		infect(graph, "U:2", "U:3", 12)
		tick(graph, 17)
		infect(graph, "U:3", "U:4", 18)
		tick(graph, 23)
		cure(graph, "U:5", "U:3", 24)
		expect(mustState(graph, "U:4").state).toBe(State.UNSTABLE)

		expect(InfectionGraph.relinkHoldSeconds(graph, "U:4", "U:1")).toBe(RootHold)
		expect(InfectionGraph.relinkHoldSeconds(graph, "U:4", "U:2")).toBe(BaseHold)
		expect(InfectionGraph.relinkHoldSeconds(graph, "U:4", InfectionGraph.virtualRootId("seed-a"))).toBeNil()

		-- 零号根退出后创建 VirtualRoot；它不是实体，不能作为重连目标。
		ok(graph, InfectionGraph.removeParticipant(graph, "U:1", 25))
		local virtualRoot = InfectionGraph.virtualRootId("seed-a")
		local before = snapshot(graph)
		rejected(graph, InfectionGraph.relink(graph, "U:4", virtualRoot, 26), Reason.VirtualRootTarget)
		expect(snapshot(graph)).toEqual(before)
		expect(InfectionGraph.relinkHoldSeconds(graph, "U:4", virtualRoot)).toBeNil()

		-- 合法目标仍然可以重连（读条倍率只是时长，不改变合法性）。
		relink(graph, "U:4", "U:2", 26)
		expect(mustState(graph, "U:4").state).toBe(State.INFECTED)
	end)
end)

describe("G-20 中途加入", function()
	it("丧尸叶子挂到现存根或 VirtualRoot，不触发断联；人类获得保护", function()
		local graph = newGraph({ "U:1", "U:2" })
		createRoot(graph, "seed-a", "U:1", 0)
		tick(graph, 5)
		infect(graph, "U:1", "U:2", 6)
		tick(graph, 11)

		local countsBefore = InfectionGraph.publicCounts(graph)
		ok(graph, InfectionGraph.addLateJoiner(graph, "U:9", "INFECTED", 70))
		expect(mustState(graph, "U:9").state).toBe(State.INFECTED)
		expect(mustState(graph, "U:9").parentEpisodeId).toBe(mustState(graph, "U:1").episodeId)
		expect(mustState(graph, "U:9").rootSeedId).toBe("seed-a")
		expect(InfectionGraph.publicCounts(graph).unstable).toBe(0)
		expect(InfectionGraph.publicCounts(graph).infected).toBe(countsBefore.infected + 1)

		ok(graph, InfectionGraph.addLateJoiner(graph, "U:10", "HUMAN", 70))
		expect(mustState(graph, "U:10").curedImmuneUntil).toBe(70 + Immunity)
		rejected(graph, InfectionGraph.infect(graph, "U:1", "U:10", 71), Reason.TargetImmune)

		ok(graph, InfectionGraph.addLateJoiner(graph, "U:11", "SPECTATOR", 70))
		expect(mustState(graph, "U:11").state).toBe(State.SPECTATOR)
		rejected(graph, InfectionGraph.addLateJoiner(graph, "U:9", "HUMAN", 72), Reason.AlreadyParticipant)

		-- 真根退出后，后来的感染者挂到 VirtualRoot。
		ok(graph, InfectionGraph.removeParticipant(graph, "U:1", 80))
		local virtualRoot = InfectionGraph.virtualRootId("seed-a")
		ok(graph, InfectionGraph.addLateJoiner(graph, "U:12", "INFECTED", 81))
		expect(mustState(graph, "U:12").parentEpisodeId).toBe(virtualRoot)

		-- 没有任何感染树时，感染者中途加入必须被拒绝。
		local empty = newGraph({ "U:20" })
		rejected(empty, InfectionGraph.addLateJoiner(empty, "U:21", "INFECTED", 100), Reason.NoTree)
	end)
end)

-- Park–Miller LCG：确定性、不依赖 math.random（G-17：同一输入日志必须复现同一结果）。
local randomState = 20261024
local function randInt(bound: number): number
	randomState = (16807 * randomState) % 2147483647
	return (randomState % bound) + 1
end

local function randomParticipantId(graph: InfectionGraph.Graph): string?
	local ids = InfectionGraph.participantIds(graph)
	if #ids == 0 then
		return nil
	end
	return ids[randInt(#ids)]
end

describe("随机属性测试（G-17 确定性）", function()
	it("500 局 × 200 次随机操作：不变量始终成立，事件日志可完整重放", function()
		local totalAccepted = 0
		local totalRejected = 0
		for round = 1, 500 do
			local participantCount = 12 + randInt(13)
			local ids: { string } = {}
			for index = 1, participantCount do
				table.insert(ids, `U:{index}`)
			end
			local graph = InfectionGraph.new(BalanceConfig, `round-{round}`, ids)
			local clock = 0
			local joinCounter = 0

			for step = 1, 200 do
				local roll = randInt(100)
				local now = clock + randInt(4) - 1
				local seqBefore = graph.seq
				local eventsBefore = #graph.events
				local result: InfectionGraph.Result? = nil

				if #InfectionGraph.participantIds(graph) == 0 then
					joinCounter += 1
					result = InfectionGraph.addLateJoiner(graph, `U:join:{round}:{step}`, "HUMAN", now)
				elseif roll <= 3 then
					joinCounter += 1
					result = InfectionGraph.createRoot(
						graph,
						`seed-{round}-{step}`,
						randomParticipantId(graph) :: string,
						now
					)
				elseif roll <= 40 then
					result = InfectionGraph.infect(
						graph,
						randomParticipantId(graph) :: string,
						randomParticipantId(graph) :: string,
						now
					)
				elseif roll <= 60 then
					now = clock + randInt(6)
					result = InfectionGraph.tick(graph, now)
				elseif roll <= 72 then
					result = InfectionGraph.cure(
						graph,
						randomParticipantId(graph) :: string,
						randomParticipantId(graph) :: string,
						now
					)
				elseif roll <= 83 then
					result = InfectionGraph.relink(
						graph,
						randomParticipantId(graph) :: string,
						randomParticipantId(graph) :: string,
						now
					)
				elseif roll <= 91 then
					result = InfectionGraph.removeParticipant(graph, randomParticipantId(graph) :: string, now)
				elseif roll <= 95 then
					joinCounter += 1
					local roleRoll = randInt(3)
					local role: InfectionGraph.LateJoinRole = if roleRoll == 1
						then "HUMAN"
						elseif roleRoll == 2 then "INFECTED"
						else "SPECTATOR"
					result = InfectionGraph.addLateJoiner(graph, `U:join:{round}:{step}`, role, now)
				elseif roll <= 98 then
					result = InfectionGraph.markExtracted(graph, randomParticipantId(graph) :: string)
				else
					-- 明确的非法命令：错误 round、过期 version、VirtualRoot 目标。
					local invalidRoll = randInt(3)
					if invalidRoll == 1 then
						result = InfectionGraph.tick(graph, now, { roundId = "round-stale" })
					elseif invalidRoll == 2 then
						result = InfectionGraph.infect(
							graph,
							randomParticipantId(graph) :: string,
							randomParticipantId(graph) :: string,
							now,
							{ expectedVersion = 9999 }
						)
					else
						result = InfectionGraph.relink(
							graph,
							randomParticipantId(graph) :: string,
							InfectionGraph.virtualRootId(`seed-{round}`),
							now
						)
					end
				end

				if result ~= nil then
					if result.ok then
						totalAccepted += 1
						clock = math.max(clock, now)
					else
						totalRejected += 1
						-- 拒绝必须是原子失败：不追加事件、不推进 seq、不改状态。
						if graph.seq ~= seqBefore or #graph.events ~= eventsBefore then
							error(
								`第 {round} 局第 {step} 步：被拒绝的命令修改了事件日志（{result.reason}）`,
								0
							)
						end
					end
				end
				InfectionGraph.assertInvariants(graph)
			end

			local eventLog = InfectionGraph.eventLog(graph)
			local replayed = InfectionGraph.replay(BalanceConfig, graph.roundId, ids, eventLog)
			InfectionGraph.assertInvariants(replayed)
			expectSameGraph(replayed, graph)
		end

		expect(totalAccepted > 0).toBe(true)
		expect(totalRejected > 0).toBe(true)
	end)
end)

TestKit.finish()
