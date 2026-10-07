package.path = "./?.lua;" .. package.path
local shown, checks = nil, 0
local widget = { new = function(_, options) return options end }
package.loaded["ui/widget/confirmbox"] = widget
package.loaded["ui/widget/infomessage"] = widget
package.loaded["ui/uimanager"] = { show = function(_, options) shown = options end }
package.loaded["ffi/util"] = { template = function(text, ...)
    local args = { ... }
    return (text:gsub("%%(%d)", function(index) return tostring(args[tonumber(index)]) end))
end }
package.loaded["weread.lib.i18n"] = { tr = function(text) return text end }
local Dialog = require("weread.ui.progress_sync_dialog")
local function contains(fragment)
    checks = checks + 1
    assert(shown and shown.text:find(fragment, 1, true), fragment)
end
local local_called, remote_called = 0, 0
Dialog.show_choice({ book_title = "Test", position_uncertain = true,
    local_position = { percent = 45 }, remote_position = { percent = 45.9 },
    keep_local = function() local_called = local_called + 1 end,
    use_remote = function() remote_called = remote_called + 1 end })
contains("Cannot precisely compare chapter offsets")
contains("The local offset is estimated")
shown.ok_callback(); shown.cancel_callback()
assert(local_called == 1 and remote_called == 1)
Dialog.notify("already_synced", {})
contains("reported coordinates match")
contains("cloud record")
Dialog.notify("upload_success", { position = { percent = 45 } })
contains("accepted the progress request")
Dialog.notify("upload_unconfirmed", { position = { percent = 45 } })
contains("has not caught up yet")
contains("the next sync will retry")
Dialog.notify("remote_applied", { position = { percent = 45 } })
contains("within-chapter position is estimated")
print(("progress_sync_dialog_spec: %d checks passed"):format(checks + 1))
