--[[
    probe.luau
    Remote handling module for Exodus
    Method: Invisible Hub Implementation
]]

local Probe = {}

local parryR
local parryMode = "buffer"
local parryInit = false

local _hooked = false
local _oldNamecall
local _oldIndex

local function RegisterRemote(remote)
    if not parryR then
        parryR = remote
    end
end

function Probe.fireParry(flag)
    if not parryR then
        return false
    end

    parryR:FireServer(buffer.fromstring(flag == 2 and "\x02" or "\x01"))
    return true
end

function Probe.initParry()
    if not parryR then
        return false
    end

    parryR:FireServer(buffer.fromstring("\x02"))
    parryInit = true
    return true
end

function Probe.setup()
    if _hooked then
        return
    end

    _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        local args = { ... }

        if not checkcaller() and (method == "FireServer" or method == "fireServer") then
            local isPayload = false

            if args[1] then
                if typeof(args[1]) == "buffer"
                    or (typeof(args[1]) == "string" and string.find(args[1], "\x01")) then
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

    _hooked = true
end

function Probe.getRemote()
    return parryR, parryMode
end

Probe.resolveRemote = Probe.getRemote

function Probe.invalidateRemote()
    parryR = nil
end

Probe.invalidate = Probe.invalidateRemote

function Probe.setRemote(remote, mode)
    parryR = remote
    parryMode = mode or "buffer"
    return true
end

function Probe.refreshRefs() end

function Probe.listHistory()
    return {}
end

function Probe.readHistory()
    return nil
end

function Probe.probeNamed()
    return parryR
end

function Probe.bindBallSync(handler, track)
    local Replicated = game:GetService("ReplicatedStorage")
    local Remotes = Replicated:FindFirstChild("Remotes")
    local candidate = Remotes and Remotes:FindFirstChild("BallSyncData")

    if not (candidate and candidate:IsA("RemoteEvent")) then
        return false
    end

    track(candidate.OnClientEvent:Connect(handler))
    return true
end

if _G.ExodusModules then
    _G.ExodusModules.Probe = Probe
end

return Probe