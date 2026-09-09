-- /opt/koreader/plugins/platomanager.koplugin/main.lua
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local PlatoManager = WidgetContainer:extend{
    name = "platomanager",
}

function PlatoManager:onUpdatePlato()
    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = _("Download and install the latest Plato release over Wi-Fi?"),
        ok_text = _("Update"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Show pending banner
            local wait_info = InfoMessage:new{
                text = _("Updating Plato... Please wait."),
                timeout = 0,
            }
            UIManager:show(wait_info)
            UIManager:forceRePaint()

            -- Run the background script and catch the exit status
            local res = os.execute("/opt/scripts/update_plato.sh > /tmp/plato_update.log 2>&1")
            UIManager:close(wait_info)

            if res == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("Plato was successfully updated!"),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Update failed! Check Wi-Fi or /tmp/plato_update.log."),
                    timeout = 5,
                })
            end
        end,
    }
    UIManager:show(confirm_dialog)
end

function PlatoManager:onSwitchToPlato()
    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = _("Close KOReader and switch to Plato now?"),
        ok_text = _("Switch"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Set persistent state for orchestrator script
            os.execute("echo plato > /tmp/current_app")
            os.execute("echo plato > /tmp/active_reader")
            -- Exit KOReader cleanly; the launcher shell loop will start Plato
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:exit()
        end,
    }
    UIManager:show(confirm_dialog)
end

-- Hook into KOReader's top navigation bar
function PlatoManager:addToMainMenu(menu_items)
    menu_items.plato_manager = {
        text = _("Plato"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Update Plato (Latest Release)"),
                callback = function()
                    self:onUpdatePlato()
                end,
            },
            {
                text = _("Switch to Plato"),
                callback = function()
                    self:onSwitchToPlato()
                end,
            },
        },
    }
end

return PlatoManager
