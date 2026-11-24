import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

// 几何计算统一用 "k-px" = 像素 / 1000

let K: Double = 1000

// MARK: - 单应性

/// 4 点精确解：src -> dst
func homography(src: [CGPoint], dst: [CGPoint]) -> [Double]? {
    var A = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<4 {
        let x = Double(src[i].x), y = Double(src[i].y)
        let X = Double(dst[i].x), Y = Double(dst[i].y)
        A[2 * i] = [x, y, 1, 0, 0, 0, -x * X, -y * X, X]
        A[2 * i + 1] = [0, 0, 0, x, y, 1, -x * Y, -y * Y, Y]
    }
    for col in 0..<8 {
        var piv = col
        for r in col..<8 where abs(A[r][col]) > abs(A[piv][col]) { piv = r }
        if abs(A[piv][col]) < 1e-12 { return nil }
        A.swapAt(piv, col)
        for r in 0..<8 where r != col {
            let f = A[r][col] / A[col][col]
            for k in col..<9 { A[r][k] -= f * A[col][k] }
        }
    }
    return (0..<8).map { A[$0][8] / A[$0][$0] } + [1.0]
}

/// 多点最小二乘：src -> dst
func fitHomography(src: [CGPoint], dst: [CGPoint]) -> [Double]? {
    if src.count < 4 || src.count != dst.count { return nil }
    var M = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<src.count {
        let x = Double(src[i].x), y = Double(src[i].y)
        let X = Double(dst[i].x), Y = Double(dst[i].y)
        let r1: [Double] = [x, y, 1, 0, 0, 0, -x * X, -y * X]
        let r2: [Double] = [0, 0, 0, x, y, 1, -x * Y, -y * Y]
        for a in 0..<8 {
            for b in 0..<8 { M[a][b] += r1[a] * r1[b] + r2[a] * r2[b] }
            M[a][8] += r1[a] * X + r2[a] * Y
        }
    }
    for col in 0..<8 {
        var piv = col
        for r in col..<8 where abs(M[r][col]) > abs(M[piv][col]) { piv = r }
        if abs(M[piv][col]) < 1e-12 { return nil }
        M.swapAt(piv, col)
        for r in 0..<8 where r != col {
            let f = M[r][col] / M[col][col]
            for k in col..<9 { M[r][k] -= f * M[col][k] }
        }
    }
    return (0..<8).map { M[$0][8] / M[$0][$0] } + [1.0]
}

func applyH(_ h: [Double], _ x: Double, _ y: Double) -> CGPoint {
    let w = h[6] * x + h[7] * y + h[8]
    return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w, y: (h[3] * x + h[4] * y + h[5]) / w)
}

func invert3(_ h: [Double]) -> [Double]? {
    let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7], i = h[8]
    let det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g)
    if abs(det) < 1e-14 { return nil }
    return [(e * i - f * hh) / det, (c * hh - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * hh - e * g) / det, (b * g - a * hh) / det, (a * e - b * d) / det]
}

// MARK: - 摄像头

final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "xq.camera")
    private var last = Date.distantPast
    private var started = false

    func start() {
        if started { return }
        started = true
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.queue.async {
                self.configure()
                self.session.startRunning()
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.4, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        onFrame?(pb)
    }
}

// MARK: - 全屏预览：叠加网格 / 识别标记 / 最佳走法箭头

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let gridLayer = CAShapeLayer()
    private let arrowOutline = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private var labels: [CATextLayer] = []

    private var g2i: [Double]? = nil
    private var imgSize = CGSize.zero
    private var viewBoard: [Int8] = []
    private var best: Move?
    private var flipped = false
    private var showLabels = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        pl.videoGravity = .resizeAspectFill
        gridLayer.fillColor = nil
        gridLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.7).cgColor
        gridLayer.lineWidth = 1
        arrowOutline.fillColor = nil
        arrowOutline.strokeColor = UIColor.white.cgColor
        arrowOutline.lineWidth = 11
        arrowOutline.lineCap = .round
        arrowOutline.lineJoin = .round
        arrowOutline.zPosition = 9
        arrowLayer.fillColor = nil
        arrowLayer.strokeColor = UIColor(red: 0.1, green: 0.85, blue: 0.2, alpha: 1).cgColor
        arrowLayer.lineWidth = 6
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        arrowLayer.zPosition = 10
        layer.addSublayer(gridLayer)
        layer.addSublayer(arrowOutline)
        layer.addSublayer(arrowLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    func update(g2i: [Double]?, imgSize: CGSize, viewBoard: [Int8], best: Move?, flipped: Bool, showLabels: Bool) {
        self.g2i = g2i
        self.imgSize = imgSize
        self.viewBoard = viewBoard
        self.best = best
        self.flipped = flipped
        self.showLabels = showLabels
        redraw()
    }

    /// 视图网格 (列, 行) -> 屏幕坐标（预览是 aspect-fill，竖屏正向）
    private func map(_ c: Double, _ r: Double) -> CGPoint? {
        guard let h = g2i, imgSize.width > 0, imgSize.height > 0 else { return nil }
        let p = applyH(h, c, r)
        let x = Double(p.x) * K, y = Double(p.y) * K
        if !x.isFinite || !y.isFinite { return nil }
        let vw = Double(bounds.width), vh = Double(bounds.height)
        let iw = Double(imgSize.width), ih = Double(imgSize.height)
        let s = max(vw / iw, vh / ih)
        let ox = (vw - iw * s) / 2, oy = (vh - ih * s) / 2
        return CGPoint(x: x * s + ox, y: y * s + oy)
    }

    private func arrowPath(_ a: CGPoint, _ t: CGPoint) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: a)
        p.addLine(to: t)
        let ang = atan2(t.y - a.y, t.x - a.x)
        let L: CGFloat = 20
        for s in [CGFloat.pi / 6, -CGFloat.pi / 6] {
            p.move(to: t)
            p.addLine(to: CGPoint(x: t.x - L * cos(ang + s), y: t.y - L * sin(ang + s)))
        }
        for q in [a, t] {
            p.append(UIBezierPath(ovalIn: CGRect(x: q.x - 20, y: q.y - 20, width: 40, height: 40)))
        }
        return p
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        gridLayer.frame = bounds
        arrowOutline.frame = bounds
        arrowLayer.frame = bounds

        let grid = UIBezierPath()
        if g2i != nil {
            for c in 0...8 {
                if let a = map(Double(c), 0), let b = map(Double(c), 9) { grid.move(to: a); grid.addLine(to: b) }
            }
            for r in 0...9 {
                if let a = map(0, Double(r)), let b = map(8, Double(r)) { grid.move(to: a); grid.addLine(to: b) }
            }
        }
        gridLayer.path = grid.cgPath

        // 最佳走法箭头（走法是规范坐标，需要换回视图坐标）
        func vp(_ i: Int) -> CGPoint? {
            let r = i / 9, c = i % 9
            return flipped ? map(Double(8 - c), Double(9 - r)) : map(Double(c), Double(r))
        }
        if let mv = best, let a = vp(mv.from), let t = vp(mv.to) {
            let path = arrowPath(a, t).cgPath
            arrowOutline.path = path
            arrowLayer.path = path
        } else {
            arrowOutline.path = nil
            arrowLayer.path = nil
        }

        // 识别标记
        var items: [(CGPoint, String, UIColor)] = []
        if showLabels, viewBoard.count == 90 {
            for i in 0..<90 where viewBoard[i] != 0 {
                if let p = map(Double(i % 9), Double(i / 9)) {
                    let v = viewBoard[i]
                    items.append((p, pieceName(v), v > 0 ? UIColor.red : UIColor.black))
                }
            }
        }
        while labels.count < items.count {
            let t = CATextLayer()
            t.contentsScale = UIScreen.main.scale
            t.alignmentMode = .center
            t.fontSize = 14
            t.cornerRadius = 10
            t.backgroundColor = UIColor.white.withAlphaComponent(0.8).cgColor
            layer.addSublayer(t)
            labels.append(t)
        }
        for (i, t) in labels.enumerated() {
            if i < items.count {
                let it = items[i]
                t.isHidden = false
                t.string = it.1
                t.foregroundColor = it.2.cgColor
                t.frame = CGRect(x: it.0.x - 10, y: it.0.y - 10, width: 20, height: 19)
            } else {
                t.isHidden = true
            }
        }
    }
}

// MARK: - OCR（Vision 文字识别，认棋子上的字）

struct Hit {
    var type: Int       // 1 帅 2 仕 3 相 4 马 5 车 6 炮 7 兵
    var side: Int       // 1 红, -1 黑, 0 字形无法区分
    var conf: Float
    var x: Double       // 像素，左上角为原点
    var y: Double
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
        let W = Double(cg.width), H = Double(cg.height)
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
            let s = cand.string
            var idx = s.startIndex
            while idx < s.endIndex {
                let nxt = s.index(after: idx)
                if let g = Glyph.table[s[idx]], let rect = try? cand.boundingBox(for: idx..<nxt) {
                    let b = rect.boundingBox
                    hits.append(Hit(type: g.0, side: g.1, conf: cand.confidence,
                                    x: Double(b.midX) * W, y: (1 - Double(b.midY)) * H))
                }
                idx = nxt
            }
        }
        return hits
    }

    /// 矩形候选（棋盘外框），返回 k-px 坐标，顺序 左上/右上/右下/左下
    static func rectangles(_ cg: CGImage) -> [[CGPoint]] {
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio = 0.6
        req.maximumAspectRatio = 1.0
        req.minimumSize = 0.2
        req.minimumConfidence = 0.3
        req.maximumObservations = 8
        req.quadratureTolerance = 30
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        let W = Double(cg.width), H = Double(cg.height)
        func p(_ q: CGPoint) -> CGPoint {
            CGPoint(x: Double(q.x) * W / K, y: (1 - Double(q.y)) * H / K)
        }
        var out = [[CGPoint]]()
        for o in req.results ?? [] {
            out.append([p(o.topLeft), p(o.topRight), p(o.bottomRight), p(o.bottomLeft)])
        }
        return out
    }
}

// MARK: - 自动找棋盘：矩形候选 × 边距 → 用识别到的棋子对齐到 9x10 网格来打分

enum Geo {
    static func legal(_ t: Int, _ c: Int, _ r: Int) -> Bool {
        switch t {
        case 1:
            return c >= 3 && c <= 5 && (r <= 2 || r >= 7)
        case 2:
            let a: Bool = c == 4 && (r == 1 || r == 8)
            let b: Bool = (c == 3 || c == 5) && (r == 0 || r == 2 || r == 7 || r == 9)
            return a || b
        case 3:
            let t1: Bool = (r == 0 || r == 4) && (c == 2 || c == 6)
            let t2: Bool = r == 2 && (c == 0 || c == 4 || c == 8)
            let b1: Bool = (r == 9 || r == 5) && (c == 2 || c == 6)
            let b2: Bool = r == 7 && (c == 0 || c == 4 || c == 8)
            return t1 || t2 || b1 || b2
        case 7:
            let red: Bool = r <= 6 && (r <= 4 || c % 2 == 0)
            let black: Bool = r >= 3 && (r >= 5 || c % 2 == 0)
            return red || black
        default:
            return true
        }
    }

    /// 返回 (内点数, 综合分)
    static func score(_ h: [Double], _ hits: [Hit], tol: Double = 0.25) -> (Int, Int) {
        var inl = 0, leg = 0
        for ht in hits {
            let p = applyH(h, ht.x / K, ht.y / K)
            let gx = Double(p.x), gy = Double(p.y)
            if !gx.isFinite || !gy.isFinite { continue }
            let c = Int(gx.rounded()), r = Int(gy.rounded())
            let dx = abs(gx - Double(c)), dy = abs(gy - Double(r))
            if dx < tol && dy < tol && c >= 0 && c <= 8 && r >= 0 && r <= 9 {
                inl += 1
                leg += legal(ht.type, c, r) ? 1 : -2
            }
        }
        return (inl, inl * 10 + leg)
    }

    static func refine(_ h: [Double], _ hits: [Hit]) -> [Double] {
        var cur = h
        var curScore = score(cur, hits).1
        for _ in 0..<3 {
            var src = [CGPoint](), dst = [CGPoint]()
            var cs = Set<Int>(), rs = Set<Int>()
            for ht in hits {
                let p = applyH(cur, ht.x / K, ht.y / K)
                let gx = Double(p.x), gy = Double(p.y)
                if !gx.isFinite || !gy.isFinite { continue }
                let c = Int(gx.rounded()), r = Int(gy.rounded())
                let dx = abs(gx - Double(c)), dy = abs(gy - Double(r))
                if dx < 0.4 && dy < 0.4 && c >= 0 && c <= 8 && r >= 0 && r <= 9 {
                    src.append(CGPoint(x: ht.x / K, y: ht.y / K))
                    dst.append(CGPoint(x: c, y: r))
                    cs.insert(c); rs.insert(r)
                }
            }
            if src.count < 6 || cs.count < 3 || rs.count < 3 { break }
            guard let nh = fitHomography(src: src, dst: dst) else { break }
            let ns = score(nh, hits).1
            if ns >= curScore { cur = nh; curScore = ns } else { break }
        }
        return cur
    }

    /// 返回 (网格->图像, 图像->网格)
    static func find(quads: [[CGPoint]], hits: [Hit]) -> ([Double], [Double])? {
        if hits.count < 5 { return nil }
        let dstGrid = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 9), CGPoint(x: 0, y: 9)]
        var hyps = [[Double]]()
        for q in quads where q.count == 4 {
            for a in [0.0, 0.3, 0.5, 0.7, 0.9, 1.2] {
                let mx = a / (8 + 2 * a), my = a / (9 + 2 * a)
                func bil(_ u: Double, _ v: Double) -> CGPoint {
                    let w0 = (1 - u) * (1 - v), w1 = u * (1 - v), w2 = u * v, w3 = (1 - u) * v
                    var x: Double = w0 * Double(q[0].x)
                    x += w1 * Double(q[1].x)
                    x += w2 * Double(q[2].x)
                    x += w3 * Double(q[3].x)
                    var y: Double = w0 * Double(q[0].y)
                    y += w1 * Double(q[1].y)
                    y += w2 * Double(q[2].y)
                    y += w3 * Double(q[3].y)
                    return CGPoint(x: x, y: y)
                }
                let src = [bil(mx, my), bil(1 - mx, my), bil(1 - mx, 1 - my), bil(mx, 1 - my)]
                if let h = homography(src: src, dst: dstGrid) { hyps.append(h) }
            }
        }
        // 兜底：用所有棋子的外接矩形
        let xs = hits.map { $0.x / K }, ys = hits.map { $0.y / K }
        if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 - x0 > 0.05, y1 - y0 > 0.05 {
            let src = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
            if let h = homography(src: src, dst: dstGrid) { hyps.append(h) }
        }
        var scored = hyps.map { ($0, score($0, hits).1) }
        scored.sort { $0.1 > $1.1 }
        var best: [Double]? = nil
        var bestTotal = Int.min
        var bestInl = 0
        for (h, _) in scored.prefix(5) {
            let r = refine(h, hits)
            let s = score(r, hits)
            if s.1 > bestTotal { bestTotal = s.1; bestInl = s.0; best = r }
        }
        guard let bh = best, bestInl >= 5, let inv = invert3(bh) else { return nil }
        return (inv, bh)
    }
}

// MARK: - 图像处理：竖直化、透视校正、颜色判断

final class Rectified {
    let cg: CGImage
    let rgba: [UInt8]
    init(cg: CGImage, rgba: [UInt8]) { self.cg = cg; self.rgba = rgba }
}

enum Analyzer {
    static let ctx = CIContext()
    static let cell = 96, W = 864, H = 960      // 校正后每格 96 像素，交叉点在格子中心

    /// 摄像头缓冲区是横向的，转成竖直（与竖屏预览一致）
    static func upright(_ pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb).oriented(.right)
        return ctx.createCGImage(ci, from: ci.extent)
    }

    static func rotated180(_ cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg).oriented(.down)
        return ctx.createCGImage(ci, from: ci.extent)
    }

    static func rectify(_ up: CGImage, g2i: [Double]) -> Rectified? {
        let ih = Double(up.height)
        func q(_ x: Double, _ y: Double) -> CGPoint {
            let p = applyH(g2i, x, y)
            return CGPoint(x: Double(p.x) * K, y: ih - Double(p.y) * K)    // CoreImage 原点在左下
        }
        let tl = q(-0.5, -0.5), tr = q(8.5, -0.5), br = q(8.5, 9.5), bl = q(-0.5, 9.5)
        for p in [tl, tr, br, bl] where !(p.x.isFinite && p.y.isFinite) { return nil }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cgImage: up)
        f.topLeft = tl
        f.topRight = tr
        f.bottomRight = br
        f.bottomLeft = bl
        guard let out = f.outputImage else { return nil }
        let e = out.extent
        guard e.width > 10, e.height > 10, e.width.isFinite, e.height.isFinite else { return nil }
        let t = CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y)
            .concatenating(CGAffineTransform(scaleX: CGFloat(W) / e.width, y: CGFloat(H) / e.height))
        guard let cg = ctx.createCGImage(out.transformed(by: t), from: CGRect(x: 0, y: 0, width: W, height: H)) else { return nil }
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                    bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return nil }
        return Rectified(cg: cg, rgba: data)
    }

    /// 格子里字的颜色：1 红, -1 黑, 0 不确定
    static func colorSide(_ R: Rectified, _ c: Int, _ r: Int) -> Int {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var n = 0, red = 0, dark = 0
        for dy in -34...34 {
            for dx in -34...34 where dx * dx + dy * dy <= 1156 {
                let p = ((cy + dy) * W + cx + dx) * 4
                let rr = Int(R.rgba[p]), gg = Int(R.rgba[p + 1]), bb = Int(R.rgba[p + 2])
                let l = (299 * rr + 587 * gg + 114 * bb) / 1000
                n += 1
                if rr > 110 && rr > 2 * gg && rr > 2 * bb { red += 1 } else if l < 90 { dark += 1 }
            }
        }
        let fr = Float(red) / Float(n), fd = Float(dark) / Float(n)
        if fr > 0.015 && fr * 3 > fd { return 1 }
        if fd > 0.02 { return -1 }
        return 0
    }
}

// MARK: - 一次完整识别

struct Recognition {
    var viewBoard: [Int8]      // 摄像头里看到的方向
    var board: [Int8]          // 规范方向（红下黑上）
    var flipped: Bool          // 摄像头里红方在上
    var g2i: [Double]          // 网格 -> 竖直图像 (k-px)
    var imgW: Double
    var imgH: Double
    var count: Int
}

enum Recognizer {
    /// cache：已找到的棋盘几何；识别质量差时清空以便下次重新找棋盘
    static func run(_ pb: CVPixelBuffer, cache: inout [Double]?) -> Recognition? {
        guard let up = Analyzer.upright(pb) else { return nil }
        let imgW = Double(up.width), imgH = Double(up.height)
        var g2i = cache
        var pass1 = [Hit]()

        if g2i == nil {
            pass1 = OCR.run(up, minHeight: 0.008)
            if let rot = Analyzer.rotated180(up) {      // 对面的棋子字是倒的
                for h in OCR.run(rot, minHeight: 0.008) {
                    var m = h
                    m.x = imgW - h.x
                    m.y = imgH - h.y
                    pass1.append(m)
                }
            }
            let quads = OCR.rectangles(up)
            guard let found = Geo.find(quads: quads, hits: pass1) else { return nil }
            g2i = found.0
        }
        guard let g = g2i, let R = Analyzer.rectify(up, g2i: g) else { cache = nil; return nil }

        // 在校正后的棋盘图上再识别一遍（更清晰），同样正反各一次
        let cw = Double(R.cg.width), ch = Double(R.cg.height)
        var hits2 = OCR.run(R.cg, minHeight: 0.02)
        if let rot = Analyzer.rotated180(R.cg) {
            for h in OCR.run(rot, minHeight: 0.02) {
                var m = h
                m.x = cw - h.x
                m.y = ch - h.y
                hits2.append(m)
            }
        }

        var cells: [Int: Hit] = [:]
        func put(_ idx: Int, _ h: Hit) {
            if let o = cells[idx], o.conf >= h.conf { return }
            cells[idx] = h
        }
        var offSum = 0.0, offN = 0.0
        let cellD = Double(Analyzer.cell)
        for h in hits2 {
            let cx = h.x / cellD - 0.5, cy = h.y / cellD - 0.5
            let c = Int(cx.rounded()), r = Int(cy.rounded())
            let dx = abs(cx - Double(c)), dy = abs(cy - Double(r))
            if dx < 0.4 && dy < 0.4 && c >= 0 && c <= 8 && r >= 0 && r <= 9 {
                put(r * 9 + c, h)
                offSum += dx + dy
                offN += 2
            }
        }
        if !pass1.isEmpty, let i2g = invert3(g) {
            for h in pass1 {
                let p = applyH(i2g, h.x / K, h.y / K)
                let gx = Double(p.x), gy = Double(p.y)
                if !gx.isFinite || !gy.isFinite { continue }
                let c = Int(gx.rounded()), r = Int(gy.rounded())
                if abs(gx - Double(c)) < 0.3 && abs(gy - Double(r)) < 0.3 && c >= 0 && c <= 8 && r >= 0 && r <= 9 {
                    var m = h
                    m.conf *= 0.9
                    put(r * 9 + c, m)
                }
            }
        }

        var view = [Int8](repeating: 0, count: 90)
        var count = 0
        for (idx, h) in cells {
            var side = h.side
            if side == 0 { side = Analyzer.colorSide(R, idx % 9, idx / 9) }
            if side == 0 { continue }
            view[idx] = Int8(side * h.type)
            count += 1
        }

        // 摄像头里红方在上就整盘旋转 180°
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

        // 质量太差或网格偏移明显 -> 下次重新找棋盘
        let avgOff = offN > 0 ? offSum / offN : 1.0
        if count < 4 || avgOff > 0.2 { cache = nil } else { cache = g }
        return Recognition(viewBoard: view, board: board, flipped: flipped, g2i: g,
                           imgW: imgW, imgH: imgH, count: count)
    }
}
