-- [[ utils ]]

local Utils = {}


-- services
local PlayersService = game:GetService("Players")
local ReplicatedStorageService = game:GetService("ReplicatedStorage")
local RunServiceService = game:GetService("RunService")
local UserInputServiceService = game:GetService("UserInputService")


local SCRIPT_VERSION = "22.1"
local SCRIPT_NAME = "Phantom Ball LOGIC"


-- state
local State = {
    active = false,
    connections = {},
    characterConnections = {},
    config = {},
    moduleURLs = {},
    manualSpamActive = false,
    guiLoaded = false,
    guiSource = "",
    diagnostics = {lastPush = 0}
}


local _onClashOn = nil
local _onTarget = nil
local _onTeleport = nil

local function disconnectAll(connections)
    for index = #connections, 1, -1 do
        local connection = connections[index]
        connections[index] = nil
        if connection then
            pcall(
                function()
                    connection:Disconnect()
                end
            )
        end
    end
end

local function track(connections, connection)
    if connection and type(connection.Disconnect) == "function" then
        connections[#connections + 1] = connection
    end
    return connection
end


-- lifecycle
function Utils.start()
    State.active = true
    
    
    _G.PhantomState = State
    if _G.PhantomManual == nil then _G.PhantomManual = false end
    if _G.PhantomAutoClash == nil then _G.PhantomAutoClash = true end
    if _G.PhantomClashOn == nil then _G.PhantomClashOn = function() return false end end
    if _G.PhantomOnTarget == nil then _G.PhantomOnTarget = function() end end
    if _G.PhantomOnTeleport == nil then _G.PhantomOnTeleport = function() end end
    if _G.PhantomOnBurst == nil then _G.PhantomOnBurst = function() end end
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
    State.diagnostics = {lastPush = 0}
end

function Utils.isActive()
    return State.active
end


-- getters
function Utils.getState()
    return State
end

function Utils.getConfig()
    return State.config
end

function Utils.getModuleURLs()
    return State.moduleURLs
end

function Utils.isManualSpamActive()
    return State.manualSpamActive
end

function Utils.isGUILoaded()
    return State.guiLoaded
end

function Utils.getGUISource()
    return State.guiSource
end

function Utils.getDiagnosticsState()
    return State.diagnostics
end


-- setters
function Utils.setConfig(configTable)
    if type(configTable) ~= "table" then return end
    for k, v in pairs(configTable) do
        State.config[k] = v
    end
    
    
    if type(_G.PhantomConfig) ~= "table" then
        _G.PhantomConfig = {}
    end
    for k, v in pairs(configTable) do
        if k ~= "ModuleURLs" and k ~= "HttpFetch" then
            _G.PhantomConfig[k] = v
        end
    end
    State.moduleURLs = State.moduleURLs or {}
    if type(configTable.ModuleURLs) == "table" then
        for k, v in pairs(configTable.ModuleURLs) do
            State.moduleURLs[k] = v
        end
        _G.PhantomModuleURLs = State.moduleURLs
    end
end

function Utils.setModuleURLs(urlsTable)
    if type(urlsTable) ~= "table" then return end
    for k, v in pairs(urlsTable) do
        State.moduleURLs[k] = v
    end
    _G.PhantomModuleURLs = State.moduleURLs
end

function Utils.setManualSpamActive(value)
    State.manualSpamActive = value == true
    _G.PhantomManual = State.manualSpamActive
end

function Utils.setGUILoaded(value)
    State.guiLoaded = value == true
end

function Utils.setGUISource(source)
    State.guiSource = type(source) == "string" and source or ""
end

function Utils.track(connection)
    return track(State.connections, connection)
end

function Utils.trackCharacter(connection)
    return track(State.characterConnections, connection)
end

function Utils.disconnectCharacterConnections()
    disconnectAll(State.characterConnections)
end


-- public services
function Utils.getPlayers()
    return PlayersService
end

function Utils.getReplicatedStorage()
    return ReplicatedStorageService
end

function Utils.getRunService()
    return RunServiceService
end

function Utils.getUserInputService()
    return UserInputServiceService
end

function Utils.getLocalPlayer()
    return PlayersService.LocalPlayer
end


-- time
function Utils.now()
    return os.clock()
end


function Utils.version()
    return SCRIPT_VERSION
end

function Utils.name()
    return SCRIPT_NAME
end

function Utils.defaultCps()
    return 4
end

function Utils.isClashActive()
    if not _onClashOn then return false end
    local ok, active = pcall(_onClashOn)
    return ok and active == true
end

function Utils.setOnClashOn(callback)
    _onClashOn = type(callback) == "function" and callback or nil
end

function Utils.onTarget(newTarget, t)
    if _onTarget then
        return pcall(_onTarget, newTarget, t)
    end
    return true
end

function Utils.setOnTarget(callback)
    _onTarget = type(callback) == "function" and callback or nil
end

function Utils.onTeleport()
    if _onTeleport then
        return pcall(_onTeleport)
    end
    return true
end

function Utils.setOnTeleport(callback)
    _onTeleport = type(callback) == "function" and callback or nil
end


_G.PhantomStop = Utils.stop

if _G.ExodusModules then
    _G.ExodusModules.Utils = Utils
end

return Utils
