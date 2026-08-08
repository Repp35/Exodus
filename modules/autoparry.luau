--[[ auto parry ]]

-- módulo
local AutoParry = {}

-- dependências
local Probe
local GameInfo
local Utils

-- tunings
local P = {
    FIRE_LOCK = 0.080,
    FIRE_TIMEOUT = 2.0,
    MIN_SPD = 3,
    DEFLECT_R = 8.5,
    RAD_FLOOR = 14,
    LEAD_CAP = 80,
    PRE_CAP = 30,
    PB_WEIGHT = 1.0,

    RES_BASE = 0,
    RES_PER_PARRY = 0.225,
    RES_CAP = 32,
    RES_HOLD_T = 1.2,
    RES_DECAY_T = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5,
    RES_HITBOX_PROX = 12,
    MIN_REFIRE_GAP = 0.015,
    REFIRE_TTH = 0.20,
    GRACE_TIMEOUT = 0.30,
}

-- estado ap
local AP = {
    armed = false,
    fired = false,
    firedAt = 0,
    wasInRange = false,
    inRangeEnterAt = 0,
    lastValidSync = 0,
    lastValidBall = 0,
    lastMissAt = 0,
}

-- estado res
local RES = {
    stack = 0,
    lastFireBallRef = nil,
    lastFireBallAt = 0,
    lastHitboxAt = 0,
    lastStackAt = 0,
}

-- variáveis locais
local _teleportLockUntil = 0
local _apBind = 0
local _localUserId = -1
local _onFired = nil
local _lastTargetSeen = -999

-- resiliência
local function resRadiusBonus()
    return math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP)
end

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

-- cooldown de deflexão
local function getDeflectCD()
    return GameInfo.getDeflectCD()
end

-- disparo de parry
local function sendParry()
    local t = Utils.now()
    if not Probe.fireParry(1) then
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

-- reset de estado
local function resetState()
    AP.armed, AP.fired, AP.firedAt = false, false, 0
    AP.inRangeEnterAt, AP.wasInRange = 0, false
    AP.lastMissAt = 0
    RES.stack = 0
    RES.lastFireBallRef = nil
    RES.lastFireBallAt = 0
    RES.lastHitboxAt = 0
    RES.lastStackAt = 0
    _teleportLockUntil = 0
    _lastTargetSeen = -999
end

-- sincronização da bola
local function onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end
    local t = Utils.now()
    if data.Teleported == true then
        _teleportLockUntil = t + 0.20
        AP.fired = false
        return
    end
    GameInfo.applySync(data)
    local newTarget = data.TargetPlayerID
    if type(newTarget) ~= "number" then
        newTarget = -999
    end

    if newTarget == _lastTargetSeen then
        return
    end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen = newTarget
    if newTarget == _localUserId then
        AP.fired = false
    elseif newTarget ~= -999 then
        if previousTarget == _localUserId then
            AP.fired = false
        end
    else
        AP.fired = false
    end
end

-- bind de parry
local function bindParry(character)
    _apBind = _apBind + 1
    local currentBindId = _apBind
    if not (character and character.Parent) then
        return
    end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if currentBindId ~= _apBind or not (hrp and hrp.Parent) then
        return
    end
    AP.fired, AP.armed = false, false

    -- heartbeat
    Utils.trackCharacter(
        Utils.getRunService().Heartbeat:Connect(
            function(dt)
                if currentBindId ~= _apBind or not (character.Parent and hrp.Parent) then
                    return
                end
                local Config = Utils.getConfig()
                if not Config or Config.AutoParry ~= true then
                    AP.fired = false
                    return
                end
                local t = Utils.now()
                if t < _teleportLockUntil then
                    return
                end
                if Utils.isClashActive() or Utils.isManualSpamActive() then
                    return
                end
                tickResilience(t)
                local ball = GameInfo.getBall()
                if not (ball and ball.Parent) then
                    return
                end
                if not GameInfo.isTargeted(_lastTargetSeen) then
                    AP.armed = false
                    return
                end
                local spd = GameInfo.ballSpeed(ball, t)
                if spd < P.MIN_SPD then
                    return
                end

                -- posição prevista da bola (GameInfo.ballPos já aplica lead do sync)
                local bp = GameInfo.ballPos(ball, t)
                if not bp then
                    return
                end

                -- lead simples baseado na velocidade e num piso (sem subsistema de ping)
                local leadSec = 0.060
                local leadB = math.min(spd * leadSec, P.LEAD_CAP)
                local pbStuds = math.min(spd * 0.05, P.PRE_CAP) -- pre-buffer leve baseado em spd
                local parryRad = math.max(P.DEFLECT_R + leadB + pbStuds + resRadiusBonus(), P.RAD_FLOOR)

                local dx = hrp.Position.X - bp.X
                local dy = hrp.Position.Y - bp.Y
                local dz = hrp.Position.Z - bp.Z
                local dist2 = dx * dx + dy * dy + dz * dz
                if dist2 > parryRad * parryRad then
                    AP.wasInRange, AP.inRangeEnterAt = false, 0
                    return
                end
                AP.wasInRange = true
                local realCD = getDeflectCD()
                if realCD > 0 then
                    return
                end
                if AP.fired then
                    if (t - AP.firedAt) < P.FIRE_LOCK then
                        return
                    end
                    if (t - AP.firedAt) < P.FIRE_TIMEOUT then
                        return
                    end
                    AP.fired = false
                    AP.lastMissAt = t
                end
                if sendParry() then
                    AP.fired, AP.firedAt = true, t
                    -- ganha resiliência a cada parry disparado
                    if RES.stack < P.RES_CAP then
                        RES.stack = RES.stack + 1
                        RES.lastStackAt = t
                    end
                else
                    AP.fired = false
                    AP.lastMissAt = t
                end
            end
        )
    )
    -- ancestry
    Utils.trackCharacter(
        character.AncestryChanged:Connect(
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
end

-- api pública
function AutoParry.setOnFired(fn)
    _onFired = fn
end

function AutoParry.fire()
    return sendParry()
end

function AutoParry.bindParry(character)
    bindParry(character)
end

function AutoParry.resetState()
    resetState()
end

function AutoParry.onBallSync(data)
    onBallSync(data)
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

function AutoParry.getLastFireBallRef()
    return RES.lastFireBallRef
end

function AutoParry.getLastFireBallAt()
    return RES.lastFireBallAt
end

function AutoParry.getP()
    return P
end

if _G.ExodusModules then
    _G.ExodusModules.AutoParry = AutoParry
end

return AutoParry
