--[[ init ]]

-- CONFIG
local CONFIG = {
    ModuleURLs = {
        Utils = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/source/Utils.luau",
        GameInfo = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/source/GameInfo.luau",
        Probe = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/source/Probe.luau",
        AutoParry = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/source/AutoParry.luau",
        AutoClash = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/source/AutoClash.luau",
        Spam = "https://raw.githubusercontent.com/Repp35/Exodus/refs/heads/main/source/Spam.luau",
        GUI = "https://raw.githubusercontent.com/Repp35/Roblox/refs/heads/main/phantom_gui.lua"
    },
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

-- global config
_G.PhantomConfig = _G.PhantomConfig or {}
_G.PhantomModuleURLs = _G.PhantomModuleURLs or CONFIG.ModuleURLs
for k, v in pairs(CONFIG) do
    if k ~= "ModuleURLs" and k ~= "HttpFetch" then
        if _G.PhantomConfig[k] == nil then
            _G.PhantomConfig[k] = v
        end
    end
end

-- httpGet
local function httpGet(url)
    if CONFIG.HttpFetch == "request" or CONFIG.HttpFetch == "auto" then
        if type(request) == "function" then
            local ok, res = pcall(request, {Url = url, Method = "GET"})
            if ok and type(res) == "table" and res.Body and #res.Body > 0 then
                return res.Body
            end
        end
    end
    if CONFIG.HttpFetch == "httpget" or CONFIG.HttpFetch == "auto" then
        if type(game) == "table" and type(game.HttpGet) == "function" then
            local ok, body = pcall(game.HttpGet, game, url)
            if ok and type(body) == "string" and #body > 0 then
                return body
            end
        end
        if type(syn) == "table" and type(syn.request) == "function" then
            local ok, res = pcall(syn.request, {Url = url, Method = "GET"})
            if ok and type(res) == "table" and res.Body and #res.Body > 0 then
                return res.Body
            end
        end
        if type(http_request) == "function" then
            local ok, res = pcall(http_request, {Url = url, Method = "GET"})
            if ok and type(res) == "table" and res.Body and #res.Body > 0 then
                return res.Body
            end
        end
    end
    return nil
end

-- loadModule
local function loadModule(name, url)
    local src
    if url and url ~= "" then
        src = httpGet(url)
    end
    if (not src or #src == 0) and type(_G["__phantom_" .. name .. "_src"]) == "string" then
        src = _G["__phantom_" .. name .. "_src"]
    end
    if not src or #src == 0 then
        error(("[phantom] failed to fetch module '%s'"):format(name))
    end
    local fn, err = loadstring(src, "phantom_" .. name)
    if not fn then
        error(("[phantom] loadstring failed for '%s': %s"):format(name, tostring(err)))
    end
    local ok, mod = pcall(fn)
    if not ok or type(mod) ~= "table" then
        error(("[phantom] module '%s' did not return a table"):format(name))
    end
    return mod
end

-- load all modules
local Utils = loadModule("Utils", CONFIG.ModuleURLs.Utils)
Utils.bootstrap(CONFIG)

local GameInfo = loadModule("GameInfo", CONFIG.ModuleURLs.GameInfo)
local Probe = loadModule("Probe", CONFIG.ModuleURLs.Probe)
local AutoParry = loadModule("AutoParry", CONFIG.ModuleURLs.AutoParry)
local AutoClash = loadModule("AutoClash", CONFIG.ModuleURLs.AutoClash)
local Spam = loadModule("Spam", CONFIG.ModuleURLs.Spam)

-- expose modules
_G.PhantomModules = {
    Utils = Utils,
    GameInfo = GameInfo,
    Probe = Probe,
    AutoParry = AutoParry,
    AutoClash = AutoClash,
    Spam = Spam
}

-- service handles
local RunService = Utils.getRunService()
local UIS = Utils.getUIS()
local Replicated = Utils.getReplicated()
local ws = workspace
local now = Utils.now()
local lp = Utils.getLocalPlayer()
local Config = _G.PhantomConfig
local State = Utils.getState()

-- module wiring
local deps = {
    Probe = Probe,
    GameInfo = GameInfo,
    Utils = Utils,
    AutoParry = AutoParry,
    AutoClash = AutoClash,
    Spam = Spam
}
AutoParry.setup(deps)
AutoClash.setup(deps)
Spam.setup(deps)
Spam.bindAutoClash(AutoClash)
AutoParry.setOnFired(
    function(t)
        AutoClash.notifyFired(t)
    end
)
AutoClash.setBurstSink(
    function()
        Spam.resetBurst()
    end
)

-- keybinds
local keyConn, keyHoldConn, installedKeySignature
local function currentKeySignature()
    return table.concat(
        {
            tostring(Config.Keybind),
            tostring(Config.SpamKeybind),
            tostring(Config.SpamMode or "Toggle")
        },
        "|"
    )
end

local function clearClash()
    local s = AutoClash.getState()
    s.clashOn, s.clashHoldUntil = false, 0
    s.clashOffAt = now()
end

local function installKeys()
    if keyConn then
        pcall(keyConn.Disconnect, keyConn)
        keyConn = nil
    end
    if keyHoldConn then
        pcall(keyHoldConn.Disconnect, keyHoldConn)
        keyHoldConn = nil
    end
    local panic, spam = Config.Keybind, Config.SpamKeybind
    local mode = Config.SpamMode == "Hold" and "Hold" or "Toggle"
    installedKeySignature = currentKeySignature()
    keyConn =
        UIS.InputBegan:Connect(
        function(i, gpe)
            if gpe then
                return
            end
            if i.KeyCode == panic then
                clearClash()
                local ap = AutoParry.getState()
                ap.fired = false
                _G.PhantomManual = false
            elseif i.KeyCode == spam then
                _G.PhantomManual = (mode == "Hold") or not _G.PhantomManual
            end
        end
    )
    Utils.track(keyConn)
    if mode == "Hold" then
        keyHoldConn =
            UIS.InputEnded:Connect(
            function(i)
                if i.KeyCode == spam then
                    _G.PhantomManual = false
                end
            end
        )
        Utils.track(keyHoldConn)
    end
end

-- pollGUI
local guiReady, _pollAcc = false, 0
local function pollGUI(dt)
    Utils.applyConfig(Config)
    _pollAcc = _pollAcc + dt
    if _pollAcc < 0.5 then
        return
    end
    _pollAcc = 0
    guiReady = true
    if installedKeySignature ~= currentKeySignature() then
        installKeys()
    end
end

installKeys()

-- bindParry
local function bindParry(ch)
    AutoParry.bindParry(ch)
end

-- bindChar
local function bindChar(ch)
    if not (ch and ch.Parent) or ch ~= lp.Character then
        return
    end
    local hrp = ch:WaitForChild("HumanoidRootPart", 10)
    if ch ~= lp.Character or not (hrp and hrp.Parent) then
        return
    end
    local dead = false
    Utils.trackCharacter(
        ch.AncestryChanged:Connect(
            function(_, parent)
                if not parent then
                    dead = true
                    AutoParry.resetState()
                    AutoClash.resetState()
                    Spam.resetState()
                end
            end
        )
    )
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if hum then
        Utils.trackCharacter(
            hum.Died:Connect(
                function()
                    AutoParry.resetState()
                    AutoClash.resetState()
                    Spam.resetState()
                end
            )
        )
    end
    Utils.trackCharacter(
        RunService.Heartbeat:Connect(
            function(dt)
                if dead or not State.active then
                    return
                end
                if not (ch.Parent and hrp.Parent) then
                    dead = true
                    return
                end
                pollGUI(dt)
                local t = now()
                AutoClash.updateDashTrack(t)
                local ball = GameInfo.getBall()
                AutoClash.evaluate(t, hrp, ball, Config)
                AutoClash.tickMaintenance()
                AutoClash.invalidateSnapshot()
                Spam.tick(dt)
                GameInfo.sampleFrameDelta(dt)
            end
        )
    )
end

-- onChar
local function onChar(ch)
    Utils.disconnectCharacterConnections()
    AutoParry.resetState()
    AutoClash.resetState()
    Spam.resetState()
    task.defer(
        function()
            pcall(bindParry, ch)
        end
    )
    task.defer(
        function()
            pcall(bindChar, ch)
        end
    )
end

Utils.track(lp.CharacterAdded:Connect(onChar))
if lp.Character then
    task.defer(
        function()
            pcall(onChar, lp.Character)
        end
    )
end

-- ball sync
local function onBallSync(d)
    AutoParry.onBallSync(d)
end
local function connectBallSync()
    return Probe.bindBallSync(onBallSync, Utils.track)
end
connectBallSync()
AutoClash.installAntiDashHooks()

-- ball ref
local _ball, _ballAt = nil, 0
local function setBall(b)
    _ball, _ballAt = b, now()
end
local function clearBallRef(b)
    if b == _ball then
        _ball, _ballAt = nil, now()
    end
end

-- ball watcher
local gameFolder = ws:WaitForChild("Game", 30)
local ballWatcher = gameFolder and gameFolder:FindFirstChild("Ball")
if ballWatcher then
    Utils.track(
        ballWatcher.ChildAdded:Connect(
            function(c)
                if c.Name == "GameBall" and c:IsA("BasePart") then
                    setBall(c)
                end
            end
        )
    )
    Utils.track(ballWatcher.ChildRemoved:Connect(clearBallRef))
    local existing = ballWatcher:FindFirstChild("GameBall")
    if existing and existing:IsA("BasePart") then
        setBall(existing)
    end
end

-- resilience hook
Utils.track(
    ws.DescendantAdded:Connect(
        function(d)
            if not State.active then
                return
            end
            if d.Name == "GameBall" and d:IsA("BasePart") then
                setBall(d)
                return
            end
            if d.Name ~= "HitboxGrow" or not d:IsA("BasePart") then
                return
            end
            local t = now()
            local res = AutoParry.getRes()
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
            local maxStack = math.floor(32 / 0.225)
            if res.stack > maxStack then
                res.stack = maxStack
            end
        end
    )
)

-- revalidateRemotes
local function revalidateRemotes()
    if not (Probe.getRemote() and (function()
                local r = Probe.getRemote()
                return r and r:IsA("RemoteEvent") and r.Parent
            end)()) then
        Probe.invalidate()
        local remote = Probe.resolveRemote()
        if not remote then
            remote = Probe.probeNamed()
        end
        if remote then
            Probe.initParry()
        end
    end
    connectBallSync()
end

-- remote bootstrap
task.spawn(
    function()
        for _ = 1, 3 do
            task.defer(GameInfo.samplePing)
            task.wait(0.2)
        end
        for _ = 1, 30 do
            pcall(
                function()
                    Probe.refreshRefs()
                    if Probe.resolveRemote() or Probe.probeNamed() then
                        Probe.initParry()
                    end
                end
            )
            task.wait(1)
        end
    end
)

-- revalidate loop
task.spawn(
    function()
        while State.active do
            pcall(revalidateRemotes)
            task.wait(3.0)
        end
    end
)

-- ball watchdog
task.spawn(
    function()
        while State.active do
            if guiReady then
                Utils.applyConfig(Config)
            end
            if not (_ball and _ball.Parent) then
                _ball, _ballAt = nil, 0
                GameInfo.getBall()
            end
            task.wait(0.5)
        end
    end
)

-- load gui
task.defer(
    function()
        if _G.__phantomGUI_loaded then
            return
        end
        local src = rawget(_G, "__phantomGUI_src")
        if type(src) ~= "string" or #src == 0 then
            local ok, body =
                pcall(
                function()
                    local url = (_G.PhantomModuleURLs and _G.PhantomModuleURLs.GUI) or CONFIG.ModuleURLs.GUI
                    if type(request) == "function" then
                        local r = request({Url = url, Method = "GET"})
                        return r and r.Body
                    end
                    if type(game) == "table" and type(game.HttpGet) == "function" then
                        return game:HttpGet(url)
                    end
                    return nil
                end
            )
            if ok and type(body) == "string" and #body > 0 then
                src = body
            end
        end
        if type(src) ~= "string" or #src == 0 or type(loadstring) ~= "function" then
            return
        end
        local fn = loadstring(src)
        if not fn then
            return
        end
        _G.__phantomGUI_src = src
        if pcall(fn) then
            _G.__phantomGUI_loaded = true
        end
    end
)

-- boot log
task.defer(
    function()
        task.wait(0.1)
        pcall(Probe.refreshRefs)
        print(
            ("[%s v%s Unified] iniciando... (Auto Spam sem TL) | GameId=%s | TS=%s | Remotes=%s | Ball=%s | ResStack=%d | PB=%.0fms pingOW=%.0fms | EMA alpha=%.2f | MAINT: interval=%.0fms holdMin=%.0fms radius=%.0f preFill=%d frames"):format(
                Utils.name(),
                Utils.version(),
                tostring(game.GameId),
                Replicated:FindFirstChild("TS") and "ok" or "nil",
                Replicated:FindFirstChild("Remotes") and "ok" or "nil",
                tostring(GameInfo.getBall() ~= nil),
                AutoParry.getRes().stack,
                GameInfo.preBufferMs(),
                GameInfo.pingOneWay() * 1000,
                0.15,
                50,
                60,
                25,
                4
            )
        )
    end
)

-- diagnostics
local _diagLast = 0
local function pushDiagnostics()
    local t = now()
    if (t - _diagLast) < 0.5 then
        return
    end
    _diagLast = t
    local b = GameInfo.getBall()
    local r, m = Probe.getRemote()
    local cs = AutoClash.getState()
    _G.PhantomDiag = {
        version = Utils.version(),
        scriptName = Utils.name(),
        gameId = game.GameId,
        placeId = game.PlaceId,
        tsOk = Replicated:FindFirstChild("TS") ~= nil,
        remotesOk = Replicated:FindFirstChild("Remotes") ~= nil,
        parryRemote = (r and r:GetFullName()) or nil,
        parryMode = m or nil,
        ballOk = b ~= nil,
        ballPath = b and b:GetFullName() or nil,
        syncOk = (t - GameInfo.syncLastAt()) < 5,
        lastSyncAt = GameInfo.syncLastAt(),
        ping = GameInfo.smoothPing(),
        pingOneWayMs = GameInfo.pingOneWay() * 1000,
        preBufferMs = GameInfo.preBufferMs(),
        jitterMs = GameInfo.jitterEMA(),
        frameVar = GameInfo.frameVar(),
        fireIntEMA = 0,
        fps = Spam.fps(),
        cps = Config.CPS,
        spamRateMode = Config.SpamRateMode,
        autoParry = Config.AutoParry == true,
        autoClash = Config.AutoClash ~= false,
        keybind = Config.Keybind and Config.Keybind.Name or nil,
        spamKeybind = Config.SpamKeybind and Config.SpamKeybind.Name or nil,
        spamMode = Config.SpamMode or "Toggle",
        manualSpam = _G.PhantomManual == true,
        clashOn = cs.clashOn,
        targetCps = cs.targetCps,
        dangerEma = cs.dangerEma,
        antiDashActive = cs.dashAnti.untilT > t,
        antiDashUntil = cs.dashAnti.untilT,
        antiDashSrc = cs.dashAnti.src and cs.dashAnti.src.Name or nil,
        resStack = AutoParry.getRes().stack,
        resBonus = AutoParry.resRadiusBonus(),
        maintLastCheck = cs.lastMaintCheck,
        maintSinceCheck = (t - cs.lastMaintCheck),
        updatedAt = t
    }
end

task.spawn(
    function()
        while State.active do
            pcall(pushDiagnostics)
            task.wait(0.5)
        end
    end
)
