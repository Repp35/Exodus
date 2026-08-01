--[[ init ]]

_G.ExodusModules = _G.ExodusModules or {}

local Init = {}

local ModuleURLs = {
    Utils = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/modules/utils.luau",
    GameInfo = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/modules/gameinfo.luau",
    Probe = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/modules/probe.luau",
    AutoParry = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/modules/autoparry.luau",
    AutoClash = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/modules/autoclash.luau",
    Spam = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/modules/spam.luau",
    GUI = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/ui-2.luau"
}

-- configurações iniciais
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
    local success, result = pcall(function()
        if type(_G.request) == "function" then
            local r = _G.request({Url = url, Method = "GET"})
            return r and r.Body
        end
        if type(game.HttpGet) == "function" then
            return game:HttpGet(url)
        end
        error("Nenhum serviço HTTP encontrado (request ou HttpGet).")
    end)
    if not success then
        warn("[Exodus Loader] Erro ao baixar de " .. url .. ": " .. tostring(result))
        return nil
    end
    return result
end

local function loadModule(name, url)
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

    _G.ExodusModules[name] = module
    return module
end

function Init.start()
    print("[Exodus] Iniciando carregamento via loadstring...")

    local Utils = loadModule("Utils", ModuleURLs.Utils)
    if not Utils then error("Falha crítica: Utils não carregado.") end

    local modulesToLoad = {"GameInfo", "Probe", "AutoParry", "AutoClash", "Spam"}
    for _, name in ipairs(modulesToLoad) do
        if not loadModule(name, ModuleURLs[name]) then
            warn("[Exodus] Aviso: Falha ao carregar " .. name)
        end
    end

    local GameInfo = _G.ExodusModules.GameInfo
    local Probe = _G.ExodusModules.Probe
    local AutoParry = _G.ExodusModules.AutoParry
    local AutoClash = _G.ExodusModules.AutoClash
    local Spam = _G.ExodusModules.Spam

    Utils.start()
    Utils.setConfig(CONFIG)

    if GameInfo then GameInfo.setup({Utils = Utils}) end
    if Probe then Probe.setup({Utils = Utils}) end
    if AutoParry then AutoParry.setup({Probe = Probe, GameInfo = GameInfo, Utils = Utils}) end
    if AutoClash then AutoClash.setup({Probe = Probe, GameInfo = GameInfo, Utils = Utils, AutoParry = AutoParry}) end
    if Spam then Spam.setup({Probe = Probe, GameInfo = GameInfo, Utils = Utils, AutoClash = AutoClash}) end

    local function setupCharacter(character)
        if not character then return end
        task.defer(function()
            if AutoParry then pcall(AutoParry.bindParry, character) end
        end)
    end

    local lp = Utils.getLocalPlayer()
    if lp then
        Utils.track(lp.CharacterAdded:Connect(setupCharacter))
    end
    if Utils.getLocalPlayer().Character then
        setupCharacter(Utils.getLocalPlayer().Character)
    end

    task.defer(function()
        print("[Exodus] Carregando Interface...")
        local guiSource = fetchSource(ModuleURLs.GUI)
        if guiSource then
            local fn, err = loadstring(guiSource, "ExodusGUI")
            if fn then
                Utils.setGUISource(guiSource)
                local ok, err2 = pcall(fn)
                if ok then
                    Utils.setGUILoaded(true)
                    print("[Exodus] Interface carregada com sucesso.")
                else
                    warn("[Exodus] Erro ao executar GUI: " .. tostring(err2))
                end
            else
                warn("[Exodus] Erro de sintaxe na GUI: " .. tostring(err))
            end
        end
    end)

    print("[Exodus] Sistema inicializado e compartilhado em _G.ExodusModules")
end

_G.ExodusModules.Init = Init

return Init
