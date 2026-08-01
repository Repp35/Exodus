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

    -- AutoClash dispara isso quando quer clicar de verdade. Sem isso, o
    -- activateBurst sobe o estado mas nunca chama o remote.
    _G.PhantomOnBurst = function()
        if AutoParry and type(AutoParry.fire) == "function" then
            pcall(AutoParry.fire)
        end
    end

    -- Globais espelhados pros módulos que checam via _G (probe, init legacy).
    Utils.setOnClashOn(function()
        if AutoClash and AutoClash.clashOn then
            return AutoClash.clashOn()
        end
        return false
    end)
    _G.PhantomClashOn = function()
        if AutoClash and AutoClash.clashOn then
            return AutoClash.clashOn()
        end
        return false
    end

    local function getConfig() return Utils.getConfig() or CONFIG end

    -- Keybinds: F9 limpa clash, F toggle manualSpam
    local UIS = Utils.getUserInputService()
    local keyConn = nil
    local keyHoldConn = nil
    local function installKeys()
        if keyConn then pcall(function() keyConn:Disconnect() end) keyConn = nil end
        if keyHoldConn then pcall(function() keyHoldConn:Disconnect() end) keyHoldConn = nil end
        local cfg = getConfig()
        local panic = cfg.Keybind or CONFIG.Keybind
        local spam = cfg.SpamKeybind or CONFIG.SpamKeybind
        local mode = (cfg.SpamMode == "Hold") and "Hold" or "Toggle"
        keyConn = UIS.InputBegan:Connect(function(i, gpe)
            if gpe then return end
            if i.KeyCode == panic then
                if AutoClash and AutoClash.getState then
                    local s = AutoClash.getState()
                    s.clashOn, s.clashHoldUntil = false, 0
                    s.clashOffAt = Utils.now()
                end
                if AutoParry and AutoParry.getState then
                    local ap = AutoParry.getState()
                    ap.fired = false
                end
                Utils.setManualSpamActive(false)
                _G.PhantomManual = false
            elseif i.KeyCode == spam then
                if mode == "Hold" then
                    Utils.setManualSpamActive(true)
                    _G.PhantomManual = true
                else
                    local cur = (_G.PhantomManual == true) or Utils.isManualSpamActive()
                    local nv = not cur
                    Utils.setManualSpamActive(nv)
                    _G.PhantomManual = nv
                end
            end
        end)
        if mode == "Hold" then
            keyHoldConn = UIS.InputEnded:Connect(function(i)
                if i.KeyCode == spam then
                    Utils.setManualSpamActive(false)
                    _G.PhantomManual = false
                end
            end)
        end
    end
    installKeys()

    -- Hook de BallSync via probe (necessário pra AutoClash.tryInlineActivate
    -- reagir a mudanças de target em tempo real).
    local function onBallSync(d)
        if AutoParry and AutoParry.onBallSync then
            pcall(AutoParry.onBallSync, d)
        end
        if AutoClash and AutoClash.tryInlineActivate then
            local lp = Utils.getLocalPlayer()
            local ch = lp and lp.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            local ball = GameInfo and GameInfo.getBall and GameInfo.getBall()
            if hrp and hrp.Parent and ball and ball.Parent then
                pcall(AutoClash.tryInlineActivate, Utils.now(), hrp, ball, getConfig())
            end
        end
    end
    if Probe and Probe.bindBallSync then
        pcall(Probe.bindBallSync, onBallSync, Utils.track)
    end

    -- Anti-dash: instala hooks nos players (animações de dash).
    if AutoClash and AutoClash.installAntiDashHooks then
        task.defer(function()
            pcall(AutoClash.installAntiDashHooks)
        end)
    end

    -- Loop principal por character: Heartbeat chamando AutoClash.evaluate,
    -- AutoClash.updateDashTrack, Spam.tick — sem isso, NENHUM clique acontece.
    local dead = false
    local function bindChar(ch)
        if not (ch and ch.Parent) then return end
        local hrp = ch:WaitForChild("HumanoidRootPart", 10)
        if not (hrp and hrp.Parent) then return end
        dead = false

        local ancestryConn
        ancestryConn = ch.AncestryChanged:Connect(function(_, parent)
            if not parent then
                dead = true
                pcall(function()
                    if AutoParry and AutoParry.resetState then AutoParry.resetState() end
                    if AutoClash and AutoClash.resetState then AutoClash.resetState() end
                    if Spam and Spam.resetState then Spam.resetState() end
                end)
            end
        end)
        Utils.trackCharacter(ancestryConn)

        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then
            Utils.trackCharacter(hum.Died:Connect(function()
                pcall(function()
                    if AutoParry and AutoParry.resetState then AutoParry.resetState() end
                    if AutoClash and AutoClash.resetState then AutoClash.resetState() end
                    if Spam and Spam.resetState then Spam.resetState() end
                end)
            end))
        end

        Utils.trackCharacter(
            Utils.getRunService().Heartbeat:Connect(function(dt)
                if dead or not Utils.isActive() then return end
                if not (ch.Parent and hrp.Parent) then dead = true return end
                local t = Utils.now()
                local ball = GameInfo and GameInfo.getBall and GameInfo.getBall()
                if AutoClash and AutoClash.updateDashTrack then
                    pcall(AutoClash.updateDashTrack, t)
                end
                if AutoClash and AutoClash.evaluate then
                    pcall(AutoClash.evaluate, t, hrp, ball, getConfig())
                end
                if AutoClash and AutoClash.invalidateSnapshot then
                    pcall(AutoClash.invalidateSnapshot)
                end
                if Spam and Spam.tick then
                    pcall(Spam.tick, dt)
                end
                if GameInfo and GameInfo.sampleFrameDelta then
                    pcall(GameInfo.sampleFrameDelta, dt)
                end
            end)
        )
    end

    local function setupCharacter(character)
        if not character then return end
        task.defer(function()
            pcall(AutoParry.bindParry, character)
        end)
        task.defer(function()
            pcall(bindChar, character)
        end)
    end

    local lp = Utils.getLocalPlayer()
    if lp then
        Utils.track(lp.CharacterAdded:Connect(setupCharacter))
    end
    if lp and lp.Character then
        setupCharacter(lp.Character)
    end

    -- Resolve remoto em background: tenta várias vezes nos primeiros segundos
    -- pq o jogo pode demorar pra replicar a TS folder.
    task.spawn(function()
        for _ = 1, 30 do
            pcall(function()
                if Probe and Probe.refreshRefs then Probe.refreshRefs() end
                if Probe and Probe.resolveRemote then
                    local r = Probe.resolveRemote()
                    if not r and Probe.probeNamed then Probe.probeNamed() end
                end
                if Probe and Probe.initParry then Probe.initParry() end
            end)
            task.wait(1)
        end
    end)

    -- Revalidação periódica do remote (caso o jogo troque a TS folder).
    task.spawn(function()
        while Utils.isActive() do
            pcall(function()
                if not Probe then return end
                local r, m = Probe.getRemote()
                if not (r and r.Parent and r:IsA("RemoteEvent")) then
                    if Probe.invalidate then Probe.invalidate() end
                    if Probe.invalidateRemote then Probe.invalidateRemote() end
                    if Probe.resolveRemote then Probe.resolveRemote() end
                    if Probe.probeNamed then Probe.probeNamed() end
                    if Probe.initParry then Probe.initParry() end
                end
                if Probe.bindBallSync then
                    pcall(Probe.bindBallSync, onBallSync, Utils.track)
                end
            end)
            task.wait(3.0)
        end
    end)

    task.defer(function()
        print("[Exodus] Carregando Interface...")
        local guiSource = fetchSource(ModuleURLs.GUI)
        if guiSource then
            local fn, err = loadstring(guiSource, "ExodusGUI")
            if fn then
                Utils.setGUISource(guiSource)
                local ok, result = pcall(fn)
                if ok then
                    local PhantomUI = result or _G.ExodusModules.GUI
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
        end
    end)

    print("[Exodus] Sistema inicializado e compartilhado em _G.ExodusModules")
end

_G.ExodusModules.Init = Init

return Init
