--[[
    probe.luau
    Remote handling module for Exodus
    Method: Invisible Hub Implementation
]]

local Probe = {}
local _ballSyncConn = nil

local parryR
local parryMode = "buffer"
local parryInit = false

local _hooked = false
local _oldNamecall
local _oldIndex

local function RegisterRemote(remote)
    if not parryR then
        parryR = remote
    end
end

function Probe.fireParry(flag)
    if not parryR then
        return false
    end

    parryR:FireServer(buffer.fromstring(flag == 2 and "\x02" or "\x01"))
    return true
end

function Probe.initParry()
    if not parryR then
        return false
    end

    parryR:FireServer(buffer.fromstring("\x02"))
    parryInit = true
    return true
end

function Probe.setup()
    if _hooked then
        return
    end

    _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        local args = { ... }

        if not checkcaller() and (method == "FireServer" or method == "fireServer") then
            local isPayload = false

            if args[1] then
                if typeof(args[1]) == "buffer"
                    or (typeof(args[1]) == "string" and string.find(args[1], "\x01")) then
                    isPayload = true
                end
            end

            if isPayload or self.Name == "RemoteEvent" then
                RegisterRemote(self)
            end
        end

        return _oldNamecall(self, ...)
    end)

    _oldIndex = hookmetamethod(game, "__index", function(self, key)
        if not checkcaller()
            and (key == "FireServer" or key == "fireServer")
            and typeof(self) == "Instance"
            and self:IsA("RemoteEvent") then

            if self.Name == "RemoteEvent"
                or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                task.spawn(function()
                    RegisterRemote(self)
                end)
            end
        end

        return _oldIndex(self, key)
    end)

    _hooked = true
end

function Probe.getRemote()
    return parryR, parryMode
end

Probe.resolveRemote = Probe.getRemote

function Probe.invalidateRemote()
    parryR = nil
end

Probe.invalidate = Probe.invalidateRemote

function Probe.setRemote(remote, mode)
    parryR = remote
    parryMode = mode or "buffer"
    return true
end

function Probe.refreshRefs() end

function Probe.listHistory()
    return {}
end

function Probe.readHistory()
    return nil
end

function Probe.probeNamed()
    return parryR
end

function Probe.bindBallSync(handler, track)
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

return Probe(node, depth, path)
        if depth > maxDepth then return end
        for _, c in ipairs(node:GetChildren()) do
            local np = path .. "." .. c.Name
            if c:IsA("RemoteEvent") or c:IsA("RemoteFunction") then
                table.insert(out, {
                    name = c.Name,
                    class = c.ClassName,
                    path = np,
                })
            end
            walk(c, depth + 1, np)
        end
    end
    walk(root, 0, root.Name)
    return out
end

-- Assinatura do servidor: PlaceId + JobId + UniverseId. Se isso muda
-- entre sessões, o remote provavelmente também muda de caminho/ID.
local function getServerFingerprint()
    local info = {}
    pcall(function()
        info.placeId = game.PlaceId
        info.jobId = game.JobId
        info.universeId = game.GameId
    end)
    local Players = game:GetService("Players")
    pcall(function()
        info.userId = Players.LocalPlayer and Players.LocalPlayer.UserId
    end)
    pcall(function()
        local gs = game:GetService("GuiService")
        if gs and type(gs.GetGameGenre) == "function" then
            info.genre = gs:GetGameGenre()
        end
    end)
    return info
end

local function findInstanceByPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local cur = game
    for seg in string.gmatch(path, "[^.]+") do
        if not cur then return nil end
        cur = cur:FindFirstChild(seg)
    end
    if validRemote(cur) then return cur end
    return nil
end

-- config persist
local function saveConfig()
    if not (parryR and validRemote(parryR)) then return false end
    local ok, http = pcall(function() return game:GetService("HttpService") end)
    if not ok or not http then return false end
    local cfg = {
        -- o remote em si
        name = parryR.Name,
        class = parryR.ClassName,
        path = getFullPath(parryR),
        fullname = parryR:GetFullName(),
        mode = parryMode or "buffer",

        -- breadcrumb de cada ancestral (nome + classe + fullname)
        ancestry = getAncestry(parryR),

        -- irmãos do remote no mesmo parent
        siblings = getSiblings(parryR),
        remote_siblings = getRemoteSiblings(parryR),

        -- mapa de RemoteEvent/RemoteFunction próximos (raio de 6 níveis)
        -- pra você ver onde o remote de parry aparece no contexto
        nearby_remotes = getNearbyRemotes(parryR.Parent or parryR, 6),

        -- assinatura do servidor — se PlaceId/JobId/UniverseId batem
        -- entre sessões, o remote provavelmente também bate
        server = getServerFingerprint(),

        captured_at = os.time()
    }
    local ok2, json = pcall(http.JSONEncode, http, cfg)
    if not ok2 then return false end
    local wrote = false
    pcall(function()
        if type(makefolder) == "function" and type(isfolder) == "function" then
            if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
            if not isfolder(HISTORY_FOLDER) then makefolder(HISTORY_FOLDER) end
        end
        if type(writefile) == "function" then
            -- atual: sempre o mais recente
            writefile(CONFIG_PATH, json)
            wrote = true

            -- histórico: cada save vira um arquivo separado, nomeado com
            -- timestamp + sufixo curto do path pra você agrupar por remote.
            -- Formato: remote_<unix>_<jobId8>_<sanitized_path>.json
            local job = (cfg.server and cfg.server.jobId) or "unknown"
            local jobShort = string.sub(job, 1, 8)
            local safePath = (cfg.fullname or cfg.name or "remote")
                :gsub("%.", "_")
                :gsub("[^%w_%-]", "_")
            if #safePath > 80 then safePath = string.sub(safePath, 1, 80) end
            local histName = HISTORY_PREFIX .. tostring(cfg.captured_at) .. "_" .. jobShort .. "_" .. safePath .. ".json"
            writefile(HISTORY_FOLDER .. "/" .. histName, json)
        end
    end)
    return wrote
end

local function loadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return nil end
    if not isfile(CONFIG_PATH) then return nil end
    local ok, content = pcall(readfile, CONFIG_PATH)
    if not ok or type(content) ~= "string" then return nil end
    local ok2, http = pcall(function() return game:GetService("HttpService") end)
    if not ok2 then return nil end
    local ok3, data = pcall(http.JSONDecode, http, content)
    if not ok3 or type(data) ~= "table" then return nil end
    return data
end

-- grava o remote setado manualmente (pelo clicker) no JSON. Sem hook,
-- sem probe. Setter explícito.
function Probe.setRemote(r, mode)
    if not validRemote(r) then return false end
    parryR, parryMode = r, mode or "buffer"
    parryInit = false
    saveConfig()
    return true
end

local function installHook()
    if _hooked then return true end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" or type(checkcaller) ~= "function" then
        return false
    end
    local ok = pcall(function()
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                if typeof(self) == "Instance" and self:IsA("RemoteEvent") then
                    if not validRemote(parryR) or parryR ~= self then
                        parryR, parryMode, parryInit = self, "buffer", false
                        saveConfig()
                    end
                end
            end
            return _oldNamecall(self, ...)
        end)
    end)
    if ok then _hooked = true end
    return _hooked
end

-- resolve: cache em memória primeiro, JSON segundo. Sem scan, sem probe.
local function resolveFromConfig()
    if validRemote(parryR) then return parryR, parryMode end
    local now = _now()
    if (now - _lastLoadAt) < LOAD_COOLDOWN then return nil end
    _lastLoadAt = now
    local cfg = loadConfig()
    if cfg and cfg.path then
        local inst = findInstanceByPath(cfg.path)
        if inst then
            parryR, parryMode = inst, cfg.mode or "buffer"
            parryInit = false
            return parryR, parryMode
        end
    end
    return nil
end

function Probe.setup(deps)
    Utils = deps.Utils
    _initBufs()
    installHook()
    local r, m = resolveFromConfig()
    if r then
        print(("[probe] Remote carregado: %s (%s)"):format(getFullPath(r), tostring(m)))
    end
end

function Probe.refreshRefs() end

-- Lista todos os JSONs de histórico. Útil pra você comparar
-- o que mudou entre sessões. Retorna tabela de paths e imprime
-- um resumo no console.
function Probe.listHistory()
    local out = {}
    if type(listfiles) ~= "function" or type(isfolder) ~= "function" then
        warn("[probe] listfiles/isfolder não disponíveis nesse executor")
        return out
    end
    if not isfolder(HISTORY_FOLDER) then return out end
    local files = listfiles(HISTORY_FOLDER) or {}
    table.sort(files)
    for _, f in ipairs(files) do
        if type(f) == "string" and f:sub(-5) == ".json" then
            table.insert(out, f)
        end
    end
    print(("[probe] %d arquivo(s) em %s"):format(#out, HISTORY_FOLDER))
    for i, f in ipairs(out) do
        if i <= 20 or i == #out then
            print(("  [%d] %s"):format(i, f))
        elseif i == 21 then
            print("  ...")
        end
    end
    return out
end

-- Lê o conteúdo de um arquivo de histórico. Útil pra diff manual.
function Probe.readHistory(filePath)
    if type(readfile) ~= "function" then return nil end
    if type(filePath) ~= "string" then return nil end
    local ok, content = pcall(readfile, filePath)
    if not ok then return nil end
    return content
end

function Probe.resolveRemote()
    return resolveFromConfig()
end

function Probe.initParry()
    if parryInit then return true end
    local r, m = resolveFromConfig()
    if not r then return false end
    if m == "event" then
        parryInit = true
        return true
    end
    local p = makeBuf(2)
    if not p then return false end
    parryInit = pcall(r.FireServer, r, p)
    return parryInit
end

function Probe.fireParry(flag)
    local function attempt()
        local r, m = resolveFromConfig()
        if not validRemote(r) then return false end
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
        if not p then return false end
        local initOk, initialized = pcall(Probe.initParry)
        if not initOk or not initialized then return false end
        local ok = pcall(r.FireServer, r, p)
        return ok
    end

    if attempt() then return true end
    Probe.invalidateRemote()
    return attempt()
end

function Probe.getRemote()
    return parryR, parryMode
end

function Probe.invalidateRemote()
    parryR, parryMode, parryInit = nil, nil, false
    _lastLoadAt = 0
end

function Probe.invalidate()
    parryR, parryMode, parryInit = nil, nil, false
    _lastLoadAt = 0
end

function Probe.probeNamed()
    return resolveFromConfig()
end

function Probe.bindBallSync(handler, track)
    if _ballSyncConn then
        pcall(function() _ballSyncConn:Disconnect() end)
        _ballSyncConn = nil
    end
    local Replicated = game:GetService("ReplicatedStorage")
    local Remotes = Replicated:FindFirstChild("Remotes")
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")
    if not (candidate and candidate:IsA("RemoteEvent")) then return false end
    _ballSyncConn = candidate.OnClientEvent:Connect(handler)
    if track then track(_ballSyncConn) end
    return true
end

if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

return Probe