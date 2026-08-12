-- [[ probe ]]

local Probe = {}

local _ballSyncConn    = nil
local _ballSyncRemote  = nil
local _parryR          = nil
local _parryInit       = false
local _hooked          = false

local _oldNamecall
local _oldIndex

local function registerRemote(remote)
    if not _parryR then _parryR = remote end
end

-- ── parry remote ─────────────────────────────────────────────────────────────

function Probe.fireParry(flag)
    if not _parryR then return false end
    local payload
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        payload = buffer.fromstring(flag == 2 and "\x02" or "\x01")
    else
        payload = flag == 2 and "\x02" or "\x01"
    end
    local ok = pcall(function() _parryR:FireServer(payload) end)
    return ok
end

function Probe.initParry()
    if not _parryR or _parryInit then return _parryInit end
    local payload = (type(buffer) == "table" and type(buffer.fromstring) == "function")
        and buffer.fromstring("\x02") or "\x02"
    local ok = pcall(function() _parryR:FireServer(payload) end)
    _parryInit = ok
    return ok
end

function Probe.getRemote()    return _parryR end
function Probe.resolveRemote() return _parryR end
function Probe.invalidate()    _parryR = nil; _parryInit = false end
function Probe.setRemote(remote)
    _parryR, _parryInit = remote, false
    return true
end

-- ── hooks ────────────────────────────────────────────────────────────────────

function Probe.setup()
    if _hooked then return end
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
                    registerRemote(self)
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
                    task.spawn(registerRemote, self)
                end
            end
            return _oldIndex(self, key)
        end)
    end)
    if ok then _hooked = true end
end

-- ── ball sync ────────────────────────────────────────────────────────────────

function Probe.bindBallSync(handler, trackFn)
    if type(handler) ~= "function" then return false end
    local Replicated = game:GetService("ReplicatedStorage")
    local Remotes    = Replicated:FindFirstChild("Remotes")
    local candidate  = Remotes and Remotes:FindFirstChild("BallSyncData")

    if not (candidate and candidate:IsA("RemoteEvent")) then
        return _ballSyncConn ~= nil and _ballSyncConn.Connected
    end
    if _ballSyncConn and _ballSyncConn.Connected and _ballSyncRemote == candidate then
        return true
    end
    if _ballSyncConn then pcall(function() _ballSyncConn:Disconnect() end) end

    local conn = candidate.OnClientEvent:Connect(handler)
    _ballSyncConn   = conn
    _ballSyncRemote = candidate
    if type(trackFn) == "function" then trackFn(conn) end
    return true
end

if _G.ExodusModules then _G.ExodusModules.Probe = Probe end
return Probe
