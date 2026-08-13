-- [[ auto parry ]]

local AutoParry = {}
local Probe, GameInfo, Utils

-- ── tunings ─────────────────────────────────────────────────────────────────

local P = {
    FIRE_LOCK    = 0.080,
    FIRE_TIMEOUT = 2.0,
    SYNC_FRESH   = 0.30,
    MIN_SPD      = 5,

    DEFLECT_R    = 8.5,

    LEAD_REACT_T = 0.040,
    LEAD_CAP     = 100,

    PB_BASE_MS   = 85,
    PB_JITTER    = 1.4,
    PB_DRIFT_MIN = 20,
    PB_DRIFT_M   = 0.6,
    PB_FPS_K     = 0.020,
    PB_FLOOR_MS  = 35,
    PB_CAP_MS    = 200,
    PRE_CAP      = 30,

    PING_SAMPLE  = 1.5,
    PING_EMA     = 0.3,
    PING_MAX     = 0.150,

    RES_BASE            = 0,
    RES_PER_PARRY       = 0.225,
    RES_CAP             = 32,
    RES_HOLD_T          = 1.2,
    RES_DECAY_T         = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5,
    RES_HITBOX_PROX     = 12,
    RES_HITBOX_GAP      = 0.4,
}

-- ── state ───────────────────────────────────────────────────────────────────

local AP = { fired = false, firedAt = 0 }

local _lastTargetSeen = -999
local _localUserId    = -1

local _smoothPing = 0.060
local _pingTimer  = 0

local _frameEMA  = 1/60
local _frameVar  = 0
local _jitterEMA = 0
local _dtLast    = 0

local Sync = {
    Speed    = 0,
    RealPos  = Vector3.zero,
    Target   = -999,
    lastAt   = 0,
    Teleport = false,
}

local RES = {
    stack           = 0,
    lastFireBallRef = nil,
    lastFireBallAt  = 0,
    lastHitboxAt    = 0,
    lastStackAt     = 0,
}

local _resBonusCache = 0
local _resBonusStamp = -1

local _activeConns       = {}
local _teleportLockUntil = 0
local _apBind            = 0
local _fbConn            = nil
local _hitboxConn        = nil

local _pbCache = { ms = -1, ping = -1, jitter = -1, var = -1 }

-- ── target check ────────────────────────────────────────────────────────────

local _br = nil
local _brTried = false
local _wsRef = nil
local function _ensureBR()
    if _brTried then return _br end
    _brTried = true
    pcall(function()
        local ts = game:GetService("ReplicatedStorage"):FindFirstChild("TS")
        if not ts then return end
        local brMod = ts:FindFirstChild("BallReplicator")
            and ts.BallReplicator:FindFirstChild("BallReplicator")
        if brMod then
            local ok, mod = pcall(require, brMod)
            if ok and mod and mod.BallReplicator then
                _br = mod.BallReplicator
            end
        end
    end)
    return _br
end

local function tgtOn()
    if not _wsRef then
        _wsRef = game:GetService("Workspace")
    end
    if _wsRef and _wsRef:GetAttribute("GameBallTarget") == _localUserId then
        return true
    end
    local br = _ensureBR()
    if br and br.syncData and br.syncData.HighlightTargetPlayerID == _localUserId then
        return true
    end
    if Sync.Target == _localUserId then
        return true
    end
    return false
end

-- ── ping ────────────────────────────────────────────────────────────────────

local Stats = game:GetService("Stats")

local function samplePing()
    local ok, p = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and type(p) == "number" and p > 0 and p < 0.5 then
        _smoothPing = _smoothPing * (1 - P.PING_EMA) + p * P.PING_EMA
    end
end

local function pingOneWay()
    return math.clamp(_smoothPing * 0.5, 0, P.PING_MAX)
end

-- ── frame delta / jitter / variance ─────────────────────────────────────────

local function sampleFrameDelta(dt)
    if dt <= 0 then return end

    _frameEMA = _frameEMA * 0.9 + dt * 0.1

    if _dtLast > 0 then
        local devMs = math.abs(dt - _dtLast) * 1000
        _jitterEMA = _jitterEMA * 0.85 + devMs * 0.15
        local dev = dt - _frameEMA
        _frameVar = _frameVar * 0.9 + (dev * dev) * 0.1
    end
    _dtLast = dt
end

-- ── preBuffer ───────────────────────────────────────────────────────────────

local function preBufferMs()
    local p        = pingOneWay() * 1000
    local jitter   = _jitterEMA
    local variance = _frameVar

    if math.abs(p - _pbCache.ping) < 1
        and math.abs(jitter - _pbCache.jitter) < 0.5
        and math.abs(variance - _pbCache.var) < 1e-7
        and _pbCache.ms > 0
    then
        return _pbCache.ms
    end

    local pb = P.PB_BASE_MS + jitter * P.PB_JITTER
    local driftMs = math.max(variance * 1000 * 100, P.PB_DRIFT_MIN)
    pb = pb + driftMs * P.PB_DRIFT_M

    local fps = 60
    if _frameEMA > 0 then fps = 1 / _frameEMA end
    if fps < 60 then
        pb = pb + (60 - fps) * P.PB_FPS_K * 1000
    end

    pb = math.clamp(pb, P.PB_FLOOR_MS, P.PB_CAP_MS)

    _pbCache.ms = pb
    _pbCache.ping = p
    _pbCache.jitter = jitter
    _pbCache.var = variance
    return pb
end

-- ── lead / preBuffer studs ──────────────────────────────────────────────────

local function leadStuds(spd, p)
    if not spd or spd < 1 then return 0 end
    return math.min(spd * (p + P.LEAD_REACT_T), P.LEAD_CAP)
end

local function preBufferStuds(spd, pbMs)
    if not spd or spd < 1 then return 0 end
    return math.min(spd * pbMs / 1000, P.PRE_CAP)
end

-- ── resilience ──────────────────────────────────────────────────────────────

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
        if frac <= 0 then
            RES.stack = 0
        else
            local decayed = math.floor(RES.stack * frac + 0.5)
            if decayed ~= RES.stack then RES.stack = decayed end
        end
    end
end

-- ── core ────────────────────────────────────────────────────────────────────

local function getDeflectCD() return GameInfo.getDeflectCD() end

local function sendParry()
    local t = Utils.now()
    if not Probe.fireParry(1) then return false end
    local b = GameInfo.getBall()
    if b and b.Parent then RES.lastFireBallRef, RES.lastFireBallAt = b, t end
    return true
end

-- ── bookkeeping ─────────────────────────────────────────────────────────────

local function resetState()
    AP.fired, AP.firedAt = false, 0
    RES.stack, RES.lastFireBallRef, RES.lastFireBallAt, RES.lastHitboxAt, RES.lastStackAt = 0, nil, 0, 0, 0
    _teleportLockUntil, _lastTargetSeen = 0, -999
    _resBonusCache, _resBonusStamp = 0, -1
    Sync.Speed, Sync.RealPos, Sync.Target, Sync.lastAt, Sync.Teleport = 0, Vector3.zero, -999, 0, false
end

local function disconnectAll()
    for i = #_activeConns, 1, -1 do
        local c = _activeConns[i]
        _activeConns[i] = nil
        if c and type(c.Disconnect) == "function" then
            c:Disconnect()
        end
    end
end

-- ── ball sync ───────────────────────────────────────────────────────────────

local function onBallSync(data)
    if typeof(data) ~= "table" then return end
    local t = Utils.now()

    if data.Teleported == true then
        _teleportLockUntil = t + 0.20
        AP.fired = false
        Sync.Teleport = true
        return
    end

    if GameInfo.applySync then GameInfo.applySync(data) end

    if type(data.Speed) == "number" then Sync.Speed = data.Speed end
    if typeof(data.RealPosition) == "Vector3" then Sync.RealPos = data.RealPosition end
    Sync.lastAt = t
    Sync.Teleport = false

    local newTarget = data.TargetPlayerID
    if type(newTarget) ~= "number" then newTarget = -999 end
    Sync.Target = newTarget

    if newTarget == _lastTargetSeen then return end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen = newTarget
    if newTarget == _localUserId or newTarget == -999 or previousTarget == _localUserId then
        AP.fired = false
    end
end

-- ── frame sampler ───────────────────────────────────────────────────────────

local function installFrameSampler()
    if _fbConn then return end
    local ok, sig = pcall(function() return Utils.getRunService().Heartbeat end)
    if not ok or not sig then return end
    _fbConn = sig:Connect(function(dt) sampleFrameDelta(dt) end)
    _activeConns[#_activeConns + 1] = _fbConn
end

-- ── hitbox hook ─────────────────────────────────────────────────────────────

local _hitboxHookConn = nil
local function installHitboxHook()
    if _hitboxHookConn then return end
    local ok, ws = pcall(function() return game:GetService("Workspace") end)
    if not ok or not ws then return end
    local gameFolder = ws:FindFirstChild("Game")
    if not gameFolder then
        -- workspace ainda não tem Game; tenta em CharacterAdded depois
        return
    end
    local ballFolder = gameFolder:FindFirstChild("Ball")
    if not ballFolder then return end

    _hitboxHookConn = ballFolder.DescendantAdded:Connect(function(d)
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
    _activeConns[#_activeConns + 1] = _hitboxHookConn
    _hitboxConn = _hitboxHookConn
end

-- ── main loop ───────────────────────────────────────────────────────────────

local function bindParry(character)
    _apBind = _apBind + 1
    local currentBindId = _apBind
    disconnectAll()
    if not (character and character.Parent) then return end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if currentBindId ~= _apBind or not (hrp and hrp.Parent) then return end
    AP.fired = false
    installFrameSampler()

    local RunService = Utils.getRunService()
    local heartbeatConn
    heartbeatConn = RunService.Heartbeat:Connect(function(dt)
        if currentBindId ~= _apBind or not (character.Parent and hrp.Parent) then return end

        local Config = Utils.getConfig()
        if not Config or Config.AutoParry ~= true then
            AP.fired = false
            return
        end

        local t = Utils.now()
        if t < _teleportLockUntil then return end
        if Utils.isClashActive() or Utils.isManualSpamActive() then return end
        if GameInfo.isGrace() then return end

        tickResilience(t)

        _pingTimer = _pingTimer + dt
        if _pingTimer >= P.PING_SAMPLE then _pingTimer = 0; samplePing() end

        local ball = GameInfo.getBall()
        if not (ball and ball.Parent) then return end
        if not tgtOn() then return end

        local spd, bp
        local syncFresh = (t - Sync.lastAt) < P.SYNC_FRESH
        if syncFresh and Sync.Speed > 0 then
            spd = Sync.Speed
            bp  = (Sync.RealPos ~= Vector3.zero) and Sync.RealPos or ball.Position
        else
            local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
            if not ok or typeof(av) ~= "Vector3" or av.Magnitude < 0.1 then return end
            spd = av.Magnitude
            bp  = ball.Position
        end
        if spd < P.MIN_SPD then return end

        local p     = pingOneWay()
        local pbMs  = preBufferMs()
        local parryRad = P.DEFLECT_R + leadStuds(spd, p) + preBufferStuds(spd, pbMs) + resRadiusBonus(t)

        local hx, hy, hz = hrp.Position.X, hrp.Position.Y, hrp.Position.Z
        local dx, dy, dz = hx - bp.X, hy - bp.Y, hz - bp.Z
        if dx*dx + dy*dy + dz*dz > parryRad * parryRad then return end

        if AP.fired then
            if (t - AP.firedAt) >= P.FIRE_TIMEOUT then AP.fired = false end
        end
        if AP.fired then return end
        if (t - AP.firedAt) < P.FIRE_LOCK then return end
        if AP.firedAt > Sync.lastAt then return end

        AP.fired, AP.firedAt = true, t
        if not sendParry() then AP.fired = false end
    end)
    _activeConns[#_activeConns + 1] = heartbeatConn
    Utils.trackCharacter(heartbeatConn)

    local ancestryConn = character.AncestryChanged:Connect(function(_, parent)
        if not parent then _apBind = _apBind + 1 end
    end)
    _activeConns[#_activeConns + 1] = ancestryConn
    Utils.trackCharacter(ancestryConn)
end

-- ── public ──────────────────────────────────────────────────────────────────

function AutoParry.setup(deps)
    Probe, GameInfo, Utils = deps.Probe, deps.GameInfo, deps.Utils
    _localUserId = Utils.getLocalPlayer().UserId
    installHitboxHook()
end

function AutoParry.bindParry(character)  bindParry(character) end
function AutoParry.resetState()          resetState() end
function AutoParry.onBallSync(data)      onBallSync(data) end
function AutoParry.resRadiusBonus()      return _resBonusCache end
function AutoParry.getPingOneWay()       return pingOneWay() end
function AutoParry.getSync()             return Sync end

function AutoParry.computeParryRadius(spd, t)
    local p    = pingOneWay()
    local pbMs = preBufferMs()
    return P.DEFLECT_R + leadStuds(spd, p) + preBufferStuds(spd, pbMs) + resRadiusBonus(t)
end

if _G.ExodusModules then _G.ExodusModules.AutoParry = AutoParry end
return AutoParry