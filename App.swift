import SwiftUI
import AVFoundation
import AVKit
import ReplayKit
import PhotosUI

@main
struct XqAssistApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - 画中画 (PiP) 悬浮窗管理器（切到后台后在屏幕角落显示实时最优解）

final class PiPManager: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private(set) var isActive = false

    override init() {
        super.init()
        setupAudioSession()
        displayLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func toggle() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func renderFrame(pos: Position, best: Move?, bestText: String, status: String) {
        let size = CGSize(width: 450, height: 560)
        UIGraphicsBeginImageContextWithOptions(size, true, 2.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))

        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: UIColor.systemGreen
        ]
        (bestText as NSString).draw(in: CGRect(x: 20, y: 14, width: 410, height: 42), withAttributes: titleAttr)

        let subAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: UIColor.lightGray
        ]
        (status as NSString).draw(in: CGRect(x: 20, y: 58, width: 410, height: 26), withAttributes: subAttr)

        let boardRect = CGRect(x: 25, y: 95, width: 400, height: 445)
        UIColor(red: 0.93, green: 0.80, blue: 0.55, alpha: 1).setFill()
        UIBezierPath(roundedRect: boardRect, cornerRadius: 10).fill()

        let cellW = boardRect.width / 9.0
        let cellH = boardRect.height / 10.0
        func pt(_ r: Int, _ c: Int) -> CGPoint {
            CGPoint(x: boardRect.minX + (CGFloat(c) + 0.5) * cellW,
                    y: boardRect.minY + (CGFloat(r) + 0.5) * cellH)
        }

        ctx.setStrokeColor(UIColor.brown.cgColor)
        ctx.setLineWidth(1.2)
        for r in 0..<10 {
            ctx.move(to: pt(r, 0)); ctx.addLine(to: pt(r, 8))
        }
        for c in 0..<9 {
            if c == 0 || c == 8 {
                ctx.move(to: pt(0, c)); ctx.addLine(to: pt(9, c))
            } else {
                ctx.move(to: pt(0, c)); ctx.addLine(to: pt(4, c))
                ctx.move(to: pt(5, c)); ctx.addLine(to: pt(9, c))
            }
        }
        ctx.strokePath()

        for i in 0..<90 where pos.b[i] != 0 {
            let v = pos.b[i]
            let p = pt(i / 9, i % 9)
            let rad = min(cellW, cellH) * 0.42
            let rect = CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
            UIColor(red: 0.98, green: 0.93, blue: 0.8, alpha: 1).setFill()
            ctx.fillEllipse(in: rect)
            let col = v > 0 ? UIColor.red : UIColor.black
            col.setStroke()
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: rect)

            let pAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: rad * 1.15, weight: .bold),
                .foregroundColor: col
            ]
            let str = pieceName(v) as NSString
            let ts = str.size(withAttributes: pAttr)
            str.draw(at: CGPoint(x: p.x - ts.width / 2, y: p.y - ts.height / 2), withAttributes: pAttr)
        }

        if let m = best {
            let a = pt(m.from / 9, m.from % 9), t = pt(m.to / 9, m.to % 9)
            ctx.setStrokeColor(UIColor.systemGreen.cgColor)
            ctx.setLineWidth(6)
            ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: t)
            ctx.strokePath()
            for q in [a, t] {
                let rr = min(cellW, cellH) * 0.46
                ctx.strokeEllipse(in: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2))
            }
        }

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        if let cg = image?.cgImage, let sb = makeSampleBuffer(from: cg) {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sb)
        }
    }

    private func makeSampleBuffer(from cgImage: CGImage) -> CMSampleBuffer? {
        let width = cgImage.width, height = cgImage.height
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &pb)
        guard let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                                        presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: 3600, preferredTimescale: 600))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}

// MARK: - 主模型

final class Model: ObservableObject {
    @Published var pos = Position.start()
    @Published var best: Move?
    @Published var bestText = "—"
    @Published var status = "1. 校准棋盘位置  2. 开启悬浮窗  3. 点录屏监控"
    @Published var info = ""
    @Published var live = true
    @Published var isBroadcasting = false
    @Published var cropRect: CGRect = SharedStore.loadCropRect()
    var editIdx = 0

    let pip = PiPManager()
    private var gen = 0
    private var mateFound = false
    private let engine = Engine()
    private let work = DispatchQueue(label: "xq.engine", qos: .userInitiated)
    private let mateQ = DispatchQueue(label: "xq.mate", qos: .userInitiated)

    init() {
        registerDarwinNotification()
        refreshPiP()
    }

    private func registerDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs = obs else { return }
            let model = Unmanaged<Model>.fromOpaque(obs).takeUnretainedValue()
            DispatchQueue.main.async { model.onRemoteBoardUpdated() }
        }, SharedStore.darwinNotifyName as CFString, nil, .deliverImmediately)
    }

    private func onRemoteBoardUpdated() {
        isBroadcasting = true
        guard live, let payload = SharedStore.loadBoard() else { return }
        info = payload.info
        if payload.unknownCount > 0 {
            status = "后台识别到 \(payload.unknownCount) 个未知棋子，请点小棋盘手动校准"
            refreshPiP()
            return
        }
        guard payload.board != pos.b else { return }

        var np = pos
        var moved = false
        for m in pos.legalMoves() {
            var t = pos
            t.make(m)
            if t.b == payload.board { moved = true; break }
        }
        np.b = payload.board
        np.redToMove = moved ? !pos.redToMove : !payload.flipped
        pos = np
        analyze()
    }

    func updateCropRect(_ rect: CGRect) {
        cropRect = rect
        SharedStore.saveCropRect(rect)
        status = "棋盘区域已保存，后台录屏将自动按此区域裁剪"
    }

    func setPiece(_ i: Int, _ code: Int) {
        live = false
        var p = pos
        p.b[i] = Int8(code)
        pos = p
        analyze()
    }

    func setTurn(red: Bool) {
        var p = pos
        p.redToMove = red
        pos = p
        analyze()
    }

    func copyFEN() {
        UIPasteboard.general.string = pos.fen
        status = "FEN 已复制"
    }

    func refreshPiP() {
        pip.renderFrame(pos: pos, best: best, bestText: bestText, status: status)
    }

    func analyze() {
        gen += 1
        let g = gen
        let p = pos
        best = nil
        mateFound = false
        if let prob = p.validate() {
            bestText = "—"
            status = "局面异常：\(prob)"
            refreshPiP()
            return
        }
        bestText = "思考中…"
        status = "绝杀 + 云库分析中…"
        refreshPiP()

        mateQ.async { [weak self] in
            guard let self = self else { return }
            let r = MateSearch().find(p, maxMoves: 7, seconds: 2.5, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen, let (mv, n) = r else { return }
                self.mateFound = true
                self.show(mv, p, note: "\(n)步杀！")
            }
        }
        Cloud.bestMove(fen: p.fen) { [weak self] mv in
            guard let self = self, g == self.gen, !self.mateFound else { return }
            if let mv = mv, p.legalMoves().contains(mv) {
                self.show(mv, p, note: "云端引擎")
            } else {
                self.runLocal(p, g)
            }
        }
    }

    private func show(_ mv: Move, _ p: Position, note: String) {
        best = mv
        bestText = (p.redToMove ? "红：" : "黑：") + p.notation(mv)
        status = note
        refreshPiP()
    }

    private func runLocal(_ p: Position, _ g: Int) {
        status = "本地引擎计算中…"
        refreshPiP()
        work.async { [weak self] in
            guard let self = self else { return }
            let r = self.engine.search(p, seconds: 3.0, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen, !self.mateFound else { return }
                if let (mv, _, depth) = r {
                    self.show(mv, p, note: "本地引擎(深度\(depth))")
                } else {
                    self.bestText = "无棋可走"
                    self.status = p.redToMove ? "红方被绝杀/困毙" : "黑方被绝杀/困毙"
                    self.refreshPiP()
                }
            }
        }
    }
}

// MARK: - 系统录屏启动按钮封装

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = "com.example.xqassist.broadcast"
        picker.showsMicrophoneButton = false
        for sub in picker.subviews {
            if let btn = sub as? UIButton {
                btn.setImage(nil, for: .normal)
                btn.setTitle("开始监控", for: .normal)
                btn.setTitleColor(.white, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
            }
        }
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - 画中画承载层视图

struct PiPHostView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        displayLayer.frame = CGRect(x: 0, y: 0, width: 180, height: 224)
        v.layer.addSublayer(displayLayer)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        displayLayer.frame = uiView.bounds
    }
}

// MARK: - 棋盘区域框选校准器

struct CalibrationView: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var screenshot: UIImage?
    @State private var rect: CGRect = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("导入一张象棋软件（如天天象棋）的完整截图，拖动绿框对齐棋盘外缘交叉点")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                PhotosPicker(selection: $selectedItem, matching: .screenshots) {
                    Label("从相册选择象棋截图", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .onChange(of: selectedItem) { item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            screenshot = img
                        }
                    }
                }

                GeometryReader { geo in
                    ZStack {
                        if let img = screenshot {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .overlay {
                                    GeometryReader { imgGeo in
                                        let w = imgGeo.size.width
                                        let h = imgGeo.size.height
                                        let box = CGRect(x: rect.minX * w, y: rect.minY * h,
                                                         width: rect.width * w, height: rect.height * h)
                                        Path { p in
                                            for c in 0...8 {
                                                let x = box.minX + CGFloat(c) / 8.0 * box.width
                                                p.move(to: CGPoint(x: x, y: box.minY))
                                                p.addLine(to: CGPoint(x: x, y: box.maxY))
                                            }
                                            for r in 0...9 {
                                                let y = box.minY + CGFloat(r) / 9.0 * box.height
                                                p.move(to: CGPoint(x: box.minX, y: y))
                                                p.addLine(to: CGPoint(x: box.maxX, y: y))
                                            }
                                        }
                                        .stroke(Color.green, lineWidth: 1.5)

                                        Rectangle()
                                            .fill(Color.green.opacity(0.12))
                                            .frame(width: box.width, height: box.height)
                                            .position(x: box.midX, y: box.midY)
                                            .gesture(DragGesture().onChanged { v in
                                                let nx = min(max(0, rect.minX + v.translation.width / w), 1 - rect.width)
                                                let ny = min(max(0, rect.minY + v.translation.height / h), 1 - rect.height)
                                                rect.origin = CGPoint(x: nx, y: ny)
                                            })

                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 24, height: 24)
                                            .position(x: box.maxX, y: box.maxY)
                                            .gesture(DragGesture().onChanged { v in
                                                let nw = min(max(0.2, (v.location.x - box.minX) / w), 1 - rect.minX)
                                                let nh = min(max(0.2, (v.location.y - box.minY) / h), 1 - rect.minY)
                                                rect.size = CGSize(width: nw, height: nh)
                                            })
                                    }
                                }
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.1))
                                .overlay(Text("请先选择一张截图").foregroundColor(.secondary))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack {
                    Button("重置默认") { rect = CGRect(x: 0.05, y: 0.24, width: 0.90, height: 0.50) }
                        .buttonStyle(.bordered)
                    Button("保存校准区域") {
                        m.updateCropRect(rect)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("校准棋盘区域")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { rect = m.cropRect }
        }
    }
}

// MARK: - 棋盘绘制 & 手动编辑器

struct BoardView: View {
    let pos: Position
    let best: Move?
    let onTap: (Int) -> Void

    var body: some View {
        GeometryReader { g in
            let cell = min(g.size.width / 9, g.size.height / 10)
            let ox = (g.size.width - cell * 9) / 2
            let oy = (g.size.height - cell * 10) / 2
            Canvas { ctx, _ in
                func P(_ r: Int, _ c: Int) -> CGPoint {
                    CGPoint(x: ox + (CGFloat(c) + 0.5) * cell, y: oy + (CGFloat(r) + 0.5) * cell)
                }
                var grid = Path()
                for r in 0..<10 { grid.move(to: P(r, 0)); grid.addLine(to: P(r, 8)) }
                for c in 0..<9 {
                    if c == 0 || c == 8 {
                        grid.move(to: P(0, c)); grid.addLine(to: P(9, c))
                    } else {
                        grid.move(to: P(0, c)); grid.addLine(to: P(4, c))
                        grid.move(to: P(5, c)); grid.addLine(to: P(9, c))
                    }
                }
                for (r0, r1) in [(0, 2), (7, 9)] {
                    grid.move(to: P(r0, 3)); grid.addLine(to: P(r1, 5))
                    grid.move(to: P(r0, 5)); grid.addLine(to: P(r1, 3))
                }
                ctx.stroke(grid, with: .color(.brown), lineWidth: 1)
                ctx.draw(Text("楚 河        汉 界").font(.system(size: cell * 0.4)).foregroundColor(.brown),
                         at: CGPoint(x: ox + cell * 4.5, y: oy + cell * 5))

                for i in 0..<90 where pos.b[i] != 0 {
                    let v = pos.b[i]
                    let p = P(i / 9, i % 9)
                    let rad = cell * 0.42
                    let col: Color = v > 0 ? .red : .black
                    let rect = CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.98, green: 0.93, blue: 0.8)))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(col), lineWidth: 2)
                    ctx.draw(Text(pieceName(v)).font(.system(size: cell * 0.5, weight: .bold)).foregroundColor(col), at: p)
                }

                if let m = best {
                    let a = P(m.from / 9, m.from % 9), t = P(m.to / 9, m.to % 9)
                    var line = Path()
                    line.move(to: a); line.addLine(to: t)
                    ctx.stroke(line, with: .color(.green), style: StrokeStyle(lineWidth: max(2, cell * 0.2), lineCap: .round))
                    for q in [a, t] {
                        let rr = cell * 0.46
                        ctx.stroke(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .color(.green), lineWidth: 3)
                    }
                }
            }
            .background(Color(red: 0.93, green: 0.8, blue: 0.55))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                let c = Int(floor((v.location.x - ox) / cell))
                let r = Int(floor((v.location.y - oy) / cell))
                if c >= 0, c < 9, r >= 0, r < 10 { onTap(r * 9 + c) }
            })
        }
    }
}

struct EditorView: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var showDlg = false

    var body: some View {
        VStack(spacing: 10) {
            Text("点击格子修正棋子").font(.footnote)
            Text(m.bestText).font(.title2.bold())
            BoardView(pos: m.pos, best: m.best) { idx in
                m.editIdx = idx
                showDlg = true
            }
            .aspectRatio(0.9, contentMode: .fit)
            Picker("", selection: Binding(get: { m.pos.redToMove }, set: { m.setTurn(red: $0) })) {
                Text("红方走").tag(true)
                Text("黑方走").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("复制FEN") { m.copyFEN() }
                Button("完成") { dismiss() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .confirmationDialog("设置该格", isPresented: $showDlg, titleVisibility: .visible) {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7], id: \.self) { code in
                Button(code == 0 ? "清空" : (code > 0 ? "红" : "黑") + pieceName(Int8(code))) {
                    m.setPiece(m.editIdx, code)
                }
            }
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var m = Model()
    @State private var showEditor = false
    @State private var showCalibrate = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(m.bestText).font(.title.bold()).foregroundColor(.green)
                            Spacer()
                            if m.isBroadcasting {
                                Label("监控中", systemImage: "record.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.red)
                            }
                        }
                        Text(m.status).font(.subheadline)
                        if !m.info.isEmpty {
                            Text(m.info).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)

                    BoardView(pos: m.pos, best: m.best) { _ in showEditor = true }
                        .aspectRatio(0.9, contentMode: .fit)
                        .cornerRadius(10)
                        .shadow(radius: 3)

                    HStack(spacing: 12) {
                        Button {
                            m.pip.toggle()
                        } label: {
                            Label("开启悬浮窗", systemImage: "pip.enter")
                                .font(.headline)
                                .frame(maxWidth: .infinity, height: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        BroadcastPickerView()
                            .frame(maxWidth: .infinity, height: 50)
                            .background(Color.green)
                            .cornerRadius(10)
                    }

                    VStack(spacing: 10) {
                        HStack {
                            Button {
                                showCalibrate = true
                            } label: {
                                Label("校准棋盘位置", systemImage: "viewfinder")
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Toggle("自动同步", isOn: $m.live)
                                .labelsHidden()
                            Text("自动同步").font(.footnote)
                        }

                        Picker("走子方", selection: Binding(get: { m.pos.redToMove }, set: { m.setTurn(red: $0) })) {
                            Text("红方走").tag(true)
                            Text("黑方走").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)

                    PiPHostView(displayLayer: m.pip.displayLayer)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                }
                .padding()
            }
            .navigationTitle("象棋后台助手")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showEditor) { EditorView(m: m) }
            .sheet(isPresented: $showCalibrate) { CalibrationView(m: m) }
        }
    }
}
