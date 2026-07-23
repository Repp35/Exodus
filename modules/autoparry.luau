--[[ AutoParry ]]

local AutoParry = {}

-- deps
local Probe, GameInfo, Utils

-- tunning
local P = {
    FIRE_LOCK = 0.080,
    MIN_SPD = 3,
    DEFLECT_R = 8.5,
    RAD_FLOOR = 14,
    LEAD_CAP = 50,
    PRE_CAP = 30,
    PB_WEIGHT = 1.0,
    CPF_MIN_SPACING_MS = 0.05,
    CPF_MAX_SPACING_MS = 16,
    CPF_FPS_SAMPLE_T = 0.5,
    CPF_PING_FLOOR = 0.040,
    CPF_PING_REF = 0.060,
    LEAD_PING_FLOOR = 0.040,
    LEAD_RTT_MULT = 0.5,
    LEAD_TICK_FRAMES = 2,
    RES_BASE = 0,
    RES_PER_PARRY = 0.225,
    RES_CAP = 32,
    RES_HOLD_T = 1.2,
    RES_DECAY_T = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5,
    RES_HITBOX_PROX = 12,
    MIN_REFIRE_GAP = 0.015,
    REFIRE_TTH = 0.20,
    GRACE_TIMEOUT = 0.30,
}

-- AP
local AP = {
    armed = false,
    fired = false,
    firedAt = 0,
    wasInRange = false,
    inRangeEnterAt = 0,
    lastValidSync = 0,
    lastValidBall = 0,
    lastMissAt = 0,
}

-- RES
local RES = {
    stack = 0,
    lastFireBallRef = nil,
    lastFireBallAt = 0,
    lastHitboxAt = 0,
    lastStackAt = 0
}

-- Sync
local Sync = {
    Speed = 0,
    RealPos = Vector3.new(0, 0, 0),
    ForceDir = false,
    ForcedDir = Vector3.new(0, 0, 0),
    DeflectDir = Vector3.new(0, 0, 0),
    Grace = false,
    Teleported = false,
    Target = -999,
    lastSyncAt = 0,
    forcedAt = 0
}

-- locals
local _teleportLockUntil = 0
local _apBind = 0
local _resolveCache = 0
local _now = os.clock
local _localUserId = -1
local _onFired = nil
local _lastTargetSeen = -999

-- resRadiusBonus
local function resRadiusBonus()
    return math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP)
end

-- tickResilience
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
        if frac <= 0 then
            RES.stack = 0
        else
            local decayed = math.floor(RES.stack * frac + 0.5)
            if decayed ~= RES.stack then
                RES.stack = decayed
            end
        end
    end
end

-- getDeflectCD (delegates to GameInfo, which auto-resolves the Deflect ability ref)
local function getDeflectCD()
    if GameInfo and GameInfo.getDeflectCD then
        local ok, v = pcall(GameInfo.getDeflectCD)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- validRemote (mirror of v22.1 guard)
local function _validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

-- sendParry (mirror of v22.1: re-resolve if invalid OR cache stale)
local function sendParry()
    local t = _now()
    local r, m
    if (not _validRemote(Probe.getRemote())) or (t - _resolveCache) > 3.0 then
        r, m = Probe.resolveRemote()
        _resolveCache = t
    else
        r, m = Probe.getRemote()
    end
    if not r then
        return false
    end
    if not Probe.fireParry(1) then
        _resolveCache = 0
        Probe.invalidate()
        return false
    end
    local b = GameInfo.getBall()
    if b and b.Parent then
        RES.lastFireBallRef, RES.lastFireBallAt = b, t
    end
    if _onFired then
        _onFired(t)
    end
    return true
end

-- tgtOn (4 fallbacks, mais rápido vence — estilo deltav3)
local _br = nil
local _brTried = false
local function _ensureBR()
    if _brTried then return _br end
    _brTried = true
    pcall(function()
        local ts = game:GetService("ReplicatedStorage"):FindFirstChild("TS")
        if not ts then return end
        local brMod = ts:FindFirstChild("BallReplicator")
            and ts.BallReplicator:FindFirstChild("BallReplicator")
        if brMod then
            local ok, mod = pcall(require, brMod)
            if ok and mod and mod.BallReplicator then
                _br = mod.BallReplicator
            end
        end
    end)
    return _br
end

local function tgtOn(ch)
    if not ch or not ch.Parent then return false end
    -- 1) Workspace attribute (replicado pelo servidor, fonte da verdade)
    local ok, ws = pcall(function() return game:GetService("Workspace") end)
    if ok and ws and ws:GetAttribute("GameBallTarget") == _localUserId then
        return true
    end
    -- 2) BallReplicator.syncData (cache RAM, instantâneo)
    local br = _ensureBR()
    if br and br.syncData and br.syncData.HighlightTargetPlayerID == _localUserId then
        return true
    end
    -- 3) Sync.Target (último recurso, derivado do server sync)
    if Sync and Sync.Target == _localUserId then
        return true
    end
    return false
end

-- resetState
local function resetState()
    AP.armed, AP.fired, AP.firedAt = false, false, 0
    AP.inRangeEnterAt, AP.wasInRange = 0, false
    AP.lastMissAt = 0
    RES.stack = 0
    RES.lastFireBallRef = nil
    RES.lastFireBallAt = 0
    RES.lastHitboxAt = 0
    RES.lastStackAt = 0
    Sync.Speed = 0
    Sync.RealPos = Vector3.new(0, 0, 0)
    Sync.ForceDir = false
    Sync.ForcedDir = Vector3.new(0, 0, 0)
    Sync.DeflectDir = Vector3.new(0, 0, 0)
    Sync.Grace = false
    Sync.Teleported = false
    Sync.Target = -999
    Sync.lastSyncAt = 0
    Sync.forcedAt = 0
    _teleportLockUntil = 0
end

-- onBallSync
local function onBallSync(d)
    if typeof(d) ~= "table" then
        return
    end
    local t = _now()
    if type(d.Speed) == "number" then
        Sync.Speed = d.Speed
    end
    if typeof(d.RealPosition) == "Vector3" then
        Sync.RealPos = d.RealPosition
    end
    if typeof(d.DeflectDirection) == "Vector3" then
        Sync.DeflectDir = d.DeflectDirection
    end
    if type(d.Grace) == "boolean" then
        Sync.Grace = d.Grace
    end
    if type(d.ForceDirection) == "boolean" then
        if d.ForceDirection and not Sync.ForceDir then
            Sync.forcedAt = t
        end
        Sync.ForceDir = d.ForceDirection
    end
    if typeof(d.ForcedDirection) == "Vector3" then
        Sync.ForcedDir = d.ForcedDirection
    end
    Sync.lastSyncAt = t
    if d.Teleported == true then
        _teleportLockUntil = t + 0.20
        AP.fired = false
        if _G.PhantomOnTeleport then
            _G.PhantomOnTeleport()
        end
        Sync.Teleported = true
        return
    end
    Sync.Teleported = false
    GameInfo.applySync(d)
    local newTarget = d.TargetPlayerID
    if type(newTarget) == "number" then
        Sync.Target = newTarget
    else
        newTarget = -999
    end
    -- FIX DOUBLE-CLICK (match v22.1): se o target NÃO mudou, não toca em AP.fired.
    -- O reset de AP.fired só rola quando o target REALMENTE muda.
    -- Regra: "bola foi minha → cliquei → bola parou de ser minha → só posso
    -- clicar quando ela voltar a ser minha".
    if newTarget == _lastTargetSeen then
        Sync.Target = newTarget
        return
    end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen, Sync.Target = newTarget, newTarget
    if newTarget == _localUserId then
        Sync.Grace = false
        AP.fired = false
    elseif newTarget ~= -999 then
        Sync.Grace = true
        if previousTarget == _localUserId then
            AP.fired = false
        end
    else
        AP.fired = false
    end
    if d.Grace == false then
        Sync.Grace = false
    elseif d.Grace == true then
        Sync.Grace = true
    end
    if _G.PhantomOnTarget then
        _G.PhantomOnTarget(newTarget, t)
    end
end

-- bindParry
local function bindParry(ch)
    _apBind = _apBind + 1
    local id = _apBind
    if not (ch and ch.Parent) then
        return
    end
    local hrp = ch:FindFirstChild("HumanoidRootPart") or ch:WaitForChild("HumanoidRootPart", 1)
    if id ~= _apBind or not (hrp and hrp.Parent) then
        return
    end
    AP.fired, AP.armed = false, false
    -- heartbeat
    Utils.trackCharacter(
        Utils.getRunService().Heartbeat:Connect(
            function(dt)
                if id ~= _apBind or not (ch.Parent and hrp.Parent) then
                    return
                end
                local Config = _G.PhantomConfig
                if not Config or Config.AutoParry ~= true then
                    AP.fired = false
                    return
                end
                local t = _now()
                -- Grace timeout PRIMEIRO: se Sync.Grace ficou stuck em true, limpa.
                if Sync.Grace and (t - Sync.lastSyncAt) > P.GRACE_TIMEOUT then
                    Sync.Grace = false
                end
                if t < _teleportLockUntil or Sync.Grace then
                    return
                end
                if (_G.PhantomClashOn and _G.PhantomClashOn()) or _G.PhantomManual then
                    return
                end
                tickResilience(t)
                local ball = GameInfo.getBall()
                if not (ball and ball.Parent) then
                    return
                end
                if tgtOn == nil or not tgtOn(ch) then
                    AP.armed = false
                    return
                end
                local syncFresh = (t - Sync.lastSyncAt) < 0.5
                local bp = (syncFresh and Sync.RealPos ~= Vector3.new(0, 0, 0)) and Sync.RealPos or ball.Position
                local spd
                if syncFresh and Sync.Speed > 0 then
                    spd = Sync.Speed
                else
                    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
                    spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
                end
                if spd < P.MIN_SPD then
                    return
                end
                local tickMs = (GameInfo.frameEMA() > 0 and GameInfo.frameEMA() * 1000) or 16.67
                local leadSec = math.max(
                    GameInfo.pingRTT() * P.LEAD_RTT_MULT + (P.LEAD_TICK_FRAMES * tickMs / 1000),
                    P.LEAD_PING_FLOOR
                )
                local leadB = math.min(spd * leadSec, P.LEAD_CAP)
                local pbStuds = math.min(GameInfo.preBufferStuds(spd), P.PRE_CAP)
                local parryRad = math.max(P.DEFLECT_R + leadB + pbStuds + resRadiusBonus(), P.RAD_FLOOR)
                local dx = hrp.Position.X - bp.X
                local dy = hrp.Position.Y - bp.Y
                local dz = hrp.Position.Z - bp.Z
                local dist2 = dx * dx + dy * dy + dz * dz
                if dist2 > parryRad * parryRad then
                    AP.wasInRange, AP.inRangeEnterAt = false, 0
                    return
                end
                AP.wasInRange = true
                -- >>> fonte da verdade: cooldown real da ability
                -- espera o cooldown real zerar antes de tentar de novo (acerto OU miss)
                local realCD = getDeflectCD()
                if realCD > 0 then
                    return
                end
                -- lock curto anti-double-fire (mesmo tick)
                if AP.fired then
                    if (t - AP.firedAt) < P.FIRE_LOCK then
                        return
                    end
                    -- passou o FIRE_LOCK e cooldown real zerou => libera
                    AP.fired = false
                    AP.lastMissAt = t
                end
                if AP.firedAt > Sync.lastSyncAt then
                    return
                end
                if (t - AP.firedAt) < P.FIRE_LOCK then
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
                    AP.lastMissAt = t
                end
            end
        )
    )
    -- ancestry
    Utils.trackCharacter(
        ch.AncestryChanged:Connect(
            function(_, parent)
                if not parent then
                    _apBind = _apBind + 1
                end
            end
        )
    )
end

-- setup
function AutoParry.setup(deps)
    Probe = deps.Probe
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    _localUserId = Utils.getLocalPlayer().UserId
    _G.PhantomResilience = RES
    _G.PhantomApState = AP
    _G.PhantomApSync = Sync
end

-- public api
function AutoParry.setOnFired(fn)
    _onFired = fn
end
function AutoParry.fire()
    return sendParry()
end
function AutoParry.bindParry(ch)
    bindParry(ch)
end
function AutoParry.resetState()
    resetState()
end
function AutoParry.onBallSync(d)
    onBallSync(d)
end
function AutoParry.resRadiusBonus()
    return resRadiusBonus()
end
function AutoParry.getState()
    return AP
end
function AutoParry.getRes()
    return RES
end
function AutoParry.getSync()
    return Sync
end
function AutoParry.getLastFireBallRef()
    return RES.lastFireBallRef
end
function AutoParry.getLastFireBallAt()
    return RES.lastFireBallAt
end
function AutoParry.getP()
    return P
end

return AutoParry
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
