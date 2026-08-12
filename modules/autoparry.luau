--[[ auto parry ]]

local AutoParry = {}
local Probe, GameInfo, Utils

-- tunings
local P = {
    FIRE_LOCK = 0.080,
    FIRE_TIMEOUT = 2.0,
    MIN_SPD = 5,
    DEFLECT_R = 8.5,
    RAD_FLOOR = 14,
    PING_FLOOR = 0.030,
    PING_CAP = 0.150,

    RES_BASE = 0,
    RES_PER_PARRY = 0.225,
    RES_CAP = 32,
    RES_HOLD_T = 1.2,
    RES_DECAY_T = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5,
    RES_HITBOX_PROX = 12,
    RES_HITBOX_GAP = 0.4,
}

-- estado ap
local AP = {
    armed = false,        -- condições de parry bateram, esperando CD zerar
    armedBall = nil,      -- ball ref usada no momento do arm (pra invalidação)
    armedAt = 0,
    armedSig = nil,
    fired = false,
    firedAt = 0,
}

local _activeConns = {}

-- estado res
local RES = {
    stack = 0,
    lastFireBallRef = nil,
    lastFireBallAt = 0,
    lastHitboxAt = 0,
    lastStackAt = 0,
}

local _teleportLockUntil = 0
local _apBind = 0
local _localUserId = -1
local _onFired = nil
local _lastTargetSeen = -999

-- estado de ping
local _smoothPing = 0.060
local _pingTimer  = 0
local PING_SAMPLE = 1.5
local PING_EMA    = 0.3

local _pingOneWayCached = 0.030
local _pingOneWayStamp  = 0

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
local _resBonusCache = 0
local _resBonusStamp = -1
local function resRadiusBonus(t)
    if t == _resBonusStamp then return _resBonusCache end
    _resBonusCache = math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP)
    _resBonusStamp = t
    return _resBonusCache
end

local function tickResilience(t)
    if RES.stack <= 0 then return end
    local since = t - RES.lastStackAt
    if since > (P.RES_HOLD_T + P.RES_DECAY_T) then
        RES.stack = 0
        return
    end
    if since > P.RES_HOLD_T then
        local frac = 1 - (since - P.RES_HOLD_T) / P.RES_DECAY_T
        if frac <= 0 then RES.stack = 0
        else
            local decayed = math.floor(RES.stack * frac + 0.5)
            if decayed ~= RES.stack then RES.stack = decayed end
        end
    end
end

local function getDeflectCD() return GameInfo.getDeflectCD() end

local function sendParry()
    local t = Utils.now()
    if not Probe.fireParry(1) then return false end
    local b = GameInfo.getBall()
    if b and b.Parent then RES.lastFireBallRef, RES.lastFireBallAt = b, t end
    if _onFired then _onFired(t) end
    return true
end

local function resetState()
    AP.armed, AP.armedBall, AP.armedAt, AP.armedSig = false, nil, 0, nil
    AP.fired, AP.firedAt = false, 0
    RES.stack, RES.lastFireBallRef, RES.lastFireBallAt, RES.lastHitboxAt, RES.lastStackAt = 0, nil, 0, 0, 0
    _teleportLockUntil, _lastTargetSeen = 0, -999
    _resBonusCache, _resBonusStamp = 0, -1
end

local function disconnectAll()
    for i = #_activeConns, 1, -1 do
        local c = _activeConns[i]
        _activeConns[i] = nil
        if c and type(c.Disconnect) == "function" then
            pcall(function() c:Disconnect() end)
        end
    end
end

local function onBallSync(data)
    if typeof(data) ~= "table" then return end
    local t = Utils.now()
    if data.Teleported == true then
        _teleportLockUntil = t + 0.20
        AP.fired = false
        return
    end
    GameInfo.applySync(data)
    local newTarget = data.TargetPlayerID
    if type(newTarget) ~= "number" then newTarget = -999 end
    if newTarget == _lastTargetSeen then return end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen = newTarget
    if newTarget == _localUserId then AP.fired = false
    elseif newTarget ~= -999 then
        if previousTarget == _localUserId then AP.fired = false end
    else AP.fired = false end
end

local function bindParry(character)
    _apBind = _apBind + 1
    local currentBindId = _apBind
    disconnectAll()
    if not (character and character.Parent) then return end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if currentBindId ~= _apBind or not (hrp and hrp.Parent) then return end
    AP.fired, AP.armed = false, false

    local heartbeatConn
    heartbeatConn = Utils.getRunService().Heartbeat:Connect(function(dt)
        if currentBindId ~= _apBind or not (character.Parent and hrp.Parent) then return end
        local Config = Utils.getConfig()
        if not Config or Config.AutoParry ~= true then
            AP.armed, AP.armedBall, AP.armedAt, AP.armedSig = false, nil, 0, nil
            AP.fired = false
            return
        end
        local t = Utils.now()
        if t < _teleportLockUntil then
            AP.armed, AP.armedBall, AP.armedAt, AP.armedSig = false, nil, 0, nil
            return
        end
        if Utils.isClashActive() or Utils.isManualSpamActive() then return end
        tickResilience(t)

        _pingTimer = _pingTimer + dt
        if _pingTimer >= PING_SAMPLE then _pingTimer = 0; samplePing() end

        -- fast path: armado, esperando CD zerar (sem timeout, só desarma se target mudar)
        if AP.armed then
            local curBall = GameInfo.getBall()
            local stillTargeted = GameInfo.isTargeted(_lastTargetSeen)
            local ballAlive = AP.armedBall and AP.armedBall.Parent ~= nil
            local sameBall = (curBall == AP.armedBall)
            if not (stillTargeted and ballAlive and sameBall) then
                -- target mudou / bola sumiu / bola trocou → desarma
                AP.armed, AP.armedBall, AP.armedAt, AP.armedSig = false, nil, 0, nil
            elseif getDeflectCD() <= 0 then
                -- CD zerou: dispara instantaneamente
                if AP.fired then
                    if (t - AP.firedAt) >= P.FIRE_TIMEOUT then AP.fired = false end
                end
                if not AP.fired then
                    if sendParry() then
                        AP.fired, AP.firedAt = true, t
                    end
                end
                AP.armed, AP.armedBall, AP.armedAt, AP.armedSig = false, nil, 0, nil
                return
            else
                -- ainda em CD, mantém armado e espera o próximo frame
                return
            end
        end

        local ball = GameInfo.getBall()
        if not (ball and ball.Parent) then return end
        if not GameInfo.isTargeted(_lastTargetSeen) then
            AP.armed = false
            return
        end
        local spd = GameInfo.ballSpeed(ball, t)
        if spd < P.MIN_SPD then return end

        local bp = GameInfo.ballPos(ball, t)
        if not bp then return end

        local pingOneWay = _pingOneWayCached
        if t - _pingOneWayStamp > 0.25 then
            _pingOneWayCached = math.clamp(_smoothPing * 0.5, P.PING_FLOOR, P.PING_CAP)
            _pingOneWayStamp  = t
            pingOneWay         = _pingOneWayCached
        end
        local triggerWindow = pingOneWay + 0.016

        local parryRad  = math.max(P.DEFLECT_R + resRadiusBonus(t), P.RAD_FLOOR)
        local detectRad = parryRad + spd * pingOneWay

        local hp = hrp.Position
        local dx, dy, dz = hp.X - bp.X, hp.Y - bp.Y, hp.Z - bp.Z
        local dist = dx * dx + dy * dy + dz * dz

        if dist > detectRad * detectRad then return end
        dist = math.sqrt(dist)

        local tImp = (dist - parryRad) / spd
        if tImp < 0 then tImp = 0 end
        if tImp > triggerWindow then return end

        -- cooldown gate: se tá em CD, ARMA em vez de descartar
        if getDeflectCD() > 0 then
            AP.armed = true
            AP.armedBall = ball
            AP.armedAt = t
            AP.armedSig = true -- marcado; a checagem de validade usa armedBall
            return
        end

        if AP.fired then
            if (t - AP.firedAt) < P.FIRE_LOCK then return end
            if (t - AP.firedAt) < P.FIRE_TIMEOUT then return end
            AP.fired = false
        end
        if sendParry() then
            AP.fired, AP.firedAt = true, t
        else
            AP.fired = false
        end
    end)
    _activeConns[#_activeConns + 1] = heartbeatConn
    Utils.trackCharacter(heartbeatConn)

    local ancestryConn = character.AncestryChanged:Connect(function(_, parent)
        if not parent then _apBind = _apBind + 1 end
    end)
    _activeConns[#_activeConns + 1] = ancestryConn
    Utils.trackCharacter(ancestryConn)
end

-- setup
local _hitboxConn
local function installHitboxHook()
    if _hitboxConn then return end
    local ws = game:GetService("Workspace")
    _hitboxConn = ws.DescendantAdded:Connect(function(d)
        if not d:IsA("BasePart") or d.Name ~= "HitboxGrow" then return end
        local t = Utils.now()
        if (t - RES.lastFireBallAt) > P.RES_HITBOX_OWN_WINDOW then return end
        if not (RES.lastFireBallRef and RES.lastFireBallRef.Parent) then return end
        if (t - RES.lastHitboxAt) < P.RES_HITBOX_GAP then return end
        if (RES.lastFireBallRef.Position - d.Position).Magnitude > P.RES_HITBOX_PROX then return end
        RES.lastHitboxAt, RES.lastStackAt = t, t
        RES.stack = RES.stack + 1
        local cap = math.floor((P.RES_CAP - P.RES_BASE) / P.RES_PER_PARRY)
        if RES.stack > cap then RES.stack = cap end
    end)
    table.insert(_activeConns, _hitboxConn)
end

function AutoParry.setup(deps)
    Probe, GameInfo, Utils = deps.Probe, deps.GameInfo, deps.Utils
    _localUserId = Utils.getLocalPlayer().UserId
    installHitboxHook()
end

function AutoParry.setOnFired(fn)       _onFired = fn end
function AutoParry.fire()                return sendParry() end
function AutoParry.bindParry(character)  bindParry(character) end
function AutoParry.resetState()          resetState() end
function AutoParry.onBallSync(data)      onBallSync(data) end
function AutoParry.resRadiusBonus()       return _resBonusCache end
function AutoParry.getState()             return AP end
function AutoParry.getRes()               return RES end
function AutoParry.getLastFireBallRef()   return RES.lastFireBallRef end
function AutoParry.getLastFireBallAt()    return RES.lastFireBallAt end
function AutoParry.getP()                 return P end
function AutoParry.getPingOneWay()
    return math.clamp(_smoothPing * 0.5, P.PING_FLOOR, P.PING_CAP)
end

if _G.ExodusModules then _G.ExodusModules.AutoParry = AutoParry end
return AutoParry
