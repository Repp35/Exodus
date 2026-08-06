--[[
    AutoClash Module
]]--

local AutoClash = {}

local Probe
local GameInfo
local Utils
local AutoParry
local P = nil

local CLASH = {
    BALL_HARD_CAP            = 22,
    HOLD                     = 0.20,
    REACT_CD                 = 0.120,
    MAX_HOLD                 = 1.2,
    BURST_ON_MS              = 0.080,
    BURST_OFF_MS             = 0.060,
    SPAM_PRE_FILL_FRAMES     = 4,
    DET_RAD_MIN              = 10,
    DET_RAD_MAX              = 25,
    DET_RAD_SPD_REF          = 120,
    DET_DOT_EMA              = 0.25,
    DET_DOT_THRESH           = 0.15,
    DET_RETURN_FACTOR        = 1.5,
    DET_TIMEOUT              = 0.8,
    RING_FRESH_MAX           = 0.6,
    CPS_WIN                  = 1.0,
    OFF_FAST                 = 0.050,
    T_IMP_CAP_BASE           = 0.090,
    T_IMP_CAP_FLOOR          = 0.050,
    PANIC_DIST               = 9,
    PANIC_BALL               = 13,
    DASH_SPD_THRESH          = 50,
    DASH_SPD_CONFIRM         = 62,
    DASH_SPD_RELEASE         = 35,
    DASH_DUR_MIN             = 0.08,
    DASH_DUR_MAX             = 0.5,
    DASH_PANIC_DOT           = 0.85,
    DASH_PANIC_DIST          = 14,
    DASH_PANIC_WINDOW        = 0.300,
    DASH_TRACK_INTERVAL      = 0.2,
    FULL_PLAYER_SCAN_INTERVAL= 1.0,
    PLAYER_SCAN_RADIUS       = 100,
    ANTIDASH_RAD_MIN         = 20,
    ANTIDASH_RAD_MAX         = 32,
    ANTIDASH_DOT_MIN         = 0.0,
    ANTIDASH_PANIC_HOLD      = 0.45,
    ANTIDASH_PANIC_MAX       = 1.2,
    ANTIDASH_COOLDOWN        = 0.35,
    MAINT_BALL_GONE_DIST     = 60,
    MIN_HOLD                 = 0.050,
    DEACT_TIMP_THRESH        = 0.25,
    DEACT_TIMP_SUSTAIN       = 0.15,
    ACT_TIMP_THRESH          = 0.22,  -- Limiar de tImp para ativação precisa
}

local RING_BUF = 8

local S = {
    lastTarget          = -999,
    lastTargetAt        = 0,
    targetRing          = table.create(RING_BUF, 0),
    targetRingIdx       = 0,
    targetCps           = 0,
    clashOn             = false,
    clashAt             = 0,
    clashHoldUntil      = 0,
    clashOffAt          = 0,
    lastClashReact      = 0,
    lastFireAt          = 0,
    teleportLockUntil   = 0,
    burstState          = "IDLE",
    burstOnStart        = 0,
    burstOffStart       = 0,
    burstSignalDuringOn = false,
    detPhase            = "IDLE",
    detEnterAt          = 0,
    detEntryTime        = 0,
    detExitAt           = 0,
    detDotEma           = 0,
    detWasInside        = false,
    detSignal           = false,
    dashEvents          = {},
    dashPanicUntil      = 0,
    dashAnti            = { untilT = 0, src = nil, at = 0 },
    tImpHighSince       = 0,
}

local _localUserId = -1
local _antidashCooldown, _antidashHooked = {}, {}
local _lastDashTrack = 0
local _ctxCache = { t = 0, valid = false }
local CLASH_SNAPSHOT_TTL = 0.05
local _spamDebt = 0

local function ringPush(t)
    S.targetRingIdx = (S.targetRingIdx % RING_BUF) + 1
    S.targetRing[S.targetRingIdx] = t
end

local function updateTargetCps(t)
    local winStart = t - CLASH.CPS_WIN
    local freshThresh = t - CLASH.RING_FRESH_MAX
    local cnt = 0
    for i = 1, RING_BUF do
        local ts = S.targetRing[i]
        if ts > winStart and ts > freshThresh then
            cnt = cnt + 1
        end
    end
    S.targetCps = cnt / CLASH.CPS_WIN
end

local function isTargeted()
    return GameInfo.isTargeted(S.lastTarget)
end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function requireP()
    if P ~= nil then return P end
    if AutoParry and type(AutoParry.getP) == "function" then
        P = AutoParry.getP()
    end
    return P
end

local function getParryBonus()
    if AutoParry and type(AutoParry.resRadiusBonus) == "function" then
        return AutoParry.resRadiusBonus()
    end
    return 0
end

local function getBall()
    return GameInfo.getBall()
end

local function getDetectorRadius(spd)
    local t = math.clamp((spd or 0) / CLASH.DET_RAD_SPD_REF, 0, 1)
    return CLASH.DET_RAD_MIN + (CLASH.DET_RAD_MAX - CLASH.DET_RAD_MIN) * t
end

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
        local limiar = S.detEntryTime * CLASH.DET_RETURN_FACTOR
        if isInside and not S.detWasInside then
            if limiar > 0 and (t - S.detExitAt) <= limiar then
                S.detSignal = true
            end
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        elseif dotComing then
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end
    end
    S.detWasInside = isInside
end

local function clashSnapshot()
    local t = Utils.now()
    if _ctxCache.valid and (t - _ctxCache.t) < CLASH_SNAPSHOT_TTL then return _ctxCache end
    local hr = getMyHRP()
    if not hr then _ctxCache.valid = false; return nil end
    local ball = getBall()
    if not (ball and ball.Parent) then _ctxCache.valid = false; return nil end
    updateTargetCps(t)
    local nearest, nearestAlive = GameInfo.nearestPlayerAlive()
    local bp = ball.Position
    local hrpPos = hr.Position
    local bDist = (hrpPos - bp).Magnitude
    local panic = nearestAlive and (nearest <= CLASH.PANIC_DIST and bDist <= CLASH.PANIC_BALL)
    local tImp, spd = 0, 0
    local live = GameInfo.liveTImp()
    if live then
        tImp = tonumber(live.tImp) or 0
        spd  = tonumber(live.spd) or 0
    end
    if spd < 1 then
        local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
        tImp = tonumber(ti) or tImp
        spd  = tonumber(s2) or spd
    end
    _ctxCache.t, _ctxCache.valid = t, true
    _ctxCache.hr = hr
    _ctxCache.ball, _ctxCache.bp = ball, bp
    _ctxCache.nearest, _ctxCache.nearestAlive = nearest, nearestAlive
    _ctxCache.bDist, _ctxCache.panic = bDist, panic
    _ctxCache.tImp, _ctxCache.spd = tImp, spd
    _ctxCache.targeted = isTargeted()
    return _ctxCache
end

local function clearClash()
    S.clashOn, S.clashHoldUntil = false, 0
    S.clashOffAt = Utils.now()
    S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
    S.tImpHighSince = 0
end

local function _activateBurst(t)
    S.burstState          = "ON"
    S.burstOnStart        = t
    S.burstSignalDuringOn = false
    S.clashOn             = true
    S.clashAt             = t
    S.clashHoldUntil      = t + CLASH.BURST_ON_MS
    S.lastClashReact      = t
    S.clashOffAt          = 0
    S.tImpHighSince       = 0
    
    local config = Utils.getConfig()
    local c = math.max(tonumber(config and config.CPS) or 25, 1)
    _spamDebt  = (1 / c) * CLASH.SPAM_PRE_FILL_FRAMES

    local burst = _G.PhantomOnBurst
    if type(burst) == "function" then
        pcall(burst)
    elseif AutoParry and type(AutoParry.fire) == "function" then
        pcall(AutoParry.fire)
    end
end

local function shouldMaintainClash(t, ctx)
    if not S.clashOn then return false end
    if t < math.max(S.clashAt + CLASH.MIN_HOLD, S.clashHoldUntil) then return true end
    if (t - S.clashAt) > CLASH.MAX_HOLD then return false end
    if t < S.teleportLockUntil then return false end
    if ctx.bDist > CLASH.MAINT_BALL_GONE_DIST then return false end

    if (ctx.tImp or 0) > CLASH.DEACT_TIMP_THRESH then
        if S.tImpHighSince == 0 then S.tImpHighSince = t end
        if (t - S.tImpHighSince) >= CLASH.DEACT_TIMP_SUSTAIN then
            return false
        end
    else
        S.tImpHighSince = 0
    end

    return true
end

local function evaluateClash(t, hr, ball, config)
    if not config or config.AutoClash == false or _G.PhantomManual then
        if S.clashOn then clearClash() end
        S.burstState = "IDLE"
        S.burstSignalDuringOn = false
        return
    end
    tickReturnDetector(t, hr, ball)
    local ctx = clashSnapshot()

    if S.clashOn then
        if ctx and not shouldMaintainClash(t, ctx) then
            clearClash()
            S.burstState          = "IDLE"
            S.burstSignalDuringOn = false
        end
        return
    end

    local antiDashActive = S.dashAnti.untilT > t
    local panicActive    = S.dashPanicUntil > t
    local targeted       = ctx and ctx.targeted or isTargeted()
    
    -- Ativação baseada em tImp e detSignal, evitando ativação cega por distância
    local timpValid      = ctx and ctx.tImp > 0 and ctx.tImp <= CLASH.ACT_TIMP_THRESH or false
    local canFire        = (S.detSignal and targeted) or antiDashActive or panicActive or (timpValid and targeted)

    if S.burstState == "IDLE" then
        if canFire then _activateBurst(t) end
    elseif S.burstState == "ON" then
        if S.detSignal then S.burstSignalDuringOn = true end
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
            _activateBurst(t)
        elseif (t - S.burstOffStart) >= CLASH.BURST_OFF_MS then
            S.burstState = "IDLE"
        end
    end
end

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    local previousTarget = S.lastTarget
    S.lastTarget = newTarget
    S.lastTargetAt = t
    ringPush(t)
    local apState = AutoParry.getState()
    if apState then apState.armed = (newTarget == _localUserId) end
end

local function updateDashTrack(t)
    if (t - _lastDashTrack) < CLASH.DASH_TRACK_INTERVAL then return end
    _lastDashTrack = t
    local lp = Utils.getLocalPlayer()
    local char = lp.Character
    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP then table.clear(S.dashEvents); return end
    local myPos = myHRP.Position
    local PlayersService = Utils.getPlayers()
    local allPlayers = PlayersService:GetPlayers()
    for i = 1, #allPlayers do
        local p = allPlayers[i]
        if p == lp then continue end
        local pChar = p.Character
        if not pChar then S.dashEvents[p.UserId] = nil; continue end
        local php = pChar:FindFirstChild("HumanoidRootPart")
        if not php then S.dashEvents[p.UserId] = nil; continue end
        local dist = (myPos - php.Position).Magnitude
        if dist > CLASH.PLAYER_SCAN_RADIUS and not S.dashEvents[p.UserId] then continue end
        local hum = pChar:FindFirstChildOfClass("Humanoid")
        if not (hum and hum.Health > 0) then S.dashEvents[p.UserId] = nil; continue end
        local av = php.AssemblyLinearVelocity
        local spd = av.Magnitude
        local ev = S.dashEvents[p.UserId]
        if spd >= CLASH.DASH_SPD_THRESH then
            local dir = av.Unit
            if not ev then
                S.dashEvents[p.UserId] = { spd = spd, dir = dir, at = t, startedAt = t, confirmed = false }
            else
                ev.spd, ev.dir, ev.at = spd, dir, t
                if not ev.confirmed and spd >= CLASH.DASH_SPD_CONFIRM then
                    ev.confirmed, ev.startedAt = true, t
                end
            end
        else
            S.dashEvents[p.UserId] = nil
        end
    end
    for uid, ev in pairs(S.dashEvents) do
        local p = PlayersService:GetPlayerByUserId(uid)
        if not p or not ev.confirmed or not ev.dir then
            if not p then S.dashEvents[uid] = nil end
            continue
        end
        local dur = t - ev.startedAt
        if dur > CLASH.DASH_DUR_MAX then S.dashEvents[uid] = nil; continue end
        if dur >= CLASH.DASH_DUR_MIN then
            local pChar = p.Character
            local php = pChar and pChar:FindFirstChild("HumanoidRootPart")
            if php then
                local toMe = myPos - php.Position
                local dist = toMe.Magnitude
                if dist <= CLASH.DASH_PANIC_DIST then
                    local dot = ev.dir:Dot(toMe.Unit)
                    if dot >= CLASH.DASH_PANIC_DOT and ev.spd >= CLASH.DASH_SPD_CONFIRM then
                        S.dashPanicUntil = math.max(S.dashPanicUntil, t + CLASH.DASH_PANIC_WINDOW)
                        S.dashAnti.src    = p
                        S.dashAnti.untilT = math.max(S.dashAnti.untilT, t + CLASH.ANTIDASH_PANIC_HOLD)
                    end
                end
            end
        end
    end
end

local function reportDash(player)
    if not player or not Utils then return end
    local lp = Utils.getLocalPlayer()
    if player == lp then return end
    if not Utils.isActive() then return end
    local t = Utils.now()
    if _antidashCooldown[player.UserId] and (t - _antidashCooldown[player.UserId]) < CLASH.ANTIDASH_COOLDOWN then return end
    _antidashCooldown[player.UserId] = t
    local ch = player.Character
    if not (ch and ch.Parent) then return end
    local php = ch:FindFirstChild("HumanoidRootPart")
    local myHRP = getMyHRP()
    if not (php and php.Parent and myHRP and myHRP.Parent) then return end
    local p = requireP()
    if p == nil then return end
    local rad = math.clamp(p.DEFLECT_R + getParryBonus() + (p.ANTIDASH_BONUS or 0), CLASH.ANTIDASH_RAD_MIN, CLASH.ANTIDASH_RAD_MAX)
    local toMe = myHRP.Position - php.Position
    local dist = toMe.Magnitude
    if dist > rad or dist < 0.1 then return end
    local dot = 1
    local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
    if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then dot = av.Unit:Dot(toMe.Unit) end
    if dot < CLASH.ANTIDASH_DOT_MIN then return end
    local untilT = math.min(t + CLASH.ANTIDASH_PANIC_MAX, t + CLASH.ANTIDASH_PANIC_HOLD)
    S.dashAnti.untilT = math.max(S.dashAnti.untilT, untilT)
    S.dashAnti.src    = player
end

local function isDashAnimation(track)
    if not track or not track.Animation then return false end
    local n  = (track.Name or ""):lower()
    local an = (track.Animation.Name or ""):lower()
    return n:find("dash", 1, true) ~= nil or an:find("dash", 1, true) ~= nil
end

local function _hookPlayerAntiDash(player)
    if not player or not Utils then return end
    if player == Utils.getLocalPlayer() then return end
    if _antidashHooked[player] then return end
    _antidashHooked[player] = true
    local function attach(char)
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        local anim = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
        if not anim then return end
        for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
            if isDashAnimation(tr) then reportDash(player); break end
        end
        anim.AnimationPlayed:Connect(function(track)
            if isDashAnimation(track) then reportDash(player) end
        end)
    end
    if player.Character then attach(player.Character) end
    player.CharacterAdded:Connect(attach)
end

local function installAntiDashHooks()
    local PlayersService = Utils.getPlayers()
    for _, p in ipairs(PlayersService:GetPlayers()) do
        if p ~= Utils.getLocalPlayer() then _hookPlayerAntiDash(p) end
    end
    PlayersService.PlayerAdded:Connect(function(p)
        if p ~= Utils.getLocalPlayer() then _hookPlayerAntiDash(p) end
    end)
    PlayersService.PlayerRemoving:Connect(function(p)
        _antidashHooked[p] = nil
        _antidashCooldown[p.UserId] = nil
        S.dashEvents[p.UserId] = nil
    end)
end

function AutoClash.setup(deps)
    Probe = deps.Probe
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry
    local lp = Utils.getLocalPlayer()
    _localUserId = lp and lp.UserId or -1
    if AutoParry and type(AutoParry.getP) == "function" then
        P = AutoParry.getP()
    end
    Utils.setOnClashOn(function() return S.clashOn end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(clearClash)
end

function AutoClash.evaluate(t, hr, ball, config)
    evaluateClash(t, hr, ball, config)
end

function AutoClash.tickMaintenance()
end

function AutoClash.updateDashTrack(t)
    updateDashTrack(t)
end

function AutoClash.installAntiDashHooks()
    installAntiDashHooks()
end

function AutoClash.getState()
    return S
end

function AutoClash.clashOn()
    return S.clashOn
end

function AutoClash.getClashAt()
    return S.clashAt
end

function AutoClash.snapshot()
    return clashSnapshot()
end

function AutoClash.invalidateSnapshot()
    _ctxCache.valid = false
end

function AutoClash.resetState()
    S.clashOn, S.clashAt, S.clashHoldUntil, S.clashOffAt, S.lastClashReact = false, 0, 0, 0, 0
    S.targetRingIdx, S.targetCps = 0, 0
    S.lastTargetAt, S.lastFireAt, S.teleportLockUntil = 0, 0, 0
    for i = 1, RING_BUF do S.targetRing[i] = 0 end
    table.clear(S.dashEvents)
    S.dashPanicUntil = 0
    S.detPhase, S.detEnterAt, S.detEntryTime, S.detExitAt = "IDLE", 0, 0, 0
    S.detDotEma, S.detWasInside, S.detSignal = 0, false, false
    S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
    S.dashAnti = { untilT = 0, src = nil, at = 0 }
    S.tImpHighSince = 0
    _ctxCache.valid = false
end

function AutoClash.setTeleportLock(t)
    S.teleportLockUntil = t + 0.20
end

function AutoClash.recordFire(t)
    S.lastFireAt = t
end

if _G.ExodusModules then
    _G.ExodusModules.AutoClash = AutoClash
end

return AutoClash
