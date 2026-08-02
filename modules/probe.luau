--[[ probe ]]

-- state
local parryR, parryMode, parryInit = nil, nil, false
local _explicitlySet = false
local _buf1, _buf2 = nil, nil
local _hooked = false
local _oldNamecall = nil

-- config
local CONFIG_FOLDER = "PhantomLogic"
local CONFIG_PATH = CONFIG_FOLDER .. "/probe_config.json"
local HISTORY_FOLDER = CONFIG_FOLDER .. "/history"
local HISTORY_PREFIX = "remote_"

-- utils
local Utils
local _now = os.clock
local _lastLoadAt = 0
local LOAD_COOLDOWN = 0.5

-- init bufs
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

local function validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

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

local function getAncestry(inst)
    local out = {}
    local cur = inst.Parent
    while cur and cur ~= game do
        table.insert(out, 1, cur.Name .. " (" .. cur.ClassName .. ")")
        cur = cur.Parent
    end
    return out
end

local function getServerFingerprint()
    local info = {}
    pcall(
        function()
            info.placeId = game.PlaceId
            info.jobId = game.JobId
            info.universeId = game.GameId
        end
    )
    local Players = game:GetService("Players")
    pcall(
        function()
            info.userId = Players.LocalPlayer and Players.LocalPlayer.UserId
        end
    )
    pcall(
        function()
            local gs = game:GetService("GuiService")
            if gs and type(gs.GetGameGenre) == "function" then
                info.genre = gs:GetGameGenre()
            end
        end
    )
    return info
end

-- persist
local function saveConfig()
    if not (parryR and validRemote(parryR)) then
        return false
    end
    local ok, http =
        pcall(
        function()
            return game:GetService("HttpService")
        end
    )
    if not ok or not http then
        return false
    end
    local cfg = {
        name = parryR.Name,
        path = getFullPath(parryR),
        fullname = parryR:GetFullName(),
        ancestry = getAncestry(parryR),
        mode = parryMode or "buffer",
        server = getServerFingerprint(),
        captured_at = os.time()
    }
    local ok2, json = pcall(http.JSONEncode, http, cfg)
    if not ok2 then
        return false
    end
    local wrote = false
    pcall(
        function()
            if type(makefolder) == "function" and type(isfolder) == "function" then
                if not isfolder(CONFIG_FOLDER) then
                    makefolder(CONFIG_FOLDER)
                end
                if not isfolder(HISTORY_FOLDER) then
                    makefolder(HISTORY_FOLDER)
                end
            end
            if type(writefile) == "function" then
                writefile(CONFIG_PATH, json)
                wrote = true
                local job = (cfg.server and cfg.server.jobId) or "unknown"
                local jobShort = string.sub(job, 1, 8)
                local safePath = (cfg.fullname or cfg.name or "remote"):gsub("%.", "_"):gsub("[^%w_%-]", "_")
                if #safePath > 80 then
                    safePath = string.sub(safePath, 1, 80)
                end
                local histName =
                    HISTORY_PREFIX .. tostring(cfg.captured_at) .. "_" .. jobShort .. "_" .. safePath .. ".json"
                writefile(HISTORY_FOLDER .. "/" .. histName, json)
            end
        end
    )
    return wrote
end

-- api
local Probe = {}

function Probe.setRemote(r, mode)
    if not validRemote(r) then
        return false
    end
    parryR, parryMode = r, mode or "buffer"
    parryInit = false
    _explicitlySet = true
    saveConfig()
    return true
end

-- hook
local function installHook()
    if _hooked then
        return true
    end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" or type(checkcaller) ~= "function" then
        return false
    end
    local ok =
        pcall(
        function()
            _oldNamecall =
                hookmetamethod(
                game,
                "__namecall",
                function(self, ...)
                    local method = getnamecallmethod()
                    local args = {...}
                    if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                        local isPayload = false
                        if args[1] then
                            if
                                typeof(args[1]) == "buffer" or
                                    (typeof(args[1]) == "string" and string.find(args[1], "\x01"))
                             then
                                isPayload = true
                            end
                        end
                        if isPayload or self.Name == "RemoteEvent" then
                            if not validRemote(parryR) or parryR ~= self then
                                parryR, parryMode, parryInit = self, "buffer", false
                                _explicitlySet = true
                                saveConfig()
                            end
                        end
                    end
                    return _oldNamecall(self, ...)
                end
            )

            local _oldIndex =
                hookmetamethod(
                game,
                "__index",
                function(self, key)
                    if
                        not checkcaller() and (key == "FireServer" or key == "fireServer") and
                            typeof(self) == "Instance" and
                            self:IsA("RemoteEvent")
                     then
                        if self.Name == "RemoteEvent" or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                            task.spawn(
                                function()
                                    if not validRemote(parryR) or parryR ~= self then
                                        parryR, parryMode, parryInit = self, "buffer", false
                                        _explicitlySet = true
                                        saveConfig()
                                    end
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
    end
    return _hooked
end

-- resolve
local function resolveFromConfig()
    if validRemote(parryR) then
        return parryR, parryMode
    end
    return nil
end

-- setup
function Probe.setup(deps)
    Utils = deps.Utils
    _initBufs()
    installHook()
    resolveFromConfig()
end

function Probe.refreshRefs()
end

function Probe.listHistory()
    local out = {}
    if type(listfiles) ~= "function" or type(isfolder) ~= "function" then
        return out
    end
    if not isfolder(HISTORY_FOLDER) then
        return out
    end
    local files = listfiles(HISTORY_FOLDER) or {}
    table.sort(files)
    for _, f in ipairs(files) do
        if type(f) == "string" and f:sub(-5) == ".json" then
            table.insert(out, f)
        end
    end
    return out
end

function Probe.readHistory(filePath)
    if type(readfile) ~= "function" then
        return nil
    end
    if type(filePath) ~= "string" then
        return nil
    end
    local ok, content = pcall(readfile, filePath)
    if not ok then
        return nil
    end
    return content
end

function Probe.resolveRemote()
    return resolveFromConfig()
end

function Probe.initParry()
    if parryInit then
        return true
    end
    local r, m = resolveFromConfig()
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
    if not _explicitlySet then
        return false
    end
    local function attempt()
        local r, m = resolveFromConfig()
        if not validRemote(r) then
            return false
        end
        if m == "event" then
            local ok = pcall(r.FireServer, r)
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
        local ok = pcall(r.FireServer, r, p)
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
    _explicitlySet = false
    _lastLoadAt = 0
end

function Probe.invalidate()
    parryR, parryMode, parryInit = nil, nil, false
    _explicitlySet = false
    _lastLoadAt = 0
end

function Probe.probeNamed()
    return resolveFromConfig()
end

function Probe.bindBallSync(handler, track)
    local Players = game:GetService("Players")
    local Replicated = game:GetService("ReplicatedStorage")
    local Remotes = Replicated:FindFirstChild("Remotes")
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")
    if not (candidate and candidate:IsA("RemoteEvent")) then
        return false
    end
    track(candidate.OnClientEvent:Connect(handler))
    return true
end

if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

return Probe
