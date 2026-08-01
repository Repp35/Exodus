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

-- hook state
local _hooked = false
local _oldNamecall, _oldIndex = nil, nil
local _hookEnabled = true

local DEFAULT_REMOTE_PATH = nil -- ex: "ReplicatedStorage.Remotes.pr_123456789"
local DEFAULT_MODE = "buffer"   -- "buffer" ou "event"

-- config persistida (opcional, sobrescreve se existir)
local CONFIG_PATH = "probe_config.json"
local _savedRemote = nil
local _resolvedOnce = false

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

local function makeBuf(flag)
    return flag == 2 and _buf2 or _buf1
end

local function validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

local function phantomWarn(tag, msg)
    local t = _now()
    if (t - _warnLast) < _warnGap then
        return
    end
    _warnLast = t
    warn(("[phantom_logic] %s: %s"):format(tag, tostring(msg)))
end

-- ============================================================
-- PERSISTÊNCIA: salva qual remote + como usar
-- ============================================================
local function getFullPath(inst)
    if not (typeof(inst) == "Instance" and inst.Parent) then
        return inst and inst.Name or "?"
    end
    local parts = { inst.Name }
    local cur = inst.Parent
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(parts, ".")
end

local function findInstanceByPath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local cur = game
    for seg in string.gmatch(path, "[^.]+") do
        if not cur then
            return nil
        end
        cur = cur:FindFirstChild(seg)
    end
    if validRemote(cur) then
        return cur
    end
    return nil
end

local function saveConfig()
    if not (parryR and validRemote(parryR)) then
        return false
    end
    local ok, http = pcall(function()
        local s = game:GetService("HttpService")
        return s and s.JSONEncode and s.JSONDecode
    end)
    if not ok or not http then
        return false
    end
    local cfg = {
        name = parryR.Name,
        path = getFullPath(parryR),
        class = parryR.ClassName,
        mode = parryMode or "buffer",
        buffer = (parryMode == "buffer") and "\\1" or nil,
        captured_at = os.time(),
        usage = string.format('%s:FireServer(buffer.fromstring("\\1"))', getFullPath(parryR)),
    }
    local ok2, json = pcall(http.JSONEncode, http, cfg)
    if not ok2 then
        return false
    end
    pcall(function()
        writefile(CONFIG_PATH, json)
    end)
    pcall(function()
        print(("[probe] remote salvo em %s -> %s"):format(CONFIG_PATH, getFullPath(parryR)))
    end)
    return true
end

local function loadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return nil
    end
    if not isfile(CONFIG_PATH) then
        return nil
    end
    local ok, content = pcall(readfile, CONFIG_PATH)
    if not ok or type(content) ~= "string" then
        return nil
    end
    local ok2, http = pcall(function()
        return game:GetService("HttpService")
    end)
    if not ok2 then
        return nil
    end
    local ok3, data = pcall(http.JSONDecode, http, content)
    if not ok3 or type(data) ~= "table" then
        return nil
    end
    return data
end

-- ============================================================
-- CACHE do remote (passo do hook)
-- ============================================================
local function cacheRemote(r, mode)
    if not validRemote(r) then
        return nil
    end
    local changed = (parryR ~= r) or (parryMode ~= mode)
    parryR, parryMode = r, mode
    parryInit = false
    if changed then
        saveConfig()
    end
    return r, mode
end

-- hook install (mesmo esquema do invisible)
local function installHook()
    if _hooked then
        return true
    end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" or type(checkcaller) ~= "function" then
        return false
    end
    local ok, err = pcall(function()
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if _hookEnabled and not checkcaller() and (method == "FireServer" or method == "fireServer") then
                local args = { ... }
                local isPayload = false
                local a1 = args[1]
                if a1 then
                    local t = typeof(a1)
                    if t == "buffer" then
                        isPayload = true
                    elseif t == "string" and string.find(a1, "\1") then
                        isPayload = true
                    end
                end
                if isPayload or (typeof(self) == "Instance" and self:IsA("RemoteEvent") and self.Name == "RemoteEvent") then
                    cacheRemote(self, "buffer")
                end
            end
            return _oldNamecall(self, ...)
        end)

        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if _hookEnabled and not checkcaller() and (key == "FireServer" or key == "fireServer")
                and typeof(self) == "Instance" and self:IsA("RemoteEvent") then
                if self.Name == "RemoteEvent" or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                    task.spawn(function() cacheRemote(self, "buffer") end)
                end
            end
            return _oldIndex(self, key)
        end)
    end)
    if ok then
        _hooked = true
    else
        phantomWarn("hook.install", err)
    end
    return _hooked
end

-- resolve: JSON (persiste) > hardcode (fallback máximo) > hook
local function resolveFromConfig()
    if _resolvedOnce and validRemote(parryR) then
        return parryR, parryMode
    end

    -- 1) JSON persiste entre sessões (vem primeiro — se já parryou antes, usa isso)
    local cfg = loadConfig()
    if cfg and cfg.path then
        local inst = findInstanceByPath(cfg.path)
        if inst then
            parryR, parryMode = inst, cfg.mode or "buffer"
            parryInit = false
            _savedRemote = cfg
            _resolvedOnce = true
            return parryR, parryMode
        end
    end

    -- 2) hardcode (só pra primeira vez, antes de qualquer parry e antes de ter JSON)
    if type(DEFAULT_REMOTE_PATH) == "string" and DEFAULT_REMOTE_PATH ~= "" then
        local inst = findInstanceByPath(DEFAULT_REMOTE_PATH)
        if inst then
            parryR, parryMode = inst, DEFAULT_MODE or "buffer"
            parryInit = false
            _resolvedOnce = true
            return parryR, parryMode
        end
    end

    return nil
end

local function resolveRemote()
    refreshRefs()

    if parryR and (not parryR.Parent or not parryR:IsA("RemoteEvent")) then
        parryR, parryMode, parryInit = nil, nil, false
    end
    if validRemote(parryR) then
        return parryR, parryMode
    end

    -- 1) config persistida (fallback máximo)
    local r, m = resolveFromConfig()
    if r then
        return r, m
    end

    -- 2) fallback por nome
    if Remotes then
        local rem = Remotes:FindFirstChild("pr_" .. tostring(Players.LocalPlayer.UserId))
        if validRemote(rem) then
            return cacheRemote(rem, "buffer")
        end
    end
    if GenRemotes then
        local rem = GenRemotes:FindFirstChild("RE_1")
        if validRemote(rem) then
            return cacheRemote(rem, "event")
        end
    end

    -- 3) ativa hook pra pegar quando o usuário (ou outro) der parry
    installHook()
    return nil
end

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
    local p
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        p = buffer.fromstring(flag == 2 and "\2" or "\1")
    else
        p = makeBuf(flag or 1)
    end
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

-- ball sync
local _ballSync, _ballSyncConn = nil, nil
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

local function revalidate()
    if not (parryR and parryR:IsA("RemoteEvent") and parryR.Parent) then
        parryR, parryMode, parryInit = nil, nil, false
        _resolvedOnce = false
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

-- já instala hook e tenta config logo no require
installHook()
resolveFromConfig()

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
    _resolvedOnce = false
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

function Probe.setHookEnabled(v)
    _hookEnabled = (v ~= false)
end
function Probe.isHookInstalled()
    return _hooked
end
function Probe.getSavedConfig()
    return _savedRemote
end
function Probe.getConfigPath()
    return CONFIG_PATH
end

return Probe
