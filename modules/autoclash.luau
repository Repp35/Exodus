--[[ AutoClash ]]

local AutoClash = {}

local CLASH = {
        BALL_HARD_CAP            = 22,
        HOLD                     = 0.20,
        REACT_CD                 = 0.120,
        OFF_FAST                 = 0.050,
        MAX_HOLD                 = 1.2,
        BURST_ON_MS              = 0.080,
        BURST_OFF_MS             = 0.060,
        DET_RAD_MIN              = 10,
        DET_RAD_MAX              = 25,
        DET_RAD_SPD_REF          = 120,
        DET_DOT_EMA              = 0.25,
        DET_DOT_THRESH           = 0.15,
        DET_RETURN_FACTOR        = 1.5,
        DET_TIMEOUT              = 0.8,
        DASH_SPD_THRESH          = 50,
        DASH_SPD_CONFIRM         = 62,
        DASH_SPD_RELEASE         = 35,
        DASH_DUR_MIN             = 0.08,
        DASH_DUR_MAX             = 0.5,
        DASH_PANIC_DOT           = 0.85,
        DASH_PANIC_WINDOW        = 0.300,
        DASH_PANIC_DIST          = 14,
        DASH_TRACK_INTERVAL      = 0.2,
        FULL_PLAYER_SCAN_INTERVAL = 1.0,
        PLAYER_SCAN_RADIUS       = 100,
        ANTIDASH_RAD_MIN         = 20,
        ANTIDASH_RAD_MAX         = 32,
        ANTIDASH_DOT_MIN         = 0.0,
        ANTIDASH_PANIC_HOLD      = 0.45,
        ANTIDASH_PANIC_MAX       = 1.2,
        ANTIDASH_COOLDOWN        = 0.35,
        ANTIDASH_BONUS           = 0,
        DEACT_FACTOR             = 4.0,
        DEACT_CONFIRM_MS         = 0.500,
        DEACT_GONE_DIST          = 60,
        DEACT_DOT_HOLD           = 0.150,
}

local P = {
        DEFLECT_R = 8.5,
}

local _now = os.clock

local GameInfo, Utils, AutoParry
local _localUserId = -1
local _antidashCooldown, _antidashHooked = {}, {}
local _lastDashTrack, _lastFullPlayerScan = 0, 0

local S = {
        lastTarget      = -999,
        wasTargeted     = false,
        clashOn         = false,
        clashAt         = 0,
        clashHoldUntil  = 0,
        lastClashReact  = 0,
        detPhase        = "IDLE",
        detEnterAt      = 0,
        detEntryTime    = 0,
        detExitAt       = 0,
        detDotEma       = 0,
        detWasInside    = false,
        detSignal       = false,
        burstState      = "IDLE",
        burstOnStart    = 0,
        burstOffStart   = 0,
        burstSignalDuringOn = false,
        dashAnti        = { untilT = 0, src = nil },
        dashPanicUntil  = 0,
        dashEvents      = {},
        dotNegStart     = nil,
}

-- helpers
local function isTargeted(target)
        local fn = GameInfo and GameInfo.isTargeted
        if type(fn) == "function" then
                local ok, v = pcall(fn, target)
                if ok and v then return true end
        end
        if type(target) == "number" and target == _localUserId then return true end
        if type(target) == "number" and target == -999 and S.lastTarget == _localUserId then return true end
        return false
end

local function clearClash()
        S.clashOn        = false
        S.clashHoldUntil = 0
        S.dotNegStart    = nil
        S.burstState     = "IDLE"
        S.burstSignalDuringOn = false
end

local function getDetectorRadius(spd)
        local t = math.clamp((spd or 0) / CLASH.DET_RAD_SPD_REF, 0, 1)
        return CLASH.DET_RAD_MIN + (CLASH.DET_RAD_MAX - CLASH.DET_RAD_MIN) * t
end

local function getParryBonus()
        local fn = AutoParry and AutoParry.resRadiusBonus
        if type(fn) ~= "function" then return 0 end
        local ok, v = pcall(fn)
        return ok and (tonumber(v) or 0) or 0
end

local function getAutoParryState()
        local fn = AutoParry and AutoParry.getState
        if type(fn) ~= "function" then return nil end
        local ok, st = pcall(fn)
        return ok and st or nil
end

local function getBall()
        local fn = GameInfo and GameInfo.getBall
        if type(fn) ~= "function" then return nil end
        local ok, b = pcall(fn)
        return ok and b or nil
end

local function getLocalHumanoid()
        if not Utils then return nil end
        local lp = Utils.getLocalPlayer()
        if not (lp and lp.Parent) then return nil end
        local ch = lp.Character
        if not (ch and ch.Parent) then return nil end
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if not (hum and hum.Parent and hum.Health > 0) then return nil end
        return hum
end

local function getMyHRP()
        if not Utils then return nil end
        local lp = Utils.getLocalPlayer()
        local ch = lp and lp.Character
        return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function getPlayers()
        if not Utils then return nil end
        local fn = Utils.getPlayers
        if type(fn) ~= "function" then return nil end
        local ok, p = pcall(fn)
        return ok and p or nil
end

local function burstActivate(t)
        S.clashOn        = true
        S.clashAt        = t
        S.clashHoldUntil = t + CLASH.BURST_ON_MS
        S.lastClashReact = t
        S.burstState          = "ON"
        S.burstOnStart        = t
        S.burstSignalDuringOn = false
        S.burstOffStart       = 0
        if _G.PhantomOnBurst then pcall(_G.PhantomOnBurst) end
end

-- return detector
local function tickReturnDetector(t, hr, ball)
        S.detSignal = false

        if not (hr and hr.Parent and ball and ball.Parent) then
                S.detPhase, S.detDotEma, S.detWasInside = "IDLE", 0, false
                return
        end

        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        if not (ok and typeof(av) == "Vector3" and av.Magnitude > 1) then
                S.detDotEma = 0
                return
        end

        local spd    = av.Magnitude
        local radius = getDetectorRadius(spd)
        local toMe   = hr.Position - ball.Position
        local dist   = toMe.Magnitude
        local unit   = toMe.Magnitude > 0.001 and toMe.Unit or Vector3.zero
        local dotRaw = av:Dot(unit)

        if dist <= radius * 1.2 then
                S.detDotEma = S.detDotEma * (1 - CLASH.DET_DOT_EMA) + dotRaw * CLASH.DET_DOT_EMA
        elseif dotRaw < CLASH.DET_DOT_THRESH then
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
                local limiar = math.max((S.detEntryTime or 0) * CLASH.DET_RETURN_FACTOR, 0.15)
                local reEntry = (isInside and not S.detWasInside) or (not isInside and dotComing)
                if reEntry then
                        if (t - S.detExitAt) <= limiar and dotComing then
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

local function shouldDeactivateClash(t, hr, ball)
        if t < S.clashHoldUntil then
                return false
        end

        if not S.clashOn then return false end

        if (t - S.clashAt) > CLASH.MAX_HOLD then return true end

        if not getLocalHumanoid() then return true end
        if not (ball and ball.Parent) then return true end
        if not (hr and hr.Parent) then return true end

        if (hr.Position - ball.Position).Magnitude > CLASH.DEACT_GONE_DIST then
                return true
        end

        if S.burstState == "IDLE" and S.detPhase == "EXITED" then
                local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
                if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
                        local toMe = hr.Position - ball.Position
                        if toMe.Magnitude > 1 then
                                local closing = av:Dot(toMe.Unit)
                                if closing < -0.1 then
                                        S.dotNegStart = S.dotNegStart or t
                                        if (t - S.dotNegStart) >= CLASH.DEACT_DOT_HOLD then
                                                return true
                                        end
                                else
                                        S.dotNegStart = nil
                                end
                        end
                end
        end

        return false
end

-- target
local function onTarget(newTarget, t)
        if type(newTarget) ~= "number" then return end
        if not GameInfo then return end

        local previousTarget = S.lastTarget
        S.lastTarget = newTarget

        local ap = getAutoParryState()
        if ap then ap.armed = (newTarget == _localUserId) end

        local Config = _G.PhantomConfig
        if not Config or Config.AutoClash == false or _G.PhantomManual then return end
        if newTarget ~= _localUserId then return end
        if previousTarget == newTarget then return end

        local hr = getMyHRP()
        local ball = getBall()
        if not (hr and hr.Parent and ball and ball.Parent) then return end

        local fnBP, fnBS, fnTIC = GameInfo.ballPos, GameInfo.ballSpeed, GameInfo.tImpCompensated
        if type(fnBP) ~= "function" or type(fnBS) ~= "function" or type(fnTIC) ~= "function" then return end

        local okP, bp = pcall(fnBP, ball, t)
        local okS, speed = pcall(fnBS, ball, t)
        if not (okP and okS) then return end

        local bDist = (hr.Position - bp).Magnitude
        local impactTime = math.huge
        if speed > 1 then
                local okT, v = pcall(fnTIC, bDist, speed)
                if okT and type(v) == "number" then impactTime = v end
        end

        if bDist <= CLASH.BALL_HARD_CAP
                and impactTime <= CLASH.OFF_FAST
                and (t - S.lastClashReact) >= CLASH.REACT_CD
        then
                burstActivate(t)
                S.clashHoldUntil = t + CLASH.HOLD
        end
end


-- evaluate
local function evaluateClash(t, hr, ball, Config)
        if not Config or Config.AutoClash == false or _G.PhantomManual then
                if S.clashOn then clearClash() end
                S.burstState, S.burstSignalDuringOn = "IDLE", false
                S.detSignal = false
                return
        end

        tickReturnDetector(t, hr, ball)

        if S.clashOn and shouldDeactivateClash(t, hr, ball) then
                clearClash()
                S.burstState, S.burstSignalDuringOn = "IDLE", false
                return
        end

        local antiDashActive = S.dashAnti.untilT > t
        local canFire = (S.detSignal and isTargeted(S.lastTarget)) or antiDashActive

        if S.clashOn then
                if S.burstState == "ON" and S.detSignal then
                        S.burstOnStart   = t
                        S.clashHoldUntil = t + CLASH.BURST_ON_MS
                end
        end

        if S.burstState == "IDLE" then
                if canFire then burstActivate(t) end
        elseif S.burstState == "ON" then
                if S.detSignal then S.burstSignalDuringOn = true end
                if (t - S.burstOnStart) >= CLASH.BURST_ON_MS then
                        if S.burstSignalDuringOn then
                                S.burstOnStart        = t
                                S.burstSignalDuringOn = false
                                S.clashHoldUntil      = t + CLASH.BURST_ON_MS
                        else
                                S.burstState, S.burstOffStart = "OFF", t
                        end
                end
        elseif S.burstState == "OFF" then
                if canFire then
                        burstActivate(t)
                elseif (t - S.burstOffStart) >= CLASH.BURST_OFF_MS then
                        S.burstState = "IDLE"
                end
        end
end

-- dash track
local function updateDashTrack(t)
        local Players = getPlayers()
        if not Players then return end

        if (t - _lastDashTrack) < CLASH.DASH_TRACK_INTERVAL then return end
        _lastDashTrack = t

        local lp = Utils.getLocalPlayer()
        local ch = lp and lp.Character
        local myHRP = ch and ch:FindFirstChild("HumanoidRootPart")
        if not (myHRP and myHRP.Parent) then
                table.clear(S.dashEvents)
                return
        end
        local myPos = myHRP.Position

        local fullScan = (t - _lastFullPlayerScan) >= CLASH.FULL_PLAYER_SCAN_INTERVAL
        local playersToCheck = {}
        if fullScan then
                _lastFullPlayerScan = t
                for _, p in Players:GetPlayers() do
                        if p ~= lp then table.insert(playersToCheck, p) end
                end
        else
                local seen = {}
                for _, p in Players:GetPlayers() do
                        if p == lp then continue end
                        seen[p.UserId] = true
                        if S.dashEvents[p.UserId] then
                                table.insert(playersToCheck, p)
                        else
                                local pch = p.Character
                                local php = pch and pch:FindFirstChild("HumanoidRootPart")
                                if php and php.Parent and (myPos - php.Position).Magnitude <= CLASH.PLAYER_SCAN_RADIUS then
                                        table.insert(playersToCheck, p)
                                end
                        end
                end
                for uid in pairs(S.dashEvents) do
                        if not seen[uid] then
                                local p = Players:GetPlayerByUserId(uid)
                                if p then table.insert(playersToCheck, p) end
                        end
                end
        end

        local processed = {}
        for _, p in ipairs(playersToCheck) do
                if processed[p.UserId] then continue end
                processed[p.UserId] = true
                local pch = p.Character
                local php = pch and pch:FindFirstChild("HumanoidRootPart")
                local hum = pch and pch:FindFirstChildOfClass("Humanoid")
                local alive = php and php.Parent and hum and hum.Parent and hum.Health > 0
                if not alive then
                        S.dashEvents[p.UserId] = nil
                        continue
                end

                local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
                if not (ok and typeof(av) == "Vector3") then
                        S.dashEvents[p.UserId] = nil
                        continue
                end
                local spd = av.Magnitude
                local ev = S.dashEvents[p.UserId]

                if spd >= CLASH.DASH_SPD_THRESH then
                        local dir = spd > 0.1 and av.Unit or nil
                        if not ev then
                                S.dashEvents[p.UserId] = { spd = spd, dir = dir, at = t, startedAt = t, confirmed = false }
                        else
                                ev.spd, ev.dir, ev.at = spd, dir, t
                                if not ev.confirmed and spd >= CLASH.DASH_SPD_CONFIRM then
                                        ev.confirmed, ev.startedAt = true, t
                                end
                        end
                elseif ev and ev.confirmed and spd >= CLASH.DASH_SPD_RELEASE then
                        ev.spd, ev.at = spd, t
                else
                        S.dashEvents[p.UserId] = nil
                end
        end

        for uid in pairs(S.dashEvents) do
                if not processed[uid] then S.dashEvents[uid] = nil end
        end

        for uid, ev in pairs(S.dashEvents) do
                if not (ev and ev.confirmed and ev.dir and ev.spd) then continue end
                local dur = ev.at - ev.startedAt
                if dur > CLASH.DASH_DUR_MAX then
                        S.dashEvents[uid] = nil
                        continue
                end
                local pl = Players:GetPlayerByUserId(uid)
                local php = pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
                if not (php and php.Parent) then
                        S.dashEvents[uid] = nil
                elseif dur >= CLASH.DASH_DUR_MIN then
                        local toMe = myPos - php.Position
                        local dist = toMe.Magnitude
                        if dist > 0.1 and dist <= CLASH.DASH_PANIC_DIST then
                                local dot = ev.dir:Dot(toMe.Unit)
                                if dot >= CLASH.DASH_PANIC_DOT and ev.spd >= CLASH.DASH_SPD_CONFIRM then
                                        S.dashPanicUntil = math.max(S.dashPanicUntil, t + CLASH.DASH_PANIC_WINDOW)
                                end
                        end
                end
        end
end

-- anti-dash
local function reportDash(player)
        if not (player and Utils) then return end
        local lp = Utils.getLocalPlayer()
        if player == lp then return end
        if not (_G.PhantomState and _G.PhantomState.active) then return end

        local t = _now()
        if _antidashCooldown[player.UserId] and (t - _antidashCooldown[player.UserId]) < CLASH.ANTIDASH_COOLDOWN then return end
        _antidashCooldown[player.UserId] = t

        local ch = player.Character
        if not (ch and ch.Parent) then return end
        local php = ch:FindFirstChild("HumanoidRootPart")
        local myHRP = getMyHRP()
        if not (php and php.Parent and myHRP and myHRP.Parent) then return end

        local rad = math.clamp(
                P.DEFLECT_R + getParryBonus() + CLASH.ANTIDASH_BONUS,
                CLASH.ANTIDASH_RAD_MIN,
                CLASH.ANTIDASH_RAD_MAX
        )
        local toMe = myHRP.Position - php.Position
        local dist = toMe.Magnitude
        if dist > rad or dist < 0.1 then return end

        local dot = 1
        local ok, av = pcall(function() return php.AssemblyLinearVelocity end)
        if ok and typeof(av) == "Vector3" and av.Magnitude > 1 then
                dot = av.Unit:Dot(toMe.Unit)
        end
        if dot < CLASH.ANTIDASH_DOT_MIN then return end

        local untilT = math.min(t + CLASH.ANTIDASH_PANIC_MAX, t + CLASH.ANTIDASH_PANIC_HOLD)
        S.dashAnti.untilT = math.max(S.dashAnti.untilT, untilT)
        S.dashAnti.src    = player
end

local function isDashAnimation(track)
        if not track or not track.Animation then return false end
        local n  = (track.Name or ""):lower()
        local an = (track.Animation.Name or ""):lower()
        return n:find("dash", 1, true) ~= nil or an:find("dash", 1, true) ~= nil
end

local function _hookPlayerAntiDash(player)
        if not player or not Utils then return end
        if player == Utils.getLocalPlayer() then return end
        if _antidashHooked[player] then return end
        _antidashHooked[player] = true

        local function attach(char)
                if not char then return end
                local hum = char:FindFirstChildOfClass("Humanoid")
                if not hum then return end
                local anim = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
                if not anim then return end
                for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
                        if isDashAnimation(tr) then reportDash(player); break end
                end
                anim.AnimationPlayed:Connect(function(track)
                        if isDashAnimation(track) then reportDash(player) end
                end)
        end

        if player.Character then attach(player.Character) end
        player.CharacterAdded:Connect(attach)
end

local function installAntiDashHooks()
        local Players = getPlayers()
        if not Players then return end
        for _, p in ipairs(Players:GetPlayers()) do
                if p ~= Utils.getLocalPlayer() then _hookPlayerAntiDash(p) end
        end
        Players.PlayerAdded:Connect(function(p)
                if p ~= Utils.getLocalPlayer() then _hookPlayerAntiDash(p) end
        end)
        Players.PlayerRemoving:Connect(function(p)
                _antidashHooked[p] = nil
                _antidashCooldown[p.UserId] = nil
                S.dashEvents[p.UserId] = nil
        end)
end

-- api
local _ballSyncConn
local function hookBallSync()
        if _ballSyncConn then return end
        local ok, rep = pcall(function() return game:GetService("ReplicatedStorage") end)
        if not ok or not rep then return end
        local remote = rep:FindFirstChild("Remotes") and rep.Remotes:FindFirstChild("BallSyncData")
        if not (remote and remote:IsA("RemoteEvent")) then
                remote = rep:FindFirstChild("BallSyncData", true)
        end
        if not (remote and remote:IsA("RemoteEvent")) then return end
        _ballSyncConn = remote.OnClientEvent:Connect(function(d)
                if type(d) == "table" and type(d.TargetPlayerID) == "number" then
                        onTarget(d.TargetPlayerID, _now())
                end
        end)
end

function AutoClash.setup(deps)
        deps = deps or {}
        GameInfo  = deps.GameInfo
        Utils     = deps.Utils
        AutoParry = deps.AutoParry

        local ok, lp = pcall(Utils.getLocalPlayer)
        _localUserId = (ok and lp and lp.UserId) or -1

        _G.PhantomClashOn    = function() return S.clashOn end
        _G.PhantomOnTarget   = onTarget
        _G.PhantomOnTeleport = clearClash

        pcall(hookBallSync)
end

function AutoClash.evaluate(t, hr, ball, Config)
        evaluateClash(t, hr, ball, Config)
end

function AutoClash.updateDashTrack(t)
        updateDashTrack(t)
end

function AutoClash.installAntiDashHooks()
        installAntiDashHooks()
end

function AutoClash.getState()   return S end
function AutoClash.clashOn()    return S.clashOn end
function AutoClash.getClashAt() return S.clashAt end
function AutoClash.snapshot()             return nil end
function AutoClash.invalidateSnapshot()   end

function AutoClash.resetState()
        if _ballSyncConn then pcall(_ballSyncConn.Disconnect, _ballSyncConn); _ballSyncConn = nil end
        S.lastTarget        = -999
        S.wasTargeted       = false
        S.clashOn, S.clashAt, S.clashHoldUntil, S.lastClashReact = false, 0, 0, 0
        table.clear(S.dashEvents)
        S.dashPanicUntil    = 0
        S.detPhase          = "IDLE"
        S.detEnterAt        = 0
        S.detEntryTime      = 0
        S.detExitAt         = 0
        S.detDotEma         = 0
        S.detWasInside      = false
        S.detSignal         = false
        S.burstState        = "IDLE"
        S.burstOnStart      = 0
        S.burstOffStart     = 0
        S.burstSignalDuringOn = false
        S.dashAnti          = { untilT = 0, src = nil }
        S.dotNegStart       = nil
end

return AutoClash
