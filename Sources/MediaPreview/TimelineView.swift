import AppKit
import AVFoundation
import AVKit

struct ABMarkerRenderState: Equatable {
    let a: Double?
    let b: Double?

    var range: ClosedRange<Double>? {
        guard let a, let b, a < b else { return nil }
        return a...b
    }
}

final class TimelineView: NSView {
    var hoverChanged: ((Double) -> Void)?; var hoverStarted: (() -> Void)?; var hoverEnded: (() -> Void)?
    var playheadFraction: Double = 0 { didSet { needsDisplay = true } }
    private enum ContentMode { case thumbnails, waveform }
    private var hoverFraction: Double? { didSet { needsDisplay = true } }; private var images = Array<NSImage?>(repeating: nil, count: 10); private var waveform: [CGFloat] = []; private var contentMode: ContentMode = .thumbnails; private var markers = ABMarkerRenderState(a: nil, b: nil); private var tracking: NSTrackingArea?
    override func updateTrackingAreas() { if let tracking { removeTrackingArea(tracking) }; let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil); addTrackingArea(area); tracking = area; super.updateTrackingAreas() }
    func setImage(_ image: NSImage, at index: Int) {
        guard images.indices.contains(index) else { return }
        if image.size.width > 0, image.size.height > 0 { images[index] = image }
        else if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { images[index] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)) }
        else { images[index] = image }
        contentMode = .thumbnails; needsDisplay = true
    }
    func setWaveform(_ values: [CGFloat]) { waveform = values.map { max(0, min(1, $0)) }; contentMode = .waveform; needsDisplay = true }
    func setABMarkers(_ markers: ABMarkerRenderState) { self.markers = markers; needsDisplay = true }
    override func mouseEntered(with event: NSEvent) { hoverStarted?(); update(event) }
    override func mouseMoved(with event: NSEvent) { update(event) }
    override func mouseExited(with event: NSEvent) { hoverFraction = nil; hoverEnded?() }
    private func update(_ event: NSEvent) { let point = convert(event.locationInWindow, from: nil); let fraction = max(0, min(1, point.x / max(bounds.width, 1))); hoverFraction = fraction; hoverChanged?(fraction) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        if contentMode == .waveform, !waveform.isEmpty {
            let width = bounds.width / CGFloat(waveform.count)
            for (index, value) in waveform.enumerated() { let height = max(2, bounds.height * value); NSColor.systemBlue.withAlphaComponent(0.75).setFill(); NSRect(x: CGFloat(index) * width + 1, y: (bounds.height - height) / 2, width: max(1, width - 2), height: height).fill() }
        }
        let width = bounds.width / 10
        if contentMode == .thumbnails {
            for index in 0..<10 { let rect = NSRect(x: CGFloat(index) * width + 1, y: 1, width: max(0, width - 2), height: bounds.height - 2); if let image = images[index] { image.draw(in: rect, from: ThumbnailCropMath.sourceCrop(imageSize: image.size, filling: rect.size), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]) } else { NSColor(calibratedWhite: 0.2, alpha: 1).setFill(); rect.fill() }; NSColor.black.withAlphaComponent(0.55).setStroke(); NSBezierPath(rect: rect).stroke() }
            if let hoverFraction { let index = min(9, Int(hoverFraction * 10)); NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect: NSRect(x: CGFloat(index) * width + 1, y: 1, width: max(0, width - 2), height: bounds.height - 2)); path.lineWidth = 2; path.stroke() }
        }
        if let range = markers.range {
            NSColor.black.withAlphaComponent(0.45).setFill(); NSRect(x: 0, y: 0, width: bounds.width * range.lowerBound, height: bounds.height).fill(); NSRect(x: bounds.width * range.upperBound, y: 0, width: bounds.width * (1 - range.upperBound), height: bounds.height).fill()
        }
        for (fraction, label) in [(markers.a, "A"), (markers.b, "B")] {
            guard let fraction else { continue }
            let x = bounds.width * fraction; NSColor.systemYellow.setStroke(); let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x, y: bounds.height)); path.lineWidth = 2; path.stroke()
            let text = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.systemYellow]); text.draw(at: NSPoint(x: min(max(2, x + 3), bounds.width - 12), y: bounds.height - 14))
        }
        let x = bounds.width * (hoverFraction ?? playheadFraction); NSColor.white.withAlphaComponent(0.9).setStroke(); let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 0)); line.line(to: NSPoint(x: x, y: bounds.height)); line.lineWidth = 1.5; line.stroke()
    }
}

enum TimelineMath { static func time(fraction: Double, duration: Double) -> Double { max(0, min(1, fraction)) * max(0, duration) } }
enum WaveformMath {
    static func bars(count: Int) -> [CGFloat] { guard count > 0 else { return [] }; return (0..<count).map { 0.18 + 0.72 * abs(sin(Double($0) * 0.47)) } }
    static func normalized(_ values: [CGFloat]) -> [CGFloat] {
        guard let peak = values.max(), peak > 0 else { return values.map { _ in 0 } }
        return values.map { min(1, max(0, $0 / peak)) }
    }
}

/// Cancellation is checked between every decoded PCM buffer so closing the panel does not
/// publish stale waveform UI updates.
final class WaveformExtraction: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum WaveformReader {
    static let preferredBarCount = 240

    static func extract(url: URL, bars: Int = preferredBarCount, cancellation: WaveformExtraction) -> [CGFloat]? {
        guard bars >= 160, bars <= 400, !cancellation.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        let duration = max(asset.duration.seconds, 0)
        guard duration.isFinite, duration > 0 else { return nil }
        var amplitudes = Array(repeating: CGFloat.zero, count: bars)
        guard reader.startReading() else { return nil }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while reader.status == .reading, !cancellation.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let sampleDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
            let start = max(0, min(bars - 1, Int((presentation / duration * Double(bars)).rounded(.down))))
            let end = max(start, min(bars - 1, Int(((presentation + max(sampleDuration, 0)) / duration * Double(bars)).rounded(.down))))
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                  let dataPointer, length >= MemoryLayout<Float>.size else { continue }
            let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            let count = length / MemoryLayout<Float>.size
            var peak: Float = 0
            for index in 0..<count { peak = max(peak, abs(samples[index])) }
            let value = CGFloat(peak)
            for index in start...end { amplitudes[index] = max(amplitudes[index], value) }
        }
        return cancellation.isCancelled ? nil : WaveformMath.normalized(amplitudes)
    }
}

final class ZoomablePlayerSurface: NSView {
    let playerView = AVPlayerView()
    var onSingleClick: (() -> Void)?
    private(set) var magnification: CGFloat = 1
    private(set) var displayTransform = VideoDisplayTransform()
    private var pan = CGPoint.zero
    private var lastDragLocation: CGPoint?
    private var didDrag = false
    private var pendingSingleClick: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        addSubview(playerView)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func layout() { super.layout(); applyTransform() }
    override func magnify(with event: NSEvent) {
        applyMagnification(by: event.magnification, centeredAt: convert(event.locationInWindow, from: nil))
    }
    func applyMagnification(by delta: CGFloat, centeredAt point: CGPoint) {
        let old = magnification
        let next = min(6, max(1, old + delta))
        guard next != old else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        pan = CGPoint(x: point.x - center.x - (point.x - center.x - pan.x) * next / old,
                      y: point.y - center.y - (point.y - center.y - pan.y) * next / old)
        magnification = next
        clampPan(); applyTransform()
    }
    override func scrollWheel(with event: NSEvent) {
        guard magnification > 1, !event.modifierFlags.contains(.control) else { return super.scrollWheel(with: event) }
        pan.x += event.scrollingDeltaX; pan.y -= event.scrollingDeltaY
        clampPan(); applyTransform()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pendingSingleClick?.cancel(); pendingSingleClick = nil; resetZoom(); return }
        lastDragLocation = convert(event.locationInWindow, from: nil)
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let lastDragLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        didDrag = true
        guard magnification > 1 else { return }
        pan.x += point.x - lastDragLocation.x; pan.y += point.y - lastDragLocation.y
        self.lastDragLocation = point; clampPan(); applyTransform()
    }
    override func mouseUp(with event: NSEvent) {
        defer { lastDragLocation = nil }
        guard event.clickCount == 1, !didDrag else { return }
        let work = DispatchWorkItem { [weak self] in self?.onSingleClick?() }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
    func resetZoom() { magnification = 1; pan = .zero; applyTransform() }
    func setDisplayTransform(_ transform: VideoDisplayTransform) {
        displayTransform = transform
        applyTransform()
    }
    private func clampPan() {
        guard magnification > 1 else { pan = .zero; return }
        let x = bounds.width * (magnification - 1) / 2
        let y = bounds.height * (magnification - 1) / 2
        pan.x = min(x, max(-x, pan.x)); pan.y = min(y, max(-y, pan.y))
    }
    private func applyTransform() {
        let baseFrame: CGRect
        if displayTransform.swapsDimensions {
            // Let AVPlayerView aspect-fit the unrotated image inside a swapped
            // canvas first. After the layer quarter-turn, that canvas is the
            // surface bounds, so a wide video is not clipped vertically.
            baseFrame = CGRect(
                x: bounds.midX - bounds.height / 2,
                y: bounds.midY - bounds.width / 2,
                width: bounds.height,
                height: bounds.width
            )
        } else {
            baseFrame = bounds
        }
        playerView.frame = baseFrame
        guard let layer = playerView.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
        let angle = -CGFloat(displayTransform.quarterTurnsClockwise) * .pi / 2
        var transform = CGAffineTransform(rotationAngle: angle)
        if displayTransform.isMirrored { transform = transform.scaledBy(x: -1, y: 1) }
        layer.setAffineTransform(transform.scaledBy(x: magnification, y: magnification))
    }
}

enum VolumeControlMath {
    static func clamped(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
}

final class VerticalVolumeControl: NSView {
    var value: Float = 1 { didSet { needsDisplay = true } }
    var valueChanged: ((Float) -> Void)?

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "音量"
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 5, dy: 3)
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width, height: track.height * CGFloat(value))
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 4, yRadius: 4).fill()
    }
    override func mouseDown(with event: NSEvent) { setValue(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { setValue(at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 12
        setValue(Float(CGFloat(value) + delta))
    }
    private func setValue(at point: NSPoint) { setValue(Float(VolumeControlMath.clamped(point.y / max(bounds.height, 1)))) }
    private func setValue(_ nextValue: Float) {
        value = nextValue
        valueChanged?(value)
    }
}

final class ZoomableImageSurface: NSView {
    let imageView = NSImageView()
    private(set) var magnification: CGFloat = 1
    private(set) var displayTransform = VideoDisplayTransform()
    private var pan = CGPoint.zero
    private var lastDragLocation: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.wantsLayer = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func layout() { super.layout(); applyTransform() }
    override func magnify(with event: NSEvent) {
        applyMagnification(by: event.magnification, centeredAt: convert(event.locationInWindow, from: nil))
    }
    func applyMagnification(by delta: CGFloat, centeredAt point: CGPoint) {
        let old = magnification
        let next = min(6, max(1, old + delta))
        guard next != old else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        pan = CGPoint(x: point.x - center.x - (point.x - center.x - pan.x) * next / old,
                      y: point.y - center.y - (point.y - center.y - pan.y) * next / old)
        magnification = next
        clampPan(); applyTransform()
    }
    override func scrollWheel(with event: NSEvent) {
        guard magnification > 1, !event.modifierFlags.contains(.control) else { return super.scrollWheel(with: event) }
        pan.x += event.scrollingDeltaX; pan.y -= event.scrollingDeltaY
        clampPan(); applyTransform()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { resetZoom(); return }
        lastDragLocation = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard magnification > 1, let lastDragLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        pan.x += point.x - lastDragLocation.x; pan.y += point.y - lastDragLocation.y
        self.lastDragLocation = point; clampPan(); applyTransform()
    }
    override func mouseUp(with event: NSEvent) { lastDragLocation = nil }
    func resetZoom() { magnification = 1; pan = .zero; applyTransform() }
    func setDisplayTransform(_ transform: VideoDisplayTransform) {
        displayTransform = transform
        applyTransform()
    }
    private func clampPan() {
        guard magnification > 1 else { pan = .zero; return }
        let x = bounds.width * (magnification - 1) / 2
        let y = bounds.height * (magnification - 1) / 2
        pan.x = min(x, max(-x, pan.x)); pan.y = min(y, max(-y, pan.y))
    }
    private func applyTransform() {
        let baseFrame: CGRect
        if displayTransform.swapsDimensions {
            baseFrame = CGRect(
                x: bounds.midX - bounds.height / 2,
                y: bounds.midY - bounds.width / 2,
                width: bounds.height,
                height: bounds.width
            )
        } else {
            baseFrame = bounds
        }
        imageView.frame = baseFrame
        guard let layer = imageView.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
        let angle = -CGFloat(displayTransform.quarterTurnsClockwise) * .pi / 2
        var transform = CGAffineTransform(rotationAngle: angle)
        if displayTransform.isMirrored { transform = transform.scaledBy(x: -1, y: 1) }
        layer.setAffineTransform(transform.scaledBy(x: magnification, y: magnification))
    }
}

enum ABLoopMath {
    static func normalized(a: Double?, b: Double?, duration: Double) -> ClosedRange<Double>? { guard let a, let b, duration > 0 else { return nil }; let lower = max(0, min(a, b)); let upper = min(duration, max(a, b)); return upper > lower ? lower...upper : nil }
    static func restartTarget(time: Double, a: Double?, b: Double?, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        if let range = normalized(a: a, b: b, duration: duration) { return time >= range.upperBound ? range.lowerBound : nil }
        return time >= duration ? 0 : nil
    }
    static func endTarget(a: Double?, b: Double?, duration: Double) -> Double { normalized(a: a, b: b, duration: duration)?.lowerBound ?? 0 }
}

enum ThumbnailCropMath {
    static func sourceCrop(imageSize: CGSize, filling cellSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, cellSize.width > 0, cellSize.height > 0 else { return .zero }
        let imageAspect = imageSize.width / imageSize.height
        let cellAspect = cellSize.width / cellSize.height
        if imageAspect > cellAspect {
            let width = imageSize.height * cellAspect
            return CGRect(x: (imageSize.width - width) / 2, y: 0, width: width, height: imageSize.height)
        }
        let height = imageSize.width / cellAspect
        return CGRect(x: 0, y: (imageSize.height - height) / 2, width: imageSize.width, height: height)
    }
}
