--[[ auto clash ]]

local AutoClash = {}

-- dependências
local Utils

-- tunings
local CLASH = {
	BALL_HARD_CAP = 22,
	HOLD = 0.20,
	MAX_HOLD = 1.2,
	DET_RAD_MIN = 10,
	DET_RAD_MAX = 25,
	DET_RAD_SPD_REF = 120,
	DET_DOT_EMA = 0.25,
	DET_DOT_THRESH = 0.15,
	DET_RETURN_FACTOR = 1.5,
	DET_TIMEOUT = 0.8,
	PANIC_DIST = 9,
	PANIC_BALL = 13,
	DASH_SPD_THRESH = 50,
	DASH_SPD_CONFIRM = 62,
	DASH_DUR_MIN = 0.08,
	DASH_DUR_MAX = 0.5,
	DASH_PANIC_DOT = 0.85,
	DASH_PANIC_DIST = 14,
	DASH_PANIC_WINDOW = 0.300,
	DASH_TRACK_INTERVAL = 0.2,
	PLAYER_SCAN_RADIUS = 100,
	ANTIDASH_RAD_MIN = 20,
	ANTIDASH_RAD_MAX = 32,
	ANTIDASH_DOT_MIN = 0.0,
	ANTIDASH_PANIC_HOLD = 0.45,
	ANTIDASH_COOLDOWN = 0.35,
	MAINT_BALL_GONE_DIST = 60,
	MIN_HOLD = 0.050,
	DEACT_TIMP_SUSTAIN = 0.15,
}

-- estado
local S = {
	lastTarget = -999,
	clashOn = false,
	clashAt = 0,
	clashHoldUntil = 0,
	clashOffAt = 0,
	detPhase = "IDLE",
	detEnterAt = 0,
	detEntryTime = 0,
	detExitAt = 0,
	detDotEma = 0,
	detWasInside = false,
	detSignal = false,
	dashEvents = {},
	dashPanicUntil = 0,
	dashAnti = { untilT = 0, src = nil },
	tImpHighSince = 0,
}

local _antidashCooldown = {}
local _lastDashTrack = 0
local _ctxCache = { t = 0, valid = false }
local CLASH_SNAPSHOT_TTL = 0.05

-- módulos
local function getGameInfo()
	return Utils.getModule("GameInfo")
end
local function getAutoParry()
	return Utils.getModule("AutoParry")
end

-- helpers
local function getMyHRP()
	local lp = Utils.getLocalPlayer()
	return lp and lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
end

local function getParryBonus()
	local ap = getAutoParry()
	return (ap and type(ap.resRadiusBonus) == "function") and ap.resRadiusBonus() or 0
end

local function getDetectorRadius(spd)
	local t = math.clamp((spd or 0) / CLASH.DET_RAD_SPD_REF, 0, 1)
	return CLASH.DET_RAD_MIN + (CLASH.DET_RAD_MAX - CLASH.DET_RAD_MIN) * t
end

-- detector
local function tickReturnDetector(t, hr, ball)
	S.detSignal = false
	if not (hr and hr.Parent and ball and ball.Parent) then
		S.detPhase, S.detDotEma, S.detWasInside = "IDLE", 0, false
		return
	end
	local ok, av = pcall(function()
		return ball.AssemblyLinearVelocity
	end)
	if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then
		return
	end
	local spd, radius = av.Magnitude, getDetectorRadius(av.Magnitude)
	local toMe = hr.Position - ball.Position
	local dist, dotRaw = toMe.Magnitude, av:Dot(toMe.Unit)
	if dist <= radius * 1.2 then
		S.detDotEma = S.detDotEma * (1 - CLASH.DET_DOT_EMA) + dotRaw * CLASH.DET_DOT_EMA
	else
		S.detDotEma = 0
	end
	local isInside = dist <= radius
	local dotComing, dotGoing = S.detDotEma > CLASH.DET_DOT_THRESH, S.detDotEma < -CLASH.DET_DOT_THRESH
	if S.detPhase == "EXITED" and (t - S.detExitAt) > CLASH.DET_TIMEOUT then
		S.detPhase = "IDLE"
	end
	if S.detPhase == "IDLE" then
		if (isInside and not S.detWasInside) or (not isInside and dotComing) then
			S.detPhase, S.detEnterAt, S.detEntryTime = "INSIDE", t, (dist > 0.1 and dist / spd or 0.01)
		end
	elseif S.detPhase == "INSIDE" then
		if (not isInside and S.detWasInside) or (isInside and dotGoing) then
			S.detPhase, S.detExitAt = "EXITED", t
		end
	elseif S.detPhase == "EXITED" then
		local limiar = S.detEntryTime * CLASH.DET_RETURN_FACTOR
		if (isInside and not S.detWasInside) or dotComing then
			if isInside and not S.detWasInside and limiar > 0 and (t - S.detExitAt) <= limiar then
				S.detSignal = true
			end
			S.detPhase, S.detEnterAt, S.detEntryTime = "INSIDE", t, (dist > 0.1 and dist / spd or 0.01)
		end
	end
	S.detWasInside = isInside
end

-- snapshot
local function clashSnapshot()
	local t, GameInfo = Utils.now(), getGameInfo()
	if _ctxCache.valid and (t - _ctxCache.t) < CLASH_SNAPSHOT_TTL then
		return _ctxCache
	end
	local hr, ball = getMyHRP(), GameInfo and GameInfo.getBall()
	if not (hr and ball and ball.Parent) then
		_ctxCache.valid = false
		return nil
	end
	local nearest, nearestAlive = GameInfo.nearestPlayerAlive()
	local bDist = (hr.Position - ball.Position).Magnitude
	local live = GameInfo.liveTImp()
	local tImp, spd = 0, 0
	if live then
		tImp = tonumber(live.tImp) or 0
		spd = tonumber(live.spd) or 0
	end

	if spd < 1 then
		local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
		tImp, spd = tonumber(ti) or tImp, tonumber(s2) or spd
	end
	_ctxCache.t, _ctxCache.valid = t, true
	_ctxCache.hr, _ctxCache.ball = hr, ball
	_ctxCache.bDist, _ctxCache.panic =
		bDist, (nearestAlive and nearest <= CLASH.PANIC_DIST and bDist <= CLASH.PANIC_BALL)
	_ctxCache.tImp, _ctxCache.spd = tImp, spd
	_ctxCache.targeted = GameInfo.isTargeted(S.lastTarget)
	return _ctxCache
end

-- controle
local function clearClash()
	S.clashOn, S.clashHoldUntil, S.clashOffAt, S.tImpHighSince = false, 0, Utils.now(), 0
end

local function _activateBurst(t)
	S.clashOn, S.clashAt, S.clashHoldUntil, S.clashOffAt, S.tImpHighSince = true, t, t + CLASH.HOLD, 0, 0
	local burst, ap = _G.PhantomOnBurst, getAutoParry()
	if type(burst) == "function" then
		pcall(burst)
	elseif ap and type(ap.fire) == "function" then
		pcall(ap.fire)
	end
end

local function getParryThresh(ctx)
	local ap = getAutoParry()
	local p = ap and ap.getP()
	return ((p and p.DEFLECT_R or 4) + getParryBonus()) / math.max(ctx.spd or 1, 1)
end

-- decisão
local function shouldActivate(t, ctx)
	if S.clashOn then
		return false
	end
	return (S.detSignal or S.dashAnti.untilT > t or S.dashPanicUntil > t) and ctx.targeted
end

local function shouldDeactivate(t, ctx)
	if not S.clashOn then
		return false
	end
	if (t - S.clashAt) > CLASH.MAX_HOLD then
		return true
	end
	if not (ctx.ball and ctx.ball.Parent) then
		return true
	end
	if ctx.bDist > CLASH.MAINT_BALL_GONE_DIST then
		return true
	end
	return false
end

local function shouldMaintain(t, ctx)
	if not S.clashOn or shouldDeactivate(t, ctx) then
		return false
	end
	if t < math.max(S.clashAt + CLASH.MIN_HOLD, S.clashHoldUntil) then
		return true
	end
	if (ctx.tImp or 0) > getParryThresh(ctx) then
		if S.tImpHighSince == 0 then
			S.tImpHighSince = t
		end
		if (t - S.tImpHighSince) >= CLASH.DEACT_TIMP_SUSTAIN then
			return false
		end
	else
		S.tImpHighSince = 0
	end
	return true
end

-- evaluate
function AutoClash.evaluate(t, hr, ball, config)
	if not config or config.AutoClash == false or _G.PhantomManual then
		if S.clashOn then
			clearClash()
		end
		return
	end
	tickReturnDetector(t, hr, ball)
	local ctx = clashSnapshot()
	if not ctx then
		return
	end

	if shouldActivate(t, ctx) then
		_activateBurst(t)
	elseif S.clashOn and not shouldMaintain(t, ctx) then
		clearClash()
	end
end

-- dash
function AutoClash.updateDashTrack(t)
	if (t - _lastDashTrack) < CLASH.DASH_TRACK_INTERVAL then
		return
	end
	_lastDashTrack = t
	local hr, PlayersService = getMyHRP(), Utils.getPlayers()
	if not hr then
		table.clear(S.dashEvents)
		return
	end
	local myPos = hr.Position
	for _, p in ipairs(PlayersService:GetPlayers()) do
		if p == Utils.getLocalPlayer() then
			continue
		end
		local php = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		if php and hum and hum.Health > 0 then
			local toMe = myPos - php.Position
			local dist, av = toMe.Magnitude, php.AssemblyLinearVelocity
			if dist <= CLASH.PLAYER_SCAN_RADIUS then
				local spd = av.Magnitude
				if spd >= CLASH.DASH_SPD_THRESH then
					local ev = S.dashEvents[p.UserId] or { startedAt = t, confirmed = false }
					ev.spd, ev.dir, ev.at = spd, av.Unit, t
					if not ev.confirmed and spd >= CLASH.DASH_SPD_CONFIRM then
						ev.confirmed, ev.startedAt = true, t
					end
					S.dashEvents[p.UserId] = ev
					if
						ev.confirmed
						and (t - ev.startedAt) >= CLASH.DASH_DUR_MIN
						and (t - ev.startedAt) <= CLASH.DASH_DUR_MAX
					then
						if dist <= CLASH.DASH_PANIC_DIST and ev.dir:Dot(toMe.Unit) >= CLASH.DASH_PANIC_DOT then
							S.dashPanicUntil, S.dashAnti.untilT =
								math.max(S.dashPanicUntil, t + CLASH.DASH_PANIC_WINDOW),
								math.max(S.dashAnti.untilT, t + CLASH.ANTIDASH_PANIC_HOLD)
						end
					end
				else
					S.dashEvents[p.UserId] = nil
				end
			else
				S.dashEvents[p.UserId] = nil
			end
		else
			S.dashEvents[p.UserId] = nil
		end
	end
end

function AutoClash.reportDash(player)
	if not player or not Utils.isActive() then
		return
	end
	local t = Utils.now()
	if _antidashCooldown[player.UserId] and (t - _antidashCooldown[player.UserId]) < CLASH.ANTIDASH_COOLDOWN then
		return
	end
	_antidashCooldown[player.UserId] = t
	local php, myHRP, ap = player.Character and player.Character:FindFirstChild("HumanoidRootPart"), getMyHRP(), getAutoParry()
	if not (php and myHRP) then
		return
	end
	local p = ap and ap.getP()
	local rad = math.clamp(
		(p and p.DEFLECT_R or 8.5) + getParryBonus(),
		CLASH.ANTIDASH_RAD_MIN,
		CLASH.ANTIDASH_RAD_MAX
	)
	local toMe = myHRP.Position - php.Position
	local dist = toMe.Magnitude
	if dist > rad or dist < 0.1 then
		return
	end
	local ok, av = pcall(function()
		return php.AssemblyLinearVelocity
	end)
	if
		ok
		and typeof(av) == "Vector3"
		and av.Magnitude > 1
		and av.Unit:Dot(toMe.Unit) < CLASH.ANTIDASH_DOT_MIN
	then
		return
	end
	S.dashAnti.untilT = math.max(S.dashAnti.untilT, t + CLASH.ANTIDASH_PANIC_HOLD)
end

-- setup
function AutoClash.setup(u)
	Utils = u
end

-- api
function AutoClash.getState()
	return S
end
function AutoClash.clashOn()
	return S.clashOn
end
function AutoClash.snapshot()
	return clashSnapshot()
end
function AutoClash.invalidateSnapshot()
	_ctxCache.valid = false
end
function AutoClash.resetState()
	clearClash()
	table.clear(S.dashEvents)
	S.dashPanicUntil, S.dashAnti.untilT = 0, 0
end

return AutoClash