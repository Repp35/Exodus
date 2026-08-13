-- [[ auto clash ]]

local AutoClash = {}
local GameInfo, Utils, AutoParry

local C = {
    -- raio de detecção (parry radius + piso)
    DET_RAD_FLOOR        = 18,
    DET_RAD_CEIL         = 45,
    DET_RAD_SPD_K        = 0.08,   -- cresce devagar com velocidade

    -- trajectory: detecção de return por dot
    TRAJ_DOT_THRESH      = 0.12,   -- dot mínimo pra confirmar inversão (2 frames)
    TRAJ_WIN_STUDS       = 40,     -- janela base em studs (dividido pela spd = janela em tempo)
    TRAJ_WIN_FACTOR      = 1.5,    -- multiplicador base da janela (afrouxa em spd baixa)
    TRAJ_WIN_SPD_REF     = 120,    -- velocidade de referência pro factor

    -- target return: janela temporal
    TARGET_GAP_MIN       = 0.02,   -- filtra sync duplicado
    TARGET_GAP_MAX       = 0.45,   -- acima disso não é return

    -- deativação
    DEACT_OUT_FRAMES     = 2,
    DEACT_RAD_MIN        = 14,

    -- sync gate (panic)
    ACT_HARD_CAP         = 22,
    ACT_TIMP_FAST        = 0.085,
}

local S = {
    lastTarget   = -999, lastTargetAt = 0,
    clashOn      = false, clashAt = 0,
    ballGoneSince = 0, outOfRangeFrames = 0,

    -- trajectory state
    dotPrev      = nil,   -- dot do frame anterior
    dotConfirm   = 0,     -- frames consecutivos com dot positivo após inversão
    returnAt     = 0,     -- quando detectou o return
    returnSpd    = 0,     -- velocidade no momento do return
    detSignal    = false,
}

local _localUserId = -1
local _ctxCache    = { t = 0, valid = false }
local SNAPSHOT_TTL = 0.05

-- ── helpers ──────────────────────────────────────────────────────────────────

local function parryBonus()
    return AutoParry and AutoParry.resRadiusBonus and AutoParry.resRadiusBonus() or 0
end

local function getMyHRP()
    local lp = Utils.getLocalPlayer()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function isTargeted()
    return AutoParry and AutoParry.isTargeted and AutoParry.isTargeted() or false
end

local function getParryRadius()
    local p = AutoParry and AutoParry.getP and AutoParry.getP() or nil
    return (p and p.DEFLECT_R or 8.5) + parryBonus()
end

local function getDetRadius(spd)
    return math.clamp(getParryRadius() + (spd or 0) * C.DET_RAD_SPD_K, C.DET_RAD_FLOOR, C.DET_RAD_CEIL)
end

local function getDeactRadius()
    return math.max(getParryRadius(), C.DEACT_RAD_MIN)
end

-- ── snapshot ─────────────────────────────────────────────────────────────────

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

    local spd, dot = 0, 0
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if ok and typeof(av) == "Vector3" and av.Magnitude > 0.1 then
        spd = av.Magnitude
        local toMe = hr.Position - ball.Position
        local dist = toMe.Magnitude
        if dist > 0.1 then dot = av:Dot(toMe.Unit) / spd end  -- cosToward normalizado
    end

    local tImp, s2 = math.huge, spd
    local live = GameInfo.liveTImp()
    if live then
        tImp = tonumber(live.tImp) or math.huge
        s2   = tonumber(live.spd) or spd
    end
    if s2 < 1 then
        local ti, _, s3 = GameInfo.computeTImp(hr, ball, t)
        tImp = ti or tImp
    end

    local hp, bp = hr.Position, ball.Position
    local bDist  = (hp - bp).Magnitude

    _ctxCache.t, _ctxCache.valid  = t, true
    _ctxCache.hr, _ctxCache.ball  = hr, ball
    _ctxCache.spd, _ctxCache.bDist = spd, bDist
    _ctxCache.dot, _ctxCache.tImp  = dot, tImp
    _ctxCache.targeted             = isTargeted()
    return _ctxCache
end

-- ── trajectory ───────────────────────────────────────────────────────────────

local function resetTraj()
    S.dotPrev    = nil
    S.dotConfirm = 0
    S.returnAt   = 0
    S.returnSpd  = 0
    S.detSignal  = false
end

local function returnWindow(spd)
    -- janela em segundos: base de studs / spd, escalada pelo factor
    -- em spd alta o factor aperta (menos tempo), em spd baixa afrouxa
    if spd < 1 then return 0.8 end
    local scale = math.clamp(C.TRAJ_WIN_SPD_REF / spd, 0.4, 2.0)
    return (C.TRAJ_WIN_STUDS / spd) * C.TRAJ_WIN_FACTOR * scale
end

local function tickTrajectory(t, hr, ball, ctx)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        resetTraj(); return
    end

    ctx = ctx or _ctxCache
    local dot = ctx.valid and ctx.dot or 0
    local spd = ctx.valid and ctx.spd or 0
    local dist = ctx.valid and ctx.bDist or 0

    -- primeiro frame: só inicializa
    if S.dotPrev == nil then
        S.dotPrev = dot; return
    end

    local prev = S.dotPrev
    S.dotPrev  = dot

    -- detecta inversão: bola ia embora (dot < 0) e agora vem (dot > thresh)
    -- exige 2 frames consecutivos pra confirmar (filtra ruído de 1 frame)
    if prev < -C.TRAJ_DOT_THRESH and dot > C.TRAJ_DOT_THRESH then
        -- inversão detectada neste frame — começa contagem de confirmação
        S.dotConfirm = 1
        S.returnAt   = t
        S.returnSpd  = spd
        return
    end

    if S.dotConfirm == 1 then
        if dot > C.TRAJ_DOT_THRESH then
            -- segundo frame confirmado: return real
            S.dotConfirm = 2
        else
            -- não confirmou: cancela
            S.dotConfirm = 0
            S.returnAt   = 0
        end
    end

    -- return confirmado: verifica se ainda está na janela e no raio
    if S.dotConfirm >= 2 and S.returnAt > 0 then
        local elapsed = t - S.returnAt
        local window  = returnWindow(S.returnSpd)
        local radius  = getDetRadius(spd)

        if elapsed > window then
            -- janela expirou: descarta return
            S.dotConfirm = 0
            S.returnAt   = 0
        elseif dist <= radius and dot > C.TRAJ_DOT_THRESH then
            -- dentro do raio, ainda vindo: ativa
            S.detSignal = true
        end
    end
end

-- ── clash ────────────────────────────────────────────────────────────────────

local function clearClash()
    S.clashOn, S.clashAt = false, 0
    S.ballGoneSince, S.outOfRangeFrames = 0, 0
    resetTraj()
    _ctxCache.valid = false
end

local function activateClash(t)
    S.clashOn, S.clashAt = true, t
    S.ballGoneSince, S.outOfRangeFrames = 0, 0
    resetTraj()
    _ctxCache.valid = false
end

local function shouldDeactivate(t, ctx)
    if not ctx then return false end
    local isOut = ctx.bDist > getDeactRadius()
    S.outOfRangeFrames = isOut and (S.outOfRangeFrames + 1) or 0
    return S.outOfRangeFrames >= C.DEACT_OUT_FRAMES
end

local function shouldActivate(t, ctx, targetJustChangedToMe)
    -- gate 1: trajectory confirmou return
    if S.detSignal then return true end

    -- gates abaixo precisam de targeted
    if not (ctx and (ctx.targeted or isTargeted())) then return false end
    if not (ctx and ctx.bDist) then return false end

    -- gate 2: sync panic (target mudou + bola perto + impacto iminente)
    if targetJustChangedToMe then
        if ctx.bDist <= C.ACT_HARD_CAP
            and ctx.tImp > 0
            and ctx.tImp <= C.ACT_TIMP_FAST then
            return true
        end
    end

    return false
end

-- ── evaluate ─────────────────────────────────────────────────────────────────

local function evaluateClash(t, hr, ball, config, targetJustChangedToMe)
    if not config or config.AutoClash == false or _G.PhantomManual then
        if S.clashOn then clearClash() end; return
    end
    if GameInfo.isGrace() then
        if S.clashOn then clearClash() end; return
    end

    local ctx = clashSnapshot()
    tickTrajectory(t, hr, ball, ctx)

    if S.clashOn then
        if shouldDeactivate(t, ctx) then clearClash() end
        return
    end

    if shouldActivate(t, ctx, targetJustChangedToMe) then activateClash(t) end
end

-- ── target handler ───────────────────────────────────────────────────────────

local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then return end
    local prevTarget, prevTargetAt = S.lastTarget, S.lastTargetAt
    S.lastTarget, S.lastTargetAt = newTarget, t

    local ap = AutoParry and AutoParry.getState and AutoParry.getState() or nil
    if ap then ap.armed = (newTarget == _localUserId) end
    _ctxCache.valid = false

    -- target return: voltou pra mim dentro da janela temporal
    local cameBackToMe = (newTarget == _localUserId)
        and (prevTarget ~= _localUserId)
        and (prevTarget ~= -999)
    if not cameBackToMe then return end

    local gap = t - (prevTargetAt or 0)
    if gap < C.TARGET_GAP_MIN or gap > C.TARGET_GAP_MAX then return end

    -- ativa direto, sem checks de física
    activateClash(t)
end

-- ── public ───────────────────────────────────────────────────────────────────

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
function AutoClash.getState()             return S end
function AutoClash.clashOn()              return S.clashOn end
function AutoClash.getClashAt()           return S.clashAt end
function AutoClash.snapshot()             return clashSnapshot() end
function AutoClash.invalidateSnapshot()   _ctxCache.valid = false end

function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then return end
    local t = Utils.now()
    onTarget(data.TargetPlayerID or -999, t)
end

function AutoClash.resetState()
    S.clashOn, S.clashAt = false, 0
    S.lastTarget, S.lastTargetAt = -999, 0
    S.ballGoneSince, S.outOfRangeFrames = 0, 0
    resetTraj()
    _ctxCache.valid = false
end

function AutoClash.forceClear() clearClash() end

if _G.ExodusModules then _G.ExodusModules.AutoClash = AutoClash end
return AutoClash
