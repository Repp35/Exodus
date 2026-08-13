-- [[ auto clash ]]

local AutoClash = {}

local GameInfo, Utils, AutoParry


-- tuning
local C = {
    MAX_HOLD             = 1.4,


    MAINT_HOLD_MIN       = 0.060,   
    MAINT_BALL_RADIUS    = 25,      
    MAINT_TIMP_MAX       = 0.30,    
    MAINT_PARRY_KEEP     = 0.10,    
    MAINT_TARGET_KEEP    = 0.15,    
    MAINT_BALL_GONE_DIST = 60,      
    MAINT_DEAD_DIST      = 80,      


    DEACT_TIMP_EMA       = 0.10,    
    DEACT_SUSTAIN        = 0.08,    
    DEACT_MARGIN         = 0.05,    
    DEACT_HARD_GONE_T    = 0.20,    


    ACT_HARD_CAP         = 22,      
    ACT_TIMP_FAST        = 0.085,


    INV_DIST_CAP         = 25,
    INV_APPROACH_SPD_MIN = 50,


    DET_RAD_MIN = 14, DET_RAD_MAX = 32, DET_RAD_SPD_REF = 120,
    DET_DOT_EMA = 0.25, DET_DOT_THRESH = 0.15,
    DET_RETURN_FACTOR = 2.2, DET_TIMEOUT = 1.1,
    DET_REQUIRE_INSIDE = true,      


    ANTIDASH_RAD_MIN    = 20, ANTIDASH_RAD_MAX = 32,
    ANTIDASH_DOT_MIN    = 0.35,     
    ANTIDASH_PANIC_HOLD = 0.45,
    ANTIDASH_PANIC_MAX  = 1.2,
    ANTIDASH_COOLDOWN   = 0.35,


    DASH_SPD_THRESH   = 50, DASH_SPD_CONFIRM = 62,
    DASH_DUR_MIN      = 0.08, DASH_DUR_MAX = 0.5,
    DASH_PANIC_DOT    = 0.85, DASH_PANIC_DIST = 14,
    DASH_PANIC_WINDOW = 0.300,
    DASH_TRACK_INTERVAL = 0.2, PLAYER_SCAN_RADIUS = 100,


    CPS_WIN = 1.0, RING_FRESH_MAX = 0.6,
}
local RING_BUF = 8


-- state
local S = {
    lastTarget = -999, lastTargetAt = 0,
    targetRing = table.create(RING_BUF, 0), targetRingIdx = 0, targetCps = 0,


    clashOn = false, clashAt = 0,
    tImpEma        = 0,
    tImpHighSince  = 0,
    ballGoneSince  = 0,


    detDotEma = 0, detSignal = false,


    dashEvents = {}, dashPanicUntil = 0,
    dashAnti = { untilT = 0 },
}

local _localUserId = -1
local _antidashCooldown, _antidashHooked, _lastDashTrack = {}, {}, 0
local _ctxCache = { t = 0, valid = false }
local SNAPSHOT_TTL = 0.05


local function getP()
    return AutoParry and AutoParry.getP and AutoParry.getP() or nil
end

local function parryBonus()
    if AutoParry and AutoParry.resRadiusBonus then return AutoParry.resRadiusBonus() end
    return 0
end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted()
    return GameInfo.isTargeted(S.lastTarget)
end

local function recentlyTargeted(t)
    return (t - S.lastTargetAt) < C.MAINT_TARGET_KEEP
end


local function maintTimpMax(spd)
    if spd < 1 then return C.MAINT_TIMP_MAX end
    local s = math.clamp(60 / spd, 0.2, 2.5)
    return math.clamp(C.MAINT_TIMP_MAX * s, 0.06, 0.40)
end

local function deactTimpMax(spd)
    if spd < 1 then return C.MAINT_TIMP_MAX end
    local s = math.clamp(60 / spd, 0.2, 2.5)
    return math.clamp(C.MAINT_TIMP_MAX * s, 0.08, 0.40)
end


local function ballApproachDot(ball, hr)
    if not (ball and ball.Parent and hr and hr.Parent) then return 0 end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return 0 end
    local toMe = hr.Position - ball.Position
    if toMe.Magnitude < 1 then return 1 end
    return av:Dot(toMe.Unit)
end


local function invisibleGate(ctx, hr)
    if not (ctx and ctx.targeted) then return false end
    if ctx.bDist > C.INV_DIST_CAP then return false end
    if ctx.spd < C.INV_APPROACH_SPD_MIN then return false end

    if hr and hr.Parent and ctx.ball and ctx.ball.Parent then
        local d = ballApproachDot(ctx.ball, hr)
        if d < C.ANTIDASH_DOT_MIN then return false end
    end
    return true
end


local function ringPush(t)
    S.targetRingIdx = (S.targetRingIdx % RING_BUF) + 1
    S.targetRing[S.targetRingIdx] = t
end

local function updateTargetCps(t)
    local winStart, fresh = t - C.CPS_WIN, t - C.RING_FRESH_MAX
    local cnt = 0
    for i = 1, RING_BUF do
        local ts = S.targetRing[i]
        if ts > winStart and ts > fresh then cnt = cnt + 1 end
    end
    S.targetCps = cnt / C.CPS_WIN
end


-- snapshot
local function clashSnapshot()
    local t = Utils.now()
    if _ctxCache.valid and (t - _ctxCache.t) < SNAPSHOT_TTL
        and _ctxCache.hr and _ctxCache.hr.Parent
        and _ctxCache.ball and _ctxCache.ball.Parent then
        return _ctxCache
    end
    local hr = getMyHRP()
    if not hr then
        _ctxCache.valid = false
        return nil
    end
    local ball = GameInfo.getBall()
    if not (ball and ball.Parent) then
        _ctxCache.valid = false
        return nil
    end

    updateTargetCps(t)
    local tImp, spd = math.huge, 0
    local live = GameInfo.liveTImp()
    if live then
        tImp = tonumber(live.tImp) or math.huge
        spd  = tonumber(live.spd) or 0
    end
    if spd < 1 then
        local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
        tImp = ti or tImp
        spd  = s2 or spd
    end
    _ctxCache.t = t
    _ctxCache.valid = true
    _ctxCache.hr = hr
    _ctxCache.ball = ball
    _ctxCache.tImp = tImp
    _ctxCache.spd = spd
    _ctxCache.bDist = (hr.Position - ball.Position).Magnitude
    _ctxCache.targeted = isTargeted()
    return _ctxCache
end






local function getDetectorRadius(spd)
    local k = math.clamp((spd or 0) / C.DET_RAD_SPD_REF, 0, 1)
    return C.DET_RAD_MIN + (C.DET_RAD_MAX - C.DET_RAD_MIN) * k
end

local function tickReturnDetector(t, hr, ball)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        S.detDotEma = 0
        return
    end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return end
    local spd, toMe = av.Magnitude, hr.Position - ball.Position
    local dist = toMe.Magnitude
    if dist < 0.001 then return end
    local dotRaw = av:Dot(toMe.Unit)
    local radius = getDetectorRadius(spd)

    -- EMA só acumula dentro do alcance (com folga 1.2x); fora zera.
    if dist <= radius * 1.2 then
        S.detDotEma = S.detDotEma * (1 - C.DET_DOT_EMA) + dotRaw * C.DET_DOT_EMA
    else
        S.detDotEma = 0
    end

    -- Sem fases. Dentro do raio + EMA do dot acima do thresh → sinaliza.
    if C.DET_REQUIRE_INSIDE then
        if dist <= radius and S.detDotEma > C.DET_DOT_THRESH then
            S.detSignal = true
        end
    else
        if S.detDotEma > C.DET_DOT_THRESH then
            S.detSignal = true
        end
    end
end


local function clearClash()
    S.clashOn, S.clashAt = false, 0
    S.tImpEma, S.tImpHighSince = 0, 0
    S.ballGoneSince = 0
    S._deactLastT = nil
    _ctxCache.valid = false
end

local function activateClash(t)
    S.clashOn       = true
    S.clashAt       = t
    S.tImpEma       = 0
    S.tImpHighSince = 0
    S.ballGoneSince = 0
    S._deactLastT   = t
    _ctxCache.valid = false
end








local function shouldMaintain(t, ctx)
    if t < S.clashAt + C.MAINT_HOLD_MIN then return true end
    if not ctx then return false end
    if ctx.bDist > C.MAINT_BALL_GONE_DIST then return false end


    if ctx.bDist <= C.MAINT_BALL_RADIUS then return true end


    local spd = ctx.spd or 0
    if ctx.tImp > 0 and ctx.tImp <= maintTimpMax(spd) then return true end


    if ctx.targeted or recentlyTargeted(t) then return true end


    local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
    if ap and ap.firedAt and (t - ap.firedAt) < C.MAINT_PARRY_KEEP then return true end

    return false
end






local function shouldDeactivate(t, ctx, hr)
    if not ctx then return false end


    if ctx.bDist > C.MAINT_DEAD_DIST then
        if S.ballGoneSince == 0 then S.ballGoneSince = t end
        if (t - S.ballGoneSince) >= C.DEACT_HARD_GONE_T then return true end
    else
        S.ballGoneSince = 0
    end

    local spd = ctx.spd or 0
    if spd < 1 then return false end


    local raw = ctx.tImp
    if type(raw) ~= "number" or raw ~= raw then raw = deactTimpMax(spd) end
    if raw == math.huge then raw = deactTimpMax(spd) * 2 end
    if raw < 0 then raw = 0 end

    local thresh  = deactTimpMax(spd)
    local threshH = thresh + C.DEACT_MARGIN


    if raw < thresh then
        S.tImpHighSince = 0
        return false
    end


    local dt = math.max(t - (S._deactLastT or t), 0)
    S._deactLastT = t
    local alpha = 1 - math.exp(-dt / C.DEACT_TIMP_EMA)
    S.tImpEma = S.tImpEma * (1 - alpha) + raw * alpha


    if S.tImpEma > threshH and raw > threshH then
        if S.tImpHighSince == 0 then S.tImpHighSince = t end
        if (t - S.tImpHighSince) >= C.DEACT_SUSTAIN then
            return true
        end
    else
        S.tImpHighSince = 0
    end

    return false
end








local function shouldActivate(t, ctx, hr, targetJustChangedToMe)
    local targeted = ctx and ctx.targeted or isTargeted()
    if not targeted then

        if S.dashAnti.untilT > t then return true end
        if S.dashPanicUntil > t then return true end
        return false
    end


    if targetJustChangedToMe and ctx then
        if ctx.bDist <= C.ACT_HARD_CAP and ctx.tImp > 0 and ctx.tImp <= C.ACT_TIMP_FAST then
            return true
        end
    end

    if S.detSignal then return true end

    if S.dashAnti.untilT > t then return true end
    if S.dashPanicUntil > t then return true end

    if invisibleGate(ctx, hr) then return true end

    return false
end


local function evaluateClash(t, hr, ball, config, targetJustChangedToMe)
    if not config or config.AutoClash == false or _G.PhantomManual then
        if S.clashOn then clearClash() end
        return
    end

    tickReturnDetector(t, hr, ball)
    local ctx = clashSnapshot()

    if S.clashOn then
        if (t - S.clashAt) > C.MAX_HOLD
            or (not shouldMaintain(t, ctx) and shouldDeactivate(t, ctx, hr)) then
            clearClash()
        end
        return
    end


    if shouldActivate(t, ctx, hr, targetJustChangedToMe) then
        activateClash(t)
    end
end


local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    S.lastTarget, S.lastTargetAt = newTarget, t
    ringPush(t)
    local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == _localUserId) end
    _ctxCache.valid = false
end


local function updateDashTrack(t)
    if (t - _lastDashTrack) < C.DASH_TRACK_INTERVAL then return end
    _lastDashTrack = t
    local lp = Utils.getLocalPlayer()
    local char = lp and lp.Character
    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP then
        table.clear(S.dashEvents)
        return
    end
    local myPos = myHRP.Position
    local Players = Utils.getPlayers()

    for _, p in ipairs(Players:GetPlayers()) do
        if p == lp then continue end
        local pChar = p.Character
        if not pChar then
            S.dashEvents[p.UserId] = nil
            continue
        end
        local php = pChar:FindFirstChild("HumanoidRootPart")
        if not php then
            S.dashEvents[p.UserId] = nil
            continue
        end
        if (myPos - php.Position).Magnitude > C.PLAYER_SCAN_RADIUS
            and not S.dashEvents[p.UserId] then continue end
        local hum = pChar:FindFirstChildOfClass("Humanoid")
        if not (hum and hum.Health > 0) then
            S.dashEvents[p.UserId] = nil
            continue
        end

        local spd = php.AssemblyLinearVelocity.Magnitude
        local ev  = S.dashEvents[p.UserId]
        if spd >= C.DASH_SPD_THRESH then
            local dir = php.AssemblyLinearVelocity.Unit
            if not ev then
                S.dashEvents[p.UserId] = { spd=spd, dir=dir, at=t, startedAt=t, confirmed=false }
            else
                ev.spd, ev.dir, ev.at = spd, dir, t
                if not ev.confirmed and spd >= C.DASH_SPD_CONFIRM then
                    ev.confirmed, ev.startedAt = true, t
                end
            end
        else
            S.dashEvents[p.UserId] = nil
        end
    end

    for uid, ev in pairs(S.dashEvents) do
        local p = Players:GetPlayerByUserId(uid)
        if not p or not ev.confirmed or not ev.dir then
            S.dashEvents[uid] = nil
            continue
        end
        local dur = t - ev.startedAt
        if dur > C.DASH_DUR_MAX then
            S.dashEvents[uid] = nil
            continue
        end
        if dur < C.DASH_DUR_MIN then continue end
        local php = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if not php then continue end
        local toMe = myPos - php.Position
        if toMe.Magnitude > C.DASH_PANIC_DIST then continue end
        if ev.dir:Dot(toMe.Unit) < C.DASH_PANIC_DOT then continue end
        if ev.spd < C.DASH_SPD_CONFIRM then continue end
        S.dashPanicUntil = math.max(S.dashPanicUntil, t + C.DASH_PANIC_WINDOW)
        S.dashAnti.untilT = math.max(S.dashAnti.untilT, t + C.ANTIDASH_PANIC_HOLD)
    end
end


local function reportDash(player)
    if not player or not Utils then return end
    local lp = Utils.getLocalPlayer()
    if player == lp or not Utils.isActive() then return end
    local t = Utils.now()
    if _antidashCooldown[player.UserId]
        and (t - _antidashCooldown[player.UserId]) < C.ANTIDASH_COOLDOWN then return end
    local php  = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local myHRP = getMyHRP()
    if not (php and php.Parent and myHRP and myHRP.Parent) then return end
    local p = getP()
    if not p then return end
    local rad = math.clamp((p.DEFLECT_R or 0) + parryBonus(), C.ANTIDASH_RAD_MIN, C.ANTIDASH_RAD_MAX)
    local toMe = myHRP.Position - php.Position
    local dist = toMe.Magnitude
    if dist > rad or dist < 0.1 then return end
    local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return end

    local dot = av.Unit:Dot(toMe.Unit)
    if dot < C.ANTIDASH_DOT_MIN then return end
    _antidashCooldown[player.UserId] = t
    local untilT = math.min(
        math.max(S.dashAnti.untilT, t) + C.ANTIDASH_PANIC_HOLD,
        t + C.ANTIDASH_PANIC_MAX
    )
    S.dashAnti.untilT = untilT
end

local function isDashTrack(track)
    if not track or not track.Animation then return false end
    local n  = (track.Name or ""):lower()
    local an = (track.Animation.Name or ""):lower()
    return n:find("dash", 1, true) ~= nil or an:find("dash", 1, true) ~= nil
end

local function hookPlayer(player)
    if not player or player == Utils.getLocalPlayer() then return end
    if _antidashHooked[player] then return end
    _antidashHooked[player] = true
    -- FIX: rastreia conexões por character pra desconectar no próximo respawn
    local charConns = {}
    local function attach(char)
        if not char then return end
        -- limpa conexões do character anterior (evita duplicação em respawn)
        for i = #charConns, 1, -1 do
            local c = charConns[i]
            charConns[i] = nil
            if c and type(c.Disconnect) == "function" then
                pcall(function() c:Disconnect() end)
            end
        end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        local anim = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
        if not anim then return end
        for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
            if isDashTrack(tr) then
                reportDash(player)
                break
            end
        end
        local animConn = anim.AnimationPlayed:Connect(function(tr)
            if isDashTrack(tr) then reportDash(player) end
        end)
        charConns[#charConns + 1] = animConn
        Utils.track(animConn)
    end
    if player.Character then attach(player.Character) end
    Utils.track(player.CharacterAdded:Connect(attach))
end

-- anti dash
local function installAntiDashHooks()
    local Players = Utils.getPlayers()
    for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
    Utils.track(Players.PlayerAdded:Connect(hookPlayer))
    Utils.track(Players.PlayerRemoving:Connect(function(p)
        _antidashHooked[p] = nil
        _antidashCooldown[p.UserId] = nil
        S.dashEvents[p.UserId] = nil
    end))
end


-- ball sync handler
local function onBallSync(data)
    if typeof(data) ~= "table" then return end
    local t = Utils and Utils.now() or os.clock()
    if data.Teleported == true then
        clearClash()
        _ctxCache.valid = false
        return
    end
    if type(data.TargetPlayerID) == "number" then
        local newTarget = data.TargetPlayerID
        if newTarget ~= S.lastTarget then
            S.lastTarget, S.lastTargetAt = newTarget, t
            ringPush(t)
            local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
            if ap then ap.armed = (newTarget == _localUserId) end
        end
    end
    _ctxCache.valid = false
end

-- public
function AutoClash.setup(deps)
    GameInfo, Utils, AutoParry = deps.GameInfo, deps.Utils, deps.AutoParry
    local localPlayer = Utils.getLocalPlayer()
    _localUserId = localPlayer and localPlayer.UserId or -1
    Utils.setOnClashOn(function() return S.clashOn end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(clearClash)
end

function AutoClash.evaluate(t, hr, ball, config, targetJustChangedToMe)
    evaluateClash(t, hr, ball, config, targetJustChangedToMe)
end
function AutoClash.onBallSync(data)                       onBallSync(data) end
function AutoClash.updateDashTrack(t)                     updateDashTrack(t) end
function AutoClash.installAntiDashHooks()                 installAntiDashHooks() end
function AutoClash.getState()                             return S end
function AutoClash.clashOn()                              return S.clashOn end
function AutoClash.getClashAt()                           return S.clashAt end
function AutoClash.snapshot()                             return clashSnapshot() end
function AutoClash.invalidateSnapshot()                   _ctxCache.valid = false end

function AutoClash.resetState()
    S.clashOn, S.clashAt = false, 0
    S.lastTarget, S.lastTargetAt = -999, 0
    S.targetRingIdx, S.targetCps = 0, 0
    for i = 1, RING_BUF do S.targetRing[i] = 0 end
    S.tImpEma = 0
    S.tImpHighSince = 0
    S.ballGoneSince = 0
    S._deactLastT = nil
    S.detDotEma, S.detSignal = 0, false
    table.clear(S.dashEvents)
    S.dashPanicUntil, S.dashAnti = 0, { untilT = 0 }
    _ctxCache.valid = false
end

function AutoClash.forceClear()
    clearClash()
end

if _G.ExodusModules then
    _G.ExodusModules.AutoClash = AutoClash
end

return AutoClash