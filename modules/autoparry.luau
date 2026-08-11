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
    PING_FLOOR = 0.030,
    PING_CAP = 0.150,
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

-- conexões ativas (pra evitar vazamento de heartbeat a cada respawn)
local _activeConns = {}

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

-- estado de ping
local _smoothPing = 0.060  -- começa com 60ms como fallback
local _pingTimer  = 0
local PING_SAMPLE = 1.5    -- amostra a cada 1.5s
local PING_EMA    = 0.3    -- suavização

-- amostragem de ping via Roblox Stats
local Stats = game:GetService("Stats")
local function samplePing()
    local ok, p = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and type(p) == "number" and p > 0 and p < 0.5 then
        _smoothPing = _smoothPing * (1 - PING_EMA) + p * PING_EMA
    end
end

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

-- desconecta todas as conexões ativas (anti-vazamento de heartbeat em respawn)
local function disconnectAll()
    for i = #_activeConns, 1, -1 do
        local c = _activeConns[i]
        _activeConns[i] = nil
        if c and type(c.Disconnect) == "function" then
            pcall(function() c:Disconnect() end)
        end
    end
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
    -- FIX: desconecta heartbeats/conexões anteriores a cada respawn
    disconnectAll()
    if not (character and character.Parent) then
        return
    end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if currentBindId ~= _apBind or not (hrp and hrp.Parent) then
        return
    end
    AP.fired, AP.armed = false, false

    -- heartbeat
    local heartbeatConn
    heartbeatConn = Utils.getRunService().Heartbeat:Connect(
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

                -- amostra ping periodicamente
                _pingTimer = _pingTimer + dt
                if _pingTimer >= PING_SAMPLE then
                    _pingTimer = 0
                    samplePing()
                end

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

                -- ping one-way suavizado (piso/teto) + folga de 1 frame pro jitter
                local pingOneWay = math.clamp(_smoothPing * 0.5, P.PING_FLOOR, P.PING_CAP)
                local triggerWindow = pingOneWay + 0.016

                -- raio físico real do servidor (sem lead — o lead vai no tempo de decisão)
                local parryRad = math.max(P.DEFLECT_R + resRadiusBonus(), P.RAD_FLOOR)
                -- raio expandido pra começar a monitorar a bola cedo o suficiente
                local detectRad = parryRad + spd * pingOneWay

                local dx = hrp.Position.X - bp.X
                local dy = hrp.Position.Y - bp.Y
                local dz = hrp.Position.Z - bp.Z
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

                -- fora da zona expandida: nem monitora
                if dist > detectRad then
                    AP.wasInRange, AP.inRangeEnterAt = false, 0
                    return
                end

                -- tImp: tempo estimado até a bola entrar no raio físico real
                local tImp = math.max((dist - parryRad) / spd, 0)
                if tImp > triggerWindow then
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
    _activeConns[#_activeConns + 1] = heartbeatConn
    Utils.trackCharacter(heartbeatConn)
    -- ancestry
    local ancestryConn = character.AncestryChanged:Connect(
            function(_, parent)
                if not parent then
                    _apBind = _apBind + 1
                end
            end
        )
    _activeConns[#_activeConns + 1] = ancestryConn
    Utils.trackCharacter(ancestryConn)
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