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
    @Published var showLabels = true
    @Published var uncertain: [Int] = []
    var editIdx = 0

    let cam = CameraService()
    private var rec: Recognizer?
    private var learnPending = false
    private var learnSamples: [LearnSample] = []
    private var pending: [Int8] = []
    private var stable = 0
    private var gen = 0
    private var mateFound = false
    private let engine = Engine()
    private let work = DispatchQueue(label: "xq.engine", qos: .userInitiated)
    private let mateQ = DispatchQueue(label: "xq.mate", qos: .userInitiated)

    private struct Saved: Codable {
        var corners: [CGPoint]
        var rec: Recognizer?
        var flipped: Bool
    }

    init() {
        if let d = UserDefaults.standard.data(forKey: "saved2"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            corners = s.corners
            rec = s.rec
            flipped = s.flipped
            if corners.count == 4 && rec != nil { status = "已载入上次的校准与模板，可打开「实时识别」" }
        }
        cam.onFrame = { [weak self] pb in self?.handle(pb) }
    }

    private func save() {
        let s = Saved(corners: corners, rec: rec, flipped: flipped)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "saved2") }
    }

    // MARK: 校准

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
        learnSamples = []
        learnPending = true
        status = "学习中 0/3…请保持手机不动、棋盘为初始局面"
    }

    // MARK: 摄像头线程

    func handle(_ pb: CVPixelBuffer) {
        let s = DispatchQueue.main.sync {
            (corners: corners, flipped: flipped, live: live, learn: learnPending, rec: rec)
        }
        guard s.corners.count == 4, s.learn || (s.live && s.rec != nil),
              let R = Analyzer.rectify(pb, corners: s.corners) else { return }
        if s.learn {
            let sample = Analyzer.learnSample(R)
            DispatchQueue.main.async { self.addSample(sample, flipped: s.flipped) }
            return
        }
        guard let r = s.rec else { return }
        let res = Analyzer.classify(R, rec: r, flipped: s.flipped)
        DispatchQueue.main.async { self.consider(res.board, res.uncertain) }
    }

    // MARK: 学习模板（连续采 3 帧）

    private func addSample(_ s: LearnSample, flipped fl: Bool) {
        guard learnPending else { return }
        learnSamples.append(s)
        if learnSamples.count < 3 {
            status = "学习中 \(learnSamples.count)/3…"
            return
        }
        learnPending = false
        finalizeLearn(fl)
    }

    private func finalizeLearn(_ fl: Bool) {
        let samples = learnSamples
        learnSamples = []
        let start = Position.start()
        var sum: [Int: [Float]] = [:]
        var occ: [[Float]] = [], emp: [[Float]] = []
        for s in samples {
            for idx in 0..<90 {
                let vr = idx / 9, vc = idx % 9
                let cr = fl ? 9 - vr : vr, cc = fl ? 8 - vc : vc
                let code = Int(start.b[cr * 9 + cc])
                if code == 0 { emp.append(s.stats[idx].f); continue }
                occ.append(s.stats[idx].f)
                var a = sum[code] ?? [Float](repeating: 0, count: s.descs[idx].count)
                for k in 0..<a.count { a[k] += s.descs[idx][k] }
                sum[code] = a
            }
        }
        guard sum.count == 14, !occ.isEmpty, !emp.isEmpty else { status = "学习失败，请重试"; return }

        func ms(_ a: [Float]) -> (Float, Float) {
            let m = a.reduce(0, +) / Float(a.count)
            let v = a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(a.count)
            return (m, v.squareRoot())
        }
        // 自动挑选最能区分"有子 / 空格"的特征
        var bf = 0, bd: Float = -1, pol: Float = 1, thr: Float = 0
        for k in 0..<Analyzer.nf {
            let (mo, so) = ms(occ.map { $0[k] })
            let (me, se) = ms(emp.map { $0[k] })
            let d = abs(mo - me) / (so + se + 1e-4)
            if d > bd {
                bd = d; bf = k
                pol = mo > me ? 1 : -1
                thr = (me * so + mo * se) / (so + se + 1e-4)
            }
        }
        let r = Recognizer(templates: sum.mapValues { Analyzer.normalize($0) }, feat: bf, pol: pol, thr: thr)
        rec = r
        save()

        // 自检：用最后一帧回测
        var ok = 0
        if let last = samples.last {
            let res = Analyzer.classify(last.rect, rec: r, flipped: fl)
            for i in 0..<90 where start.b[i] != 0 && res.board[i] == start.b[i] { ok += 1 }
        }
        status = "模板学习完成，自检 \(ok)/32 正确，可打开「实时识别」"
    }

    // MARK: 识别结果（主线程）：连续 3 次一致才采纳

    private func consider(_ board: [Int8], _ unc: [Int]) {
        uncertain = unc
        if !unc.isEmpty {
            stable = 0
            pending = []
            status = "有 \(unc.count) 个格子认不出（黄色？号）：调整光线/角度，或点右上角小棋盘手动修正"
            return
        }
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

    // MARK: 手动编辑

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

    // MARK: 分析：绝杀搜索 + 云端引擎（本地引擎兜底）

    func analyze() {
        gen += 1
        let g = gen
        let p = pos
        best = nil
        mateFound = false
        if let prob = p.validate() {
            bestText = "—"
            status = "局面不合法：\(prob)"
            return
        }
        bestText = "分析中…"
        status = "绝杀搜索 + 云端引擎分析中…"

        // 1) 本地绝杀搜索：N 步内的连将杀
        mateQ.async { [weak self] in
            guard let self = self else { return }
            let r = MateSearch().find(p, maxMoves: 7, seconds: 2.5, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen, let (mv, n) = r else { return }
                self.mateFound = true
                self.show(mv, p, note: "\(n)步杀！")
            }
        }
        // 2) 云端强引擎
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
    }

    private func runLocal(_ p: Position, _ g: Int) {
        status = "云端不可用，使用本地引擎…"
        work.async { [weak self] in
            guard let self = self else { return }
            let r = self.engine.search(p, seconds: 3.0, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen, !self.mateFound else { return }
                if let (mv, _, depth) = r {
                    self.show(mv, p, note: "本地引擎（深度\(depth)，联网后更强）")
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
    let board: [Int8]
    let best: Move?
    let flipped: Bool
    let uncertain: [Int]
    let showLabels: Bool
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.pl.session = session
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.onTap = onTap
        v.update(corners: corners, board: board, best: best, flipped: flipped,
                 uncertain: uncertain, showLabels: showLabels)
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

// MARK: - 手动修正局面（点小棋盘进入）

struct EditorView: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var showDlg = false

    var body: some View {
        VStack(spacing: 10) {
            Text("点击格子修改棋子（修改后实时识别会暂停）").font(.footnote)
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

// MARK: - 主界面：全屏摄像头 + 叠加最佳走法

struct ContentView: View {
    @StateObject private var m = Model()
    @State private var showEditor = false

    var body: some View {
        ZStack {
            CameraPreview(session: m.cam.session, corners: m.corners, board: m.pos.b, best: m.best,
                          flipped: m.flipped, uncertain: m.uncertain, showLabels: m.showLabels,
                          onTap: { m.tapCorner($0) })
                .ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.bestText).font(.title2.bold()).foregroundColor(.white)
                        Text(m.status).font(.footnote).foregroundColor(.white)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(10)
                    Spacer(minLength: 0)
                    BoardView(pos: m.pos, best: m.best) { _ in showEditor = true }
                        .frame(width: 117, height: 130)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1))
                }
                .padding(.horizontal, 8)
                Spacer()
                VStack(spacing: 6) {
                    HStack {
                        Button("校准") { m.startCalibration() }
                        Button("学习模板") { m.requestLearn() }
                        Button("初始局面") { m.reset() }
                        Button(m.showLabels ? "隐藏标记" : "显示标记") { m.showLabels.toggle() }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                    HStack {
                        Toggle("实时识别", isOn: $m.live)
                        Toggle("我执黑", isOn: $m.flipped)
                    }
                    .font(.footnote)
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .onAppear { m.cam.start() }
        .sheet(isPresented: $showEditor) { EditorView(m: m) }
    }
}
