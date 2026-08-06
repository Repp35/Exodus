--[[ auto parry ]]

local AutoParry = {}

-- dependências
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
	LEAD_PING_FLOOR = 0.060,
	LEAD_RTT_MULT = 0.5,
	LEAD_TICK_FRAMES = 2,
	RES_PER_PARRY = 0.225,
	RES_CAP = 32,
	RES_HOLD_T = 1.2,
	RES_DECAY_T = 4.0,
	GRACE_TIMEOUT = 0.30,
}

-- estado
local AP = { fired = false, firedAt = 0 }
local RES = { stack = 0, lastFireBallRef = nil, lastFireBallAt = 0, lastStackAt = 0 }
local Sync = {
	Speed = 0,
	RealPos = Vector3.new(0, 0, 0),
	DeflectDir = Vector3.new(0, 0, 0),
	Grace = false,
	Target = -999,
	lastSyncAt = 0,
	hasRealPos = false,
}

local _apBind = 0
local _localUserId = -1
local _onFired = nil
local _lastTargetSeen = -999
local _teleportLockUntil = 0
local _br = nil
local _brTried = false

-- módulos
local function getProbe()
	return Utils.getModule("Probe")
end
local function getGameInfo()
	return Utils.getModule("GameInfo")
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
		RES.stack = math.floor(RES.stack * math.max(frac, 0) + 0.5)
	end
end

-- disparo
local function sendParry()
	local t, Probe = Utils.now(), getProbe()
	if not (Probe and Probe.fireParry(1)) then
		return false
	end
	local GameInfo = getGameInfo()
	local b = GameInfo and GameInfo.getBall()
	if b and b.Parent then
		RES.lastFireBallRef, RES.lastFireBallAt = b, t
	end
	if _onFired then
		_onFired(t)
	end
	return true
end

-- alvo
local function _ensureBR()
	if _brTried then
		return _br
	end
	_brTried = true
	pcall(function()
		local ts = Utils.getReplicatedStorage():FindFirstChild("TS")
		if not ts then
			return
		end
		-- busca recursiva para maior compatibilidade
		local brMod = ts:FindFirstChild("BallReplicator", true)
		if brMod and brMod:IsA("ModuleScript") then
			local ok, mod = pcall(require, brMod)
			if ok and mod then
				_br = mod.BallReplicator or mod
			end
		end
	end)
	return _br
end

local function isTargetedByBall()
	if game:GetAttribute("GameBallTarget") == _localUserId then
		return true
	end
	local br = _ensureBR()
	if br and br.syncData and br.syncData.HighlightTargetPlayerID == _localUserId then
		return true
	end
	return Sync.Target == _localUserId
end

-- reset
local function resetState()
	AP.fired, AP.firedAt = false, 0
	RES.stack, RES.lastStackAt = 0, 0
	RES.lastFireBallRef, RES.lastFireBallAt = nil, 0
	Sync.Speed, Sync.lastSyncAt = 0, 0
	Sync.RealPos, Sync.DeflectDir = Vector3.new(0, 0, 0), Vector3.new(0, 0, 0)
	Sync.Grace, Sync.hasRealPos = false, false
	Sync.Target = -999
	_teleportLockUntil, _lastTargetSeen = 0, -999
end

-- sincronização
local function onBallSync(data)
	if typeof(data) ~= "table" then
		return
	end
	local t, GameInfo = Utils.now(), getGameInfo()
	if type(data.Speed) == "number" then
		Sync.Speed = data.Speed
	end
	if typeof(data.RealPosition) == "Vector3" then
		Sync.RealPos, Sync.hasRealPos = data.RealPosition, true
	end
	if typeof(data.DeflectDirection) == "Vector3" then
		Sync.DeflectDir = data.DeflectDirection
	end
	if type(data.Grace) == "boolean" then
		Sync.Grace = data.Grace
	end
	Sync.lastSyncAt = t
	if data.Teleported == true then
		_teleportLockUntil, AP.fired = t + 0.20, false
		return
	end
	if GameInfo then
		GameInfo.applySync(data)
	end
	local newTarget = tonumber(data.TargetPlayerID) or -999
	if newTarget ~= _lastTargetSeen then
		local prev = _lastTargetSeen
		_lastTargetSeen, Sync.Target = newTarget, newTarget
		if newTarget == _localUserId or prev == _localUserId then
			AP.fired = false
		end
		Sync.Grace = (newTarget ~= _localUserId and newTarget ~= -999)
	end
	if type(data.Grace) == "boolean" then
		Sync.Grace = data.Grace
	end
end

-- heartbeat
local function bindParry(character)
	_apBind = _apBind + 1
	local currentBindId = _apBind
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp or currentBindId ~= _apBind then
		return
	end
	AP.fired = false
	Utils.trackCharacter(
		Utils.getRunService().Heartbeat:Connect(function(dt)
			if currentBindId ~= _apBind or not (character.Parent and hrp.Parent) then
				return
			end
			local Config, GameInfo = Utils.getConfig(), getGameInfo()
			if not Config or Config.AutoParry ~= true or not GameInfo then
				AP.fired = false
				return
			end
			local t = Utils.now()
			if Sync.Grace and (t - Sync.lastSyncAt) > P.GRACE_TIMEOUT then
				Sync.Grace = false
			end
			if t < _teleportLockUntil or Sync.Grace or Utils.isClashActive() or Utils.isManualSpamActive() then
				return
			end
			tickResilience(t)
			local ball = GameInfo.getBall()
			if not (ball and ball.Parent) or not isTargetedByBall() then
				return
			end
			local syncFresh = (t - Sync.lastSyncAt) < 0.5
			local spd = (syncFresh and Sync.Speed > 0) and Sync.Speed or ball.AssemblyLinearVelocity.Magnitude
			if spd < P.MIN_SPD then
				return
			end
			local bp = ball.Position
			local tickMs = math.max(GameInfo.frameEMA() * 1000, 1)
			local leadSec = math.max(
				GameInfo.pingRTT() * P.LEAD_RTT_MULT + (P.LEAD_TICK_FRAMES * tickMs / 1000),
				P.LEAD_PING_FLOOR
			)
			local parryRad = math.max(
				P.DEFLECT_R
					+ math.min(spd * leadSec, P.LEAD_CAP)
					+ math.min(GameInfo.preBufferStuds(spd), P.PRE_CAP)
					+ resRadiusBonus(),
				P.RAD_FLOOR
			)

			-- otimização: distância ao quadrado
			local myPos, bPos = hrp.Position, bp
			local dx, dy, dz = myPos.X - bPos.X, myPos.Y - bPos.Y, myPos.Z - bPos.Z
			if (dx * dx + dy * dy + dz * dz) > (parryRad * parryRad) then
				return
			end

			if GameInfo.getDeflectCD() > 0 then
				return
			end
			if AP.fired then
				if (t - AP.firedAt) < P.FIRE_LOCK or (t - AP.firedAt) < P.FIRE_TIMEOUT then
					return
				end
				AP.fired = false
			end
			if AP.firedAt > Sync.lastSyncAt then
				return
			end
			GameInfo.accumPingTimer(dt)
			if GameInfo.shouldSamplePing(1.5) then
				GameInfo.samplePing()
			end
			if sendParry() then
				AP.fired, AP.firedAt = true, t
			else
				AP.fired = false
			end
		end)
	)
end

-- setup
function AutoParry.setup(u)
	Utils = u
	_localUserId = Utils.getLocalPlayer().UserId
end

-- api
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
function AutoParry.getSync()
	return Sync
end
function AutoParry.getP()
	return P
end

return AutoParry
