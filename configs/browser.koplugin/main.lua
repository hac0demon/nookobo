--[[
  KOReader NetSurf Browser Launcher Plugin
  Provides an integrated "Web Browser (NetSurf)" menu entry with on-screen keyboard URL prompt.
--]]

local Dispatcher = require("dispatcher")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Browser = WidgetContainer:extend{
    name = "browser",
    is_doc_only = false,
}

function Browser:onDispatcherRegisterActions()
    Dispatcher:registerAction("launch_browser_action", {
        category = "none",
        event = "LaunchBrowser",
        title = _("Web Browser (NetSurf)"),
        general = true,
    })
end

function Browser:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Browser:addToMainMenu(menu_items)
    menu_items.web_browser = {
        text = _("Web Browser (NetSurf)"),
        sorting_hint = "more_tools",
        callback = function()
            self:onLaunchBrowser()
        end,
    }
end

function Browser:onLaunchBrowser()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Web Browser (NetSurf)"),
        description = _("Enter URL to browse:"),
        input = "https://lite.duckduckgo.com",
        input_type = "string",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Open"),
                    is_affirmative = true,
                    callback = function()
                        local url = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if url and url ~= "" then
                            if not url:find("^https?://") then
                                url = "https://" .. url
                            end
                            os.execute("/opt/start_browser.sh '" .. url .. "'")
                        else
                            os.execute("/opt/start_browser.sh")
                        end
                        -- After browser exits, force a full clean repaint of KOReader
                        UIManager:forceRePaint()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return Browser
