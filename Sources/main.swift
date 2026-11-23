// XrayViewer — a tiny, dependency-free DICOM viewer / PNG converter for macOS.
// Pure AppKit + ImageIO. Builds as a universal (arm64 + x86_64) binary.

import Cocoa
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model

struct DicomError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

struct DicomImage {
    var rows = 0, cols = 0, samples = 1
    var bitsStored = 16
    var signed = false
    var mono1 = false                 // MONOCHROME1: 0 = white, so it needs inverting for a dark background
    var gray: [UInt16] = []           // samples == 1
    var rgb: [UInt8] = []             // samples == 3, interleaved
    var slope = 1.0, intercept = 0.0
    var wc: Double?, ww: Double?      // window from the file
    var patient = "", modality = "", studyDate = "", transferSyntax = ""
    var frames = 1
}

struct WL { var c: Double; var w: Double }

enum TS {
    static let implicitLE = "1.2.840.10008.1.2"
    static let explicitLE = "1.2.840.10008.1.2.1"
    static let deflated = "1.2.840.10008.1.2.1.99"
    static let explicitBE = "1.2.840.10008.1.2.2"
    static let rle = "1.2.840.10008.1.2.5"
    static let jpegLossless: Set<String> = ["1.2.840.10008.1.2.4.57", "1.2.840.10008.1.2.4.70"]
    static let imageIO: Set<String> = ["1.2.840.10008.1.2.4.50", "1.2.840.10008.1.2.4.51",
                                       "1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91"]
}

// MARK: - DICOM parser

struct DicomParser {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }

    func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
    func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }

    static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT"]
    static let wanted: Set<UInt32> = [
        0x00020010, 0x00080020, 0x00080060, 0x00100010,
        0x00280002, 0x00280004, 0x00280006, 0x00280008, 0x00280010, 0x00280011,
        0x00280100, 0x00280101, 0x00280103, 0x00281050, 0x00281051, 0x00281052, 0x00281053,
    ]

    struct Header { var group: Int; var elem: Int; var len: Int; var hdr: Int }   // len < 0: undefined length

    func header(at p: Int, explicit: Bool) -> Header? {
        guard p >= 0, p + 8 <= b.count else { return nil }
        let g = u16(p), e = u16(p + 2)
        func L(_ v: Int) -> Int { v == 0xFFFF_FFFF ? -1 : v }
        if g == 0xFFFE { return Header(group: g, elem: e, len: L(u32(p + 4)), hdr: 8) }
        if explicit {
            let vr = String(decoding: b[(p + 4)...(p + 5)], as: UTF8.self)
            if DicomParser.longVRs.contains(vr) {
                guard p + 12 <= b.count else { return nil }
                return Header(group: g, elem: e, len: L(u32(p + 8)), hdr: 12)
            }
            return Header(group: g, elem: e, len: u16(p + 6), hdr: 8)
        }
        return Header(group: g, elem: e, len: L(u32(p + 4)), hdr: 8)
    }

    func skipSequence(_ start: Int, explicit: Bool) -> Int {
        var p = start
        while let h = header(at: p, explicit: explicit) {
            if h.group == 0xFFFE && h.elem == 0xE0DD { return p + 8 }
            if h.group == 0xFFFE && h.elem == 0xE000 {
                p = h.len < 0 ? skipItem(p + 8, explicit: explicit) : p + 8 + h.len
            } else { p += 8 }
        }
        return b.count
    }

    func skipItem(_ start: Int, explicit: Bool) -> Int {
        var p = start
        while let h = header(at: p, explicit: explicit) {
            if h.group == 0xFFFE && h.elem == 0xE00D { return p + 8 }
            p = h.len < 0 ? skipSequence(p + h.hdr, explicit: explicit) : p + h.hdr + h.len
        }
        return b.count
    }

    func fragments(from start: Int) -> [ArraySlice<UInt8>] {
        var p = start
        var out: [ArraySlice<UInt8>] = []
        while let h = header(at: p, explicit: false) {
            if h.group == 0xFFFE && h.elem == 0xE0DD { break }
            guard h.group == 0xFFFE, h.elem == 0xE000, h.len >= 0 else { break }
            let s = p + 8, e = min(s + h.len, b.count)
            out.append(b[s..<e])
            p = s + h.len
        }
        return out
    }

    enum Pixels { case native(ArraySlice<UInt8>), encapsulated([ArraySlice<UInt8>]) }

    func parse() throws -> DicomImage {
        var p = 0
        if b.count > 132, b[128] == 0x44, b[129] == 0x49, b[130] == 0x43, b[131] == 0x4D { p = 132 }
        func upper(_ x: UInt8) -> Bool { x >= 0x41 && x <= 0x5A }
        guard p + 8 <= b.count else { throw DicomError("File too small to be DICOM") }
        var explicitDS = upper(b[p + 4]) && upper(b[p + 5])
        var ts = explicitDS ? TS.explicitLE : TS.implicitLE
        var vals: [UInt32: ArraySlice<UInt8>] = [:]
        var pixels: Pixels?

        while p + 8 <= b.count {
            let g = u16(p)
            guard let h = header(at: p, explicit: g == 2 || explicitDS) else { break }
            if h.group == 0xFFFE { p += 8; continue }
            let key = UInt32(h.group) << 16 | UInt32(h.elem)
            let vp = p + h.hdr
            if key == 0x7FE0_0010 {
                if h.len < 0 { pixels = .encapsulated(Array(fragments(from: vp).dropFirst())) }
                else { pixels = .native(b[vp..<min(vp + h.len, b.count)]) }
                break
            }
            if h.len < 0 { p = skipSequence(vp, explicit: g == 2 || explicitDS); continue }
            if DicomParser.wanted.contains(key), vp + h.len <= b.count {
                vals[key] = b[vp..<(vp + h.len)]
                if key == 0x00020010 {
                    ts = clean(b[vp..<(vp + h.len)])
                    explicitDS = ts != TS.implicitLE
                }
            }
            p = vp + h.len
        }
        guard let pixels else { throw DicomError("No image data in this file (maybe a DICOMDIR index?)") }

        func str(_ k: UInt32) -> String? {
            guard let v = vals[k] else { return nil }
            let s = clean(v).split(separator: "\\").first.map(String.init) ?? ""
            return s.isEmpty ? nil : s
        }
        func us(_ k: UInt32) -> Int? {
            guard let v = vals[k], v.count >= 2 else { return nil }
            return Int(v[v.startIndex]) | Int(v[v.startIndex + 1]) << 8
        }

        var im = DicomImage()
        im.rows = us(0x00280010) ?? 0
        im.cols = us(0x00280011) ?? 0
        im.samples = us(0x00280002) ?? 1
        let bitsAlloc = us(0x00280100) ?? 16
        im.bitsStored = us(0x00280101) ?? bitsAlloc
        im.signed = (us(0x00280103) ?? 0) == 1
        let photometric = str(0x00280004) ?? "MONOCHROME2"
        let planar = us(0x00280006) ?? 0
        im.frames = Int(str(0x00280008) ?? "1") ?? 1
        im.slope = Double(str(0x00281053) ?? "") ?? 1
        im.intercept = Double(str(0x00281052) ?? "") ?? 0
        im.wc = Double(str(0x00281050) ?? "")
        im.ww = Double(str(0x00281051) ?? "")
        im.mono1 = photometric == "MONOCHROME1"
        im.patient = (str(0x00100010) ?? "").replacingOccurrences(of: "^", with: " ")
        im.modality = str(0x00080060) ?? ""
        im.studyDate = str(0x00080020) ?? ""
        im.transferSyntax = ts

        guard im.rows > 0, im.cols > 0, im.rows * im.cols < 400_000_000 else { throw DicomError("Invalid image size") }
        guard im.samples == 1 || im.samples == 3 else { throw DicomError("Unsupported samples per pixel: \(im.samples)") }
        let n = im.rows * im.cols

        switch pixels {
        case .native(let raw):
            guard ts == TS.implicitLE || ts == TS.explicitLE else {
                throw DicomError("Unsupported transfer syntax \(ts)")
            }
            if im.samples == 1 {
                im.gray = try gray(from: raw, count: n, bitsAlloc: bitsAlloc)
            } else {
                guard bitsAlloc == 8, raw.count >= n * 3 else { throw DicomError("Unsupported colour layout") }
                let s = raw.startIndex
                var out = [UInt8](repeating: 0, count: n * 3)
                if planar == 0 { for i in 0..<(n * 3) { out[i] = raw[s + i] } }
                else { for i in 0..<n { for c in 0..<3 { out[i * 3 + c] = raw[s + c * n + i] } } }
                if photometric.hasPrefix("YBR") { ybrToRGB(&out) }
                im.rgb = out
            }

        case .encapsulated(let frags):
            guard !frags.isEmpty else { throw DicomError("Empty pixel data") }
            // Single-frame files: all fragments belong to frame 1. Multi-frame: one fragment per frame (first shown).
            var frame = [UInt8]()
            if im.frames <= 1 { for f in frags { frame.append(contentsOf: f) } } else { frame = Array(frags[0]) }

            if TS.jpegLossless.contains(ts) {
                let r = try LosslessJPEG.decode(frame)
                guard r.w == im.cols, r.h == im.rows else { throw DicomError("JPEG size does not match DICOM header") }
                if r.nc == 1 { im.gray = r.px; im.bitsStored = max(im.bitsStored, r.prec) }
                else if r.nc == 3 {
                    im.samples = 3
                    let shift = max(r.prec - 8, 0)
                    im.rgb = r.px.map { UInt8(truncatingIfNeeded: Int($0) >> shift) }
                    if photometric.hasPrefix("YBR") { ybrToRGB(&im.rgb) }
                } else { throw DicomError("Unsupported JPEG component count") }
            } else if TS.imageIO.contains(ts) {
                try decodeWithImageIO(Data(frame), into: &im)
            } else if ts == TS.rle {
                try decodeRLE(frame, into: &im, bitsAlloc: bitsAlloc, planar: planar, photometric: photometric)
            } else {
                throw DicomError("Unsupported compression (\(ts)). Supported: uncompressed, RLE, JPEG, JPEG Lossless, JPEG 2000.")
            }
        }
        return im
    }

    func clean(_ s: ArraySlice<UInt8>) -> String {
        String(decoding: s, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0\n\r"))
    }

    func gray(from raw: ArraySlice<UInt8>, count n: Int, bitsAlloc: Int) throws -> [UInt16] {
        let s = raw.startIndex
        switch bitsAlloc {
        case 8:
            guard raw.count >= n else { throw DicomError("Pixel data is truncated") }
            return raw.prefix(n).map { UInt16($0) }
        case 16:
            guard raw.count >= n * 2 else { throw DicomError("Pixel data is truncated") }
            var out = [UInt16](repeating: 0, count: n)
            for i in 0..<n { out[i] = UInt16(raw[s + 2 * i]) | UInt16(raw[s + 2 * i + 1]) << 8 }
            return out
        default: throw DicomError("Unsupported bit depth: \(bitsAlloc)")
        }
    }

    func ybrToRGB(_ px: inout [UInt8]) {
        var i = 0
        func clamp(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 255)) }
        while i + 2 < px.count {
            let y = Double(px[i]), cb = Double(px[i + 1]) - 128, cr = Double(px[i + 2]) - 128
            px[i] = clamp(y + 1.402 * cr)
            px[i + 1] = clamp(y - 0.344136 * cb - 0.714136 * cr)
            px[i + 2] = clamp(y + 1.772 * cb)
            i += 3
        }
    }

    // JPEG / JPEG 2000 via the system ImageIO decoder.
    func decodeWithImageIO(_ data: Data, into im: inout DicomImage) throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw DicomError("The system image decoder could not read this compressed image")
        }
        let w = img.width, h = img.height
        guard w == im.cols, h == im.rows else { throw DicomError("Compressed image size does not match header") }
        im.wc = nil; im.ww = nil; im.slope = 1; im.intercept = 0; im.signed = false   // scaling unknown → auto-window
        if im.samples == 1 {
            let isGrayModel = img.colorSpace?.model == .monochrome
            let space = isGrayModel ? img.colorSpace! : CGColorSpaceCreateDeviceGray()
            if img.bitsPerComponent > 8 {
                var buf = [UInt16](repeating: 0, count: w * h)
                let ok: Bool = buf.withUnsafeMutableBytes { raw in
                    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 2,
                                              space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
                    else { return false }
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                    return true
                }
                if ok { im.gray = buf; im.bitsStored = 16; return }
            }
            var buf = [UInt8](repeating: 0, count: w * h)
            let ok: Bool = buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { throw DicomError("Could not convert decoded image") }
            im.gray = buf.map { UInt16($0) }
            im.bitsStored = 8
        } else {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ok: Bool = buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { throw DicomError("Could not convert decoded image") }
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { rgb[3 * i] = buf[4 * i]; rgb[3 * i + 1] = buf[4 * i + 1]; rgb[3 * i + 2] = buf[4 * i + 2] }
            im.rgb = rgb
        }
    }

    // DICOM RLE (PackBits per byte plane).
    func decodeRLE(_ f: [UInt8], into im: inout DicomImage, bitsAlloc: Int, planar: Int, photometric: String) throws {
        guard f.count >= 64 else { throw DicomError("Bad RLE data") }
        func u32le(_ p: Int) -> Int { Int(f[p]) | Int(f[p + 1]) << 8 | Int(f[p + 2]) << 16 | Int(f[p + 3]) << 24 }
        let nSeg = u32le(0)
        let n = im.rows * im.cols
        var planes: [[UInt8]] = []
        for s in 0..<min(nSeg, 15) {
            var p = u32le(4 + 4 * s)
            let end = s + 1 < nSeg ? u32le(8 + 4 * s) : f.count
            var out = [UInt8](); out.reserveCapacity(n)
            while p < min(end, f.count), out.count < n {
                let c = Int(Int8(bitPattern: f[p])); p += 1
                if c >= 0 {
                    let k = min(c + 1, f.count - p); if k > 0 { out.append(contentsOf: f[p..<(p + k)]) }; p += c + 1
                } else if c != -128, p < f.count {
                    out.append(contentsOf: repeatElement(f[p], count: 1 - c)); p += 1
                }
            }
            if out.count < n { out.append(contentsOf: repeatElement(0, count: n - out.count)) }
            planes.append(Array(out.prefix(n)))
        }
        if im.samples == 1 {
            if bitsAlloc == 8, planes.count >= 1 { im.gray = planes[0].map { UInt16($0) } }
            else if bitsAlloc == 16, planes.count >= 2 {
                var g = [UInt16](repeating: 0, count: n)
                for i in 0..<n { g[i] = UInt16(planes[0][i]) << 8 | UInt16(planes[1][i]) }
                im.gray = g
            } else { throw DicomError("Unsupported RLE layout") }
        } else {
            guard planes.count >= 3, bitsAlloc == 8 else { throw DicomError("Unsupported RLE layout") }
            var rgb = [UInt8](repeating: 0, count: n * 3)
            for i in 0..<n { for c in 0..<3 { rgb[3 * i + c] = planes[c][i] } }
            if photometric.hasPrefix("YBR") { ybrToRGB(&rgb) }
            im.rgb = rgb
        }
    }
}

// MARK: - Lossless JPEG (ITU T.81 process 14, SOF3) — what ImageIO can't do

struct HuffTable {
    var maxcode = [Int](repeating: -1, count: 17)
    var mincode = [Int](repeating: 0, count: 17)
    var valptr = [Int](repeating: 0, count: 17)
    var vals: [UInt8] = []
    init() {}
    init(counts: [Int], vals: [UInt8]) {
        self.vals = vals
        var code = 0, k = 0
        for l in 1...16 {
            valptr[l] = k; mincode[l] = code
            code += counts[l - 1]; k += counts[l - 1]
            maxcode[l] = counts[l - 1] > 0 ? code - 1 : -1
            code <<= 1
        }
    }
}

struct BitReader {
    let b: [UInt8]
    var pos: Int
    var buf = 0, cnt = 0
    init(_ b: [UInt8], pos: Int) { self.b = b; self.pos = pos }

    mutating func bit() -> Int {
        if cnt == 0 {
            var c = 0
            if pos < b.count {
                c = Int(b[pos])
                if c == 0xFF {
                    if pos + 1 < b.count, b[pos + 1] == 0 { pos += 2 } else { c = 0 }   // marker: feed zeros
                } else { pos += 1 }
            }
            buf = c; cnt = 8
        }
        cnt -= 1
        return (buf >> cnt) & 1
    }
    mutating func bits(_ n: Int) -> Int { var v = 0; for _ in 0..<n { v = v << 1 | bit() }; return v }
    mutating func huff(_ t: HuffTable) -> Int {
        var code = 0
        for l in 1...16 {
            code = code << 1 | bit()
            if t.maxcode[l] >= 0, code <= t.maxcode[l] {
                let i = t.valptr[l] + code - t.mincode[l]
                return i < t.vals.count ? Int(t.vals[i]) : 0
            }
        }
        return 0
    }
    mutating func restart() {
        cnt = 0
        while pos + 1 < b.count {
            if b[pos] == 0xFF, b[pos + 1] >= 0xD0, b[pos + 1] <= 0xD7 { pos += 2; return }
            pos += 1
        }
    }
}

enum LosslessJPEG {
    static func decode(_ b: [UInt8]) throws -> (w: Int, h: Int, nc: Int, prec: Int, px: [UInt16]) {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw DicomError("Not a JPEG stream") }
        func be16(_ p: Int) -> Int { Int(b[p]) << 8 | Int(b[p + 1]) }
        var p = 2
        var prec = 0, X = 0, Y = 0, nc = 0
        var tables = [Int: HuffTable]()
        var restartInterval = 0
        var compTable: [Int] = []
        var ss = 1, pt = 0
        scan: while p + 4 <= b.count {
            guard b[p] == 0xFF else { p += 1; continue }
            let m = b[p + 1]
            if m == 0xFF { p += 1; continue }
            p += 2
            switch m {
            case 0xD8, 0x01, 0xD0...0xD7: continue
            case 0xD9: throw DicomError("JPEG ended before image data")
            case 0xC3:
                prec = Int(b[p + 2]); Y = be16(p + 3); X = be16(p + 5); nc = Int(b[p + 7])
                for i in 0..<nc where b[p + 9 + 3 * i] != 0x11 { throw DicomError("Subsampled lossless JPEG is not supported") }
                p += be16(p)
            case 0xC0, 0xC1, 0xC2, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF, 0xF7:
                throw DicomError("JPEG process not supported as lossless")
            case 0xC4:
                let end = p + be16(p); var q = p + 2
                while q + 17 <= end {
                    let tcTh = Int(b[q]); q += 1
                    let counts = (0..<16).map { Int(b[q + $0]) }; q += 16
                    let total = counts.reduce(0, +)
                    guard q + total <= b.count else { throw DicomError("Corrupt JPEG tables") }
                    tables[tcTh & 0x0F] = HuffTable(counts: counts, vals: Array(b[q..<(q + total)])); q += total
                }
                p = end
            case 0xDD: restartInterval = be16(p + 2); p += be16(p)
            case 0xDA:
                let ns = Int(b[p + 2])
                compTable = (0..<ns).map { Int(b[p + 4 + 2 * $0] >> 4) }
                ss = Int(b[p + 3 + 2 * ns]); pt = Int(b[p + 5 + 2 * ns] & 0x0F)
                p += be16(p)
                break scan
            default: p += be16(p)
            }
        }
        guard X > 0, Y > 0, nc > 0, compTable.count == nc, prec >= 2, prec <= 16 else { throw DicomError("Corrupt lossless JPEG header") }
        let tbls = try compTable.map { (id: Int) -> HuffTable in
            guard let t = tables[id] else { throw DicomError("Missing JPEG Huffman table") }
            return t
        }

        var out = [UInt16](repeating: 0, count: X * Y * nc)
        var br = BitReader(b, pos: p)
        let initPred = 1 << (prec - pt - 1)
        var mcu = 0
        var atRestart = true
        var restartY = 0
        let stride = X * nc
        for y in 0..<Y {
            for x in 0..<X {
                if restartInterval > 0, mcu > 0, mcu % restartInterval == 0 {
                    br.restart(); atRestart = true; restartY = y
                }
                for c in 0..<nc {
                    let t = br.huff(tbls[c])
                    var diff = 0
                    if t == 16 { diff = 32768 }
                    else if t > 0 {
                        let v = br.bits(t)
                        diff = v < (1 << (t - 1)) ? v - (1 << t) + 1 : v
                    }
                    let i = y * stride + x * nc + c
                    var pred: Int
                    if atRestart { pred = initPred }
                    else if y == 0 || y == restartY { pred = Int(out[i - nc]) }
                    else if x == 0 { pred = Int(out[i - stride]) }
                    else {
                        let ra = Int(out[i - nc]), rb = Int(out[i - stride]), rc = Int(out[i - stride - nc])
                        switch ss {
                        case 2: pred = rb
                        case 3: pred = rc
                        case 4: pred = ra + rb - rc
                        case 5: pred = ra + ((rb - rc) >> 1)
                        case 6: pred = rb + ((ra - rc) >> 1)
                        case 7: pred = (ra + rb) >> 1
                        default: pred = ra
                        }
                    }
                    out[i] = UInt16(truncatingIfNeeded: pred + diff)
                }
                atRestart = false
                mcu += 1
            }
        }
        if pt > 0 { for i in 0..<out.count { out[i] <<= UInt16(pt) } }
        return (X, Y, nc, prec, out)
    }
}

// MARK: - Loading, windowing, rendering

enum Loader {
    static func load(_ url: URL) throws -> DicomImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try DicomParser([UInt8](data)).parse()
    }

    static let exts: Set<String> = ["dcm", "dicom", "dic", "ima"]

    static func looksLikeDicom(_ u: URL) -> Bool {
        if u.lastPathComponent == "DICOMDIR" { return false }
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        if exts.contains(u.pathExtension.lowercased()) { return true }
        guard let fh = try? FileHandle(forReadingFrom: u), let d = try? fh.read(upToCount: 132) else { return false }
        try? fh.close()
        return d.count == 132 && d[128] == 0x44 && d[129] == 0x49 && d[130] == 0x43 && d[131] == 0x4D
    }

    static func collect(_ inputs: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let f as URL in en where looksLikeDicom(f) { out.append(f) }
                }
            } else { out.append(u) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

func rawValue(_ i: Int, _ im: DicomImage) -> Double {
    let size = 1 << min(max(im.bitsStored, 1), 16)
    var v = Double(i)
    if im.signed && i >= size / 2 { v -= Double(size) }
    return v * im.slope + im.intercept
}

func autoWL(_ im: DicomImage) -> WL {
    guard im.samples == 1, !im.gray.isEmpty else { return WL(c: 128, w: 256) }
    let bits = min(max(im.bitsStored, 1), 16)
    let size = 1 << bits, mask = UInt16(truncatingIfNeeded: size - 1)
    var hist = [Int](repeating: 0, count: size)
    for g in im.gray { hist[Int(g & mask)] += 1 }
    let total = im.gray.count
    func percentile(_ q: Double) -> Int {
        let target = Int(Double(total) * q); var acc = 0
        for i in 0..<size { acc += hist[i]; if acc > target { return i } }
        return size - 1
    }
    var lo = rawValue(percentile(0.005), im), hi = rawValue(percentile(0.995), im)
    if hi <= lo {
        let used = hist.indices.filter { hist[$0] > 0 }
        lo = rawValue(used.first ?? 0, im); hi = rawValue(used.last ?? 1, im)
    }
    return WL(c: (lo + hi) / 2, w: max(hi - lo, 1))
}

func defaultWL(_ im: DicomImage) -> WL {
    if im.samples == 1, let c = im.wc, let w = im.ww, w > 1 { return WL(c: c, w: w) }
    return autoWL(im)
}

func render(_ im: DicomImage, wl: WL, invert: Bool) -> CGImage? {
    let w = im.cols, h = im.rows
    if im.samples == 3 {
        guard im.rgb.count >= w * h * 3, let prov = CGDataProvider(data: Data(im.rgb) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    guard im.gray.count >= w * h else { return nil }
    let bits = min(max(im.bitsStored, 1), 16)
    let size = 1 << bits, mask = UInt16(truncatingIfNeeded: size - 1)
    let lo = wl.c - wl.w / 2, inv = 1.0 / max(wl.w, 1e-6)
    var lut = [UInt8](repeating: 0, count: size)
    for i in 0..<size {
        let t = min(max((rawValue(i, im) - lo) * inv, 0), 1)
        let o = UInt8(t * 255 + 0.5)
        lut[i] = invert ? 255 - o : o
    }
    var out = [UInt8](repeating: 0, count: w * h)
    im.gray.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            lut.withUnsafeBufferPointer { l in
                for i in 0..<(w * h) { dst[i] = l[Int(src[i] & mask)] }
            }
        }
    }
    guard let prov = CGDataProvider(data: Data(out) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func writePNG(_ cg: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw DicomError("Cannot create \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { throw DicomError("Failed to write \(url.lastPathComponent)") }
}

/// Converts every DICOM in `inputs` to PNG in `outDir` with a dark (bones-bright) look. Returns (ok, failures).
func convertAll(_ inputs: [URL], to outDir: URL, invert: Bool, progress: ((Int, Int) -> Void)? = nil) -> (Int, [String]) {
    let files = Loader.collect(inputs)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var used = Set<String>(), ok = 0, failures: [String] = []
    for (n, f) in files.enumerated() {
        autoreleasepool {
            do {
                let im = try Loader.load(f)
                guard let cg = render(im, wl: defaultWL(im), invert: im.mono1 != invert) else { throw DicomError("render failed") }
                var name = f.deletingPathExtension().lastPathComponent, k = 2
                while used.contains(name.lowercased()) { name = f.deletingPathExtension().lastPathComponent + "-\(k)"; k += 1 }
                used.insert(name.lowercased())
                try writePNG(cg, to: outDir.appendingPathComponent(name + ".png"))
                ok += 1
            } catch { failures.append("\(f.lastPathComponent): \(error)") }
        }
        progress?(n + 1, files.count)
    }
    return (ok, failures)
}

// MARK: - View

final class Canvas: NSView {
    var cg: CGImage? { didSet { needsDisplay = true } }
    var overlay: [String] = [] { didSet { needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var pan = CGPoint.zero { didSet { needsDisplay = true } }
    var onWindowDrag: ((CGFloat, CGFloat) -> Void)?
    var onReset: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }

    var fitScale: CGFloat {
        guard let cg, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / CGFloat(cg.width), bounds.height / CGFloat(cg.height))
    }
    func fit() { zoom = 1; pan = .zero }
    func actualSize() { zoom = 1 / fitScale; pan = .zero }

    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        if let cg {
            let s = fitScale * zoom
            let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
            let r = CGRect(x: (bounds.width - w) / 2 + pan.x, y: (bounds.height - h) / 2 + pan.y, width: w, height: h)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.interpolationQuality = s >= 2 ? .none : .high
            ctx.draw(cg, in: r)
        }
        let shadow = NSShadow(); shadow.shadowColor = .black; shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.85, alpha: 1), .shadow: shadow,
        ]
        for (i, line) in overlay.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 10, y: bounds.height - 22 - CGFloat(i) * 15), withAttributes: attrs)
        }
        if let message {
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
            let sz = (message as NSString).size(withAttributes: big)
            (message as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: big)
        }
    }

    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onReset?() } }
    override func mouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) { pan.x += e.deltaX; pan.y -= e.deltaY }
        else { onWindowDrag?(e.deltaX, e.deltaY) }
    }
    override func rightMouseDragged(with e: NSEvent) { pan.x += e.deltaX; pan.y -= e.deltaY }
    override func otherMouseDragged(with e: NSEvent) { pan.x += e.deltaX; pan.y -= e.deltaY }
    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas { pan.x += e.scrollingDeltaX; pan.y += e.scrollingDeltaY }
        else { zoom = min(max(zoom * (1 + 0.05 * e.scrollingDeltaY), 0.05), 60) }
    }
    override func magnify(with e: NSEvent) { zoom = min(max(zoom * (1 + e.magnification), 0.05), 60) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls); return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let canvas = Canvas()
    var urls: [URL] = []
    var index = 0
    var img: DicomImage?
    var wl = WL(c: 128, w: 256)
    var userInvert = false
    var showPatient = false

    func applicationWillFinishLaunching(_ n: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 400)
        window.contentView = canvas
        window.title = "X-ray Viewer"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        canvas.message = "Open a DICOM file or folder (⌘O), or drop it here"
        canvas.onDrop = { [weak self] in self?.open($0) }
        canvas.onReset = { [weak self] in self?.resetWindow() }
        canvas.onWindowDrag = { [weak self] dx, dy in
            guard let self, self.img?.samples == 1 else { return }
            let k = max(1, self.wl.w / 300)
            self.wl.w = max(1, self.wl.w + Double(dx) * k)
            self.wl.c -= Double(dy) * k
            self.refresh()
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if urls.isEmpty {
            let args = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
            if !args.isEmpty { open(args.map { URL(fileURLWithPath: $0) }) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ app: NSApplication, open urls: [URL]) { open(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // Menu
    func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = sel == nil ? nil : (sel == #selector(NSApplication.terminate(_:)) ? NSApp : self)
            menu.addItem(it)
        }
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m; return m
        }
        let app = submenu("X-ray Viewer")
        add(app, "Quit X-ray Viewer", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open…", #selector(openPanel), "o")
        file.addItem(.separator())
        add(file, "Export Current as PNG…", #selector(exportCurrent), "e")
        add(file, "Export All as PNG…", #selector(exportAll), "E", [.command, .shift])
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let view = submenu("View")
        add(view, "Previous Image", #selector(prev), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [])
        add(view, "Next Image", #selector(next), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [])
        view.addItem(.separator())
        add(view, "Invert", #selector(toggleInvert), "i", [])
        add(view, "Reset Window/Level", #selector(resetWindowAction), "r", [])
        add(view, "Auto Window/Level", #selector(autoWindow), "a", [])
        add(view, "Show Patient Info", #selector(togglePatient), "i", .command)
        view.addItem(.separator())
        add(view, "Fit to Window", #selector(fitAction), "0")
        add(view, "Actual Size", #selector(actualAction), "1")
        add(view, "Zoom In", #selector(zoomIn), "+")
        add(view, "Zoom Out", #selector(zoomOut), "-")
        NSApp.mainMenu = main
    }

    @objc func prev() { step(-1) }
    @objc func next() { step(1) }
    @objc func toggleInvert() { userInvert.toggle(); refresh() }
    @objc func resetWindowAction() { resetWindow() }
    @objc func autoWindow() { if let im = img { wl = autoWL(im); refresh() } }
    @objc func togglePatient() { showPatient.toggle(); refresh() }
    @objc func fitAction() { canvas.fit() }
    @objc func actualAction() { canvas.actualSize() }
    @objc func zoomIn() { canvas.zoom = min(canvas.zoom * 1.25, 60) }
    @objc func zoomOut() { canvas.zoom = max(canvas.zoom / 1.25, 0.05) }

    func resetWindow() { if let im = img { wl = defaultWL(im); refresh() } }

    func step(_ d: Int) {
        guard urls.count > 1 else { return }
        index = (index + d + urls.count) % urls.count
        load()
    }

    @objc func openPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose DICOM files or a folder containing them"
        p.beginSheetModal(for: window) { [weak self] r in if r == .OK { self?.open(p.urls) } }
    }

    func open(_ inputs: [URL]) {
        let files = Loader.collect(inputs)
        guard !files.isEmpty else { alert("No DICOM files found", "Nothing in the selection looked like a DICOM file."); return }
        urls = files; index = 0; canvas.fit(); load()
    }

    func load() {
        let url = urls[index]
        do {
            let im = try Loader.load(url)
            img = im; wl = defaultWL(im); canvas.message = nil
        } catch {
            img = nil; canvas.cg = nil; canvas.message = "\(url.lastPathComponent): \(error)"
        }
        refresh()
    }

    func refresh() {
        guard let im = img else {
            canvas.overlay = []; window.title = urls.isEmpty ? "X-ray Viewer" : urls[index].lastPathComponent
            return
        }
        canvas.cg = render(im, wl: wl, invert: im.mono1 != userInvert)
        let name = urls[index].lastPathComponent
        window.title = urls.count > 1 ? "\(name)  (\(index + 1)/\(urls.count))" : name
        var lines = ["\(im.cols) × \(im.rows)"]
        if im.samples == 1 { lines.append(String(format: "W %.0f  L %.0f", wl.w, wl.c)) }
        if showPatient {
            lines.insert(contentsOf: [im.patient, [im.modality, im.studyDate].filter { !$0.isEmpty }.joined(separator: "  ")].filter { !$0.isEmpty }, at: 0)
        }
        canvas.overlay = lines
    }

    // Export
    @objc func exportCurrent() {
        guard let im = img, let cg = render(im, wl: wl, invert: im.mono1 != userInvert) else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = urls[index].deletingPathExtension().lastPathComponent + ".png"
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            do { try writePNG(cg, to: u) } catch { self?.alert("Export failed", "\(error)") }
        }
    }

    @objc func exportAll() {
        guard !urls.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Export Here"; p.message = "Choose a folder for the PNG files"
        let files = urls, inv = userInvert
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let dir = p.url else { return }
            self?.window.title = "Exporting…"
            DispatchQueue.global(qos: .userInitiated).async {
                let (ok, fails) = convertAll(files, to: dir, invert: inv)
                DispatchQueue.main.async {
                    self?.refresh()
                    self?.alert("Exported \(ok) of \(files.count) image\(files.count == 1 ? "" : "s")",
                                fails.isEmpty ? dir.path : fails.prefix(8).joined(separator: "\n"))
                }
            }
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.beginSheetModal(for: window)
    }
}

// MARK: - Entry point

// Headless mode: XrayViewer --convert <file-or-folder>... <output-folder> [--invert]
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--convert" {
    var rest = Array(args.dropFirst())
    let inv = rest.contains("--invert"); rest.removeAll { $0 == "--invert" }
    guard rest.count >= 2 else { print("usage: --convert <file-or-folder>... <output-folder> [--invert]"); exit(2) }
    let out = URL(fileURLWithPath: rest.removeLast())
    let (ok, fails) = convertAll(rest.map { URL(fileURLWithPath: $0) }, to: out, invert: inv)
    print("converted \(ok) file(s) → \(out.path)")
    fails.forEach { print("FAILED \($0)") }
    exit(fails.isEmpty && ok > 0 ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
