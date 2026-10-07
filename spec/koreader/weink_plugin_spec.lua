-- This file is copied into KOReader's spec/front/unit tree by
-- scripts/run_koreader_integration.sh and runs with KOReader's own Busted setup.

describe("WeRead plugin integration", function()
    local original_package_path
    before_each(function() original_package_path = package.path end)
    after_each(function() package.path = original_package_path end)

    setup(function()
        require("commonrequire")
        disable_plugins()
    end)

    it("is discovered and loaded by KOReader PluginLoader", function()
        load_plugin("weink.koplugin")

        local PluginLoader = require("pluginloader")
        local plugin
        for _, candidate in ipairs(PluginLoader.enabled_plugins) do
            if candidate.name == "weink" then
                plugin = candidate
                break
            end
        end

        assert.is_table(plugin)
        assert.equals("weink", plugin.name)
        assert.equals("WeRead", plugin.fullname)
        assert.is_false(plugin.is_doc_only)
        assert.matches("weink%.koplugin$", plugin.path)
    end)

    it("lays out personal quotes and thoughts with real scrollable widgets", function()
        load_plugin("weink.koplugin")
        -- PluginLoader restores package.path after discovery. Direct component
        -- tests must provide the same plugin-local paths as runtime loading.
        package.path = "plugins/weink.koplugin/?.lua;plugins/weink.koplugin/?/init.lua;" .. package.path
        local Screen = require("device").screen
        local Blitbuffer = require("ffi/blitbuffer")
        local UIManager = require("ui/uimanager")
        local View = require("weink.ui.own_notes_view")
        local note = { kind = "review", quote = string.rep("Quoted paragraph.\n", 100),
            content = string.rep("My thought.\n", 100) }
        local selected
        local view = View.show{
            title = "Personal notes · Book", records = { { note = note, metadata = "2026-10-06 · Chapter" } },
            on_refresh = function() end,
            on_delete = function(row) selected = row end,
        }
        local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight(), Blitbuffer.TYPE_BB8)
        view:paintTo(bb, 0, 0)
        local block = view._blocks[1]
        assert.is_true(block.quote:getSize().h > view.scroll.dimen.h)
        assert.is_true(block.thought.dimen.y > block.quote.dimen.y)
        assert.equals(note.content, block.thought.text)
        view:onNextPage()
        assert.is_true(view.scroll:getScrolledOffset().y > 0)
        view:paintTo(bb, 0, 0)
        view:onPrevPage()
        assert.equals(0, view.scroll:getScrolledOffset().y)
        block.delete.callback()
        assert.equals(note, selected)
        UIManager:close(view)
        bb:free()
    end)

    it("loads its startup module through the weread namespace", function()
        -- Client, settings and menu load only when the user opens Protocol.
        -- PluginLoader discovery itself requires path_index from main.lua.
        assert.is_table(package.loaded["weink.lib.path_index"])
        assert.is_nil(package.loaded["lib.path_index"])
    end)
end)
