-- [[ init ]]

_G.ExodusModules = _G.ExodusModules or {}

local Init = {}

local REPO     = "Repp35/Exodus"
local BRANCH   = "main"
local BASE_URL = "https://raw.githubusercontent.com/" .. REPO .. "/"

local ModuleURLs = {
    Utils     = BASE_URL .. BRANCH .. "/modules/utils.luau",
    GameInfo  = BASE_URL .. BRANCH .. "/modules/gameinfo.luau",
    Probe     = BASE_URL .. BRANCH .. "/modules/probe.luau",
    AutoParry = BASE_URL .. BRANCH .. "/modules/autoparry.luau",
    AutoClash = BASE_URL .. BRANCH .. "/modules/autoclash.luau",
    Spam      = BASE_URL .. BRANCH .. "/modules/spam.luau",
    GUI       = BASE_URL .. BRANCH .. "/ui-2.luau",
}

local CONFIG = {
    AutoParry     = true,
    AutoClash     = true,
    ManualSpam    = false,
    CPS           = 4,
    SpamRateMode  = "CPF",
    Keybind       = Enum.KeyCode.F9,
    SpamKeybind   = Enum.KeyCode.F,
    SpamMode      = "Toggle",
    HttpFetch     = "auto",
}

-- ── loader ───────────────────────────────────────────────────────────────────

local function fetchSource(url)
    if type(url) ~= "string" or url == "" then return nil end
    local ok, res = pcall(function()
        if type(_G.request) == "function" then
            local r = _G.request({ Url = url, Method = "GET" })
            if type(r) ~= "table" or type(r.Body) ~= "string" then error("Resposta HTTP inválida.") end
            if type(r.StatusCode) == "number" and r.StatusCode ~= 200 then error("HTTP " .. tostring(r.StatusCode)) end
            return r.Body
        end
        if type(game.HttpGet) == "function" then return game:HttpGet(url) end
        error("Nenhum serviço HTTP encontrado (request ou HttpGet).")
    end)
    if not ok or type(res) ~= "string" or res == "" then
        warn("[Exodus Loader] Erro ao baixar de " .. url .. ": " .. tostring(res))
        return nil
    end
    return res
end

local function loadModule(name, url)
    if type(loadstring) ~= "function" then
        error("loadstring não está disponível neste ambiente.")
    end
    local source = fetchSource(url)
    if not source then return nil end

    local fn, err = loadstring(source, name)
    if not fn then
        warn("[Exodus Loader] Erro de sintaxe em " .. name .. ": " .. tostring(err))
        return nil
    end

    local ok, mod = pcall(fn)
    if not ok then
        warn("[Exodus Loader] Erro ao executar " .. name .. ": " .. tostring(mod))
        return nil
    end
    if type(mod) ~= "table" then
        warn("[Exodus Loader] " .. name .. " não retornou tabela.")
        return nil
    end

    _G.ExodusModules[name] = mod
    return mod
end

local function getLatestSHA()
    local apiURL = "https://api.github.com/repos/" .. REPO .. "/commits/" .. BRANCH .. "?t=" .. os.time()
    local ok, sha = pcall(function()
        local http = game:GetService("HttpService")
        local headers = { ["User-Agent"] = "Exodus-Loader/1.0", ["Cache-Control"] = "no-cache" }
        local body
        if type(_G.request) == "function" then
            local r = _G.request({ Url = apiURL, Method = "GET", Headers = headers })
            if r and r.StatusCode == 200 then body = r.Body end
        elseif type(game.HttpGet) == "function" then
            body = game:HttpGet(apiURL)
        end
        if type(body) == "string" and body ~= "" then
            local data = http:JSONDecode(body)
            if type(data) == "table" and type(data.sha) == "string" and #data.sha >= 7 then
                return data.sha
            end
        end
        return nil
    end)
    return ok and sha or nil
end

local function refreshURLs()
    local sha = getLatestSHA()
    local ver
    if sha then
        print("[Exodus] SHA obtido: " .. sha:sub(1, 7))
        ver = sha
    else
        warn("[Exodus] Falha ao obter SHA, usando branch main.")
        ver = "refs/heads/" .. BRANCH
    end
    for k in pairs(ModuleURLs) do
        if k ~= "GUI" then ModuleURLs[k] = BASE_URL .. ver .. "/modules/" .. k:lower() .. ".luau" end
    end
    ModuleURLs.GUI = BASE_URL .. ver .. "/ui-2.luau"
end

-- ── boot ─────────────────────────────────────────────────────────────────────

function Init.start()
    print("[Exodus] Iniciando carregamento via loadstring...")

    if type(_G.PhantomStop) == "function" then pcall(_G.PhantomStop) end

    refreshURLs()

    local modulesToLoad = { "Utils", "GameInfo", "Probe", "AutoParry", "AutoClash", "Spam" }
    local loaded = {}
    for _, name in ipairs(modulesToLoad) do
        loaded[name] = loadModule(name, ModuleURLs[name])
        if not loaded[name] then error("Falha crítica: " .. name .. " não carregado.") end
    end

    local Utils, GameInfo, Probe, AutoParry, AutoClash, Spam =
        loaded.Utils, loaded.GameInfo, loaded.Probe, loaded.AutoParry, loaded.AutoClash, loaded.Spam

    Utils.start()
    Utils.setConfig(CONFIG)
    Utils.setModuleURLs(ModuleURLs)

    Probe.setup()
    GameInfo.setup({ Utils = Utils })
    AutoParry.setup({ Probe = Probe, GameInfo = GameInfo, Utils = Utils })
    AutoClash.setup({ Probe = Probe, GameInfo = GameInfo, Utils = Utils, AutoParry = AutoParry })
    Spam.setup({ Probe = Probe, GameInfo = GameInfo, Utils = Utils, AutoClash = AutoClash })

    _G.PhantomOnBurst = function()
        if AutoParry and type(AutoParry.fire) == "function" then pcall(AutoParry.fire) end
    end

    local function onBallSync(data)
        if AutoParry and type(AutoParry.onBallSync) == "function" then
            pcall(AutoParry.onBallSync, data)
        end
        if AutoClash and type(AutoClash.onBallSync) == "function" then
            pcall(AutoClash.onBallSync, data)
        end
    end

    Utils.track(GameInfo.installBallWatcher(Utils.track))
    Utils.track(Probe.bindBallSync(onBallSync, Utils.track))

    -- ── character glue ──────────────────────────────────────────────────────────

    local characterGeneration = 0

    local function resetStates()
        pcall(AutoParry.resetState)
        pcall(AutoClash.resetState)
        pcall(Spam.resetState)
    end

    local function bindChar(ch, generation)
        if not (ch and ch.Parent) then return end
        local hrp = ch:WaitForChild("HumanoidRootPart", 10)
        if generation ~= characterGeneration or not (hrp and hrp.Parent) then return end

        local dead = false
        local function deactivate()
            if dead then return end
            dead = true
            resetStates()
        end

        Utils.trackCharacter(ch.AncestryChanged:Connect(function(_, parent)
            if not parent then deactivate() end
        end))
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then
            Utils.trackCharacter(hum.Died:Connect(deactivate))
        end

        local runService = Utils.getRunService()
        Utils.trackCharacter(runService.Heartbeat:Connect(function(dt)
            if generation ~= characterGeneration or dead or not Utils.isActive() then return end
            if not (ch.Parent and hrp.Parent) then deactivate(); return end

            local t = Utils.now()
            local ball = GameInfo.getBall()
            AutoClash.updateDashTrack(t)
            AutoClash.evaluate(t, hrp, ball, Utils.getConfig() or CONFIG)
            AutoClash.invalidateSnapshot()
            Spam.tick(dt)
        end))
    end

    local function setupCharacter(character)
        if not character then return end
        characterGeneration = characterGeneration + 1
        local generation = characterGeneration
        Utils.disconnectCharacterConnections()

        task.defer(function()
            if generation == characterGeneration and Utils.isActive() then
                pcall(AutoParry.bindParry, character)
            end
        end)
        task.defer(function()
            if generation == characterGeneration and Utils.isActive() then
                pcall(bindChar, character, generation)
            end
        end)
    end

    local lp = Utils.getLocalPlayer()
    if lp then
        Utils.track(lp.CharacterAdded:Connect(setupCharacter))
    end
    if lp and lp.Character then
        setupCharacter(lp.Character)
    end

    local function installKeys()
        local UIS = Utils.getUserInputService()
        Utils.track(UIS.InputBegan:Connect(function(input, gpe)
            if gpe then return end
            local cfg = Utils.getConfig() or CONFIG
            local panic = cfg.Keybind     or CONFIG.Keybind
            local spam  = cfg.SpamKeybind or CONFIG.SpamKeybind
            local mode  = cfg.SpamMode == "Hold" and "Hold" or "Toggle"

            if input.KeyCode == panic then
                local ap = AutoParry.getState()
                if ap then ap.fired = false end
                Utils.setManualSpamActive(false)
            elseif input.KeyCode == spam then
                if mode == "Hold" then
                    Utils.setManualSpamActive(true)
                else
                    Utils.setManualSpamActive(not Utils.isManualSpamActive())
                end
            end
        end))
        Utils.track(UIS.InputEnded:Connect(function(input)
            local cfg = Utils.getConfig() or CONFIG
            if cfg.SpamMode == "Hold" and input.KeyCode == (cfg.SpamKeybind or CONFIG.SpamKeybind) then
                Utils.setManualSpamActive(false)
            end
        end))
    end
    installKeys()

    local function remoteMaintenance()
        while Utils.isActive() do
            local initialized = false
            local ok, err = pcall(function()
                local remote = Probe.getRemote()
                if remote and not (remote.Parent and remote:IsA("RemoteEvent")) then
                    Probe.invalidate()
                    remote = nil
                end
                if not remote then remote = Probe.resolveRemote() end
                if remote then initialized = Probe.initParry() == true end
                Probe.bindBallSync(onBallSync, Utils.track)
            end)
            if not ok then warn("[Exodus] Erro na manutenção remota: " .. tostring(err)) end
            task.wait(initialized and 3.0 or 1.0)
        end
    end
    task.spawn(remoteMaintenance)

    task.defer(function()
        print("[Exodus] Carregando Interface...")
        local guiSource = fetchSource(ModuleURLs.GUI)
        if not guiSource then
            warn("[Exodus] Não foi possível baixar a interface.")
            return
        end
        local fn, err = loadstring(guiSource, "ExodusGUI")
        if not fn then
            warn("[Exodus] Erro de sintaxe na GUI: " .. tostring(err))
            return
        end
        Utils.setGUISource(guiSource)
        _G.ExodusModules.GUI = nil
        local ok, result = pcall(fn)
        if not ok then
            warn("[Exodus] Erro ao executar script da GUI: " .. tostring(result))
            return
        end
        local PhantomUI = type(result) == "table" and result or _G.ExodusModules.GUI
        if PhantomUI and type(PhantomUI.setup) == "function" then
            local ok2, err3 = pcall(PhantomUI.setup, { Utils = Utils })
            if ok2 then
                Utils.setGUILoaded(true)
                print("[Exodus] Interface inicializada com sucesso.")
            else
                warn("[Exodus] Erro ao inicializar GUI: " .. tostring(err3))
            end
        else
            warn("[Exodus] Módulo GUI carregado mas PhantomUI.setup não encontrado.")
        end
    end)

    print("[Exodus] Sistema inicializado e compartilhado em _G.ExodusModules")
    return true
end

_G.ExodusModules.Init = Init
return Init
