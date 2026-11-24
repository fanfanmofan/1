import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - 单应性变换（棋盘格坐标 -> 图像坐标）

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

func applyH(_ h: [Double], _ x: Double, _ y: Double) -> CGPoint {
    let w = h[6] * x + h[7] * y + h[8]
    return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w, y: (h[3] * x + h[4] * y + h[5]) / w)
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

// MARK: - 全屏预览视图：点击标定四角 + 叠加网格 + 识别标记 + 最佳走法箭头

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let gridLayer = CAShapeLayer()
    private let arrowOutline = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private var labels: [CATextLayer] = []

    var onTap: ((CGPoint) -> Void)?
    private var corners: [CGPoint] = []
    private var board: [Int8] = []
    private var best: Move?
    private var flipped = false
    private var uncertain: [Int] = []
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
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        onTap?(pl.captureDevicePointConverted(fromLayerPoint: p))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    func update(corners: [CGPoint], board: [Int8], best: Move?, flipped: Bool, uncertain: [Int], showLabels: Bool) {
        self.corners = corners
        self.board = board
        self.best = best
        self.flipped = flipped
        self.uncertain = uncertain
        self.showLabels = showLabels
        redraw()
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
        var map: ((Int, Int) -> CGPoint)? = nil      // 视图网格 (行, 列) -> 屏幕点
        if corners.count == 4 {
            let src = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 9), CGPoint(x: 0, y: 9)]
            if let h = homography(src: src, dst: corners) {
                let player = pl
                map = { r, c in player.layerPointConverted(fromCaptureDevicePoint: applyH(h, Double(c), Double(r))) }
                if let m = map {
                    for c in 0...8 { grid.move(to: m(0, c)); grid.addLine(to: m(9, c)) }
                    for r in 0...9 { grid.move(to: m(r, 0)); grid.addLine(to: m(r, 8)) }
                }
            }
        } else {
            for p in corners {
                let q = pl.layerPointConverted(fromCaptureDevicePoint: p)
                grid.append(UIBezierPath(ovalIn: CGRect(x: q.x - 8, y: q.y - 8, width: 16, height: 16)))
            }
        }
        gridLayer.path = grid.cgPath

        // 最佳走法箭头
        if let mv = best, let m = map {
            func vp(_ i: Int) -> CGPoint {
                let r = i / 9, c = i % 9
                return flipped ? m(9 - r, 8 - c) : m(r, c)
            }
            let path = arrowPath(vp(mv.from), vp(mv.to)).cgPath
            arrowOutline.path = path
            arrowLayer.path = path
        } else {
            arrowOutline.path = nil
            arrowLayer.path = nil
        }

        // 识别标记（红/黑棋子名；黄色问号=有子但认不出）
        var items: [(CGPoint, String, UIColor, UIColor)] = []
        if showLabels, let m = map, board.count == 90 {
            for i in 0..<90 where board[i] != 0 {
                let r = i / 9, c = i % 9
                let p = flipped ? m(9 - r, 8 - c) : m(r, c)
                let v = board[i]
                items.append((p, pieceName(v), v > 0 ? UIColor.red : UIColor.black, UIColor.white.withAlphaComponent(0.8)))
            }
            for idx in uncertain {
                items.append((m(idx / 9, idx % 9), "?", UIColor.black, UIColor.yellow))
            }
        }
        while labels.count < items.count {
            let t = CATextLayer()
            t.contentsScale = UIScreen.main.scale
            t.alignmentMode = .center
            t.fontSize = 14
            t.cornerRadius = 10
            layer.addSublayer(t)
            labels.append(t)
        }
        for (i, t) in labels.enumerated() {
            if i < items.count {
                let it = items[i]
                t.isHidden = false
                t.string = it.1
                t.foregroundColor = it.2.cgColor
                t.backgroundColor = it.3.cgColor
                t.frame = CGRect(x: it.0.x - 10, y: it.0.y - 10, width: 20, height: 19)
            } else {
                t.isHidden = true
            }
        }
    }
}

// MARK: - 棋盘校正 + 棋子识别

final class Rectified {
    let rgba: [UInt8]
    let lum: [UInt8]
    init(rgba: [UInt8], lum: [UInt8]) { self.rgba = rgba; self.lum = lum }
}

struct CellStat {
    var f: [Float]      // 5 个"有无棋子"特征
    var red: Float      // 圆内红色像素占比
    var dark: Float     // 圆内深色像素占比
}

struct LearnSample {
    var stats: [CellStat]
    var descs: [[Float]]
    var rect: Rectified
}

/// 学习结果：棋子模板 + 自动挑选的"有子/无子"判别特征与阈值
struct Recognizer: Codable {
    var templates: [Int: [Float]]
    var feat: Int
    var pol: Float
    var thr: Float
}

enum Analyzer {
    static let ctx = CIContext()
    static let cell = 64, W = 576, H = 640
    static let nf = 5
    static let G = 22          // 描述子网格边长（覆盖格子中心 44x44 像素，只看棋子内部字形）

    /// 透视校正为正向的 9x10 格图像（每个交叉点位于格子中心）
    static func rectify(_ pb: CVPixelBuffer, corners: [CGPoint]) -> Rectified? {
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        let dst = corners.map { CGPoint(x: Double($0.x) * w, y: Double($0.y) * h) }
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 9), CGPoint(x: 0, y: 9)]
        guard let hm = homography(src: src, dst: dst) else { return nil }
        func q(_ x: Double, _ y: Double) -> CGPoint {
            let p = applyH(hm, x, y)
            return CGPoint(x: Double(p.x), y: h - Double(p.y))   // CoreImage 坐标原点在左下
        }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cvPixelBuffer: pb)
        f.topLeft = q(-0.5, -0.5)
        f.topRight = q(8.5, -0.5)
        f.bottomRight = q(8.5, 9.5)
        f.bottomLeft = q(-0.5, 9.5)
        guard let out = f.outputImage else { return nil }
        let e = out.extent
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
        var lum = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let pr: Int = Int(data[4 * i])
            let pg: Int = Int(data[4 * i + 1])
            let pbl: Int = Int(data[4 * i + 2])
            let lv: Int = (299 * pr + 587 * pg + 114 * pbl) / 1000
            lum[i] = UInt8(lv)
        }
        return Rectified(rgba: data, lum: lum)
    }

    /// 单个格子的统计特征
    static func stat(_ R: Rectified, _ r: Int, _ c: Int) -> CellStat {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        let h = cell / 2
        var n1 = 0, ink1 = 0, n2 = 0, ink2 = 0, nr = 0, inkr = 0, nc = 0
        var sl = 0, sl2 = 0, dr = 0, dg = 0, db = 0, cr = 0, cg = 0, cb = 0, red = 0, dark = 0
        for dy in -h..<h {
            for dx in -h..<h {
                let o = (cy + dy) * W + cx + dx
                let p = o * 4
                let rr = Int(R.rgba[p]), gg = Int(R.rgba[p + 1]), bb = Int(R.rgba[p + 2])
                let l = Int(R.lum[o])
                let d2 = dx * dx + dy * dy
                let isRed = rr > 110 && rr > 2 * gg && rr > 2 * bb
                let isDark = !isRed && l < 90
                if d2 <= 676 {                       // 半径 26 的圆盘
                    n1 += 1; sl += l; sl2 += l * l; dr += rr; dg += gg; db += bb
                    if isRed { red += 1; ink1 += 1 } else if isDark { dark += 1; ink1 += 1 }
                    if d2 <= 256 {                   // 半径 16 的中心区（字所在）
                        n2 += 1
                        if isRed || isDark { ink2 += 1 }
                    }
                }
                if d2 >= 441 && d2 <= 841 {          // 半径 21~29 的圆环（棋子边框）
                    nr += 1
                    if isRed || isDark { inkr += 1 }
                }
                if abs(dx) >= 24 && abs(dy) >= 24 {  // 格子四角（一定是棋盘底色）
                    nc += 1; cr += rr; cg += gg; cb += bb
                }
            }
        }
        let fn1 = Float(n1), fnc = Float(max(nc, 1))
        let mean: Float = Float(sl) / fn1
        let meanSq: Float = Float(sl2) / fn1
        let variance: Float = max(0, meanSq - mean * mean)
        let ex: Float = Float(dr) / fn1 - Float(cr) / fnc
        let ey: Float = Float(dg) / fn1 - Float(cg) / fnc
        let ez: Float = Float(db) / fn1 - Float(cb) / fnc
        let sq: Float = ex * ex + ey * ey + ez * ez
        let cdist: Float = sq.squareRoot() / 255
        let fa: Float = Float(ink1) / fn1
        let fb: Float = Float(ink2) / Float(n2)
        let fc: Float = Float(inkr) / Float(max(nr, 1))
        let fd: Float = variance.squareRoot() / 64
        let f: [Float] = [fa, fb, fc, fd, cdist]
        return CellStat(f: f, red: Float(red) / fn1, dark: Float(dark) / fn1)
    }

    /// 以 (cx, cy) 为中心的 22x22 灰度描述子（圆形掩码，零均值、单位长度）
    static func descriptor(_ R: Rectified, _ cx: Int, _ cy: Int) -> [Float] {
        var d = [Float](repeating: 0, count: G * G)
        let hg = G / 2
        var mean: Float = 0, cnt: Float = 0
        for j in 0..<G {
            for i in 0..<G {
                let ii = i - hg, jj = j - hg
                if ii * ii + jj * jj > hg * hg { continue }
                let x0 = cx - G + 2 * i, y0 = cy - G + 2 * j
                let i0: Int = y0 * W + x0
                let i1: Int = i0 + W
                var s: Int = Int(R.lum[i0])
                s += Int(R.lum[i0 + 1])
                s += Int(R.lum[i1])
                s += Int(R.lum[i1 + 1])
                let v: Float = Float(s) / 4
                d[j * G + i] = v
                mean += v; cnt += 1
            }
        }
        mean /= cnt
        var nrm: Float = 0
        for j in 0..<G {
            for i in 0..<G {
                let ii = i - hg, jj = j - hg
                if ii * ii + jj * jj > hg * hg { continue }
                d[j * G + i] -= mean
                nrm += d[j * G + i] * d[j * G + i]
            }
        }
        nrm = nrm.squareRoot()
        if nrm > 1e-3 { for k in 0..<(G * G) { d[k] /= nrm } }
        return d
    }

    static func learnSample(_ R: Rectified) -> LearnSample {
        var stats = [CellStat](), descs = [[Float]]()
        for r in 0..<10 {
            for c in 0..<9 {
                stats.append(stat(R, r, c))
                descs.append(descriptor(R, c * cell + cell / 2, r * cell + cell / 2))
            }
        }
        return LearnSample(stats: stats, descs: descs, rect: R)
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 1e-6 ? v.map { $0 / n } : v
    }

    /// 识别整盘：返回规范局面（红下黑上）和"有子但认不出"的格子（视图网格索引）
    static func classify(_ R: Rectified, rec: Recognizer, flipped: Bool) -> (board: [Int8], uncertain: [Int]) {
        var board = [Int8](repeating: 0, count: 90)
        var unc = [Int]()
        for r in 0..<10 {
            for c in 0..<9 {
                let st = stat(R, r, c)
                if rec.pol * (st.f[rec.feat] - rec.thr) <= 0 { continue }     // 空格
                let cx = c * cell + cell / 2, cy = r * cell + cell / 2
                // 颜色只作加分项（繁体字本身就能区分红黑）
                var sideRed: Bool? = nil
                if st.red > 0.02 { sideRed = true } else if st.dark > 0.06 && st.red < 0.01 { sideRed = false }
                var bestCode = 0
                var bestScore: Float = -2
                for sy in stride(from: -6, through: 6, by: 3) {
                    for sx in stride(from: -6, through: 6, by: 3) {      // 容忍标定误差：±6 像素内找最佳对齐
                        let d = descriptor(R, cx + sx, cy + sy)
                        for (code, tpl) in rec.templates {
                            var s: Float = 0
                            for k in 0..<tpl.count { s += tpl[k] * d[k] }
                            if let sr = sideRed, (code > 0) == sr { s += 0.1 }
                            if s > bestScore { bestScore = s; bestCode = code }
                        }
                    }
                }
                let idx = r * 9 + c
                if bestCode == 0 || bestScore < 0.35 { unc.append(idx); continue }
                let ci = flipped ? (9 - r) * 9 + (8 - c) : idx
                board[ci] = Int8(bestCode)
            }
        }
        return (board, unc)
    }
}
