-- [[ auto clash ]]

local AutoClash = {}
local GameInfo, Utils, AutoParry

-- ── tuning ──────────────────────────────────────────────────────────────────

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

    CLASH_PREACT_FRAC    = 0.30,
    CLASH_PREACT_MIN     = 0.10,
    CLASH_PREACT_MAX     = 0.25,

    CLASH_PREACT_BASE    = 0.20,
    CLASH_PREACT_SPD_K   = 0.0010,

    RETURN_TARGET_GAP    = 0.10,
    RETURN_TARGET_MAXD   = 60,
}

-- ── state ───────────────────────────────────────────────────────────────────

local S = {
    lastTarget = -999, lastTargetAt = 0,
    clashOn = false, clashAt = 0,
    ballGoneSince = 0,
    prevDist = nil, atPeak = nil, peakDist = nil,
    derivSign = 0, detSignal = false,
    outOfRangeFrames = 0,

    returnDetected = false,
    returnAt       = 0,
    returnDist     = 0,
    returnSpeed    = 0,
    returnRadius   = 0,

    pendingClashFromTargetFlip = false,
}

local _localUserId = -1
local _ctxCache    = { t = 0, valid = false }
local _detRadius   = 0
local SNAPSHOT_TTL = 0.05

-- ── utils ───────────────────────────────────────────────────────────────────

local function getP()       return AutoParry and AutoParry.getP and AutoParry.getP() or nil end
local function parryBonus() return AutoParry and AutoParry.resRadiusBonus and AutoParry.resRadiusBonus() or 0 end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted() return GameInfo.isTargeted(S.lastTarget) end

local function ballRadial(ctx)
    if not (ctx and ctx.ball and ctx.ball.Parent
            and ctx.toMeMag and ctx.toMeMag > 0.1) then
        return 0, 0
    end
    local ok, av = pcall(function() return ctx.ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3") then return 0, 0 end
    local speed = av.Magnitude
    if speed < 0.1 then return 0, 0 end
    local radial = (av.X * ctx.toMeX + av.Y * ctx.toMeY + av.Z * ctx.toMeZ) / ctx.toMeMag
    return radial, radial / speed
end

local function getBaseRadius()
    local p = getP()
    return math.max((p and p.DEFLECT_R or 8.5) + parryBonus(), 8.5)
end

-- ── snapshot cache ──────────────────────────────────────────────────────────

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
    local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, bp.Z - bp.Z
    local bDist = math.sqrt(dx * dx + dy * dy + dz * dz)

    local radial, cosToward = ballRadial({ ball = ball, toMeX = dx, toMeY = dy, toMeZ = dz, toMeMag = bDist })

    _ctxCache.t, _ctxCache.valid, _ctxCache.hr, _ctxCache.ball = t, true, hr, ball
    _ctxCache.tImp, _ctxCache.spd, _ctxCache.bDist = tImp, spd, bDist
    _ctxCache.targeted = isTargeted()
    _ctxCache.toMeX, _ctxCache.toMeY, _ctxCache.toMeZ, _ctxCache.toMeMag = dx, dy, dz, bDist
    _ctxCache.radialSpd = radial
    _ctxCache.cosToward = cosToward
    return _ctxCache
end

-- ── trajectory detector ─────────────────────────────────────────────────────

local function resetTrajState()
    S.prevDist, S.atPeak, S.peakDist = nil, nil, nil
    S.derivSign, S.detSignal = 0, false
end

local function resetReturnState()
    S.returnDetected = false
    S.returnAt       = 0
    S.returnDist     = 0
    S.returnSpeed    = 0
    S.returnRadius   = 0
    S.pendingClashFromTargetFlip = false
end

local function armReturn(t, dist, instant)
    local ctx = _ctxCache
    if not (ctx and dist and dist > 0) then return false end

    local spd = (ctx.tImp and ctx.tImp > 0) and (dist / ctx.tImp) or 0
    if spd < 1 and ctx.spd and ctx.spd > 0 then spd = ctx.spd end
    if spd < 1 then return false end

    S.returnDetected = true
    S.returnAt       = t
    S.returnDist     = dist
    S.returnSpeed    = spd
    S.returnRadius   = getBaseRadius()
    S.derivSign      = -1
    if instant then S.pendingClashFromTargetFlip = true end
    return true
end

local function updatePeakIfRising(t, dist)
    if dist > (S.peakDist or 0) then S.atPeak, S.peakDist = t, dist end
end

local function classifySign(radial, cosToward, delta)
    if cosToward > 0.25 or radial < -2.0 then return -1 end
    if cosToward < -0.25 or radial > 2.0 then return 1 end
    if delta >  C.TRAJ_DIST_FLOOR then return  1 end
    if delta < -C.TRAJ_DIST_FLOOR then return -1 end
    return nil
end

local function tickTrajectory(t, hr, ball)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        resetTrajState()
        resetReturnState()
        _detRadius = 0
        return
    end

    local dist = (_ctxCache.valid and _ctxCache.bDist) or nil
    if not dist then
        local hp, bp = hr.Position, ball.Position
        local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, bp.Z - bp.Z
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local spd = _ctxCache.valid and (_ctxCache.spd or 0) or 0
    _detRadius = math.clamp(getBaseRadius() + spd * C.TRAJ_RAD_SPD_K, C.TRAJ_RAD_FLOOR, C.TRAJ_RAD_CEIL)

    local radial, cosToward = _ctxCache.radialSpd or 0, _ctxCache.cosToward or 0

    if S.prevDist == nil then
        S.prevDist, S.atPeak, S.peakDist = dist, t, dist
        S.derivSign = (cosToward > 0.3) and -1 or 1
        return
    end

    local delta = dist - S.prevDist
    S.prevDist = dist

    local sign = classifySign(radial, cosToward, delta) or S.derivSign

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
            if (dtInv / expectedTime) < C.TRAJ_INV_RATIO_MAX then
                if dist <= _detRadius then S.detSignal = true end
                armReturn(t, dist)
            end
        end
    elseif sign == 1 then
        S.atPeak, S.peakDist = nil, nil
        resetReturnState()
    end
end

-- ── clash transitions ───────────────────────────────────────────────────────

local function clearClash()
    S.clashOn, S.clashAt = false, 0
    S.ballGoneSince, S.outOfRangeFrames = 0, 0
    resetTrajState()
    resetReturnState()
    _detRadius, _ctxCache.valid = 0, false
end

local function activateClash(t)
    S.clashOn, S.clashAt, S.ballGoneSince, S.outOfRangeFrames = true, t, 0, 0
    resetTrajState()
    resetReturnState()
    _detRadius, _ctxCache.valid = 0, false
end

-- ── decision ────────────────────────────────────────────────────────────────

local function shouldDeactivate(t, ctx)
    if not ctx then return false end
    local spd = ctx.spd or 0
    local pingOneWay = (AutoParry and AutoParry.getPingOneWay and AutoParry.getPingOneWay())
        or C.DEACT_PING_FLOOR
    local raioEfetivo = math.clamp(8.5 + 14, 18, 30)
    local futureDist = ctx.bDist - (ctx.radialSpd or 0) * pingOneWay
    local isOut = ctx.bDist > raioEfetivo or futureDist > raioEfetivo
    S.outOfRangeFrames = isOut and (S.outOfRangeFrames + 1) or 0
    return S.outOfRangeFrames >= C.DEACT_OUT_FRAMES
end

local function confirmApproaching(ctx)
    if not ctx then return false end
    if ctx.tImp and ctx.tImp > 0 and ctx.tImp <= C.CLASH_PREACT_MAX then return true end
    if (ctx.radialSpd or 0) < -2.0 then return true end
    if S.derivSign == -1 then return true end
    if ctx.bDist and ctx.bDist <= C.ACT_HARD_CAP then return true end
    return false
end

local function inPreactWindow(ctx)
    if not (ctx and ctx.tImp and ctx.tImp > 0) then return false end
    local radius = S.returnRadius > 0 and S.returnRadius or _detRadius
    local remaining = ctx.bDist - radius
    if remaining <= 0 then return false end
    local spd = S.returnSpeed > 0 and S.returnSpeed or ctx.spd or 0
    if spd < 1 then spd = ctx.bDist / ctx.tImp end
    if spd < 1 then return false end
    local tToRadius = remaining / spd
    local preact = math.max(C.CLASH_PREACT_BASE, C.CLASH_PREACT_BASE + spd * C.CLASH_PREACT_SPD_K)
    return tToRadius <= preact
end

local function shouldActivate(t, ctx, targetJustChangedToMe)
    if not (ctx and ctx.targeted or isTargeted()) then return false end

    if S.pendingClashFromTargetFlip then
        S.pendingClashFromTargetFlip = false
        if confirmApproaching(ctx) then return true end
    end

    if targetJustChangedToMe and ctx then
        if ctx.bDist <= C.ACT_HARD_CAP and ctx.tImp and ctx.tImp > 0 and ctx.tImp <= C.ACT_TIMP_FAST then
            return true
        end
        if ctx.tImp and ctx.tImp > 0 and ctx.bDist and ctx.bDist > C.ACT_HARD_CAP then
            armReturn(t, ctx.bDist)
        end
    end

    if S.detSignal then return true end

    if S.returnDetected and ctx and ctx.bDist and confirmApproaching(ctx) and inPreactWindow(ctx) then
        return true
    end

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
    if shouldActivate(t, ctx, targetJustChangedToMe) then activateClash(t) end
end

-- ── targeting ───────────────────────────────────────────────────────────────

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    local prevTarget, prevTargetAt = S.lastTarget, S.lastTargetAt
    S.lastTarget, S.lastTargetAt = newTarget, t
    local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == _localUserId) end
    _ctxCache.valid = false

    local cameBackToMe = (newTarget == _localUserId)
        and (prevTarget ~= _localUserId)
        and (prevTarget ~= -999)
    if not cameBackToMe then
        resetReturnState()
        return
    end

    if (t - (prevTargetAt or 0)) < C.RETURN_TARGET_GAP then return end
    local ctx = _ctxCache
    if not (ctx and ctx.bDist and ctx.bDist <= C.RETURN_TARGET_MAXD) then return end
    local instant = ctx.tImp and ctx.tImp > 0 and ctx.tImp <= C.CLASH_PREACT_MAX
    armReturn(t, ctx.bDist, instant)
end

-- ── public ──────────────────────────────────────────────────────────────────

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
function AutoClash.updateDashTrack(t)     end
function AutoClash.installAntiDashHooks() end
function AutoClash.getState()       return S end
function AutoClash.clashOn()        return S.clashOn end
function AutoClash.getClashAt()     return S.clashAt end
function AutoClash.snapshot()       return clashSnapshot() end
function AutoClash.invalidateSnapshot() _ctxCache.valid = false end

function AutoClash.resetState()
    S.clashOn, S.clashAt, S.ballGoneSince, S.outOfRangeFrames = false, 0, 0, 0
    S.lastTarget, S.lastTargetAt = -999, 0
    resetTrajState()
    resetReturnState()
    _detRadius, _ctxCache.valid = 0, false
end

function AutoClash.forceClear() clearClash() end

if _G.ExodusModules then _G.ExodusModules.AutoClash = AutoClash end
return AutoClash
