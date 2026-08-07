-- [[ auto parry ]]

local AutoParry = {}

local Probe
local GameInfo
local Utils


-- tuning
local P = {
    FIRE_TIMEOUT    = 2.0,
    MIN_SPD         = 5,
    DEFLECT_R       = 8.5,
    RAD_FLOOR       = 14,
    GRACE_TIMEOUT   = 0.30,
    RES_PER_PARRY   = 0.225,
    RES_CAP         = 32,
    RES_HOLD_T      = 1.2,
    RES_DECAY_T     = 4.0,
    LEAD_CAP        = 80,
    PRE_CAP         = 30,
    LEAD_PING_FLOOR = 0.060,
    LEAD_TICK_FRAMES = 2,
}


-- state
local AP = {
    armed   = false,
    fired   = false,
    firedAt = 0,
}


local RES = {
    stack        = 0,
    decayBase    = 0,
    lastStackAt  = 0,
    lastFireBallRef = nil,
    lastFireBallAt  = 0,
}


local Sync = {
    Speed       = 0,
    RealPos     = Vector3.new(0, 0, 0),
    hasRealPos  = false,
    Target      = -999,
    lastSyncAt  = 0,
    positionAt  = 0,
    Grace       = false,  
    DeflectDir  = Vector3.new(0, 0, 0),  
}


local _localUserId    = -1
local _teleportLock   = 0
local _apBind         = 0
local _onFired        = nil


-- resilience
local function resRadiusBonus()
    return math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP)
end

local function tickResilience(t)
    if RES.stack <= 0 then return end
    local since = t - RES.lastStackAt
    if since > (P.RES_HOLD_T + P.RES_DECAY_T) then
        RES.stack, RES.decayBase = 0, 0
        return
    end
    if since > P.RES_HOLD_T then
        local frac = 1 - (since - P.RES_HOLD_T) / P.RES_DECAY_T
        RES.stack = math.max(math.floor(RES.decayBase * frac + 0.5), 0)
    end
end


-- target
local function isTargeted()
    if not _localUserId or _localUserId < 0 then return false end
    if game:GetAttribute("GameBallTarget") == _localUserId then return true end
    if Sync.Target == _localUserId then return true end
    return false
end


-- cooldown
local function getDeflectCD()
    return GameInfo.getDeflectCD()
end


-- fire
local function sendParry()
    if not Probe.fireParry(1) then return false end
    local t = Utils.now()
    local b = GameInfo.getBall()
    if b and b.Parent then
        RES.lastFireBallRef, RES.lastFireBallAt = b, t
    end
    if _onFired then pcall(_onFired, t) end
    return true
end


local _lastTargetSeen = -999

-- sync
local function onBallSync(data)
    if typeof(data) ~= "table" then return end
    local t = Utils.now()
    Sync.lastSyncAt = t
    GameInfo.applySync(data)

    if type(data.Speed) == "number" and data.Speed == data.Speed and data.Speed >= 0 then
        Sync.Speed = data.Speed
    else
        Sync.Speed = 0
    end
    if typeof(data.RealPosition) == "Vector3" then
        Sync.RealPos = data.RealPosition
        Sync.hasRealPos = true
        Sync.positionAt = t
    end
    if typeof(data.DeflectDirection) == "Vector3" then
        Sync.DeflectDir = data.DeflectDirection
    end
    if type(data.Grace) == "boolean" then
        Sync.Grace = data.Grace
    end
    if data.Teleported == true then
        _teleportLock = t + 0.20
        Utils.onTeleport()
        if AP.fired and (t - AP.firedAt) >= P.FIRE_TIMEOUT then
            AP.fired = false
        end
    end
    local newTarget = data.TargetPlayerID
    if type(newTarget) ~= "number" then newTarget = -999 end

    
    if newTarget == _lastTargetSeen then
        Sync.Target = newTarget
        return
    end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen, Sync.Target = newTarget, newTarget
    Utils.onTarget(newTarget, t)

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
end


-- heartbeat
local function bindParry(character)
    _apBind = _apBind + 1
    local bindId = _apBind
    if not (character and character.Parent) then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)
    if bindId ~= _apBind or not (hrp and hrp.Parent) then return end

    AP.fired, AP.armed = false, false
    Sync.Grace = false
    _lastTargetSeen = -999

    Utils.trackCharacter(
        Utils.getRunService().Heartbeat:Connect(function()
            if bindId ~= _apBind or not (character.Parent and hrp.Parent) then return end
            local cfg = Utils.getConfig()
            if type(cfg) ~= "table" or cfg.AutoParry ~= true then
                AP.fired = false
                return
            end
            local t = Utils.now()
            if t < _teleportLock then return end
            
            if Sync.Grace and (t - Sync.lastSyncAt) > P.GRACE_TIMEOUT then
                Sync.Grace = false
            end
            if Sync.Grace then return end
            if Utils.isClashActive() or Utils.isManualSpamActive() then return end

            tickResilience(t)

            local ball = GameInfo.getBall()
            if not (ball and ball.Parent and ball:IsA("BasePart")) then return end
            if not isTargeted() then
                AP.armed = false
                return
            end

            
            local syncFresh = (t - Sync.lastSyncAt) < 0.5
            local positionFresh = Sync.hasRealPos and (t - Sync.positionAt) < 0.5
            local spd = (syncFresh and Sync.Speed > 0)
                and Sync.Speed
                or ball.AssemblyLinearVelocity.Magnitude
            if spd < P.MIN_SPD then return end

            
            local bp
            if positionFresh then
                local av = ball.AssemblyLinearVelocity
                local direction = Sync.DeflectDir.Magnitude > 0.1 and Sync.DeflectDir.Unit
                    or (av.Magnitude > 0.1 and av.Unit or nil)
                if direction then
                    bp = Sync.RealPos + direction * (spd * (t - Sync.positionAt))
                else
                    bp = Sync.RealPos
                end
            else
                bp = ball.Position
            end

            
            local tickMs = (GameInfo.frameEMA() > 0 and GameInfo.frameEMA() * 1000) or 16.67
            local leadSec = P.LEAD_PING_FLOOR + (P.LEAD_TICK_FRAMES * tickMs / 1000)
            local leadB = math.min(spd * leadSec, P.LEAD_CAP)
            local pbStuds = math.min(GameInfo.preBufferStuds(spd), P.PRE_CAP)
            local parryRad = math.max(P.DEFLECT_R + leadB + pbStuds + resRadiusBonus(), P.RAD_FLOOR)
            local dx, dy, dz = hrp.Position.X - bp.X, hrp.Position.Y - bp.Y, hrp.Position.Z - bp.Z
            if dx*dx + dy*dy + dz*dz > parryRad * parryRad then return end

            if getDeflectCD() > 0 then return end
            if AP.fired and (t - AP.firedAt) < P.FIRE_TIMEOUT then return end
            if AP.fired then AP.fired = false end
            if AP.firedAt > Sync.lastSyncAt then return end

            if sendParry() then
                AP.fired, AP.firedAt = true, t
                
                if RES.stack == 0 or (t - RES.lastStackAt) > P.RES_HOLD_T then
                    RES.stack = 1
                else
                    RES.stack = RES.stack + 1
                end
                RES.decayBase = RES.stack
                RES.lastStackAt = t
            end
        end)
    )

    Utils.trackCharacter(
        character.AncestryChanged:Connect(function(_, parent)
            if not parent then _apBind = _apBind + 1 end
        end)
    )
end


local function resetState()
    AP.armed, AP.fired, AP.firedAt = false, false, 0
    RES.stack, RES.decayBase, RES.lastStackAt = 0, 0, 0
    RES.lastFireBallRef, RES.lastFireBallAt = nil, 0
    Sync.Speed = 0
    Sync.RealPos = Vector3.new(0, 0, 0)
    Sync.hasRealPos = false
    Sync.DeflectDir = Vector3.new(0, 0, 0)
    Sync.Target = -999
    Sync.lastSyncAt = 0
    Sync.positionAt = 0
    Sync.Grace = false
    _teleportLock = 0
    _lastTargetSeen = -999
end


-- public
function AutoParry.setup(deps)
    Probe    = deps.Probe
    GameInfo = deps.GameInfo
    Utils    = deps.Utils
    local localPlayer = Utils.getLocalPlayer()
    _localUserId = localPlayer and localPlayer.UserId or -1
end

function AutoParry.setOnFired(fn)   _onFired = type(fn) == "function" and fn or nil end
function AutoParry.fire()           return sendParry() end
function AutoParry.bindParry(ch)    bindParry(ch) end
function AutoParry.resetState()     resetState() end
function AutoParry.onBallSync(d)    onBallSync(d) end
function AutoParry.resRadiusBonus() return resRadiusBonus() end
function AutoParry.getState()       return AP end
function AutoParry.getRes()         return RES end
function AutoParry.getSync()        return Sync end
function AutoParry.getLastFireBallRef() return RES.lastFireBallRef end
function AutoParry.getLastFireBallAt()  return RES.lastFireBallAt end
function AutoParry.getP()           return P end

if _G.ExodusModules then
    _G.ExodusModules.AutoParry = AutoParry
end

return AutoParry
