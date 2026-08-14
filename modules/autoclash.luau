-- [[ auto clash ]]

local AutoClash = {}

local GameInfo
local Utils
local AutoParry

-- ── tunable ──────────────────────────────────────────────────────────────────

local C = {
	ACT_RAD_FACTOR = 1.40,
	ACT_RETURN_RADIUS_FACTOR = 1.50,

	DET_RAD_MIN = 10,
	DET_RAD_MAX = 25,
	DET_RAD_SPD_REF = 120,
	DET_DIST_DELTA = 0.5,

	DET_RETURN_MAX_LO = 0.220,
	DET_RETURN_MIN_HI = 0.100,
	DET_RETURN_SPD_LO = 60,
	DET_RETURN_SPD_HI = 200,

	TARGET_RETURN_MAX_LO = 0.140,
	TARGET_RETURN_MIN_HI = 0.070,
	TARGET_RETURN_SPD_LO = 60,
	TARGET_RETURN_SPD_HI = 200,
	TARGET_RETURN_DOT_MIN = 0.05,
	TARGET_RETURN_DIST_DELTA = 0.5,

	DEACT_TARGET_SPD_LO = 60,
	DEACT_TARGET_SPD_HI = 200,
	DEACT_TIMEOUT_LO = 0.055,
	DEACT_TIMEOUT_HI = 0.025,

	ACTIVE_LOCK = 0.080,
	INACTIVE_LOCK = 0.080,
}

-- ── state ────────────────────────────────────────────────────────────────────

local S = {
	enabled = false,
	active = false,
	activeAt = 0,
	inactiveAt = 0,

	detPhase = "IDLE",
	detEnterAt = 0,
	detExitAt = 0,
	detMinDist = 0,

	lastTarget = -999,
	lastTargetAt = 0,
	lastTimeWasTarget = 0,

	wasMeTarget = false,
	lostMeAt = 0,
	targetReturnMinDist = 0,

	activationSpeed = 0,
	activationTargetWindow = 0,

	teleportLockUntil = 0,
}

-- ── aliases ──────────────────────────────────────────────────────────────────

local function now()
	return Utils.now()
end

local function getLocalPlayer()
	return Utils.getLocalPlayer()
end

local function getMyHRP()
	local player = getLocalPlayer()
	local character = player and player.Character

	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getBall()
	return GameInfo.getBall()
end

local function isTargeted()
	return AutoParry.isTargeted()
end

local function getBallVelocity(ball)
	if not ball or not ball.Parent then
		return nil
	end

	local ok, velocity = pcall(function()
		return ball.AssemblyLinearVelocity
	end)

	if not ok or typeof(velocity) ~= "Vector3" then
		return nil
	end

	return velocity
end

local function getBallSpeed(ball)
	local velocity = getBallVelocity(ball)

	return velocity and velocity.Magnitude or 0
end

local function lerpBySpeed(speed, speedLow, speedHigh, valueLow, valueHigh)
	if speedHigh <= speedLow then
		return valueLow
	end

	local alpha = math.clamp(
		(speed - speedLow) / (speedHigh - speedLow),
		0,
		1
	)

	return valueLow + (valueHigh - valueLow) * alpha
end

local function getDetectorRadius(speed)
	local alpha = math.clamp(
		speed / C.DET_RAD_SPD_REF,
		0,
		1
	)

	return C.DET_RAD_MIN
		+ (C.DET_RAD_MAX - C.DET_RAD_MIN) * alpha
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

local function resetDetector()
	S.detPhase = "IDLE"
	S.detEnterAt = 0
	S.detExitAt = 0
	S.detMinDist = 0
end

local function activate(t, ball)
	if S.active then
		return false
	end

	if t - S.inactiveAt < C.INACTIVE_LOCK then
		return false
	end

	local speed = getBallSpeed(ball)

	S.active = true
	S.activeAt = t
	S.inactiveAt = 0

	S.activationSpeed = speed
	S.activationTargetWindow = lerpBySpeed(
		speed,
		C.TARGET_RETURN_SPD_LO,
		C.TARGET_RETURN_SPD_HI,
		C.TARGET_RETURN_MAX_LO,
		C.TARGET_RETURN_MIN_HI
	)

	S.lastTimeWasTarget = t

	resetDetector()

	return true
end

local function deactivate(t)
	if not S.active then
		return false
	end

	if t - S.activeAt < C.ACTIVE_LOCK then
		return false
	end

	S.active = false
	S.activeAt = 0
	S.inactiveAt = t

	S.activationSpeed = 0
	S.activationTargetWindow = 0

	resetDetector()

	return true
end

local function forceDeactivate(t)
	S.active = false
	S.activeAt = 0
	S.inactiveAt = t

	S.activationSpeed = 0
	S.activationTargetWindow = 0

	resetDetector()

	return true
end

-- ── return detector ──────────────────────────────────────────────────────────

local function getDetectorReturnWindow(speed)
	return lerpBySpeed(
		speed,
		C.DET_RETURN_SPD_LO,
		C.DET_RETURN_SPD_HI,
		C.DET_RETURN_MAX_LO,
		C.DET_RETURN_MIN_HI
	)
end

local function tickReturnDetector(t, hr, ball)
	if not (
		hr
		and hr.Parent
		and ball
		and ball.Parent
	) then
		resetDetector()
		return false
	end

	local velocity = getBallVelocity(ball)

	if not velocity then
		resetDetector()
		return false
	end

	local speed = velocity.Magnitude

	if speed <= 1 then
		resetDetector()
		return false
	end

	local offset = hr.Position - ball.Position
	local distance = offset.Magnitude

	if distance <= 0.001 then
		resetDetector()
		return false
	end

	local radius = getDetectorRadius(speed)
	local activationRadius = radius * C.ACT_RETURN_RADIUS_FACTOR

	local coming = velocity:Dot(offset.Unit) > 0

	if distance > activationRadius then
		resetDetector()
		return false
	end

	if S.detPhase == "EXITED"
		and t - S.detExitAt > C.DET_RETURN_MAX_LO
	then
		resetDetector()
	end

	if S.detPhase == "IDLE" then
		if distance <= activationRadius and coming then
			S.detPhase = "INSIDE"
			S.detEnterAt = t
			S.detMinDist = distance
		end

		return false
	end

	if S.detPhase == "INSIDE" then
		S.detMinDist = math.min(
			S.detMinDist,
			distance
		)

		if distance > S.detMinDist + C.DET_DIST_DELTA then
			S.detPhase = "EXITED"
			S.detExitAt = t
		end

		return false
	end

	if S.detPhase == "EXITED" then
		local elapsed = t - S.detExitAt
		local window = getDetectorReturnWindow(speed)

		local returned =
			distance <= S.detMinDist + C.DET_DIST_DELTA
			and coming

		if returned then
			S.detPhase = "INSIDE"
			S.detEnterAt = t
			S.detMinDist = distance

			return elapsed <= window
		end
	end

	return false
end

-- ── target return ────────────────────────────────────────────────────────────

local function getTargetReturnWindow(speed)
	return lerpBySpeed(
		speed,
		C.TARGET_RETURN_SPD_LO,
		C.TARGET_RETURN_SPD_HI,
		C.TARGET_RETURN_MAX_LO,
		C.TARGET_RETURN_MIN_HI
	)
end

local function tickTargetReturn(t, hr, ball)
	if not (
		S.wasMeTarget
		and isTargeted()
		and hr
		and hr.Parent
		and ball
		and ball.Parent
	) then
		return false
	end

	local velocity = getBallVelocity(ball)

	if not velocity then
		return false
	end

	local speed = velocity.Magnitude

	if speed <= 1 then
		return false
	end

	local offset = hr.Position - ball.Position
	local distance = offset.Magnitude

	if distance <= 0.001 then
		return false
	end

	local dot = velocity:Dot(offset.Unit) / speed

	if dot < C.TARGET_RETURN_DOT_MIN then
		return false
	end

	local elapsed = t - S.lostMeAt
	local window = getTargetReturnWindow(speed)

	S.targetReturnMinDist = math.min(
		S.targetReturnMinDist,
		distance
	)

	local approaching =
		distance <= S.targetReturnMinDist + C.TARGET_RETURN_DIST_DELTA

	if not approaching then
		return false
	end

	if elapsed > window then
		S.wasMeTarget = false
		S.lostMeAt = 0
		S.targetReturnMinDist = 0

		return false
	end

	S.wasMeTarget = false
	S.lostMeAt = 0
	S.targetReturnMinDist = 0

	return true
end

-- ── activation ───────────────────────────────────────────────────────────────

local function shouldActivate(t, hr, ball)
	if not hr or not hr.Parent then
		return false
	end

	if not ball or not ball.Parent then
		return false
	end

	if tickReturnDetector(t, hr, ball) then
		return true
	end

	return tickTargetReturn(t, hr, ball)
end

-- ── deactivation ─────────────────────────────────────────────────────────────

local function getDeactivateTimeout(speed)
	return lerpBySpeed(
		speed,
		C.DEACT_TARGET_SPD_LO,
		C.DEACT_TARGET_SPD_HI,
		C.DEACT_TIMEOUT_LO,
		C.DEACT_TIMEOUT_HI
	)
end

local function shouldDeactivate(t, hr, ball)
	if t < S.teleportLockUntil then
		return true
	end

	if not (
		hr
		and hr.Parent
		and ball
		and ball.Parent
	) then
		return true
	end

	local velocity = getBallVelocity(ball)

	if not velocity then
		return true
	end

	local speed = velocity.Magnitude

	if speed <= 1 then
		return true
	end

	local offset = hr.Position - ball.Position
	local distance = offset.Magnitude

	if distance <= 0.001 then
		return true
	end

	local dot = velocity:Dot(offset.Unit) / speed
	local timeout = getDeactivateTimeout(speed)

	local sinceTarget = t - S.lastTimeWasTarget
	local sinceActivation = t - S.activeAt

	if sinceActivation < C.ACTIVE_LOCK then
		return false
	end

	if sinceTarget <= timeout then
		return false
	end

	if dot > 0 then
		return false
	end

	return true
end

-- ── evaluate ─────────────────────────────────────────────────────────────────

local function evaluate(t, hr, ball, config)
	local enabled =
		config
		and config.AutoClash ~= false
		and not _G.PhantomManual

	if not enabled then
		S.enabled = false
		forceDeactivate(t)
		return
	end

	if GameInfo.isGrace() then
		forceDeactivate(t)
		return
	end

	S.enabled = true

	if not hr or not hr.Parent then
		forceDeactivate(t)
		return
	end

	if not ball or not ball.Parent then
		forceDeactivate(t)
		return
	end

	if t < S.teleportLockUntil then
		forceDeactivate(t)
		return
	end

	if S.active then
		if shouldDeactivate(t, hr, ball) then
			deactivate(t)
		end
	elseif shouldActivate(t, hr, ball) then
		activate(t, ball)
	end
end

-- ── callbacks ────────────────────────────────────────────────────────────────

local function onTarget(newTarget, t)
	if type(newTarget) ~= "number" then
		return
	end

	local previousTarget = S.lastTarget
	local player = getLocalPlayer()
	local userId = player and player.UserId

	if not userId then
		return
	end

	S.lastTarget = newTarget
	S.lastTargetAt = t

	local isMe = newTarget == userId
	local wasMe = previousTarget == userId

	if isMe then
		S.lastTimeWasTarget = t
	end

	if wasMe and not isMe then
		S.wasMeTarget = true
		S.lostMeAt = t

		local ball = getBall()
		local hr = getMyHRP()

		if ball and ball.Parent and hr and hr.Parent then
			S.targetReturnMinDist =
				(hr.Position - ball.Position).Magnitude
		else
			S.targetReturnMinDist = math.huge
		end
	end

	if not isMe and not wasMe then
		S.wasMeTarget = false
		S.lostMeAt = 0
		S.targetReturnMinDist = 0
	end

	local getState = AutoParry.getState

	if type(getState) == "function" then
		local state = getState()

		if state then
			state.armed = isMe
		end
	end
end

local function onTeleport()
	local t = now()

	S.teleportLockUntil = t + 0.5
	forceDeactivate(t)
end

-- ── public ───────────────────────────────────────────────────────────────────

function AutoClash.setup(deps)
	if type(deps) ~= "table" then
		return false
	end

	GameInfo = deps.GameInfo
	Utils = deps.Utils
	AutoParry = deps.AutoParry

	if not GameInfo or not Utils or not AutoParry then
		return false
	end

	Utils.setOnClashOn(function()
		return S.active
	end)

	Utils.setOnTarget(onTarget)
	Utils.setOnTeleport(onTeleport)

	return true
end

function AutoClash.evaluate(t, hr, ball, config)
	evaluate(t, hr, ball, config)
end

function AutoClash.updateDashTrack(...)
end

function AutoClash.installAntiDashHooks()
end

function AutoClash.getState()
	return S
end

function AutoClash.clashOn()
	return S.active
end

function AutoClash.getClashAt()
	return S.activeAt
end

function AutoClash.snapshot()
	return nil
end

function AutoClash.invalidateSnapshot()
end

function AutoClash.onBallSync(data)
	if typeof(data) ~= "table" then
		return
	end

	onTarget(
		data.TargetPlayerID or -999,
		now()
	)
end

function AutoClash.resetState()
	S.enabled = false
	S.active = false
	S.activeAt = 0
	S.inactiveAt = 0

	S.lastTarget = -999
	S.lastTargetAt = 0
	S.lastTimeWasTarget = 0

	S.wasMeTarget = false
	S.lostMeAt = 0
	S.targetReturnMinDist = 0

	S.activationSpeed = 0
	S.activationTargetWindow = 0

	S.teleportLockUntil = 0

	resetDetector()
end

function AutoClash.forceClear()
	forceDeactivate(now())
end

if _G.ExodusModules then
	_G.ExodusModules.AutoClash = AutoClash
end

return AutoClash