-- [[ auto clash ]]

local AutoClash = {}

local GameInfo
local Utils
local AutoParry

-- ── constants ────────────────────────────────────────────────────────────────

local C = {
    -- raio de ativação = parryRadius * ACT_RAD_FACTOR
    ACT_RAD_FACTOR      = 1.40,

    -- return detector (mesma lógica da v22, sem EMA = mais rápido)
    DET_RAD_MIN         = 10,    -- raio mínimo do detector
    DET_RAD_MAX         = 25,    -- raio máximo do detector
    DET_RAD_SPD_REF     = 120,   -- spd de referência pro scaling
    DET_RAD_SLACK       = 1.2,   -- folga do EMA (1.2x do raio)
    DET_DOT_THRESH      = 0.05,  -- threshold direto (sem EMA = mais sensível)
    DET_RETURN_FACTOR   = 1.5,   -- janela = entryTime * factor
    DET_TIMEOUT         = 0.8,   -- reset IDLE se não voltar a tempo

    -- target return (eu era → deixei de ser → voltei a ser)
    -- Janela adaptativa por velocidade: 290ms (spd baixa) → 190ms (spd alta)
    TARGET_RETURN_MAX_LO = 0.290,
    TARGET_RETURN_MIN_HI = 0.190,
    TARGET_RETURN_SPD_LO = 60,
    TARGET_RETURN_SPD_HI = 200,

    -- deactivate: piso de 14 studs + scaling, sempre > parryRadius
    -- 14 base + 8 studs a 120 spd (sempre acompanha o raio de parry)
    DEACT_FLOOR_BASE    = 14,
    DEACT_FLOOR_SPD_REF = 120,
    DEACT_FLOOR_K       = 0.0667, -- 8/120 → 8 studs adicionais a 120 spd

    -- deactivate por ausência de return (escalando com velocidade)
    -- Bola dentro do raio e sem return por X tempo → desativa
    DEACT_NO_RETURN_MAX_LO = 0.380,  -- 380ms @ spd baixa
    DEACT_NO_RETURN_MIN_HI = 0.200,  -- 200ms @ spd alta
    DEACT_NO_RETURN_SPD_LO = 60,
    DEACT_NO_RETURN_SPD_HI = 200,
    DEACT_RETURN_RADIUS    = 30,     -- só checa return timeout dentro desse raio

    -- hard fails
    TELEPORT_LOCK       = 0.20,
}

-- ── state ────────────────────────────────────────────────────────────────────

local S = {
    enabled  = false,
    active   = false,
    activeAt = 0,

    -- return detector (máquina de estado igual v22, sem EMA)
    detPhase     = "IDLE",   -- IDLE | INSIDE | EXITED
    detEnterAt   = 0,
    detEntryTime = 0,
    detExitAt    = 0,
    detWasInside = false,

    -- target tracking
    lastTarget   = -999,
    lastTargetAt = 0,
    wasMeTarget  = false,
    lostMeAt     = 0,

    -- deact
    lastReturnAt      = 0,
    teleportLockUntil = 0,
}

-- ── aliases ──────────────────────────────────────────────────────────────────

local function now()            return Utils.now() end
local function getLocalPlayer() return Utils.getLocalPlayer() end

local function getMyHRP()
    local lp = getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function getBall()    return GameInfo.getBall() end
local function isTargeted() return AutoParry.isTargeted() end

local function getActRadius(spd)
    local t = now()
    local base = AutoParry.computeParryRadius(spd, t)
    return base * C.ACT_RAD_FACTOR
end

-- raio do detector (igual v22: 10-25 studs baseado em spd)
local function getDetectorRadius(spd)
    local k = math.clamp(spd / C.DET_RAD_SPD_REF, 0, 1)
    return C.DET_RAD_MIN + (C.DET_RAD_MAX - C.DET_RAD_MIN) * k
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

local function resetDetector()
    S.detPhase     = "IDLE"
    S.detEnterAt   = 0
    S.detEntryTime = 0
    S.detExitAt    = 0
    S.detWasInside = false
end

local function activate(t)
    S.active         = true
    S.activeAt       = t
    S.lastReturnAt   = t
    resetDetector()
end

local function deactivate()
    S.active   = false
    S.activeAt = 0
    resetDetector()
end

-- ── return detector (v22 logic, sem EMA) ─────────────────────────────────────

-- Máquina de estado: IDLE → INSIDE → EXITED → INSIDE (signal)
-- Sem EMA: usa dotRaw direto pra ser mais rápido.
local function tickReturnDetector(t, hr, ball)
    if not (hr and hr.Parent and ball and ball.Parent) then
        S.detPhase, S.detWasInside = "IDLE", false
        return false
    end

    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then
        return false
    end

    local spd    = av.Magnitude
    local radius = getDetectorRadius(spd)
    local toMe   = hr.Position - ball.Position
    local dist   = toMe.Magnitude
    local dotRaw = av:Dot(toMe.Unit)   -- SEM EMA: dot direto

    -- fora do alcance: reseta detector
    if dist > radius * C.DET_RAD_SLACK then
        S.detPhase, S.detWasInside = "IDLE", false
        return false
    end

    local isInside  = dist <= radius
    local dotComing = dotRaw >  C.DET_DOT_THRESH
    local dotGoing  = dotRaw < -C.DET_DOT_THRESH

    -- reset de timeout na fase EXITED
    if S.detPhase == "EXITED" and (t - S.detExitAt) > C.DET_TIMEOUT then
        S.detPhase = "IDLE"
    end

    local signal = false

    if S.detPhase == "IDLE" then
        -- arm: entrou no raio OU dot já vem positivo (mesmo fora)
        if (isInside and not S.detWasInside) or (not isInside and dotComing) then
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end

    elseif S.detPhase == "INSIDE" then
        -- sai: saiu do raio OU dot going (mesmo dentro)
        if (not isInside and S.detWasInside) or (isInside and dotGoing) then
            S.detPhase  = "EXITED"
            S.detExitAt = t
        end

    elseif S.detPhase == "EXITED" then
        local delta  = t - S.detExitAt
        local limiar = S.detEntryTime * C.DET_RETURN_FACTOR

        -- volta: entrou de novo OU dot coming, dentro da janela
        if (isInside and not S.detWasInside) or dotComing then
            if delta <= limiar and dotComing then
                signal = true           -- return confirmado
                S.lastReturnAt = t
            end
            -- re-arm pra próximo ciclo
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end
    end

    S.detWasInside = isInside
    return signal
end

-- ── activation ───────────────────────────────────────────────────────────────

local function shouldActivate(t, hr, ball)
    if not (isTargeted() and hr and hr.Parent and ball and ball.Parent) then
        return false
    end

    -- return detector armado
    if tickReturnDetector(t, hr, ball) then return true end

    return false
end

-- ── deactivation ─────────────────────────────────────────────────────────────
-- O gate de desativação é o timeout de "no return".
-- O piso (14 + 8*(spd/120)) é só a distância mínima que a bola precisa estar
-- pra esse gate ser considerado. NÃO é um trigger imediato.

local function getDeactFloor(spd)
    local k = math.clamp(spd / C.DEACT_FLOOR_SPD_REF, 0, 2.5)
    return C.DEACT_FLOOR_BASE + 8 * k
end

local function noReturnTimeout(spd)
    local u = math.clamp((spd - C.DEACT_NO_RETURN_SPD_LO) / (C.DEACT_NO_RETURN_SPD_HI - C.DEACT_NO_RETURN_SPD_LO), 0, 1)
    return C.DEACT_NO_RETURN_MAX_LO + (C.DEACT_NO_RETURN_MIN_HI - C.DEACT_NO_RETURN_MAX_LO) * u
end

local function shouldDeactivate(t, hr, ball)
    if t < S.teleportLockUntil then return true end
    if not (ball and ball.Parent and hr and hr.Parent) then return true end

    local dist = (hr.Position - ball.Position).Magnitude
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
    local floor = getDeactFloor(spd)

    -- dentro do piso: não desativa (bola ainda na zona ativa)
    if dist <= floor then return false end

    -- além do piso: gate é o timeout de no-return
    local timeout = noReturnTimeout(spd)
    if (t - S.lastReturnAt) > timeout then return true end

    return false
end

-- ── evaluate ─────────────────────────────────────────────────────────────────

local function evaluate(t, hr, ball, config)
    if not config or config.AutoClash == false or _G.PhantomManual then
        S.enabled = false
        deactivate()
        return
    end

    if GameInfo.isGrace() then
        deactivate()
        return
    end

    S.enabled = true

    -- hard fails
    if not (hr and hr.Parent and ball and ball.Parent) then
        deactivate()
        return
    end
    if t < S.teleportLockUntil then
        deactivate()
        return
    end

    -- uma vez ativo: mantém o detector tickando, mas não desativa fácil
    if S.active then
        tickReturnDetector(t, hr, ball)
        if shouldDeactivate(t, hr, ball) then deactivate() end
        return
    end

    -- inativo: tenta ativar via detector
    if shouldActivate(t, hr, ball) then activate(t) end
end

-- ── callbacks ────────────────────────────────────────────────────────────────

-- Janela do target return adaptativa à velocidade da bola
local function targetReturnWindow(spd)
    local u = math.clamp((spd - C.TARGET_RETURN_SPD_LO) / (C.TARGET_RETURN_SPD_HI - C.TARGET_RETURN_SPD_LO), 0, 1)
    return C.TARGET_RETURN_MAX_LO + (C.TARGET_RETURN_MIN_HI - C.TARGET_RETURN_MAX_LO) * u
end

-- Target return: se eu era target → deixei de ser → voltei a ser dentro da janela
local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end

    local prevTarget = S.lastTarget
    local lp         = getLocalPlayer()
    local myId       = lp and lp.UserId or -1

    S.lastTarget   = newTarget
    S.lastTargetAt = t

    local ap = AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == myId) end

    local isMe  = (newTarget == myId)
    local wasMe = (prevTarget == myId)

    -- rastrear quando deixei de ser target
    if wasMe and not isMe then
        S.lostMeAt    = t
        S.wasMeTarget = true
    end

    -- target return: voltei a ser target depois de ter perdido
    if isMe and not wasMe and S.wasMeTarget then
        -- janela adaptativa por velocidade da bola
        local spd = 0
        local ball = getBall()
        if ball and ball.Parent then
            local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
            if ok and typeof(av) == "Vector3" then spd = av.Magnitude end
        end
        local win = targetReturnWindow(spd)

        local gap = t - (S.lostMeAt or 0)
        if gap <= win then
            if not S.active then activate(t) end
            S.lastReturnAt = t
        end
        S.wasMeTarget = false
        S.lostMeAt    = 0
    end
end

local function onTeleport()
    local t = now()
    S.teleportLockUntil = t + C.TELEPORT_LOCK
    deactivate()
end

-- ── public ───────────────────────────────────────────────────────────────────

function AutoClash.setup(deps)
    GameInfo = deps.GameInfo
    Utils    = deps.Utils
    AutoParry = deps.AutoParry

    Utils.setOnClashOn(function() return S.active end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(onTeleport)
end

function AutoClash.evaluate(t, hr, ball, config)
    evaluate(t, hr, ball, config)
end

function AutoClash.updateDashTrack(...)    end
function AutoClash.installAntiDashHooks()  end
function AutoClash.getState()              return S end
function AutoClash.clashOn()               return S.active end
function AutoClash.getClashAt()            return S.activeAt end
function AutoClash.snapshot()              return nil end
function AutoClash.invalidateSnapshot()    end

function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then return end
    onTarget(data.TargetPlayerID or -999, now())
end

function AutoClash.resetState()
    S.enabled = false
    S.active, S.activeAt = false, 0
    S.lastTarget, S.lastTargetAt = -999, 0
    S.wasMeTarget, S.lostMeAt = false, 0
    S.lastReturnAt, S.teleportLockUntil = 0, 0
    resetDetector()
end

function AutoClash.forceClear() deactivate() end

if _G.ExodusModules then _G.ExodusModules.AutoClash = AutoClash end
return AutoClash
