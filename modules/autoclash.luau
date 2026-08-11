-- [[ auto clash ]]

local AutoClash = {}

local GameInfo, Utils, AutoParry

-- tuning
local C = {
    DEACT_HARD_GONE_T    = 0.20,
    DEACT_DEAD_DIST      = 80,

    DEACT_CLICK_WINDOW   = 0.100,  -- janela adicional pra evitar flick
    DEACT_PING_FLOOR     = 0.030,
    DEACT_PING_CAP       = 0.150,
    DEACT_RADIAL_EMA     = 0.35,

    ACT_HARD_CAP         = 22,
    ACT_TIMP_FAST        = 0.085,

    TRAJ_DIST_FLOOR      = 0.05,
    TRAJ_RAD_FLOOR       = 18,
    TRAJ_RAD_CEIL        = 45,
    TRAJ_RAD_SPD_K       = 0.15,
    TRAJ_INV_MIN_TRAVEL  = 1.2,
    TRAJ_INV_RATIO_MAX   = 0.4,

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
}

-- state
local S = {
    lastTarget = -999, lastTargetAt = 0,

    clashOn = false, clashAt = 0,
    ballGoneSince = 0,

    prevDist      = nil,
    atPeak        = nil,
    peakDist      = nil,
    derivSign     = 0,
    detSignal     = false,

    dashEvents = {}, dashPanicUntil = 0,
    dashAnti = { untilT = 0 },

    radialSpdEma = 0,
}

local _localUserId       = -1
local _antidashCooldown  = {}
local _antidashHooked    = {}
local _lastDashTrack     = 0
local _ctxCache          = { t = 0, valid = false }
local _detRadius         = 0

local SNAPSHOT_TTL       = 0.05

-- utils
local function getP()       return AutoParry and AutoParry.getP and AutoParry.getP() or nil end
local function parryBonus() return AutoParry and AutoParry.resRadiusBonus and AutoParry.resRadiusBonus() or 0 end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted()
    return GameInfo.isTargeted(S.lastTarget)
end

-- snapshot cache
local function clashSnapshot()
    local t = Utils.now()
    if _ctxCache.valid and (t - _ctxCache.t) < SNAPSHOT_TTL
        and _ctxCache.hr and _ctxCache.hr.Parent
        and _ctxCache.ball and _ctxCache.ball.Parent then
        return _ctxCache
    end
    local hr = getMyHRP()
    if not hr then _ctxCache.valid = false; return nil end
    local ball = GameInfo.getBall()
    if not (ball and ball.Parent) then _ctxCache.valid = false; return nil end

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

    _ctxCache.t        = t
    _ctxCache.valid    = true
    _ctxCache.hr       = hr
    _ctxCache.ball     = ball
    _ctxCache.tImp     = tImp
    _ctxCache.spd      = spd
    _ctxCache.bDist    = (hr.Position - ball.Position).Magnitude
    _ctxCache.targeted = isTargeted()
    return _ctxCache
end

-- trajectory detector → detSignal ativa o clash
local function resetTrajState()
    S.prevDist, S.atPeak, S.peakDist = nil, nil, nil
    S.derivSign                      = 0
    S.detSignal                      = false
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

    local dist  = (hr.Position - ball.Position).Magnitude
    local p     = getP()
    local parryR = (p and p.DEFLECT_R or 0) + parryBonus()
    local spd   = _ctxCache.valid and (_ctxCache.spd or 0) or 0
    _detRadius  = math.clamp(parryR + spd * C.TRAJ_RAD_SPD_K, C.TRAJ_RAD_FLOOR, C.TRAJ_RAD_CEIL)

    if S.prevDist == nil then
        S.prevDist = dist
        S.atPeak, S.peakDist = t, dist
        return
    end

    local delta = dist - S.prevDist
    S.prevDist  = dist

    local sign
    if delta > C.TRAJ_DIST_FLOOR then
        sign = 1
    elseif delta < -C.TRAJ_DIST_FLOOR then
        sign = -1
    else
        sign = S.derivSign
    end

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
    S.derivSign    = sign

    if prevSign == 1 and sign == -1 then
        local traveled = (S.peakDist or 0) - dist
        if S.atPeak and traveled >= C.TRAJ_INV_MIN_TRAVEL then
            local dtInv       = t - S.atPeak
            local expectedTime = spd > 1 and (traveled / spd) or 0.1
            local ratio       = dtInv / expectedTime
            if dist <= _detRadius and ratio < C.TRAJ_INV_RATIO_MAX then
                S.detSignal = true
            end
        end
    elseif sign == 1 then
        S.atPeak, S.peakDist = nil, nil
    end
end

-- clash transitions
local function clearClash()
    S.clashOn, S.clashAt = false, 0
    S.ballGoneSince      = 0
    S.radialSpdEma       = 0
    resetTrajState()
    _detRadius        = 0
    _ctxCache.valid   = false
end

local function activateClash(t)
    S.clashOn       = true
    S.clashAt       = t
    S.ballGoneSince = 0
    S.radialSpdEma  = 0
    resetTrajState()
    _detRadius      = 0
    _ctxCache.valid = false
end

-- decisão
local function shouldDeactivate(t, ctx)
    if not ctx then return false end

    -- hard gone
    if ctx.bDist > C.DEACT_DEAD_DIST then
        if S.ballGoneSince == 0 then S.ballGoneSince = t end
        if (t - S.ballGoneSince) >= C.DEACT_HARD_GONE_T then return true end
    else
        S.ballGoneSince = 0
    end

    local spd = ctx.spd or 0
    if spd < 1 then return false end

    -- velocidade radial com EMA
    local radialSpd = 0
    if ctx.hr and ctx.hr.Parent and ctx.ball and ctx.ball.Parent then
        local ok, av = pcall(function() return ctx.ball.AssemblyLinearVelocity end)
        if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
            local toMe = ctx.hr.Position - ctx.ball.Position
            if toMe.Magnitude > 0.1 then
                radialSpd = av:Dot(toMe.Unit)
            end
        end
    end
    S.radialSpdEma = S.radialSpdEma * (1 - C.DEACT_RADIAL_EMA) + radialSpd * C.DEACT_RADIAL_EMA

    -- ping e raio efetivo
    local pingOneWay = AutoParry and AutoParry.getPingOneWay
        and AutoParry.getPingOneWay()
        or C.DEACT_PING_FLOOR

    local p = getP()
    local baseRad = (p and p.DEFLECT_R or 8.5) + parryBonus()
    local raioEfetivo = math.max(
        baseRad + spd * (pingOneWay + C.DEACT_CLICK_WINDOW),
        14
    )

    -- posição prevista quando o clique chegar ao servidor
    local futureDist = ctx.bDist - S.radialSpdEma * pingOneWay

    -- bola vai estar dentro da zona → não desativa
    if futureDist <= raioEfetivo then return false end

    -- bola vai estar fora → desativa
    return true
end

local function shouldActivate(t, ctx, targetJustChangedToMe)
    local targeted = ctx and ctx.targeted or isTargeted()
    if not targeted then
        if S.dashAnti.untilT  > t then return true end
        if S.dashPanicUntil   > t then return true end
        return false
    end

    if targetJustChangedToMe and ctx then
        if ctx.bDist <= C.ACT_HARD_CAP and ctx.tImp > 0 and ctx.tImp <= C.ACT_TIMP_FAST then
            return true
        end
    end

    if S.detSignal         then return true end
    if S.dashAnti.untilT   > t then return true end
    if S.dashPanicUntil    > t then return true end
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
        if shouldDeactivate(t, ctx) then clearClash() end
        return
    end

    if shouldActivate(t, ctx, targetJustChangedToMe) then
        activateClash(t)
    end
end

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    S.lastTarget, S.lastTargetAt = newTarget, t
    local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == _localUserId) end
    _ctxCache.valid = false
end

-- dash tracking
local function updateDashTrack(t)
    if (t - _lastDashTrack) < C.DASH_TRACK_INTERVAL then return end
    _lastDashTrack = t
    local lp   = Utils.getLocalPlayer()
    local char = lp and lp.Character
    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP then table.clear(S.dashEvents); return end
    local myPos   = myHRP.Position
    local Players = Utils.getPlayers()

    for _, p in ipairs(Players:GetPlayers()) do
        if p == lp then continue end
        local pChar = p.Character
        if not pChar then S.dashEvents[p.UserId] = nil; continue end
        local php = pChar:FindFirstChild("HumanoidRootPart")
        if not php then S.dashEvents[p.UserId] = nil; continue end
        if (myPos - php.Position).Magnitude > C.PLAYER_SCAN_RADIUS
            and not S.dashEvents[p.UserId] then continue end
        local hum = pChar:FindFirstChildOfClass("Humanoid")
        if not (hum and hum.Health > 0) then S.dashEvents[p.UserId] = nil; continue end

        local spd = php.AssemblyLinearVelocity.Magnitude
        local ev  = S.dashEvents[p.UserId]
        if spd >= C.DASH_SPD_THRESH then
            local dir = php.AssemblyLinearVelocity.Unit
            if not ev then
                S.dashEvents[p.UserId] = { spd = spd, dir = dir, at = t, startedAt = t, confirmed = false }
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
        if not p or not ev.confirmed or not ev.dir then S.dashEvents[uid] = nil; continue end
        local dur = t - ev.startedAt
        if dur > C.DASH_DUR_MAX then S.dashEvents[uid] = nil; continue end
        if dur < C.DASH_DUR_MIN then continue end
        local php = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if not php then continue end
        local toMe = myPos - php.Position
        if toMe.Magnitude > C.DASH_PANIC_DIST then continue end
        if ev.dir:Dot(toMe.Unit) < C.DASH_PANIC_DOT then continue end
        if ev.spd < C.DASH_SPD_CONFIRM then continue end
        S.dashPanicUntil   = math.max(S.dashPanicUntil, t + C.DASH_PANIC_WINDOW)
        S.dashAnti.untilT  = math.max(S.dashAnti.untilT, t + C.ANTIDASH_PANIC_HOLD)
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
    local p   = getP()
    if not p then return end
    local rad = math.clamp((p.DEFLECT_R or 0) + parryBonus(), C.ANTIDASH_RAD_MIN, C.ANTIDASH_RAD_MAX)
    local toMe = myHRP.Position - php.Position
    if toMe.Magnitude > rad or toMe.Magnitude < 0.1 then return end
    local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return end
    if av.Unit:Dot(toMe.Unit) < C.ANTIDASH_DOT_MIN then return end

    _antidashCooldown[player.UserId] = t
    S.dashAnti.untilT = math.min(
        math.max(S.dashAnti.untilT, t) + C.ANTIDASH_PANIC_HOLD,
        t + C.ANTIDASH_PANIC_MAX
    )
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
            if c and type(c.Disconnect) == "function" then pcall(function() c:Disconnect() end) end
        end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        local anim = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
        if not anim then return end
        for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
            if isDashTrack(tr) then reportDash(player); break end
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
    _localUserId = Utils.getLocalPlayer().UserId
    Utils.setOnClashOn(function() return S.clashOn end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(clearClash)
end

function AutoClash.evaluate(t, hr, ball, config, targetJustChangedToMe)
    evaluateClash(t, hr, ball, config, targetJustChangedToMe)
end
function AutoClash.updateDashTrack(t)         updateDashTrack(t) end
function AutoClash.installAntiDashHooks()     installAntiDashHooks() end
function AutoClash.getState()                 return S end
function AutoClash.clashOn()                  return S.clashOn end
function AutoClash.getClashAt()               return S.clashAt end
function AutoClash.snapshot()                 return clashSnapshot() end
function AutoClash.invalidateSnapshot()       _ctxCache.valid = false end

function AutoClash.resetState()
    S.clashOn, S.clashAt = false, 0
    S.lastTarget, S.lastTargetAt = -999, 0
    S.ballGoneSince = 0
    S.radialSpdEma  = 0
    resetTrajState()
    _detRadius = 0
    table.clear(S.dashEvents)
    S.dashPanicUntil, S.dashAnti = 0, { untilT = 0 }
    _ctxCache.valid = false
end

function AutoClash.forceClear() clearClash() end

if _G.ExodusModules then
    _G.ExodusModules.AutoClash = AutoClash
end

return AutoClash