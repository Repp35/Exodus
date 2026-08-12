-- [[ PHANTOM BALL LOGIC ]]

local SCRIPT_VERSION = "22.5"
local SCRIPT_NAME    = "Phantom Ball LOGIC"

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local Stats      = game:GetService("Stats")
local UIS        = game:GetService("UserInputService")

-- [[ SERVICES ]]
local lp, ws = Players.LocalPlayer, workspace
local now    = os.clock
local INF    = math.huge
local V3ZERO = Vector3.new(0, 0, 0)

-- [[ CLASH CONSTANTS ]]
local CLASH = {
    DECAY = 0.310, HOLD = 0.20, REACT_CD = 0.120,
    BALL_RANGE = 18, BALL_HARD_CAP = 22, MAX_BALL_DIST = 45,
    PANIC_DIST = 9, PANIC_BALL = 13,
    CPS_THRESH = 8, CPS_WIN = 1.0, MIN_DANGER = 70,
    TIMP_FAR = 0.180,
    SPD_FAST = 65, SPD_MID = 40, SPD_LOW = 20,
    OFF_PANIC = 0.090, OFF_FAST = 0.050, OFF_MID = 0.060,
    OFF_LOW = 0.070, OFF_VLOW = 0.090,
    COLD_TIMP_CAP = 0.210, MIN_HOLD = 0.050, MAX_HOLD = 1.2,
    TIMP_RISE_FLOOR = 0.006, TIMP_RISE_N_OF_M = 2, TIMP_RISE_M = 3,
    RING_FRESH_MAX = 0.6,
    REARM_HYST_FACTOR = 0.5, REARM_HYST_WIN = 0.5, REARM_COOLDOWN = 0.220,
    ARM_DIST_CAP = 22, ARM_TIMP_CAP = 0.22, REENTRY_DIST = 22,
    FAST_BALL_SPD = 200, FAST_BALL_CPS = 0, FAST_BALL_TIMP_CAP = 0.060,
    DASH_SPD_THRESH = 50, DASH_SPD_CONFIRM = 62, DASH_SPD_RELEASE = 35,
    DASH_DUR_MIN = 0.08, DASH_DUR_MAX = 0.5,
    DASH_PANIC_DOT = 0.85, DASH_PANIC_WINDOW = 0.300, DASH_PANIC_DIST = 14,
    PREEMPT_DIST = 22, PREEMPT_TIMP_CAP = 0.120,
    PING_CREDIT_F = 0.5, PING_FLOOR = 0.040,
    PING_REF = 0.060, PING_MAX_SCALE = 1.0,
    COLD_PING_SCALE = 0.4, FAST_PING_SCALE = 0.5, PREEMPT_PING_SCALE = 0.4,
    MAINT_CHECK_INTERVAL = 0.050,
    MAINT_HOLD_MIN       = 0.060,
    MAINT_BALL_RADIUS    = 25,
    MAINT_TIMP_MAX       = 0.30,
    MAINT_PARRY_KEEP     = 0.10,
    MAINT_TARGET_KEEP    = 0.15,
    MAINT_BALL_GONE_DIST = 60,
    SPAM_PRE_FILL_FRAMES = 4,
    BURST_ON_MS          = 0.080,
    BURST_OFF_MS         = 0.060,
    DET_RAD_MIN          = 10,
    DET_RAD_MAX          = 25,
    DET_RAD_SPD_REF      = 120,
    DET_RETURN_FACTOR    = 1.5,
    DET_DOT_EMA          = 0.25,
    DET_DOT_THRESH       = 0.15,
    DET_TIMEOUT          = 0.8,
    ANTIDASH_RAD_MIN     = 20,
    ANTIDASH_RAD_MAX     = 32,
    ANTIDASH_DOT_MIN     = 0.0,
    ANTIDASH_PANIC_HOLD  = 0.45,
    ANTIDASH_PANIC_MAX   = 1.2,
    ANTIDASH_COOLDOWN    = 0.35,
}

-- [[ PARRY CONSTANTS ]]
local P = {
    FIRE_LOCK = 0.080, MIN_SPD = 3, DEFLECT_R = 8.5, RAD_FLOOR = 14,
    LEAD_CAP = 50, PRE_CAP = 30, PB_WEIGHT = 1.0,
    CPF_MIN_SPACING_MS = 0.05, CPF_MAX_SPACING_MS = 16,
    CPF_FPS_SAMPLE_T = 0.5, CPF_PING_FLOOR = 0.040, CPF_PING_REF = 0.060,
    LEAD_PING_FLOOR = 0.040, LEAD_RTT_MULT = 0.5, LEAD_TICK_FRAMES = 2,
    RES_BASE = 0, RES_PER_PARRY = 0.225, RES_CAP = 32,
    RES_HOLD_T = 1.2, RES_DECAY_T = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5, RES_HITBOX_PROX = 12,
    MIN_REFIRE_GAP = 0.015,
    BURST_SIZE = 8,
    BURST_GAP_FAST = 0.002,
    BURST_GAP_SLOW = 0.012,
    TRIGGER_TTH = 0.18,
    RAD_WIN = 0.20,
    RAD_OFF = 0,
    RAD_PRE = 0,
    RAD_MIN = 9,
    RAD_MAX = 90,
}

-- [[ MISC CONSTANTS ]]
local PING_EMA, PING_MAX, PING_SAMPLE       = 0.5, 0.150, 1.5
local TELEPORT_LOCK, SYNC_FRESH_T, RING_BUF = 0.20, 1.0, 8
local _BALL_PROC_TIMP, _BALL_CACHE_TTL      = 0.25, 0.5
local LIVE_TIMP_TTL                         = 0.05
local PING_BOOT_FALLBACK                    = 0.060
local DEFAULT_CPS                           = 25
local PARRY_PROBE_INTERVAL                  = 3.0
local NEAREST_PLAYER_ALIVE_INTERVAL         = 0.5
local SPAM = { MAX_PER_ITER = 50, WIN = 1.5, DT_CAP = 1 }

local _G_lastNearestPlayerAliveUpdate = 0
local _lastDashTrackUpdate            = 0
local DASH_TRACK_INTERVAL             = 0.2
local _lastFullPlayerScan             = 0
local FULL_PLAYER_SCAN_INTERVAL       = 1.0
local PLAYER_SCAN_RADIUS              = 100
local FRAME_SAMPLE_COUNT              = 60
local DANGER_EMA_ALPHA                = 0.15

-- [[ CONFIG ]]
local Config = {
    AutoParry = true, ManualSpam = false, AutoClash = true,
    SpamRateMode = "CPF", CPS = 4, CustomCPS = false,
    Keybind = Enum.KeyCode.F9, SpamKeybind = Enum.KeyCode.F, SpamMode = "Toggle",
}

-- [[ STATE ]]
local State = { active = true, conns = {}, charConns = {} }

local S = {
    ball = nil, lastTarget = -999, lastTargetAt = 0,
    clashOn = false, clashAt = 0, clashHoldUntil = 0, clashOffAt = 0, lastClashReact = 0,
    dangerEma = 0, lastTImp = 0, lastTImpAt = 0, tImpRising = false, tImpRiseHist = {0, 0, 0},
    lastFireAt = 0, smoothPing = 0.05, pingTimer = 0, teleportLockUntil = 0,
    targetRing = table.create(RING_BUF, 0), targetRingIdx = 0, targetCps = 0,
    maintSpam = false, maintSpamOffAt = 0, lastMaintCheck = 0,
    frameDeltaEMA = 1 / 60, frameDeltaVar = 0,
    dtSamples = {}, dtIdx = 0, dtLast = 0, dtSum = 0, dtSumSq = 0, dtCount = 0,
    jitterEMA = 0, fireIntervalEMA = 80, _lastFireObserved = 0,
    dashEvents = {}, dashPanicUntil = 0,
    nearestDistance = INF, nearestAlive = false,
    detPhase = "IDLE", detEnterAt = 0, detEntryTime = 0, detExitAt = 0,
    detDotEma = 0, detWasInside = false, detSignal = false,
    burstState = "IDLE", burstOnStart = 0, burstOffStart = 0, burstSignalDuringOn = false,
    dashAnti = { untilT = 0, src = nil, at = 0 },
}

local Sync = {
    Speed = 0, RealPos = V3ZERO,
    ForceDir = false, ForcedDir = V3ZERO, DeflectDir = V3ZERO,
    Grace = false, Teleported = false,
    Target = -999, lastSyncAt = 0, forcedAt = 0,
}

local AP = {
    armed = false, fired = false, firedAt = 0,
    wasInRange = false, inRangeEnterAt = 0,
    burstLeft = 0, burstNextAt = 0,
}

local RES = {
    stack = 0, lastFireBallRef = nil,
    lastFireBallAt = 0, lastHitboxAt = 0, lastStackAt = 0,
}


-- [[ LOCAL DECLARATIONS ]]
local _ball, _ballAt = nil, 0
local _burstQueueHead, _burstActive, _nextCpfBurstAt = 1, false, 0
local _spamDebt, _spamWinStart, _spamClickIdx, _spamWasActive = 0, 0, 0, false
local _burstQueue = {}
local _spamCooldownUntil = 0
local getBall

-- [[ PROBE ]]

local Probe = {}
local _ballSyncConn = nil
local _ballSyncRemote = nil

local parryR
local parryMode = "buffer"
local parryInit = false

local _hooked = false
local _oldNamecall
local _oldIndex

-- [[ REMOTE ]]
local function RegisterRemote(remote)
    if not parryR then
        parryR = remote
    end
end

function Probe.fireParry(flag)
    if not parryR then
        return false
    end

    local p
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        p = buffer.fromstring(flag == 2 and "\x02" or "\x01")
    else
        p = (flag == 2 and "\x02" or "\x01")
    end

    local ok = pcall(function()
        parryR:FireServer(p)
    end)
    return ok
end

function Probe.initParry()
    if not parryR or parryInit then
        return parryInit
    end

    local p
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        p = buffer.fromstring("\x02")
    else
        p = "\x02"
    end

    local ok = pcall(function()
        parryR:FireServer(p)
    end)
    parryInit = ok
    return ok
end

-- [[ SETUP ]]
function Probe.setup()
    if _hooked then
        return
    end

    local ok = pcall(function()
        if type(hookmetamethod) ~= "function" then return end
        
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local args = { ... }

            if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                local isPayload = false

                if args[1] then
                    if typeof(args[1]) == "buffer"
                        or (typeof(args[1]) == "string" and (string.find(args[1], "\x01") or string.find(args[1], "\x02"))) then
                        isPayload = true
                    end
                end

                if isPayload or self.Name == "RemoteEvent" then
                    RegisterRemote(self)
                end
            end

            return _oldNamecall(self, ...)
        end)

        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if not checkcaller()
                and (key == "FireServer" or key == "fireServer")
                and typeof(self) == "Instance"
                and self:IsA("RemoteEvent") then

                if self.Name == "RemoteEvent"
                    or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                    task.spawn(function()
                        RegisterRemote(self)
                    end)
                end
            end

            return _oldIndex(self, key)
        end)
    end)

    if ok then _hooked = true end
end

function Probe.getRemote()
    return parryR, parryMode
end

function Probe.resolveRemote()
    return parryR
end

function Probe.invalidateRemote()
    parryR = nil
    parryInit = false
end

function Probe.invalidate()
    Probe.invalidateRemote()
end

function Probe.setRemote(remote, mode)
    parryR = remote
    parryMode = mode or "buffer"
    parryInit = false
    return true
end

-- [[ SYNC ]]
function Probe.bindBallSync(handler, track)
    if type(handler) ~= "function" then return false end

    local Replicated = game:GetService("ReplicatedStorage")
    local Remotes = Replicated:FindFirstChild("Remotes")
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")

    if not (candidate and candidate:IsA("RemoteEvent")) then
        return _ballSyncConn ~= nil and _ballSyncConn.Connected
    end
    if _ballSyncConn and _ballSyncConn.Connected and _ballSyncRemote == candidate then
        return true
    end
    if _ballSyncConn then
        pcall(function() _ballSyncConn:Disconnect() end)
    end

    local conn = candidate.OnClientEvent:Connect(handler)
    _ballSyncConn = conn
    _ballSyncRemote = candidate
    if type(track) == "function" then track(conn) end
    return true
end

if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

-- [[ PROBE ]]

-- [[ PROBE ]]
Probe.setup()

-- [[ GLOBALS ]]
_G.PhantomConfig = Config
_G.PhantomState  = State
_G.PhantomManual = false
_G.PhantomAutoClash = true
_G.PhantomStop = function()
    State.active = false
    for _, connections in ipairs({ State.charConns, State.conns }) do
        for i = #connections, 1, -1 do
            local c = connections[i]; connections[i] = nil
            if c then pcall(c.Disconnect, c) end
        end
    end
    _G.PhantomManual = false
    _G.__phantomGUI_loaded = nil
    _G.__phantomGUI_src    = nil
    _G.PhantomDiag        = nil
end

-- [[ UTILS ]]
local function track(c)
    if c and c.Disconnect then State.conns[#State.conns + 1] = c end
    return c
end

local function trackCharacter(c)
    if c and c.Disconnect then State.charConns[#State.charConns + 1] = c end
    return c
end

local function disconnectCharacterConnections()
    for i = #State.charConns, 1, -1 do
        local c = State.charConns[i]; State.charConns[i] = nil
        if c then pcall(c.Disconnect, c) end
    end
end

local function tImpCapFor(spd, base, refSpd, lo, hi)
    if spd < 1 then return base end
    local s = math.clamp(refSpd / spd, 0.2, 2.5)
    return math.clamp(base * s, lo, hi)
end
local function coldTimpCap(spd)    return tImpCapFor(spd, CLASH.COLD_TIMP_CAP,   60,  0.05, 0.30) end
local function fastTimpCap(spd)    return tImpCapFor(spd, CLASH.FAST_BALL_TIMP_CAP, 200, 0.03, 0.10) end
local function maintTimpMax(spd)   return tImpCapFor(spd, CLASH.MAINT_TIMP_MAX,  60,  0.06, 0.40) end
local function deactTimpMax(spd)   return tImpCapFor(spd, CLASH.MAINT_TIMP_MAX,  60,  0.08, 0.40) end

-- [[ STATE ]]
local function resetAllState()
    parryR, parryMode, parryInit = nil, "buffer", false
    Probe.invalidateRemote()
    S.ball, S.lastTarget, S.lastTargetAt = nil, -999, 0
    S.clashOn, S.clashAt, S.clashHoldUntil, S.clashOffAt, S.lastClashReact = false, 0, 0, 0, 0
    S.dangerEma, S.lastTImp, S.lastTImpAt, S.tImpRising = 0, 0, 0, false
    S.tImpRiseHist = {0, 0, 0}
    S.lastFireAt, S.teleportLockUntil = 0, 0
    S.targetRingIdx, S.targetCps, S.maintSpam, S.maintSpamOffAt, S.lastMaintCheck = 0, 0, false, 0, 0
    for i = 1, RING_BUF do S.targetRing[i] = 0 end
    S.frameDeltaEMA, S.frameDeltaVar, S.dtIdx = 1 / 60, 0, 0
    S.dtLast, S.dtSum, S.dtSumSq, S.dtCount = 0, 0, 0, 0
    table.clear(S.dtSamples)
    S.jitterEMA = 0
    table.clear(S.dashEvents)
    S.dashPanicUntil = 0
    S.nearestDistance, S.nearestAlive = INF, false
    S.detPhase, S.detEnterAt, S.detEntryTime, S.detExitAt = "IDLE", 0, 0, 0
    S.detDotEma, S.detWasInside, S.detSignal = 0, false, false
    S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
    S.dashAnti = { untilT = 0, src = nil, at = 0 }
    Sync.Speed, Sync.RealPos = 0, V3ZERO
    Sync.ForceDir, Sync.ForcedDir, Sync.DeflectDir = false, V3ZERO, V3ZERO
    Sync.Grace, Sync.Teleported = false, false
    Sync.Target, Sync.lastSyncAt, Sync.forcedAt = -999, 0, 0
    AP.armed, AP.fired, AP.firedAt, AP.inRangeEnterAt, AP.wasInRange = false, false, 0, 0, false
    AP.burstLeft, AP.burstNextAt = 0, 0
    S.fireIntervalEMA, S._lastFireObserved = 80, 0
    RES.stack, RES.lastFireBallRef, RES.lastFireBallAt, RES.lastHitboxAt, RES.lastStackAt = 0, nil, 0, 0, 0
    _G.PhantomManual = false
    _ball, _ballAt = nil, 0
    _burstQueueHead, _burstActive, _nextCpfBurstAt = 1, false, 0
    _spamDebt, _spamWinStart, _spamClickIdx, _spamWasActive = 0, now(), 0, false
    table.clear(_burstQueue)
end

-- [[ PING ]]
local function getPing()
    local p = S.smoothPing
    if not p or p <= 0 then p = PING_BOOT_FALLBACK end
    return math.clamp(p * 0.5, 0, PING_MAX)
end
local function pingOneWay() return math.max(getPing(), CLASH.PING_FLOOR) end
local function pingRTT()    return math.max(getPing() * 2, CLASH.PING_FLOOR * 2) end
local function pingScale()
    return math.clamp((pingOneWay() - CLASH.PING_REF) / CLASH.PING_REF, 0, CLASH.PING_MAX_SCALE)
end
local function pingCredit(raw, spd)
    if spd < 1 then return 0 end
    return math.min(raw, spd * pingOneWay() * CLASH.PING_CREDIT_F)
end
local function tImpCompensated(raw, spd)
    if spd < 1 then return INF end
    return math.max((raw - pingCredit(raw, spd)) / spd, 0)
end

local function samplePing()
    local ok, p = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000 end)
    if ok and type(p) == "number" and p > 0 and p < 0.5 then
        S.smoothPing = S.smoothPing * (1 - PING_EMA) + p * PING_EMA
    end
end

local _pbCache = { ms = -1, ping = -1, jitter = -1, var = -1 }
local function preBufferMs()
    local p, jitter, variance = pingOneWay() * 1000, S.jitterEMA, S.frameDeltaVar
    if math.abs(p - _pbCache.ping) < 1 and math.abs(jitter - _pbCache.jitter) < 0.5
        and math.abs(variance - _pbCache.var) < 1e-7 and _pbCache.ms > 0
    then return _pbCache.ms end
    local PB_PING_FLAT_MS, PB_PING_FULL_MS, PB_PING_AT_MAX_MS = 90, 180, 100
    local PB_JITTER_MULT = 1.4
    local PB_DRIFT_FLOOR, PB_DRIFT_MULT = 20, 0.6
    local PB_FPS_FACTOR, PB_CAP_MS, PB_FLOOR_MS = 0.020, 200, 0
    local pingThrottle = math.clamp((p - PB_PING_FLAT_MS) / (PB_PING_FULL_MS - PB_PING_FLAT_MS), 0, 1)
    local pb = pingThrottle * PB_PING_AT_MAX_MS
              + jitter * PB_JITTER_MULT
              + math.max(variance * 1000 * 100, PB_DRIFT_FLOOR) * PB_DRIFT_MULT
    local fps = S.frameDeltaEMA > 0 and (1 / S.frameDeltaEMA) or 60
    if fps < 60 then pb = pb + (60 - fps) * PB_FPS_FACTOR * 1000 end
    pb = math.clamp(pb * P.PB_WEIGHT, PB_FLOOR_MS, PB_CAP_MS)
    _pbCache.ms, _pbCache.ping, _pbCache.jitter, _pbCache.var = pb, p, jitter, variance
    return pb
end

local function preBufferStuds(spd)
    if not spd or spd < 1 then return 0 end
    return math.min(spd * preBufferMs() / 1000, P.PRE_CAP)
end

local function sampleFrameDelta(dt)
    if dt <= 0 then return end
    S.frameDeltaEMA = S.frameDeltaEMA * 0.9 + dt * 0.1
    if S.dtLast > 0 then
        S.jitterEMA = S.jitterEMA * 0.85 + math.abs(dt - S.dtLast) * 1000 * 0.15
    end
    S.dtLast = dt
    S.dtIdx = (S.dtIdx % FRAME_SAMPLE_COUNT) + 1
    local previous = S.dtSamples[S.dtIdx]
    if previous then
        S.dtSum = S.dtSum - previous
        S.dtSumSq = S.dtSumSq - previous * previous
    else
        S.dtCount = S.dtCount + 1
    end
    S.dtSamples[S.dtIdx] = dt
    S.dtSum = S.dtSum + dt
    S.dtSumSq = S.dtSumSq + dt * dt
    if S.dtCount > 0 then
        local mean = S.dtSum / S.dtCount
        S.frameDeltaVar = math.max((S.dtSumSq / S.dtCount) - mean * mean, 0)
    end
end

-- [[ PROBE ]]
local _apResolveCache, _spamResolveCache, _spamCooldownUntil = 0, 0, 0

local function sendParry()
    local r, m = Probe.getRemote()
    if not r then r = Probe.resolveRemote() end
    local t = now()
    if (t - _apResolveCache) > 3.0 then _apResolveCache = t end
    if not r then return false end
    if not Probe.fireParry(1) then return false end
    S.lastFireAt = t
    local prev = S._lastFireObserved or t
    local interval = (t - prev) * 1000
    if interval > 0 and interval < 1000 then
        S.fireIntervalEMA = S.fireIntervalEMA * 0.7 + interval * 0.3
    end
    S._lastFireObserved = t
    local b = getBall()
    if b and b.Parent then RES.lastFireBallRef, RES.lastFireBallAt = b, t end
    return true
end

local function sendSpam()
    local t = now()
    if t < _spamCooldownUntil then return false end
    if not Probe.fireParry(1) then
        _spamCooldownUntil = t + 0.25
        Probe.invalidateRemote()
        return false
    end
    S.lastFireAt = t
    return true
end

getBall = function()
    local t = now()
    if _ball and _ball.Parent and (t - _ballAt) < _BALL_CACHE_TTL then return _ball end
    if ws then
        local b = ws:FindFirstChild("GameBall", true)
        if b and b.Parent then _ball, _ballAt = b, t; return b end
    end
    _ball, _ballAt = nil, t
    return nil
end

-- [[ NEAREST ALIVE ]]
local function nearestPlayerAlive()
    local t = now()
    if (t - _G_lastNearestPlayerAliveUpdate) < NEAREST_PLAYER_ALIVE_INTERVAL then
        return S.nearestDistance, S.nearestAlive
    end
    _G_lastNearestPlayerAliveUpdate = t
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (myHRP and myHRP.Parent) then
        S.nearestDistance, S.nearestAlive = INF, false
        return INF, false
    end
    local myPos = myHRP.Position
    local curDist, curAlive = INF, false
    for _, p in Players:GetPlayers() do
        if p ~= lp then
            local ch = p.Character
            local php = ch and ch:FindFirstChild("HumanoidRootPart")
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            local alive = php and php.Parent and hum and hum.Parent and hum.Health > 0
            if alive then
                local d = (myPos - php.Position).Magnitude
                if d < curDist then curDist, curAlive = d, true end
            end
        end
    end
    S.nearestDistance, S.nearestAlive = curDist, curAlive
    return S.nearestDistance, S.nearestAlive
end

-- [[ BALL SPEED / POSITION ]]
local function ballSpeed(ball, t)
    if (t - Sync.lastSyncAt) < SYNC_FRESH_T and Sync.Speed > 0 then return Sync.Speed end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    return (ok and typeof(av) == "Vector3") and av.Magnitude or 0
end

local function ballPos(ball, t)
    if (t - Sync.lastSyncAt) < SYNC_FRESH_T and Sync.RealPos ~= V3ZERO then return Sync.RealPos end
    if Sync.RealPos ~= V3ZERO and Sync.Speed > 0 and (t - Sync.lastSyncAt) < 2.0 then
        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
            return Sync.RealPos + av * (t - Sync.lastSyncAt)
        end
    end
    return ball.Position
end

local _liveTImpCache = { tImp = INF, bp = V3ZERO, spd = 0, at = 0 }
local function liveTImp()
    local n = now()
    if (n - _liveTImpCache.at) < LIVE_TIMP_TTL then return _liveTImpCache end
    local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()
    if hr and hr.Parent and ball and ball.Parent then
        local bp = ball.Position
        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
        if spd < 1 then
            _liveTImpCache = { tImp = INF, bp = bp, spd = 0, at = n }
        else
            _liveTImpCache = { tImp = tImpCompensated((hr.Position - bp).Magnitude, spd), bp = bp, spd = spd, at = n }
        end
    else
        _liveTImpCache = { tImp = INF, bp = V3ZERO, spd = 0, at = n }
    end
    return _liveTImpCache
end

local function computeTImp(hrp, ball, t)
    local bp, spd = ball.Position, ballSpeed(ball, t)
    if spd < 1 then return INF, bp, spd end
    return tImpCompensated((hrp.Position - bp).Magnitude, spd), bp, spd
end

local function isTargeted()
    return Sync.Target == lp.UserId or S.lastTarget == lp.UserId or ws:GetAttribute("GameBallTarget") == lp.UserId
end

local function updateTargetCps(t, freshWin)
    local winStart = t - CLASH.CPS_WIN
    local cnt = 0
    for i = 1, RING_BUF do
        local ts = S.targetRing[i]
        if ts and ts >= winStart and (not freshWin or ts >= t - freshWin) then cnt = cnt + 1 end
    end
    S.targetCps = cnt / CLASH.CPS_WIN
end

local function ringPush(t)
    S.targetRingIdx = (S.targetRingIdx % RING_BUF) + 1
    S.targetRing[S.targetRingIdx] = t
end

-- [[ CLASH SNAPSHOT ]]
local _ctxCache = { t = 0, valid = false, bDist = 0, tImp = INF, spd = 0, nearest = INF, nearestAlive = false, panic = false }
local CLASH_SNAPSHOT_TTL = 0.05

local function clashSnapshot()
    local t = now()
    if _ctxCache.valid and (t - _ctxCache.t) < CLASH_SNAPSHOT_TTL then return _ctxCache end
    local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (hr and hr.Parent) then _ctxCache.valid = false; return nil end
    updateTargetCps(t, CLASH.RING_FRESH_MAX)
    local ball = getBall()
    if not (ball and ball.Parent) then _ctxCache.valid = false; return nil end
    local nearest, nearestAlive = nearestPlayerAlive()
    local bp = ball.Position
    local bDist = (hr.Position - bp).Magnitude
    local panic = nearestAlive and (nearest <= CLASH.PANIC_DIST and bDist <= CLASH.PANIC_BALL)
    local live = liveTImp()
    local tImp, spd = live.tImp, live.spd
    if spd < 1 then local ti, _, s2 = computeTImp(hr, ball, t); tImp, spd = ti, s2 end
    _ctxCache.t, _ctxCache.valid = t, true
    _ctxCache.hr = hr
    _ctxCache.ball, _ctxCache.bp = ball, bp
    _ctxCache.nearest, _ctxCache.nearestAlive = nearest, nearestAlive
    _ctxCache.bDist, _ctxCache.panic = bDist, panic
    _ctxCache.tImp, _ctxCache.spd = tImp, spd
    return _ctxCache
end

local function resRadiusBonus() return math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP) end

local function tickResilience(t)
    if RES.stack <= 0 then return end
    local since = t - RES.lastStackAt
    if since > (P.RES_HOLD_T + P.RES_DECAY_T) then RES.stack = 0; return end
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

-- [[ DASH TRACK ]]
local function updateDashTrack(t)
    if (t - _lastDashTrackUpdate) < DASH_TRACK_INTERVAL then return end
    _lastDashTrackUpdate = t
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (myHRP and myHRP.Parent) then
        table.clear(S.dashEvents)
        return
    end
    local myPos = myHRP.Position
    local curDist, curAlive = INF, false
    local playersToCheck = {}
    local fullScan = (t - _lastFullPlayerScan) >= FULL_PLAYER_SCAN_INTERVAL
    if fullScan then
        _lastFullPlayerScan = t
        for _, p in Players:GetPlayers() do
            if p ~= lp then table.insert(playersToCheck, p) end
        end
    else
        for uid in pairs(S.dashEvents) do
            local p = Players:GetPlayerByUserId(uid)
            if p and p ~= lp then table.insert(playersToCheck, p) end
        end
        for _, p in Players:GetPlayers() do
            if p ~= lp and not S.dashEvents[p.UserId] then
                local ch = p.Character
                local php = ch and ch:FindFirstChild("HumanoidRootPart")
                if php and php.Parent and (myPos - php.Position).Magnitude <= PLAYER_SCAN_RADIUS then
                    table.insert(playersToCheck, p)
                end
            end
        end
    end
    local processed = {}
    for _, p in ipairs(playersToCheck) do
        if processed[p.UserId] then continue end
        processed[p.UserId] = true
        local ch = p.Character
        local php = ch and ch:FindFirstChild("HumanoidRootPart")
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        local alive = php and php.Parent and hum and hum.Parent and hum.Health > 0
        if alive then
            local d = (myPos - php.Position).Magnitude
            if d < curDist then curDist, curAlive = d, true end
            local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
            local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
            local dir = (ok and typeof(av) == "Vector3" and av.Magnitude > 0.1) and av.Unit or nil
            local ev = S.dashEvents[p.UserId]
            if spd >= CLASH.DASH_SPD_THRESH and dir then
                if not ev then
                    S.dashEvents[p.UserId] = { spd = spd, dir = dir, at = t, startedAt = t, confirmed = false }
                else
                    ev.spd, ev.dir, ev.at = spd, dir, t
                    if not ev.confirmed and spd >= CLASH.DASH_SPD_CONFIRM then
                        ev.confirmed = true
                        ev.startedAt = t
                    end
                end
            elseif ev and ev.confirmed and spd >= CLASH.DASH_SPD_RELEASE and dir then
                ev.spd, ev.dir, ev.at = spd, dir, t
            elseif ev and ev.confirmed and spd >= CLASH.DASH_SPD_THRESH then
                ev.spd, ev.at = spd, t
            else
                S.dashEvents[p.UserId] = nil
            end
        else
            S.dashEvents[p.UserId] = nil
        end
    end
    S.nearestDistance, S.nearestAlive = curDist, curAlive
    for uid in pairs(S.dashEvents) do
        if not processed[uid] then S.dashEvents[uid] = nil end
    end
    for uid, ev in pairs(S.dashEvents) do
        if ev and ev.confirmed and ev.dir and ev.spd then
            local dur = ev.at - ev.startedAt
            if dur > CLASH.DASH_DUR_MAX then
                S.dashEvents[uid] = nil
            else
                local pl = Players:GetPlayerByUserId(uid)
                local ch = pl and pl.Character
                local php = ch and ch:FindFirstChild("HumanoidRootPart")
                if not (php and php.Parent) then
                    S.dashEvents[uid] = nil
                elseif dur >= CLASH.DASH_DUR_MIN then
                    local toMe = myPos - php.Position
                    local dist = toMe.Magnitude
                    if dist <= CLASH.DASH_PANIC_DIST and dist > 0.1 then
                        local dot = ev.dir:Dot(toMe.Unit)
                        if dot >= CLASH.DASH_PANIC_DOT and ev.spd >= CLASH.DASH_SPD_CONFIRM then
                            S.dashPanicUntil = math.max(S.dashPanicUntil, t + CLASH.DASH_PANIC_WINDOW)
                        end
                    end
                end
            end
        end
    end
end

local function clearClash()
    S.clashOn, S.clashHoldUntil = false, 0
    S.clashOffAt = now()
end

-- [[ ANTI-DASH ]]
local _antidashCooldown = {}
local function reportDash(player)
    if not player or player == lp then return end
    if not State.active then return end
    local t = now()
    local last = _antidashCooldown[player.UserId]
    if last and (t - last) < CLASH.ANTIDASH_COOLDOWN then return end
    _antidashCooldown[player.UserId] = t
    local ch = player.Character
    if not (ch and ch.Parent) then return end
    local php = ch:FindFirstChild("HumanoidRootPart")
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (php and php.Parent and myHRP and myHRP.Parent) then return end
    local baseParryRad = P.DEFLECT_R + resRadiusBonus() + P.RAD_FLOOR
    local rad = math.clamp(baseParryRad, CLASH.ANTIDASH_RAD_MIN, CLASH.ANTIDASH_RAD_MAX)
    local toMe = myHRP.Position - php.Position
    local dist = toMe.Magnitude
    if dist > rad or dist < 0.1 then return end
    local dot = 1
    local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
    if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
        dot = av.Unit:Dot(toMe.Unit)
    end
    if dot < CLASH.ANTIDASH_DOT_MIN then return end
    local untilT = t + CLASH.ANTIDASH_PANIC_HOLD
    S.dashAnti.untilT = math.max(S.dashAnti.untilT, math.min(untilT, t + CLASH.ANTIDASH_PANIC_MAX))
    S.dashAnti.src   = player
    S.dashAnti.at    = t
end

local _antidashHooked = {}
local function _hookPlayerAntiDash(player)
    if not player or player == lp then return end
    if _antidashHooked[player] then return end
    _antidashHooked[player] = true
    local function attach(char)
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        local anim = hum:WaitForChild("Animator", 5)
        if not anim then return end
        task.defer(function()
            pcall(function()
                for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
                    local n = (tr.Name or ""):lower()
                    local an = tr.Animation and tr.Animation.Name or ""
                    if n:find("dash") or an:lower():find("dash") then
                        reportDash(player)
                        break
                    end
                end
            end)
        end)
        pcall(function()
            anim.AnimationPlayed:Connect(function(track)
                if not track or not track.Animation then return end
                local n = (track.Name or ""):lower()
                local an = track.Animation.Name or ""
                if n:find("dash") or an:lower():find("dash") then
                    reportDash(player)
                end
            end)
        end)
    end
    if player.Character then attach(player.Character) end
    pcall(function() player.CharacterAdded:Connect(attach) end)
end

local function installAntiDashHooks()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then _hookPlayerAntiDash(p) end
    end
    pcall(function() Players.PlayerAdded:Connect(function(p) if p ~= lp then _hookPlayerAntiDash(p) end end) end)
    pcall(function() Players.PlayerRemoving:Connect(function(p)
        _antidashHooked[p] = nil
        _antidashCooldown[p.UserId] = nil
    end) end)
end

-- [[ DETECTOR ]]
local function getDetectorRadius(spd)
    local t = math.clamp((spd or 0) / CLASH.DET_RAD_SPD_REF, 0, 1)
    return CLASH.DET_RAD_MIN + (CLASH.DET_RAD_MAX - CLASH.DET_RAD_MIN) * t
end

local function tickReturnDetector(t, hr, ball)
    S.detSignal = false
    if not (hr and hr.Parent and ball and ball.Parent) then
        S.detPhase, S.detDotEma, S.detWasInside = "IDLE", 0, false
        return
    end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return end
    local spd    = av.Magnitude
    local radius = getDetectorRadius(spd)
    local toMe   = hr.Position - ball.Position
    local dist   = toMe.Magnitude
    local dotRaw = av:Dot(toMe.Unit)
    if dist <= radius * 1.2 then
        S.detDotEma = S.detDotEma * (1 - CLASH.DET_DOT_EMA) + dotRaw * CLASH.DET_DOT_EMA
    else
        S.detDotEma = 0
    end
    local isInside  = dist <= radius
    local dotComing = S.detDotEma >  CLASH.DET_DOT_THRESH
    local dotGoing  = S.detDotEma < -CLASH.DET_DOT_THRESH
    if S.detPhase == "EXITED" and (t - S.detExitAt) > CLASH.DET_TIMEOUT then
        S.detPhase = "IDLE"
    end
    if S.detPhase == "IDLE" then
        if (isInside and not S.detWasInside) or (not isInside and dotComing) then
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end
    elseif S.detPhase == "INSIDE" then
        if (not isInside and S.detWasInside) or (isInside and dotGoing) then
            S.detPhase  = "EXITED"
            S.detExitAt = t
        end
    elseif S.detPhase == "EXITED" then
        local delta  = t - S.detExitAt
        local limiar = S.detEntryTime * CLASH.DET_RETURN_FACTOR
        if (isInside and not S.detWasInside) or dotComing then
            if delta <= limiar and dotComing then S.detSignal = true end
            local entryTime = dist > 0.1 and (dist / spd) or 0.01
            S.detPhase     = "INSIDE"
            S.detEnterAt   = t
            S.detEntryTime = entryTime
        end
    end
    S.detWasInside = isInside
end

-- [[ MAINTENANCE ]]
local function maintRadius(spd)
    local base = math.max(P.DEFLECT_R + preBufferStuds(spd) + resRadiusBonus(), CLASH.MAINT_BALL_RADIUS)
    return math.min(base, 55)
end

local function shouldMaintainClash()
    if not S.clashOn then return false end
    local t = now()
    if (t - S.clashAt) < CLASH.MAINT_HOLD_MIN then return true end
    local ctx = clashSnapshot()
    if not ctx then return false end
    if ctx.bDist > CLASH.MAINT_BALL_GONE_DIST then return false end
    if ctx.bDist <= maintRadius(ctx.spd) then return true end
    if ctx.tImp > 0 and ctx.tImp <= maintTimpMax(ctx.spd) then return true end
    if isTargeted() then return true end
    if (t - S.lastFireAt) < CLASH.MAINT_PARRY_KEEP then return true end
    if (t - S.lastTargetAt) < CLASH.MAINT_TARGET_KEEP then return true end
    return false
end

local function tickMaintenance()
    if not S.clashOn then return end
    local t = now()
    if (t - S.lastMaintCheck) < CLASH.MAINT_CHECK_INTERVAL then return end
    S.lastMaintCheck = t
    if not shouldMaintainClash() then clearClash() end
end

local function isBallApproaching(hrp, ball)
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return true end
    local toMe = hrp.Position - ball.Position
    if toMe.Magnitude < 1 then return true end
    return av:Dot(toMe.Unit) > 0.25
end

local function shouldDeactivateClash()
    if not S.clashOn then return false end
    local t = now()
    if t < math.max(S.clashAt + CLASH.MIN_HOLD, S.clashHoldUntil) then return false end
    if (t - S.clashAt) > CLASH.MAX_HOLD then return true end
    local myChar = lp.Character
    if not (myChar and myChar.Parent) then return true end
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not (myHum and myHum.Parent and myHum.Health > 0) then return true end
    if t < S.teleportLockUntil then return true end
    local ball = getBall()
    if not (ball and ball.Parent) then return true end
    local ctx = clashSnapshot()
    if not ctx then return true end
    if ctx.bDist > CLASH.MAINT_BALL_GONE_DIST then return true end
    local deactRad = math.clamp(P.DEFLECT_R + P.RAD_FLOOR, 18, 30)
    if ctx.bDist > deactRad then return true end
    if ctx.tImp > deactTimpMax(ctx.spd) then return true end
    local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if hr and hr.Parent and ctx.ball and ctx.ball.Parent then
        if not isBallApproaching(hr, ctx.ball) and ctx.bDist > 15 then return true end
    end
    if ctx.spd < 1 and ctx.bDist > 20 then return true end
    return false
end

-- [[ BURST ]]
local function _activateBurst(t)
    S.burstState          = "ON"
    S.burstOnStart        = t
    S.burstSignalDuringOn = false
    S.clashOn             = true
    S.clashAt             = t
    S.clashHoldUntil      = t + CLASH.BURST_ON_MS
    S.lastClashReact      = t
    S.clashOffAt          = 0
    S.lastTImp, S.lastTImpAt, S.tImpRising = 0, 0, false
    S.tImpRiseHist        = {0, 0, 0}
    S.lastMaintCheck      = t
    local c = math.max(tonumber(Config.CPS) or DEFAULT_CPS, 1)
    _spamDebt  = (1 / c) * CLASH.SPAM_PRE_FILL_FRAMES
    _burstActive = false
end

local function evaluateClash(t, hr, ball)
    if Config.AutoClash == false or _G.PhantomManual then
        if S.clashOn then clearClash() end
        S.burstState = "IDLE"
        S.burstSignalDuringOn = false
        return
    end
    tickReturnDetector(t, hr, ball)
    if S.clashOn then
        if shouldDeactivateClash() then
            clearClash()
            S.burstState          = "IDLE"
            S.burstSignalDuringOn = false
        end
        return
    end
    local antiDashActive = S.dashAnti.untilT > t
    local canFire = (S.detSignal and isTargeted()) or antiDashActive
    if S.burstState == "IDLE" then
        if canFire then _activateBurst(t) end
    elseif S.burstState == "ON" then
        if S.detSignal then S.burstSignalDuringOn = true end
        if (t - S.burstOnStart) >= CLASH.BURST_ON_MS then
            if S.burstSignalDuringOn then
                S.burstOnStart        = t
                S.burstSignalDuringOn = false
                S.clashHoldUntil      = t + CLASH.BURST_ON_MS
            else
                S.burstState    = "OFF"
                S.burstOffStart = t
            end
        end
    elseif S.burstState == "OFF" then
        if canFire then
            _activateBurst(t)
        elseif (t - S.burstOffStart) >= CLASH.BURST_OFF_MS then
            S.burstState = "IDLE"
        end
    end
end

-- [[ BIND PARRY ]]
local apBind = 0
local function bindParry(ch)
    apBind = apBind + 1
    local id = apBind
    if not (ch and ch.Parent) then return end
    local hrp = ch:FindFirstChild("HumanoidRootPart") or ch:WaitForChild("HumanoidRootPart", 1)
    if id ~= apBind or not (hrp and hrp.Parent) then return end
    AP.fired, AP.armed = false, false
    trackCharacter(RunService.Heartbeat:Connect(function(dt)
        if id ~= apBind or not (ch.Parent and hrp.Parent) then return end
        if not Config.AutoParry then AP.fired, AP.burstLeft = false, 0; return end
        local t = now()
        if t < S.teleportLockUntil or Sync.Grace then return end
        if S.clashOn or _G.PhantomManual then return end
        tickResilience(t)
        local ball = getBall()
        if not (ball and ball.Parent) then return end
        if Sync.Target ~= lp.UserId then AP.armed = false; return end
        local syncFresh = (t - Sync.lastSyncAt) < 0.3
        local bp = (syncFresh and Sync.RealPos ~= V3ZERO) and Sync.RealPos or ball.Position
        local spd
        if syncFresh and Sync.Speed > 0 then
            spd = Sync.Speed
        else
            local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
            spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
        end
        if spd < P.MIN_SPD then return end
        local tickMs = (S.frameDeltaEMA > 0 and S.frameDeltaEMA * 1000) or 16.67
        local leadSec = math.max(pingRTT() * P.LEAD_RTT_MULT + (P.LEAD_TICK_FRAMES * tickMs / 1000), P.LEAD_PING_FLOOR)
        local leadB   = math.min(spd * leadSec, P.LEAD_CAP)
        local pbStuds = math.min(preBufferStuds(spd), P.PRE_CAP)
        local parryRad = math.max(P.DEFLECT_R + leadB + pbStuds + resRadiusBonus(), P.RAD_FLOOR)
        local dx, dy, dz = hrp.Position.X - bp.X, hrp.Position.Y - bp.Y, hrp.Position.Z - bp.Z
        if dx*dx + dy*dy + dz*dz > parryRad * parryRad then
            AP.wasInRange, AP.inRangeEnterAt = false, 0
            return
        end
        AP.wasInRange = true
        if AP.fired then
            local toMe = hrp.Position - bp
            local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
            local vel = (ok and typeof(av) == "Vector3") and av or nil
            if vel and vel.Magnitude > 0.5 then
                local currentSpd = vel.Magnitude
                local rad = math.clamp(currentSpd * P.RAD_WIN + P.RAD_OFF, P.RAD_MIN, P.RAD_MAX) + P.RAD_PRE
                local distance = toMe.Magnitude
                local inRange = distance <= rad
                local closing = distance > 1e-4 and vel:Dot(toMe.Unit) or currentSpd
                local timeToHit = currentSpd > 1 and (distance / currentSpd) or INF
                local imminent = timeToHit < P.TRIGGER_TTH
                if imminent and inRange and (t - AP.firedAt) > P.MIN_REFIRE_GAP and AP.burstLeft == 0 then
                    if sendParry() then
                        AP.firedAt = t
                        AP.burstLeft = P.BURST_SIZE - 1
                        local gap = closing > 80 and P.BURST_GAP_FAST or P.BURST_GAP_SLOW
                        AP.burstNextAt = t + gap
                    end
                elseif AP.burstLeft > 0 and t >= AP.burstNextAt then
                    if sendParry() then
                        AP.burstLeft = AP.burstLeft - 1
                        local gap = closing > 80 and P.BURST_GAP_FAST or P.BURST_GAP_SLOW
                        AP.burstNextAt = t + gap
                        AP.firedAt = t
                    else
                        AP.burstLeft = 0
                    end
                end
            end
            return
        end
        if AP.firedAt > Sync.lastSyncAt then return end
        if (t - AP.firedAt) < P.FIRE_LOCK then return end
        S.pingTimer = S.pingTimer + dt
        if S.pingTimer >= PING_SAMPLE then S.pingTimer = 0; samplePing() end
        AP.burstLeft, AP.burstNextAt = 0, 0
        if sendParry() then
            AP.fired, AP.firedAt = true, t
        else
            AP.fired = false
        end
    end))
    trackCharacter(ch.AncestryChanged:Connect(function(_, parent)
        if not parent then apBind = apBind + 1 end
    end))
end

-- [[ KEYS ]]
local keyConn, keyHoldConn, installedKeySignature
local function currentKeySignature()
    return table.concat({
        tostring(Config.Keybind), tostring(Config.SpamKeybind), tostring(Config.SpamMode or "Toggle"),
    }, "|")
end

local function installKeys()
    if keyConn     then pcall(keyConn.Disconnect, keyConn);     keyConn     = nil end
    if keyHoldConn then pcall(keyHoldConn.Disconnect, keyHoldConn); keyHoldConn = nil end
    local panic, spam = Config.Keybind, Config.SpamKeybind
    local mode = Config.SpamMode == "Hold" and "Hold" or "Toggle"
    installedKeySignature = currentKeySignature()
    keyConn = UIS.InputBegan:Connect(function(i, gpe)
        if gpe then return end
        if i.KeyCode == panic then
            clearClash(); AP.fired = false; _G.PhantomManual = false
        elseif i.KeyCode == spam then
            _G.PhantomManual = (mode == "Hold") or not _G.PhantomManual
        end
    end)
    track(keyConn)
    if mode == "Hold" then
        keyHoldConn = UIS.InputEnded:Connect(function(i) if i.KeyCode == spam then _G.PhantomManual = false end end)
        track(keyHoldConn)
    end
end

-- [[ CONFIG ]]
local CONFIG_KEYS = { "AutoParry", "AutoClash", "CPS", "SpamRateMode", "CustomCPS", "Keybind", "SpamKeybind", "SpamMode" }
local guiReady, _pollAcc = false, 0
local function applyConfig()
    local source = _G.PhantomConfig
    if type(source) ~= "table" then return end
    for _, key in ipairs(CONFIG_KEYS) do
        if source[key] ~= nil then Config[key] = source[key] end
    end
    Config.CPS = math.clamp(tonumber(Config.CPS) or DEFAULT_CPS, 1, 1000)
    Config.SpamRateMode = Config.SpamRateMode == "CPF" and "CPF" or "CPS"
    Config.SpamMode = Config.SpamMode == "Hold" and "Hold" or "Toggle"
end

local function pollGUI(dt)
    applyConfig()
    _pollAcc = _pollAcc + dt
    if _pollAcc < 0.5 then return end
    _pollAcc = 0
    guiReady = true
    if installedKeySignature ~= currentKeySignature() then installKeys() end
end
installKeys()

-- [[ SPAM ]]
local _fpsBuf, _fpsBufIdx, _fpsLast, _fpsSmooth = {}, 0, now(), 60
local function sampleFPS(dt)
    if dt <= 0 then return end
    _fpsBufIdx = (_fpsBufIdx % 60) + 1
    _fpsBuf[_fpsBufIdx] = 1 / dt
    local t = now()
    if (t - _fpsLast) < P.CPF_FPS_SAMPLE_T then return end
    _fpsLast = t
    local sum, cnt = 0, 0
    for i = 1, 60 do local v = _fpsBuf[i]; if v then sum, cnt = sum + v, cnt + 1 end end
    if cnt > 0 then _fpsSmooth = sum / cnt end
end

local function getCPF()
    local value = tonumber(Config.CPS) or 1
    return math.clamp(math.floor(value + 0.5), 1, SPAM.MAX_PER_ITER)
end

local _spacingCacheMs, _lastPingForSpacing = -1, -1
local function calcSpacingMs()
    local p = pingOneWay()
    if math.abs(p - _lastPingForSpacing) < 0.002 and _spacingCacheMs > 0 then return _spacingCacheMs end
    _lastPingForSpacing = p
    p = math.max(p, P.CPF_PING_FLOOR)
    _spacingCacheMs = math.clamp(
        P.CPF_MIN_SPACING_MS * math.max(p / P.CPF_PING_REF, 1.0),
        P.CPF_MIN_SPACING_MS, P.CPF_MAX_SPACING_MS
    )
    return _spacingCacheMs
end

local function queueBurst(t)
    local count = getCPF()
    local spacing = calcSpacingMs() / 1000
    table.clear(_burstQueue)
    _burstQueueHead = 1
    _burstActive = true
    for i = 1, count do _burstQueue[i] = t + (i - 1) * spacing end
end

local function drainBurst(t)
    if not _burstActive then return true end
    local head = _burstQueueHead
    local length = #_burstQueue
    local fired = 0
    while head <= length and fired < SPAM.MAX_PER_ITER do
        local fireAt = _burstQueue[head]
        if not fireAt or t < fireAt then break end
        if not sendSpam() then return false end
        head, fired = head + 1, fired + 1
    end
    _burstQueueHead = head
    if head > length then _burstActive = false; table.clear(_burstQueue) end
    return true
end

local function _spamShouldRun()
    if _G.PhantomManual == true then return true end
    if not S.clashOn then return false end
    local ctx = clashSnapshot()
    if not ctx then return false end
    local spamRad = math.clamp(P.DEFLECT_R + P.RAD_FLOOR, 18, 30)
    return ctx.bDist <= spamRad
end

local function tickSpam(dt)
    sampleFPS(dt)
    if not _spamShouldRun() then
        if _spamWasActive then
            _spamDebt, _spamWinStart, _spamWasActive = 0, now(), false
            _burstActive, _burstQueueHead, _nextCpfBurstAt = false, 1, 0
            table.clear(_burstQueue)
        end
        return
    end
    _spamWasActive = true
    if Config.SpamRateMode == "CPF" then
        local t = now()
        if not drainBurst(t) then return end
        if not _burstActive and t >= _nextCpfBurstAt then
            queueBurst(t)
            _nextCpfBurstAt = t + math.max(dt, 1 / math.max(_fpsSmooth, 1))
            drainBurst(t)
        end
        return
    end
    if dt > SPAM.DT_CAP then dt = SPAM.DT_CAP end
    _spamDebt = _spamDebt + dt
    local c = tonumber(Config.CPS) or DEFAULT_CPS
    if c < 1 then c = 1 end
    local step, n = 1 / c, 0
    while _spamDebt >= step and n < SPAM.MAX_PER_ITER do
        if not _spamShouldRun() then _spamDebt = 0; break end
        _spamClickIdx = _spamClickIdx + 1
        if not sendSpam() then _spamDebt = 0; break end
        _spamDebt = _spamDebt - step
        n = n + 1
    end
end

-- [[ BIND CHARACTER ]]
local function bindChar(ch)
    if not (ch and ch.Parent) or ch ~= lp.Character then return end
    local hrp = ch:WaitForChild("HumanoidRootPart", 10)
    if ch ~= lp.Character or not (hrp and hrp.Parent) then return end
    local dead = false
    trackCharacter(ch.AncestryChanged:Connect(function(_, parent)
        if not parent then dead = true; resetAllState() end
    end))
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if hum then trackCharacter(hum.Died:Connect(resetAllState)) end
    trackCharacter(RunService.Heartbeat:Connect(function(dt)
        if dead or not State.active then return end
        if not (ch.Parent and hrp.Parent) then dead = true; return end
        pollGUI(dt)
        local t = now()
        updateDashTrack(t)
        local ball = getBall()
        evaluateClash(t, hrp, ball)
        tickMaintenance()
        _ctxCache.valid = false
        tickSpam(dt)
        sampleFrameDelta(dt)
    end))
end

local function onChar(ch)
    disconnectCharacterConnections()
    resetAllState()
    task.defer(function() pcall(bindParry, ch) end)
    task.defer(function() pcall(bindChar,  ch) end)
end

track(lp.CharacterAdded:Connect(onChar))
if lp.Character then task.defer(function() pcall(onChar, lp.Character) end) end

-- [[ SYNC ]]
local function onBallSync(d)
    if typeof(d) ~= "table" then return end
    local t = now()
    if type(d.Speed) == "number" then Sync.Speed = d.Speed end
    if typeof(d.RealPosition) == "Vector3" then Sync.RealPos = d.RealPosition end
    if typeof(d.DeflectDirection) == "Vector3" then Sync.DeflectDir = d.DeflectDirection end
    if type(d.Grace) == "boolean" then Sync.Grace = d.Grace end
    if type(d.ForceDirection) == "boolean" then
        if d.ForceDirection and not Sync.ForceDir then Sync.forcedAt = t end
        Sync.ForceDir = d.ForceDirection
    end
    if typeof(d.ForcedDirection) == "Vector3" then Sync.ForcedDir = d.ForcedDirection end
    Sync.lastSyncAt = t
    if d.Teleported == true then
        S.teleportLockUntil = t + TELEPORT_LOCK
        AP.fired = false
        clearClash()
        Sync.Teleported = true
        return
    end
    Sync.Teleported = false
    local newTarget = d.TargetPlayerID
    if newTarget ~= S.lastTarget and newTarget == lp.UserId then Sync.Grace = false end
    if newTarget == S.lastTarget then Sync.Target = newTarget; return end
    local previousTarget = S.lastTarget
    S.lastTarget, S.lastTargetAt, Sync.Target = newTarget, t, newTarget
    ringPush(t)
    AP.armed = newTarget == lp.UserId
    AP.fired = false
    local targeted = newTarget == lp.UserId
    if targeted and Config.AutoClash ~= false and not _G.PhantomManual
        and previousTarget ~= lp.UserId and previousTarget ~= -999
    then
        local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        local ball = getBall()
        if hr and hr.Parent and ball and ball.Parent then
            local bp = ballPos(ball, t)
            local bDist = (hr.Position - bp).Magnitude
            local speed = ballSpeed(ball, t)
            local impactTime = speed > 1 and tImpCompensated(bDist, speed) or INF
            if bDist <= CLASH.BALL_HARD_CAP
                and impactTime <= CLASH.OFF_FAST
                and (t - S.lastClashReact) >= CLASH.REACT_CD
            then
                S.clashOn = true
                S.clashAt = t
                S.clashHoldUntil = t + CLASH.HOLD
                S.lastClashReact = t
            end
        end
    end
end

Probe.bindBallSync(onBallSync, track)

installAntiDashHooks()

-- [[ BALL WATCHER ]]
local function setBall(b) _ball, _ballAt = b, now() end
local function clearBallRef(b) if b == _ball then _ball, _ballAt = nil, now() end end
local gameFolder  = ws:WaitForChild("Game", 30)
local ballWatcher = gameFolder and gameFolder:FindFirstChild("Ball")
if ballWatcher then
    track(ballWatcher.ChildAdded:Connect(function(c)
        if c.Name == "GameBall" and c:IsA("BasePart") then setBall(c) end
    end))
    track(ballWatcher.ChildRemoved:Connect(clearBallRef))
    local existing = ballWatcher:FindFirstChild("GameBall")
    if existing and existing:IsA("BasePart") then setBall(existing) end
end

track(ws.DescendantAdded:Connect(function(d)
    if not State.active then return end
    if d.Name == "GameBall" and d:IsA("BasePart") then
        setBall(d)
        return
    end
    if d.Name ~= "HitboxGrow" or not d:IsA("BasePart") then return end
    local t = now()
    if (t - RES.lastFireBallAt) > P.RES_HITBOX_OWN_WINDOW then return end
    if not (RES.lastFireBallRef and RES.lastFireBallRef.Parent) then return end
    if (t - RES.lastHitboxAt) < 0.4 then return end
    local dp = d.Position
    if typeof(dp) ~= "Vector3" then return end
    if (RES.lastFireBallRef.Position - dp).Magnitude > P.RES_HITBOX_PROX then return end
    RES.lastHitboxAt, RES.lastStackAt = t, t
    RES.stack = RES.stack + 1
    local maxStack = math.floor((P.RES_CAP - P.RES_BASE) / P.RES_PER_PARRY)
    if RES.stack > maxStack then RES.stack = maxStack end
end))

-- [[ GUI ]]
local GUI_URL = "https://raw.githubusercontent.com/Repp35/Exodus/main/ui-1.luau"

task.spawn(function()
    for _ = 1, 3 do task.defer(samplePing); task.wait(0.2) end
end)

task.spawn(function()
    while State.active do
        if guiReady then applyConfig() end
        if not (_ball and _ball.Parent) then _ball, _ballAt = nil, 0; getBall() end
        task.wait(0.5)
    end
end)

task.defer(function()
    if _G.__phantomGUI_loaded then return end
    local src = rawget(_G, "__phantomGUI_src")
    if type(src) ~= "string" or #src == 0 then
        local ok, body = pcall(function()
            if type(request) == "function" then
                local r = request({ Url = GUI_URL, Method = "GET" })
                return r and r.Body
            end
            return type(game.HttpGet) == "function" and game:HttpGet(GUI_URL)
        end)
        if ok and type(body) == "string" and #body > 0 then src = body end
    end
    if type(src) ~= "string" or #src == 0 or type(loadstring) ~= "function" then return end
    local fn = loadstring(src)
    if not fn then return end
    _G.__phantomGUI_src = src
    if pcall(fn) then _G.__phantomGUI_loaded = true end
end)

task.defer(function()
    task.wait(0.1)
    print(("[%s v%s Unified] iniciando... (Auto Spam sem TL) | GameId=%s | Ball=%s | ResStack=%d | PB=%.0fms pingOW=%.0fms | MAINT: interval=%.0fms holdMin=%.0fms radius=%.0f preFill=%d frames"):format(
        SCRIPT_NAME, SCRIPT_VERSION, tostring(game.GameId),
        tostring(getBall() ~= nil), RES.stack,
        preBufferMs(), pingOneWay() * 1000,
        CLASH.MAINT_CHECK_INTERVAL * 1000, CLASH.MAINT_HOLD_MIN * 1000, CLASH.MAINT_BALL_RADIUS, CLASH.SPAM_PRE_FILL_FRAMES))
end)

-- [[ DIAGNOSTICS ]]
local _diagLast = 0
local function pushDiagnostics()
    local t = now()
    if (t - _diagLast) < 0.5 then return end
    _diagLast = t
    local b = getBall()
    local r, m = Probe.getRemote()
    _G.PhantomDiag = {
        version = SCRIPT_VERSION, scriptName = SCRIPT_NAME,
        gameId = game.GameId, placeId = game.PlaceId,
        parryRemote = (r and r:GetFullName()) or nil, parryMode = m or nil,
        ballOk = b ~= nil, ballPath = b and b:GetFullName() or nil,
        syncOk = (t - Sync.lastSyncAt) < 5, lastSyncAt = Sync.lastSyncAt,
        ping = S.smoothPing, pingOneWayMs = pingOneWay() * 1000,
        preBufferMs = preBufferMs(), jitterMs = S.jitterEMA, frameVar = S.frameDeltaVar,
        fireIntEMA = S.fireIntervalEMA, fps = _fpsSmooth,
        cps = Config.CPS, spamRateMode = Config.SpamRateMode,
        autoParry = Config.AutoParry == true, autoClash = Config.AutoClash ~= false,
        keybind = Config.Keybind and Config.Keybind.Name or nil,
        spamKeybind = Config.SpamKeybind and Config.SpamKeybind.Name or nil,
        spamMode = Config.SpamMode or "Toggle", manualSpam = _G.PhantomManual == true,
        clashOn = S.clashOn, targetCps = S.targetCps, dangerEma = S.dangerEma,
        antiDashActive = S.dashAnti.untilT > t,
        antiDashUntil  = S.dashAnti.untilT,
        antiDashSrc    = S.dashAnti.src and S.dashAnti.src.Name or nil,
        resStack = RES.stack, resBonus = resRadiusBonus(),
        maintLastCheck = S.lastMaintCheck,
        maintSinceCheck = (t - S.lastMaintCheck),
        maintShouldRun = (S.clashOn and (t - S.clashAt) >= CLASH.MAINT_HOLD_MIN) and shouldMaintainClash() or nil,
        updatedAt = t,
    }
end

task.spawn(function()
    while State.active do pcall(pushDiagnostics); task.wait(0.5) end
end)

return Probe
