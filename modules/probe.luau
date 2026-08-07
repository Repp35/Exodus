-- [[ probe ]]

local Probe = {}
local _ballSyncConn = nil
local _ballSyncRemote = nil

local parryR
local parryMode = "buffer"
local parryInit = false

local _hooked = false
local _oldNamecall
local _oldIndex

-- remote
local function RegisterRemote(remote)
    if not parryR then
        parryR = remote
    end
end

function Probe.fireParry(flag)
    if not parryR then
        return false
    end

    local p
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        p = buffer.fromstring(flag == 2 and "\x02" or "\x01")
    else
        p = (flag == 2 and "\x02" or "\x01")
    end

    local ok = pcall(function()
        parryR:FireServer(p)
    end)
    return ok
end

function Probe.initParry()
    if not parryR or parryInit then
        return parryInit
    end

    local p
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        p = buffer.fromstring("\x02")
    else
        p = "\x02"
    end

    local ok = pcall(function()
        parryR:FireServer(p)
    end)
    parryInit = ok
    return ok
end

-- setup
function Probe.setup()
    if _hooked then
        return
    end

    local ok = pcall(function()
        if type(hookmetamethod) ~= "function" then return end
        
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local args = { ... }

            if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                local isPayload = false

                if args[1] then
                    if typeof(args[1]) == "buffer"
                        or (typeof(args[1]) == "string" and (string.find(args[1], "\x01") or string.find(args[1], "\x02"))) then
                        isPayload = true
                    end
                end

                if isPayload or self.Name == "RemoteEvent" then
                    RegisterRemote(self)
                end
            end

            return _oldNamecall(self, ...)
        end)

        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if not checkcaller()
                and (key == "FireServer" or key == "fireServer")
                and typeof(self) == "Instance"
                and self:IsA("RemoteEvent") then

                if self.Name == "RemoteEvent"
                    or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                    task.spawn(function()
                        RegisterRemote(self)
                    end)
                end
            end

            return _oldIndex(self, key)
        end)
    end)

    if ok then _hooked = true end
end

function Probe.getRemote()
    return parryR, parryMode
end

function Probe.resolveRemote()
    return parryR
end

function Probe.invalidateRemote()
    parryR = nil
    parryInit = false
end

function Probe.invalidate()
    Probe.invalidateRemote()
end

function Probe.setRemote(remote, mode)
    parryR = remote
    parryMode = mode or "buffer"
    parryInit = false
    return true
end

-- sync
function Probe.bindBallSync(handler, track)
    if type(handler) ~= "function" then return false end

    local Replicated = game:GetService("ReplicatedStorage")
    local Remotes = Replicated:FindFirstChild("Remotes")
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")

    if not (candidate and candidate:IsA("RemoteEvent")) then
        return _ballSyncConn ~= nil and _ballSyncConn.Connected
    end
    if _ballSyncConn and _ballSyncConn.Connected and _ballSyncRemote == candidate then
        return true
    end
    if _ballSyncConn then
        pcall(function() _ballSyncConn:Disconnect() end)
    end

    local conn = candidate.OnClientEvent:Connect(handler)
    _ballSyncConn = conn
    _ballSyncRemote = candidate
    if type(track) == "function" then track(conn) end
    return true
end

if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

return Probe
