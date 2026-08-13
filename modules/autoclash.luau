-- [[ auto clash ]]

local AutoClash = {}
local GameInfo, Utils, AutoParry

local C = {
    DET_RAD_FLOOR     = 18,
    DET_RAD_CEIL      = 45,
    DET_RAD_SPD_K     = 0.08,

    TRAJ_DOT_THRESH   = 0.12,
    TRAJ_WIN_STUDS    = 40,
    TRAJ_WIN_FACTOR   = 1.5,
    TRAJ_WIN_SPD_REF  = 120,

    TARGET_GAP_MIN    = 0.02,
    TARGET_GAP_MAX    = 0.28,

    TELEPORT_LOCK     = 0.20,

    -- soft-deactivate: tempo máximo sem nenhum return antes de desligar
    -- escala com a velocidade: 40 spd precisa de janela generosa,
    -- 600 spd precisa de janela curta (cada frame é ~16ms)
    DEACT_TIMEOUT_MIN = 0.18,   -- piso (bola lenta / parada)
    DEACT_TIMEOUT_MAX = 0.45,   -- teto (bola lenta andando)
    DEACT_TIMEOUT_SPD_REF = 80, -- abaixo disso usa o teto, acima escala
    DEACT_TIMEOUT_SPD_FAST = 400, -- acima disso usa o piso

    CLASH_HARD_MAX    = 1.4,    -- trava de segurança: nunca passa disso
}

local S = {
    lastTarget        = -999,
    lastTargetAt      = 0,
    clashOn           = false,
    clashAt           = 0,
    teleportLockUntil = 0,

    dotPrev           = nil,
    dotConfirm        = 0,
    returnAt          = 0,
    returnSpd         = 0,

    detSignalTraj     = false,
    detSignalTarget   = false,
    deactSoftHit      = 0,

    -- soft-deactivate: último return detectado (traj ou target)
    -- o clash se mantém enquanto (t - lastReturnAt) <= timeout
    lastReturnAt      = 0,
    lastReturnSpd     = 0,
}

local _localUserId = -1
local _ctxCache = {
    t = 0,
    valid = false,
}

local SNAPSHOT_TTL = 0.05

-- ── helpers ──────────────────────────────────────────────────────────────────

local function parryBonus()
    return AutoParry
        and AutoParry.resRadiusBonus
        and AutoParry.resRadiusBonus()
        or 0
end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character

    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted()
    return AutoParry
        and AutoParry.isTargeted
        and AutoParry.isTargeted()
        or false
end

local function getParryRadius()
    local p = AutoParry
        and AutoParry.getP
        and AutoParry.getP()
        or nil

    return (p and p.DEFLECT_R or 8.5) + parryBonus()
end

local function getDetRadius(spd)
    return math.clamp(
        getParryRadius() + (spd or 0) * C.DET_RAD_SPD_K,
        C.DET_RAD_FLOOR,
        C.DET_RAD_CEIL
    )
end

-- ── snapshot ─────────────────────────────────────────────────────────────────

local function clashSnapshot()
    local t = Utils.now()

    if _ctxCache.valid
        and (t - _ctxCache.t) < SNAPSHOT_TTL
        and _ctxCache.hr
        and _ctxCache.hr.Parent
        and _ctxCache.ball
        and _ctxCache.ball.Parent then
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

    local spd, dot = 0, 0

    local ok, av = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if ok and typeof(av) == "Vector3" and av.Magnitude > 0.1 then
        spd = av.Magnitude

        local toMe = hr.Position - ball.Position
        local dist = toMe.Magnitude

        if dist > 0.1 then
            dot = av:Dot(toMe.Unit) / spd
        end
    end

    local tImp = math.huge
    local s2 = spd

    local live = GameInfo.liveTImp()

    if live then
        tImp = tonumber(live.tImp) or math.huge
        s2 = tonumber(live.spd) or spd
    end

    if s2 < 1 then
        local ti, _, s3 = GameInfo.computeTImp(hr, ball, t)

        if ti then
            tImp = ti
        end

        if s3 and s3 > s2 then
            s2 = s3
        end
    end

    local hp = hr.Position
    local bp = ball.Position
    local bDist = (hp - bp).Magnitude

    _ctxCache.t = t
    _ctxCache.valid = true
    _ctxCache.hr = hr
    _ctxCache.ball = ball
    _ctxCache.spd = s2
    _ctxCache.bDist = bDist
    _ctxCache.dot = dot
    _ctxCache.tImp = tImp
    _ctxCache.targeted = isTargeted()

    return _ctxCache
end

-- ── trajectory ───────────────────────────────────────────────────────────────

local function resetTraj()
    S.dotPrev = nil
    S.dotConfirm = 0
    S.returnAt = 0
    S.returnSpd = 0
    S.detSignalTraj = false
end

local function returnWindow(spd)
    if spd < 1 then
        return 0.8
    end

    local scale = math.clamp(
        C.TRAJ_WIN_SPD_REF / spd,
        0.4,
        2.0
    )

    return (C.TRAJ_WIN_STUDS / spd)
        * C.TRAJ_WIN_FACTOR
        * scale
end

local function tickTrajectory(t, hr, ball, ctx)
    S.detSignalTraj = false

    if not (hr and hr.Parent and ball and ball.Parent) then
        resetTraj()
        return
    end

    ctx = ctx or _ctxCache

    local dot = ctx.valid and ctx.dot or 0
    local spd = ctx.valid and ctx.spd or 0
    local dist = ctx.valid and ctx.bDist or 0

    if S.dotPrev == nil then
        S.dotPrev = dot
        return
    end

    local prev = S.dotPrev
    S.dotPrev = dot

    if prev < -C.TRAJ_DOT_THRESH
        and dot > C.TRAJ_DOT_THRESH then

        S.dotConfirm = 1
        S.returnAt = t
        S.returnSpd = spd

        -- feed do soft-deactivate: a bola voltou pra você
        S.lastReturnAt = t
        S.lastReturnSpd = spd

        return
    end

    if S.dotConfirm == 1 then
        if dot > C.TRAJ_DOT_THRESH then
            S.dotConfirm = 2
        else
            S.dotConfirm = 0
            S.returnAt = 0
        end
    end

    if S.dotConfirm >= 2 and S.returnAt > 0 then
        local elapsed = t - S.returnAt
        local window = returnWindow(S.returnSpd)
        local radius = getDetRadius(spd)

        if elapsed > window then
            S.dotConfirm = 0
            S.returnAt = 0
        elseif dist <= radius and dot > C.TRAJ_DOT_THRESH then
            S.detSignalTraj = true
        end
    end
end

-- ── clash state ──────────────────────────────────────────────────────────────

local function clearClash()
    S.clashOn = false
    S.clashAt = 0
    S.deactSoftHit = 0
    S.detSignalTarget = false
    S.lastReturnAt = 0
    S.lastReturnSpd = 0

    resetTraj()

    _ctxCache.valid = false
end

local function activateClash(t)
    S.clashOn = true
    S.clashAt = t
    S.deactSoftHit = 0
    S.detSignalTarget = false
    -- começa "alimentado": qualquer return imediato reativa o timer,
    -- mas se nenhum return chegar, o soft já começa a contar
    S.lastReturnAt = t
    S.lastReturnSpd = 0

    resetTraj()

    _ctxCache.valid = false
end

local function onTeleport()
    local t = Utils.now()

    S.teleportLockUntil = t + C.TELEPORT_LOCK

    clearClash()
end

-- ── deactivation ─────────────────────────────────────────────────────────────

-- timeout = tempo máximo esperado entre dois returns consecutivos num clash real
-- escala com a velocidade da bola: bola rápida troca de direção mais rápido,
-- então timeout menor. bola lenta / parada usa o teto.
local function returnTimeout(spd)
    if spd <= 0 or spd < C.DEACT_TIMEOUT_SPD_REF then
        return C.DEACT_TIMEOUT_MAX
    end

    if spd >= C.DEACT_TIMEOUT_SPD_FAST then
        return C.DEACT_TIMEOUT_MIN
    end

    -- interpolação linear entre ref e fast
    local k = (spd - C.DEACT_TIMEOUT_SPD_REF)
        / (C.DEACT_TIMEOUT_SPD_FAST - C.DEACT_TIMEOUT_SPD_REF)

    return C.DEACT_TIMEOUT_MAX
        + (C.DEACT_TIMEOUT_MIN - C.DEACT_TIMEOUT_MAX) * k
end

local function shouldDeactivate(t, ctx)
    if not S.clashOn then
        return false
    end

    -- hard: trava de segurança — clash nunca dura mais que isso
    if (t - S.clashAt) > C.CLASH_HARD_MAX then
        return true
    end

    -- hard: bola sumiu do mundo
    if not (ctx and ctx.ball and ctx.ball.Parent) then
        return true
    end

    -- hard: bola muito longe (> 60 studs) — fora de qualquer clash real
    if ctx.bDist and ctx.bDist > 60 then
        return true
    end

    -- hard: teleporte recente
    if S.teleportLockUntil and t < S.teleportLockUntil then
        return true
    end

    -- soft: passou do timeout desde o último return detectado
    -- se nunca houve return, usa spd atual pra calcular a janela
    if S.lastReturnAt <= 0 then
        return false
    end

    local spd = S.lastReturnSpd
    if not spd or spd < 1 then
        spd = (ctx and ctx.spd) or 0
    end

    local timeout = returnTimeout(spd)
    local silent = t - S.lastReturnAt

    return silent > timeout
end

-- ── activation ───────────────────────────────────────────────────────────────

local function shouldActivate(t, ctx)
    if not (S.detSignalTraj or S.detSignalTarget) then
        return false
    end

    return (ctx and ctx.targeted) or isTargeted()
end

-- ── evaluate ─────────────────────────────────────────────────────────────────

local function evaluateClash(t, hr, ball, config)
    if not config
        or config.AutoClash == false
        or _G.PhantomManual then

        if S.clashOn then
            clearClash()
        end

        return
    end

    if GameInfo.isGrace() then
        if S.clashOn then
            clearClash()
        end

        return
    end

    local ctx = clashSnapshot()

    tickTrajectory(t, hr, ball, ctx)

    if S.clashOn then
        if shouldDeactivate(t, ctx) then
            clearClash()
        end

        return
    end

    if shouldActivate(t, ctx) then
        activateClash(t)
    end
end

-- ── target handler ───────────────────────────────────────────────────────────

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then
        return
    end

    local prevTarget = S.lastTarget
    local prevTargetAt = S.lastTargetAt

    S.lastTarget = newTarget
    S.lastTargetAt = t

    local ap = AutoParry
        and AutoParry.getState
        and AutoParry.getState()
        or nil

    if ap then
        ap.armed = newTarget == _localUserId
    end

    _ctxCache.valid = false

    local cameBackToMe =
        newTarget == _localUserId
        and prevTarget ~= _localUserId
        and prevTarget ~= -999

    if not cameBackToMe then
        return
    end

    local gap = t - (prevTargetAt or 0)

    if gap < C.TARGET_GAP_MIN
        or gap > C.TARGET_GAP_MAX then
        return
    end

    S.detSignalTarget = true

    -- feed do soft-deactivate: a bola voltou pra você via troca de target
    local liveSpd = (_ctxCache.valid and _ctxCache.spd) or 0
    S.lastReturnAt = t
    S.lastReturnSpd = liveSpd
end

-- ── public ───────────────────────────────────────────────────────────────────

function AutoClash.setup(deps)
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry

    _localUserId = Utils.getLocalPlayer().UserId

    Utils.setOnClashOn(function()
        return S.clashOn
    end)

    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(onTeleport)
end

function AutoClash.evaluate(t, hr, ball, config)
    evaluateClash(t, hr, ball, config)
end

function AutoClash.updateDashTrack(t)
end

function AutoClash.installAntiDashHooks()
end

function AutoClash.getState()
    return S
end

function AutoClash.clashOn()
    return S.clashOn
end

function AutoClash.getClashAt()
    return S.clashAt
end

function AutoClash.snapshot()
    return clashSnapshot()
end

function AutoClash.invalidateSnapshot()
    _ctxCache.valid = false
end

function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

    local t = Utils.now()

    onTarget(data.TargetPlayerID or -999, t)
end

function AutoClash.resetState()
    S.clashOn = false
    S.clashAt = 0
    S.teleportLockUntil = 0
    S.deactSoftHit = 0
    S.lastTarget = -999
    S.lastTargetAt = 0
    S.detSignalTarget = false
    S.lastReturnAt = 0
    S.lastReturnSpd = 0

    resetTraj()

    _ctxCache.valid = false
end

function AutoClash.forceClear()
    clearClash()
end

if _G.ExodusModules then
    _G.ExodusModules.AutoClash = AutoClash
end

return AutoClash