-- [[ auto clash ]]
-- Desativação: target saiu + bola se afastando (histerese dupla)

local AutoClash = {}

local GameInfo
local Utils
local AutoParry

-- ── constants ────────────────────────────────────────────────────────────────

local C = {
    ACT_RAD_FACTOR = 1.40,

    DET_RAD_MIN = 10,
    DET_RAD_MAX = 25,
    DET_RAD_SPD_REF = 120,
    DET_DIST_DELTA = 0.5,

    DET_RETURN_MAX_LO = 0.220,
    DET_RETURN_MIN_HI = 0.100,
    DET_RETURN_SPD_LO = 60,
    DET_RETURN_SPD_HI = 200,
    DET_TIMEOUT = 0.8,

    TARGET_RETURN_MAX_LO = 0.200,
    TARGET_RETURN_MIN_HI = 0.100,
    TARGET_RETURN_SPD_LO = 60,
    TARGET_RETURN_SPD_HI = 200,

    -- Desativação: tImp < 0 continuamente por X tempo (varia com speed)
    -- tImp < 0 = bola já passou de mim, está se afastando
    -- thresholds baseados na ativação (~190ms), com folga
    DEACT_TIMP_SPD_LO = 60,
    DEACT_TIMP_SPD_HI = 200,
    DEACT_TIMP_T_LO   = 0.300,  -- 300ms em speed baixa
    DEACT_TIMP_T_HI   = 0.150,  -- 150ms em speed alta

    TELEPORT_LOCK = 0.20,
}

-- ── state ────────────────────────────────────────────────────────────────────

local S = {
    enabled = false,
    active = false,
    activeAt = 0,

    detPhase = "IDLE",
    detEnterAt = 0,
    detExitAt = 0,
    detMinDist = 0,

    lastTarget = -999,
    lastTargetAt = 0,
    wasMeTarget = false,
    lostMeAt = 0,

    -- tImp < 0 continuamente desde este timestamp (0 = bola não está se afastando)
    timpAwaySince = 0,

    teleportLockUntil = 0,
}

-- ── aliases ──────────────────────────────────────────────────────────────────

local function now()
    return Utils.now()
end

local function getLocalPlayer()
    return Utils.getLocalPlayer()
end

local function getMyHRP()
    local player = getLocalPlayer()
    local character = player and player.Character

    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
end

local function getBall()
    return GameInfo.getBall()
end

local function isTargeted()
    return AutoParry.isTargeted()
end

local function getBallSpeed(ball)
    if not ball or not ball.Parent then
        return 0
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        return 0
    end

    return velocity.Magnitude
end

local function lerpBySpeed(
    speed,
    speedLow,
    speedHigh,
    valueLow,
    valueHigh
)
    if speedHigh <= speedLow then
        return valueLow
    end

    local alpha = math.clamp(
        (speed - speedLow) / (speedHigh - speedLow),
        0,
        1
    )

    return valueLow + (valueHigh - valueLow) * alpha
end

local function getDetectorRadius(speed)
    local alpha = math.clamp(speed / C.DET_RAD_SPD_REF, 0, 1)

    return C.DET_RAD_MIN
        + (C.DET_RAD_MAX - C.DET_RAD_MIN) * alpha
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

local function resetDetector()
    S.detPhase = "IDLE"
    S.detEnterAt = 0
    S.detExitAt = 0
    S.detMinDist = 0
end

local function activate(t)
    S.active = true
    S.activeAt = t

    S.timpAwaySince = 0
    resetDetector()
end

local function deactivate()
    S.active = false
    S.activeAt = 0

    S.timpAwaySince = 0
    resetDetector()
end

-- ── return detector ──────────────────────────────────────────────────────────

local function getDetectorReturnWindow(speed)
    return lerpBySpeed(
        speed,
        C.DET_RETURN_SPD_LO,
        C.DET_RETURN_SPD_HI,
        C.DET_RETURN_MAX_LO,
        C.DET_RETURN_MIN_HI
    )
end

local function resetDetectorState()
    S.detPhase = "IDLE"
    S.detEnterAt = 0
    S.detExitAt = 0
    S.detMinDist = 0
end

local function tickReturnDetector(t, hr, ball)
    if not (
        hr
        and hr.Parent
        and ball
        and ball.Parent
    ) then
        resetDetectorState()
        return false
    end

    local velocity
    local ok = pcall(function()
        velocity = ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        resetDetectorState()
        return false
    end

    local speed = velocity.Magnitude

    if speed <= 1 then
        resetDetectorState()
        return false
    end

    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude

    if distance <= 0.001 then
        resetDetectorState()
        return false
    end

    local radius = getDetectorRadius(speed)
    local coming = velocity:Dot(offset.Unit) > 0

    if distance > radius * 1.2 then
        resetDetectorState()
        return false
    end

    if S.detPhase == "EXITED"
        and t - S.detExitAt > C.DET_TIMEOUT
    then
        resetDetectorState()
    end

    if S.detPhase == "IDLE" then
        if distance <= radius and coming then
            S.detPhase = "INSIDE"
            S.detEnterAt = t
            S.detMinDist = distance
        end

        return false
    end

    if S.detPhase == "INSIDE" then
        S.detMinDist = math.min(S.detMinDist, distance)

        if distance > S.detMinDist + C.DET_DIST_DELTA then
            S.detPhase = "EXITED"
            S.detExitAt = t
        end

        return false
    end

    if S.detPhase == "EXITED" then
        local elapsed = t - S.detExitAt
        local window = getDetectorReturnWindow(speed)

        local returned =
            distance <= S.detMinDist + C.DET_DIST_DELTA
            and coming

        if returned then
            S.detPhase = "INSIDE"
            S.detEnterAt = t
            S.detMinDist = distance

            if elapsed <= window then
                return true
            end
        end
    end

    return false
end

-- ── activation ───────────────────────────────────────────────────────────────

local function shouldActivate(t, hr, ball)
    if not hr or not hr.Parent then
        return false
    end

    if not ball or not ball.Parent then
        return false
    end

    if not isTargeted() then
        return false
    end

    return tickReturnDetector(t, hr, ball)
end

-- ── deactivation ─────────────────────────────────────────────────────────────
-- Critério: tImp < 0 continuamente por X ms (X varia com speed).
-- tImp < 0 = bola já passou de mim, está se afastando.

-- pega raio de parry real do AutoParry (com fallback conservador)
local PARRY_RAD_FALLBACK = 14
local function getParryRadius(speed, t)
    local parryRadius = PARRY_RAD_FALLBACK
    if AutoParry and type(AutoParry.getParryRadius) == "function" then
        local v = AutoParry.getParryRadius(speed, t)
        if type(v) == "number" and v > 0 then
            parryRadius = v
        end
    end
    return parryRadius
end

-- mesmo tImp do AutoParry: (dist - parryRad) / speed
-- < 0 = bola passou, está se afastando
local function computeTImp(hr, ball, speed, t)
    local parryRad = getParryRadius(speed, t)
    local dist = (hr.Position - ball.Position).Magnitude
    return (dist - parryRad) / speed, parryRad
end

-- threshold ajustado por velocidade (rápido = desativa mais rápido)
local function getDeactTimpT(speed)
    return lerpBySpeed(
        speed,
        C.DEACT_TIMP_SPD_LO,
        C.DEACT_TIMP_SPD_HI,
        C.DEACT_TIMP_T_LO,
        C.DEACT_TIMP_T_HI
    )
end

local function shouldDeactivate(t, hr, ball)
    -- hard fails (sempre desativa)
    if t < S.teleportLockUntil then
        return true
    end

    if not hr or not hr.Parent then
        return true
    end

    if not ball or not ball.Parent then
        return true
    end

    local speed = getBallSpeed(ball)
    if speed <= 1 then
        return true
    end

    -- calcula tImp
    local tImp, _parryRad = computeTImp(hr, ball, speed, t)

    -- Timer: bola se afastando (tImp < 0) continuamente
    if tImp < 0 then
        if S.timpAwaySince == 0 then
            S.timpAwaySince = t
        end
    else
        S.timpAwaySince = 0
    end

    -- Desativa só se ficou se afastando pelo tempo mínimo
    if S.timpAwaySince > 0 then
        local timpAwayFor = t - S.timpAwaySince
        if timpAwayFor >= getDeactTimpT(speed) then
            return true
        end
    end

    return false
end

-- ── evaluate ─────────────────────────────────────────────────────────────────

local function evaluate(t, hr, ball, config)
    local enabled =
        config
        and config.AutoClash ~= false
        and not _G.PhantomManual

    if not enabled then
        S.enabled = false
        deactivate()
        return
    end

    if GameInfo.isGrace() then
        deactivate()
        return
    end

    S.enabled = true

    if not hr or not hr.Parent then
        deactivate()
        return
    end

    if not ball or not ball.Parent then
        deactivate()
        return
    end

    if t < S.teleportLockUntil then
        deactivate()
        return
    end

    if S.active then
        if shouldDeactivate(t, hr, ball) then
            deactivate()
        end

        return
    end

    if shouldActivate(t, hr, ball) then
        activate(t)
    end
end

-- ── callbacks ────────────────────────────────────────────────────────────────

local function getTargetReturnWindow(speed)
    return lerpBySpeed(
        speed,
        C.TARGET_RETURN_SPD_LO,
        C.TARGET_RETURN_SPD_HI,
        C.TARGET_RETURN_MAX_LO,
        C.TARGET_RETURN_MIN_HI
    )
end

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then
        return
    end

    local previousTarget = S.lastTarget
    local player = getLocalPlayer()
    local userId = player and player.UserId

    if not userId then
        return
    end

    S.lastTarget = newTarget
    S.lastTargetAt = t

    local getState = AutoParry.getState
    if type(getState) == "function" then
        local state = getState()

        if state then
            state.armed = newTarget == userId
        end
    end

    local isMe = newTarget == userId
    local wasMe = previousTarget == userId

    if wasMe and not isMe then
        S.wasMeTarget = true
        S.lostMeAt = t
        return
    end

    if not isMe or wasMe or not S.wasMeTarget then
        return
    end

    local ball = getBall()
    local speed = getBallSpeed(ball)
    local window = getTargetReturnWindow(speed)
    local elapsed = t - S.lostMeAt

    if elapsed <= window then
        if not S.active then
            activate(t)
        end
    end

    S.wasMeTarget = false
    S.lostMeAt = 0
end

local function onTeleport()
    local t = now()

    S.teleportLockUntil = t + C.TELEPORT_LOCK
    deactivate()
end

-- ── public ───────────────────────────────────────────────────────────────────

function AutoClash.setup(deps)
    if type(deps) ~= "table" then
        return false
    end

    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry

    if not GameInfo or not Utils or not AutoParry then
        return false
    end

    Utils.setOnClashOn(function()
        return S.active
    end)

    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(onTeleport)

    return true
end

function AutoClash.evaluate(t, hr, ball, config)
    evaluate(t, hr, ball, config)
end

function AutoClash.updateDashTrack(...)
end

function AutoClash.installAntiDashHooks()
end

function AutoClash.getState()
    return S
end

function AutoClash.clashOn()
    return S.active
end

function AutoClash.getClashAt()
    return S.activeAt
end

function AutoClash.snapshot()
    return nil
end

function AutoClash.invalidateSnapshot()
end

function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

    onTarget(
        data.TargetPlayerID or -999,
        now()
    )
end

function AutoClash.resetState()
    S.enabled = false
    S.active = false
    S.activeAt = 0

    S.lastTarget = -999
    S.lastTargetAt = 0
    S.wasMeTarget = false
    S.lostMeAt = 0

    S.timpAwaySince = 0

    S.teleportLockUntil = 0

    resetDetector()
end

function AutoClash.forceClear()
    deactivate()
end

if _G.ExodusModules then
    _G.ExodusModules.AutoClash = AutoClash
end

return AutoClash
