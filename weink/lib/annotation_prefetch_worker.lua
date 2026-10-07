local Sync = require("weink.lib.annotation_sync")
local WorkerSettings = require("weink.lib.worker_settings")

local M = {}

function M.run(settings, client, context, chapters, worker_context)
    local auth_result = WorkerSettings.capture(settings)
    local job = Sync:new {
        store = context.store,
        client = client,
        book_id = context.book_id,
        chapters = chapters or context.chapters,
        ranges = context.ranges,
        document = nil,
        document_key = nil,
        refresh = false,
        offline = false,
        is_cancelled = worker_context.cancelled,
    }
    while true do
        worker_context.checkCancelled()
        local done, state = job:step()
        if done == nil then error(state, 0) end
        if done then return { auth = auth_result() } end
        worker_context.emit(state)
        if state and tonumber(state.delay) and tonumber(state.delay) > 0 then
            worker_context.sleep(state.delay)
        end
    end
end

return M
