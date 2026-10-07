-- Optional integrations with third-party KOReader interfaces.

local logger = require("weink.lib.logger")

local Integrations = {}
local modules = {
    require("integrations.zenui"),
}

function Integrations.register(plugin)
    for _i, integration in ipairs(modules) do
        local ok, err = pcall(function()
            integration:register(plugin)
        end)
        if not ok then
            logger.warn("weink: failed to register integration:",
                integration.name, tostring(err))
        end
    end
end

function Integrations.onZenUIReady(plugin)
    for _i, integration in ipairs(modules) do
        if integration.onZenUIReady then
            local ok, err = pcall(function()
                integration:onZenUIReady(plugin)
            end)
            if not ok then
                logger.warn("weink: ZenUIReady integration failed:",
                    integration.name, tostring(err))
            end
        end
    end
end

return Integrations
