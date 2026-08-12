-- [[ auto clash ]]

local AutoClash = {}

local GameInfo, Utils, AutoParry

-- tuning
local C = {
    DEACT_PING_FLOOR     = 0.030,
    DEACT_OUT_FRAMES     = 4,
    ACT_HARD_CAP         = 22,
    ACT_TIMP_FAST        = 0.085,
    TRAJ_DIST_FLOOR      = 0.05,
    TRAJ_RAD_FLOOR       = 18,
    TRAJ_RAD_CEIL        = 45,
    TRAJ_RAD_SPD_K       = 0.15,
    TRAJ_INV_MIN_TRAVEL  = 1.2,
    TRAJ_INV_RATIO_MAX   = 0.4,
}

-- state
local S = {
    lastTarget = -999, lastTargetAt = 0,
    clashOn = false, clashAt = 0,
    ballGoneSince = 0,
    prevDist = nil, atPeak = nil, peakDist = nil,
    derivSign = 0, detSignal = false,
    outOfRangeFrames = 0,
}

local _localUserId = -1
local _ctxCache    = { t = 0, valid = false }
local _detRadius   = 0
local SNAPSHOT_TTL = 0.05

-- utils
local function getP()       return AutoParry and AutoParry.getP and AutoParry.getP() or nil end
local function parryBonus() return AutoParry and AutoParry.resRadiusBonus and AutoParry.resRadiusBonus() or 0 end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted() return GameInfo.isTargeted(S.lastTarget) end

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
    if live then tImp = tonumber(live.tImp) or math.huge; spd = tonumber(live.spd) or 0 end
    if spd < 1 then
        local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
        tImp = ti or tImp; spd = s2 or spd
    end

    local hp, bp = hr.Position, ball.Position
    local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, hp.Z - bp.Z
    local bDist = math.sqrt(dx * dx + dy * dy + dz * dz)

    _ctxCache.t, _ctxCache.valid, _ctxCache.hr, _ctxCache.ball = t, true, hr, ball
    _ctxCache.tImp, _ctxCache.spd, _ctxCache.bDist = tImp, spd, bDist
    _ctxCache.targeted = isTargeted()
    _ctxCache.toMeX, _ctxCache.toMeY, _ctxCache.toMeZ, _ctxCache.toMeMag = dx, dy, dz, bDist
    return _ctxCache
end

-- trajectory detector
local function resetTrajState()
    S.prevDist, S.atPeak, S.peakDist = nil, nil, nil
    S.derivSign, S.detSignal = 0, false
end

local function updatePeakIfRising(t, dist)
    if dist > (S.peakDist or 0) then S.atPeak, S.peakDist = t, dist end
end

local function tickTrajectory(t, hr, ball)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        resetTrajState(); _detRadius = 0; return
    end

    local dist = _ctxCache.valid and _ctxCache.bDist or nil
    if not dist then
        local hp, bp = hr.Position, ball.Position
        local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, hp.Z - bp.Z
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local p, parryR = getP(), (getP() and getP().DEFLECT_R or 0) + parryBonus()
    local spd = _ctxCache.valid and (_ctxCache.spd or 0) or 0
    _detRadius = parryR + spd * C.TRAJ_RAD_SPD_K
    _detRadius = math.clamp(_detRadius, C.TRAJ_RAD_FLOOR, C.TRAJ_RAD_CEIL)

    if dist > _detRadius and S.prevDist then
        local delta = dist - S.prevDist
        if delta >= 0 then S.prevDist = dist; return end
    end

    if S.prevDist == nil then
        S.prevDist, S.atPeak, S.peakDist = dist, t, dist
        return
    end

    local delta = dist - S.prevDist
    S.prevDist = dist

    local sign
    if delta > C.TRAJ_DIST_FLOOR then sign = 1
    elseif delta < -C.TRAJ_DIST_FLOOR then sign = -1
    else sign = S.derivSign end

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
            if dist <= _detRadius and (dtInv / expectedTime) < C.TRAJ_INV_RATIO_MAX then
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
    S.ballGoneSince, S.outOfRangeFrames = 0, 0
    resetTrajState()
    _detRadius, _ctxCache.valid = 0, false
end

local function activateClash(t)
    S.clashOn, S.clashAt, S.ballGoneSince, S.outOfRangeFrames = true, t, 0, 0
    resetTrajState()
    _detRadius, _ctxCache.valid = 0, false
end

-- decisão
local function shouldDeactivate(t, ctx)
    if not ctx then return false end

    local p = getP()
    local baseRad = (p and p.DEFLECT_R or 8.5) + parryBonus()
    local spd = ctx.spd or 0

    local pingOneWay = AutoParry and AutoParry.getPingOneWay
        and AutoParry.getPingOneWay() or C.DEACT_PING_FLOOR

    local raioEfetivo = math.max(baseRad + spd * pingOneWay, 14)

    local radialSpd = 0
    if ctx.toMeMag and ctx.toMeMag > 0.1
        and ctx.hr and ctx.hr.Parent
        and ctx.ball and ctx.ball.Parent then
        local ok, av = pcall(function() return ctx.ball.AssemblyLinearVelocity end)
        if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
            radialSpd = (av.X * ctx.toMeX + av.Y * ctx.toMeY + av.Z * ctx.toMeZ) / ctx.toMeMag
        end
    end

    local futureDist = ctx.bDist - radialSpd * pingOneWay
    local isOut = ctx.bDist > raioEfetivo or futureDist > raioEfetivo

    S.outOfRangeFrames = isOut and (S.outOfRangeFrames + 1) or 0
    return S.outOfRangeFrames >= C.DEACT_OUT_FRAMES
end

local function shouldActivate(t, ctx, targetJustChangedToMe)
    local targeted = ctx and ctx.targeted or isTargeted()
    if not targeted then return false end
    if targetJustChangedToMe and ctx then
        if ctx.bDist <= C.ACT_HARD_CAP and ctx.tImp > 0 and ctx.tImp <= C.ACT_TIMP_FAST then
            return true
        end
    end
    return S.detSignal
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
    if shouldActivate(t, ctx, targetJustChangedToMe) then activateClash(t) end
end

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    S.lastTarget, S.lastTargetAt = newTarget, t
    local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == _localUserId) end
    _ctxCache.valid = false
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
function AutoClash.updateDashTrack(t)         end
function AutoClash.installAntiDashHooks()     end
function AutoClash.getState()           return S end
function AutoClash.clashOn()            return S.clashOn end
function AutoClash.getClashAt()         return S.clashAt end
function AutoClash.snapshot()           return clashSnapshot() end
function AutoClash.invalidateSnapshot() _ctxCache.valid = false end

function AutoClash.resetState()
    S.clashOn, S.clashAt, S.ballGoneSince, S.outOfRangeFrames = false, 0, 0, 0
    S.lastTarget, S.lastTargetAt = -999, 0
    resetTrajState()
    _detRadius, _ctxCache.valid = 0, false
end

function AutoClash.forceClear() clearClash() end

if _G.ExodusModules then _G.ExodusModules.AutoClash = AutoClash end
return AutoClash
