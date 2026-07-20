--[[ Utils ]]

local Utils = {}

-- meta
local SCRIPT_VERSION = "22.1"
local SCRIPT_NAME = "Phantom Ball LOGIC"

-- services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")

-- constants
local now = os.clock
local INF = math.huge
local V3ZERO = Vector3.new(0, 0, 0)
local DEFAULT_CPS = 25

-- state
local State = {active = true, conns = {}, charConns = {}}

-- bootstrap
function Utils.bootstrap(cfg)
    cfg = cfg or {}
    if type(_G.PhantomConfig) ~= "table" then
        _G.PhantomConfig = {}
    end
    local seed = {
        AutoParry = true,
        ManualSpam = false,
        AutoClash = true,
        SpamRateMode = "CPF",
        CPS = 4,
        CustomCPS = false,
        Keybind = Enum.KeyCode.F9,
        SpamKeybind = Enum.KeyCode.F,
        SpamMode = "Toggle"
    }
    for k, v in pairs(seed) do
        if _G.PhantomConfig[k] == nil then
            _G.PhantomConfig[k] = (cfg[k] ~= nil) and cfg[k] or v
        end
    end
    _G.PhantomState = State
    _G.PhantomManual = _G.PhantomManual == true
    _G.PhantomAutoClash = _G.PhantomAutoClash ~= false
    _G.PhantomModuleURLs = cfg.ModuleURLs or {}
    return _G.PhantomConfig
end

-- track
function Utils.track(c)
    if c and c.Disconnect then
        State.conns[#State.conns + 1] = c
    end
    return c
end

-- trackCharacter
function Utils.trackCharacter(c)
    if c and c.Disconnect then
        State.charConns[#State.charConns + 1] = c
    end
    return c
end

-- disconnectCharacterConnections
function Utils.disconnectCharacterConnections()
    for i = #State.charConns, 1, -1 do
        local c = State.charConns[i]
        State.charConns[i] = nil
        if c then
            pcall(c.Disconnect, c)
        end
    end
end

-- CONFIG_KEYS
local CONFIG_KEYS = {
    "AutoParry",
    "AutoClash",
    "CPS",
    "SpamRateMode",
    "CustomCPS",
    "Keybind",
    "SpamKeybind",
    "SpamMode"
}

-- applyConfig
function Utils.applyConfig(target)
    local source = _G.PhantomConfig
    if type(source) ~= "table" or type(target) ~= "table" then
        return
    end
    for _, key in ipairs(CONFIG_KEYS) do
        if source[key] ~= nil then
            target[key] = source[key]
        end
    end
    target.CPS = math.clamp(tonumber(target.CPS) or DEFAULT_CPS, 1, 1000)
    target.SpamRateMode = (target.SpamRateMode == "CPF") and "CPF" or "CPS"
    target.SpamMode = (target.SpamMode == "Hold") and "Hold" or "Toggle"
end

-- getters
function Utils.getState()
    return State
end
function Utils.getPlayers()
    return Players
end
function Utils.getRunService()
    return RunService
end
function Utils.getReplicated()
    return Replicated
end
function Utils.getUIS()
    return UIS
end
function Utils.getLocalPlayer()
    return Players.LocalPlayer
end
function Utils.now()
    return now
end
function Utils.INF()
    return INF
end
function Utils.V3ZERO()
    return V3ZERO
end
function Utils.version()
    return SCRIPT_VERSION
end
function Utils.name()
    return SCRIPT_NAME
end
function Utils.defaultCps()
    return DEFAULT_CPS
end

-- stop
local function stop()
    State.active = false
    Utils.disconnectCharacterConnections()
    for i = #State.conns, 1, -1 do
        local c = State.conns[i]
        State.conns[i] = nil
        if c then
            pcall(c.Disconnect, c)
        end
    end
    _G.PhantomManual = false
    _G.__phantomGUI_loaded = nil
    _G.__phantomGUI_src = nil
    _G.PhantomDiag = nil
end

_G.PhantomStop = stop

return Utils
