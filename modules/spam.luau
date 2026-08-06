--[[ spam ]]

local Spam = {}

-- dependências
local Utils

-- estado
local _fps = nil
local EMA = 0.08

-- módulos
local function getProbe()
	return Utils.getModule("Probe")
end
local function getAutoClash()
	return Utils.getModule("AutoClash")
end

-- tick
local function tick(dt)
	local cfg = Utils.getConfig()
	local AutoClash = getAutoClash()
	local Probe = getProbe()

	if not cfg or (not Utils.isManualSpamActive() and not (AutoClash and AutoClash.clashOn())) then
		return
	end

	local fpsNow = 1 / dt

	if not _fps then
		_fps = fpsNow
	else
		_fps = _fps + (fpsNow - _fps) * EMA
	end

	local cpf = math.max(tonumber(cfg.CPS) or 1, 1)
	local clicks = cpf * math.max(60, _fps) / _fps

	for i = 1, math.floor(clicks) do
		if Probe then
			Probe.fireParry(1)
		end
	end
end

-- setup
function Spam.setup(u)
	Utils = u
end

-- api
function Spam.tick(dt)
	tick(dt)
end

function Spam.resetState()
	_fps = nil
end

function Spam.fps()
	return _fps or 60
end

if _G.ExodusModules then
	_G.ExodusModules.Spam = Spam
end

return Spam
