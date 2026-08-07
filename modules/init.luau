-- [[ init ]]

_G.ExodusModules = _G.ExodusModules or {}

local Init = {}

local REPO = "Repp35/Exodus"
local BRANCH = "main"
local BASE_URL = "https://raw.githubusercontent.com/" .. REPO .. "/"

local ModuleURLs = {
    Utils = BASE_URL .. BRANCH .. "/modules/utils.luau",
    GameInfo = BASE_URL .. BRANCH .. "/modules/gameinfo.luau",
    Probe = BASE_URL .. BRANCH .. "/modules/probe.luau",
    AutoParry = BASE_URL .. BRANCH .. "/modules/autoparry.luau",
    AutoClash = BASE_URL .. BRANCH .. "/modules/autoclash.luau",
    Spam = BASE_URL .. BRANCH .. "/modules/spam.luau",
    GUI = BASE_URL .. BRANCH .. "/ui-2.luau"
}

-- loader
local function getLatestSHA()
    
    local apiURL = "https://api.github.com/repos/" .. REPO .. "/commits/" .. BRANCH .. "?t=" .. os.time()
    
    local success, result = pcall(function()
        local body
        local httpService = game:GetService("HttpService")
        
        
        local headers = {
            ["User-Agent"] = "Exodus-Loader/1.0",
            ["Cache-Control"] = "no-cache"
        }

        if type(_G.request) == "function" then
            local r = _G.request({
                Url = apiURL, 
                Method = "GET",
                Headers = headers
            })
            if r and r.StatusCode == 200 then
                body = r.Body
            end
        elseif type(game.HttpGet) == "function" then
            
            body = game:HttpGet(apiURL)
        end
        
        if type(body) == "string" and body ~= "" then
            local data = httpService:JSONDecode(body)
            if type(data) == "table" and type(data.sha) == "string" and #data.sha >= 7 then
                return data.sha
            end
        end
        return nil
    end)
    
    return success and result or nil
end

local function updateURLs()
    local sha = getLatestSHA()
    local versionIdentifier
    
    if sha then
        print("[Exodus] SHA obtido com sucesso: " .. sha:sub(1, 7))
        versionIdentifier = sha
    else
        warn("[Exodus] Falha ao obter SHA, usando branch main (pode haver cache de 5 min)")
        versionIdentifier = "refs/heads/" .. BRANCH
    end
    
    
    ModuleURLs.Utils = BASE_URL .. versionIdentifier .. "/modules/utils.luau"
    ModuleURLs.GameInfo = BASE_URL .. versionIdentifier .. "/modules/gameinfo.luau"
    ModuleURLs.Probe = BASE_URL .. versionIdentifier .. "/modules/probe.luau"
    ModuleURLs.AutoParry = BASE_URL .. versionIdentifier .. "/modules/autoparry.luau"
    ModuleURLs.AutoClash = BASE_URL .. versionIdentifier .. "/modules/autoclash.luau"
    ModuleURLs.Spam = BASE_URL .. versionIdentifier .. "/modules/spam.luau"
    ModuleURLs.GUI = BASE_URL .. versionIdentifier .. "/ui-2.luau"
end

updateURLs()

-- config
local CONFIG = {
    AutoParry = true,
    AutoClash = true,
    ManualSpam = false,
    CPS = 4,
    SpamRateMode = "CPF",
    Keybind = Enum.KeyCode.F9,
    SpamKeybind = Enum.KeyCode.F,
    SpamMode = "Toggle",
    HttpFetch = "auto"
}

local function fetchSource(url)
    if type(url) ~= "string" or url == "" then return nil end
    local success, result = pcall(function()
        if type(_G.request) == "function" then
            local r = _G.request({Url = url, Method = "GET"})
            if type(r) ~= "table" or type(r.Body) ~= "string" then
                error("Resposta HTTP inválida.")
            end
            if type(r.StatusCode) == "number" and r.StatusCode ~= 200 then
                error("HTTP " .. tostring(r.StatusCode))
            end
            return r.Body
        end
        if type(game.HttpGet) == "function" then
            return game:HttpGet(url)
        end
        error("Nenhum serviço HTTP encontrado (request ou HttpGet).")
    end)
    if not success or type(result) ~= "string" or result == "" then
        warn("[Exodus Loader] Erro ao baixar de " .. url .. ": " .. tostring(result))
        return nil
    end
    return result
end

local function loadModule(name, url)
    if type(loadstring) ~= "function" then
        error("loadstring não está disponível neste ambiente.")
    end
    local source = fetchSource(url)
    if not source then return nil end

    local fn, err = loadstring(source, name)
    if not fn then
        warn("[Exodus Loader] Erro de sintaxe no módulo " .. name .. ": " .. tostring(err))
        return nil
    end

    local ok, module = pcall(fn)
    if not ok then
        warn("[Exodus Loader] Erro ao executar módulo " .. name .. ": " .. tostring(module))
        return nil
    end

    if type(module) ~= "table" then
        warn("[Exodus Loader] O módulo " .. name .. " não retornou uma tabela.")
        return nil
    end

    _G.ExodusModules[name] = module
    return module
end

-- start
function Init.start()
    print("[Exodus] Iniciando carregamento via loadstring...")

    if type(_G.PhantomStop) == "function" then
        pcall(_G.PhantomStop)
    end

    local loaded = {}
    local modulesToLoad = {"Utils", "GameInfo", "Probe", "AutoParry", "AutoClash", "Spam"}
    for _, name in ipairs(modulesToLoad) do
        loaded[name] = loadModule(name, ModuleURLs[name])
        if not loaded[name] then
            error("Falha crítica: " .. name .. " não carregado.")
        end
    end

    local Utils = loaded.Utils
    local GameInfo = loaded.GameInfo
    local Probe = loaded.Probe
    local AutoParry = loaded.AutoParry
    local AutoClash = loaded.AutoClash
    local Spam = loaded.Spam

    Utils.start()
    Utils.setConfig(CONFIG)
    Utils.setModuleURLs(ModuleURLs)

    GameInfo.setup({Utils = Utils})
    Probe.setup({Utils = Utils})
    AutoParry.setup({Probe = Probe, GameInfo = GameInfo, Utils = Utils})
    AutoClash.setup({Probe = Probe, GameInfo = GameInfo, Utils = Utils, AutoParry = AutoParry})
    Spam.setup({Probe = Probe, GameInfo = GameInfo, Utils = Utils, AutoClash = AutoClash})

    
    
    _G.PhantomOnBurst = function()
        if AutoParry and type(AutoParry.fire) == "function" then
            pcall(AutoParry.fire)
        end
    end

    
    local function clashOn()
        return AutoClash.clashOn()
    end
    Utils.setOnClashOn(clashOn)
    _G.PhantomClashOn = clashOn

    local function getConfig()
        local cfg = Utils.getConfig()
        return type(cfg) == "table" and cfg or CONFIG
    end

    
    local UIS = Utils.getUserInputService()
    local function installKeys()
        Utils.track(UIS.InputBegan:Connect(function(i, gpe)
            if gpe then return end
            local cfg = getConfig()
            local panic = cfg.Keybind or CONFIG.Keybind
            local spam = cfg.SpamKeybind or CONFIG.SpamKeybind
            local mode = cfg.SpamMode == "Hold" and "Hold" or "Toggle"

            if i.KeyCode == panic then
                AutoClash.forceClear()
                local ap = AutoParry.getState()
                if ap then ap.fired = false end
                Utils.setManualSpamActive(false)
            elseif i.KeyCode == spam then
                if mode == "Hold" then
                    Utils.setManualSpamActive(true)
                else
                    Utils.setManualSpamActive(not Utils.isManualSpamActive())
                end
            end
        end))

        Utils.track(UIS.InputEnded:Connect(function(i)
            local cfg = getConfig()
            local spam = cfg.SpamKeybind or CONFIG.SpamKeybind
            if cfg.SpamMode == "Hold" and i.KeyCode == spam then
                Utils.setManualSpamActive(false)
            end
        end))
    end
    installKeys()

    
    
    
    local localPlayer = Utils.getLocalPlayer()
    local _localUserId = localPlayer and localPlayer.UserId or -1
    local _lastBallTarget = -999
    local function onBallSync(d)
        if typeof(d) ~= "table" then return end
        local ok, err = pcall(AutoParry.onBallSync, d)
        if not ok then
            warn("[Exodus] Erro ao processar BallSync: " .. tostring(err))
            return
        end

        local newTarget = d.TargetPlayerID
        if type(newTarget) ~= "number" then newTarget = -999 end
        local targetJustChangedToMe = newTarget == _localUserId and _lastBallTarget ~= _localUserId
        _lastBallTarget = newTarget
        if not targetJustChangedToMe then return end

        local ch = localPlayer and localPlayer.Character
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        local ball = GameInfo.getBall()
        if hrp and hrp.Parent and ball and ball.Parent then
            pcall(AutoClash.evaluate, Utils.now(), hrp, ball, getConfig(), true)
        end
    end

    pcall(GameInfo.installBallWatcher, Utils.track)
    pcall(Probe.bindBallSync, onBallSync, Utils.track)

    task.defer(function()
        pcall(AutoClash.installAntiDashHooks)
    end)

    
    
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
            if not (ch.Parent and hrp.Parent) then
                deactivate()
                return
            end

            local t = Utils.now()
            local ball = GameInfo.getBall()
            AutoClash.updateDashTrack(t)
            AutoClash.evaluate(t, hrp, ball, getConfig())
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

    
    
    task.spawn(function()
        while Utils.isActive() do
            local initialized = false
            local ok, err = pcall(function()
                local remote = Probe.getRemote()
                if remote and not (remote.Parent and remote:IsA("RemoteEvent")) then
                    Probe.invalidate()
                    remote = nil
                end
                if not remote then
                    remote = Probe.resolveRemote()
                end
                if remote then
                    initialized = Probe.initParry() == true
                end
                Probe.bindBallSync(onBallSync, Utils.track)
            end)
            if not ok then
                warn("[Exodus] Erro na manutenção remota: " .. tostring(err))
            end
            task.wait(initialized and 3.0 or 1.0)
        end
    end)

    task.defer(function()
        print("[Exodus] Carregando Interface...")
        local guiSource = fetchSource(ModuleURLs.GUI)
        if guiSource then
            local fn, err = loadstring(guiSource, "ExodusGUI")
            if fn then
                Utils.setGUISource(guiSource)
                _G.ExodusModules.GUI = nil
                local ok, result = pcall(fn)
                if ok then
                    local PhantomUI = type(result) == "table" and result or _G.ExodusModules.GUI
                    if PhantomUI and type(PhantomUI.setup) == "function" then
                        local ok2, err3 = pcall(PhantomUI.setup, {Utils = Utils})
                        if ok2 then
                            Utils.setGUILoaded(true)
                            print("[Exodus] Interface inicializada com sucesso.")
                        else
                            warn("[Exodus] Erro ao inicializar GUI: " .. tostring(err3))
                        end
                    else
                        warn("[Exodus] Módulo GUI carregado mas PhantomUI.setup não encontrado.")
                    end
                else
                    warn("[Exodus] Erro ao executar script da GUI: " .. tostring(result))
                end
            else
                warn("[Exodus] Erro de sintaxe na GUI: " .. tostring(err))
            end
        else
            warn("[Exodus] Não foi possível baixar a interface.")
        end
    end)

    print("[Exodus] Sistema inicializado e compartilhado em _G.ExodusModules")
    return true
end

_G.ExodusModules.Init = Init

return Init
