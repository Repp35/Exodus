--[[ Probe ]]

local Probe = {}

-- services
local Replicated = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- state
local TSFolder, Remotes, GenRemotes, abilFolder = nil, nil, nil, nil
local Deflect = nil
local parryR, parryMode, parryInit = nil, nil, false
local _buf1, _buf2 = nil, nil
local _warnLast, _warnGap = 0, 5
local _now = os.clock

-- safeReq
local function safeReq(m)
    if not (m and m:IsA("ModuleScript")) then
        return nil
    end
    local ok, r = pcall(require, m)
    return ok and r or nil
end

-- refreshRefs
local function refreshRefs()
    if not (TSFolder and TSFolder.Parent) then
        TSFolder = Replicated:FindFirstChild("TS")
        GenRemotes = TSFolder and TSFolder:FindFirstChild("GeneratedNetworkRemotes")
        abilFolder = TSFolder and TSFolder:FindFirstChild("Abilities")
        if abilFolder then
            local mod = safeReq(abilFolder:FindFirstChild("DeflectAbility")) or {}
            Deflect = (type(mod) == "table" and mod.DeflectAbility) or mod
            if type(Deflect) ~= "table" then
                Deflect = nil
            end
        end
    end
    if not (Remotes and Remotes.Parent) then
        Remotes = Replicated:FindFirstChild("Remotes")
    end
end

-- _initBufs
local function _initBufs()
    if type(buffer) ~= "table" then
        return
    end
    if type(buffer.fromstring) == "function" then
        _buf1 = buffer.fromstring("\1")
        _buf2 = buffer.fromstring("\2")
    elseif type(buffer.create) == "function" and type(buffer.writeu8) == "function" then
        _buf1 = buffer.create(1)
        buffer.writeu8(_buf1, 0, 1)
        _buf2 = buffer.create(1)
        buffer.writeu8(_buf2, 0, 2)
    end
end
_initBufs()

-- makeBuf
local function makeBuf(flag)
    return flag == 2 and _buf2 or _buf1
end

-- validRemote
local function validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

-- getGlobal
local function getGlobal()
    if type(getfenv) ~= "function" or type(Deflect) ~= "table" then
        return _G
    end
    local candidates = {"Deflect", "OnClientCreate", "constructor"}
    for _, name in ipairs(candidates) do
        local fn = Deflect[name]
        if type(fn) == "function" then
            local ok, env = pcall(getfenv, fn)
            if ok and type(env) == "table" then
                local g = rawget(env, "_G")
                return (type(g) == "table" and g or env)
            end
        end
    end
    return _G
end

-- setGlobal
local function setGlobal(k, v)
    local g = getGlobal()
    if type(g) == "table" then
        rawset(g, k, v)
    end
end

-- cacheRemote
local function cacheRemote(r, mode)
    if not validRemote(r) then
        return nil
    end
    if r.Name == "RE_1" then
        mode = "event"
    end
    parryR, parryMode = r, mode
    if mode == "buffer" then
        setGlobal("did", r)
    end
    return r, mode
end

-- resolveRemote
local function resolveRemote()
    refreshRefs()
    if parryR and (not parryR.Parent or not parryR:IsA("RemoteEvent")) then
        parryR, parryMode, parryInit = nil, nil, false
    end
    if validRemote(parryR) then
        return parryR, parryMode
    end
    local did = rawget(getGlobal(), "did")
    if validRemote(did) then
        return cacheRemote(did, "buffer")
    end
    if Remotes then
        local r = Remotes:FindFirstChild("pr_" .. tostring(Players.LocalPlayer.UserId))
        if validRemote(r) then
            return cacheRemote(r, "buffer")
        end
    end
    if GenRemotes then
        local r = GenRemotes:FindFirstChild("RE_1")
        if validRemote(r) then
            return cacheRemote(r, "event")
        end
    end
    return nil
end

-- probeNamedRemoteEvents
local function probeNamedRemoteEvents()
    local pools = {
        {Remotes, {"did", "RE_Deflect", "Deflect"}},
        {GenRemotes, {"RE_1", "RE_Deflect"}},
        {TSFolder, {"Deflect", "RE_Deflect"}}
    }
    for _, pool in ipairs(pools) do
        local folder, names = pool[1], pool[2]
        if folder then
            for _, n in ipairs(names) do
                if type(n) == "string" then
                    local r = folder:FindFirstChild(n)
                    if validRemote(r) then
                        return cacheRemote(r, (r.Name == "RE_1") and "event" or "buffer")
                    end
                end
            end
        end
    end
    return nil
end

-- initParry
local function initParry()
    if parryInit then
        return true
    end
    local r, m = resolveRemote()
    if not r then
        r, m = probeNamedRemoteEvents()
    end
    if not r then
        return false
    end
    if m == "event" then
        parryInit = true
        return true
    end
    local p = makeBuf(2)
    if not p then
        return false
    end
    parryInit = pcall(r.FireServer, r, p)
    return parryInit
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

-- fireParry
local function fireParry(r, m, flag)
    if not validRemote(r) then
        return false
    end
    if m == "event" then
        local ok, err = pcall(r.FireServer, r)
        if not ok then
            phantomWarn("fireParry.event", err)
        end
        return ok
    end
    local p = makeBuf(flag or 1)
    if not p then
        return false
    end
    local initOk, initialized = pcall(initParry)
    if not initOk or not initialized then
        phantomWarn("fireParry.init", "inicialização falhou")
        return false
    end
    local ok, err = pcall(r.FireServer, r, p)
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

-- tryConnectResilience
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
    if not (parryR and parryR:IsA("RemoteEvent") and parryR.Parent) then
        parryR, parryMode, parryInit = nil, nil, false
        local remote = resolveRemote()
        if not remote then
            remote = probeNamedRemoteEvents()
        end
        if remote then
            initParry()
        end
    end
    refreshRefs()
end

-- public api
function Probe.refreshRefs()
    refreshRefs()
end
function Probe.resolveRemote()
    return resolveRemote()
end
function Probe.probeNamed()
    return probeNamedRemoteEvents()
end
function Probe.initParry()
    return initParry()
end
function Probe.fireParry(flag)
    return fireParry(parryR, parryMode, flag or 1)
end
function Probe.getRemote()
    return parryR, parryMode
end

function Probe.invalidate()
    parryR, parryMode, parryInit = nil, nil, false
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
    if validRemote(parryR) and (t - (lastResolveAt or 0)) <= (maxAge or 3.0) then
        return parryR, parryMode
    end
    local r, m = resolveRemote()
    return r, m
end

return Probe
