package.path = "./?.lua;" .. package.path

local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end

local prefetch = read("weread/lib/annotation_prefetch_worker.lua")
assert(not prefetch:find("fetch_chapter_xhtml", 1, true),
    "prefetch worker still fetches web chapter HTML")
assert(not prefetch:find("fetch_source", 1, true),
    "prefetch worker still supplies a web original-HTML source")

local controller = read("weread/ui/annotation_sync_controller.lua")
assert(not controller:find("fetch_chapter_xhtml", 1, true),
    "annotation sync still fetches web chapter HTML")
assert(not controller:find("ensure_reader_state", 1, true),
    "annotation sync still opens the web reader for psvts")

local downloader = read("weread/lib/downloader.lua")
assert(not downloader:find("ensure_reader_state", 1, true),
    "downloader still opens the web reader before ZIP download")
assert(not downloader:find("fetch_chapter_xhtml_parallel", 1, true),
    "downloader still advertises web shard workers")

local runtime = read("weread/lib/plugin_runtime.lua")
assert(not runtime:find("ensure_reader_state", 1, true),
    "catalog refresh still opens the web reader")

print("annotation_eink_source_spec: passed")
