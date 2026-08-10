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

    DEACT_HARD_GONE_T    = 0.20,

    ACT_HARD_CAP         = 22,
    ACT_TIMP_FAST        = 0.085,

    TRAJ_INV_MIN_TRAVEL  = 1.2,
    TRAJ_INV_RATIO_MAX   = 0.4,
    TRAJ_DIST_FLOOR      = 0.05,
    TRAJ_RAD_FLOOR       = 18,
    TRAJ_RAD_CEIL        = 45,
    TRAJ_RAD_SPD_K       = 0.15,
    TRAJ_DEACT_WIN_T     = 0.12,
    TRAJ_DEACT_RATIO_MIN = 0.35,

    ANTIDASH_RAD_MIN     = 20, ANTIDASH_RAD_MAX = 32,
    ANTIDASH_DOT_MIN     = 0.35,
    ANTIDASH_PANIC_HOLD  = 0.45,
    ANTIDASH_PANIC_MAX   = 1.2,
    ANTIDASH_COOLDOWN    = 0.35,

    DASH_SPD_THRESH      = 50, DASH_SPD_CONFIRM = 62,
    DASH_DUR_MIN         = 0.08, DASH_DUR_MAX = 0.5,
    DASH_PANIC_DOT       = 0.85, DASH_PANIC_DIST = 14,
    DASH_PANIC_WINDOW    = 0.300,
    DASH_TRACK_INTERVAL  = 0.2, PLAYER_SCAN_RADIUS = 100,

    CPS_WIN = 1.0, RING_FRESH_MAX = 0.6,
}
local RING_BUF = 8

-- state
local S = {
    lastTarget = -999, lastTargetAt = 0,
    targetRing = table.create(RING_BUF, 0), targetRingIdx = 0, targetCps = 0,

    clashOn = false, clashAt = 0,
    ballGoneSince = 0,

    prevDist      = nil,
    atPeak        = nil,
    peakDist      = nil,
    derivSign     = 0,
    risingSince   = nil,
    riseIntegral  = 0,
    riseWinStart  = nil,
    riseWinSpdMax = 0,
    detSignal     = false,

    dashEvents = {}, dashPanicUntil = 0,
    dashAnti = { untilT = 0 },
}

local _localUserId = -1
local _antidashCooldown, _antidashHooked, _lastDashTrack = {}, {}, 0
local _ctxCache = { t = 0, valid = false }
local SNAPSHOT_TTL = 0.05
local _detRadius = 0

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

local function ballApproachDot(ball, hr)
    if not (ball and ball.Parent and hr and hr.Parent) then return 0 end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return 0 end
    local toMe = hr.Position - ball.Position
    if toMe.Magnitude < 1 then return 1 end
    return av:Dot(toMe.Unit)
end

-- target ring
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

-- trajectory detector
local function resetTrajState()
    S.prevDist, S.atPeak, S.peakDist = nil, nil, nil
    S.derivSign, S.risingSince = 0, nil
    S.riseIntegral, S.riseWinStart, S.riseWinSpdMax = 0, nil, 0
    S.detSignal = false
end

local function updatePeakIfRising(t, dist)
    if dist > (S.peakDist or 0) then
        S.atPeak, S.peakDist = t, dist
    end
end

local function tickTrajectory(t, hr, ball)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        resetTrajState()
        _detRadius = 0
        return
    end

    local dist = (hr.Position - ball.Position).Magnitude
    local p = getP()
    local parryR = (p and p.DEFLECT_R or 0) + parryBonus()
    local spd = (_ctxCache and _ctxCache.valid) and (_ctxCache.spd or 0) or 0
    _detRadius = math.clamp(parryR + spd * C.TRAJ_RAD_SPD_K, C.TRAJ_RAD_FLOOR, C.TRAJ_RAD_CEIL)

    if S.prevDist == nil then
        S.prevDist = dist
        S.atPeak, S.peakDist = t, dist
        S.riseIntegral, S.riseWinStart, S.riseWinSpdMax = 0, t, spd
        return
    end

    local delta = dist - S.prevDist
    S.prevDist = dist

    local sign
    if delta > C.TRAJ_DIST_FLOOR then
        sign = 1
    elseif delta < -C.TRAJ_DIST_FLOOR then
        sign = -1
    else
        sign = S.derivSign
    end

    if S.riseWinStart == nil then
        S.riseWinStart, S.riseWinSpdMax = t, spd
    end
    if t - S.riseWinStart > C.TRAJ_DEACT_WIN_T then
        S.riseIntegral = 0
        S.riseWinStart = t
        S.riseWinSpdMax = spd
    end
    if sign == 1 and delta > 0 then
        S.riseIntegral = S.riseIntegral + delta
    end
    if spd > S.riseWinSpdMax then S.riseWinSpdMax = spd end

    if S.derivSign == 0 then
        S.derivSign = sign
        if sign == 1 then updatePeakIfRising(t, dist) end
        return
    end

    if sign == S.derivSign then
        if sign == 1 then updatePeakIfRising(t, dist) end
        return
    end

    local prevSign = S.derivSign
    S.derivSign = sign

    if prevSign == 1 and sign == -1 then
        local traveled = (S.peakDist or 0) - dist
        if S.atPeak and traveled >= C.TRAJ_INV_MIN_TRAVEL then
            local dtInv = t - S.atPeak
            local expectedTime = spd > 1 and (traveled / spd) or 0.1
            local ratio = dtInv / expectedTime
            if dist <= _detRadius and ratio < C.TRAJ_INV_RATIO_MAX then
                S.detSignal = true
                S.riseIntegral, S.riseWinStart, S.riseWinSpdMax = 0, t, spd
            end
        end
        S.risingSince = nil
    elseif sign == 1 then
        S.risingSince = t
        S.atPeak, S.peakDist = nil, nil
    end

    if sign == -1 then
        S.riseIntegral = 0
        S.riseWinStart = t
        S.riseWinSpdMax = spd
    end
end

-- clash transitions
local function clearClash()
    S.clashOn, S.clashAt = false, 0
    S.ballGoneSince = 0
    resetTrajState()
    _detRadius = 0
    _ctxCache.valid = false
end

local function activateClash(t)
    S.clashOn       = true
    S.clashAt       = t
    S.ballGoneSince = 0
    resetTrajState()
    _detRadius = 0
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

local function shouldDeactivate(t, ctx)
    if not ctx then return false end

    if ctx.bDist > C.MAINT_DEAD_DIST then
        if S.ballGoneSince == 0 then S.ballGoneSince = t end
        if (t - S.ballGoneSince) >= C.DEACT_HARD_GONE_T then return true end
    else
        S.ballGoneSince = 0
    end

    if S.riseWinStart
        and (t - S.riseWinStart) >= C.TRAJ_DEACT_WIN_T then

        local spdMax = S.riseWinSpdMax or 0

        if spdMax > 1 then
            local winT = t - S.riseWinStart
            local expected = spdMax * winT

            if expected > 0 then
                local ratio = S.riseIntegral / expected

                if ratio >= C.TRAJ_DEACT_RATIO_MIN
                    and ctx.bDist > _detRadius then
                    return true
                end
            end
        end
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

    return false
end

local function evaluateClash(t, hr, ball, config, targetJustChangedToMe)
    if not config or config.AutoClash == false or _G.PhantomManual then
        if S.clashOn then clearClash() end
        return
    end

    local ctx = clashSnapshot()
    tickTrajectory(t, hr, ball)

    if S.clashOn then
        if (t - S.clashAt) > C.MAX_HOLD
            or shouldDeactivate(t, ctx) then
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

-- dash tracking
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
    local charConns = {}
    local function attach(char)
        if not char then return end
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
    S.ballGoneSince = 0
    resetTrajState()
    _detRadius = 0
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
