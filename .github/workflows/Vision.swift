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

// MARK: - 预览视图（点击标定四角 + 叠加网格）

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let overlay = CAShapeLayer()
    var onTap: ((CGPoint) -> Void)?
    var corners: [CGPoint] = [] { didSet { redraw() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pl.videoGravity = .resizeAspectFill
        overlay.fillColor = nil
        overlay.strokeColor = UIColor.systemGreen.cgColor
        overlay.lineWidth = 1
        layer.addSublayer(overlay)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        onTap?(pl.captureDevicePointConverted(fromLayerPoint: p))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        redraw()
    }

    private func redraw() {
        let path = UIBezierPath()
        if corners.count == 4 {
            let src = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 9), CGPoint(x: 0, y: 9)]
            if let h = homography(src: src, dst: corners) {
                func lp(_ x: Double, _ y: Double) -> CGPoint {
                    pl.layerPointConverted(fromCaptureDevicePoint: applyH(h, x, y))
                }
                for c in 0...8 { path.move(to: lp(Double(c), 0)); path.addLine(to: lp(Double(c), 9)) }
                for r in 0...9 { path.move(to: lp(0, Double(r))); path.addLine(to: lp(8, Double(r))) }
            }
        } else {
            for p in corners {
                let q = pl.layerPointConverted(fromCaptureDevicePoint: p)
                path.append(UIBezierPath(ovalIn: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)))
            }
        }
        overlay.path = path.cgPath
    }
}

// MARK: - 棋盘校正 + 棋子特征提取

struct CellFeatures {
    var ink: Float      // 圆内“墨迹”（深色或红色）像素占比，用于判断有无棋子
    var red: Float
    var dark: Float
    var desc: [Float]   // 24x24 归一化灰度描述子，用于模板匹配
}

enum Analyzer {
    static let ctx = CIContext()
    static let cell = 60, W = 540, H = 600

    /// 透视校正为正向的 9x10 格图像（每个交叉点位于格子中心）
    static func rectify(_ pb: CVPixelBuffer, corners: [CGPoint]) -> CGImage? {
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
        return ctx.createCGImage(out.transformed(by: t), from: CGRect(x: 0, y: 0, width: W, height: H))
    }

    static func analyze(_ pb: CVPixelBuffer, corners: [CGPoint]) -> [CellFeatures]? {
        guard let cg = rectify(pb, corners: corners) else { return nil }
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                    bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return nil }

        var out = [CellFeatures]()
        out.reserveCapacity(90)
        let R = 24
        for r in 0..<10 {
            for c in 0..<9 {
                let cx = c * cell + cell / 2, cy = r * cell + cell / 2
                var n = 0, red = 0, dark = 0
                for dy in -R...R {
                    for dx in -R...R where dx * dx + dy * dy <= R * R {
                        let o = ((cy + dy) * W + (cx + dx)) * 4
                        let rr = Int(data[o]), gg = Int(data[o + 1]), bb = Int(data[o + 2])
                        n += 1
                        let l = (299 * rr + 587 * gg + 114 * bb) / 1000
                        if rr > 110 && rr > 2 * gg && rr > 2 * bb { red += 1 }
                        else if l < 90 { dark += 1 }
                    }
                }
                var d = [Float](repeating: 0, count: 576)
                var mean: Float = 0
                for j in 0..<24 {
                    for i in 0..<24 {
                        var s = 0
                        for yy in 0..<2 {
                            for xx in 0..<2 {
                                let o = ((cy - 24 + j * 2 + yy) * W + (cx - 24 + i * 2 + xx)) * 4
                                s += (299 * Int(data[o]) + 587 * Int(data[o + 1]) + 114 * Int(data[o + 2])) / 1000
                            }
                        }
                        let v = Float(s) / 4
                        d[j * 24 + i] = v
                        mean += v
                    }
                }
                mean /= 576
                var nrm: Float = 0
                for k in 0..<576 { d[k] -= mean; nrm += d[k] * d[k] }
                nrm = nrm.squareRoot()
                if nrm > 1e-3 { for k in 0..<576 { d[k] /= nrm } }
                out.append(CellFeatures(ink: Float(red + dark) / Float(n),
                                        red: Float(red) / Float(n),
                                        dark: Float(dark) / Float(n),
                                        desc: d))
            }
        }
        return out
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 1e-6 ? v.map { $0 / n } : v
    }

    /// 把 90 个格子的特征匹配成规范局面（红下黑上）
    static func classify(_ feats: [CellFeatures], templates: [Int: [Float]], thr: Float, flipped: Bool) -> [Int8] {
        var board = [Int8](repeating: 0, count: 90)
        for idx in 0..<90 {
            let f = feats[idx]
            if f.ink < thr { continue }
            let red = f.red > f.dark
            var bestCode = 0
            var bestScore: Float = -2
            for t in 1...7 {
                let code = red ? t : -t
                guard let tpl = templates[code] else { continue }
                var s: Float = 0
                for k in 0..<tpl.count { s += tpl[k] * f.desc[k] }
                if s > bestScore { bestScore = s; bestCode = code }
            }
            if bestCode == 0 || bestScore < 0.2 { continue }
            let r = idx / 9, c = idx % 9
            let ci = flipped ? (9 - r) * 9 + (8 - c) : idx
            board[ci] = Int8(bestCode)
        }
        return board
    }
}
