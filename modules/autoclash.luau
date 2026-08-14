-- [[ auto clash ]]

local AutoClash = {}

local GameInfo
local Utils
local AutoParry

-- ── tunable ──────────────────────────────────────────────────────────────────

local C = {
	ACT_RAD_FACTOR = 1.40,

	DET_RAD_MIN = 10,
	DET_RAD_MAX = 25,
	DET_RAD_SPD_REF = 120,
	DET_DIST_DELTA = 0.5,

	DET_RETURN_MAX_LO = 0.220,
	DET_RETURN_MIN_HI = 0.100,
	DET_RETURN_SPD_LO = 60,
	DET_RETURN_SPD_HI = 200,

	-- target return: era target → deixou de ser → voltou em janela curta = ativa
	-- convive com return físico (fontes separadas, OR na ativação)
	-- apertado com folga: rejeita oscilação lenta, pega return rápido
	TARGET_RETURN_MAX_LO = 0.140, -- @ spd baixa
	TARGET_RETURN_MIN_HI = 0.070, -- @ spd alta
	TARGET_RETURN_SPD_LO = 60,
	TARGET_RETURN_SPD_HI = 200,

	-- deactivation: ausência de target (evento de sync, separado do return detector)
	-- timeout curto → desativa fácil
	DEACT_TARGET_SPD_LO = 60,
	DEACT_TARGET_SPD_HI = 200,
	DEACT_TIMEOUT_LO = 0.180,   -- desativa fácil @ spd baixa
	DEACT_TIMEOUT_HI = 0.080,   -- desativa fácil @ spd alta

	-- lockout/histerese temporal
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
	lastTimeWasTarget = 0, -- timestamp da última vez que fui target (driver da deactivation)
	wasMeTarget = false,   -- driver do target return (ativação)
	lostMeAt = 0,          -- quando perdi o target (pra medir "voltei rápido")

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

local function activate(t)
	if S.active then
		return false
	end

	if t - S.inactiveAt < C.INACTIVE_LOCK then
		return false
	end

	S.active = true
	S.activeAt = t
	S.inactiveAt = 0
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
	resetDetector()

	return true
end

local function forceDeactivate(t)
	S.active = false
	S.activeAt = 0
	S.inactiveAt = t
	resetDetector()
	return true
end

-- ── return detector (ativação) ───────────────────────────────────────────────
-- INTOCADO: é a fonte da ativação. Não pode ser usado para desativar.

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
	local coming = velocity:Dot(offset.Unit) > 0

	if distance > radius * 1.2 then
		resetDetector()
		return false
	end

	if S.detPhase == "EXITED"
		and t - S.detExitAt > C.DET_TIMEOUT
	then
		resetDetector()
	end

	if S.detPhase == "IDLE" then
		if distance <= radius and coming then
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

-- ── target return (ativação) ────────────────────────────────────────────────
-- "era meu target → deixou de ser → voltou rápido" = ativa
-- Fonte: sync de target. Independente do return detector (física).

local function getTargetReturnWindow(speed)
	return lerpBySpeed(
		speed,
		C.TARGET_RETURN_SPD_LO,
		C.TARGET_RETURN_SPD_HI,
		C.TARGET_RETURN_MAX_LO,
		C.TARGET_RETURN_MIN_HI
	)
end

local function tickTargetReturn(t, ball)
	if not (S.wasMeTarget and isTargeted()) then
		return false
	end

	local speed = getBallSpeed(ball)
	local window = getTargetReturnWindow(speed)
	local elapsed = t - S.lostMeAt

	-- consome o evento (one-shot)
	S.wasMeTarget = false
	S.lostMeAt = 0

	return elapsed <= window
end

-- ── activation ───────────────────────────────────────────────────────────────

local function shouldActivate(t, hr, ball)
	if not hr or not hr.Parent then
		return false
	end

	if not ball or not ball.Parent then
		return false
	end

	-- return físico OU target return (fontes separadas, OR)
	if tickReturnDetector(t, hr, ball) then
		return true
	end

	if isTargeted() then
		return tickTargetReturn(t, ball)
	end

	return false
end

-- ── deactivation ─────────────────────────────────────────────────────────────
-- Mede AUSÊNCIA de target (evento de sync do servidor).
-- Fonte completamente diferente do return detector, não conflita com ativação.

local function getDeactivateTimeout(speed)
	-- bola rápida → timeout curto; bola lenta → timeout longo
	return lerpBySpeed(
		speed,
		C.DEACT_TARGET_SPD_LO,
		C.DEACT_TARGET_SPD_HI,
		C.DEACT_TIMEOUT_LO,
		C.DEACT_TIMEOUT_HI
	)
end

local function shouldDeactivate(t, hr, ball)
	-- panic: teleporte
	if t < S.teleportLockUntil then
		return true
	end

	-- panic: bola ou player não existe
	if not (hr and hr.Parent and ball and ball.Parent) then
		return true
	end

	-- GATE: target demorou mais que o timeout pra voltar (= não é return)
	-- em clash, o target volta em ms → sinceTarget < timeout → bloqueado aqui
	local speed = getBallSpeed(ball)
	local timeout = getDeactivateTimeout(speed)
	local sinceTarget = t - S.lastTimeWasTarget

	if sinceTarget <= timeout then
		return false
	end

	-- CONFIRMAÇÃO: passou do gate, agora checa se a bola foi embora (dot ≤ 0)
	-- dot > 0 = bola ainda voltando / vindo → segura mais um pouco
	-- dot ≤ 0 = bola já tá se afastando → desativa
	local velocity = getBallVelocity(ball)
	if not velocity or speed <= 1 then
		-- sem velocidade válida: conservador, desativa
		return true
	end

	local offset = hr.Position - ball.Position
	local distance = offset.Magnitude

	if distance <= 0.001 then
		return true
	end

	local movingAway = velocity:Dot(offset.Unit) <= 0

	return movingAway
end

-- ── evaluate ─────────────────────────────────────────────────────────────────

local function evaluate(t, hr, ball, config)
	local enabled =
		config
		and config.AutoClash ~= false
		and not _G.PhantomManual

	if not enabled then
		S.enabled = false
		forceDeactivate(now())
		return
	end

	if GameInfo.isGrace() then
		forceDeactivate(now())
		return
	end

	S.enabled = true

	if not hr or not hr.Parent then
		forceDeactivate(now())
		return
	end

	if not ball or not ball.Parent then
		forceDeactivate(now())
		return
	end

	if t < S.teleportLockUntil then
		forceDeactivate(now())
		return
	end

	if S.active then
		if shouldDeactivate(t, hr, ball) then
			deactivate(t)
		end
	else
		if shouldActivate(t, hr, ball) then
			activate(t)
		end
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

	-- marca timestamp sempre que o target for eu (driver da deactivation)
	if isMe then
		S.lastTimeWasTarget = t
	end

	-- detecta "era meu target → deixou de ser" (arma target return)
	if wasMe and not isMe then
		S.wasMeTarget = true
		S.lostMeAt = t
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
	S.teleportLockUntil = now() + 0.5
	forceDeactivate(now())
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
