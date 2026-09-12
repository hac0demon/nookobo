--[[
  KOReader Battery Tracker & Power Monitor Plugin for BNRV700
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local BatteryTracker = WidgetContainer:extend{
    name = "batterytracker",
    is_doc_only = false,
}

function BatteryTracker:onDispatcherRegisterActions()
    Dispatcher:registerAction("battery_tracker_action", {
        category = "none",
        event = "ShowBatteryMonitor",
        title = _("Battery Usage Monitor"),
        general = true,
    })
end

function BatteryTracker:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function BatteryTracker:addToMainMenu(menu_items)
    menu_items.battery_tracker = {
        text = _("Battery & Power Monitor"),
        sorting_hint = "more_tools",
        callback = function()
            self:showMonitorDialog()
        end,
    }
end

function BatteryTracker:getBatteryStats()
    local stats = {}
    local p = io.popen("/opt/battery_tracker.sh status 2>/dev/null")
    if p then
        for line in p:lines() do
            local k, v = line:match("^([A-Z_]+):(.*)$")
            if k and v then
                stats[k] = v
            end
        end
        p:close()
    end
    return stats
end

function BatteryTracker:getRecentLog()
    local lines = {}
    local p = io.popen("tail -n 5 /data/battery_history.csv 2>/dev/null")
    if p then
        for line in p:lines() do
            if not line:find("^epoch") then
                local parts = {}
                for part in line:gmatch("([^,]+)") do
                    table.insert(parts, part)
                end
                if #parts >= 5 then
                    local dt = parts[2]:match("%d+-%d+-%d+%s+(%d+:%d+)") or parts[2]
                    table.insert(lines, string.format("%s: %s%% (%s mV, %s)", dt, parts[3], parts[4], parts[5]))
                end
            end
        end
        p:close()
    end
    return table.concat(lines, "\n")
end

function BatteryTracker:showMonitorDialog()
    local s = self:getBatteryStats()
    local recent = self:getRecentLog()

    local desc = _("Level: ") .. (s.CAPACITY or "N/A") .. " | " .. _("Voltage: ") .. (s.VOLTAGE or "N/A") .. "\n"
              .. _("Status: ") .. (s.STATUS or "N/A") .. " | " .. _("Health: ") .. (s.HEALTH or "Good") .. "\n"
              .. _("Temperature: ") .. (s.TEMP or "N/A") .. "\n"
              .. _("Discharge Rate: ") .. (s.RATE or "Calculating...") .. "\n"
              .. _("Est. Remaining: ") .. (s.TIME_REMAINING or "N/A")

    if recent ~= "" then
        desc = desc .. "\n\n" .. _("Recent History:") .. "\n" .. recent
    end

    local dialog
    dialog = ButtonDialog:new{
        title = _("Battery Usage Monitor"),
        description = desc,
        buttons = {
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showMonitorDialog()
                    end,
                },
                {
                    text = _("Log Reading Now"),
                    is_affirmative = true,
                    callback = function()
                        os.execute("/opt/battery_tracker.sh log")
                        UIManager:close(dialog)
                        self:showMonitorDialog()
                    end,
                },
            },
            {
                {
                    text = _("Clear History"),
                    callback = function()
                        os.execute("/opt/battery_tracker.sh clear")
                        UIManager:close(dialog)
                        self:showMonitorDialog()
                    end,
                },
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return BatteryTracker
