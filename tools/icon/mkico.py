"""Build the app icons from a flat SVG — stdlib Python only, no image tools.

    python3 tools/icon/mkico.py assets/icon/zigz.svg

writes next to the SVG:
  * <name>.ico — 16…256 px PNG entries, embedded in the Windows .exe as a
    resource (Explorer, title bar, taskbar); see build.zig / zigui.rc;
  * <name>.png — 256 px, loaded at runtime via `Config.icon_png` for the
    window/Dock icon on macOS and Linux;
  * with `--iconset`, also <name>.iconset/ — the 16…1024 px PNGs (@1x and
    @2x) a macOS bundle's icon is made of: `iconutil -c icns <name>.iconset`.

Handles only what the icon uses: <path> elements with absolute M/L/Z commands
and solid #rrggbb fills (polygons, even-odd per path, painted in order), with
16x16 supersampled anti-aliasing. Re-run after editing the SVG and commit the
outputs, so builds never need this step."""
import re, struct, sys, zlib, os

SS = 16  # supersamples per axis, for the small sizes

def supersamples(size):
    """Fewer samples above 256 px: a 1024 px icon at 16x16 would take minutes
    in pure Python, and the larger sizes need less antialiasing. Up to 256 px
    (the .ico and .png) it stays at SS, so those outputs don't change."""
    return max(2, min(SS, 4096 // size))

def parse(svg):
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    polys = []
    for m in re.finditer(r'<path\b[^>]*>', svg):
        tag = m.group(0)
        fill = re.search(r'fill="#([0-9a-fA-F]{6})"', tag).group(1)
        d = re.search(r'\sd="([^"]+)"', tag).group(1)
        toks = re.findall(r'[MLZmlz]|-?[\d.]+', d)
        assert all(t in 'MLZ' or t[0].isdigit() or t[0] in '-.' for t in toks), d
        pts, cur, i = [], None, 0
        while i < len(toks):
            t = toks[i]
            if t in 'ML':
                cur = t; i += 1; continue
            if t == 'Z':
                i += 1; continue
            pts.append((float(toks[i]), float(toks[i + 1]))); i += 2
        polys.append((tuple(int(fill[k:k + 2], 16) for k in (0, 2, 4)), pts))
    return vb, polys

def render(vb, polys, size):
    # Coverage per pixel per fill color (union of polygons sharing a color).
    x0, y0, vw, vh = vb
    ss = supersamples(size)
    sub = size * ss
    sx, sy = sub / vw, sub / vh
    colors = {}
    for color, pts in polys:
        grid = colors.setdefault(color, [bytearray(sub) for _ in range(sub)])
        P = [((x - x0) * sx, (y - y0) * sy) for x, y in pts]
        n = len(P)
        for r in range(sub):
            yc = r + 0.5
            xs = []
            for k in range(n):
                (ax, ay), (bx, by) = P[k], P[(k + 1) % n]
                if (ay <= yc) != (by <= yc):
                    xs.append(ax + (yc - ay) * (bx - ax) / (by - ay))
            xs.sort()
            row = grid[r]
            for a, b in zip(xs[0::2], xs[1::2]):  # even-odd within one polygon
                lo = max(0, int(a + 0.5)); hi = min(sub, int(b + 0.5))
                if hi > lo:
                    row[lo:hi] = b'\x01' * (hi - lo)
    out = bytearray(size * size * 4)
    for color, grid in colors.items():
        for py in range(size):
            rows = grid[py * ss:(py + 1) * ss]
            for px in range(size):
                c = sum(sum(rw[px * ss:(px + 1) * ss]) for rw in rows)
                if not c:
                    continue
                a = c / (ss * ss)
                o = (py * size + px) * 4
                # straight-alpha "over" onto what's there
                da = out[o + 3] / 255
                oa = a + da * (1 - a)
                for ch in range(3):
                    out[o + ch] = round((color[ch] * a + out[o + ch] * da * (1 - a)) / oa)
                out[o + 3] = round(oa * 255)
    return bytes(out)

def png(rgba, size):
    raw = b''.join(b'\x00' + rgba[y * size * 4:(y + 1) * size * 4] for y in range(size))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

def ico(pngs):
    hdr = struct.pack('<HHH', 0, 1, len(pngs))
    off = 6 + 16 * len(pngs)
    dirs, data = b'', b''
    for size, blob in pngs:
        dirs += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(blob), off + len(data))
        data += blob
    return hdr + dirs + data

if __name__ == '__main__':
    src = sys.argv[1]
    iconset = '--iconset' in sys.argv[2:]
    base = os.path.splitext(src)[0]
    vb, polys = parse(open(src).read())
    pngs = [(s, png(render(vb, polys, s), s)) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)]
    open(base + '.ico', 'wb').write(ico(pngs))
    open(base + '.png', 'wb').write(pngs[-1][1])
    print(f'wrote {base}.ico ({len(pngs)} sizes) and {base}.png (256 px)')
    if iconset:
        os.makedirs(base + '.iconset', exist_ok=True)
        done = {s: blob for s, blob in pngs}
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = points * scale
                if px not in done:
                    done[px] = png(render(vb, polys, px), px)
                name = f'icon_{points}x{points}' + ('@2x' if scale == 2 else '') + '.png'
                open(os.path.join(base + '.iconset', name), 'wb').write(done[px])
        print(f'wrote {base}.iconset (10 images)')
