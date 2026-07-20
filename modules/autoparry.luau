--[[ AutoParry fallback ]]

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
    BURST_SIZE = 8,
    BURST_GAP_FAST = 0.002,
    BURST_GAP_SLOW = 0.012,
    TRIGGER_TTH = 0.18,
    RAD_WIN = 0.20,
    RAD_OFF = 0,
    RAD_PRE = 0,
    RAD_MIN = 9,
    RAD_MAX = 90
}

-- AP
local AP = {
    armed = false,
    fired = false,
    firedAt = 0,
    wasInRange = false,
    inRangeEnterAt = 0,
    burstLeft = 0,
    burstNextAt = 0
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

-- resetState
local function resetState()
    AP.armed, AP.fired, AP.firedAt = false, false, 0
    AP.inRangeEnterAt, AP.wasInRange = 0, false
    AP.burstLeft, AP.burstNextAt = 0, 0
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
                    AP.fired, AP.burstLeft = false, 0
                    return
                end
                local t = _now()
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
                if not tgtOn(ch) then
                    AP.armed = false
                    return
                end
                local syncFresh = (t - Sync.lastSyncAt) < 0.3
                local bp = (syncFresh and Sync.RealPos ~= Vector3.new(0, 0, 0)) and Sync.RealPos or ball.Position
                local spd
                if syncFresh and Sync.Speed > 0 then
                    spd = Sync.Speed
                else
                    local ok, av =
                        pcall(
                        function()
                            return ball.AssemblyLinearVelocity
                        end
                    )
                    spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
                end
                if spd < P.MIN_SPD then
                    return
                end
                local tickMs = (GameInfo.frameEMA() > 0 and GameInfo.frameEMA() * 1000) or 16.67
                local leadSec =
                    math.max(
                    GameInfo.pingRTT() * P.LEAD_RTT_MULT + (P.LEAD_TICK_FRAMES * tickMs / 1000),
                    P.LEAD_PING_FLOOR
                )
                local leadB = math.min(spd * leadSec, P.LEAD_CAP)
                local pbStuds = math.min(GameInfo.preBufferStuds(spd), P.PRE_CAP)
                local parryRad = math.max(P.DEFLECT_R + leadB + pbStuds + resRadiusBonus(), P.RAD_FLOOR)
                local dx = hrp.Position.X - bp.X
                local dy = hrp.Position.Y - bp.Y
                local dz = hrp.Position.Z - bp.Z
                if dx * dx + dy * dy + dz * dz > parryRad * parryRad then
                    AP.wasInRange, AP.inRangeEnterAt = false, 0
                    return
                end
                AP.wasInRange = true
                if AP.fired then
                    local toMe = hrp.Position - bp
                    local ok, av =
                        pcall(
                        function()
                            return ball.AssemblyLinearVelocity
                        end
                    )
                    local vel = (ok and typeof(av) == "Vector3") and av or nil
                    if vel and vel.Magnitude > 0.5 then
                        local currentSpd = vel.Magnitude
                        local rad = math.clamp(currentSpd * P.RAD_WIN + P.RAD_OFF, P.RAD_MIN, P.RAD_MAX) + P.RAD_PRE
                        local distance = toMe.Magnitude
                        local inRange = distance <= rad
                        local closing = distance > 1e-4 and vel:Dot(toMe.Unit) or currentSpd
                        local timeToHit = currentSpd > 1 and (distance / currentSpd) or math.huge
                        local imminent = timeToHit < P.TRIGGER_TTH
                        if imminent and inRange and (t - AP.firedAt) > P.MIN_REFIRE_GAP and AP.burstLeft == 0 then
                            if sendParry() then
                                AP.firedAt = t
                                AP.burstLeft = P.BURST_SIZE - 1
                                local gap = closing > 80 and P.BURST_GAP_FAST or P.BURST_GAP_SLOW
                                AP.burstNextAt = t + gap
                            end
                        elseif AP.burstLeft > 0 and t >= AP.burstNextAt then
                            if sendParry() then
                                AP.burstLeft = AP.burstLeft - 1
                                local gap = closing > 80 and P.BURST_GAP_FAST or P.BURST_GAP_SLOW
                                AP.burstNextAt = t + gap
                                AP.firedAt = t
                            else
                                AP.burstLeft = 0
                            end
                        end
                    end
                    return
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
                AP.burstLeft, AP.burstNextAt = 0, 0
                if sendParry() then
                    AP.fired, AP.firedAt = true, t
                else
                    AP.fired = false
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

-- tgtOn (3 fallbacks, mais rápido vence — estilo deltav3)
local _br
local function _ensureBR()
    if _br ~= nil then return _br end
    local ok, mod = pcall(function()
        return Utils.getReplicatedStorage()
            :WaitForChild("TS", 5)
            :WaitForChild("BallReplicator", 5)
            :WaitForChild("BallReplicator", 5)
    end)
    if ok and mod and mod.BallReplicator then
        _br = mod.BallReplicator
    else
        _br = false
    end
    return _br
end

local function tgtOn(ch)
    if not ch or not ch.Parent then return false end
    -- 1) Highlight visual (local, instantâneo)
    if ch:FindFirstChild("Highlight") then return true end
    -- 2) Workspace attribute (replicado, rápido)
    if Utils.getWorkspace():GetAttribute("GameBallTarget") == _localUserId then
        return true
    end
    -- 3) BallReplicator.syncData (cache RAM)
    local br = _ensureBR()
    if br and br.syncData and br.syncData.HighlightTargetPlayerID == _localUserId then
        return true
    end
    -- 4) Sync.Target (último recurso, derivado do server sync)
    if Sync and Sync.Target == _localUserId then
        return true
    end
    return false
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
