--[[ game info ]]

local GameInfo = {}

-- dependências
local Utils

-- serviços
local Players
local Stats
local Workspace

-- constantes
local PING_EMA = 0.5
local NEAREST_TICK = 0.5
local FRAME_SAMPLES = 60
local BALL_CACHE_TTL = 0.5
local LIVE_TIMP_TTL = 0.05

-- estado
local _ball, _ballAt = nil, 0
local _ping = 0.05
local _pingTimer = 0
local _lastNearest = 0
local _frameEMA = 1 / 60
local _frameVar = 0
local _jitterEMA = 0
local _dtLast = 0
local _dtIdx = 0
local _dtSum, _dtSumSq = 0, 0
local _dtCount = 0
local _dtSamples = {}
local _nearestDist = math.huge
local _nearestAlive = false

local _sync = {
	Speed = 0,
	RealPos = Vector3.new(0, 0, 0),
	Target = -999,
	lastSyncAt = 0,
}

local _liveTImpCache = { tImp = math.huge, bp = Vector3.new(0, 0, 0), spd = 0, at = 0 }
local _pbCache = { ms = -1, ping = -1, jitter = -1, var = -1 }

local _deflectAbilityRef = nil
local _deflectAbilityTried = false
local _deflectAbilityLastCheck = 0

-- bola
local function getBall()
	local t = Utils.now()
	if _ball and _ball.Parent and (t - _ballAt) < BALL_CACHE_TTL then
		return _ball
	end
	if Workspace then
		local b = Workspace:FindFirstChild("GameBall", true)
		if b and b.Parent then
			_ball, _ballAt = b, t
			return b
		end
	end
	_ball, _ballAt = nil, t
	return nil
end

local function setBall(b)
	_ball, _ballAt = b, Utils.now()
end

local function clearBallRef(b)
	if b == _ball then
		_ball, _ballAt = nil, Utils.now()
	end
end

-- ping
local function samplePing()
	local ok, p = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
	end)
	if ok and type(p) == "number" and p > 0 and p < 0.5 then
		_ping = _ping * (1 - PING_EMA) + p * PING_EMA
	end
end

local function pingOneWay()
	return math.max(_ping * 0.5, 0.040)
end

local function pingRTT()
	return math.max(_ping, 0.080)
end

-- impacto
local function tImpCompensated(raw, spd)
	if spd < 1 then
		return math.huge
	end
	return math.max(raw / spd, 0)
end

local function computeTImp(hrp, ball, t)
	local bp, av = ball.Position, ball.AssemblyLinearVelocity
	local spd = av.Magnitude
	if spd < 1 then
		return math.huge, bp, spd
	end
	return tImpCompensated((hrp.Position - bp).Magnitude, spd), bp, spd
end

-- frame
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

local function preBufferMs()
	local p, jitter, variance = pingOneWay() * 1000, _jitterEMA, _frameVar
	if
		math.abs(p - _pbCache.ping) < 1
		and math.abs(jitter - _pbCache.jitter) < 0.5
		and math.abs(variance - _pbCache.var) < 1e-7
		and _pbCache.ms > 0
	then
		return _pbCache.ms
	end
	local pb = (jitter * 1.4) + math.max(variance * 100000, 20) * 0.6
	local fps = (_frameEMA > 0) and (1 / _frameEMA) or 60
	if fps < 60 then
		pb = pb + (60 - fps) * 20
	end
	pb = math.clamp(pb, 0, 200)
	_pbCache.ms, _pbCache.ping, _pbCache.jitter, _pbCache.var = pb, p, jitter, variance
	return pb
end

local function preBufferStuds(spd)
	if not spd or spd < 1 then
		return 0
	end
	return math.min(spd * preBufferMs() / 1000, 30)
end

-- proximidade
local function nearestPlayerAlive()
	local t = Utils.now()
	if (t - _lastNearest) < NEAREST_TICK then
		return _nearestDist, _nearestAlive
	end
	_lastNearest = t
	local lp = Players.LocalPlayer
	local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if not myHRP then
		_nearestDist, _nearestAlive = math.huge, false
		return _nearestDist, _nearestAlive
	end
	local myPos, curDist, curAlive = myHRP.Position, math.huge, false
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp and p.Character then
			local php = p.Character:FindFirstChild("HumanoidRootPart")
			local hum = p.Character:FindFirstChildOfClass("Humanoid")
			if php and hum and hum.Health > 0 then
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

-- sincronização
local function isTargeted(lastTarget)
	local lp = Players.LocalPlayer
	return _sync.Target == lp.UserId
		or lastTarget == lp.UserId
		or Workspace:GetAttribute("GameBallTarget") == lp.UserId
end

local function applySync(d)
	if typeof(d) ~= "table" then
		return
	end
	if type(d.Speed) == "number" then
		_sync.Speed = d.Speed
	end
	if typeof(d.RealPosition) == "Vector3" then
		_sync.RealPos = d.RealPosition
	end
	if type(d.TargetPlayerID) == "number" then
		_sync.Target = d.TargetPlayerID
	end
	_sync.lastSyncAt = Utils.now()
end

-- habilidade
local function _ensureDeflectAbility()
	if _deflectAbilityRef and _deflectAbilityRef.Parent ~= nil then
		return _deflectAbilityRef
	end
	local t = Utils.now()
	if _deflectAbilityTried and (t - _deflectAbilityLastCheck) < 2.0 then
		return _deflectAbilityRef
	end
	_deflectAbilityTried, _deflectAbilityLastCheck = true, t
	pcall(function()
		local ts = Utils.getReplicatedStorage():FindFirstChild("TS")
		local bmMod = ts and ts:FindFirstChild("BindableManager")
		if not bmMod then
			return
		end
		local BM = require(bmMod)
		local getFn = BM and BM.GetFunction and BM:GetFunction("AbilityManager::GetAbility")
		if not getFn then
			return
		end
		for _, key in ipairs({ "Deflect", "Block" }) do
			local ok, ref = pcall(function()
				return getFn:Invoke(key)
			end)
			if ok and ref and type(ref.Cooldown) == "number" then
				_deflectAbilityRef = ref
				return
			end
		end
	end)
	return _deflectAbilityRef
end

local function getDeflectCD()
	local ref = _ensureDeflectAbility()
	if not ref then
		return 0
	end
	local ok, v = pcall(function()
		return ref.Cooldown
	end)
	return (ok and type(v) == "number") and v or 0
end

-- watcher
local function installBallWatcher(trackFn)
	local gameFolder = Workspace:WaitForChild("Game", 30)
	local ballWatcher = gameFolder and gameFolder:FindFirstChild("Ball")
	if ballWatcher then
		trackFn(ballWatcher.ChildAdded:Connect(function(c)
			if c.Name == "GameBall" and c:IsA("BasePart") then
				setBall(c)
			end
		end))
		trackFn(ballWatcher.ChildRemoved:Connect(clearBallRef))
		local existing = ballWatcher:FindFirstChild("GameBall")
		if existing and existing:IsA("BasePart") then
			setBall(existing)
		end
	end
end

-- setup
function GameInfo.setup(u)
	Utils = u
	Players, Stats, Workspace = Utils.getPlayers(), game:GetService("Stats"), game:GetService("Workspace")
end

-- api
function GameInfo.getBall()
	return getBall()
end

function GameInfo.nearestPlayerAlive()
	return nearestPlayerAlive()
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

function GameInfo.preBufferStuds(spd)
	return preBufferStuds(spd)
end

function GameInfo.frameEMA()
	return _frameEMA
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

function GameInfo.installBallWatcher(trackFn)
	installBallWatcher(trackFn)
end

function GameInfo.getDeflectCD()
	return getDeflectCD()
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

function GameInfo.liveTImp()
	local n = Utils.now()
	if (n - _liveTImpCache.at) < LIVE_TIMP_TTL then
		return _liveTImpCache
	end
	local lp, ball = Players.LocalPlayer, getBall()
	local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if hr and ball and ball.Parent then
		local bp, av = ball.Position, ball.AssemblyLinearVelocity
		local spd = av.Magnitude
		_liveTImpCache = {
			tImp = tImpCompensated((hr.Position - bp).Magnitude, spd),
			bp = bp,
			spd = spd,
			at = n,
		}
	else
		_liveTImpCache = { tImp = math.huge, bp = Vector3.new(0, 0, 0), spd = 0, at = n }
	end
	return _liveTImpCache
end

function GameInfo.computeTImp(hr, b, t)
	return computeTImp(hr, b, t)
end

return GameInfo
