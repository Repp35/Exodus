-- [[ utils ]]

local Utils = {}

local PlayersService       = game:GetService("Players")
local ReplicatedStorageSvc = game:GetService("ReplicatedStorage")
local RunServiceSvc        = game:GetService("RunService")
local UserInputServiceSvc  = game:GetService("UserInputService")

local SCRIPT_VERSION = "22.3"
local SCRIPT_NAME    = "Phantom Ball LOGIC"

local State = {
    active               = false,
    connections           = {},
    characterConnections  = {},
    config                = {},
    moduleURLs            = {},
    manualSpamActive      = false,
    guiLoaded             = false,
    guiSource             = "",
    diagnostics           = { lastPush = 0 },
}

local _onClashOn, _onTarget, _onTeleport

-- ── internals ────────────────────────────────────────────────────────────────

local function disconnectAll(list)
    for i = #list, 1, -1 do
        local c = list[i]
        list[i] = nil
        if c then pcall(function() c:Disconnect() end) end
    end
end

local function track(list, c)
    if c and type(c.Disconnect) == "function" then
        list[#list + 1] = c
    end
    return c
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function Utils.start()
    State.active = true
    _G.PhantomState = State
    if _G.PhantomManual       == nil then _G.PhantomManual       = false end
    if _G.PhantomAutoClash     == nil then _G.PhantomAutoClash     = true end
    if _G.PhantomClashOn       == nil then _G.PhantomClashOn       = function() return false end end
    if _G.PhantomOnTarget      == nil then _G.PhantomOnTarget      = function() end end
    if _G.PhantomOnTeleport    == nil then _G.PhantomOnTeleport    = function() end end
    if _G.PhantomOnBurst       == nil then _G.PhantomOnBurst       = function() end end
    return State
end

function Utils.stop()
    State.active = false
    disconnectAll(State.characterConnections)
    disconnectAll(State.connections)
    State.manualSpamActive = false
    _G.PhantomManual = false
    State.guiLoaded = false
    State.guiSource = ""
    State.diagnostics = { lastPush = 0 }
end

function Utils.isActive()             return State.active end
function Utils.getState()             return State end
function Utils.getConfig()            return State.config end
function Utils.getModuleURLs()        return State.moduleURLs end
function Utils.isManualSpamActive()   return State.manualSpamActive end
function Utils.isGUILoaded()          return State.guiLoaded end
function Utils.getGUISource()         return State.guiSource end
function Utils.getDiagnosticsState()  return State.diagnostics end

function Utils.setConfig(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do State.config[k] = v end
    if type(_G.PhantomConfig) ~= "table" then _G.PhantomConfig = {} end
    for k, v in pairs(t) do
        if k ~= "ModuleURLs" and k ~= "HttpFetch" then
            _G.PhantomConfig[k] = v
        end
    end
    if type(t.ModuleURLs) == "table" then
        Utils.setModuleURLs(t.ModuleURLs)
    end
end

function Utils.setModuleURLs(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do State.moduleURLs[k] = v end
    _G.PhantomModuleURLs = State.moduleURLs
end

function Utils.setManualSpamActive(v)
    State.manualSpamActive = v == true
    _G.PhantomManual = State.manualSpamActive
end

function Utils.setGUILoaded(v) State.guiLoaded = v == true end
function Utils.setGUISource(s) State.guiSource = type(s) == "string" and s or "" end

function Utils.track(c)            return track(State.connections, c) end
function Utils.trackCharacter(c)  return track(State.characterConnections, c) end
function Utils.disconnectCharacterConnections() disconnectAll(State.characterConnections) end

-- ── services ─────────────────────────────────────────────────────────────────

function Utils.getPlayers()           return PlayersService end
function Utils.getReplicatedStorage() return ReplicatedStorageSvc end
function Utils.getRunService()        return RunServiceSvc end
function Utils.getUserInputService()  return UserInputServiceSvc end
function Utils.getLocalPlayer()       return PlayersService.LocalPlayer end
function Utils.now()                  return os.clock() end

function Utils.version()      return SCRIPT_VERSION end
function Utils.name()         return SCRIPT_NAME end
function Utils.defaultCps()   return 4 end

-- ── hooks ────────────────────────────────────────────────────────────────────

function Utils.isClashActive()
    if not _onClashOn then return false end
    local ok, v = pcall(_onClashOn)
    return ok and v == true
end

function Utils.setOnClashOn(fn) _onClashOn = type(fn) == "function" and fn or nil end

function Utils.onTarget(newTarget, t)
    if _onTarget then return pcall(_onTarget, newTarget, t) end
    return true
end

function Utils.setOnTarget(fn) _onTarget = type(fn) == "function" and fn or nil end

function Utils.onTeleport()
    if _onTeleport then return pcall(_onTeleport) end
    return true
end

function Utils.setOnTeleport(fn) _onTeleport = type(fn) == "function" and fn or nil end

_G.PhantomStop = Utils.stop

if _G.ExodusModules then _G.ExodusModules.Utils = Utils end
return Utils
