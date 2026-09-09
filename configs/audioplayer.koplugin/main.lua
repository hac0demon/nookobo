--[[
  KOReader Audio Player Plugin for BNRV700
  Supports background MP3/audio playback through 3.5mm Headphone Jack and Bluetooth A2DP.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local AudioPlayer = WidgetContainer:extend{
    name = "audioplayer",
    is_doc_only = false,
}

function AudioPlayer:onDispatcherRegisterActions()
    Dispatcher:registerAction("audioplayer_action", {
        category = "none",
        event = "ShowAudioPlayer",
        title = _("Audio Player (MP3)"),
        general = true,
    })
end

function AudioPlayer:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function AudioPlayer:addToMainMenu(menu_items)
    menu_items.audioplayer = {
        text = _("Audio Player (MP3 / BT)"),
        sorting_hint = "more_tools",
        callback = function()
            self:showPlayerDialog()
        end,
    }
end

function AudioPlayer:getStatus()
    local status = "STOPPED"
    local track = ""
    local shuffle = false
    local count = 0
    local index = 0
    local p = io.popen("/opt/audiocontrol.sh status 2>/dev/null")
    if p then
        for line in p:lines() do
            local s = line:match("^STATUS:(.*)")
            if s then status = s end
            local t = line:match("^TRACK:(.*)")
            if t then track = t end
            local sh = line:match("^SHUFFLE:(.*)")
            if sh and sh == "1" then shuffle = true end
            local cnt = line:match("^COUNT:(.*)")
            if cnt then count = tonumber(cnt) or 0 end
            local idx = line:match("^INDEX:(.*)")
            if idx then index = tonumber(idx) or 0 end
        end
        p:close()
    end
    return status, track, shuffle, count, index
end

function AudioPlayer:showPlayerDialog()
    local status, track, shuffle, count, index = self:getStatus()
    local track_name = track ~= "" and track:match("([^/]+)$") or _("No track selected")
    local status_text = status == "PLAYING" and _("Playing") or (status == "PAUSED" and _("Paused") or _("Stopped"))
    local shuffle_text = shuffle and _("ON") or _("OFF")
    local playlist_info = count > 0 and string.format(_("Track %d of %d"), index + 1, count) or _("Empty Playlist")

    local desc = _("Track: ") .. track_name .. "\n" ..
                 _("Status: ") .. status_text .. "  |  " .. playlist_info .. "  |  " .. _("Shuffle: ") .. shuffle_text

    local dialog
    dialog = ButtonDialog:new{
        title = _("Audio Player"),
        description = desc,
        buttons = {
            {
                {
                    text = _("|<< Prev"),
                    callback = function()
                        os.execute("/opt/audiocontrol.sh prev")
                        UIManager:close(dialog)
                        self:showPlayerDialog()
                    end,
                },
                {
                    text = status == "PLAYING" and _("Pause [||]") or _("Play [>]"),
                    is_affirmative = true,
                    callback = function()
                        os.execute("/opt/audiocontrol.sh pause")
                        UIManager:close(dialog)
                        self:showPlayerDialog()
                    end,
                },
                {
                    text = _("Next >>|"),
                    callback = function()
                        os.execute("/opt/audiocontrol.sh next")
                        UIManager:close(dialog)
                        self:showPlayerDialog()
                    end,
                },
            },
            {
                {
                    text = _("Shuffle: ") .. shuffle_text,
                    callback = function()
                        os.execute("/opt/audiocontrol.sh shuffle")
                        UIManager:close(dialog)
                        self:showPlayerDialog()
                    end,
                },
                {
                    text = _("Reorder Playlist"),
                    callback = function()
                        os.execute("/opt/audiocontrol.sh reorder")
                        UIManager:close(dialog)
                        self:showPlayerDialog()
                    end,
                },
                {
                    text = _("Rescan Files"),
                    callback = function()
                        UIManager:close(dialog)
                        local msg = InfoMessage:new{
                            text = _("Scanning storage for audio files..."),
                            timeout = 3,
                        }
                        UIManager:show(msg)
                        os.execute("/opt/audiocontrol.sh scan")
                        UIManager:close(msg)
                        self:showPlayerDialog()
                    end,
                },
            },
            {
                {
                    text = _("Vol -"),
                    callback = function()
                        os.execute("/opt/audiocontrol.sh voldown")
                    end,
                },
                {
                    text = _("Vol +"),
                    callback = function()
                        os.execute("/opt/audiocontrol.sh volup")
                    end,
                },
                {
                    text = _("Select File"),
                    callback = function()
                        UIManager:close(dialog)
                        self:onSelectAudioFile()
                    end,
                },
            },
            {
                {
                    text = _("Bluetooth Setup"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showBluetoothDialog()
                    end,
                },
                {
                    text = _("Stop"),
                    callback = function()
                        os.execute("/opt/audiocontrol.sh stop")
                        UIManager:close(dialog)
                        self:showPlayerDialog()
                    end,
                },
                {
                    text = _("Close (Keep Playing)"),
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

function AudioPlayer:onSelectAudioFile()
    local FileChooser = require("ui/widget/filechooser")
    local lfs = require("libs/libkoreader-lfs")

    local start_path = "/sdcard/Music"
    if not lfs.attributes(start_path, "mode") then
        start_path = "/sdcard"
    end
    if not lfs.attributes(start_path, "mode") then
        start_path = "/data/books"
    end

    local chooser
    chooser = FileChooser:new{
        title = _("Select Audio File"),
        path = start_path,
        file_filter = function(filename)
            local lower = filename:lower()
            return lower:match("%.mp3$") or lower:match("%.flac$") or lower:match("%.ogg$") or lower:match("%.wav$") or lower:match("%.m4a$")
        end,
    }

    chooser.show_file = function(this, filename, fullpath)
        UIManager:close(chooser)
        local escaped = fullpath:gsub("'", "'\\''")
        os.execute("/opt/audiocontrol.sh play '" .. escaped .. "'")
        self:showPlayerDialog()
    end

    UIManager:show(chooser)
end

function AudioPlayer:showBluetoothDialog()
    local status_handle = io.popen("/opt/bt-manager.sh status 2>/dev/null")
    local status_out = status_handle and status_handle:read("*a") or "Bluetooth status unknown"
    if status_handle then status_handle:close() end

    local bt_dialog
    bt_dialog = ButtonDialog:new{
        title = _("Bluetooth Manager"),
        description = status_out,
        buttons = {
            {
                {
                    text = _("Scan Devices (5s)"),
                    callback = function()
                        UIManager:close(bt_dialog)
                        local scan_msg = InfoMessage:new{
                            text = _("Scanning for Bluetooth devices..."),
                            timeout = 5,
                        }
                        UIManager:show(scan_msg)

                        local scan_handle = io.popen("/opt/bt-manager.sh scan 2>/dev/null")
                        local scan_out = scan_handle and scan_handle:read("*a") or "No devices found"
                        if scan_handle then scan_handle:close() end
                        UIManager:close(scan_msg)

                        local results_dialog = ButtonDialog:new{
                            title = _("Bluetooth Devices"),
                            description = scan_out,
                            buttons = {
                                {
                                    {
                                        text = _("Connect MAC"),
                                        is_affirmative = true,
                                        callback = function()
                                            UIManager:close(results_dialog)
                                            self:promptConnectMAC()
                                        end,
                                    },
                                    {
                                        text = _("Back"),
                                        callback = function()
                                            UIManager:close(results_dialog)
                                            self:showBluetoothDialog()
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(results_dialog)
                    end,
                },
                {
                    text = _("Enable BT"),
                    callback = function()
                        os.execute("/opt/bt-manager.sh on")
                        UIManager:close(bt_dialog)
                        self:showBluetoothDialog()
                    end,
                },
                {
                    text = _("Disable BT"),
                    callback = function()
                        os.execute("/opt/bt-manager.sh off")
                        UIManager:close(bt_dialog)
                        self:showBluetoothDialog()
                    end,
                },
            },
            {
                {
                    text = _("Back to Player"),
                    callback = function()
                        UIManager:close(bt_dialog)
                        self:showPlayerDialog()
                    end,
                },
            },
        },
    }
    UIManager:show(bt_dialog)
end

function AudioPlayer:promptConnectMAC()
    local mac_input
    mac_input = InputDialog:new{
        title = _("Connect Bluetooth Device"),
        description = _("Enter device MAC address (e.g. 00:11:22:33:44:55):"),
        input = "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(mac_input)
                        self:showBluetoothDialog()
                    end,
                },
                {
                    text = _("Pair & Connect"),
                    is_affirmative = true,
                    callback = function()
                        local mac = mac_input:getInputText()
                        UIManager:close(mac_input)
                        if mac and mac ~= "" then
                            local escaped = mac:gsub("'", "'\\''")
                            os.execute("/opt/bt-manager.sh connect '" .. escaped .. "'")
                        end
                        self:showBluetoothDialog()
                    end,
                },
            },
        },
    }
    UIManager:show(mac_input)
    mac_input:onShowKeyboard()
end

return AudioPlayer
