--!strict
-- 交互动作载荷校验（GDB V1.1 §20.4、§21.2）：客户端只发意图，targetId 长度与形状由服务端收紧。
-- 纯逻辑：不引用 Roblox 全局对象，可在 Lune 中测试。

export type Result = {
	ok: boolean,
	reason: string?,
	targetId: string?,
}

local InteractPayload = {}

local Reason = table.freeze({
	NotTable = "PAYLOAD_NOT_TABLE",
	MissingTarget = "MISSING_TARGET",
	TargetTooLong = "TARGET_TOO_LONG",
})
InteractPayload.Reason = Reason

-- StartCure / TryRelink 共用：payload 必须是 table，targetId 必须是非空字符串且 ≤ maxBytes。
function InteractPayload.validateTarget(payload: any, maxBytes: number): Result
	if type(payload) ~= "table" then
		return { ok = false, reason = Reason.NotTable }
	end
	local targetId = payload.targetId
	if type(targetId) ~= "string" or targetId == "" then
		return { ok = false, reason = Reason.MissingTarget }
	end
	if maxBytes > 0 and #targetId > maxBytes then
		return { ok = false, reason = Reason.TargetTooLong }
	end
	return { ok = true, targetId = targetId }
end

return table.freeze(InteractPayload)
