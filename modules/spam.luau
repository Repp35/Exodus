-- [[ spam ]]

local Spam = {}

local Probe, AutoClash, Utils
local _fps, _heartbeat
local EMA = 0.08

local function tick(dt)
    local cfg = Utils.getConfig()
    if type(cfg) ~= "table" then return end
    if not Utils.isManualSpamActive() and not (AutoClash and AutoClash.clashOn()) then return end
    if type(dt) ~= "number" or dt <= 0 then return end

    local fpsNow = 1 / dt
    _fps = _fps and (_fps + (fpsNow - _fps) * EMA) or fpsNow

    local cpf = math.max(tonumber(cfg.CPS) or 1, 1)
    local fps = math.max(_fps or fpsNow, 1)
    local clicks = cpf * math.max(60, fps) / fps

    for _ = 1, math.floor(clicks) do Probe.fireParry(1) end
end

function Spam.setup(deps)
    Probe, AutoClash, Utils = deps.Probe, deps.AutoClash, deps.Utils
    if _heartbeat then pcall(function() _heartbeat:Disconnect() end) end
    _heartbeat = Utils.getRunService().Heartbeat:Connect(tick)
    Utils.track(_heartbeat)
end

function Spam.tick(dt)   tick(dt) end
function Spam.resetState() _fps = nil end

if _G.ExodusModules then _G.ExodusModules.Spam = Spam end
return Spam
