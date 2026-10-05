package.path = "./?.lua;" .. package.path

package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://reader/" .. tostring(book_id) .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["bit"] = function() return { rshift = function(value, bits) return math.floor(value / 2 ^ bits) end } end
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["ffi/util"] = function() return {} end

local zip_calls = 0
package.preload["weread.lib.eink"] = function()
    return {
        build_chapters_param = function(uids) return table.concat(uids, "-") end,
        files_to_chapter_bodies = function(files, chapters)
            local bodies = {}
            for _, chapter in ipairs(chapters or {}) do
                local uid = tostring(chapter.chapterUid)
                bodies[uid] = files[uid]
            end
            return bodies, {}
        end,
    }
end

local Content = require("weread.lib.content")
Content.ensure_eink_chapter_files = function(_client, _book, chapters)
    return chapters
end

local client = {
    can_eink_download = function() return true end,
    eink_download_zip = function(_self, _book_id, param)
        zip_calls = zip_calls + 1
        if param == "1" then return { ["1"] = "<p>one</p>" } end
        if param == "2" then return { ["2"] = "<p>two</p>" } end
        error("unexpected chapters param " .. tostring(param))
    end,
}
local settings = {
    get = function() return { download_book_images = false } end,
}
local book = { book_id = "book" }

assert(Content.fetch_single_chapter_source(client, settings, book,
    { chapterUid = 1 }, {}) == "<p>one</p>", "first chapter failed")
assert(Content.fetch_single_chapter_source(client, settings, book,
    { chapterUid = 2 }, {}) == "<p>two</p>", "second chapter failed")
assert(zip_calls == 2, "each missing chapter uses eink zip")

local ok, err = pcall(Content.fetch_single_chapter_source, {
    can_eink_download = function() return false end,
}, settings, book, { chapterUid = 1 }, {})
assert(not ok and tostring(err):find("eink download is not available", 1, true),
    "missing eink login does not fall back to web shards")

print("content_reader_state_reuse_spec: passed")
