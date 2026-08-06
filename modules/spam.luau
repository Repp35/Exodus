--[[ spam ]]

local Spam = {}
local Probe, AutoClash, Utils

local _fps = nil
local EMA = 0.08

local function tick(dt)
    local cfg = Utils.getConfig()

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
        Probe.fireParry(1)
    end
end

function Spam.setup(deps)
    Probe = deps.Probe
    AutoClash = deps.AutoClash
    Utils = deps.Utils
end

function Spam.tick(dt)
    tick(dt)
end

function Spam.resetState()
    _fps = nil
end

if _G.ExodusModules then
    _G.ExodusModules.Spam = Spam
end

return Spam