package.path = "./?.lua;" .. package.path

local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end

local library = read("weread/ui/library.lua")
assert(library:find("list_type = 8", 1, true),
    "recommended reviews must use APK BOOK_WONDERFUL listType=8")
assert(library:find("review_type = 4", 1, true),
    "recommended reviews must request type=4 book reviews")
assert(library:find("list_type = 3", 1, true),
    "latest reviews must keep APK BOOK_TOP listType=3")
assert(not library:find('mode == "latest" and 3 or 1', 1, true),
    "recommended reviews must not use listType=1 (own underlines)")

local client = read("weread/lib/client.lua")
assert(client:find("params.type = review_type", 1, true),
    "client must pass APK review type to /review/list")

print("book_reviews_eink_spec: passed")
