-- [[ game info ]]

local GameInfo = {}

local Utils
local Players
local Workspace


local BALL_CACHE_TTL = 0.5
local NEAREST_TICK   = 0.5
local SYNC_FRESH_T   = 1.0
local LIVE_TIMP_TTL  = 0.05

local _ball, _ballAt = nil, 0
local _lastNearest   = 0
local _nearestDist   = math.huge
local _nearestAlive  = false

local _sync = {
    Speed      = 0,
    RealPos    = Vector3.new(0, 0, 0),
    hasRealPos = false,
    Target     = -999,
    lastSyncAt = 0,
    positionAt = 0,
    DeflectDir = Vector3.new(0, 0, 0),
}

local _liveTImpCache = { tImp = math.huge, bp = Vector3.new(0,0,0), spd = 0, at = 0 }


-- ball
local function getBall()
    local t = Utils.now()
    if _ball and _ball.Parent and (t - _ballAt) < BALL_CACHE_TTL then
        return _ball
    end
    local b = Workspace:FindFirstChild("GameBall", true)
    if b and b.Parent and b:IsA("BasePart") then
        _ball, _ballAt = b, t
        return b
    end
    _ball, _ballAt = nil, t
    return nil
end

local function setBall(b)
    if not (b and b.Parent and b:IsA("BasePart")) then return end
    _ball, _ballAt = b, Utils.now()
    _liveTImpCache.at = 0
end

local function clearBallRef(b)
    if b == _ball then
        _ball, _ballAt = nil, Utils.now()
        _liveTImpCache.at = 0
    end
end

local function ballSpeed(ball, t)
    if not (ball and ball.Parent and ball:IsA("BasePart")) then return 0 end
    t = type(t) == "number" and t or Utils.now()
    if (t - _sync.lastSyncAt) < SYNC_FRESH_T and _sync.Speed > 0 then
        return _sync.Speed
    end
    local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
    return (ok and typeof(av) == "Vector3") and av.Magnitude or 0
end


local function ballPos(ball, t)
    if not (ball and ball.Parent and ball:IsA("BasePart")) then return nil end
    t = type(t) == "number" and t or Utils.now()
    local positionAge = t - _sync.positionAt
    if _sync.hasRealPos and positionAge >= 0 and positionAge < SYNC_FRESH_T then
        local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
        local direction = _sync.DeflectDir.Magnitude > 0.1 and _sync.DeflectDir.Unit
            or (ok and typeof(av) == "Vector3" and av.Magnitude > 1 and av.Unit or nil)
        if direction and _sync.Speed > 0 then
            return _sync.RealPos + direction * (_sync.Speed * positionAge)
        end
        return _sync.RealPos
    end
    return ball.Position
end



-- timp
local function computeTImp(hrp, ball, t)
    if not (hrp and hrp.Parent) then return math.huge, nil, 0 end
    local bp = ballPos(ball, t)
    if not bp then return math.huge, nil, 0 end
    local spd = ballSpeed(ball, t)
    if spd < 1 then return math.huge, bp, spd end
    return (hrp.Position - bp).Magnitude / spd, bp, spd
end

local function liveTImp()
    local n = Utils.now()
    if _liveTImpCache and (n - _liveTImpCache.at) < LIVE_TIMP_TTL then
        return _liveTImpCache
    end
    local lp   = Players.LocalPlayer
    local char = lp and lp.Character
    local hr   = char and char:FindFirstChild("HumanoidRootPart")
    local ball = getBall()
    if hr and ball and ball.Parent then
        local tImp, bp, spd = computeTImp(hr, ball, n)
        _liveTImpCache = {
            tImp = tImp,
            bp   = bp,
            spd  = spd,
            at   = n,
        }
    else
        _liveTImpCache = { tImp = math.huge, bp = Vector3.new(0,0,0), spd = 0, at = n }
    end
    return _liveTImpCache
end


-- target
local function isTargeted(lastTarget)
    local localPlayer = Players.LocalPlayer
    if not localPlayer then return false end
    local uid = localPlayer.UserId
    return _sync.Target == uid
        or lastTarget == uid
        or Workspace:GetAttribute("GameBallTarget") == uid
end

local function nearestPlayerAlive()
    local t = Utils.now()
    if (t - _lastNearest) < NEAREST_TICK then
        return _nearestDist, _nearestAlive
    end
    _lastNearest = t
    local lp   = Players.LocalPlayer
    local char = lp and lp.Character
    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP then
        _nearestDist, _nearestAlive = math.huge, false
        return _nearestDist, _nearestAlive
    end
    local myPos = myHRP.Position
    local curDist, curAlive = math.huge, false
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            local pChar = p.Character
            if pChar then
                local php = pChar:FindFirstChild("HumanoidRootPart")
                if php then
                    local hum = pChar:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        local d = (myPos - php.Position).Magnitude
                        if d < curDist then curDist, curAlive = d, true end
                    end
                end
            end
        end
    end
    _nearestDist, _nearestAlive = curDist, curAlive
    return _nearestDist, _nearestAlive
end


-- sync
local function applySync(d)
    if typeof(d) ~= "table" then return end
    local t = Utils.now()
    if type(d.Speed) == "number" and d.Speed >= 0 then _sync.Speed = d.Speed end
    if typeof(d.RealPosition) == "Vector3" then
        _sync.RealPos = d.RealPosition
        _sync.hasRealPos = true
        _sync.positionAt = t
    end
    if typeof(d.DeflectDirection) == "Vector3" then
        _sync.DeflectDir = d.DeflectDirection
    end
    if type(d.TargetPlayerID) == "number" then _sync.Target = d.TargetPlayerID end
    _sync.lastSyncAt = t
    _liveTImpCache.at = 0
end


local _deflectAbilityRef, _deflectAbilityTried, _deflectAbilityLastCheck = nil, false, 0

-- ability cd
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
        if not ts then return end
        local bm = ts:FindFirstChild("BindableManager")
        if not bm then return end
        local ok, BM = pcall(require, bm)
        if not ok or not BM or not BM.GetFunction then return end
        local getFn = BM:GetFunction("AbilityManager::GetAbility")
        if not getFn then return end
        for _, key in ipairs({"Deflect", "Block"}) do
            local ok2, ref = pcall(function() return getFn:Invoke(key) end)
            if ok2 and ref and type(ref.Cooldown) == "number" and type(ref.SetCooldown) == "function" then
                _deflectAbilityRef = ref
                return
            end
        end
    end)
    return _deflectAbilityRef
end

local function getDeflectCD()
    local ref = _ensureDeflectAbility()
    if not ref then return 0 end
    local ok, v = pcall(function() return ref.Cooldown end)
    return (ok and type(v) == "number") and v or 0
end


-- watcher
local function installBallWatcher(trackFn)
    if type(trackFn) ~= "function" then return false end
    local gameFolder    = Workspace:WaitForChild("Game", 30)
    local ballWatcher   = gameFolder and gameFolder:FindFirstChild("Ball")
    if not ballWatcher then return false end
    trackFn(ballWatcher.ChildAdded:Connect(function(c)
        if c.Name == "GameBall" and c:IsA("BasePart") then setBall(c) end
    end))
    trackFn(ballWatcher.ChildRemoved:Connect(clearBallRef))
    local existing = ballWatcher:FindFirstChild("GameBall")
    if existing and existing:IsA("BasePart") then setBall(existing) end
    return true
end


-- public
function GameInfo.setup(deps)
    Utils     = deps.Utils
    Players   = Utils.getPlayers()
    Workspace = game:GetService("Workspace")
end

function GameInfo.getBall()          return getBall() end
function GameInfo.ballSpeed(b, t)    return ballSpeed(b, t) end
function GameInfo.ballPos(b, t)      return ballPos(b, t) end
function GameInfo.nearestPlayerAlive() return nearestPlayerAlive() end
function GameInfo.liveTImp()         return liveTImp() end
function GameInfo.computeTImp(hr, b, t) return computeTImp(hr, b, t) end
function GameInfo.isTargeted(lt)     return isTargeted(lt) end
function GameInfo.applySync(d)       applySync(d) end
function GameInfo.syncTarget()       return _sync.Target end
function GameInfo.syncLastAt()       return _sync.lastSyncAt end
function GameInfo.syncSpeed()        return _sync.Speed end
function GameInfo.syncRealPos()      return _sync.RealPos end
function GameInfo.installBallWatcher(fn) return installBallWatcher(fn) end
function GameInfo.getDeflectCD()     return getDeflectCD() end

if _G.ExodusModules then
    _G.ExodusModules.GameInfo = GameInfo
end

return GameInfo
