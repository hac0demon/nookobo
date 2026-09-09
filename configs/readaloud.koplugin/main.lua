--[[
  KOReader Read Aloud Plugin (eSpeak-NG TTS) for BNRV700
  Synthesizes text phonetically with ~3-5% CPU usage via 3.5mm Headphone Jack.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ReadAloud = WidgetContainer:extend{
    name = "readaloud",
    is_doc_only = false,
    speed = 160,
    voice = "en-us",
}

function ReadAloud:onDispatcherRegisterActions()
    Dispatcher:registerAction("read_aloud_action", {
        category = "none",
        event = "ReadAloudPage",
        title = _("Read Page Aloud (eSpeak)"),
        general = false,
    })
end

function ReadAloud:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ReadAloud:addToMainMenu(menu_items)
    menu_items.readaloud = {
        text = _("Read Aloud (TTS / 3.5mm)"),
        sorting_hint = "more_tools",
        callback = function()
            self:showTTSDialog()
        end,
    }
end

function ReadAloud:getCurrentPageText()
    if self.view and self.ui and self.ui.document then
        local pageno = self.view.state and self.view.state.page or 1
        local page_text = self.ui.document:getPageText(pageno)
        if type(page_text) == "string" and page_text ~= "" then
            return page_text
        elseif type(page_text) == "table" then
            local text_parts = {}
            for _, box in ipairs(page_text) do
                if type(box) == "table" and box.text then
                    table.insert(text_parts, box.text)
                elseif type(box) == "string" then
                    table.insert(text_parts, box)
                end
            end
            return table.concat(text_parts, " ")
        end
    end
    return nil
end

function ReadAloud:speakText(text)
    if not text or text == "" then
        local msg = InfoMessage:new{
            text = _("No text available on the current page to read aloud."),
            timeout = 3,
        }
        UIManager:show(msg)
        return
    end

    -- Write text to temp file to safely handle quotes and newlines
    local tf = io.open("/tmp/tts_page.txt", "w")
    if tf then
        tf:write(text)
        tf:close()
        os.execute("SPEED=" .. self.speed .. " VOICE=" .. self.voice .. " /opt/speak.sh < /tmp/tts_page.txt &")
    end
end

function ReadAloud:stopSpeaking()
    os.execute("/opt/speak.sh stop")
end

function ReadAloud:isSpeaking()
    local p = io.popen("/opt/speak.sh status 2>/dev/null")
    local status = p and p:read("*l") or "IDLE"
    if p then p:close() end
    return status == "SPEAKING"
end

function ReadAloud:showTTSDialog()
    local speaking = self:isSpeaking()
    local status_text = speaking and _("Status: Speaking") or _("Status: Idle")

    local dialog
    dialog = ButtonDialog:new{
        title = _("Read Aloud (eSpeak-NG TTS)"),
        description = _("Audio routes out the 3.5mm headphone jack with ~3% CPU usage.\n")
                      .. status_text .. "\n"
                      .. _("Speed: ") .. self.speed .. " wpm | " .. _("Voice: ") .. self.voice,
        buttons = {
            {
                {
                    text = _("Read Current Page"),
                    is_affirmative = true,
                    callback = function()
                        UIManager:close(dialog)
                        local text = self:getCurrentPageText()
                        self:speakText(text)
                        self:showTTSDialog()
                    end,
                },
                {
                    text = _("Stop"),
                    callback = function()
                        self:stopSpeaking()
                        UIManager:close(dialog)
                        self:showTTSDialog()
                    end,
                },
            },
            {
                {
                    text = _("Slower (130)"),
                    callback = function()
                        self.speed = math.max(100, self.speed - 25)
                        UIManager:close(dialog)
                        self:showTTSDialog()
                    end,
                },
                {
                    text = _("Faster (190)"),
                    callback = function()
                        self.speed = math.min(260, self.speed + 25)
                        UIManager:close(dialog)
                        self:showTTSDialog()
                    end,
                },
                {
                    text = _("Custom Text"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptCustomSpeech()
                    end,
                },
            },
            {
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

function ReadAloud:promptCustomSpeech()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("eSpeak Text Input"),
        description = _("Enter text to synthesize via 3.5mm jack:"),
        input = "Welcome to your Nook GlowLight Plus on Alpine Linux.",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:showTTSDialog()
                    end,
                },
                {
                    text = _("Speak"),
                    is_affirmative = true,
                    callback = function()
                        local t = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if t and t ~= "" then
                            self:speakText(t)
                        end
                        self:showTTSDialog()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return ReadAloud
