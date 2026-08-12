-- [[ auto clash ]]

local AutoClash = {}
local GameInfo, Utils, AutoParry

local C = {
    DEACT_OUT_FRAMES     = 2,

    TRAJ_DIST_FLOOR      = 0.05,
    TRAJ_RAD_FLOOR       = 18,
    TRAJ_RAD_CEIL        = 45,
    TRAJ_RAD_SPD_K       = 0.15,
    TRAJ_INV_MIN_TRAVEL  = 1.2,
    TRAJ_INV_RATIO_MAX   = 0.4,

    RETURN_TARGET_GAP    = 0.16,
    RETURN_TARGET_MAXD   = 60,
}

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
}

local _localUserId = -1
local _ctxCache    = { t = 0, valid = false }
local _detRadius   = 0
local SNAPSHOT_TTL = 0.05

-- ── helpers ─────────────────────────────────────────────────────────────────

local function parryBonus() return AutoParry and AutoParry.resRadiusBonus and AutoParry.resRadiusBonus() or 0 end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted() return AutoParry and AutoParry.isTargeted and AutoParry.isTargeted() or false end

-- ── ball radial ─────────────────────────────────────────────────────────────

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

-- ── base radius ─────────────────────────────────────────────────────────────

local function getBaseRadius(t)
    local ctx = _ctxCache
    if ctx.valid and ctx.spd ~= nil then
        return AutoParry.computeParryRadius(ctx.spd, t) + parryBonus()
    end
    return 8.5 + parryBonus()
end

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

    local spd = 0
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if ok and typeof(av) == "Vector3" then spd = av.Magnitude end

    local hp, bp = hr.Position, ball.Position
    local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, hp.Z - bp.Z
    local bDist = math.sqrt(dx * dx + dy * dy + dz * dz)

    local radial, cosToward = ballRadial({ ball = ball, toMeX = dx, toMeY = dy, toMeZ = dz, toMeMag = bDist })

    _ctxCache.t, _ctxCache.valid, _ctxCache.hr, _ctxCache.ball = t, true, hr, ball
    _ctxCache.spd, _ctxCache.bDist = spd, bDist
    _ctxCache.targeted = isTargeted()
    _ctxCache.toMeX, _ctxCache.toMeY, _ctxCache.toMeZ, _ctxCache.toMeMag = dx, dy, dz, bDist
    _ctxCache.radialSpd = radial
    _ctxCache.cosToward = cosToward
    return _ctxCache
end

-- ── trajectory state ────────────────────────────────────────────────────────

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
end

local function armReturn(t, dist)
    local ctx = _ctxCache
    if not (ctx and dist and dist > 0) then return false end

    local spd = ctx.spd or 0
    if spd < 1 then return false end

    S.returnDetected = true
    S.returnAt       = t
    S.returnDist     = dist
    S.returnSpeed    = spd
    S.returnRadius   = getBaseRadius(t)
    S.derivSign      = -1
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

local function tickTrajectory(t, hr, ball, ctx)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        resetTrajState()
        resetReturnState()
        _detRadius = 0
        return
    end

    ctx = ctx or _ctxCache
    local dist = (ctx.valid and ctx.bDist) or nil
    if not dist then
        local hp, bp = hr.Position, ball.Position
        local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, hp.Z - bp.Z
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local spd = (ctx.valid and (ctx.spd or 0)) or 0
    _detRadius = math.clamp(getBaseRadius(t) + spd * C.TRAJ_RAD_SPD_K, C.TRAJ_RAD_FLOOR, C.TRAJ_RAD_CEIL)

    local radial, cosToward = (ctx.radialSpd or 0), (ctx.cosToward or 0)

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

-- ── clash activation ────────────────────────────────────────────────────────

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

local function shouldDeactivate(t, ctx)
    if not ctx then return false end
    local isOut = ctx.bDist > getBaseRadius(t)
    S.outOfRangeFrames = isOut and (S.outOfRangeFrames + 1) or 0
    return S.outOfRangeFrames >= C.DEACT_OUT_FRAMES
end

local function shouldActivate(t, ctx)
    if not (ctx and (ctx.targeted or isTargeted())) then return false end
    if not (ctx and ctx.bDist) then return false end

    local r = getBaseRadius(t)
    if ctx.bDist > r then return false end
    if (ctx.radialSpd or 0) >= 0 then return false end

    if S.detSignal then return true end
    if S.returnDetected then return true end

    return false
end

-- ── evaluate ────────────────────────────────────────────────────────────────

local function evaluateClash(t, hr, ball, config)
    if not config or config.AutoClash == false or _G.PhantomManual then
        if S.clashOn then clearClash() end
        return
    end
    if GameInfo.isGrace() then
        if S.clashOn then clearClash() end
        return
    end
    local ctx = clashSnapshot()
    tickTrajectory(t, hr, ball, ctx)
    if S.clashOn then
        if shouldDeactivate(t, ctx) then clearClash() end
        return
    end
    if shouldActivate(t, ctx) then activateClash(t) end
end

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
    local ctx = clashSnapshot()
    if not (ctx and ctx.bDist and ctx.bDist <= C.RETURN_TARGET_MAXD) then return end
    if (ctx.radialSpd or 0) >= -0.5 then return end
    armReturn(t, ctx.bDist)
end

-- ── public ──────────────────────────────────────────────────────────────────

function AutoClash.setup(deps)
    GameInfo, Utils, AutoParry = deps.GameInfo, deps.Utils, deps.AutoParry
    _localUserId = Utils.getLocalPlayer().UserId
    Utils.setOnClashOn(function() return S.clashOn end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(clearClash)
end

function AutoClash.evaluate(t, hr, ball, config)
    evaluateClash(t, hr, ball, config)
end
function AutoClash.updateDashTrack(t)     end
function AutoClash.installAntiDashHooks() end
function AutoClash.getState()       return S end
function AutoClash.clashOn()        return S.clashOn end
function AutoClash.getClashAt()     return S.clashAt end
function AutoClash.snapshot()       return clashSnapshot() end
function AutoClash.invalidateSnapshot() _ctxCache.valid = false end

function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then return end
    local t = Utils.now()
    onTarget(data.TargetPlayerID or -999, t)
end

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
