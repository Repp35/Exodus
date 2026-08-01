--[[ probe ]]

-- módulo
local Probe = {}

-- dependências
local Utils

-- serviços
local Replicated = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- estado
local TSFolder, Remotes, GenRemotes, abilFolder = nil, nil, nil, nil
local Deflect = nil
local parryR, parryMode, parryInit = nil, nil, false
local _buf1, _buf2 = nil, nil
local _warnLast, _warnGap = 0, 5
local _now = os.clock

local _hooked = false
local _oldNamecall, _oldIndex = nil, nil
local _hookEnabled = true

local DEFAULT_REMOTE_PATH = nil
local DEFAULT_MODE = "buffer"

local CONFIG_FOLDER = "PhantomLogic"
local CONFIG_PATH = CONFIG_FOLDER .. "/probe_config.json"
local _savedRemote = nil
local _resolvedOnce = false

-- buffers
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

local function makeBuf(flag)
    return flag == 2 and _buf2 or _buf1
end

-- validação
local function validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

-- referências
local function refreshRefs()
    if not (TSFolder and TSFolder.Parent) then
        TSFolder = Replicated:FindFirstChild("TS")
        GenRemotes = TSFolder and TSFolder:FindFirstChild("GeneratedNetworkRemotes")
        abilFolder = TSFolder and TSFolder:FindFirstChild("Abilities")
    end
    if not (Remotes and Remotes.Parent) then
        Remotes = Replicated:FindFirstChild("Remotes")
    end
end

-- path helpers
local function getFullPath(inst)
    if not (typeof(inst) == "Instance" and inst.Parent) then
        return inst and inst.Name or "?"
    end
    local parts = {inst.Name}
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

-- config persist
local function saveConfig()
    if not (parryR and validRemote(parryR)) then
        return false
    end
    local ok, http = pcall(function()
        return game:GetService("HttpService")
    end)
    if not ok or not http then
        return false
    end
    local cfg = {
        name = parryR.Name,
        path = getFullPath(parryR),
        class = parryR.ClassName,
        mode = parryMode or "buffer",
        captured_at = os.time()
    }
    local ok2, json = pcall(http.JSONEncode, http, cfg)
    if not ok2 then
        return false
    end
    pcall(function()
        if type(makefolder) == "function" and type(isfolder) == "function" then
            if not isfolder(CONFIG_FOLDER) then
                makefolder(CONFIG_FOLDER)
            end
        end
        if type(writefile) == "function" then
            writefile(CONFIG_PATH, json)
        end
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

-- cache / hook
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

local function installHook()
    if _hooked then
        return true
    end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" or type(checkcaller) ~= "function" then
        return false
    end
    local ok = pcall(function()
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local args = {...}
            if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                local isPayload = false
                if args[1] then
                    if typeof(args[1]) == "buffer" or (typeof(args[1]) == "string" and string.find(args[1], "\x01")) then
                        isPayload = true
                    end
                end
                if isPayload or self.Name == "RemoteEvent" then
                    cacheRemote(self, "buffer")
                end
            end
            return _oldNamecall(self, ...)
        end)

        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if not checkcaller() and (key == "FireServer" or key == "fireServer") and typeof(self) == "Instance" and self:IsA("RemoteEvent") then
                if self.Name == "RemoteEvent" or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                    task.spawn(function() cacheRemote(self, "buffer") end)
                end
            end
            return _oldIndex(self, key)
        end)
    end)
    if ok then
        _hooked = true
    end
    return _hooked
end

-- resolve
local function resolveFromConfig()
    if _resolvedOnce and validRemote(parryR) then
        return parryR, parryMode
    end
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
    local r, m = resolveFromConfig()
    if r then
        return r, m
    end
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

-- setup
function Probe.setup(deps)
    Utils = deps.Utils
    _initBufs()
    installHook()
    resolveRemote()
end

-- api pública
function Probe.refreshRefs()
    refreshRefs()
end

function Probe.resolveRemote()
    return resolveRemote()
end

function Probe.initParry()
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

function Probe.fireParry(flag)
    local function attempt()
        local r, m = resolveRemote()
        if not validRemote(r) then
            return false
        end
        if m == "event" then
            local ok, err = pcall(r.FireServer, r)
            if not ok then
                warn(("[phantom_logic] fireParry.event fail: %s"):format(tostring(err)))
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
        local initOk, initialized = pcall(Probe.initParry)
        if not initOk or not initialized then
            return false
        end
        local ok, err = pcall(r.FireServer, r, p)
        if not ok then
            warn(("[phantom_logic] fireParry.fire fail: %s"):format(tostring(err)))
        end
        return ok
    end

    if attempt() then
        return true
    end
    Probe.invalidateRemote()
    return attempt()
end

function Probe.getRemote()
    return parryR, parryMode
end

function Probe.invalidateRemote()
    parryR, parryMode, parryInit = nil, nil, false
end

-- alias usado pelo init pra revalidar
function Probe.invalidate()
    parryR, parryMode, parryInit = nil, nil, false
end

-- alias usado pelo init pra varrer pools nomeados (did/RE_Deflect/Deflect)
function Probe.probeNamed()
    return probeNamedRemoteEvents()
end

function Probe.bindBallSync(handler, track)
    refreshRefs()
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")
    if not (candidate and candidate:IsA("RemoteEvent")) then
        return false
    end
    track(candidate.OnClientEvent:Connect(handler))
    return true
end

-- Registra no estado global para compatibilidade com executores
if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

return Probe
