--[[
  KOReader Plato Reader Switcher Plugin for BNRV700
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SwitchPlato = WidgetContainer:extend{
    name = "switch_plato",
    is_doc_only = false,
}

function SwitchPlato:onDispatcherRegisterActions()
    Dispatcher:registerAction("switch_plato_action", {
        category = "none",
        event = "SwitchToPlato",
        title = _("Switch to Plato Reader"),
        general = true,
    })
end

function SwitchPlato:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function SwitchPlato:addToMainMenu(menu_items)
    menu_items.switch_plato = {
        text = _("Switch to Plato Reader"),
        sorting_hint = "tools",
        callback = function()
            self:confirmSwitch()
        end,
    }
end

function SwitchPlato:confirmSwitch()
    local confirm_dialog
    confirm_dialog = ButtonDialog:new{
        title = _("Switch to Plato Reader"),
        description = _("KOReader will exit and Plato Reader will start.\n\nWhen you select 'Quit' in Plato, you will automatically return back to KOReader."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(confirm_dialog)
                    end,
                },
                {
                    text = _("Switch to Plato"),
                    is_affirmative = true,
                    callback = function()
                        UIManager:close(confirm_dialog)
                        local f = io.open("/tmp/active_reader", "w")
                        if f then
                            f:write("plato\n")
                            f:close()
                        end
                        os.exit(0)
                    end,
                },
            },
        },
    }
    UIManager:show(confirm_dialog)
end

return SwitchPlato
