--[[ autoclash.luau ]]

-- módulo
local AutoClash = {}

-- dependências
local Probe
local GameInfo
local Utils
local AutoParry

-- tunings
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
    CPS_THRESH               = 8,

    OFF_FAST                 = 0.050,
    T_IMP_CAP_BASE           = 0.090,
    T_IMP_CAP_FLOOR          = 0.050,

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

    DEACT_RETURN_FACTOR      = 4.0,
    DEACT_RETURN_FLOOR       = 0.250,
    DEACT_HOLD_OFF_MS        = 0.150,
    FLOW_PROTECT_MS          = 0.150,

    MAINT_EMA_UP             = 0.6,
    MAINT_EMA_DOWN           = 0.10,
    MAINT_FLOOR              = 0.30,

    PANIC_CD_RADIUS          = 0.180,
    PANIC_CD_TARGET          = 0.140,
    PANIC_CD_DASH            = 0.220,
    PANIC_HOLD_RADIUS        = 0.150,
    PANIC_HOLD_TARGET        = 0.140,
    PANIC_HOLD_DASH          = 0.220,

    PARRY_BUFFER_MS          = 0.200,

    CLASH_REACTIVATE_CD      = 0.120,
    PANIC_HOLD_MS            = 0.100,
}

-- estado
local RING_BUF = 8

local S = {
    lastTarget      = -999,
    lastTargetAt    = 0,
    targetRing      = table.create(RING_BUF, 0),
    targetRingIdx   = 0,
    targetCps       = 0,
    targetHoldOffAt = 0,

    clashOn         = false,
    clashAt         = 0,
    clashHoldUntil  = 0,
    clashOffAt      = 0,
    lastClashReact  = 0,
    lastClashOffAt  = 0,

    lastFireAt      = 0,
    teleportLockUntil = 0,

    burstState          = "IDLE",
    burstOnStart        = 0,
    burstOffStart       = 0,
    burstSignalDuringOn = false,

    detPhase        = "IDLE",
    detEnterAt      = 0,
    detEntryTime    = 0,
    detExitAt       = 0,
    detDotEma       = 0,
    detWasInside    = false,
    detSignal       = false,

    maintEma        = 0,

    dashEvents      = {},
    dashPanicUntil  = 0,

    dashAnti        = { untilT = 0, src = nil, at = 0 },

    lastFlowAt      = 0,
    panicHoldUntil  = 0,

    panicLastFire   = {
        RADIUS = 0,
        TARGET = 0,
        DASH   = 0,
    },
}

local _localUserId = -1
local _antidashCooldown, _antidashHooked = {}, {}
local _lastDashTrack, _lastFullPlayerScan = 0, 0
local _ctxCache = { t = 0, valid = false }
local CLASH_SNAPSHOT_TTL = 0.05

-- helpers
local function ringPush(t)
    S.targetRingIdx = (S.targetRingIdx % RING_BUF) + 1
    S.targetRing[S.targetRingIdx] = t
end

local function updateTargetCps(t)
    local winStart = t - CLASH.CPS_WIN
    local cnt = 0
    for i = 1, RING_BUF do
        local ts = S.targetRing[i]
        if ts and ts >= winStart and ts >= t - CLASH.RING_FRESH_MAX then
            cnt = cnt + 1
        end
    end
    S.targetCps = cnt / CLASH.CPS_WIN
end

local function isTargeted()
    return GameInfo.isTargeted(S.lastTarget)
end

local function getLocalHumanoid()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    if not (ch and ch.Parent) then return nil end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not (hum and hum.Parent and hum.Health > 0) then return nil end
    return hum
end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function getParryBonus()
    return AutoParry.resRadiusBonus()
end

local function effectiveRadius(spd)
    return P.DEFLECT_R + getParryBonus()
end

local function maintenanceRadius(spd)
    return effectiveRadius(spd) + (spd or 0) * CLASH.PARRY_BUFFER_MS
end

local function getBall()
    return GameInfo.getBall()
end

-- burst
local function activateBurst(t, config)
    S.burstState          = "ON"
    S.burstOnStart        = t
    S.burstSignalDuringOn = false
    S.clashOn             = true
    S.clashAt             = t
    S.clashHoldUntil      = t + CLASH.BURST_ON_MS
    S.lastClashReact      = t
    S.clashOffAt          = 0
    -- Callback para o init.luau, se necessário
    -- if Utils.onBurst then Utils.onBurst end
end

local function clearClash()
    local t = Utils.now()
    S.clashOn, S.clashHoldUntil = false, 0
    S.clashOffAt = t
    S.lastClashOffAt = t
    S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
    S.maintEma = 0
end

-- detector de retorno
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
        if (isInside and not S.detWasInside) or dotComing then
            if limiar > 0 and (t - S.detExitAt) <= limiar and dotComing then
                S.detSignal = true
            end
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end
    end
    S.detWasInside = isInside
    if S.detSignal then S.lastFlowAt = t end
end

-- snapshot
local function clashSnapshot()
    local t = Utils.now()
    if _ctxCache.valid and (t - _ctxCache.t) < CLASH_SNAPSHOT_TTL then
        return _ctxCache
    end
    local hr = getMyHRP()
    if not (hr and hr.Parent) then
        _ctxCache.valid = false
        return nil
    end
    updateTargetCps(t)
    local ball = getBall()
    if not (ball and ball.Parent) then
        _ctxCache.valid = false
        return nil
    end
    local nearest, nearestAlive = GameInfo.nearestPlayerAlive()
    local bp = ball.Position
    local bDist = (hr.Position - bp).Magnitude
    local panic = nearestAlive and (nearest <= 9 and bDist <= 13)
    local tImp, spd = 0, 0
    local live = GameInfo.liveTImp()
    if live then
        tImp, spd = live.tImp or 0, live.spd or 0
    end
    if spd < 1 then
        local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
        tImp, spd = ti, s2
    end
    local rad      = effectiveRadius(spd)
    local maintRad = maintenanceRadius(spd)
    local panicR   = rad * 0.5
    _ctxCache.t, _ctxCache.valid = t, true
    _ctxCache.hr = hr
    _ctxCache.ball, _ctxCache.bp = ball, bp
    _ctxCache.nearest, _ctxCache.nearestAlive = nearest, nearestAlive
    _ctxCache.bDist, _ctxCache.panic = bDist, panic
    _ctxCache.tImp, _ctxCache.spd = tImp, spd
    _ctxCache.rad      = rad
    _ctxCache.maintRad = maintRad
    _ctxCache.panicR   = panicR
    _ctxCache.targeted = isTargeted()
    return _ctxCache
end

-- panics
local function checkPanicRadius(t, ctx)
    if not (ctx and ctx.valid) then return false end
    if not ctx.targeted then return false end
    if ctx.bDist > ctx.panicR then return false end
    if (t - S.panicLastFire.RADIUS) < CLASH.PANIC_CD_RADIUS then return false end
    S.panicLastFire.RADIUS = t
    S.panicHoldUntil = math.max(S.panicHoldUntil or 0, t + CLASH.PANIC_HOLD_RADIUS)
    return true
end

local function checkPanicTarget(t, ctx, justBecameTarget)
    if not (ctx and ctx.valid) then return false end
    if not justBecameTarget then return false end
    if not ctx.targeted then return false end
    if ctx.bDist > ctx.rad then return false end
    if (t - S.panicLastFire.TARGET) < CLASH.PANIC_CD_TARGET then return false end
    S.panicLastFire.TARGET = t
    S.panicHoldUntil = math.max(S.panicHoldUntil or 0, t + CLASH.PANIC_HOLD_TARGET)
    return true
end

local function checkPanicDash(t, ctx, sourceUserId)
    if not (ctx and ctx.valid) then return false end
    if not sourceUserId then return false end
    local imTarget     = ctx.targeted
    local sourceTarget = (sourceUserId == S.lastTarget)
    if not (imTarget or sourceTarget) then return false end
    if (t - S.panicLastFire.DASH) < CLASH.PANIC_CD_DASH then return false end
    S.panicLastFire.DASH = t
    S.panicHoldUntil = math.max(S.panicHoldUntil or 0, t + CLASH.PANIC_HOLD_DASH)
    return true
end

-- manutenção
local function updateMaintEma(t, hr, ball, ctx)
    local input = 0
    if ctx and ctx.valid and hr and hr.Parent and ball and ball.Parent then
        local within = ctx.bDist <= ctx.maintRad
        local flowOk = (t - S.lastFlowAt) < CLASH.FLOW_PROTECT_MS
        if within or flowOk then
            input = 1
        end
    end
    if input >= S.maintEma then
        S.maintEma = S.maintEma + (input - S.maintEma) * CLASH.MAINT_EMA_UP
    else
        S.maintEma = S.maintEma + (input - S.maintEma) * CLASH.MAINT_EMA_DOWN
    end
end

local function maintStep(t, ctx)
    if not (ctx and ctx.valid) then return "DEACT" end

    updateMaintEma(t, ctx.hr, ctx.ball, ctx)

    if S.maintEma < CLASH.MAINT_FLOOR then
        return "DEACT"
    end

    if ctx.bDist > ctx.maintRad then
        return "DEACT"
    end

    if S.detSignal then
        return "REFRESH"
    end

    return "HOLD"
end

-- desativação
local function shouldDeactivateClash(t, ctx)
    if not S.clashOn then return false end
    if t < math.max(S.clashAt + CLASH.HOLD, S.clashHoldUntil) then return false end
    if (t - S.clashAt) > CLASH.MAX_HOLD then return true end
    if t < S.teleportLockUntil then return true end
    local hum = getLocalHumanoid()
    if not hum then return true end
    if not (ctx and ctx.valid) then return true end

    -- Usar um valor razoável para a distância máxima da bola, não uma constante mágica
    local MAX_BALL_DIST_TO_DEACTIVATE = 50
    if ctx.bDist > MAX_BALL_DIST_TO_DEACTIVATE then return true end

    local deactRad = math.clamp(P.DEFLECT_R + 14, 18, 30)
    if ctx.bDist > deactRad then return true end

    -- tImp cap deve ser calculado com base na velocidade, não um valor fixo
    local tImpCap = ctx.spd > 0 and ((CLASH.T_IMP_CAP_BASE * 60) / math.max(ctx.spd, 1)) or CLASH.T_IMP_CAP_FLOOR
    if ctx.tImp > tImpCap then return true end

    if S.detPhase == "EXITED" then
        local returnWindow = math.max(
            (S.detEntryTime or 0) * CLASH.DEACT_RETURN_FACTOR,
            CLASH.DEACT_RETURN_FLOOR
        )
        if (t - S.detExitAt) > returnWindow then
            if isTargeted() then
                if S.targetHoldOffAt == 0 then S.targetHoldOffAt = t end
                if (t - S.targetHoldOffAt) < CLASH.DEACT_HOLD_OFF_MS then
                    return false
                end
            else
                S.targetHoldOffAt = 0
            end
            return true
        end
    end
    return false
end

-- alvo
local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    local previousTarget = S.lastTarget
    S.lastTarget = newTarget
    S.lastTargetAt = t
    ringPush(t)
    local apState = AutoParry.getState()
    if apState then apState.armed = (newTarget == _localUserId) end

    local config = Utils.getConfig()
    local targeted = (newTarget == _localUserId)
    if not (targeted and config and config.AutoClash ~= false and not Utils.isManualSpamActive()) then return end

    if previousTarget == _localUserId then return end

    local justBecameTarget = true
    local ctx = clashSnapshot()
    if checkPanicTarget(t, ctx, justBecameTarget) then
        activateBurst(t, config)
        S.clashHoldUntil = t + CLASH.PANIC_HOLD_TARGET
    end
end

-- avaliação
local function evaluateClash(t, hr, ball, config)
    if not config or config.AutoClash == false or Utils.isManualSpamActive() then
        if S.clashOn then clearClash() end
        S.burstState, S.burstSignalDuringOn = "IDLE", false
        return
    end

    tickReturnDetector(t, hr, ball)

    if S.lastClashOffAt > 0 and (t - S.lastClashOffAt) < CLASH.CLASH_REACTIVATE_CD then
        if S.clashOn and shouldDeactivateClash(t, clashSnapshot()) then
            clearClash()
            S.burstState, S.burstSignalDuringOn = "IDLE", false
        end
        return
    end

    local ctx = clashSnapshot()

    if S.clashOn then
        if shouldDeactivateClash(t, ctx) then
            clearClash()
            S.burstState, S.burstSignalDuringOn = "IDLE", false
            return
        end

        local step = maintStep(t, ctx)
        if step == "DEACT" then
            clearClash()
            S.burstState, S.burstSignalDuringOn = "IDLE", false
            return
        elseif step == "REFRESH" then
            S.burstOnStart        = t
            S.burstSignalDuringOn = false
            S.clashHoldUntil      = t + CLASH.BURST_ON_MS
            S.burstState          = "ON"
            S.lastClashReact      = t
            S.lastFlowAt          = t
            return
        else
            if S.burstState == "ON" and S.detSignal then S.burstSignalDuringOn = true end
            if S.burstState == "ON" and (t - S.burstOnStart) >= CLASH.BURST_ON_MS then
                if S.burstSignalDuringOn then
                    S.burstOnStart        = t
                    S.burstSignalDuringOn = false
                    S.clashHoldUntil      = t + CLASH.BURST_ON_MS
                else
                    S.burstState, S.burstOffStart = "OFF", t
                end
            elseif S.burstState == "OFF" then
                if (t - S.burstOffStart) >= CLASH.BURST_OFF_MS then
                    S.burstState = "IDLE"
                end
            end
            return
        end
    end

    local antiDashActive = S.dashAnti.untilT > t

    if checkPanicRadius(t, ctx) then
        activateBurst(t, config)
        S.clashHoldUntil = t + CLASH.PANIC_HOLD_RADIUS
        S.lastClashReact = t
        return
    end

    if antiDashActive and checkPanicDash(t, ctx, S.dashAnti.src and S.dashAnti.src.UserId) then
        activateBurst(t, config)
        S.clashHoldUntil = t + CLASH.PANIC_HOLD_DASH
        S.lastClashReact = t
        return
    end

    if S.panicHoldUntil and t < S.panicHoldUntil then
        if ctx and ctx.valid and ctx.targeted and ctx.bDist <= ctx.rad then
            activateBurst(t, config)
            S.clashHoldUntil = t + CLASH.PANIC_HOLD_TARGET
            S.lastClashReact = t
            return
        end
    end

    if S.detSignal and isTargeted() then
        activateBurst(t, config)
        S.clashHoldUntil = t + CLASH.BURST_ON_MS
        S.lastClashReact = t
        return
    end
end

-- fast-path inline
local function tryInlineActivate(t, hr, ball, config)
    if S.clashOn then return end
    if not config or config.AutoClash == false or Utils.isManualSpamActive() then return end
    if (t - S.lastClashReact) < CLASH.REACT_CD then return end
    if S.burstState ~= "IDLE" then return end
    if not (hr and hr.Parent and ball and ball.Parent) then return end
    local bp = ball.Position
    local bDist = (hr.Position - bp).Magnitude
    if bDist > CLASH.BALL_HARD_CAP then return end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3") then return end
    local speed = av.Magnitude
    local impactTime = speed > 1 and (bDist / speed) or math.huge
    if bDist <= CLASH.BALL_HARD_CAP and impactTime <= CLASH.OFF_FAST then
        activateBurst(t, config)
        S.clashHoldUntil = t + CLASH.HOLD
        S.lastClashReact = t
    end
end

-- rastreamento de dash
local function updateDashTrack(t)
    if (t - _lastDashTrack) < CLASH.DASH_TRACK_INTERVAL then return end
    _lastDashTrack = t
    local lp = Utils.getLocalPlayer()
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (myHRP and myHRP.Parent) then
        table.clear(S.dashEvents)
        return
    end
    local myPos = myHRP.Position
    local fullScan = (t - _lastFullPlayerScan) >= CLASH.FULL_PLAYER_SCAN_INTERVAL
    local playersToCheck = {}
    local PlayersService = Utils.getPlayers()
    if fullScan then
        _lastFullPlayerScan = t
        for _, p in PlayersService:GetPlayers() do
            if p ~= lp then table.insert(playersToCheck, p) end
        end
    else
        local seen = {}
        for _, p in PlayersService:GetPlayers() do
            if p == lp then continue end
            seen[p.UserId] = true
            if S.dashEvents[p.UserId] then
                table.insert(playersToCheck, p)
            else
                local ch = p.Character
                local php = ch and ch:FindFirstChild("HumanoidRootPart")
                if php and php.Parent and (myPos - php.Position).Magnitude <= CLASH.PLAYER_SCAN_RADIUS then
                    table.insert(playersToCheck, p)
                end
            end
        end
        for uid in pairs(S.dashEvents) do
            if not seen[uid] then
                local p = PlayersService:GetPlayerByUserId(uid)
                if p then table.insert(playersToCheck, p) end
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
        if not alive then
            S.dashEvents[p.UserId] = nil
            continue
        end
        local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
        if not (ok and typeof(av) == "Vector3") then
            S.dashEvents[p.UserId] = nil
            continue
        end
        local spd = av.Magnitude
        local ev = S.dashEvents[p.UserId]
        if spd >= CLASH.DASH_SPD_THRESH then
            local dir = spd > 0.1 and av.Unit or nil
            if not ev then
                S.dashEvents[p.UserId] = { spd = spd, dir = dir, at = t, startedAt = t, confirmed = false }
            else
                ev.spd, ev.dir, ev.at = spd, dir, t
                if not ev.confirmed and spd >= CLASH.DASH_SPD_CONFIRM then
                    ev.confirmed, ev.startedAt = true, t
                end
            end
        elseif ev and ev.confirmed and spd >= CLASH.DASH_SPD_RELEASE then
            ev.spd, ev.at = spd, t
        else
            S.dashEvents[p.UserId] = nil
        end
    end
    for uid in pairs(S.dashEvents) do
        if not processed[uid] then S.dashEvents[uid] = nil end
    end
    for uid, ev in pairs(S.dashEvents) do
        if not (ev and ev.confirmed and ev.dir and ev.spd) then continue end
        local dur = ev.at - ev.startedAt
        if dur > CLASH.DASH_DUR_MAX then
            S.dashEvents[uid] = nil
            continue
        end
        local pl = PlayersService:GetPlayerByUserId(uid)
        local php = pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
        if not (php and php.Parent) then
            S.dashEvents[uid] = nil
        elseif dur >= CLASH.DASH_DUR_MIN then
            local toMe = myPos - php.Position
            local dist = toMe.Magnitude
            if dist > 0.1 and dist <= CLASH.DASH_PANIC_DIST then
                local dot = ev.dir:Dot(toMe.Unit)
                if dot >= CLASH.DASH_PANIC_DOT and ev.spd >= CLASH.DASH_SPD_CONFIRM then
                    S.dashPanicUntil = math.max(S.dashPanicUntil, t + CLASH.DASH_PANIC_WINDOW)
                    local src = PlayersService:GetPlayerByUserId(uid)
                    if src then
                        S.dashAnti.src    = src
                        S.dashAnti.untilT = math.max(S.dashAnti.untilT, t + CLASH.ANTIDASH_PANIC_HOLD)
                    end
                end
            end
        end
    end
end

-- anti-dash
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
    local rad = math.clamp(
        P.DEFLECT_R + getParryBonus() + (P.ANTIDASH_BONUS or 0),
        CLASH.ANTIDASH_RAD_MIN,
        CLASH.ANTIDASH_RAD_MAX
    )
    local toMe = myHRP.Position - php.Position
    local dist = toMe.Magnitude
    if dist > rad or dist < 0.1 then return end
    local dot = 1
    local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
    if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
        dot = av.Unit:Dot(toMe.Unit)
    end
    if dot < CLASH.ANTIDASH_DOT_MIN then return end
    local untilT = math.min(t + CLASH.ANTIDASH_PANIC_MAX, t + CLASH.ANTIDASH_PANIC_HOLD)
    S.dashAnti.untilT = math.max(S.dashAnti.untilT, untilT)
    S.dashAnti.src    = player
end

local function isDashAnimation(track)
    if not track or not track.Animation then return false end
    local n  = (track.Name or ""):lower()
    local an = track.Animation.Name:lower()
    return n:find("dash", 1, true) or an:find("dash", 1, true) ~= nil
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

-- setup
function AutoClash.setup(deps)
    Probe = deps.Probe
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry
    local lp = Utils.getLocalPlayer()
    _localUserId = lp and lp.UserId or -1
    -- Callbacks para Utils
    Utils.setOnClashOn(function() return S.clashOn end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(clearClash)
end

-- api pública
function AutoClash.evaluate(t, hr, ball, config)
    evaluateClash(t, hr, ball, config)
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
    S.lastClashOffAt = 0
    S.targetRingIdx, S.targetCps = 0, 0
    S.lastTargetAt, S.lastFireAt, S.teleportLockUntil = 0, 0, 0
    for i = 1, RING_BUF do S.targetRing[i] = 0 end
    table.clear(S.dashEvents)
    S.dashPanicUntil = 0
    S.detPhase, S.detEnterAt, S.detEntryTime, S.detExitAt = "IDLE", 0, 0, 0
    S.detDotEma, S.detWasInside, S.detSignal = 0, false, false
    S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
    S.dashAnti = { untilT = 0, src = nil, at = 0 }
    S.panicHoldUntil = 0
    S.lastFlowAt = 0
    S.targetHoldOffAt = 0
    S.maintEma = 0
    S.panicLastFire = { RADIUS = 0, TARGET = 0, DASH = 0 }
    _ctxCache.valid = false
end

function AutoClash.tryInlineActivate(t, hr, ball, config)
    tryInlineActivate(t, hr, ball, config)
end

function AutoClash.setTeleportLock(t)
    S.teleportLockUntil = t + 0.20
end

function AutoClash.getLastTargetAt()
    return S.lastTargetAt
end

function AutoClash.getTeleportLock()
    return S.teleportLockUntil
end

function AutoClash.getClashOffAt()
    return S.clashOffAt
end

function AutoClash.getLastFireAt()
    return S.lastFireAt
end

function AutoClash.recordFire(t)
    S.lastFireAt = t
end

return AutoClash