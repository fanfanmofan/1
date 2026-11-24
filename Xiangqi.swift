import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private let recognizer = ScreenRecognizer()
    private var lastRun = Date.distantPast
    private var pendingBoard: [Int8] = []
    private var stableCount = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lastRun = Date.distantPast
        pendingBoard = []
        stableCount = 0
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              Date().timeIntervalSince(lastRun) >= 0.8,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastRun = Date()

        autoreleasepool {
            guard let res = recognizer.run(pb) else { return }

            if res.board == pendingBoard {
                stableCount += 1
            } else {
                pendingBoard = res.board
                stableCount = 1
            }

            if stableCount == 2 {
                SharedStore.saveBoard(
                    res.board,
                    flipped: res.flipped,
                    unknownCount: res.unknownCount,
                    info: res.info
                )
            }
        }
    }
}
