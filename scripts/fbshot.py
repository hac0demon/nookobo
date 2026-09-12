#!/usr/bin/env python3
"""Render BNRV700 /dev/fb0 dumps (stride 2816 B, 1404 px usable, RGB565) to PNG.

usage: fbshot.py dump.raw outprefix [page] [--check MIN_DARK]

Without a page argument, reports ink for every virtual page, writes the
best-inked page to <outprefix>.png and prints an ASCII preview.

--check MIN_DARK exits 0 if the selected page has at least MIN_DARK dark
pixels, 1 otherwise (used by scripts/device_check.sh to assert that text
actually rendered on the panel instead of a blank frame).
"""
import sys

from PIL import Image, ImageChops

S, W, H = 2816, 1404, 1872
RAMP = "@%#*+=-:. "

# RGB565 little-endian: v = lo | hi<<8 -> r from hi[3:7], g from hi[0:2]+lo[5:7], b from lo[0:4]
TBL_R = [((h >> 3) & 0x1F) << 3 for h in range(256)]
TBL_B = [(l & 0x1F) << 3 for l in range(256)]
TBL_GH = [((h & 0x07) << 3) << 2 for h in range(256)]
TBL_GL = [((l >> 5) & 0x07) << 2 for l in range(256)]


def page_image(buf, p):
    base = p * H * S
    if base + H * S > len(buf):
        return None
    los, his = [], []
    for y in range(H):
        row = buf[base + y * S: base + y * S + W * 2]
        if len(row) < W * 2:
            return None
        los.append(row[0::2])
        his.append(row[1::2])
    lo = Image.frombytes("L", (W, H), b"".join(los))
    hi = Image.frombytes("L", (W, H), b"".join(his))
    return Image.merge("RGB", (
        hi.point(TBL_R, "L"),
        ImageChops.add(hi.point(TBL_GH, "L"), lo.point(TBL_GL, "L")),
        lo.point(TBL_B, "L"),
    ))


def ascii_art(img, bw=6, bh=12):
    small = img.convert("L").resize(((W + bw - 1) // bw, (H + bh - 1) // bh),
                                   Image.BOX)
    px = small.load()
    return "\n".join(
        "%4d|%s|" % (y * bh,
                     "".join(RAMP[min(9, int((255 - px[x, y]) / 25.6))]
                             for x in range(small.width)))
        for y in range(small.height))


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv
    check_min = None
    if check:
        i = sys.argv.index("--check")
        check_min = int(sys.argv[i + 1])
    if len(args) < 2:
        sys.exit(__doc__)
    buf = open(args[0], "rb").read()
    pre = args[1]
    forced = int(args[2]) if len(args) > 2 else None
    cand, ink, p = {}, {}, 0
    while True:
        img = page_image(buf, p)
        if img is None:
            break
        cand[p] = img
        hist = img.convert("L").histogram()
        ink[p] = (sum(hist[:200]), sum(hist[200:]))
        print("page %d: dark=%d light=%d" % (p, ink[p][0], ink[p][1]))
        p += 1
    if not cand:
        print("no decodable page found (need %d bytes for one frame)" % (H * S))
        sys.exit(1)
    if forced is not None:
        pg = forced
    else:
        # the visible page has both ink and paper; spare pages are solid
        mixed = [k for k in ink if ink[k][0] > 1000 and ink[k][1] > 1000]
        pg = mixed[0] if mixed else max(ink, key=lambda k: ink[k][0])
    cand[pg].save("%s.png" % pre)
    print("wrote %s.png (page %d)" % (pre, pg))
    print(ascii_art(cand[pg]))
    if check:
        dark = ink[pg][0]
        print("check: dark=%d min=%d -> %s" % (dark, check_min,
                                               "PASS" if dark >= check_min else "FAIL"))
        sys.exit(0 if dark >= check_min else 1)


if __name__ == "__main__":
    main()
