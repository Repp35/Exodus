--[[ spam ]]

-- módulo
local Spam = {}

-- dependências
local Probe
local GameInfo
local Utils
local AutoClash

-- tunings
local SPAM = {
    MAX_PER_ITER = 50,
    DT_CAP = 1
}

local P = {
    CPF_MIN_SPACING_MS = 0.05,
    CPF_MAX_SPACING_MS = 16,
    CPF_FPS_SAMPLE_T = 0.5,
    CPF_PING_FLOOR = 0.040,
    CPF_PING_REF = 0.060,
    DEFLECT_R = 8.5,
    RAD_FLOOR = 14
}

-- estado
local _fpsBuf = {}
local _fpsBufIdx = 0
local _fpsLast = 0
local _fpsSmooth = 60
local _spacingCacheMs = -1
local _lastPingForSpacing = -1
local _burstQueue = {}
local _burstQueueHead = 1
local _burstActive = false
local _nextCpfBurstAt = 0
local _spamDebt = 0
local _spamWasActive = false
local _spamCooldownUntil = 0

-- fps
local function sampleFPS(dt)
    if dt <= 0 then
        return
    end
    _fpsBufIdx = (_fpsBufIdx % 60) + 1
    _fpsBuf[_fpsBufIdx] = 1 / dt
    local t = Utils.now()
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

-- cpf
local function getCPF()
    local config = Utils.getConfig()
    local value = tonumber(config and config.CPS) or 1
    return math.clamp(math.floor(value + 0.5), 1, SPAM.MAX_PER_ITER)
end

-- espaçamento
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

-- disparo de spam
local function sendSpam()
    local t = Utils.now()
    if not Utils.isManualSpamActive() and t < _spamCooldownUntil then
        return false
    end
    if not Probe.fireParry(1) then
        if not Utils.isManualSpamActive() then
            _spamCooldownUntil = t + 0.25
        end
        Probe.invalidateRemote()
        return false
    end
    return true
end

-- fila de burst
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

-- snapshot
local function getClashSnapshot()
    if AutoClash and AutoClash.snapshot then
        return AutoClash.snapshot()
    end
    return nil
end

-- tick principal
local function tickSpam(dt)
    sampleFPS(dt)
    local shouldSpam = false
    local config = Utils.getConfig()

    if Utils.isManualSpamActive() then
        shouldSpam = true
    elseif AutoClash and AutoClash.clashOn and AutoClash.clashOn() then
        local ctx = getClashSnapshot()
        if ctx then
            local spamRad = math.clamp(P.DEFLECT_R + P.RAD_FLOOR, 18, 30)
            shouldSpam = ctx.bDist <= spamRad
        end
    end

    if not shouldSpam then
        if _spamWasActive then
            _spamDebt, _spamWasActive = 0, false
            _burstActive, _burstQueueHead, _nextCpfBurstAt = false, 1, 0
            table.clear(_burstQueue)
        end
        return
    end

    _spamWasActive = true

    if config.SpamRateMode == "CPF" then
        local t = Utils.now()
        if Utils.isManualSpamActive() then
            -- Disparo direto e imediato no manual spam
            for i = 1, math.min(getCPF(), SPAM.MAX_PER_ITER) do
                sendSpam()
            end
            return
        end
        if not _burstActive then
            queueBurst(t)
        end
        drainBurst(t)
        return
    end

    -- cps mode
    if dt > SPAM.DT_CAP then
        dt = SPAM.DT_CAP
    end
    _spamDebt = _spamDebt + dt
    local cps = tonumber(config.CPS) or Utils.defaultCps()
    if cps < 1 then
        cps = 1
    end
    local step = 1 / cps
    local firedCount = 0
    while _spamDebt >= step and firedCount < SPAM.MAX_PER_ITER do
        if not shouldSpam then
            _spamDebt = 0
            break
        end
        if not sendSpam() then
            _spamDebt = 0
            break
        end
        _spamDebt = _spamDebt - step
        firedCount = firedCount + 1
    end
end

-- reset de estado
local function resetState()
    _spamDebt, _spamWasActive = 0, false
    _burstQueueHead, _burstActive, _nextCpfBurstAt = 1, false, 0
    table.clear(_burstQueue)
    _spacingCacheMs, _lastPingForSpacing = -1, -1
    _spamCooldownUntil = 0
end

-- reset de burst
local function resetBurst()
    _burstQueueHead, _burstActive, _nextCpfBurstAt = 1, false, 0
    table.clear(_burstQueue)
end

-- setup
function Spam.setup(deps)
    Probe = deps.Probe
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoClash = deps.AutoClash
    _fpsLast = Utils.now()
end

-- api pública
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

if _G.ExodusModules then
    _G.ExodusModules.Spam = Spam
end

return Spam
