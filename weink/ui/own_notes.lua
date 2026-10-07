-- Current-book cloud note manager. No writes to KOReader notes or public overlays.
local UIManager = require("ui/uimanager")
local NotesView = require("weink.ui.own_notes_view")
local ConfirmBox = require("ui/widget/confirmbox")
local Notes = require("weink.lib.own_notes")
local BookReviews = require("weink.lib.book_reviews")
local PluginUtil = require("weink.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local M = {}

local function kind_label(note)
    return note.kind == "bookmark" and _("My underline") or _("My thought")
end

local function chapter_label(session, note)
    local title = note.chapter_title ~= "" and note.chapter_title or session.chapters[note.chapter_uid]
    return title or T(_("Chapter %1"), note.chapter_uid ~= "" and note.chapter_uid or "?")
end

local function current(session)
    local plugin = session.plugin
    local doc = plugin.ui and plugin.ui.document
    if not doc or doc.file ~= session.path or plugin._reader_session_gen ~= session.reader_generation then
        return false
    end
    local binding = plugin:_annotationBinding()
    return binding and tostring(binding.book_id) == session.book_id
        and tostring(plugin.client:eink_credentials() or "") == session.vid
end

local function guard(session)
    assert(current(session), _("Book or account changed. Reopen My underlines/thoughts."))
end

local function run(session, label, action)
    if session.running then return end
    session.running = true
    session.plugin:showBusy(label)
    local started = session.plugin:runOnlineTask(label, function()
        local ok, err = pcall(function()
            guard(session)
            action()
        end)
        session.running = false
        session.plugin:closeBusy()
        if not ok then
            session.plugin:showInfo(T(_("%1 failed:\n%2"), label, PluginUtil.display_error(err)))
        end
    end)
    if started == false then
        session.running = false
        session.plugin:closeBusy()
    end
end

local render, load

local function fetch(session, more)
    guard(session)
    local client = session.plugin.client
    local bookmarks, chapters = session.items, session.chapters
    if not more then
        local data = client:eink_bookmarklist(session.book_id, true)
        guard(session)
        bookmarks = Notes.bookmarks(data, session.book_id, session.vid)
        chapters = {}
        for _, chapter in ipairs(data.chapters or {}) do
            if type(chapter) == "table" and chapter.chapterUid and type(chapter.title) == "string" then
                chapters[tostring(chapter.chapterUid)] = chapter.title
            end
        end
    end
    local cursor = more and session.cursor or 0
    local data = client:eink_own_reviews(session.book_id, cursor)
    guard(session)
    local rows, has_more, next_cursor, removed = Notes.review_page(data, session.book_id, session.vid, cursor)
    -- Commit a whole successful page; a failed refresh retains the displayed list.
    if more and has_more then
        assert(not session.cursors[next_cursor], _("Thought pagination did not advance. Refresh and retry."))
    end
    session.items = Notes.merge(bookmarks, rows, removed)
    session.chapters, session.more, session.cursor = chapters, has_more, next_cursor
    if not more then session.cursors = {} end
    if next_cursor then session.cursors[next_cursor] = true end
end

local function confirm_delete(session, note)
    if session.running then return end
    if not current(session) then
        session.plugin:showInfo(_("Book or account changed. Reopen My underlines/thoughts."))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete this %1 from WeRead cloud? This cannot be undone.\n\n%2\n\nOnly this record will be deleted. KOReader notes and downloaded public underlines/thoughts are not changed."),
            kind_label(note), BookReviews.preview(note.content ~= "" and note.content or note.quote, 160)),
        ok_text = _("Delete from WeRead"),
        ok_callback = function()
            run(session, _("Deleting cloud note..."), function()
                -- Recheck after confirmation AND after the deferred online callback.
                guard(session)
                local found = false
                for _, row in ipairs(session.items) do if row == note then found = true; break end end
                assert(found, _("Note list changed. Refresh and retry."))
                Notes.delete(session.plugin.client, note, session.book_id, session.vid)
                guard(session)
                -- Success only: remove the selected kind/id, never the paired quote/thought.
                for index, row in ipairs(session.items) do
                    if row == note then table.remove(session.items, index); break end
                end
                local ok, err = pcall(fetch, session, false)
                if current(session) then render(session) end
                if not ok then
                    session.plugin:showInfo(T(_("Deleted from WeRead, but refresh failed:\n%1\nUse Refresh to reload the cloud list."),
                        PluginUtil.display_error(err)))
                end
            end)
        end,
    })
end

render = function(session)
    local records = {}
    for _, note in ipairs(session.items) do
        local metadata = chapter_label(session, note)
        local date = BookReviews.format_date(note.create_time)
        if date ~= "" then metadata = date .. " · " .. metadata end
        if note.kind == "bookmark" then metadata = kind_label(note) .. " · " .. metadata end
        records[#records + 1] = { note = note, metadata = metadata }
    end
    if session.menu then UIManager:close(session.menu) end
    session.menu = NotesView.show{
        title = _("My underlines/thoughts") .. " · " .. session.title,
        records = records, more = session.more,
        on_refresh = function() load(session, false) end,
        on_more = function() load(session, true) end,
        on_delete = function(note) confirm_delete(session, note) end,
    }
end

load = function(session, more)
    run(session, _("Loading my underlines/thoughts..."), function()
        fetch(session, more)
        render(session)
    end)
end

function M.show(plugin)
    local binding = plugin:_annotationBinding()
    if not binding then
        plugin:showInfo(_("Match this local book with a WeRead book first."))
        return
    end
    if not plugin:requireLogin() then return end
    local vid = plugin.client:eink_credentials()
    if not vid then return end
    local session = {
        plugin = plugin, book_id = tostring(binding.book_id), vid = tostring(vid),
        title = binding.title or tostring(binding.book_id), path = plugin.ui.document.file,
        reader_generation = plugin._reader_session_gen,
        items = {}, chapters = {}, cursors = {}, cursor = 0,
    }
    load(session, false)
    return session
end

return M
