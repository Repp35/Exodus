--[[ probe ]]

-- módulo
local Probe = {}

-- dependências
local Utils

-- serviços
local Players
local ReplicatedStorage

-- estado
local TSFolder, RemotesFolder, GeneratedRemotesFolder = nil, nil, nil
local parryRemote, parryMode, parryInitialized = nil, nil, false
local _buf1, _buf2 = nil, nil
local _hooked = false
local _oldNamecall, _oldIndex = nil, nil
local _hookEnabled = true

-- buffers
local function initBuffers()
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

local function getBuffer(flag)
    return flag == 2 and _buf2 or _buf1
end

-- validação
local function isValidRemote(remote)
    return typeof(remote) == "Instance" and remote.Parent ~= nil and remote:IsA("RemoteEvent")
end

-- referências de serviço
local function refreshServiceRefs()
    TSFolder = ReplicatedStorage:FindFirstChild("TS")
    RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
    GeneratedRemotesFolder = TSFolder and TSFolder:FindFirstChild("GeneratedNetworkRemotes")
end

-- hook de metamétodo
local function installMetamethodHook()
    if _hooked then
        return true
    end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" or type(checkcaller) ~= "function" then
        return false
    end
    local ok, err =
        pcall(
        function()
            _oldNamecall =
                hookmetamethod(
                game,
                "__namecall",
                function(self, ...)
                    local method = getnamecallmethod()
                    if _hookEnabled and not checkcaller() and (method == "FireServer" or method == "fireServer") then
                        local args = {...}
                        local a1 = args[1]
                        local t = typeof(a1)
                        local isPayload = (t == "buffer") or (t == "string" and pcall(string.find, a1, "\1", 1, true))
                        if
                            isPayload or
                                (typeof(self) == "Instance" and self:IsA("RemoteEvent") and self.Name == "RemoteEvent")
                         then
                            parryRemote, parryMode = self, "buffer"
                            parryInitialized = false
                        end
                    end
                    return _oldNamecall(self, ...)
                end
            )

            _oldIndex =
                hookmetamethod(
                game,
                "__index",
                function(self, key)
                    if
                        _hookEnabled and not checkcaller() and (key == "FireServer" or key == "fireServer") and
                            typeof(self) == "Instance" and
                            self:IsA("RemoteEvent")
                     then
                        if
                            self.Name == "RemoteEvent" or
                                (self.Parent and type(self.Parent.Name) == "string" and
                                    string.find(self.Parent.Name, "Remote"))
                         then
                            task.spawn(
                                function()
                                    parryRemote, parryMode = self, "buffer"
                                    parryInitialized = false
                                end
                            )
                        end
                    end
                    return _oldIndex(self, key)
                end
            )
        end
    )
    if ok then
        _hooked = true
    else
        warn(string.format("[Probe] Falha ao instalar hook: %s", tostring(err)))
    end
    return _hooked
end

-- resolução de remote
local function resolveParryRemote()
    refreshServiceRefs()

    if parryRemote and (not parryRemote.Parent or not parryRemote:IsA("RemoteEvent")) then
        parryRemote, parryMode, parryInitialized = nil, nil, false
    end
    if isValidRemote(parryRemote) then
        return parryRemote, parryMode
    end

    -- tenta remotes conhecidos
    if RemotesFolder then
        local rem = RemotesFolder:FindFirstChild("pr_" .. tostring(Players.LocalPlayer.UserId))
        if isValidRemote(rem) then
            parryRemote, parryMode = rem, "buffer"
            parryInitialized = false
            return parryRemote, parryMode
        end
    end
    if GeneratedRemotesFolder then
        local rem = GeneratedRemotesFolder:FindFirstChild("RE_1")
        if isValidRemote(rem) then
            parryRemote, parryMode = rem, "event"
            parryInitialized = false
            return parryRemote, parryMode
        end
    end

    -- tenta remotes nomeados
    local pools = {
        {RemotesFolder, {"did", "RE_Deflect", "Deflect"}},
        {GeneratedRemotesFolder, {"RE_1", "RE_Deflect"}},
        {TSFolder, {"Deflect", "RE_Deflect"}}
    }
    for _, pool in ipairs(pools) do
        local folder, names = pool[1], pool[2]
        if folder then
            for _, name in ipairs(names) do
                if type(name) == "string" then
                    local remote = folder:FindFirstChild(name)
                    if isValidRemote(remote) then
                        parryRemote, parryMode = remote, (remote.Name == "RE_1") and "event" or "buffer"
                        parryInitialized = false
                        return parryRemote, parryMode
                    end
                end
            end
        end
    end

    installMetamethodHook()
    return nil
end

-- inicialização do parry
local function initializeParry()
    if parryInitialized then
        return true
    end
    local remote, mode = resolveParryRemote()
    if not remote then
        return false
    end
    if mode == "event" then
        parryInitialized = true
        return true
    end
    local buf = getBuffer(2)
    if not buf then
        return false
    end
    parryInitialized = pcall(remote.FireServer, remote, buf)
    return parryInitialized
end

-- disparo do parry
local function fireParry(flag)
    local remote, mode = Probe.getRemote()
    if not isValidRemote(remote) then
        return false
    end
    if mode == "event" then
        local ok, err = pcall(remote.FireServer, remote)
        if not ok then
            warn(string.format("[Probe] Falha ao disparar evento: %s", tostring(err)))
        end
        return ok
    end
    local buf = getBuffer(flag or 1)
    if not buf then
        return false
    end
    local initOk, initialized = pcall(initializeParry)
    if not initOk or not initialized then
        warn("[Probe] Inicialização do parry falhou.")
        return false
    end
    local ok, err = pcall(remote.FireServer, remote, buf)
    if not ok then
        warn(string.format("[Probe] Falha ao disparar remote: %s", tostring(err)))
    end
    return ok
end

-- sincronização da bola
local _ballSyncRemote, _ballSyncConnection = nil, nil

local function connectBallSyncRemote()
    refreshServiceRefs()
    local candidate = RemotesFolder and RemotesFolder:FindFirstChild("BallSyncData")
    if not (candidate and candidate:IsA("RemoteEvent")) then
        return false
    end
    if candidate == _ballSyncRemote and _ballSyncConnection and _ballSyncConnection.Connected then
        return true
    end
    if _ballSyncConnection then
        pcall(_ballSyncConnection.Disconnect, _ballSyncConnection)
    end
    _ballSyncRemote = candidate
    return true
end

-- setup
function Probe.setup(deps)
    Utils = deps.Utils
    Players = Utils.getPlayers()
    ReplicatedStorage = Utils.getReplicatedStorage()
    initBuffers()
    installMetamethodHook()
    resolveParryRemote()
end

-- api pública
function Probe.refreshRefs()
    refreshServiceRefs()
end

function Probe.resolveRemote()
    return resolveParryRemote()
end

function Probe.initParry()
    return initializeParry()
end

function Probe.fireParry(flag)
    return fireParry(flag)
end

function Probe.getRemote()
    return parryRemote, parryMode
end

function Probe.invalidateRemote()
    parryRemote, parryMode, parryInitialized = nil, nil, false
end

function Probe.bindBallSync(handler, trackFn)
    if not connectBallSyncRemote() then
        return false
    end
    if _ballSyncConnection then
        pcall(_ballSyncConnection.Disconnect, _ballSyncConnection)
    end
    _ballSyncConnection = trackFn(_ballSyncRemote.OnClientEvent:Connect(handler))
    return true
end

function Probe.connectBallSyncRemote()
    return connectBallSyncRemote()
end

function Probe.setHookEnabled(value)
    _hookEnabled = (value ~= false)
end

function Probe.isHookInstalled()
    return _hooked
end

if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

return Probe
