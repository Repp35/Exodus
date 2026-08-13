-- [[ auto clash ]]

local AutoClash = {}

local GameInfo
local Utils
local AutoParry

-- ── constants ────────────────────────────────────────────────────────────────

local C = {
    -- raio de ativação = parryRadius * ACT_RAD_FACTOR
    ACT_RAD_FACTOR      = 1.30,

    -- return detector (global, sem raio mínimo pra detectar)
    DET_DOT_EMA         = 0.15,   -- EMA pequeno = mais rápido, menos suavização
    DET_DOT_THRESH      = 0.12,   -- dot mínimo pra considerar "vindo"
    DET_RETURN_FACTOR   = 2.0,    -- janela = entryTime * factor (adaptativa por spd)
    DET_TIMEOUT         = 1.20,   -- tempo até resetar pra IDLE se não houver retorno
    DET_GLOBAL_RANGE    = 40,     -- alcance global de detecção de return

    -- target return
    TARGET_GAP_MIN      = 0.02,   -- filtra sync duplicado
    TARGET_GAP_MAX      = 0.28,   -- janela máxima de return

    -- invisible gate
    INV_DOT_MIN         = 0.30,   -- dot mínimo da bola em direção a você
    INV_SPD_MIN         = 50,     -- velocidade mínima da bola

    -- deativação por ausência de return (adaptativo por velocidade)
    DEACT_RETURN_BASE   = 0.40,   -- timeout base em segundos
    DEACT_RETURN_SPD_REF = 120,   -- velocidade de referência pro factor
    DEACT_GONE_DIST     = 65,     -- bola sumida = desativa imediato
    TELEPORT_LOCK       = 0.20,
}

-- ── state ────────────────────────────────────────────────────────────────────

local S = {
    enabled  = false,
    active   = false,
    activeAt = 0,

    -- return detector
    detPhase     = "IDLE",  -- IDLE | INSIDE | EXITED
    detEnterAt   = 0,
    detEntryTime = 0,
    detExitAt    = 0,
    detDotEma    = 0,
    detWasInside = false,

    -- target
    lastTarget   = -999,
    lastTargetAt = 0,

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

local function deactReturnTimeout(spd)
    if spd < 1 then return C.DEACT_RETURN_BASE end
    -- bola rápida = timeout menor, bola lenta = timeout maior
    local scale = math.clamp(C.DEACT_RETURN_SPD_REF / spd, 0.4, 2.0)
    return C.DEACT_RETURN_BASE * scale
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

local function resetDetector()
    S.detPhase     = "IDLE"
    S.detEnterAt   = 0
    S.detEntryTime = 0
    S.detExitAt    = 0
    S.detDotEma    = 0
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

-- ── return detector (global + armado) ────────────────────────────────────────

-- Detecta return globalmente (fora do raio). 
-- Quando detecta, fica "armado" e retorna true quando entra no raio.
local function tickReturnDetector(t, hr, ball)
    if not (hr and hr.Parent and ball and ball.Parent) then
        resetDetector()
        return false
    end

    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then
        return false
    end

    local spd  = av.Magnitude
    local toMe = hr.Position - ball.Position
    local dist = toMe.Magnitude
    if dist < 0.001 then return false end

    local dotRaw = av:Dot(toMe.Unit)   -- positivo = vindo em direção a você

    -- EMA acumula dentro do alcance global; fora zera imediato
    if dist <= C.DET_GLOBAL_RANGE then
        S.detDotEma = S.detDotEma * (1 - C.DET_DOT_EMA) + dotRaw * C.DET_DOT_EMA
    else
        S.detDotEma = 0
    end

    local dotComing = S.detDotEma >  C.DET_DOT_THRESH
    local dotGoing  = S.detDotEma < -C.DET_DOT_THRESH

    local actRadius = getActRadius(spd)
    local isInside  = dist <= actRadius

    -- reset de timeout na fase EXITED
    if S.detPhase == "EXITED" and (t - S.detExitAt) > C.DET_TIMEOUT then
        S.detPhase = "IDLE"
    end

    local signal = false

    if S.detPhase == "IDLE" then
        -- arm: detecta inversão global (dot passa de negativo pra positivo)
        if dotComing and not S.detWasInside then
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end

    elseif S.detPhase == "INSIDE" then
        -- sai: dot negativo ou se afastando
        if dotGoing then
            S.detPhase  = "EXITED"
            S.detExitAt = t
        end

    elseif S.detPhase == "EXITED" then
        local delta  = t - S.detExitAt
        local limiar = S.detEntryTime * C.DET_RETURN_FACTOR

        -- volta: dot positivo novamente dentro da janela
        if dotComing then
            if delta <= limiar then
                -- return confirmado, reinicia o ciclo com dados atuais
                S.detPhase     = "INSIDE"
                S.detEnterAt   = t
                S.detEntryTime = dist > 0.1 and (dist / spd) or 0.01
            end
        end
    end

    S.detWasInside = isInside

    -- ativa quando return está armado E bola entrou no raio
    if S.detPhase == "INSIDE" and isInside and dotComing then
        signal = true
        S.lastReturnAt = t
    end

    return signal
end

-- ── invisible gate ───────────────────────────────────────────────────────────

local function invisibleGate(hr, ball, spd)
    if not isTargeted() then return false end
    if spd < C.INV_SPD_MIN then return false end

    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return false end

    local toMe = hr.Position - ball.Position
    if toMe.Magnitude < 0.1 then return true end

    local dot = av:Dot(toMe.Unit) / av.Magnitude
    return dot >= C.INV_DOT_MIN
end

-- ── activation ───────────────────────────────────────────────────────────────

local function shouldActivate(t, hr, ball)
    -- return detector: não precisa de targeted (detector já filtra por raio)
    if tickReturnDetector(t, hr, ball) then
        if isTargeted() then return true end
    end

    if not isTargeted() then return false end

    -- invisible gate: targeted + bola rápida vindo em direção a você
    if ball and ball.Parent then
        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        if ok and typeof(av) == "Vector3" then
            if invisibleGate(hr, ball, av.Magnitude) then return true end
        end
    end

    return false
end

-- ── deactivation ─────────────────────────────────────────────────────────────

local function shouldDeactivate(t, hr, ball)
    -- hard: teleporte
    if t < S.teleportLockUntil then return true end

    -- hard: bola sumiu ou não existe
    if not (ball and ball.Parent and hr and hr.Parent) then return true end

    local dist = (hr.Position - ball.Position).Magnitude
    if dist > C.DEACT_GONE_DIST then return true end

    -- soft: sem return por tempo adaptativo à velocidade da bola
    -- continua o detector durante o clash pra atualizar lastReturnAt
    tickReturnDetector(t, hr, ball)

    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
    local timeout = deactReturnTimeout(spd)

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

    if S.active then
        if shouldDeactivate(t, hr, ball) then deactivate() end
        return
    end

    if hr and hr.Parent then
        if shouldActivate(t, hr, ball) then activate(t) end
    end
end

-- ── callbacks ────────────────────────────────────────────────────────────────

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end

    local prevTarget   = S.lastTarget
    local prevTargetAt = S.lastTargetAt
    S.lastTarget   = newTarget
    S.lastTargetAt = t

    local ap = AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == Utils.getLocalPlayer().UserId) end

    -- target return: voltou pra mim dentro da janela
    local cameBackToMe = newTarget == Utils.getLocalPlayer().UserId
        and prevTarget ~= Utils.getLocalPlayer().UserId
        and prevTarget ~= -999

    if not cameBackToMe then return end

    local gap = t - (prevTargetAt or 0)
    if gap < C.TARGET_GAP_MIN or gap > C.TARGET_GAP_MAX then return end

    -- ativa direto e registra return
    if not S.active then activate(t) end
    S.lastReturnAt = t
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
    S.lastReturnAt, S.teleportLockUntil = 0, 0
    resetDetector()
end

function AutoClash.forceClear() deactivate() end

if _G.ExodusModules then _G.ExodusModules.AutoClash = AutoClash end
return AutoClash
