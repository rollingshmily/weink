-- This file is copied into KOReader's spec/front/unit tree by
-- scripts/run_koreader_integration.sh and runs with KOReader's own Busted setup.

describe("WeRead plugin integration", function()
    setup(function()
        require("commonrequire")
        disable_plugins()
    end)

    it("is discovered and loaded by KOReader PluginLoader", function()
        load_plugin("weread.koplugin")

        local PluginLoader = require("pluginloader")
        local plugin
        for _, candidate in ipairs(PluginLoader.enabled_plugins) do
            if candidate.name == "weread" then
                plugin = candidate
                break
            end
        end

        assert.is_table(plugin)
        assert.equals("weread", plugin.name)
        assert.equals("WeRead", plugin.fullname)
        assert.is_false(plugin.is_doc_only)
        assert.matches("weread%.koplugin$", plugin.path)
    end)

    it("loads its startup module through the weread namespace", function()
        -- Client, settings and menu load only when the user opens WeRead.
        -- PluginLoader discovery itself requires path_index from main.lua.
        assert.is_table(package.loaded["weread.lib.path_index"])
        assert.is_nil(package.loaded["lib.path_index"])
    end)
end)
