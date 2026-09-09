--[[
  /opt/koreader/patches/1-bnrv700-hardware.lua
  BNRV700 (NOOK GlowLight Plus 7.8" / Quill) Hardware Adaptation Patch
  
  Applied automatically by KOReader's userpatch system (early priority).
  Survives internal KOReader OTA updates without requiring file modifications
  to stock KOReader Lua source files.
--]]

local logger = require("logger")
logger.info("BNRV700: Initializing hardware adaptation userpatch...")

-- 1. Configure Screensaver to display current book cover on sleep
if G_reader_settings then
    if G_reader_settings:hasNot("screensaver_type") or G_reader_settings:readSetting("screensaver_type") == "disable" then
        logger.info("BNRV700: Setting sleep screen to current book cover...")
        G_reader_settings:saveSetting("screensaver_type", "cover")
        G_reader_settings:saveSetting("screensaver_stretch_images", true)
        G_reader_settings:saveSetting("screensaver_show_message", false)
    end
end

-- 2. Clean interceptor via package.loaders[2] (preserves native module loading without preload loops)
local orig_searcher = package.loaders[2]
package.loaders[2] = function(name)
    local chunk, err = orig_searcher(name)
    if type(chunk) ~= "function" then
        return chunk, err
    end

    if name == "ffi/framebuffer_mxcfb" then
        return function(modname)
            local FramebufferMXCFB = chunk(modname)
            local orig_init = FramebufferMXCFB.init

            FramebufferMXCFB.init = function(self)
                orig_init(self)

                local ffi = require("ffi")
                local C = ffi.C

                logger.info("BNRV700: Enforcing Freescale EPDC V1 ioctls and geometry...")
                self.use_mxcfb_v1 = true

                if not self.update_data_v1 then
                    self.update_data_v1 = ffi.new("struct mxcfb_update_data_v1")
                    self.update_data_v1.temp = C.TEMP_USE_AMBIENT
                    self.update_data_v1.flags = 0
                end

                if not self.marker_data_v1 then
                    self.marker_data_v1 = ffi.new("struct mxcfb_update_marker_data")
                    self.marker_data_v1.collision_test = 0
                end

                -- Hardware update completion wait (0xc008462f / 3221767727 with struct mxcfb_update_marker_data)
                self.mech_wait_update_complete = function(fb, marker)
                    fb.marker_data_v1.update_marker = marker
                    return C.ioctl(fb.fd, 3221767727, fb.marker_data_v1)
                end

                -- Direct V1 ioctl screen refresh with correct coordinate transformation
                self.mech_refresh = function(fb, is_flashing, waveform_mode, x, y, w, h, dither)
                    local bb = fb.full_bb or fb.bb
                    x, y, w, h = bb:getBoundedRect(x, y, w, h, dither and 8 or fb.alignment_constraint)
                    -- Transform logical portrait coordinates into physical landscape EPDC rect
                    x, y, w, h = bb:getPhysicalRect(x, y, w, h)

                    if w <= 1 or h <= 1 then
                        return
                    end

                    if waveform_mode == C.WAVEFORM_MODE_DU then
                        fb.update_data_v1.flags = C.EPDC_FLAG_FORCE_MONOCHROME
                    else
                        fb.update_data_v1.flags = 0
                    end

                    fb.update_data_v1.update_mode = is_flashing and C.UPDATE_MODE_FULL or C.UPDATE_MODE_PARTIAL
                    fb.update_data_v1.waveform_mode = waveform_mode or C.WAVEFORM_MODE_AUTO
                    fb.update_data_v1.update_region.left = x
                    fb.update_data_v1.update_region.top = y
                    fb.update_data_v1.update_region.width = w
                    fb.update_data_v1.update_region.height = h
                    local marker = fb:_get_next_marker()
                    fb.update_data_v1.update_marker = marker

                    -- Force initial full GC16 hardware refresh to clear ghosting and wake panel
                    if marker <= 1 then
                        fb.update_data_v1.update_mode = C.UPDATE_MODE_FULL
                        fb.update_data_v1.waveform_mode = C.WAVEFORM_MODE_GC16
                    end

                    local ret = C.ioctl(fb.fd, 0x4040462e, fb.update_data_v1)
                    if ret == -1 then
                        logger.warn("BNRV700: MXCFB_SEND_UPDATE_V1 failed: " .. ffi.string(C.strerror(ffi.errno())))
                    end

                    -- Fence off full updates using standard marker wait ioctl
                    if fb.update_data_v1.update_mode == C.UPDATE_MODE_FULL and fb.mech_wait_update_complete then
                        fb:mech_wait_update_complete(marker)
                        fb.dont_wait_for_marker = marker
                    end

                    return ret
                end
            end

            return FramebufferMXCFB
        end

    elseif name == "device/kobo/device" then
        return function(modname)
            local KoboDevice = chunk(modname)
            logger.info("BNRV700: Configuring Kobo device abstraction for Quill hardware...")

            local function yes() return true end
            local function no() return false end

            -- Force full refresh on wake/resume
            KoboDevice.needsScreenRefreshAfterResume = yes
            KoboDevice.hasNaturalLightMixer = yes
            KoboDevice.hasKeys = yes
            KoboDevice.hasMultitouch = yes

            -- Elan Touch Protocol with Snow Protocol Lift Detection on BNRV700
            KoboDevice.touch_phoenix_protocol = false
            KoboDevice.touch_snow_protocol = true
            KoboDevice.touch_switch_xy = true
            KoboDevice.touch_mirrored_x = true
            KoboDevice.touch_mirrored_y = false

            -- Configure TI LM3630A I2C controller for brightness and warmth
            KoboDevice.frontlight_settings = {
                frontlight_white = "/sys/class/backlight/mxc_msp430_fl.0/brightness",
                frontlight_mixer = "/sys/class/backlight/lm3630a_led/color",
                frontlight_ioctl = false,
                nl_min = 0,
                nl_max = 10,
                nl_inverted = false,
            }

            -- Hook input mapping to register BNRV700 physical page buttons and long-press Home handler
            local orig_kobo_init = KoboDevice.init
            KoboDevice.init = function(self)
                self.hasKeys = yes
                self.hasNaturalLightMixer = yes
                self.hasMultitouch = yes
                self.needsScreenRefreshAfterResume = yes
                self.touch_phoenix_protocol = false
                self.touch_snow_protocol = true
                self.touch_switch_xy = true
                self.touch_mirrored_x = true
                self.touch_mirrored_y = false
                self.frontlight_settings = {
                    frontlight_white = "/sys/class/backlight/mxc_msp430_fl.0/brightness",
                    frontlight_mixer = "/sys/class/backlight/lm3630a_led/color",
                    frontlight_ioctl = false,
                    nl_min = 0,
                    nl_max = 10,
                    nl_inverted = false,
                }
                orig_kobo_init(self)
                self.input.snow_protocol = true
                logger.info("BNRV700: touch_snow_protocol active, snow_protocol=" .. tostring(self.input.snow_protocol))

                if self.input and self.input.event_map then
                    logger.info("BNRV700: Registering physical page button event mappings...")
                    self.input.event_map[191] = "LPgBack" -- Top Left
                    self.input.event_map[192] = "LPgFwd"  -- Bottom Left
                    self.input.event_map[193] = "RPgBack" -- Top Right
                    self.input.event_map[194] = "RPgFwd"  -- Bottom Right
                    self.input.event_map[102] = "Home"    -- Nook Home Touch Icon
                end

                -- Long press Home button -> opens frontlight brightness/warmth dialog
                if self.input and self.input.event_map_adapter then
                    local home_down_ts = nil
                    local home_long_fired = false

                    self.input.event_map_adapter.Home = function(ev)
                        local UIManager = require("ui/uimanager")
                        local Event = require("ui/event")
                        local time = require("ui/time")

                        if self.input:isEvKeyPress(ev) then
                            home_down_ts = time.now()
                            home_long_fired = false
                            -- 500ms hold threshold triggers frontlight dialog
                            UIManager:scheduleIn(0.5, function()
                                if home_down_ts ~= nil and not home_long_fired then
                                    home_long_fired = true
                                    logger.info("BNRV700: Home button long press detected -> opening frontlight dialog")
                                    local Device = require("device")
                                    local Input = require("device/input")
                                    -- Clear any input inhibition that may have been set
                                    -- by key handling (e.g. inhibitInputUntil) so that
                                    -- touch events reach the frontlight dialog controls.
                                    Input:inhibitInputUntil()
                                    -- Reset gesture recognizer state to avoid stale
                                    -- finger-down state from the synthetic KEY_HOME
                                    -- hold/release sequence confusing tap detection.
                                    Input:resetState()
                                    Device:showLightDialog()
                                end
                            end)
                            return nil
                        elseif self.input:isEvKeyRelease(ev) then
                            home_down_ts = nil
                            if home_long_fired then
                                home_long_fired = false
                                return nil
                            end
                            -- Short tap: navigate to Home/Library
                            return "Home"
                        end
                    end
                end

                -- Gesture debug logging to verify touch coordinates and responsiveness
                if self.input then
                    self.input.gestureAdjustHook = function(input_self, ges)
                        if ges and ges.pos then
                            logger.info(string.format("BNRV700: Touch gesture '%s' at (%d, %d)", tostring(ges.ges), ges.pos.x, ges.pos.y))
                        end
                    end
                end

                -- Magnetic Smart-Cover Sleep/Wake (Hall Sensor)
                if self.input and self.input.registerEventAdjustHook then
                    self.input:registerEventAdjustHook(function(input_self, ev)
                        if ev.type == 5 and ev.code == 0 then
                            local UIManager = require("ui/uimanager")
                            local Event = require("ui/event")
                            if ev.value == 1 then
                                logger.info("BNRV700: Hall sensor magnetic cover closed -> SleepCoverClosed")
                                UIManager:broadcastEvent(Event:new("SleepCoverClosed"))
                            elseif ev.value == 0 then
                                logger.info("BNRV700: Hall sensor magnetic cover opened -> SleepCoverOpened")
                                UIManager:broadcastEvent(Event:new("SleepCoverOpened"))
                            end
                        end
                    end)
                end
            end

            return KoboDevice
        end

    elseif name == "ui/network/manager" then
        return function(modname)
            local NetworkMgr = chunk(modname)
            NetworkMgr.getNetworkInterfaceName = function(self)
                return os.getenv("INTERFACE") or "wlan0"
            end
            return NetworkMgr
        end
    end

    return chunk
end

logger.info("BNRV700: Hardware adaptation hooks successfully installed.")
