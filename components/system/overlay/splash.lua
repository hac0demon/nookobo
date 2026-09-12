local ffi = require("ffi")
ffi.cdef[[
    int open(const char*, int);
    int close(int);
    int ioctl(int, unsigned long, ...);
    void* mmap(void*, size_t, int, int, int, long);
    int munmap(void*, size_t);
    void memset(void*, int, size_t);
    struct mxcfb_rect { uint32_t top, left, width, height; };
    struct mxcfb_alt_buffer_data { uint32_t phys_addr, width, height; struct mxcfb_rect alt_update_region; };
    struct mxcfb_update_data_v1 {
        struct mxcfb_rect update_region;
        uint32_t waveform_mode, update_mode, update_marker;
        int temp;
        unsigned int flags;
        struct mxcfb_alt_buffer_data alt_buffer_data;
    };
    struct mxcfb_update_marker_data { uint32_t update_marker, collision_test; };
]]
local C = ffi.C
local fd = C.open("/dev/fb0", 2)
if fd < 0 then
    print("[splash] Cannot open /dev/fb0")
    os.exit(0)
end

local stride = 1888
local w = 1872
local h = 1404
local fb_size = stride * h * 2

local ptr = C.mmap(nil, fb_size, 3, 1, fd, 0)
if ptr == nil or ptr == ffi.cast("void*", -1) then
    print("[splash] mmap failed")
    C.close(fd)
    os.exit(0)
end

-- Clear framebuffer to pure white (0xFFFF)
C.memset(ptr, 0xFF, fb_size)

-- Draw an elegant centered title card for 1872x1404
local p16 = ffi.cast("uint16_t*", ptr)
local banner_top = 550
local banner_bottom = 850
local banner_left = 536
local banner_right = 1336

-- Outer framing
for y = banner_top, banner_bottom do
    for x = banner_left, banner_right do
        if (y >= banner_top and y <= banner_top + 4) or
           (y >= banner_bottom - 4 and y <= banner_bottom) or
           (x >= banner_left and x <= banner_left + 4) or
           (x >= banner_right - 4 and x <= banner_right) then
            p16[y * stride + x] = 0x0000 -- Solid black outer border
        elseif (y >= banner_top + 10 and y <= banner_top + 12) or
               (y >= banner_bottom - 12 and y <= banner_bottom - 10) or
               (x >= banner_left + 10 and x <= banner_left + 12) or
               (x >= banner_right - 12 and x <= banner_right - 10) then
            p16[y * stride + x] = 0x0000 -- Thin inner border
        elseif y >= banner_top + 20 and y <= banner_top + 26 and x >= banner_left + 24 and x <= banner_right - 24 then
            p16[y * stride + x] = 0x0000 -- Header bar
        end
    end
end

-- Draw a battery gauge below the title card (outline, tip, proportional fill)
local cap = 100
local cf = io.open("/sys/class/power_supply/mc13892_bat/capacity", "r")
if cf then
    local v = cf:read("*number")
    if v and v >= 0 and v <= 100 then cap = v end
    cf:close()
end
local gx, gy, gw, gh = 856, 900, 160, 80
for y = gy, gy + gh do
    for x = gx, gx + gw do
        if y == gy or y == gy + gh - 1 or x == gx or x == gx + gw - 1 then
            p16[y * stride + x] = 0x0000
        end
    end
end
for y = gy + 20, gy + gh - 20 do
    for x = gx + gw, gx + gw + 16 do
        p16[y * stride + x] = 0x0000
    end
end
local fill_w = math.floor((gw - 8) * cap / 100)
for y = gy + 4, gy + gh - 4 do
    for x = gx + 4, gx + 4 + fill_w do
        p16[y * stride + x] = 0x0000
    end
end

-- Send FULL GC16 hardware refresh to wake up and flash the E Ink panel
local upd = ffi.new("struct mxcfb_update_data_v1")
upd.update_region.top = 0
upd.update_region.left = 0
upd.update_region.width = w
upd.update_region.height = h
upd.waveform_mode = 2 -- GC16
upd.update_mode = 1 -- FULL
upd.update_marker = 1
upd.temp = 4096 -- ambient
upd.flags = 0

local ret = C.ioctl(fd, 0x4040462e, upd)
if ret == 0 then
    -- Wait for completion
    local mdata = ffi.new("struct mxcfb_update_marker_data", 1, 0)
    C.ioctl(fd, 0xc008462f, mdata)
else
    -- Fallback via sysfs update trigger
    local f = io.open("/sys/class/graphics/fb0/update", "w")
    if f then
        f:write("gc16\n")
        f:close()
    end
end

C.munmap(ptr, fb_size)
C.close(fd)
print("[splash] E Ink splash rendered successfully.")
