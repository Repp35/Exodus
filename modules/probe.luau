--[[ probe ]]

local Probe = {}

-- dependências
local Utils
local _ballSyncConn = nil
local parryR = nil
local parryInit = false

-- registro
local function RegisterRemote(remote)
	if not parryR then
		parryR = remote
	end
end

-- disparo
function Probe.fireParry(flag)
	if not parryR then
		return false
	end
	local payload = (flag == 2 and "\x02" or "\x01")
	if type(buffer) == "table" and type(buffer.fromstring) == "function" then
		payload = buffer.fromstring(payload)
	end
	return pcall(function()
		parryR:FireServer(payload)
	end)
end

function Probe.initParry()
	if not parryR or parryInit then
		return parryInit
	end
	local payload = "\x02"
	if type(buffer) == "table" and type(buffer.fromstring) == "function" then
		payload = buffer.fromstring(payload)
	end
	local ok = pcall(function()
		parryR:FireServer(payload)
	end)
	parryInit = ok
	return ok
end

-- hooks
function Probe.setup(u)
	Utils = u
	if type(hookmetamethod) ~= "function" then
		return
	end

	local oldNamecall
	oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
		local method = getnamecallmethod()
		local args = { ... }
		if not checkcaller() and (method == "FireServer" or method == "fireServer") then
			local isPayload = false
			if args[1] then
				local t = typeof(args[1])
				if
					t == "buffer"
					or (t == "string" and (string.find(args[1], "\x01") or string.find(args[1], "\x02")))
				then
					isPayload = true
				end
			end
			if isPayload or self.Name == "RemoteEvent" then
				RegisterRemote(self)
			end
		end
		return oldNamecall(self, ...)
	end)

	local oldIndex
	oldIndex = hookmetamethod(game, "__index", function(self, key)
		if
			not checkcaller()
			and (key == "FireServer" or key == "fireServer")
			and typeof(self) == "Instance"
			and self:IsA("RemoteEvent")
		then
			if self.Name == "RemoteEvent" or (self.Parent and string.find(self.Parent.Name, "Remote")) then
				task.spawn(RegisterRemote, self)
			end
		end
		return oldIndex(self, key)
	end)
end

-- estado
function Probe.getRemote()
	return parryR
end

function Probe.invalidateRemote()
	parryR, parryInit = nil, false
end

-- sincronização
function Probe.bindBallSync(handler, track)
	if _ballSyncConn then
		pcall(function()
			_ballSyncConn:Disconnect()
		end)
		_ballSyncConn = nil
	end
	local candidate = game:GetService("ReplicatedStorage"):FindFirstChild("BallSyncData", true)
	if not (candidate and candidate:IsA("RemoteEvent")) then
		return false
	end
	local conn = candidate.OnClientEvent:Connect(handler)
	_ballSyncConn = conn
	if track then
		track(conn)
	end
	return true
end

return Probe
