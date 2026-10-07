-- Exercise the callback wired by the real runtime, not a copied calculation.
package.path = "./?.lua;./?/init.lua;" .. package.path
local original_require = require
local captured
local generic = { new = function() return {} end }
local stubs = {
    ["ui/event"] = { new = function(_, name, percent) return { name = name, percent = percent } end },
    ["weink.lib.progress_sync"] = { new = function(_, options) captured = options; return {} end },
    ["weink.lib.plugin_util"] = { tr = function(v) return v end },
    ["weink.lib.logger"] = { info = function() end },
    ["integrations.init"] = { register = function() end },
}
-- All boot services except the runtime under test are isolated (no settings,
-- accounts, filesystem writes or network are touched).
_G.require = function(name) return stubs[name] or generic end
local Runtime = dofile("weink/lib/plugin_runtime.lua")
_G.require = original_require
Runtime.mixins_applied = true
Runtime.services = {}
local received
local plugin = { onDispatcherRegisterActions = function() end, ui = { rolling = {
    onGotoPercent = function(_, percent) received = percent end,
} } }
Runtime.boot(plugin)
local checks = 0
for _, case in ipairs({
    { 0.44678535854103, 44.678535854103 }, { 0, 0 }, { 1, 100 },
    { -0.1, 0 }, { 1.1, 100 }, { 0.000001, 0.0001 },
}) do
    assert(captured.goto_fraction(case[1]))
    assert(math.abs(received - case[2]) < 1e-12)
    checks = checks + 1
end
plugin.ui = { handleEvent = function(_, event)
    assert(event.name == "GotoPercent")
    received = event.percent
end }
assert(captured.goto_fraction(0.44678535854103))
assert(math.abs(received - 44.678535854103) < 1e-12)
plugin.ui = { rolling = { onGotoXPointer = function(_, xp) received = xp end } }
assert(captured.goto_xpointer("/body/p[9]"))
assert(received == "/body/p[9]")
plugin.ui = { handleEvent = function(_, event)
    assert(event.name == "GotoXPointer")
    received = event.percent
end }
assert(captured.goto_xpointer("/body/p[10]"))
assert(received == "/body/p[10]")
checks = checks + 4
plugin.ui = nil
assert(not captured.goto_xpointer("/body/p[10]"))
assert(not captured.goto_fraction(0.5))
print(("plugin_runtime_progress_spec: %d checks"):format(checks + 2))
