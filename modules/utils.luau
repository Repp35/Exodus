--[[ utils ]]

local Utils = {}

-- serviços
local PlayersService = game:GetService("Players")
local ReplicatedStorageService = game:GetService("ReplicatedStorage")
local RunServiceService = game:GetService("RunService")
local UserInputServiceService = game:GetService("UserInputService")

-- estado
local State = {
	active = false,
	connections = {},
	characterConnections = {},
	config = {},
	manualSpamActive = false,
	guiLoaded = false,
	guiSource = "",
}

-- hub
Utils.Modules = {}

-- callbacks
local _onClashOn = nil
local _onTarget = nil
local _onTeleport = nil

-- limpeza
local function disconnectAll(connections)
	for index = #connections, 1, -1 do
		local connection = connections[index]
		connections[index] = nil
		if connection then
			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

local function track(connections, connection)
	if connection and type(connection.Disconnect) == "function" then
		connections[#connections + 1] = connection
	end
	return connection
end

-- registro
function Utils.registerModule(name, module)
	Utils.Modules[name] = module
	return module
end

function Utils.getModule(name)
	local mod = Utils.Modules[name]
	if not mod then
		if _G.ExodusModules and _G.ExodusModules[name] then
			mod = _G.ExodusModules[name]
			Utils.Modules[name] = mod
		end
	end
	return mod
end

-- ciclo de vida
function Utils.start()
	State.active = true
	_G.PhantomState = State
	if _G.PhantomManual == nil then
		_G.PhantomManual = false
	end
	return State
end

function Utils.stop()
	State.active = false
	disconnectAll(State.characterConnections)
	disconnectAll(State.connections)
	State.manualSpamActive = false
	State.guiLoaded = false
	State.guiSource = ""
end

function Utils.isActive()
	return State.active
end

function Utils.getState()
	return State
end

function Utils.getConfig()
	return State.config
end

function Utils.isManualSpamActive()
	return State.manualSpamActive
end

-- setters
function Utils.setConfig(configTable)
	if type(configTable) ~= "table" then
		return
	end
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
end

function Utils.setManualSpamActive(value)
	State.manualSpamActive = value
	_G.PhantomManual = value
end

function Utils.setGUILoaded(value)
	State.guiLoaded = value
end

function Utils.setGUISource(source)
	State.guiSource = source
end

function Utils.track(connection)
	return track(State.connections, connection)
end

function Utils.trackCharacter(connection)
	return track(State.characterConnections, connection)
end

-- api serviços
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

-- utilitários
function Utils.now()
	return os.clock()
end

function Utils.defaultCps()
	return 4
end

function Utils.isClashActive()
	if _onClashOn then
		return _onClashOn()
	end
	local AutoClash = Utils.getModule("AutoClash")
	return AutoClash and AutoClash.clashOn() or false
end

function Utils.setOnClashOn(callback)
	_onClashOn = callback
end

function Utils.onTarget(newTarget, t)
	if _onTarget then
		_onTarget(newTarget, t)
	end
end

function Utils.setOnTarget(callback)
	_onTarget = callback
end

function Utils.onTeleport()
	if _onTeleport then
		_onTeleport()
	end
end

function Utils.setOnTeleport(callback)
	_onTeleport = callback
end

-- exportação
_G.PhantomStop = Utils.stop

if _G.ExodusModules then
	_G.ExodusModules.Utils = Utils
end

return Utils
