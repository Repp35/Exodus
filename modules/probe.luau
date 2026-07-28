--[[ Probe v2 ]]

local Probe = {}

-- services
local Replicated = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- state
local TSFolder, Remotes = nil, nil
local ReqDef = nil
local _warnLast, _warnGap = 0, 5
local _now = os.clock

-- refreshRefs
local function refreshRefs()
    if not (TSFolder and TSFolder.Parent) then
        TSFolder = Replicated:FindFirstChild("TS")
    end
    if not (Remotes and Remotes.Parent) then
        Remotes = Replicated:FindFirstChild("Remotes")
    end
    if Remotes and (not ReqDef or not ReqDef.Parent) then
        ReqDef = Remotes:FindFirstChild("ReqDef")
    end
end

-- validRemote
local function validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

-- resolveReqDef
local function resolveReqDef()
    refreshRefs()
    if validRemote(ReqDef) then
        return ReqDef
    end
    ReqDef = nil
    if Remotes then
        ReqDef = Remotes:FindFirstChild("ReqDef")
        if validRemote(ReqDef) then
            return ReqDef
        end
    end
    return nil
end

-- phantomWarn
local function phantomWarn(tag, msg)
    local t = _now()
    if (t - _warnLast) < _warnGap then
        return
    end
    _warnLast = t
    warn(("[phantom_logic] %s: %s"):format(tag, tostring(msg)))
end

-- fireParryImpl
-- Nota: payload vazio. Se o server esperar args, ajuste aqui.
local function fireParryImpl(...)
    local r = resolveReqDef()
    if not r then
        phantomWarn("fireParry", "ReqDef não encontrado")
        return false
    end
    local ok, err = pcall(r.FireServer, r, ...)
    if not ok then
        phantomWarn("fireParry.fire", err)
    end
    return ok
end

-- ball sync state
local _ballSync, _ballSyncConn = nil, nil

-- connectBallSync
local function connectBallSync(track)
    refreshRefs()
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")
    if not (candidate and candidate:IsA("RemoteEvent")) then
        return false
    end
    if candidate == _ballSync and _ballSyncConn and _ballSyncConn.Connected then
        return true
    end
    if _ballSyncConn then
        pcall(_ballSyncConn.Disconnect, _ballSyncConn)
    end
    _ballSync = candidate
    return true
end

-- bindBallSync
local function bindBallSync(handler, track)
    if not connectBallSync(track) then
        return false
    end
    if _ballSyncConn then
        pcall(_ballSyncConn.Disconnect, _ballSyncConn)
    end
    _ballSyncConn = track(_ballSync.OnClientEvent:Connect(handler))
    return true
end

-- tryConnectResilience (mantido igual)
local function tryConnectResilience(track)
    track(
        workspace.DescendantAdded:Connect(
            function(d)
                if not _G.PhantomState or not _G.PhantomState.active then
                    return
                end
                if d.Name == "GameBall" and d:IsA("BasePart") then
                    return
                end
                if d.Name ~= "HitboxGrow" or not d:IsA("BasePart") then
                    return
                end
                local t = _now()
                local res = _G.PhantomResilience
                if not res then
                    return
                end
                if (t - res.lastFireBallAt) > 0.5 then
                    return
                end
                if not (res.lastFireBallRef and res.lastFireBallRef.Parent) then
                    return
                end
                if (t - res.lastHitboxAt) < 0.4 then
                    return
                end
                local dp = d.Position
                if typeof(dp) ~= "Vector3" then
                    return
                end
                if (res.lastFireBallRef.Position - dp).Magnitude > 12 then
                    return
                end
                res.lastHitboxAt, res.lastStackAt = t, t
                res.stack = res.stack + 1
                local maxStack = math.floor((32 - 0) / 0.225)
                if res.stack > maxStack then
                    res.stack = maxStack
                end
            end
        )
    )
end

-- revalidate
local function revalidate()
    if not (ReqDef and ReqDef:IsA("RemoteEvent") and ReqDef.Parent) then
        ReqDef = nil
        resolveReqDef()
    end
    refreshRefs()
end

-- public api
function Probe.refreshRefs()
    refreshRefs()
end

function Probe.resolveRemote()
    return resolveReqDef()
end

function Probe.fireParry(...)
    return fireParryImpl(...)
end

function Probe.getRemote()
    return ReqDef
end

function Probe.invalidate()
    ReqDef = nil
end

function Probe.bindBallSync(handler, track)
    return bindBallSync(handler, track)
end

function Probe.connectBallSync(track)
    return connectBallSync(track)
end

function Probe.revalidate()
    revalidate()
end

function Probe.tryConnectResilience(track)
    tryConnectResilience(track)
end

function Probe.resolveIfStale(lastResolveAt, maxAge)
    local t = _now()
    if validRemote(ReqDef) and (t - (lastResolveAt or 0)) <= (maxAge or 3.0) then
        return ReqDef
    end
    return resolveReqDef()
end

return Probe
