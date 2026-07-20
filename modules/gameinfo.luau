--[[ GameInfo ]]

local GameInfo = {}

-- services
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local ws = workspace

-- constants
local PING_EMA = 0.5
local PING_MAX = 0.150
local PING_BOOT = 0.060
local NEAREST_TICK = 0.5
local FRAME_SAMPLES = 60
local BALL_CACHE_TTL = 0.5
local LIVE_TIMP_TTL = 0.05
local SYNC_FRESH_T = 1.0

-- state
local _ball, _ballAt = nil, 0
local _ping = 0.05
local _pingTimer = 0
local _lastNearest = 0
local _lastDashTrack = 0
local _lastFullScan = 0
local _frameEMA = 1 / 60
local _frameVar = 0
local _jitterEMA = 0
local _dtIdx, _dtLast = 0, 0
local _dtSum, _dtSumSq = 0, 0
local _dtCount = 0
local _dtSamples = {}
local _nearestDist = math.huge
local _nearestAlive = false

-- getBall
local function getBall()
    local t = os.clock()
    if _ball and _ball.Parent and (t - _ballAt) < BALL_CACHE_TTL then
        return _ball
    end
    if ws then
        local b = ws:FindFirstChild("GameBall", true)
        if b and b.Parent then
            _ball, _ballAt = b, t
            return b
        end
    end
    _ball, _ballAt = nil, t
    return nil
end

-- samplePing
local function samplePing()
    local ok, p =
        pcall(
        function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
        end
    )
    if ok and type(p) == "number" and p > 0 and p < 0.5 then
        _ping = _ping * (1 - PING_EMA) + p * PING_EMA
    end
end

-- getPing
local function getPing()
    local p = _ping
    if not p or p <= 0 then
        p = PING_BOOT
    end
    return math.clamp(p * 0.5, 0, PING_MAX)
end

-- pingOneWay
-- pingRTT
local function pingOneWay()
    return math.max(getPing(), 0.040)
end
local function pingRTT()
    return math.max(getPing() * 2, 0.080)
end

-- pingScale
local function pingScale()
    return math.clamp((pingOneWay() - 0.060) / 0.060, 0, 1.0)
end

-- pingCredit
local function pingCredit(raw, spd)
    if spd < 1 then
        return 0
    end
    return math.min(raw, spd * pingOneWay() * 0.5)
end

-- tImpCompensated
local function tImpCompensated(raw, spd)
    if spd < 1 then
        return math.huge
    end
    return math.max((raw - pingCredit(raw, spd)) / spd, 0)
end

-- sampleFrameDelta
local function sampleFrameDelta(dt)
    if dt <= 0 then
        return
    end
    _frameEMA = _frameEMA * 0.9 + dt * 0.1
    if _dtLast > 0 then
        _jitterEMA = _jitterEMA * 0.85 + math.abs(dt - _dtLast) * 1000 * 0.15
    end
    _dtLast = dt
    _dtIdx = (_dtIdx % FRAME_SAMPLES) + 1
    local previous = _dtSamples[_dtIdx]
    if previous then
        _dtSum = _dtSum - previous
        _dtSumSq = _dtSumSq - previous * previous
    else
        _dtCount = _dtCount + 1
    end
    _dtSamples[_dtIdx] = dt
    _dtSum = _dtSum + dt
    _dtSumSq = _dtSumSq + dt * dt
    if _dtCount > 0 then
        local mean = _dtSum / _dtCount
        _frameVar = math.max((_dtSumSq / _dtCount) - mean * mean, 0)
    end
end

-- _pbCache
local _pbCache = {ms = -1, ping = -1, jitter = -1, var = -1}

-- preBufferMs
local function preBufferMs()
    local p, jitter, variance = pingOneWay() * 1000, _jitterEMA, _frameVar
    if
        math.abs(p - _pbCache.ping) < 1 and math.abs(jitter - _pbCache.jitter) < 0.5 and
            math.abs(variance - _pbCache.var) < 1e-7 and
            _pbCache.ms > 0
     then
        return _pbCache.ms
    end
    local PB_PING_FLAT_MS, PB_PING_FULL_MS, PB_PING_AT_MAX_MS = 90, 180, 100
    local PB_JITTER_MULT = 1.4
    local PB_DRIFT_FLOOR, PB_DRIFT_MULT = 20, 0.6
    local PB_FPS_FACTOR, PB_CAP_MS, PB_FLOOR_MS = 0.020, 200, 0
    local pingThrottle = math.clamp((p - PB_PING_FLAT_MS) / (PB_PING_FULL_MS - PB_PING_FLAT_MS), 0, 1)
    local pb =
        pingThrottle * PB_PING_AT_MAX_MS + jitter * PB_JITTER_MULT +
        math.max(variance * 1000 * 100, PB_DRIFT_FLOOR) * PB_DRIFT_MULT
    local fps = (_frameEMA > 0) and (1 / _frameEMA) or 60
    if fps < 60 then
        pb = pb + (60 - fps) * PB_FPS_FACTOR * 1000
    end
    pb = math.clamp(pb * 1.0, PB_FLOOR_MS, PB_CAP_MS)
    _pbCache.ms, _pbCache.ping, _pbCache.jitter, _pbCache.var = pb, p, jitter, variance
    return pb
end

-- preBufferStuds
local function preBufferStuds(spd)
    if not spd or spd < 1 then
        return 0
    end
    return math.min(spd * preBufferMs() / 1000, 30)
end

-- nearestPlayerAlive
local function nearestPlayerAlive()
    local t = os.clock()
    if (t - _lastNearest) < NEAREST_TICK then
        return _nearestDist, _nearestAlive
    end
    _lastNearest = t
    local lp = Players.LocalPlayer
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (myHRP and myHRP.Parent) then
        _nearestDist, _nearestAlive = math.huge, false
        return _nearestDist, _nearestAlive
    end
    local myPos = myHRP.Position
    local curDist, curAlive = math.huge, false
    for _, p in Players:GetPlayers() do
        if p ~= lp then
            local ch = p.Character
            local php = ch and ch:FindFirstChild("HumanoidRootPart")
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            local alive = php and php.Parent and hum and hum.Parent and hum.Health > 0
            if alive then
                local d = (myPos - php.Position).Magnitude
                if d < curDist then
                    curDist, curAlive = d, true
                end
            end
        end
    end
    _nearestDist, _nearestAlive = curDist, curAlive
    return _nearestDist, _nearestAlive
end

-- _sync
local _sync = {
    Speed = 0,
    RealPos = Vector3.new(0, 0, 0),
    Target = -999,
    lastSyncAt = 0
}

-- ballSpeed
local function ballSpeed(ball, t)
    if (t - _sync.lastSyncAt) < SYNC_FRESH_T and _sync.Speed > 0 then
        return _sync.Speed
    end
    local ok, av =
        pcall(
        function()
            return ball.AssemblyLinearVelocity
        end
    )
    return (ok and typeof(av) == "Vector3") and av.Magnitude or 0
end

-- ballPos
local function ballPos(ball, t)
    if (t - _sync.lastSyncAt) < SYNC_FRESH_T and _sync.RealPos ~= Vector3.new(0, 0, 0) then
        return _sync.RealPos
    end
    if _sync.RealPos ~= Vector3.new(0, 0, 0) and _sync.Speed > 0 and (t - _sync.lastSyncAt) < 2.0 then
        local ok, av =
            pcall(
            function()
                return ball.AssemblyLinearVelocity
            end
        )
        if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
            return _sync.RealPos + av * (t - _sync.lastSyncAt)
        end
    end
    return ball.Position
end

-- _liveTImpCache
local _liveTImpCache = {tImp = math.huge, bp = Vector3.new(0, 0, 0), spd = 0, at = 0}

-- liveTImp
local function liveTImp()
    local n = os.clock()
    if (n - _liveTImpCache.at) < LIVE_TIMP_TTL then
        return _liveTImpCache
    end
    local lp = Players.LocalPlayer
    local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()
    if hr and hr.Parent and ball and ball.Parent then
        local bp = ball.Position
        local ok, av =
            pcall(
            function()
                return ball.AssemblyLinearVelocity
            end
        )
        local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
        if spd < 1 then
            _liveTImpCache = {tImp = math.huge, bp = bp, spd = 0, at = n}
        else
            _liveTImpCache = {
                tImp = tImpCompensated((hr.Position - bp).Magnitude, spd),
                bp = bp,
                spd = spd,
                at = n
            }
        end
    else
        _liveTImpCache = {tImp = math.huge, bp = Vector3.new(0, 0, 0), spd = 0, at = n}
    end
    return _liveTImpCache
end

-- computeTImp
local function computeTImp(hrp, ball, t)
    local bp, spd = ball.Position, ballSpeed(ball, t)
    if spd < 1 then
        return math.huge, bp, spd
    end
    return tImpCompensated((hrp.Position - bp).Magnitude, spd), bp, spd
end

-- isTargeted
local function isTargeted(lastTarget)
    return _sync.Target == Players.LocalPlayer.UserId or lastTarget == Players.LocalPlayer.UserId or
        workspace:GetAttribute("GameBallTarget") == Players.LocalPlayer.UserId
end

-- applySync
local function applySync(d)
    if typeof(d) ~= "table" then
        return
    end
    local t = os.clock()
    if type(d.Speed) == "number" then
        _sync.Speed = d.Speed
    end
    if typeof(d.RealPosition) == "Vector3" then
        _sync.RealPos = d.RealPosition
    end
    if type(d.TargetPlayerID) == "number" then
        _sync.Target = d.TargetPlayerID
    end
    _sync.lastSyncAt = t
end

-- setBall
-- clearBallRef
local function setBall(b)
    _ball, _ballAt = b, os.clock()
end

local function clearBallRef(b)
    if b == _ball then
        _ball, _ballAt = nil, os.clock()
    end
end

-- installBallWatcher
local function installBallWatcher(track)
    local gameFolder = workspace:WaitForChild("Game", 30)
    local ballWatcher = gameFolder and gameFolder:FindFirstChild("Ball")
    if ballWatcher then
        track(
            ballWatcher.ChildAdded:Connect(
                function(c)
                    if c.Name == "GameBall" and c:IsA("BasePart") then
                        setBall(c)
                    end
                end
            )
        )
        track(ballWatcher.ChildRemoved:Connect(clearBallRef))
        local existing = ballWatcher:FindFirstChild("GameBall")
        if existing and existing:IsA("BasePart") then
            setBall(existing)
        end
    end
end

-- public api
function GameInfo.getBall()
    return getBall()
end
function GameInfo.ballSpeed(b, t)
    return ballSpeed(b, t)
end
function GameInfo.ballPos(b, t)
    return ballPos(b, t)
end
function GameInfo.nearestPlayerAlive()
    return nearestPlayerAlive()
end
function GameInfo.liveTImp()
    return liveTImp()
end
function GameInfo.computeTImp(hr, b, t)
    return computeTImp(hr, b, t)
end
function GameInfo.isTargeted(lastTarget)
    return isTargeted(lastTarget)
end
function GameInfo.pingOneWay()
    return pingOneWay()
end
function GameInfo.pingRTT()
    return pingRTT()
end
function GameInfo.pingScale()
    return pingScale()
end
function GameInfo.pingCredit(raw, spd)
    return pingCredit(raw, spd)
end
function GameInfo.tImpCompensated(raw, spd)
    return tImpCompensated(raw, spd)
end
function GameInfo.preBufferMs()
    return preBufferMs()
end
function GameInfo.preBufferStuds(spd)
    return preBufferStuds(spd)
end
function GameInfo.frameEMA()
    return _frameEMA
end
function GameInfo.jitterEMA()
    return _jitterEMA
end
function GameInfo.frameVar()
    return _frameVar
end
function GameInfo.smoothPing()
    return _ping
end
function GameInfo.samplePing()
    samplePing()
end
function GameInfo.sampleFrameDelta(dt)
    sampleFrameDelta(dt)
end
function GameInfo.applySync(d)
    applySync(d)
end
function GameInfo.syncTarget()
    return _sync.Target
end
function GameInfo.syncLastAt()
    return _sync.lastSyncAt
end
function GameInfo.syncSpeed()
    return _sync.Speed
end
function GameInfo.syncRealPos()
    return _sync.RealPos
end
function GameInfo.accumPingTimer(dt)
    _pingTimer = _pingTimer + dt
end
function GameInfo.shouldSamplePing(interval)
    if _pingTimer >= interval then
        _pingTimer = 0
        return true
    end
    return false
end
function GameInfo.installBallWatcher(track)
    installBallWatcher(track)
end

return GameInfo
