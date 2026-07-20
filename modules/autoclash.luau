--[[ AutoClash ]]

local AutoClash = {}

-- deps
local _Probe, GameInfo, Utils, AutoParry

-- tunning
local CLASH = {
	DECAY                    = 0.310,
	HOLD                     = 0.20,
	REACT_CD                 = 0.120,
	BALL_RANGE               = 18,
	BALL_HARD_CAP            = 22,
	MAX_BALL_DIST            = 45,
	PANIC_DIST               = 9,
	PANIC_BALL               = 13,
	CPS_THRESH               = 8,
	CPS_WIN                  = 1.0,
	MIN_DANGER               = 70,
	TIMP_FAR                 = 0.180,
	SPD_FAST                 = 65,
	SPD_MID                  = 40,
	SPD_LOW                  = 20,
	OFF_PANIC                = 0.090,
	OFF_FAST                 = 0.050,
	OFF_MID                  = 0.060,
	OFF_LOW                  = 0.070,
	OFF_VLOW                 = 0.090,
	COLD_TIMP_CAP            = 0.210,
	MIN_HOLD                 = 0.050,
	MAX_HOLD                 = 1.2,
	TIMP_RISE_FLOOR          = 0.006,
	TIMP_RISE_N_OF_M         = 2,
	TIMP_RISE_M              = 3,
	RING_FRESH_MAX           = 0.6,
	REARM_HYST_FACTOR        = 0.5,
	REARM_HYST_WIN           = 0.5,
	REARM_COOLDOWN           = 0.220,
	ARM_DIST_CAP             = 22,
	ARM_TIMP_CAP             = 0.22,
	REENTRY_DIST             = 22,
	FAST_BALL_SPD            = 200,
	FAST_BALL_CPS            = 0,
	FAST_BALL_TIMP_CAP       = 0.060,
	DASH_SPD_THRESH          = 50,
	DASH_SPD_CONFIRM         = 62,
	DASH_SPD_RELEASE         = 35,
	DASH_DUR_MIN             = 0.08,
	DASH_DUR_MAX             = 0.5,
	DASH_PANIC_DOT           = 0.85,
	DASH_PANIC_WINDOW        = 0.300,
	DASH_PANIC_DIST          = 14,
	PREEMPT_DIST             = 22,
	PREEMPT_TIMP_CAP         = 0.120,
	PING_CREDIT_F            = 0.5,
	PING_FLOOR               = 0.040,
	PING_REF                 = 0.060,
	PING_MAX_SCALE           = 1.0,
	COLD_PING_SCALE          = 0.4,
	FAST_PING_SCALE          = 0.5,
	PREEMPT_PING_SCALE       = 0.4,
	MAINT_CHECK_INTERVAL     = 0.050,
	MAINT_HOLD_MIN           = 0.060,
	MAINT_BALL_RADIUS        = 25,
	MAINT_TIMP_MAX           = 0.30,
	MAINT_PARRY_KEEP         = 0.10,
	MAINT_TARGET_KEEP        = 0.15,
	MAINT_BALL_GONE_DIST     = 60,
	SPAM_PRE_FILL_FRAMES     = 4,
	BURST_ON_MS              = 0.080,
	BURST_OFF_MS             = 0.060,
	DET_RAD_MIN              = 10,
	DET_RAD_MAX              = 25,
	DET_RAD_SPD_REF          = 120,
	DET_RETURN_FACTOR        = 1.5,
	DET_DOT_EMA              = 0.25,
	DET_DOT_THRESH           = 0.15,
	DET_TIMEOUT              = 0.8,
	ANTIDASH_RAD_MIN         = 20,
	ANTIDASH_RAD_MAX         = 32,
	ANTIDASH_DOT_MIN         = 0.0,
	ANTIDASH_PANIC_HOLD      = 0.45,
	ANTIDASH_PANIC_MAX       = 1.2,
	ANTIDASH_COOLDOWN        = 0.35,
	TELEPORT_LOCK            = 0.20,
	DASH_TRACK_INTERVAL      = 0.2,
	FULL_PLAYER_SCAN_INTERVAL = 1.0,
	PLAYER_SCAN_RADIUS       = 100,
	DANGER_EMA_ALPHA         = 0.15,
}

-- P
local P = {
	DEFLECT_R         = 8.5,
	RAD_FLOOR         = 14,
	MIN_SPD           = 3,
	MAINT_BALL_RADIUS = 25,
}

-- S
local S = {
	lastTarget           = -999,
	lastTargetAt         = 0,
	clashOn              = false,
	clashAt              = 0,
	clashHoldUntil       = 0,
	clashOffAt           = 0,
	lastClashReact       = 0,
	dangerEma            = 0,
	lastTImp             = 0,
	lastTImpAt           = 0,
	tImpRising           = false,
	tImpRiseHist         = { 0, 0, 0 },
	targetRing           = table.create(8, 0),
	targetRingIdx        = 0,
	targetCps            = 0,
	dashEvents           = {},
	dashPanicUntil       = 0,
	detPhase             = "IDLE",
	detEnterAt           = 0,
	detEntryTime         = 0,
	detExitAt            = 0,
	detDotEma            = 0,
	detWasInside         = false,
	detSignal            = false,
	burstState           = "IDLE",
	burstOnStart         = 0,
	burstOffStart        = 0,
	burstSignalDuringOn  = false,
	dashAnti             = { untilT = 0, src = nil, at = 0 },
	lastMaintCheck       = 0,
	lastFireAt           = 0,
}

-- locals
local _burstActiveShared = false
local _onBurstSink       = nil

local _ctxCache = { t = 0, valid = false }
local CLASH_SNAPSHOT_TTL = 0.05
local RING_BUF           = 8
local _now               = os.clock
local _lastDashTrack     = 0
local _lastFullPlayerScan = 0
local _antidashCooldown  = {}
local _antidashHooked    = {}
local _localUserId       = -1
local _spamDebt          = 0

-- ringPush
local function ringPush(t)
	S.targetRingIdx = (S.targetRingIdx % RING_BUF) + 1
	S.targetRing[S.targetRingIdx] = t
end

-- updateTargetCps
local function updateTargetCps(t, freshWin)
	local winStart = t - CLASH.CPS_WIN
	local cnt = 0
	for i = 1, RING_BUF do
		local ts = S.targetRing[i]
		if ts and ts >= winStart and (not freshWin or ts >= t - freshWin) then
			cnt = cnt + 1
		end
	end
	S.targetCps = cnt / CLASH.CPS_WIN
end

-- tImpCapFor
local function tImpCapFor(spd, base, refSpd, lo, hi)
	if spd < 1 then return base end
	local s = math.clamp(refSpd / spd, 0.2, 2.5)
	return math.clamp(base * s, lo, hi)
end

-- maintTimpMax
-- deactTimpMax
local function maintTimpMax(spd) return tImpCapFor(spd, CLASH.MAINT_TIMP_MAX, 60, 0.06, 0.40) end
local function deactTimpMax(spd) return tImpCapFor(spd, CLASH.MAINT_TIMP_MAX, 60, 0.08, 0.40) end

-- isTargeted
local function isTargeted()
	return GameInfo.isTargeted(S.lastTarget)
end

-- clearClash
local function clearClash()
	S.clashOn, S.clashHoldUntil = false, 0
	S.clashOffAt = _now()
end

-- getDetectorRadius
local function getDetectorRadius(spd)
	local t = math.clamp((spd or 0) / CLASH.DET_RAD_SPD_REF, 0, 1)
	return CLASH.DET_RAD_MIN + (CLASH.DET_RAD_MAX - CLASH.DET_RAD_MIN) * t
end

-- tickReturnDetector
local function tickReturnDetector(t, hr, ball)
	S.detSignal = false
	if not (hr and hr.Parent and ball and ball.Parent) then
		S.detPhase, S.detDotEma, S.detWasInside = "IDLE", 0, false
		return
	end
	local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
	if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return end
	local spd    = av.Magnitude
	local radius = getDetectorRadius(spd)
	local toMe   = hr.Position - ball.Position
	local dist   = toMe.Magnitude
	local dotRaw = av:Dot(toMe.Unit)
	if dist <= radius * 1.2 then
		S.detDotEma = S.detDotEma * (1 - CLASH.DET_DOT_EMA) + dotRaw * CLASH.DET_DOT_EMA
	else
		S.detDotEma = 0
	end
	local isInside  = dist <= radius
	local dotComing = S.detDotEma >  CLASH.DET_DOT_THRESH
	local dotGoing  = S.detDotEma < -CLASH.DET_DOT_THRESH
	if S.detPhase == "EXITED" and (t - S.detExitAt) > CLASH.DET_TIMEOUT then
		S.detPhase = "IDLE"
	end
	if S.detPhase == "IDLE" then
		if (isInside and not S.detWasInside) or (not isInside and dotComing) then
			local entryTime = dist > 0.1 and (dist / spd) or 0.01
			S.detPhase     = "INSIDE"
			S.detEnterAt   = t
			S.detEntryTime = entryTime
		end
	elseif S.detPhase == "INSIDE" then
		if (not isInside and S.detWasInside) or (isInside and dotGoing) then
			S.detPhase  = "EXITED"
			S.detExitAt = t
		end
	elseif S.detPhase == "EXITED" then
		local delta  = t - S.detExitAt
		local limiar = S.detEntryTime * CLASH.DET_RETURN_FACTOR
		if (isInside and not S.detWasInside) or dotComing then
			if delta <= limiar and dotComing then
				S.detSignal = true
			end
			local entryTime = dist > 0.1 and (dist / spd) or 0.01
			S.detPhase     = "INSIDE"
			S.detEnterAt   = t
			S.detEntryTime = entryTime
		end
	end
	S.detWasInside = isInside
end

-- clashSnapshot
local function clashSnapshot()
	local t = _now()
	if _ctxCache.valid and (t - _ctxCache.t) < CLASH_SNAPSHOT_TTL then
		return _ctxCache
	end
	local lp = Utils.getLocalPlayer()
	local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if not (hr and hr.Parent) then
		_ctxCache.valid = false
		return nil
	end
	updateTargetCps(t, CLASH.RING_FRESH_MAX)
	local ball = GameInfo.getBall()
	if not (ball and ball.Parent) then
		_ctxCache.valid = false
		return nil
	end
	local nearest, nearestAlive = GameInfo.nearestPlayerAlive()
	local bp = ball.Position
	local bDist = (hr.Position - bp).Magnitude
	local panic = nearestAlive and (nearest <= CLASH.PANIC_DIST and bDist <= CLASH.PANIC_BALL)
	local live = GameInfo.liveTImp()
	local tImp, spd = live.tImp, live.spd
	if spd < 1 then
		local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
		tImp, spd = ti, s2
	end
	_ctxCache.t, _ctxCache.valid = t, true
	_ctxCache.hr = hr
	_ctxCache.ball, _ctxCache.bp = ball, bp
	_ctxCache.nearest, _ctxCache.nearestAlive = nearest, nearestAlive
	_ctxCache.bDist, _ctxCache.panic = bDist, panic
	_ctxCache.tImp, _ctxCache.spd = tImp, spd
	return _ctxCache
end

function AutoClash.invalidateSnapshot()
	_ctxCache.valid = false
end

-- maintRadius
local function maintRadius(spd)
	local base = math.max(
		P.DEFLECT_R + GameInfo.preBufferStuds(spd) + (AutoParry and AutoParry.resRadiusBonus() or 0),
		CLASH.MAINT_BALL_RADIUS
	)
	return math.min(base, 55)
end

-- shouldMaintainClash
local function shouldMaintainClash()
	if not S.clashOn then return false end
	local t = _now()
	if (t - S.clashAt) < CLASH.MAINT_HOLD_MIN then return true end
	local ctx = clashSnapshot()
	if not ctx then return false end
	if ctx.bDist > CLASH.MAINT_BALL_GONE_DIST then return false end
	if ctx.bDist <= maintRadius(ctx.spd) then return true end
	if ctx.tImp > 0 and ctx.tImp <= maintTimpMax(ctx.spd) then return true end
	if isTargeted() then return true end
	if (t - S.lastFireAt) < CLASH.MAINT_PARRY_KEEP then return true end
	if (t - S.lastTargetAt) < CLASH.MAINT_TARGET_KEEP then return true end
	return false
end

-- tickMaintenance
local function tickMaintenance()
	if not S.clashOn then return end
	local t = _now()
	if (t - S.lastMaintCheck) < CLASH.MAINT_CHECK_INTERVAL then return end
	S.lastMaintCheck = t
	if not shouldMaintainClash() then
		clearClash()
	end
end

-- isBallApproaching
local function isBallApproaching(hrp, ball)
	local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
	if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return true end
	local toMe = hrp.Position - ball.Position
	if toMe.Magnitude < 1 then return true end
	return av:Dot(toMe.Unit) > 0.25
end

-- shouldDeactivateClash
local function shouldDeactivateClash()
	if not S.clashOn then return false end
	local t = _now()
	if t < math.max(S.clashAt + CLASH.MIN_HOLD, S.clashHoldUntil) then return false end
	if (t - S.clashAt) > CLASH.MAX_HOLD then return true end
	local lp = Utils.getLocalPlayer()
	local myChar = lp.Character
	if not (myChar and myChar.Parent) then return true end
	local myHum = myChar:FindFirstChildOfClass("Humanoid")
	if not (myHum and myHum.Parent and myHum.Health > 0) then return true end
	local ball = GameInfo.getBall()
	if not (ball and ball.Parent) then return true end
	local ctx = clashSnapshot()
	if not ctx then return true end
	if ctx.bDist > CLASH.MAINT_BALL_GONE_DIST then return true end
	local deactRad = math.clamp(P.DEFLECT_R + P.RAD_FLOOR, 18, 30)
	if ctx.bDist > deactRad then return true end
	if ctx.tImp > deactTimpMax(ctx.spd) then return true end
	local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if hr and hr.Parent and ctx.ball and ctx.ball.Parent then
		if not isBallApproaching(hr, ctx.ball) and ctx.bDist > 15 then return true end
	end
	if ctx.spd < 1 and ctx.bDist > 20 then return true end
	return false
end

-- activateBurst
local function activateBurst(t, Config)
	S.burstState          = "ON"
	S.burstOnStart        = t
	S.burstSignalDuringOn = false
	S.clashOn             = true
	S.clashAt             = t
	S.clashHoldUntil      = t + CLASH.BURST_ON_MS
	S.lastClashReact      = t
	S.clashOffAt          = 0
	S.lastTImp, S.lastTImpAt, S.tImpRising = 0, 0, false
	S.tImpRiseHist        = { 0, 0, 0 }
	S.lastMaintCheck      = t
	local c = math.max(tonumber(Config.CPS) or Utils.defaultCps(), 1)
	_spamDebt  = (1 / c) * CLASH.SPAM_PRE_FILL_FRAMES
	_burstActiveShared = false
	if _onBurstSink then
		_onBurstSink()
	end
	if _G.PhantomOnBurst then
		_G.PhantomOnBurst()
	end
end

-- onTarget
local function onTarget(newTarget, t)
	if type(newTarget) ~= "number" then
		return
	end
	local previousTarget = S.lastTarget
	S.lastTarget, S.lastTargetAt = newTarget, t
	ringPush(t)
	local ap = AutoParry.getState()
	ap.armed = newTarget == _localUserId
	-- (v22.1: AP.fired é resetado pelo onBallSync na borda de target, não aqui)
	local Config = _G.PhantomConfig
	local targeted = newTarget == _localUserId
	if targeted and Config and Config.AutoClash ~= false and not _G.PhantomManual
		and previousTarget ~= _localUserId and previousTarget ~= -999
	then
		local lp = Utils.getLocalPlayer()
		local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
		local ball = GameInfo.getBall()
		if hr and hr.Parent and ball and ball.Parent then
			local bp = GameInfo.ballPos(ball, t)
			local bDist = (hr.Position - bp).Magnitude
			local speed = GameInfo.ballSpeed(ball, t)
			local impactTime = speed > 1 and GameInfo.tImpCompensated(bDist, speed) or math.huge
			if bDist <= CLASH.BALL_HARD_CAP
				and impactTime <= CLASH.OFF_FAST
				and (t - S.lastClashReact) >= CLASH.REACT_CD
			then
				activateBurst(t, Config)
				S.clashHoldUntil = t + CLASH.HOLD
			end
		end
	end
end

-- onTeleport
local function onTeleport()
	clearClash()
end

-- evaluateClash
local function evaluateClash(t, hr, ball, Config)
	if Config.AutoClash == false or _G.PhantomManual then
		if S.clashOn then
			clearClash()
		end
		S.burstState = "IDLE"
		S.burstSignalDuringOn = false
		return
	end
	
	-- Detector roda SEMPRE, inclusive quando clashOn
	tickReturnDetector(t, hr, ball)
	
	-- Desativação por condições extremas (morte, teleporte, bola sumiu)
	if S.clashOn and shouldDeactivateClash() then
		clearClash()
		S.burstState          = "IDLE"
		S.burstSignalDuringOn = false
		return
	end
	
	-- Se clash está on, só o burst renova o hold
	-- O maintain segura o clash via shouldMaintainClash
	if S.clashOn then
		-- Burst em ON: renova se houver sinal
		if S.burstState == "ON" then
			if S.detSignal then
				S.burstSignalDuringOn = true
			end
			-- Não vai pro OFF: deixa o maintain decidir
			-- Só renova o hold se houver sinal
			if S.burstSignalDuringOn then
				S.burstOnStart        = t
				S.burstSignalDuringOn = false
				S.clashHoldUntil      = t + CLASH.BURST_ON_MS
			end
		end
		return
	end
	
	-- Clash não está on: máquina de burst normal
	local antiDashActive = S.dashAnti.untilT > t
	local canFire = (S.detSignal and isTargeted()) or antiDashActive
	
	if S.burstState == "IDLE" then
		if canFire then
			activateBurst(t, Config)
		end
	elseif S.burstState == "ON" then
		if S.detSignal then
			S.burstSignalDuringOn = true
		end
		if (t - S.burstOnStart) >= CLASH.BURST_ON_MS then
			if S.burstSignalDuringOn then
				S.burstOnStart        = t
				S.burstSignalDuringOn = false
				S.clashHoldUntil      = t + CLASH.BURST_ON_MS
			else
				S.burstState    = "OFF"
				S.burstOffStart = t
			end
		end
	elseif S.burstState == "OFF" then
		if canFire then
			activateBurst(t, Config)
		elseif (t - S.burstOffStart) >= CLASH.BURST_OFF_MS then
			S.burstState = "IDLE"
		end
	end
end

-- updateDashTrack
local function updateDashTrack(t, Players)
	if (t - _lastDashTrack) < CLASH.DASH_TRACK_INTERVAL then return end
	_lastDashTrack = t
	local lp = Utils.getLocalPlayer()
	local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if not (myHRP and myHRP.Parent) then
		table.clear(S.dashEvents)
		return
	end
	local myPos = myHRP.Position
	local curDist = math.huge
	local playersToCheck = {}
	local fullScan = (t - _lastFullPlayerScan) >= CLASH.FULL_PLAYER_SCAN_INTERVAL
	if fullScan then
		_lastFullPlayerScan = t
		for _, p in Players:GetPlayers() do
			if p ~= lp then
				table.insert(playersToCheck, p)
			end
		end
	else
		for uid in pairs(S.dashEvents) do
			local p = Players:GetPlayerByUserId(uid)
			if p and p ~= lp then
				table.insert(playersToCheck, p)
			end
		end
		for _, p in Players:GetPlayers() do
			if p ~= lp and not S.dashEvents[p.UserId] then
				local ch = p.Character
				local php = ch and ch:FindFirstChild("HumanoidRootPart")
				if php and php.Parent and (myPos - php.Position).Magnitude <= CLASH.PLAYER_SCAN_RADIUS then
					table.insert(playersToCheck, p)
				end
			end
		end
	end
	local processed = {}
	for _, p in ipairs(playersToCheck) do
		if processed[p.UserId] then continue end
		processed[p.UserId] = true
		local ch = p.Character
		local php = ch and ch:FindFirstChild("HumanoidRootPart")
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		local alive = php and php.Parent and hum and hum.Parent and hum.Health > 0
		if alive then
			local d = (myPos - php.Position).Magnitude
			if d < curDist then
				curDist = d
			end
			local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
			local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
			local dir = (ok and typeof(av) == "Vector3" and av.Magnitude > 0.1) and av.Unit or nil
			local ev = S.dashEvents[p.UserId]
			if spd >= CLASH.DASH_SPD_THRESH and dir then
				if not ev then
					S.dashEvents[p.UserId] = {
						spd = spd, dir = dir, at = t,
						startedAt = t, confirmed = false,
					}
				else
					ev.spd, ev.dir, ev.at = spd, dir, t
					if not ev.confirmed and spd >= CLASH.DASH_SPD_CONFIRM then
						ev.confirmed = true
						ev.startedAt = t
					end
				end
			elseif ev and ev.confirmed and spd >= CLASH.DASH_SPD_RELEASE and dir then
				ev.spd, ev.dir, ev.at = spd, dir, t
			elseif ev and ev.confirmed and spd >= CLASH.DASH_SPD_THRESH then
				ev.spd, ev.at = spd, t
			else
				S.dashEvents[p.UserId] = nil
			end
		else
			S.dashEvents[p.UserId] = nil
		end
	end
	for uid in pairs(S.dashEvents) do
		if not processed[uid] then
			S.dashEvents[uid] = nil
		end
	end
	for uid, ev in pairs(S.dashEvents) do
		if ev and ev.confirmed and ev.dir and ev.spd then
			local dur = ev.at - ev.startedAt
			if dur > CLASH.DASH_DUR_MAX then
				S.dashEvents[uid] = nil
			else
				local pl = Players:GetPlayerByUserId(uid)
				local ch = pl and pl.Character
				local php = ch and ch:FindFirstChild("HumanoidRootPart")
				if not (php and php.Parent) then
					S.dashEvents[uid] = nil
				elseif dur >= CLASH.DASH_DUR_MIN then
					local toMe = myPos - php.Position
					local dist = toMe.Magnitude
					if dist <= CLASH.DASH_PANIC_DIST and dist > 0.1 then
						local dot = ev.dir:Dot(toMe.Unit)
						if dot >= CLASH.DASH_PANIC_DOT and ev.spd >= CLASH.DASH_SPD_CONFIRM then
							S.dashPanicUntil = math.max(S.dashPanicUntil, t + CLASH.DASH_PANIC_WINDOW)
						end
					end
				end
			end
		end
	end
end

-- reportDash
local function reportDash(player)
	if not player or player == Utils.getLocalPlayer() then return end
	if not _G.PhantomState or not _G.PhantomState.active then return end
	local t = _now()
	local last = _antidashCooldown[player.UserId]
	if last and (t - last) < CLASH.ANTIDASH_COOLDOWN then return end
	_antidashCooldown[player.UserId] = t
	local ch = player.Character
	if not (ch and ch.Parent) then return end
	local php = ch:FindFirstChild("HumanoidRootPart")
	local lp = Utils.getLocalPlayer()
	local myChar = lp and lp.Character
	local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
	if not (php and php.Parent and myHRP and myHRP.Parent) then return end
	local baseParryRad = P.DEFLECT_R + (AutoParry and AutoParry.resRadiusBonus() or 0) + P.RAD_FLOOR
	local rad = math.clamp(baseParryRad, CLASH.ANTIDASH_RAD_MIN, CLASH.ANTIDASH_RAD_MAX)
	local toMe = myHRP.Position - php.Position
	local dist = toMe.Magnitude
	if dist > rad or dist < 0.1 then return end
	local dot = 1
	local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
	if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
		dot = av.Unit:Dot(toMe.Unit)
	end
	if dot < CLASH.ANTIDASH_DOT_MIN then return end
	local untilT = t + CLASH.ANTIDASH_PANIC_HOLD
	S.dashAnti.untilT = math.max(S.dashAnti.untilT, math.min(untilT, t + CLASH.ANTIDASH_PANIC_MAX))
	S.dashAnti.src   = player
	S.dashAnti.at    = t
end

-- _hookPlayerAntiDash
local function _hookPlayerAntiDash(player)
	if not player or player == Utils.getLocalPlayer() then return end
	if _antidashHooked[player] then return end
	_antidashHooked[player] = true
	local function attach(char)
		if not char then return end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		local anim = hum:WaitForChild("Animator", 5)
		if not anim then return end
		task.defer(function()
			pcall(function()
				for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
					local n  = (tr.Name or ""):lower()
					local an = tr.Animation and tr.Animation.Name or ""
					if n:find("dash") or an:lower():find("dash") then
						reportDash(player)
						break
					end
				end
			end)
		end)
		pcall(function()
			anim.AnimationPlayed:Connect(function(track)
				if not track or not track.Animation then return end
				local n  = (track.Name or ""):lower()
				local an = track.Animation.Name or ""
				if n:find("dash") or an:lower():find("dash") then
					reportDash(player)
				end
			end)
		end)
	end
	if player.Character then
		attach(player.Character)
	end
	pcall(function() player.CharacterAdded:Connect(attach) end)
end

-- installAntiDashHooks
local function installAntiDashHooks(Players)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= Utils.getLocalPlayer() then
			_hookPlayerAntiDash(p)
		end
	end
	pcall(function()
		Players.PlayerAdded:Connect(function(p)
			if p ~= Utils.getLocalPlayer() then
				_hookPlayerAntiDash(p)
			end
		end)
	end)
	pcall(function()
		Players.PlayerRemoving:Connect(function(p)
			_antidashHooked[p] = nil
			_antidashCooldown[p.UserId] = nil
		end)
	end)
end

-- setup
function AutoClash.setup(deps)
	_Probe    = deps.Probe
	GameInfo  = deps.GameInfo
	Utils     = deps.Utils
	AutoParry = deps.AutoParry
	_localUserId = Utils.getLocalPlayer().UserId
	_G.PhantomClashOn    = function() return S.clashOn end
	_G.PhantomOnTarget   = onTarget
	_G.PhantomOnTeleport = onTeleport
end

-- public api
function AutoClash.evaluate(t, hr, ball, Config)
	evaluateClash(t, hr, ball, Config)
end

function AutoClash.tickMaintenance()      tickMaintenance() end
function AutoClash.updateDashTrack(t)     updateDashTrack(t, Utils.getPlayers()) end
function AutoClash.installAntiDashHooks() installAntiDashHooks(Utils.getPlayers()) end
function AutoClash.getState()             return S end
function AutoClash.clashOn()              return S.clashOn end
function AutoClash.getClashAt()           return S.clashAt end
function AutoClash.snapshot()             return clashSnapshot() end

-- resetState
function AutoClash.resetState()
	S.clashOn, S.clashAt, S.clashHoldUntil, S.clashOffAt, S.lastClashReact = false, 0, 0, 0, 0
	S.dangerEma, S.lastTImp, S.lastTImpAt, S.tImpRising = 0, 0, 0, false
	S.tImpRiseHist = { 0, 0, 0 }
	S.targetRingIdx, S.targetCps, S.lastMaintCheck = 0, 0, 0
	S.lastFireAt = 0
	for i = 1, RING_BUF do
		S.targetRing[i] = 0
	end
	table.clear(S.dashEvents)
	S.dashPanicUntil = 0
	S.detPhase, S.detEnterAt, S.detEntryTime, S.detExitAt = "IDLE", 0, 0, 0
	S.detDotEma, S.detWasInside, S.detSignal = 0, false, false
	S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
	S.dashAnti = { untilT = 0, src = nil, at = 0 }
	_ctxCache.valid = false
end

-- notifyFired
-- setBurstActive
-- getBurstActive
-- setBurstSink
function AutoClash.notifyFired(t)
	S.lastFireAt = t
end

function AutoClash.setBurstActive(b)
	_burstActiveShared = b
end

function AutoClash.getBurstActive() return _burstActiveShared end
function AutoClash.setBurstSink(fn) _onBurstSink = fn end

return AutoClash
