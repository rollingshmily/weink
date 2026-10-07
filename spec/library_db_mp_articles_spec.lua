-- Tests for LibraryDB caching of WeRead MP articles (favorites and floating).

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks, failures = 0, 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        print("FAIL " .. (message or ("check " .. checks)))
    end
end

package.preload["weink.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local mock_tables = {
    mp_articles = {
        { review_id = "fav_1", list_type = 1, idx = 1,
          cached_path = "/old/fav1.html", title = "Old favorite" },
    },
}
local schema_old, migrations = true, 0

package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(_path)
            local db = {}
            db.exec = function(_db, sql)
                if sql:find("ALTER TABLE mp_articles_new RENAME TO mp_articles", 1, true) then
                    schema_old = false
                    migrations = migrations + 1
                end
            end
            db.close = function() end
            db.prepare = function(_db, sql)
                local stmt = { sql = sql, args = {} }
                stmt.reset = function(self)
                    self.args = {}
                    return self
                end
                stmt.bind = function(self, ...)
                    self.args = { ... }
                    return self
                end
                stmt.close = function() end
                stmt.step = function(self)
                    if self.sql == "PRAGMA table_info(mp_articles)" then
                        self.row_idx = (self.row_idx or 0) + 1
                        if schema_old then
                            return ({
                                { 0, "review_id", "TEXT", 0, nil, 1 },
                                { 1, "list_type", "INTEGER", 1, nil, 0 },
                            })[self.row_idx]
                        end
                        return ({
                            { 0, "review_id", "TEXT", 1, nil, 2 },
                            { 1, "list_type", "INTEGER", 1, nil, 1 },
                        })[self.row_idx]
                    elseif self.sql:find("DELETE FROM mp_articles WHERE list_type=?", 1, true) then
                        local lt = self.args[1]
                        local filtered = {}
                        for _, row in ipairs(mock_tables.mp_articles) do
                            if row.list_type ~= lt then
                                filtered[#filtered + 1] = row
                            end
                        end
                        mock_tables.mp_articles = filtered
                        return nil
                    elseif self.sql:find("DELETE FROM mp_articles WHERE review_id=?", 1, true) then
                        local rid = self.args[1]
                        local filtered = {}
                        for _, row in ipairs(mock_tables.mp_articles) do
                            if row.review_id ~= rid then
                                filtered[#filtered + 1] = row
                            end
                        end
                        mock_tables.mp_articles = filtered
                        return nil
                    elseif self.sql:find("INSERT INTO mp_articles", 1, true) then
                        for _, row in ipairs(mock_tables.mp_articles) do
                            if row.list_type == self.args[2] and row.review_id == self.args[1] then
                                error("duplicate composite article key")
                            end
                        end
                        -- Values: review_id, list_type, idx, key, book_id, title, account, url, thumb_url, mpavatar, update_time, from_wechat, cached_path, is_read
                        mock_tables.mp_articles[#mock_tables.mp_articles + 1] = {
                            review_id = self.args[1],
                            list_type = self.args[2],
                            idx = self.args[3],
                            key = self.args[4],
                            book_id = self.args[5],
                            title = self.args[6],
                            account = self.args[7],
                            url = self.args[8],
                            thumb_url = self.args[9],
                            mpavatar = self.args[10],
                            update_time = self.args[11],
                            from_wechat = self.args[12],
                            cached_path = self.args[13],
                            is_read = self.args[14],
                        }
                        return nil
                    elseif self.sql:find("UPDATE mp_articles SET cached_path=?", 1, true) then
                        local cpath = self.args[1]
                        local rid = self.args[3]
                        for _, row in ipairs(mock_tables.mp_articles) do
                            if row.review_id == rid then
                                row.cached_path = cpath
                            end
                        end
                        return nil
                    elseif self.sql:find("SELECT review_id, list_type", 1, true) then
                        if not self.rows then
                            local lt = self.args[1]
                            local matched = {}
                            for _, r in ipairs(mock_tables.mp_articles) do
                                if r.list_type == lt then
                                    matched[#matched + 1] = {
                                        r.review_id, r.list_type, r.idx, r.key, r.book_id,
                                        r.title, r.account, r.url, r.thumb_url, r.mpavatar,
                                        r.update_time, r.from_wechat, r.cached_path, r.is_read,
                                    }
                                end
                            end
                            self.rows = matched
                            self.row_idx = 0
                        end
                        self.row_idx = self.row_idx + 1
                        return self.rows[self.row_idx]
                    end
                    return nil
                end
                return stmt
            end
            return db
        end,
    }
end

local LibraryDB = require("weink.lib.library_db")
local tmp_dir = os.tmpname() .. "-lib-mp"
os.remove(tmp_dir)

local current_account = { user_vid = "12345", login_method = "qr" }
local settings = {
    data_dir = tmp_dir,
    get = function(_self, key, default)
        if key == "account" then return current_account end
        return default
    end,
}

local db = LibraryDB:new(settings)

-- Test 1: cacheMpArticles and getMpArticles for listType 1 (favorites) and 2 (floating)
local fav_articles = {
    { reviewId = "fav_1", title = "Favorite 1", account = "Account A", url = "https://mp.weixin.qq.com/1" },
    { reviewId = "fav_2", title = "Favorite 2", account = "Account B", sourceUrl = "https://mp.weixin.qq.com/2" },
    { reviewId = "fav_1", title = "Duplicate favorite" },
}
local float_articles = {
    { reviewId = "flt_1", title = "Float 1", account = "Account C", url = "https://mp.weixin.qq.com/3" },
    { reviewId = "fav_1", title = "Favorite also floating", account = "Account A" },
}

expect(db:cacheMpArticles(1, fav_articles) == true, "cache favorites failed")
expect(migrations == 1, "article table was not migrated exactly once")
expect(db:cacheMpArticles(2, float_articles) == true, "cache floating failed")

local fetched_favs = db:getMpArticles(1)
expect(type(fetched_favs) == "table" and #fetched_favs == 2, "getMpArticles(1) length mismatch")
expect(fetched_favs[1].title == "Favorite 1", "fav 1 title mismatch")
expect(fetched_favs[1].cached_path == nil,
    "incompatible article cache path survived table reset")
expect(fetched_favs[2].account == "Account B", "fav 2 account mismatch")
expect(fetched_favs[2].url == "https://mp.weixin.qq.com/2",
    "offline article lost its WeChat source URL")

local fetched_floats = db:getMpArticles(2)
expect(type(fetched_floats) == "table" and #fetched_floats == 2, "getMpArticles(2) length mismatch")
expect(fetched_floats[1].title == "Float 1", "float 1 title mismatch")
expect(fetched_floats[2].reviewId == "fav_1", "same article should coexist in both lists")

-- Test 2: updateMpArticleCachePath
expect(db:updateMpArticleCachePath("fav_1", "/path/to/fav1.html") == true, "update cache path failed")
local updated_favs = db:getMpArticles(1)
expect(updated_favs[1].cached_path == "/path/to/fav1.html", "cached_path not updated")
expect(db:cacheMpArticles(1, fav_articles), "refresh favorites failed")
expect(db:getMpArticles(1)[1].cached_path == nil,
    "list refresh retained a stale article path")

-- Test 3: eink account fallback in accountKey
current_account = { user_vid = "" }
local current_eink = { vid = "67890" }
settings.get = function(_self, key, default)
    if key == "account" then return current_account end
    if key == "eink" then return current_eink end
    return default
end
local eink_db = LibraryDB:new(settings)
local eink_path = eink_db:databasePath()
expect(type(eink_path) == "string" and eink_path ~= "", "eink account fallback failed to generate db path")

if failures > 0 then
    error(string.format("%d checks failed in library_db_mp_articles_spec", failures))
end
print(string.format("library_db_mp_articles_spec: %d checks, 0 failure(s)", checks))
