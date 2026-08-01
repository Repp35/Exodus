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
local _remoteTrusted = false

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
local function cacheRemote(r, mode, trusted)
    if not validRemote(r) then
        return nil
    end
    local changed = (parryR ~= r) or (parryMode ~= mode)
    parryR, parryMode = r, mode
    parryInit = false
    -- Se veio de um FireServer com payload confirmado, marcamos como
    -- trusted. Pool nomeado e config salvo ficam "untrusted" até o hook
    -- de payload confirmar depois.
    if trusted then
        _remoteTrusted = true
    end
    if changed then
        saveConfig()
    end
    return r, mode
end

-- Detecta o "payload de parry" da mesma forma que o invisible hub faz:
-- o primeiro argumento precisa ser buffer OU string contendo o byte 0x01.
-- Sem esse match, NÃO cacheia — foi essa a causa do erro "CFrame was
-- passed" no Network (o remote cacheado era um RemoteEvent genérico
-- chamado com CFrame, e o fireParry depois mandava um buffer pra ele).
local function looksLikeParryPayload(a1)
    local t = typeof(a1)
    if t == "buffer" then
        return true
    end
    if t == "string" then
        local ok, found = pcall(string.find, a1, "\1", 1, true)
        return ok and found ~= nil
    end
    return false
end

local function installHook()
    if _hooked then
        return true
    end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" or type(checkcaller) ~= "function" then
        return false
    end
    local ok, err = pcall(function()
        -- Hook principal: __namecall. Igual ao invisible hub, só captura
        -- o remote quando o payload realmente bate (buffer ou string com
        -- \x01). Isso evita cachear o RemoteEvent errado.
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if _hookEnabled and not checkcaller() and (method == "FireServer" or method == "fireServer") then
                if typeof(self) == "Instance" and self:IsA("RemoteEvent") then
                    local args = {...}
                    if looksLikeParryPayload(args[1]) then
                        cacheRemote(self, "buffer", true)
                    end
                end
            end
            return _oldNamecall(self, ...)
        end)

        -- Hook secundário: __index. Usado pelo invisible pra detectar o
        -- remote na hora do fetch. Mantemos o fallback, mas só cacheia
        -- se o remote realmente parecer o de parry (nome RemoteEvent
        -- com parent que contém "Remote" no path).
        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if _hookEnabled and not checkcaller() and (key == "FireServer" or key == "fireServer") and typeof(self) == "Instance" and self:IsA("RemoteEvent") then
                if self.Name == "RemoteEvent" or (self.Parent and type(self.Parent.Name) == "string" and string.find(self.Parent.Name, "Remote")) then
                    task.spawn(function()
                        -- Index hook não confirma payload — fica untrusted.
                        cacheRemote(self, "buffer", false)
                    end)
                end
            end
            return _oldIndex(self, key)
        end)
    end)
    if ok then
        _hooked = true
    else
        warn("[probe] installHook falhou: " .. tostring(err))
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
            _remoteTrusted = false -- config salvo, sem confirmação de payload
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
            return cacheRemote(rem, "buffer", false)
        end
    end
    if GenRemotes then
        local rem = GenRemotes:FindFirstChild("RE_1")
        if validRemote(rem) then
            return cacheRemote(rem, "event", false)
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
                        return cacheRemote(r, (r.Name == "RE_1") and "event" or "buffer", false)
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
    -- Estratégia (alinhada com o invisible hub):
    -- 1) Resolve o remote cacheado.
    -- 2) Se for "event", dispara sem payload.
    -- 3) Se for "buffer", manda o payload de parry. Se o remote não for
    --    trusted (veio de config/pool nomeado/__index sem payload), faz
    --    um "probe silencioso" com pcall antes pra detectar remote errado
    --    (ex.: CFrame was passed). Se falhar, invalida e re-resolve.
    -- 4) Em qualquer falha, re-tenta UMA vez depois de invalidar.
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

        if not _remoteTrusted then
            local probeOk, probeErr = pcall(r.FireServer, r, p)
            if not probeOk then
                warn(("[phantom_logic] remote não aceitou payload, re-resolvendo: %s"):format(tostring(probeErr)))
                parryR, parryMode, parryInit, _remoteTrusted = nil, nil, false, false
                r, m = resolveRemote()
                if not validRemote(r) then
                    return false
                end
            else
                -- Passou no probe — agora o remote é trusted.
                _remoteTrusted = true
                parryInit = true
                return true
            end
        end

        local initOk, initialized = pcall(Probe.initParry)
        if not initOk or not initialized then
            return false
        end
        local ok, err = pcall(r.FireServer, r, p)
        if not ok then
            warn(("[phantom_logic] fireParry.fire fail: %s"):format(tostring(err)))
        else
            _remoteTrusted = true
        end
        return ok
    end

    if attempt() then
        return true
    end
    -- Falhou: invalida o remote cacheado e re-tenta UMA vez.
    Probe.invalidateRemote()
    return attempt()
end

function Probe.getRemote()
    return parryR, parryMode
end

function Probe.invalidateRemote()
    parryR, parryMode, parryInit = nil, nil, false
    _remoteTrusted = false
end

-- alias usado pelo init pra revalidar
function Probe.invalidate()
    parryR, parryMode, parryInit = nil, nil, false
    _remoteTrusted = false
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
