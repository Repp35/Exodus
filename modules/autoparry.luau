--[[ AutoParry delta ]]

local AutoParry = {}

-- deps
local Probe, GameInfo, Utils

-- tunning (res mantido, lógica de fogo estilo delta v3)
local P = {
    -- radius / range
    DEFLECT_R    = 8.5,
    RAD_FLOOR    = 9,
    RAD_MIN      = 9,
    RAD_MAX      = 90,
    RAD_WIN      = 0.40,   -- multiplicador spd → radius (delta v3)
    RAD_OFF      = 6,      -- offset base (delta v3)
    RAD_PRE      = 0,      -- raio extra pré-activação (delta v3)

    -- velocidade
    MIN_SPD      = 5,      -- minSpeed do delta v3

    -- impact window
    MAX_IMPACT_T = 0.35,   -- maxImpactTime do delta v3 (sem ping comp; usamos ping do GameInfo)
    PING_FLOOR   = 0.020,
    PING_MULT    = 1.1,
    PING_OFFSET  = 0.02,
    PING_MAX     = 0.25,

    -- lead simples (suficiente p/ o grace)
    LEAD_RTT_MULT     = 0.5,
    LEAD_TICK_FRAMES  = 2,
    LEAD_PING_FLOOR   = 0.020,
    LEAD_CAP          = 50,

    -- pre-buffer mantido pra res
    PRE_CAP           = 30,

    -- res (inalterado)
    RES_BASE          = 0,
    RES_PER_PARRY     = 0.225,
    RES_CAP           = 32,
    RES_HOLD_T        = 1.2,
    RES_DECAY_T       = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5,
    RES_HITBOX_PROX   = 12,

    -- ball reset (delta v3)
    BALL_RESET_THRESH = 50,
    BALL_RESET_LOCKOUT = 0.6,

    -- target / processing
    ACTIVATION_DIST_OFFSET = 7,
}

-- AP
local AP = {
    armed = false,
    fired = false,
    firedAt = 0,
    wasInRange = false,
    inRangeEnterAt = 0,
    -- sem burst
}

-- RES
local RES = {
    stack = 0,
    lastFireBallRef = nil,
    lastFireBallAt = 0,
    lastHitboxAt = 0,
    lastStackAt = 0
}

-- Sync
local Sync = {
    Speed = 0,
    RealPos = Vector3.new(0, 0, 0),
    ForceDir = false,
    ForcedDir = Vector3.new(0, 0, 0),
    DeflectDir = Vector3.new(0, 0, 0),
    Grace = false,
    Teleported = false,
    Target = -999,
    lastSyncAt = 0,
    forcedAt = 0
}

-- locals
local _teleportLockUntil = 0
local _apBind = 0
local _resolveCache = 0
local _now = os.clock
local _localUserId = -1
local _onFired = nil
local _lastTargetSeen = -999

-- ball processed (impede duplo clique sem lock fixo)
local ballProcessed = false
local ballLeftMe    = false
local lastBallPos   = nil
local ballResetAt   = 0
local _lastProcessReset = 0
local _vel = Vector3.zero
local _lastBP, _lastBT = nil, nil
local _lastParryTime = 0

-- resRadiusBonus
local function resRadiusBonus()
    return math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP)
end

-- tickResilience
local function tickResilience(t)
    if RES.stack <= 0 then
        return
    end
    local since = t - RES.lastStackAt
    if since > (P.RES_HOLD_T + P.RES_DECAY_T) then
        RES.stack = 0
        return
    end
    if since > P.RES_HOLD_T then
        local frac = 1 - (since - P.RES_HOLD_T) / P.RES_DECAY_T
        if frac <= 0 then
            RES.stack = 0
        else
            local decayed = math.floor(RES.stack * frac + 0.5)
            if decayed ~= RES.stack then
                RES.stack = decayed
            end
        end
    end
end

-- validRemote
local function _validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

-- sendParry
local function sendParry()
    local t = _now()
    local r, m
    if (not _validRemote(Probe.getRemote())) or (t - _resolveCache) > 3.0 then
        r, m = Probe.resolveRemote()
        _resolveCache = t
    else
        r, m = Probe.getRemote()
    end
    if not r then
        return false
    end
    if not Probe.fireParry(1) then
        _resolveCache = 0
        Probe.invalidate()
        return false
    end
    local b = GameInfo.getBall()
    if b and b.Parent then
        RES.lastFireBallRef, RES.lastFireBallAt = b, t
    end
    if _onFired then
        _onFired(t)
    end
    return true
end

-- resetState
local function resetState()
    AP.armed, AP.fired, AP.firedAt = false, false, 0
    AP.inRangeEnterAt, AP.wasInRange = 0, false
    RES.stack = 0
    RES.lastFireBallRef = nil
    RES.lastFireBallAt = 0
    RES.lastHitboxAt = 0
    RES.lastStackAt = 0
    Sync.Speed = 0
    Sync.RealPos = Vector3.new(0, 0, 0)
    Sync.ForceDir = false
    Sync.ForcedDir = Vector3.new(0, 0, 0)
    Sync.DeflectDir = Vector3.new(0, 0, 0)
    Sync.Grace = false
    Sync.Teleported = false
    Sync.Target = -999
    Sync.lastSyncAt = 0
    Sync.forcedAt = 0
    _teleportLockUntil = 0
    ballProcessed = false
    ballLeftMe = false
    lastBallPos = nil
    ballResetAt = 0
    _lastProcessReset = 0
    _vel = Vector3.zero
    _lastBP, _lastBT = nil, nil
    _lastParryTime = 0
    _lastTargetSeen = -999
end

-- onBallSync (mantido: gerencia target/Grace igual o original)
local function onBallSync(d)
    if typeof(d) ~= "table" then
        return
    end
    local t = _now()
    if type(d.Speed) == "number" then
        Sync.Speed = d.Speed
    end
    if typeof(d.RealPosition) == "Vector3" then
        Sync.RealPos = d.RealPosition
    end
    if typeof(d.DeflectDirection) == "Vector3" then
        Sync.DeflectDir = d.DeflectDirection
    end
    if type(d.Grace) == "boolean" then
        Sync.Grace = d.Grace
    end
    if type(d.ForceDirection) == "boolean" then
        if d.ForceDirection and not Sync.ForceDir then
            Sync.forcedAt = t
        end
        Sync.ForceDir = d.ForceDirection
    end
    if typeof(d.ForcedDirection) == "Vector3" then
        Sync.ForcedDir = d.ForcedDirection
    end
    Sync.lastSyncAt = t
    if d.Teleported == true then
        _teleportLockUntil = t + 0.20
        AP.fired = false
        if _G.PhantomOnTeleport then
            _G.PhantomOnTeleport()
        end
        Sync.Teleported = true
        return
    end
    Sync.Teleported = false
    GameInfo.applySync(d)
    local newTarget = d.TargetPlayerID
    if type(newTarget) == "number" then
        Sync.Target = newTarget
    else
        newTarget = -999
    end
    if newTarget == _lastTargetSeen then
        Sync.Target = newTarget
        return
    end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen, Sync.Target = newTarget, newTarget
    if newTarget == _localUserId then
        Sync.Grace = false
        AP.fired = false
        -- bola voltou pra mim: libera processed (igual delta v3)
        if ballLeftMe then
            ballProcessed = false
            ballLeftMe = false
        end
    elseif newTarget ~= -999 then
        Sync.Grace = true
        if previousTarget == _localUserId then
            ballLeftMe = true
            AP.fired = false
        end
    else
        AP.fired = false
    end
    if d.Grace == false then
        Sync.Grace = false
    elseif d.Grace == true then
        Sync.Grace = true
    end
    if _G.PhantomOnTarget then
        _G.PhantomOnTarget(newTarget, t)
    end
end

-- getBallVel (helper)
local function getBallVel(b)
    if not (b and b.Parent) then return nil end
    local ok, av = pcall(function() return b.AssemblyLinearVelocity end)
    if ok and typeof(av) == "Vector3" and av.Magnitude > 0.1 then
        return av
    end
    return nil
end

-- ping compensation (delta v3 style)
local function getPingCompensation()
    local raw = GameInfo.pingRTT() or 0.05
    return math.clamp(raw * P.PING_MULT + P.PING_OFFSET, P.PING_FLOOR, P.PING_MAX)
end

-- bindParry
local function bindParry(ch)
    _apBind = _apBind + 1
    local id = _apBind
    if not (ch and ch.Parent) then
        return
    end
    local hrp = ch:FindFirstChild("HumanoidRootPart") or ch:WaitForChild("HumanoidRootPart", 1)
    if id ~= _apBind or not (hrp and hrp.Parent) then
        return
    end
    AP.fired, AP.armed = false, false

    Utils.trackCharacter(
        Utils.getRunService().Heartbeat:Connect(
            function(dt)
                if id ~= _apBind or not (ch.Parent and hrp.Parent) then
                    return
                end
                local Config = _G.PhantomConfig
                if not Config or Config.AutoParry ~= true then
                    AP.fired = false
                    return
                end
                local t = _now()

                -- grace / locks
                if t < _teleportLockUntil or Sync.Grace then
                    return
                end
                if (_G.PhantomClashOn and _G.PhantomClashOn()) or _G.PhantomManual then
                    return
                end

                tickResilience(t)

                local ball = GameInfo.getBall()
                if not (ball and ball.Parent) then
                    return
                end

                -- alvo precisa ser eu (delta v3)
                if Sync.Target ~= _localUserId then
                    AP.armed = false
                    return
                end

                -- reseta ballProcessed depois de processResetInt (delta v3)
                if ballProcessed and (t - _lastProcessReset) >= 0.4 then
                    ballProcessed = false
                end

                local bp = ball.Position

                -- detecção de reset por salto de posição
                if lastBallPos then
                    local jump = (bp - lastBallPos).Magnitude
                    if jump > P.BALL_RESET_THRESH then
                        ballProcessed = true
                        _lastProcessReset = t
                        ballResetAt = t
                        _vel = Vector3.zero
                        _lastBP, _lastBT = nil, nil
                        lastBallPos = bp
                        return
                    end
                end
                lastBallPos = bp

                if (t - ballResetAt) < P.BALL_RESET_LOCKOUT then
                    return
                end

                -- velocidade da bola (igual delta v3)
                local av = getBallVel(ball)
                if av then
                    _vel = av
                    _lastBT, _lastBP = t, bp
                elseif not _lastBT then
                    _lastBT, _lastBP = t, bp
                else
                    local dtt = t - _lastBT
                    if dtt > 0 then
                        local rawV = (bp - _lastBP) / dtt
                        local a = dt / (0.05 + dt)
                        _vel = _vel + (rawV - _vel) * a
                        _lastBT, _lastBP = t, bp
                    end
                end

                local hrpPos = hrp.Position
                local spd = _vel.Magnitude
                if spd < P.MIN_SPD then
                    return
                end

                -- RAIO: fórmula delta v3 + lead (que escala com spd) + res
                -- sem RAD_PRE, mas com lead dinâmico (leadB) + pre-buffer do GameInfo,
                -- então em spd alta o raio cresce sozinho sem ficar fixo em 10.
                local leadSec = math.max(
                    (GameInfo.pingRTT() or 0.05) * P.LEAD_RTT_MULT
                        + (P.LEAD_TICK_FRAMES * 16.67 / 1000),
                    P.LEAD_PING_FLOOR
                )
                local leadB = math.min(spd * leadSec, P.LEAD_CAP)
                local pbStuds = math.min(GameInfo.preBufferStuds and GameInfo.preBufferStuds(spd) or 0, P.PRE_CAP)

                local rad = math.clamp(spd * P.RAD_WIN + P.RAD_OFF, P.RAD_MIN, P.RAD_MAX)
                    + leadB
                    + pbStuds
                    + resRadiusBonus()

                local d = (bp - hrpPos).Magnitude
                -- precisa estar perto
                if d > rad then
                    AP.wasInRange, AP.inRangeEnterAt = false, 0
                    return
                end
                AP.wasInRange = true

                -- aproximando?
                local app = _vel:Dot(hrpPos - bp) > 0
                if not app then return end

                -- impact time + ping comp
                local tImp = spd > 1 and (d / spd) or 1e9
                local ping = getPingCompensation()
                if tImp > (P.MAX_IMPACT_T + ping) then
                    return
                end

                -- sem cooldown fixo: só ballProcessed
                if ballProcessed then
                    return
                end

                -- FOGO
                if sendParry() then
                    ballProcessed = true
                    _lastProcessReset = t
                    _lastParryTime = t
                    AP.firedAt = t
                end
            end
        )
    )

    Utils.trackCharacter(
        ch.AncestryChanged:Connect(
            function(_, parent)
                if not parent then
                    _apBind = _apBind + 1
                end
            end
        )
    )
end

-- setup
function AutoParry.setup(deps)
    Probe = deps.Probe
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    _localUserId = Utils.getLocalPlayer().UserId
    _G.PhantomResilience = RES
    _G.PhantomApState = AP
    _G.PhantomApSync = Sync
end

-- public api
function AutoParry.setOnFired(fn)
    _onFired = fn
end
function AutoParry.bindParry(ch)
    bindParry(ch)
end
function AutoParry.resetState()
    resetState()
end
function AutoParry.onBallSync(d)
    onBallSync(d)
end
function AutoParry.resRadiusBonus()
    return resRadiusBonus()
end
function AutoParry.getState()
    return AP
end
function AutoParry.getRes()
    return RES
end
function AutoParry.getSync()
    return Sync
end
function AutoParry.getLastFireBallRef()
    return RES.lastFireBallRef
end
function AutoParry.getLastFireBallAt()
    return RES.lastFireBallAt
end
function AutoParry.getP()
    return P
end

return AutoParry
