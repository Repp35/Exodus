--[[ Spam ]]

local Spam = {}

-- deps
local Probe, GameInfo, Utils, _AutoParry, AutoClash

-- tunning
local SPAM = {
    MAX_PER_ITER = 50,
    WIN = 1.5,
    DT_CAP = 1
}

-- P
local P = {
    CPF_MIN_SPACING_MS = 0.05,
    CPF_MAX_SPACING_MS = 16,
    CPF_FPS_SAMPLE_T = 0.5,
    CPF_PING_FLOOR = 0.040,
    CPF_PING_REF = 0.060,
    DEFLECT_R = 8.5,
    RAD_FLOOR = 14
}

-- locals
local _now = os.clock
local _fpsBuf = {}
local _fpsBufIdx = 0
local _fpsLast = _now()
local _fpsSmooth = 60
local _spacingCacheMs = -1
local _lastPingForSpacing = -1
local _burstQueue = {}
local _burstQueueHead = 1
local _burstActive = false
local _nextCpfBurstAt = 0
local _spamDebt = 0
local _spamWinStart = _now()
local _spamClickIdx = 0
local _spamWasActive = false
local _spamResolveCache = 0
local _spamCooldownUntil = 0

-- sampleFPS
local function sampleFPS(dt)
    if dt <= 0 then
        return
    end
    _fpsBufIdx = (_fpsBufIdx % 60) + 1
    _fpsBuf[_fpsBufIdx] = 1 / dt
    local t = _now()
    if (t - _fpsLast) < P.CPF_FPS_SAMPLE_T then
        return
    end
    _fpsLast = t
    local sum, cnt = 0, 0
    for i = 1, 60 do
        local v = _fpsBuf[i]
        if v then
            sum, cnt = sum + v, cnt + 1
        end
    end
    if cnt > 0 then
        _fpsSmooth = sum / cnt
    end
end

-- getCPF
local function getCPF()
    local value = tonumber(_G.PhantomConfig and _G.PhantomConfig.CPS) or 1
    return math.clamp(math.floor(value + 0.5), 1, SPAM.MAX_PER_ITER)
end

-- calcSpacingMs
local function calcSpacingMs()
    local p = GameInfo.pingOneWay()
    if math.abs(p - _lastPingForSpacing) < 0.002 and _spacingCacheMs > 0 then
        return _spacingCacheMs
    end
    _lastPingForSpacing = p
    p = math.max(p, P.CPF_PING_FLOOR)
    _spacingCacheMs =
        math.clamp(P.CPF_MIN_SPACING_MS * math.max(p / P.CPF_PING_REF, 1.0), P.CPF_MIN_SPACING_MS, P.CPF_MAX_SPACING_MS)
    return _spacingCacheMs
end

-- sendSpam
local function sendSpam()
    local t = _now()
    if t < _spamCooldownUntil then
        return false
    end
    local r
    if t - _spamResolveCache > 3.0 then
        r = Probe.resolveRemote()
        _spamResolveCache = t
    else
        r = Probe.getRemote()
    end
    if not r or not (r and r.Parent and r:IsA("RemoteEvent")) then
        r = Probe.probeNamed()
        if not r then
            Probe.invalidate()
            return false
        end
    end
    if not Probe.fireParry(1) then
        _spamCooldownUntil = t + 0.25
        Probe.invalidate()
        return false
    end
    return true
end

-- queueBurst
local function queueBurst(t)
    local count = getCPF()
    local spacing = calcSpacingMs() / 1000
    table.clear(_burstQueue)
    _burstQueueHead = 1
    _burstActive = true
    for i = 1, count do
        _burstQueue[i] = t + (i - 1) * spacing
    end
end

-- drainBurst
local function drainBurst(t)
    if not _burstActive then
        return true
    end
    local head = _burstQueueHead
    local length = #_burstQueue
    local fired = 0
    while head <= length and fired < SPAM.MAX_PER_ITER do
        local fireAt = _burstQueue[head]
        if not fireAt or t < fireAt then
            break
        end
        if not sendSpam() then
            return false
        end
        head, fired = head + 1, fired + 1
    end
    _burstQueueHead = head
    if head > length then
        _burstActive = false
        table.clear(_burstQueue)
    end
    return true
end

-- _snapshot
local function _snapshot()
    if AutoClash and AutoClash.snapshot then
        return AutoClash.snapshot()
    end
    return nil
end

-- tickSpam
local function tickSpam(dt)
    sampleFPS(dt)
    local should = false
    if _G.PhantomManual == true then
        should = true
    elseif AutoClash and AutoClash.clashOn and AutoClash.clashOn() then
        local ctx = _snapshot()
        if ctx then
            local spamRad = math.clamp(P.DEFLECT_R + P.RAD_FLOOR, 18, 30)
            should = ctx.bDist <= spamRad
        end
    end
    if not should then
        if _spamWasActive then
            _spamDebt, _spamWinStart, _spamWasActive = 0, _now(), false
            _burstActive, _burstQueueHead, _nextCpfBurstAt = false, 1, 0
            table.clear(_burstQueue)
        end
        return
    end
    _spamWasActive = true
    local Config = _G.PhantomConfig
    if Config.SpamRateMode == "CPF" then
        local t = _now()
        if not drainBurst(t) then
            return
        end
        if not _burstActive and t >= _nextCpfBurstAt then
            queueBurst(t)
            _nextCpfBurstAt = t + math.max(dt, 1 / math.max(_fpsSmooth, 1))
            drainBurst(t)
        end
        return
    end
    if dt > SPAM.DT_CAP then
        dt = SPAM.DT_CAP
    end
    _spamDebt = _spamDebt + dt
    local c = tonumber(Config.CPS) or Utils.defaultCps()
    if c < 1 then
        c = 1
    end
    local step, n = 1 / c, 0
    while _spamDebt >= step and n < SPAM.MAX_PER_ITER do
        if not should then
            _spamDebt = 0
            break
        end
        _spamClickIdx = _spamClickIdx + 1
        if not sendSpam() then
            _spamDebt = 0
            break
        end
        _spamDebt = _spamDebt - step
        n = n + 1
    end
end

-- resetState
local function resetState()
    _spamDebt, _spamWinStart, _spamClickIdx, _spamWasActive = 0, _now(), 0, false
    _burstQueueHead, _burstActive, _nextCpfBurstAt = 1, false, 0
    table.clear(_burstQueue)
    _spacingCacheMs, _lastPingForSpacing = -1, -1
    _spamResolveCache, _spamCooldownUntil = 0, 0
end

-- resetBurst
local function resetBurst()
    _burstQueueHead, _burstActive, _nextCpfBurstAt = 1, false, 0
    table.clear(_burstQueue)
end

-- setup
function Spam.setup(deps)
    Probe = deps.Probe
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    _AutoParry = deps.AutoParry
end

-- public api
function Spam.tick(dt)
    tickSpam(dt)
end
function Spam.resetState()
    resetState()
end
function Spam.resetBurst()
    resetBurst()
end
function Spam.fps()
    return _fpsSmooth
end

function Spam.bindAutoClash(ac)
    AutoClash = ac
end

return Spam
