import SwiftUI
import AVFoundation

@main
struct XqAssistApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - 模型

final class Model: ObservableObject {
    @Published var pos = Position.start()
    @Published var best: Move?
    @Published var bestText = "—"
    @Published var status = "① 点「校准」，按提示点棋盘四角"
    @Published var corners: [CGPoint] = []
    @Published var calibrating = false
    @Published var live = false
    @Published var flipped = false { didSet { save() } }
    var editIdx = 0

    let cam = CameraService()
    private var templates: [Int: [Float]] = [:]
    private var thr: Float = 0.12
    private var learnPending = false
    private var pending: [Int8] = []
    private var stable = 0
    private var gen = 0
    private let engine = Engine()
    private let work = DispatchQueue(label: "xq.engine", qos: .userInitiated)

    private struct Saved: Codable {
        var corners: [CGPoint]
        var templates: [Int: [Float]]
        var thr: Float
        var flipped: Bool
    }

    init() {
        if let d = UserDefaults.standard.data(forKey: "saved"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            corners = s.corners
            templates = s.templates
            thr = s.thr
            flipped = s.flipped
            if corners.count == 4 && !templates.isEmpty { status = "已载入上次的校准与模板，可打开「实时识别」" }
        }
        cam.onFrame = { [weak self] pb in self?.handle(pb) }
    }

    private func save() {
        let s = Saved(corners: corners, templates: templates, thr: thr, flipped: flipped)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "saved") }
    }

    // 校准
    func startCalibration() {
        corners = []
        calibrating = true
        live = false
        status = "按 左上→右上→右下→左下 顺序，点棋盘最外侧四个交叉点（1/4）"
    }

    func tapCorner(_ p: CGPoint) {
        guard calibrating else { return }
        corners.append(p)
        if corners.count == 4 {
            calibrating = false
            save()
            status = "校准完成：检查绿色网格是否贴合；摆好初始局面后点「学习模板」"
        } else {
            status = "已点 \(corners.count)/4"
        }
    }

    func requestLearn() {
        guard corners.count == 4 else { status = "请先校准"; return }
        learnPending = true
        status = "学习中…请保持手机不动、棋盘为初始局面"
    }

    // 摄像头线程
    func handle(_ pb: CVPixelBuffer) {
        let s = DispatchQueue.main.sync {
            (corners: corners, flipped: flipped, live: live, learn: learnPending, templates: templates, thr: thr)
        }
        guard s.corners.count == 4, s.learn || (s.live && !s.templates.isEmpty),
              let feats = Analyzer.analyze(pb, corners: s.corners) else { return }
        if s.learn {
            DispatchQueue.main.async { self.finishLearn(feats, flipped: s.flipped) }
            return
        }
        let board = Analyzer.classify(feats, templates: s.templates, thr: s.thr, flipped: s.flipped)
        DispatchQueue.main.async { self.consider(board) }
    }

    private func finishLearn(_ feats: [CellFeatures], flipped fl: Bool) {
        guard learnPending else { return }
        learnPending = false
        let start = Position.start()
        var sum: [Int: [Float]] = [:]
        var occ: [Float] = [], emp: [Float] = []
        for idx in 0..<90 {
            let vr = idx / 9, vc = idx % 9
            let cr = fl ? 9 - vr : vr, cc = fl ? 8 - vc : vc
            let code = Int(start.b[cr * 9 + cc])
            let f = feats[idx]
            if code == 0 { emp.append(f.ink); continue }
            occ.append(f.ink)
            var a = sum[code] ?? [Float](repeating: 0, count: f.desc.count)
            for k in 0..<a.count { a[k] += f.desc[k] }
            sum[code] = a
        }
        guard sum.count == 14, let me = emp.max(), let mo = occ.min() else { status = "学习失败，请重试"; return }
        templates = sum.mapValues { Analyzer.normalize($0) }
        if me < mo {
            thr = (me + mo) / 2
        } else {
            thr = (emp.reduce(0, +) / Float(emp.count) + occ.reduce(0, +) / Float(occ.count)) / 2
        }
        save()
        status = "模板学习完成，可打开「实时识别」"
    }

    // 识别结果（主线程）：连续 3 次一致才采纳
    private func consider(_ board: [Int8]) {
        if board == pending { stable += 1 } else { pending = board; stable = 1 }
        guard live, stable >= 3, board != pos.b else { return }
        var np = pos
        // 如果新局面恰好是当前局面走一步合法棋的结果，自动切换走子方
        for m in pos.legalMoves() {
            var t = pos
            t.make(m)
            if t.b == board { np.redToMove.toggle(); break }
        }
        np.b = board
        pos = np
        analyze()
    }

    // 手动编辑
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

    func reset() {
        live = false
        pos = Position.start()
        analyze()
    }

    func copyFEN() {
        UIPasteboard.general.string = pos.fen
        status = "FEN 已复制"
    }

    // 引擎分析
    func analyze() {
        gen += 1
        let g = gen
        let p = pos
        best = nil
        if let prob = p.validate() {
            bestText = "—"
            status = "局面不合法：\(prob)"
            return
        }
        status = "思考中…"
        work.async { [weak self] in
            guard let self = self else { return }
            let r = self.engine.search(p, seconds: 2.0, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                if let (mv, score, depth) = r {
                    self.best = mv
                    self.bestText = (p.redToMove ? "红：" : "黑：") + p.notation(mv)
                    self.status = "搜索深度 \(depth)，评分 \(score)"
                } else {
                    self.bestText = "无棋可走"
                    self.status = p.redToMove ? "红方已被将死/困毙" : "黑方已被将死/困毙"
                }
            }
        }
    }
}

// MARK: - 摄像头预览封装

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let corners: [CGPoint]
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.pl.session = session
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.onTap = onTap
        v.corners = corners
    }
}

// MARK: - 棋盘绘制

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
                    ctx.stroke(line, with: .color(.green), style: StrokeStyle(lineWidth: 5, lineCap: .round))
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

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var m = Model()
    @State private var showEdit = false

    var body: some View {
        VStack(spacing: 6) {
            CameraPreview(session: m.cam.session, corners: m.corners, onTap: { m.tapCorner($0) })
                .frame(height: 230)
                .clipped()
                .overlay(alignment: .bottom) {
                    Text(m.status)
                        .font(.footnote)
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.55))
                        .foregroundColor(.white)
                }
            Text(m.bestText).font(.title2.bold())
            BoardView(pos: m.pos, best: m.best) { idx in
                m.editIdx = idx
                showEdit = true
            }
            .aspectRatio(0.9, contentMode: .fit)
            HStack {
                Button("校准") { m.startCalibration() }
                Button("学习模板") { m.requestLearn() }
                Button("初始局面") { m.reset() }
                Button("复制FEN") { m.copyFEN() }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            HStack {
                Toggle("实时识别", isOn: $m.live)
                Toggle("我执黑", isOn: $m.flipped)
            }
            .font(.footnote)
            .padding(.horizontal)
            Picker("", selection: Binding(get: { m.pos.redToMove }, set: { m.setTurn(red: $0) })) {
                Text("红方走").tag(true)
                Text("黑方走").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .onAppear { m.cam.start() }
        .confirmationDialog("设置该格", isPresented: $showEdit, titleVisibility: .visible) {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7], id: \.self) { code in
                Button(code == 0 ? "清空" : (code > 0 ? "红" : "黑") + pieceName(Int8(code))) {
                    m.setPiece(m.editIdx, code)
                }
            }
        }
    }
}
