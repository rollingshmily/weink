std = "luajit"

globals = {
    "G_defaults",
    "G_reader_settings",
    "G_reader_ui",
}

-- KOReader callbacks intentionally leave some arguments unused, and a few
-- compatibility branches are deliberately empty.
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
    "581", -- preserve explicit boolean expressions used by menu callbacks
}

max_line_length = false

files["weink/lib/client.lua"] = {
    ignore = { "211/_status" },
}

files["weink/lib/content.lua"] = {
    ignore = {
        "211/normalize_void_elements",
        "431/bit",
    },
}

files["weink/lib/i18n.lua"] = {
    -- Translation catalogs intentionally repeat a key in two grouped sections.
    ignore = { "314" },
}

files["weink/lib/plugin_util.lua"] = {
    ignore = { "143/table" },
}

files["weink/lib/progress_sync.lua"] = {
    ignore = {
        "211/_reason",
        "231/_index",
    },
}

files["weink/lib/protocol.lua"] = {
    ignore = { "311/width" },
}

files["weink/lib/reader_lifecycle.lua"] = {
    ignore = {
        "211/current_ch",
        "211/_started",
        "211/_title",
    },
}

files["weink/ui/annotations_controller.lua"] = {
    ignore = {
        "211/Annotations",
        "211/_current_idx",
    },
}

files["weink/ui/reader_navigation.lua"] = {
    ignore = { "211/current_ch" },
}

files["spec/scan_spec.lua"] = {
    ignore = { "211/d_added" },
}

files["spec/koreader/*.lua"] = {
    globals = {
        "describe",
        "setup",
        "it",
        "disable_plugins",
        "load_plugin",
    },
}
