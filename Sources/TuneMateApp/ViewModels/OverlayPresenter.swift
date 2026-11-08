import Foundation
import Combine
import TuneMateCore
#if os(iOS)
import UIKit
import AVKit
import AVFoundation
import UserNotifications
#endif

/// 같은 아이패드에서 공식 믹서 앱을 전체 화면으로 쓰는 동안 지시 체크리스트를 작은 창(PiP)으로 띄운다.
/// iOS 는 다른 앱 위에 뷰를 올릴 수 없으므로, 체크리스트를 영상 프레임으로 그려 Picture-in-Picture 로 내보낸다.
@MainActor
final class OverlayPresenter: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isSupported = false
    @Published var lastError = ""

    #if os(iOS)
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var timer: Timer?
    private var current: Instruction?
    private var frameIndex: Int64 = 0
    private let fps: Double = 2
    private let size = CGSize(width: 640, height: 480)
    private var hostView: UIView?
    #endif

    override init() {
        super.init()
        #if os(iOS)
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        #endif
    }

    /// 지시를 PiP 창으로 띄운다 (iOS). 이미 떠 있으면 내용만 갱신.
    func show(_ instruction: Instruction) {
        #if os(iOS)
        current = instruction
        if isActive { render(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { lastError = "오디오 세션: \(error.localizedDescription)" }
        if hostView == nil, let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)); v.isHidden = false; v.alpha = 0.01
            displayLayer.frame = v.bounds; displayLayer.videoGravity = .resizeAspect
            v.layer.addSublayer(displayLayer)
            window.addSubview(v); hostView = v
        }
        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            pipController = AVPictureInPictureController(contentSource: source)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        render()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in Task { @MainActor in self?.render() } }
        // 몇 프레임이 들어간 뒤 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let pip = self.pipController else { return }
            if pip.isPictureInPicturePossible { pip.startPictureInPicture() } else { self.lastError = "PiP 를 지금 시작할 수 없습니다 (앱이 전면에 있고 화면이 보이는 상태여야 합니다)" }
        }
        #endif
    }

    func update(_ instruction: Instruction) {
        #if os(iOS)
        current = instruction
        if isActive { render() }
        #endif
    }

    func hide() {
        #if os(iOS)
        pipController?.stopPictureInPicture()
        timer?.invalidate(); timer = nil
        #endif
    }

    #if os(iOS)
    private func render() {
        guard let ins = current else { return }
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor(white: 0.08, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let title = NSAttributedString(string: ins.title, attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white])
            title.draw(at: CGPoint(x: 24, y: 18))
            var y: CGFloat = 70
            let pending = ins.steps.filter { !$0.done }
            let shown = Array(ins.steps.prefix(7))
            for st in shown {
                let mark = st.done ? "☑" : "☐"
                let color: UIColor = st.done ? UIColor(white: 0.55, alpha: 1) : UIColor.white
                let line = NSAttributedString(string: "\(mark) \(st.text)", attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .medium), .foregroundColor: color])
                line.draw(in: CGRect(x: 24, y: y, width: size.width - 48, height: 60))
                y += 52
            }
            let foot = NSAttributedString(string: "남은 항목 \(pending.count)/\(ins.steps.count) · 튠메이트", attributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor(white: 0.7, alpha: 1)])
            foot.draw(at: CGPoint(x: 24, y: size.height - 34))
        }
        guard let cg = img.cgImage, let buffer = Self.pixelBuffer(from: cg, size: size) else { return }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)), presentationTimeStamp: CMTime(value: frameIndex, timescale: Int32(fps)), decodeTimeStamp: .invalid)
        frameIndex += 1
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sample)
        }
    }

    private static func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return pb
    }
    #endif

    // MARK: 알림 배너 — 새 지시가 오면 다른 앱 위에도 뜬다
    static func requestNotificationPermission() {
        #if os(iOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }
    static func notify(_ instruction: Instruction) {
        #if os(iOS)
        let c = UNMutableNotificationContent()
        c.title = "튠메이트 지시: \(instruction.title)"
        c.body = instruction.steps.prefix(3).map(\.text).joined(separator: "\n") + (instruction.steps.count > 3 ? "\n외 \(instruction.steps.count - 3)항목" : "")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: instruction.id.uuidString, content: c, trigger: nil))
        #endif
    }
}

#if os(iOS)
extension OverlayPresenter: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.isActive = true } }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.isActive = false; self.timer?.invalidate() } }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.isActive = false; self.lastError = "PiP 시작 실패: \(error.localizedDescription)" }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}
#endif
