-- Signed MP article link prefetch specs.
-- The background worker resolves the links for the articles on screen so the
-- tap-to-open path does not pay the 15%-hit-rate lookup every time, and it
-- interleaves attempts so one stubborn article cannot eat the whole budget.
-- Run with: luajit spec/mp_link_prefetch_worker_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weink.lib.crypto"] = function()
    return { sha256_hex = function() return string.rep("a", 64) end }
end
package.preload["weink.lib.reader_state"] = function() return {} end
package.preload["weink.lib.thoughts"] = function() return {} end

local Content = require("weink.lib.content")
local Worker = require("weink.lib.mp_link_prefetch_worker")

local SIGNED = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&chksm="
    .. string.rep("c", 64)
local UNSIGNED = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&scene=58&subscene=0"
local DOC_URL = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&chksm="
    .. string.rep("d", 64) .. "#rd"

Content.clear_mp_article_urls()

-- 1) candidates: only unsigned, still-uncached articles with a reviewId
local picked = Worker.candidates({
    { reviewId = "p-1", url = UNSIGNED },
    { reviewId = "p-2", url = SIGNED },
    { reviewId = "", url = UNSIGNED },
    { url = UNSIGNED },
    { reviewId = "p-3", url = "" },
    { reviewId = "p-4", url = UNSIGNED },
})
expect(#picked == 2, "expected 2 candidates, got " .. #picked)
expect(picked[1].reviewId == "p-1" and picked[2].reviewId == "p-4",
    "candidates must keep the unsigned, uncached articles only")

-- 2) already cached links are skipped (nothing to resolve)
Content.remember_mp_article_url("p-1", DOC_URL)
picked = Worker.candidates({ { reviewId = "p-1", url = UNSIGNED },
    { reviewId = "p-4", url = UNSIGNED } })
expect(#picked == 1 and picked[1].reviewId == "p-4",
    "cached links must not be re-resolved")
Content.forget_mp_article_url("p-1")

-- 3) the limit caps how many links one run resolves
picked = Worker.candidates({
    { reviewId = "l-1", url = UNSIGNED }, { reviewId = "l-2", url = UNSIGNED },
    { reviewId = "l-3", url = UNSIGNED }, { reviewId = "l-4", url = UNSIGNED },
    { reviewId = "l-5", url = UNSIGNED },
}, 3)
expect(#picked == 3, "limit must cap candidates, got " .. #picked)

-- 4) run(): resolves the unsigned links, reports progress, and hands the links
--    back for the parent to cache (the child never writes the parent's cache)
local emitted = {}
local lookups = {}
local client = {
    eink_json = function(_self, path, params)
        expect(path == "/review/single", "wrong endpoint: " .. tostring(path))
        lookups[#lookups + 1] = params.reviewId
        return { review = { mpInfo = { doc_url = DOC_URL } } }
    end,
}
local context = {
    checkCancelled = function() end,
    emit = function(state) emitted[#emitted + 1] = state end,
}
local result = Worker.run({}, client, {
    { reviewId = "w-1", title = "one", url = UNSIGNED },
    { reviewId = "w-2", title = "two", url = SIGNED },
}, context)
expect(type(result) == "table" and result.ok == nil, "run must return a plain result table")
expect(result.resolved == 1, "only the unsigned link may be resolved, got "
    .. tostring(result.resolved))
expect(result.attempted == 1, "a signed stored link must not be attempted, got "
    .. tostring(result.attempted))
expect(result.links["w-1"] == DOC_URL, "resolved link must be handed back")
expect(result.links["w-2"] == nil, "an already signed link must not be prefetched")
expect(#lookups == 1 and lookups[1] == "w-1",
    "only the unsigned article may be looked up")
expect(#emitted == 1, "one round must be emitted for a single pending link, got "
    .. #emitted)
expect(emitted[1].stage == "links" and emitted[1].count == 1 and emitted[1].round == 1,
    "progress must carry stage, round and total")

-- 5) attempts are interleaved: an article that never resolves must not stop the
--    others from being resolved in the same round
local interleaved = {}
local stubborn_client = {
    eink_json = function(_self, path, params)
        interleaved[#interleaved + 1] = params.reviewId
        if params.reviewId == "rr-2" then
            return { review = { mpInfo = { doc_url = DOC_URL } } }
        end
        return { review = { mpInfo = { doc_url = UNSIGNED } } }
    end,
}
local rr = Worker.run({}, stubborn_client, {
    { reviewId = "rr-1", url = UNSIGNED },
    { reviewId = "rr-2", url = UNSIGNED },
}, context)
expect(rr.links["rr-2"] == DOC_URL, "a resolvable link must be found in round one")
expect(rr.links["rr-1"] == nil, "an unresolvable link must stay uncached")
expect(interleaved[1] == "rr-1" and interleaved[2] == "rr-2",
    "round one must ask every pending article once")
expect(rr.rounds == Worker.DEFAULT_ROUNDS, "run must report its round budget")

-- 6) cancellation aborts the batch instead of resolving the rest
local cancelled = false
local cancel_context = {
    checkCancelled = function()
        if cancelled then error("__weink_worker_cancelled__", 0) end
    end,
    emit = function() end,
}
local cancel_client = {
    eink_json = function()
        cancelled = true
        return { review = { mpInfo = { doc_url = DOC_URL } } }
    end,
}
local ok, err = pcall(Worker.run, {}, cancel_client, {
    { reviewId = "c-1", url = UNSIGNED }, { reviewId = "c-2", url = UNSIGNED },
}, cancel_context)
expect(not ok, "cancelled batch must abort")
expect(tostring(err):find("__weink_worker_cancelled__", 1, true) ~= nil,
    "cancellation must surface the worker sentinel, got " .. tostring(err))

print("mp_link_prefetch_worker_spec: " .. checks .. " checks passed")
