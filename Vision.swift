import CoreImage
import UIKit
import Vision

// MARK: - App Groups 跨进程共享存储（连接 Broadcast Extension 与主 App）

enum SharedStore {
    static let suiteName = "group.com.example.xqassist"
    static let darwinNotifyName = "com.example.xqassist.boardUpdated"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func saveCropRect(_ rect: CGRect) {
        let arr = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        defaults?.set(arr, forKey: "board_crop_rect")
    }

    static func loadCropRect() -> CGRect {
        if let arr = defaults?.array(forKey: "board_crop_rect") as? [Double], arr.count == 4 {
            return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
        return CGRect(x: 0.05, y: 0.24, width: 0.90, height: 0.50)
    }

    static func saveBoard(_ board: [Int8], flipped: Bool, unknownCount: Int, info: String) {
        let data = Data(bytes: board, count: 90)
        defaults?.set(data, forKey: "latest_board")
        defaults?.set(flipped, forKey: "latest_flipped")
        defaults?.set(unknownCount, forKey: "latest_unknown")
        defaults?.set(info, forKey: "latest_info")

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotifyName as CFString),
            nil, nil, true
        )
    }

    static func loadBoard() -> (board: [Int8], flipped: Bool, unknownCount: Int, info: String)? {
        guard let data = defaults?.data(forKey: "latest_board"), data.count == 90 else { return nil }
        let board = data.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
        let flipped = defaults?.bool(forKey: "latest_flipped") ?? false
        let unknown = defaults?.integer(forKey: "latest_unknown") ?? 0
        let info = defaults?.string(forKey: "latest_info") ?? ""
        return (board, flipped, unknown, info)
    }
}

// MARK: - OCR（针对无反光屏幕图像的棋子文字识别）

struct Hit {
    var type: Int       // 1 帅 2 仕 3 相 4 马 5 车 6 炮 7 兵
    var side: Int       // 1 红, -1 黑, 0 字形无法区分
    var conf: Float
}

enum Glyph {
    static let table: [Character: (Int, Int)] = [
        "帅": (1, 1), "帥": (1, 1), "将": (1, -1), "將": (1, -1),
        "仕": (2, 1), "士": (2, -1), "相": (3, 1), "象": (3, -1),
        "马": (4, 0), "馬": (4, 0), "傌": (4, 1),
        "车": (5, 0), "車": (5, 0), "俥": (5, 1),
        "炮": (6, 0), "砲": (6, -1), "兵": (7, 1), "卒": (7, -1),
    ]
}

enum OCR {
    static func run(_ cg: CGImage, minHeight: Float) -> [Hit] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        req.usesLanguageCorrection = false
        req.minimumTextHeight = minHeight
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        var hits = [Hit]()
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            for ch in cand.string {
                if let g = Glyph.table[ch] { hits.append(Hit(type: g.0, side: g.1, conf: cand.confidence)) }
            }
        }
        return hits
    }
}

// MARK: - 屏幕图像处理：直接按校准比例裁剪 + 特征匹配

final class Rectified {
    let cg: CGImage
    let rgba: [UInt8]
    let lum: [UInt8]
    init(cg: CGImage, rgba: [UInt8], lum: [UInt8]) { self.cg = cg; self.rgba = rgba; self.lum = lum }
}

enum Analyzer {
    static let ctx = CIContext(options: [.cacheIntermediates: false])
    static let cell = 96, W = 864, H = 960

    static func cropScreen(_ pb: CVPixelBuffer, normalizedRect: CGRect) -> Rectified? {
        let ci = CIImage(cvPixelBuffer: pb)
        let iw = ci.extent.width
        let ih = ci.extent.height
        guard iw > 10, ih > 10 else { return nil }

        let cellW = normalizedRect.width / 8.0
        let cellH = normalizedRect.height / 9.0
        let x0 = max(0, (normalizedRect.minX - cellW * 0.5) * iw)
        let yTop = max(0, (normalizedRect.minY - cellH * 0.5) * ih)
        let w = min(iw - x0, (normalizedRect.width + cellW) * iw)
        let h = min(ih - yTop, (normalizedRect.height + cellH) * ih)
        let y0 = ih - yTop - h

        let crop = ci.cropped(to: CGRect(x: x0, y: y0, width: w, height: h))
        let t = CGAffineTransform(translationX: -crop.extent.origin.x, y: -crop.extent.origin.y)
            .concatenating(CGAffineTransform(scaleX: CGFloat(W) / crop.extent.width, y: CGFloat(H) / crop.extent.height))

        guard let cg = ctx.createCGImage(crop.transformed(by: t), from: CGRect(x: 0, y: 0, width: W, height: H)) else { return nil }
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                    bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return nil }

        var lum = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let pr = Int(data[4 * i])
            let pg = Int(data[4 * i + 1])
            let pbl = Int(data[4 * i + 2])
            lum[i] = UInt8((299 * pr + 587 * pg + 114 * pbl) / 1000)
        }
        return Rectified(cg: cg, rgba: data, lum: lum)
    }

    static func cellScore(_ R: Rectified, _ r: Int, _ c: Int) -> Float {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var n1 = 0, dr = 0, dg = 0, db = 0
        var nc = 0, cr = 0, cg2 = 0, cb = 0
        var nr = 0, ink = 0
        for dy in -47...47 {
            for dx in -47...47 {
                let d2 = dx * dx + dy * dy
                let o = (cy + dy) * W + cx + dx
                let p = o * 4
                if d2 <= 676 {
                    n1 += 1
                    dr += Int(R.rgba[p]); dg += Int(R.rgba[p + 1]); db += Int(R.rgba[p + 2])
                } else if d2 >= 1156 && d2 <= 1936 {
                    nr += 1
                    let rr = Int(R.rgba[p]), gg = Int(R.rgba[p + 1]), bb = Int(R.rgba[p + 2])
                    let isRed = rr > 110 && rr > 2 * gg && rr > 2 * bb
                    if isRed || Int(R.lum[o]) < 90 { ink += 1 }
                }
                if abs(dx) >= 36 && abs(dy) >= 36 {
                    nc += 1
                    cr += Int(R.rgba[p]); cg2 += Int(R.rgba[p + 1]); cb += Int(R.rgba[p + 2])
                }
            }
        }
        let a = Float(max(n1, 1)), b = Float(max(nc, 1))
        let ex = Float(dr) / a - Float(cr) / b
        let ey = Float(dg) / a - Float(cg2) / b
        let ez = Float(db) / a - Float(cb) / b
        let cdist = (ex * ex + ey * ey + ez * ez).squareRoot() / 255
        let ring = Float(ink) / Float(max(nr, 1))
        return cdist + 0.6 * ring
    }

    static func descriptor(_ R: Rectified, _ r: Int, _ c: Int) -> [Float] {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var d = [Float](repeating: 0, count: 576)
        var mean: Float = 0, cnt: Float = 0
        for j in 0..<24 {
            for i in 0..<24 {
                let ii = i - 12, jj = j - 12
                if ii * ii + jj * jj > 144 { continue }
                var s = 0
                for yy in 0..<3 {
                    for xx in 0..<3 {
                        let x = cx - 36 + i * 3 + xx
                        let y = cy - 36 + j * 3 + yy
                        s += Int(R.lum[y * W + x])
                    }
                }
                let v = Float(s) / 9
                d[j * 24 + i] = v
                mean += v; cnt += 1
            }
        }
        mean /= cnt
        var nrm: Float = 0
        for j in 0..<24 {
            for i in 0..<24 {
                let ii = i - 12, jj = j - 12
                if ii * ii + jj * jj > 144 { continue }
                d[j * 24 + i] -= mean
                nrm += d[j * 24 + i] * d[j * 24 + i]
            }
        }
        nrm = nrm.squareRoot()
        if nrm > 1e-3 { for k in 0..<576 { d[k] /= nrm } }
        return d
    }

    static func colorSide(_ R: Rectified, _ c: Int, _ r: Int) -> Int {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var n = 0, red = 0, dark = 0
        for dy in -34...34 {
            for dx in -34...34 where dx * dx + dy * dy <= 1156 {
                let o = (cy + dy) * W + cx + dx
                let p = o * 4
                let rr = Int(R.rgba[p]), gg = Int(R.rgba[p + 1]), bb = Int(R.rgba[p + 2])
                n += 1
                let isRed = rr > 110 && rr > 2 * gg && rr > 2 * bb
                if isRed { red += 1 } else if Int(R.lum[o]) < 90 { dark += 1 }
            }
        }
        let fr = Float(red) / Float(n), fd = Float(dark) / Float(n)
        if fr > 0.015 && fr * 3 > fd { return 1 }
        if fd > 0.02 { return -1 }
        return 0
    }

    static func paddedCrop(_ R: Rectified, _ r: Int, _ c: Int) -> CGImage? {
        let rect = CGRect(x: c * cell, y: r * cell, width: cell, height: cell)
        guard let crop = R.cg.cropping(to: rect) else { return nil }
        let S = 288
        guard let g = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        g.setFillColor(UIColor.white.cgColor)
        g.fill(CGRect(x: 0, y: 0, width: S, height: S))
        g.draw(crop, in: CGRect(x: 48, y: 48, width: 192, height: 192))
        return g.makeImage()
    }

    static func ocrCell(_ R: Rectified, _ r: Int, _ c: Int) -> Int {
        guard let img = paddedCrop(R, r, c) else { return 0 }
        let hits = OCR.run(img, minHeight: 0.1)
        if let h = hits.max(by: { $0.conf < $1.conf }), h.conf >= 0.25 {
            var side = h.side
            if side == 0 { side = colorSide(R, c, r) }
            if side == 0 { return 0 }
            return side * h.type
        }
        return 0
    }
}

// MARK: - 屏幕识别器

struct ScreenRecognition {
    var board: [Int8]
    var flipped: Bool
    var unknownCount: Int
    var info: String
}

final class ScreenRecognizer {
    private var bank: [(code: Int, d: [Float])] = []

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for k in 0..<a.count { s += a[k] * b[k] }
        return s
    }

    private func matchBank(_ d: [Float]) -> (Int, Float)? {
        var bc = 0
        var bs: Float = -2
        for e in bank {
            let s = dot(e.d, d)
            if s > bs { bs = s; bc = e.code }
        }
        return bs > -2 ? (bc, bs) : nil
    }

    private func learn(_ code: Int, _ d: [Float]) {
        for e in bank where e.code == code && dot(e.d, d) > 0.98 { return }
        bank.append((code, d))
        if bank.count > 120 { bank.removeFirst(bank.count - 120) }
    }

    func run(_ pb: CVPixelBuffer) -> ScreenRecognition? {
        let t0 = Date()
        let cropRect = SharedStore.loadCropRect()
        guard let R = Analyzer.cropScreen(pb, normalizedRect: cropRect) else { return nil }

        var sc = [Float](repeating: 0, count: 90)
        for r in 0..<10 {
            for c in 0..<9 { sc[r * 9 + c] = Analyzer.cellScore(R, r, c) }
        }
        let lo = sc.min() ?? 0, hi = sc.max() ?? 0
        var c0 = lo, c1 = hi
        for _ in 0..<10 {
            var s0: Float = 0, n0: Float = 0, s1: Float = 0, n1: Float = 0
            for v in sc {
                if abs(v - c0) <= abs(v - c1) { s0 += v; n0 += 1 } else { s1 += v; n1 += 1 }
            }
            if n0 > 0 { c0 = s0 / n0 }
            if n1 > 0 { c1 = s1 / n1 }
        }
        let thr = c0 + 0.4 * (c1 - c0)
        var occupied = [Int]()
        if c1 - c0 > 0.12 {
            for i in 0..<90 where sc[i] > thr { occupied.append(i) }
        }

        var codes = [Int](repeating: 0, count: 90)
        var descs: [Int: [Float]] = [:]
        var todo = [Int]()
        for i in occupied {
            let d = Analyzer.descriptor(R, i / 9, i % 9)
            descs[i] = d
            if let m = matchBank(d), m.1 >= 0.90 { codes[i] = m.0 } else { todo.append(i) }
        }

        for i in todo.prefix(8) {
            let code = Analyzer.ocrCell(R, i / 9, i % 9)
            if code != 0 {
                codes[i] = code
                if let d = descs[i] { learn(code, d) }
            }
        }

        var view = [Int8](repeating: 0, count: 90)
        var unknownCount = 0
        var count = 0
        for i in occupied {
            if codes[i] != 0 { view[i] = Int8(codes[i]); count += 1 } else { unknownCount += 1 }
        }

        var flipped = false
        if let rk = view.firstIndex(of: 1) {
            flipped = rk / 9 <= 4
        } else if let bk = view.firstIndex(of: -1) {
            flipped = bk / 9 >= 5
        }
        var board = [Int8](repeating: 0, count: 90)
        for i in 0..<90 where view[i] != 0 {
            let r = i / 9, c = i % 9
            let ci = flipped ? (9 - r) * 9 + (8 - c) : i
            board[ci] = view[i]
        }

        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let info = "识别 \(count) 子 · 耗时 \(ms)ms"
        return ScreenRecognition(board: board, flipped: flipped, unknownCount: unknownCount, info: info)
    }
}
