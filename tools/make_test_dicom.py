import struct, sys, os, math
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
W, H = 256, 192

def img(cx=128, cy=96, bright=2500, bar=65):
    px = []
    for y in range(H):
        for x in range(W):
            d = math.hypot(x-cx, y-cy)
            v = 300 + int(bright*max(0, 1 - d/90))           # bright "bone" disc
            if bar-5 < x < bar+5: v += 900                       # vertical bar
            if (x//16 + y//16) % 2 == 0: v += 60           # faint checker
            px.append(min(v, 4095))
    return px
PX = img()

LONG = {b"OB", b"OW", b"SQ", b"UN", b"UT", b"OF"}
def el(g, e, vr, val):
    if vr in LONG:
        return struct.pack("<HH2sHI", g, e, vr, 0, len(val)) + val
    return struct.pack("<HH2sH", g, e, vr, len(val)) + val
def s(v):
    v = v.encode(); return v + (b" " if len(v) % 2 else b"")
def us(v): return struct.pack("<H", v)

def dataset(ts, pixel_el, photometric, bits_alloc=16, signed=0, tail=b"", patient="Test^Patient", date="20261101", time="101500", series=""):
    seq_item = struct.pack("<HHI", 0xFFFE, 0xE000, 0xFFFFFFFF) + el(0x28, 0x10, b"US", us(8)) \
        + struct.pack("<HHI", 0xFFFE, 0xE00D, 0)
    seq = struct.pack("<HH2sHI", 0x08, 0x1140, b"SQ", 0, 0xFFFFFFFF) + seq_item + struct.pack("<HHI", 0xFFFE, 0xE0DD, 0)
    sd = el(0x08, 0x103E, b"LO", s(series.encode("latin-1").decode("latin-1")) if False else (series.encode("latin-1") + (b" " if len(series.encode("latin-1")) % 2 else b""))) if series else b""
    d  = el(0x08, 0x05, b"CS", s("ISO_IR 100")) + el(0x08, 0x20, b"DA", s(date)) + el(0x08, 0x30, b"TM", s(time)) + el(0x08, 0x60, b"CS", s("DX")) + sd + seq
    d += el(0x10, 0x10, b"PN", s(patient))
    d += el(0x28, 0x02, b"US", us(1)) + el(0x28, 0x04, b"CS", s(photometric))
    d += el(0x28, 0x10, b"US", us(H)) + el(0x28, 0x11, b"US", us(W))
    d += el(0x28, 0x100, b"US", us(bits_alloc)) + el(0x28, 0x101, b"US", us(12 if bits_alloc == 16 else 8))
    d += el(0x28, 0x102, b"US", us(11 if bits_alloc == 16 else 7)) + el(0x28, 0x103, b"US", us(signed))
    return d + pixel_el

def wrap(ts, body):
    meta = el(0x02, 0x10, b"UI", s(ts))
    meta = el(0x02, 0x00, b"UL", struct.pack("<I", len(meta))) + meta
    return b"\0"*128 + b"DICM" + meta + body

native = b"".join(struct.pack("<H", v) for v in PX)
EXPL, IMPL = "1.2.840.10008.1.2.1", "1.2.840.10008.1.2"

# 1) explicit LE, MONOCHROME1 (inverted data), 2) explicit LE MONOCHROME2
inv = b"".join(struct.pack("<H", 4095 - v) for v in PX)
open(f"{out}/explicit_mono1.dcm", "wb").write(wrap(EXPL, dataset(EXPL, el(0x7FE0, 0x10, b"OW", inv), "MONOCHROME1")))
open(f"{out}/explicit_mono2.dcm", "wb").write(wrap(EXPL, dataset(EXPL, el(0x7FE0, 0x10, b"OW", native), "MONOCHROME2")))

# 3) RLE
def packbits_lits(data):
    o = bytearray()
    for i in range(0, len(data), 128):
        c = data[i:i+128]; o.append(len(c)-1); o += c
    return bytes(o)
hi = bytes(v >> 8 for v in PX); lo = bytes(v & 255 for v in PX)
s0, s1 = packbits_lits(hi), packbits_lits(lo)
rle = struct.pack("<I", 2) + struct.pack("<I", 64) + struct.pack("<I", 64+len(s0)) + b"\0"*(15-2)*4 + s0 + s1
def encap(frag):
    if len(frag) % 2: frag += b"\0"
    return struct.pack("<HHI", 0xFFFE, 0xE000, 0) + struct.pack("<HHI", 0xFFFE, 0xE000, len(frag)) + frag + struct.pack("<HHI", 0xFFFE, 0xE0DD, 0)
def encap_el(frag): return struct.pack("<HH2sHI", 0x7FE0, 0x10, b"OB", 0, 0xFFFFFFFF) + encap(frag)
RLE = "1.2.840.10008.1.2.5"
open(f"{out}/rle.dcm", "wb").write(wrap(RLE, dataset(RLE, encap_el(rle), "MONOCHROME2")))

# 4) Lossless JPEG (SOF3, predictor 1, 12-bit), with restart-free single scan
P = 12
bits = []
def put(v, n):
    for i in range(n-1, -1, -1): bits.append((v >> i) & 1)
for y in range(H):
    for x in range(W):
        i = y*W + x
        pred = (1 << (P-1)) if i == 0 else (PX[i-1] if y == 0 else (PX[i-W] if x == 0 else PX[i-1]))
        d = PX[i] - pred
        t = abs(d).bit_length()
        put(t, 5)
        if t: put(d if d >= 0 else (d - 1) & ((1 << t) - 1), t)
while len(bits) % 8: bits.append(1)
raw = bytes(int("".join(map(str, bits[i:i+8])), 2) for i in range(0, len(bits), 8))
raw = raw.replace(b"\xff", b"\xff\x00")
counts = [0]*16; counts[4] = 17
jpg = b"\xff\xd8" + b"\xff\xc3" + struct.pack(">HBHHB", 11, P, H, W, 1) + bytes([1, 0x11, 0]) \
    + b"\xff\xc4" + struct.pack(">H", 2+1+16+17) + bytes([0]) + bytes(counts) + bytes(range(17)) \
    + b"\xff\xda" + struct.pack(">HB", 8, 1) + bytes([1, 0x00]) + bytes([1, 0, 0]) + raw + b"\xff\xd9"
LJ = "1.2.840.10008.1.2.4.70"
open(f"{out}/lossless_jpeg.dcm", "wb").write(wrap(LJ, dataset(LJ, encap_el(jpg), "MONOCHROME2")))

# 5) implicit VR, no meta/preamble-less variant is rare; do implicit with preamble
def il(g, e, val): return struct.pack("<HHI", g, e, len(val)) + val
d = il(0x28,0x02,us(1)) + il(0x28,0x04,s("MONOCHROME2")) + il(0x28,0x10,us(H)) + il(0x28,0x11,us(W)) \
  + il(0x28,0x100,us(16)) + il(0x28,0x101,us(12)) + il(0x28,0x103,us(0)) + il(0x7FE0,0x10,native)
open(f"{out}/implicit.dcm", "wb").write(wrap(IMPL, d))

# 6) A small "history": several patients with scans on different dates (for the library / compare view)
series = os.path.join(out, "series"); os.makedirs(series, exist_ok=True)
people = {
    "Muster^Anna": [("20240312", "093000", 120, 90, "Thorax"), ("20250118", "141500", 128, 96, "Unterschenkel links"),
                    ("20251107", "081000", 136, 100, "Unterschenkel links"), ("20251107", "082500", 110, 96, "Sprunggelenk links"),
                    ("20251107", "083900", 150, 90, "Fuß seitlich")],
    "Beispiel^Jonas": [("20250605", "110000", 100, 96, "Kniegelenk rechts"), ("20251020", "160000", 150, 96, "Kniegelenk rechts")],
    "Schmidt^Eva": [("20251201", "120000", 128, 70, "Handgelenk")],
}
n = 0
for name, scans in people.items():
    for date, time, cx, cy, ser in scans:
        n += 1
        data = b"".join(struct.pack("<H", 4095 - v) for v in img(cx=cx, cy=cy, bright=1800 + 150*n, bar=40 + 10*n))
        open(f"{series}/{name.split('^')[0].lower()}_{date}_{time}.dcm", "wb").write(
            wrap(EXPL, dataset(EXPL, el(0x7FE0, 0x10, b"OW", data), "MONOCHROME1", patient=name, date=date, time=time, series=ser)))
print("ok")
