--[[ AutoClash ]]

local AutoClash = {}
local _Probe, GameInfo, Utils, AutoParry

-- tunning
local CLASH = {
        DECAY                    = 0.310,
        HOLD                     = 0.20,
        REACT_CD                 = 0.120,
        BALL_RANGE               = 18,
        BALL_HARD_CAP            = 22,
        MAX_BALL_DIST            = 45,
        PANIC_DIST               = 9,
        PANIC_BALL               = 13,
        CPS_THRESH               = 8,
        CPS_WIN                  = 1.0,
        MIN_DANGER               = 70,
        TIMP_FAR                 = 0.180,
        SPD_FAST                 = 65,
        SPD_MID                  = 40,
        SPD_LOW                  = 20,
        OFF_PANIC                = 0.090,
        OFF_FAST                 = 0.050,
        OFF_MID                  = 0.060,
        OFF_LOW                  = 0.070,
        OFF_VLOW                 = 0.090,
        COLD_TIMP_CAP            = 0.210,
        MIN_HOLD                 = 0.050,
        MAX_HOLD                 = 1.2,
        TIMP_RISE_FLOOR          = 0.006,
        TIMP_RISE_N_OF_M         = 2,
        TIMP_RISE_M              = 3,
        RING_FRESH_MAX           = 0.6,
        REARM_HYST_FACTOR        = 0.5,
        REARM_HYST_WIN           = 0.5,
        REARM_COOLDOWN           = 0.220,
        ARM_DIST_CAP             = 22,
        ARM_TIMP_CAP             = 0.22,
        REENTRY_DIST             = 22,
        FAST_BALL_SPD            = 200,
        FAST_BALL_CPS            = 0,
        FAST_BALL_TIMP_CAP       = 0.060,
        DASH_SPD_THRESH          = 50,
        DASH_SPD_CONFIRM         = 62,
        DASH_SPD_RELEASE         = 35,
        DASH_DUR_MIN             = 0.08,
        DASH_DUR_MAX             = 0.5,
        DASH_PANIC_DOT           = 0.85,
        DASH_PANIC_WINDOW        = 0.300,
        DASH_PANIC_DIST          = 14,
        PREEMPT_DIST             = 22,
        PREEMPT_TIMP_CAP         = 0.120,
        PING_CREDIT_F            = 0.5,
        PING_FLOOR               = 0.040,
        PING_REF                 = 0.060,
        PING_MAX_SCALE           = 1.0,
        COLD_PING_SCALE          = 0.4,
        FAST_PING_SCALE          = 0.5,
        PREEMPT_PING_SCALE       = 0.4,
        -- (maintenance thresholds removed; deactivation now derives everything from effectiveRadius)
        DEACT_GONE_FACTOR        = 1.5,
        DEACT_NOTARGET_FACTOR   = 1.2,
        DEACT_STOP_DIST          = 12,
        DEACT_STOP_SPD           = 3,
        DEACT_TIMP_FACTOR        = 1.3,
        DEACT_TIMP_MIN           = 0.08,
        DEACT_TIMP_MAX           = 0.25,
        -- Gate vindo do detector de retorno: se passou da janela dinâmica
        -- (mesma que o detector usa pra detectar retorno) E do piso,
        -- a bola foi embora de verdade.
        DEACT_RETURN_FLOOR_MS    = 0.350,
        -- Tracker de dot leaving: bola visivelmente indo embora por X tempo
        -- (complemento da regra 1: mede direção, não física prevista)
        DEACT_DOT_ENTER          = -0.30,  -- dot precisa ser < isto pra começar a contar
        DEACT_DOT_EXIT           = -0.15,  -- dot precisa ser > isto pra resetar
        DEACT_DOT_HOLD           = 0.350,  -- tempo sustentado antes de desativar
        DEACT_DOT_MIN_SPD        = 1.0,    -- abaixo disto, dot é lixo, reseta
        SPAM_PRE_FILL_FRAMES     = 4,
        BURST_ON_MS              = 0.080,
        BURST_OFF_MS             = 0.060,
        DET_RAD_MIN              = 10,
        DET_RAD_MAX              = 25,
        DET_RAD_SPD_REF          = 120,
        DET_RETURN_FACTOR        = 1.3,
        DET_DOT_EMA              = 0.25,
        DET_DOT_THRESH           = 0.15,
        DET_TIMEOUT              = 0.8,
        ANTIDASH_RAD_MIN         = 20,
        ANTIDASH_RAD_MAX         = 32,
        ANTIDASH_DOT_MIN         = 0.0,
        ANTIDASH_PANIC_HOLD      = 0.45,
        ANTIDASH_PANIC_MAX       = 1.2,
        ANTIDASH_COOLDOWN        = 0.35,
        TELEPORT_LOCK            = 0.20,
        DASH_TRACK_INTERVAL      = 0.2,
        FULL_PLAYER_SCAN_INTERVAL = 1.0,
        PLAYER_SCAN_RADIUS       = 100,
        DANGER_EMA_ALPHA         = 0.15,
}

-- P
local P = {
        DEFLECT_R         = 8.5,
        RAD_FLOOR         = 14,
        MIN_SPD           = 3,
        MAINT_BALL_RADIUS = 25,
}

-- S
local S = {
        lastTarget           = -999,
        lastTargetAt         = 0,
        clashOn              = false,
        clashAt              = 0,
        clashHoldUntil       = 0,
        clashOffAt           = 0,
        lastClashReact       = 0,
        dangerEma            = 0,
        lastTImp             = 0,
        lastTImpAt           = 0,
        tImpRising           = false,
        tImpRiseHist         = { 0, 0, 0 },
        targetRing           = table.create(8, 0),
        targetRingIdx        = 0,
        targetCps            = 0,
        dashEvents           = {},
        dashPanicUntil       = 0,
        detPhase             = "IDLE",
        detEnterAt           = 0,
        detEntryTime         = 0,
        detExitAt            = 0,
        detDotEma            = 0,
        detWasInside         = false,
        detSignal            = false,
        burstState           = "IDLE",
        burstOnStart         = 0,
        burstOffStart        = 0,
        burstSignalDuringOn  = false,
        dashAnti             = { untilT = 0, src = nil, at = 0 },
        lastFireAt           = 0,
        dotLeaveStart        = -1, -- -1 = inativo; caso contrário timestamp em que dot ficou < DEACT_DOT_ENTER
}

-- locals
local _burstActiveShared = false
local _onBurstSink       = nil

local _ctxCache = { t = 0, valid = false }
local CLASH_SNAPSHOT_TTL = 0.05
local RING_BUF           = 8
local _now               = os.clock
local _lastDashTrack     = 0
local _lastFullPlayerScan = 0
local _antidashCooldown  = {}
local _antidashHooked    = {}
local _localUserId       = -1
local _spamDebt          = 0

-- ringPush
local function ringPush(t)
        S.targetRingIdx = (S.targetRingIdx % RING_BUF) + 1
        S.targetRing[S.targetRingIdx] = t
end

-- updateTargetCps
local function updateTargetCps(t, freshWin)
        local winStart = t - CLASH.CPS_WIN
        local cnt = 0
        for i = 1, RING_BUF do
                local ts = S.targetRing[i]
                if ts and ts >= winStart and (not freshWin or ts >= t - freshWin) then
                        cnt = cnt + 1
                end
        end
        S.targetCps = cnt / CLASH.CPS_WIN
end

-- tImpCapFor
local function tImpCapFor(spd, base, refSpd, lo, hi)
        if spd < 1 then return base end
        local s = math.clamp(refSpd / spd, 0.2, 2.5)
        return math.clamp(base * s, lo, hi)
end

-- deactTimpMax
-- tImpMax(spd) = clamp(0.25 / (spd/60), 0.08, 0.25)  -- i.e. larger for slow balls, smaller for fast
local function deactTimpMax(spd)
        if spd < 1 then return CLASH.DEACT_TIMP_MAX end
        return math.clamp(CLASH.DEACT_TIMP_MAX / (spd / 60), CLASH.DEACT_TIMP_MIN, CLASH.DEACT_TIMP_MAX)
end

-- isTargeted
local function isTargeted()
        return GameInfo.isTargeted(S.lastTarget)
end

-- clearClash
local function clearClash()
        S.clashOn, S.clashHoldUntil = false, 0
        S.clashOffAt = _now()
end

-- getDetectorRadius
local function getDetectorRadius(spd)
        local t = math.clamp((spd or 0) / CLASH.DET_RAD_SPD_REF, 0, 1)
        return CLASH.DET_RAD_MIN + (CLASH.DET_RAD_MAX - CLASH.DET_RAD_MIN) * t
end

-- tickReturnDetector
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
                        if delta <= limiar and dotComing then
                                S.detSignal = true
                        end
                        local entryTime = dist > 0.1 and (dist / spd) or 0.01
                        S.detPhase     = "INSIDE"
                        S.detEnterAt   = t
                        S.detEntryTime = entryTime
                end
        end
        S.detWasInside = isInside
end

-- clashSnapshot
local function clashSnapshot()
        local t = _now()
        if _ctxCache.valid and (t - _ctxCache.t) < CLASH_SNAPSHOT_TTL then
                return _ctxCache
        end
        local lp = Utils.getLocalPlayer()
        local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        if not (hr and hr.Parent) then
                _ctxCache.valid = false
                return nil
        end
        updateTargetCps(t, CLASH.RING_FRESH_MAX)
        local ball = GameInfo.getBall()
        if not (ball and ball.Parent) then
                _ctxCache.valid = false
                return nil
        end
        local nearest, nearestAlive = GameInfo.nearestPlayerAlive()
        local bp = ball.Position
        local bDist = (hr.Position - bp).Magnitude
        local panic = nearestAlive and (nearest <= CLASH.PANIC_DIST and bDist <= CLASH.PANIC_BALL)
        local live = GameInfo.liveTImp()
        local tImp, spd = live.tImp, live.spd
        if spd < 1 then
                local ti, _, s2 = GameInfo.computeTImp(hr, ball, t)
                tImp, spd = ti, s2
        end
        _ctxCache.t, _ctxCache.valid = t, true
        _ctxCache.hr = hr
        _ctxCache.ball, _ctxCache.bp = ball, bp
        _ctxCache.nearest, _ctxCache.nearestAlive = nearest, nearestAlive
        _ctxCache.bDist, _ctxCache.panic = bDist, panic
        _ctxCache.tImp, _ctxCache.spd = tImp, spd
        return _ctxCache
end

function AutoClash.invalidateSnapshot()
        _ctxCache.valid = false
end

-- trackDotLeaving
-- Retorna true se a bola está visivelmente indo embora há mais de DEACT_DOT_HOLD.
-- Histerese: precisa de DEACT_DOT_ENTER pra entrar, DEACT_DOT_EXIT pra sair.
-- Reseta se a bola parar (spd < DEACT_DOT_MIN_SPD) ou se a leitura falhar.
-- Sentinel: -1 = inativo. Não usa 0 porque colide com t=0 no início do jogo.
local function trackDotLeaving(ball, hr, t)
        local function reset() S.dotLeaveStart = -1 end
        if not (ball and ball.Parent and hr and hr.Parent) then
                reset()
                return false
        end
        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        if not (ok and typeof(av) == "Vector3" and av.Magnitude > CLASH.DEACT_DOT_MIN_SPD) then
                reset()
                return false
        end
        local toMe = hr.Position - ball.Position
        local mag = toMe.Magnitude
        if mag < 0.1 then
                reset()
                return false
        end
        local dot = av:Dot(toMe.Unit)

        if dot < CLASH.DEACT_DOT_ENTER then
                if S.dotLeaveStart < 0 then
                        S.dotLeaveStart = t
                end
                return (t - S.dotLeaveStart) > CLASH.DEACT_DOT_HOLD
        elseif dot > CLASH.DEACT_DOT_EXIT then
                reset()
                return false
        else
                return (S.dotLeaveStart >= 0) and ((t - S.dotLeaveStart) > CLASH.DEACT_DOT_HOLD) or false
        end
end

-- effectiveRadius
-- Raio efetivo do parry: tudo que tá dentro ainda é "nosso".
-- DEFLECT_R + bonus de raio do AutoParry + buffers de velocidade/latência + margem mínima.
local function effectiveRadius(spd)
        local parryBonus = (AutoParry and AutoParry.resRadiusBonus and AutoParry.resRadiusBonus() or 0)
        local ping = (GameInfo.getPing and GameInfo.getPing() or 0)
        return P.DEFLECT_R
                + parryBonus
                + (spd or 0) * 0.05
                + ping * 0.5
                + 1.5
end

-- (shouldMaintainClash / tickMaintenance removidos — shouldDeactivateClash decide tudo, todo frame)

-- isBallApproaching
local function isBallApproaching(hrp, ball)
        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then return true end
        local toMe = hrp.Position - ball.Position
        if toMe.Magnitude < 1 then return true end
        return av:Dot(toMe.Unit) > 0.25
end

-- shouldDeactivateClash
-- Roda todo frame, sem hold mínimo, sem maintain. Primeira regra que bater, desativa.
-- 1.  Gate do detector de retorno: EXITED há mais que (entryTime*1.3, 350ms)
-- 1.5 Dot leaving sustentado: dot<-0.30 por >350ms (histerese -0.30/-0.15)
-- 2.  Bola simplesmente longe demais (1.5x effectiveRadius)
-- 3.  tImp muito alto (bola não chega tão cedo)
-- 4.  Não sou target + distância moderada
-- 5.  Bola parada/morta longe
local function shouldDeactivateClash()
        if not S.clashOn then return false end

        -- Teto duro de duração (mantido como cinto de segurança)
        local t = _now()
        if (t - S.clashAt) > CLASH.MAX_HOLD then return true end

        -- Fatais: morreu / HRP sumiu / bola sumiu
        local lp = Utils.getLocalPlayer()
        local myChar = lp and lp.Character
        if not (myChar and myChar.Parent) then return true end
        local myHum = myChar:FindFirstChildOfClass("Humanoid")
        if not (myHum and myHum.Parent and myHum.Health > 0) then return true end
        local ball = GameInfo.getBall()
        if not (ball and ball.Parent) then return true end
        local hr = myChar:FindFirstChild("HumanoidRootPart")
        if not (hr and hr.Parent) then return true end

        local ctx = clashSnapshot()
        if not ctx then return true end

        local dist = ctx.bDist
        local spd  = ctx.spd or 0
        local rad  = effectiveRadius(spd)

        -- 1. Gate do detector de retorno: mesma lógica da ativação.
        -- Se a bola saiu do raio (EXITED) e já passou da janela dinâmica
        -- (detEntryTime * DET_RETURN_FACTOR) + piso de 350ms sem voltar,
        -- não é mais clash. Usa a física que a ativação já validou.
        if S.detPhase == "EXITED" then
                local window = (S.detEntryTime or 0) * CLASH.DET_RETURN_FACTOR
                local elapsed = t - S.detExitAt
                local threshold = math.max(window, CLASH.DEACT_RETURN_FLOOR_MS)
                if elapsed > threshold then
                        return true
                end
        end

        -- 1.5. Dot leaving sustentado: bola visivelmente indo embora por > 350ms.
        -- Complemento da regra 1: mede direção observada, não física prevista.
        -- Histerese: precisa de dot < -0.30 pra entrar, > -0.15 pra sair.
        if trackDotLeaving(ctx.ball, hr, t) then
                return true
        end

        -- 2. Longe demais, ponto.
        if dist > rad * CLASH.DEACT_GONE_FACTOR then return true end

        -- 3. tImp muito alto (bola não chega tão cedo)
        if ctx.tImp > deactTimpMax(spd) * CLASH.DEACT_TIMP_FACTOR then return true end

        -- 4. Não sou target + distância moderada
        if not isTargeted() and dist > rad * CLASH.DEACT_NOTARGET_FACTOR then return true end

        -- 5. Bola parada/morta longe
        if spd < CLASH.DEACT_STOP_SPD and dist > CLASH.DEACT_STOP_DIST then return true end

        return false
end

-- activateBurst
local function activateBurst(t, Config)
        S.burstState          = "ON"
        S.burstOnStart        = t
        S.burstSignalDuringOn = false
        S.clashOn             = true
        S.clashAt             = t
        S.clashHoldUntil      = t + CLASH.BURST_ON_MS
        S.lastClashReact      = t
        S.clashOffAt          = 0
        S.lastTImp, S.lastTImpAt, S.tImpRising = 0, 0, false
        S.tImpRiseHist        = { 0, 0, 0 }
        local c = math.max(tonumber(Config.CPS) or Utils.defaultCps(), 1)
        _spamDebt  = (1 / c) * CLASH.SPAM_PRE_FILL_FRAMES
        _burstActiveShared = false
        if _onBurstSink then
                _onBurstSink()
        end
        if _G.PhantomOnBurst then
                _G.PhantomOnBurst()
        end
end

-- onTarget
local function onTarget(newTarget, t)
        if type(newTarget) ~= "number" then
                return
        end
        local previousTarget = S.lastTarget
        S.lastTarget, S.lastTargetAt = newTarget, t
        ringPush(t)
        local ap = AutoParry.getState()
        ap.armed = newTarget == _localUserId
        -- (v22.1: AP.fired é resetado pelo onBallSync na borda de target, não aqui)
        local Config = _G.PhantomConfig
        local targeted = newTarget == _localUserId
        if targeted and Config and Config.AutoClash ~= false and not _G.PhantomManual
                and previousTarget ~= _localUserId and previousTarget ~= -999
        then
                local lp = Utils.getLocalPlayer()
                local hr = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
                local ball = GameInfo.getBall()
                if hr and hr.Parent and ball and ball.Parent then
                        local bp = GameInfo.ballPos(ball, t)
                        local bDist = (hr.Position - bp).Magnitude
                        local speed = GameInfo.ballSpeed(ball, t)
                        local impactTime = speed > 1 and GameInfo.tImpCompensated(bDist, speed) or math.huge
                        if bDist <= CLASH.BALL_HARD_CAP
                                and impactTime <= CLASH.OFF_FAST
                                and (t - S.lastClashReact) >= CLASH.REACT_CD
                        then
                                activateBurst(t, Config)
                                S.clashHoldUntil = t + CLASH.HOLD
                        end
                end
        end
end

-- onTeleport
local function onTeleport()
        clearClash()
end

-- evaluateClash
local function evaluateClash(t, hr, ball, Config)
        if Config.AutoClash == false or _G.PhantomManual then
                if S.clashOn then
                        clearClash()
                end
                S.burstState = "IDLE"
                S.burstSignalDuringOn = false
                return
        end

        -- Detector roda SEMPRE, inclusive quando clashOn
        tickReturnDetector(t, hr, ball)

        -- Desativação por condições extremas (morte, teleporte, bola sumiu)
        if S.clashOn and shouldDeactivateClash() then
                clearClash()
                S.burstState          = "IDLE"
                S.burstSignalDuringOn = false
                return
        end

        -- Se clash está on, só o burst renova o hold
        -- (sem maintain: shouldDeactivateClash já correu acima e decide tudo)
        if S.clashOn then
                -- Burst em ON: renova se houver sinal
                if S.burstState == "ON" then
                        if S.detSignal then
                                S.burstSignalDuringOn = true
                        end
                        -- Só renova o hold se houver sinal
                        if S.burstSignalDuringOn then
                                S.burstOnStart        = t
                                S.burstSignalDuringOn = false
                                S.clashHoldUntil      = t + CLASH.BURST_ON_MS
                        end
                end
                return
        end

        -- Clash não está on: máquina de burst normal
        local antiDashActive = S.dashAnti.untilT > t
        local canFire = (S.detSignal and isTargeted()) or antiDashActive

        if S.burstState == "IDLE" then
                if canFire then
                        activateBurst(t, Config)
                end
        elseif S.burstState == "ON" then
                if S.detSignal then
                        S.burstSignalDuringOn = true
                end
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
                        activateBurst(t, Config)
                elseif (t - S.burstOffStart) >= CLASH.BURST_OFF_MS then
                        S.burstState = "IDLE"
                end
        end
end

-- updateDashTrack
local function updateDashTrack(t, Players)
        if (t - _lastDashTrack) < CLASH.DASH_TRACK_INTERVAL then return end
        _lastDashTrack = t
        local lp = Utils.getLocalPlayer()
        local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        if not (myHRP and myHRP.Parent) then
                table.clear(S.dashEvents)
                return
        end
        local myPos = myHRP.Position
        local curDist = math.huge
        local playersToCheck = {}
        local fullScan = (t - _lastFullPlayerScan) >= CLASH.FULL_PLAYER_SCAN_INTERVAL
        if fullScan then
                _lastFullPlayerScan = t
                for _, p in Players:GetPlayers() do
                        if p ~= lp then
                                table.insert(playersToCheck, p)
                        end
                end
        else
                for uid in pairs(S.dashEvents) do
                        local p = Players:GetPlayerByUserId(uid)
                        if p and p ~= lp then
                                table.insert(playersToCheck, p)
                        end
                end
                for _, p in Players:GetPlayers() do
                        if p ~= lp and not S.dashEvents[p.UserId] then
                                local ch = p.Character
                                local php = ch and ch:FindFirstChild("HumanoidRootPart")
                                if php and php.Parent and (myPos - php.Position).Magnitude <= CLASH.PLAYER_SCAN_RADIUS then
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
                        if d < curDist then
                                curDist = d
                        end
                        local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
                        local spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
                        local dir = (ok and typeof(av) == "Vector3" and av.Magnitude > 0.1) and av.Unit or nil
                        local ev = S.dashEvents[p.UserId]
                        if spd >= CLASH.DASH_SPD_THRESH and dir then
                                if not ev then
                                        S.dashEvents[p.UserId] = {
                                                spd = spd, dir = dir, at = t,
                                                startedAt = t, confirmed = false,
                                        }
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
        for uid in pairs(S.dashEvents) do
                if not processed[uid] then
                        S.dashEvents[uid] = nil
                end
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

-- reportDash
local function reportDash(player)
        if not player or player == Utils.getLocalPlayer() then return end
        if not _G.PhantomState or not _G.PhantomState.active then return end
        local t = _now()
        local last = _antidashCooldown[player.UserId]
        if last and (t - last) < CLASH.ANTIDASH_COOLDOWN then return end
        _antidashCooldown[player.UserId] = t
        local ch = player.Character
        if not (ch and ch.Parent) then return end
        local php = ch:FindFirstChild("HumanoidRootPart")
        local lp = Utils.getLocalPlayer()
        local myChar = lp and lp.Character
        local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
        if not (php and php.Parent and myHRP and myHRP.Parent) then return end
        local baseParryRad = P.DEFLECT_R + (AutoParry and AutoParry.resRadiusBonus() or 0) + P.RAD_FLOOR
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

-- _hookPlayerAntiDash
local function _hookPlayerAntiDash(player)
        if not player or player == Utils.getLocalPlayer() then return end
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
                                        local n  = (tr.Name or ""):lower()
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
                                local n  = (track.Name or ""):lower()
                                local an = track.Animation.Name or ""
                                if n:find("dash") or an:lower():find("dash") then
                                        reportDash(player)
                                end
                        end)
                end)
        end
        if player.Character then
                attach(player.Character)
        end
        pcall(function() player.CharacterAdded:Connect(attach) end)
end

-- installAntiDashHooks
local function installAntiDashHooks(Players)
        for _, p in ipairs(Players:GetPlayers()) do
                if p ~= Utils.getLocalPlayer() then
                        _hookPlayerAntiDash(p)
                end
        end
        pcall(function()
                Players.PlayerAdded:Connect(function(p)
                        if p ~= Utils.getLocalPlayer() then
                                _hookPlayerAntiDash(p)
                        end
                end)
        end)
        pcall(function()
                Players.PlayerRemoving:Connect(function(p)
                        _antidashHooked[p] = nil
                        _antidashCooldown[p.UserId] = nil
                end)
        end)
end

-- setup
function AutoClash.setup(deps)
        _Probe    = deps.Probe
        GameInfo  = deps.GameInfo
        Utils     = deps.Utils
        AutoParry = deps.AutoParry
        _localUserId = Utils.getLocalPlayer().UserId
        _G.PhantomClashOn    = function() return S.clashOn end
        _G.PhantomOnTarget   = onTarget
        _G.PhantomOnTeleport = onTeleport
end

-- public api
function AutoClash.evaluate(t, hr, ball, Config)
        evaluateClash(t, hr, ball, Config)
end

function AutoClash.updateDashTrack(t)     updateDashTrack(t, Utils.getPlayers()) end
function AutoClash.installAntiDashHooks() installAntiDashHooks(Utils.getPlayers()) end
function AutoClash.getState()             return S end
function AutoClash.clashOn()              return S.clashOn end
function AutoClash.getClashAt()           return S.clashAt end
function AutoClash.snapshot()             return clashSnapshot() end

-- resetState
function AutoClash.resetState()
        S.clashOn, S.clashAt, S.clashHoldUntil, S.clashOffAt, S.lastClashReact = false, 0, 0, 0, 0
        S.dangerEma, S.lastTImp, S.lastTImpAt, S.tImpRising = 0, 0, 0, false
        S.tImpRiseHist = { 0, 0, 0 }
        S.targetRingIdx, S.targetCps = 0, 0
        S.lastFireAt = 0
        for i = 1, RING_BUF do
                S.targetRing[i] = 0
        end
        table.clear(S.dashEvents)
        S.dashPanicUntil = 0
        S.detPhase, S.detEnterAt, S.detEntryTime, S.detExitAt = "IDLE", 0, 0, 0
        S.detDotEma, S.detWasInside, S.detSignal = 0, false, false
        S.burstState, S.burstOnStart, S.burstOffStart, S.burstSignalDuringOn = "IDLE", 0, 0, false
        S.dashAnti = { untilT = 0, src = nil, at = 0 }
        S.dotLeaveStart = -1
        _ctxCache.valid = false
end

-- notifyFired
-- setBurstActive
-- getBurstActive
-- setBurstSink
function AutoClash.notifyFired(t)
        S.lastFireAt = t
end

function AutoClash.setBurstActive(b)
        _burstActiveShared = b
end

function AutoClash.getBurstActive() return _burstActiveShared end
function AutoClash.setBurstSink(fn) _onBurstSink = fn end

return AutoClash