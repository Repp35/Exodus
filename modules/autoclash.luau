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

    -- NOVO: desativação por histerese target + tImp
    -- target precisa estar fora por 250ms (espelho + folga da ativação)
    -- E a bola precisa estar se afastando (tImp < 0) por 100ms contínuos
    DEACT_TARGET_LOST_T = 0.250,
    DEACT_TIMP_AWAY_T   = 0.100,

    -- fallback se AutoParry não responder
    PARRY_RAD_FALLBACK = 14,

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

    -- NOVO: timers da histerese de desativação
    targetLostAt   = 0, -- 0 = target ainda em mim
    timpAwaySince  = 0, -- 0 = bola não está se afastando

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

    -- zera timers de desativação
    S.targetLostAt = 0
    S.timpAwaySince = 0

    resetDetector()
end

local function deactivate()
    S.active = false
    S.activeAt = 0

    -- zera timers
    S.targetLostAt = 0
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

-- pega raio de parry real do AutoParry (com fallback)
local function getParryRadius(speed, t)
    local parryRadius = C.PARRY_RAD_FALLBACK
    if AutoParry and type(AutoParry.getParryRadius) == "function" then
        local v = AutoParry.getParryRadius(speed, t)
        if type(v) == "number" and v > 0 then
            parryRadius = v
        end
    end
    return parryRadius
end

-- calcula tImp igual ao AutoParry: (dist - parryRad) / speed
-- tImp < 0 = bola já passou de mim, está se afastando
local function computeTImp(hr, ball, speed)
    local parryRad = getParryRadius(speed, now())
    local dist = (hr.Position - ball.Position).Magnitude
    local tImp = (dist - parryRad) / speed
    if tImp < 0 then tImp = 0 end
    return tImp, parryRad
end

-- histerese dupla: target perdido + bola se afastando
local function shouldDeactivate(t, hr, ball)
    -- hard fails (sempre desativa, sem histerese)
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
        -- bola parada, sem clash possível
        return true
    end

    local tImp, parryRad = computeTImp(hr, ball, speed)
    local distance = (hr.Position - ball.Position).Magnitude

    -- "se afastando de verdade" = bola passou do parry radius E está
    -- a uma distância significativamente maior (não é só uma oscilação
    -- na borda). Evita desativar no meio do clash quando a bola vai
    -- e volta do rebatedor.
    local farFromParry = distance > parryRad * 1.5
    local timpIsAway = tImp < 0 and farFromParry

    -- ── Timer 1: target perdido ───────────────────────────────────────────
    if isTargeted() then
        S.targetLostAt = 0
    else
        if S.targetLostAt == 0 then
            S.targetLostAt = t
        end
    end

    -- ── Timer 2: bola se afastando (tImp < 0) CONSISTENTEMENTE ──────────
    -- reseta se tImp >= 0 em qualquer frame (bola voltou a vir em minha direção)
    if tImp < 0 then
        if S.timpAwaySince == 0 then
            S.timpAwaySince = t
        end
    else
        S.timpAwaySince = 0
    end

    -- ── Decisão: ambos precisam estar "velhos" ao mesmo tempo ───────────
    local targetLostFor = (S.targetLostAt > 0) and (t - S.targetLostAt) or 0
    local timpAwayFor   = (S.timpAwaySince > 0) and (t - S.timpAwaySince) or 0

    if targetLostFor >= C.DEACT_TARGET_LOST_T
        and timpAwayFor >= C.DEACT_TIMP_AWAY_T
    then
        return true
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

        -- target saiu: começa a contar para desativação
        if S.active and S.targetLostAt == 0 then
            S.targetLostAt = t
        end

        return
    end

    if not isMe or wasMe or not S.wasMeTarget then
        return
    end

    -- target voltou pra mim: zera timer de desativação
    if S.active then
        S.targetLostAt = 0
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

    S.targetLostAt = 0
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
