import AppKit
import AVKit
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: PreviewPanel?
    private var controller: PreviewController?
    private var keyEventMonitor: Any?
    private var idleTerminationWorkItem: DispatchWorkItem?
    private var settingsController: ShortcutSettingsWindowController?
    private let keepsOpenForVisualQA = ProcessInfo.processInfo.environment["MEDIA_PREVIEW_QA_KEEP_OPEN"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        installMainMenu()
        guard let url = LaunchInput.mediaURL(from: CommandLine.arguments) else {
            scheduleIdleTermination()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { NSApp.terminate(nil); return }
        presentPreview(for: url)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "AI Video Cutty")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 AI Video Cutty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsController ?? ShortcutSettingsWindowController(store: .shared)
        settingsController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc(showMediaPreview:userData:error:)
    func showMediaPreview(_ pasteboard: NSPasteboard, userData _: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        cancelIdleTermination()
        guard let url = ServiceInput.firstRegularFileURL(from: pasteboard) else {
            error.pointee = "Select a media file in Finder." as NSString
            scheduleIdleTermination()
            return
        }
        presentPreview(for: url)
    }

    private func presentPreview(for url: URL) {
        let visibleFrame = PreviewPanelLayout.selectedVisibleFrame(
            primaryScreen: NSScreen.screens.first?.visibleFrame,
            mainScreen: NSScreen.main?.visibleFrame
        )
        if let panel {
            placePreviewPanel(panel, in: visibleFrame)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let mediaKind = MediaRoute.previewKind(for: url) else { NSApp.terminate(nil); return }
        let panelSize = PreviewPanelLayout.size(for: visibleFrame.size)
        let controller = PreviewController(url: url, mediaKind: mediaKind)
        controller.onShowShortcutSettings = { [weak self] in self?.showSettings(nil) }
        let panel = PreviewPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.fullScreenPrimary]; panel.backgroundColor = .black
        panel.delegate = self; panel.contentViewController = controller
        placePreviewPanel(panel, in: visibleFrame)
        self.panel = panel; self.controller = controller
        installKeyEventMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func placePreviewPanel(_ panel: PreviewPanel, in visibleFrame: NSRect) {
        panel.setContentSize(PreviewPanelLayout.size(for: visibleFrame.size))
        panel.setFrame(
            PreviewPanelLayout.targetFrame(for: visibleFrame, windowFrameSize: panel.frame.size),
            display: true
        )
    }

    func windowWillClose(_ notification: Notification) {
        cancelIdleTermination()
        removeKeyEventMonitor()
        controller?.tearDown()
        NSApp.terminate(nil)
    }

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.shouldRoutePreviewInput(event) else { return event }
            switch event.type {
            case .keyDown:
                if let command = PreviewKeyRouting.command(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                    switch command {
                    case .close: self.panel?.close()
                    default: self.controller?.handle(command)
                    }
                    return nil
                }
                return self.controller?.handlePlainArrowKeyDown(event) == true ? nil : event
            case .keyUp:
                return self.controller?.handlePlainArrowKeyUp(event) == true ? nil : event
            default:
                return event
            }
        }
    }

    /// A local monitor also sees native sheets and the shortcut-settings window.
    /// Keep their text editors in the normal responder chain, especially the
    /// compression size field in an NSSavePanel accessory view.
    private func shouldRoutePreviewInput(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        return !(event.window?.firstResponder is NSTextView)
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func scheduleIdleTermination() {
        cancelIdleTermination()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.panel == nil else { return }
            self.showSettings(nil)
        }
        idleTerminationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func cancelIdleTermination() {
        idleTerminationWorkItem?.cancel()
        idleTerminationWorkItem = nil
    }
}

enum PreviewPanelLayout {
    static let screenFraction: CGFloat = 0.68
    static let minimumSize = CGSize(width: 960, height: 680)
    static let screenMargin: CGFloat = 40
    static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 960, height: 680)

    static func selectedVisibleFrame(
        primaryScreen: NSRect?,
        mainScreen: NSRect?,
        fallback: NSRect = fallbackVisibleFrame
    ) -> NSRect {
        primaryScreen ?? mainScreen ?? fallback
    }

    static func size(for visibleScreenSize: CGSize) -> CGSize {
        let maximumSize = CGSize(
            width: max(0, visibleScreenSize.width - 2 * screenMargin),
            height: max(0, visibleScreenSize.height - 2 * screenMargin)
        )
        let targetSize = CGSize(
            width: visibleScreenSize.width * screenFraction,
            height: visibleScreenSize.height * screenFraction
        )
        let canFitMinimum = maximumSize.width >= minimumSize.width && maximumSize.height >= minimumSize.height
        return CGSize(
            width: min(maximumSize.width, canFitMinimum ? max(targetSize.width, minimumSize.width) : targetSize.width),
            height: min(maximumSize.height, canFitMinimum ? max(targetSize.height, minimumSize.height) : targetSize.height)
        )
    }

    static func targetFrame(for visibleFrame: NSRect, windowFrameSize: CGSize) -> NSRect {
        NSRect(
            x: visibleFrame.midX - windowFrameSize.width / 2,
            y: visibleFrame.midY - windowFrameSize.height / 2,
            width: windowFrameSize.width,
            height: windowFrameSize.height
        )
    }
}

@MainActor
enum PreviewContentLayout {
    @discardableResult
    static func constrainToContentWidth(_ view: NSView, in stack: NSStackView) -> NSLayoutConstraint {
        let insetWidth = stack.edgeInsets.left + stack.edgeInsets.right
        let constraint = view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -insetWidth)
        constraint.isActive = true
        return constraint
    }
}

enum LaunchInput {
    static func mediaURL(from arguments: [String]) -> URL? {
        guard let input = arguments.dropFirst().first(where: { !$0.isEmpty && !$0.hasPrefix("-psn_") }) else { return nil }
        if let url = URL(string: input), url.scheme != nil {
            guard url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: input).standardizedFileURL
    }
}

enum MediaKind: Equatable { case video, audio, image, unsupported }

private extension MediaKind {
    var provisionalMetadataType: String {
        switch self {
        case .video: return "VIDEO"
        case .audio: return "AUDIO"
        case .image: return "IMAGE"
        case .unsupported: return "MEDIA"
        }
    }
}

enum MediaRoute {
    static func kind(for url: URL) -> MediaKind {
        guard url.isFileURL else { return .unsupported }
        let resourceType = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier).flatMap(UTType.init)
        return kind(for: resourceType ?? UTType(filenameExtension: url.pathExtension))
    }

    static func kind(for contentType: UTType?) -> MediaKind {
        guard let contentType else { return .unsupported }
        if contentType.conforms(to: .image) { return .image }
        if contentType.conforms(to: .audio) { return .audio }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) { return .video }
        return .unsupported
    }

    static func preflight(kind: MediaKind, imageIsDecodable: Bool) -> MediaKind? {
        switch kind {
        case .image: return imageIsDecodable ? .image : nil
        case .video: return .video
        case .audio: return .audio
        case .unsupported: return imageIsDecodable ? .image : nil
        }
    }

    static func previewKind(for url: URL) -> MediaKind? {
        preflight(kind: kind(for: url), imageIsDecodable: ImagePreview.canDecode(url: url))
    }
}

enum ShuttleDirection { case reverse, forward }

enum PlaybackMath {
    static let speedOrder: [Float] = [8, 4, 2, 1.5, 1.25, 1, 0.75, 0.5]

    static func jump(time: Double, duration: Double, fraction: Double) -> Double {
        max(0, min(max(0, duration), time + max(0, duration) * fraction))
    }

    static func nextShuttleRate(currentRate: Float, direction: ShuttleDirection) -> Float {
        let directionMultiplier: Float = direction == .forward ? 1 : -1
        let sameDirection = currentRate != 0 && (currentRate > 0) == (direction == .forward)
        let magnitude = sameDirection ? min(abs(currentRate) * 2, 8) : 1
        return directionMultiplier * magnitude
    }
}

enum PlaybackSpaceAction: Equatable {
    case togglePlayback
    case restartFromBeginning
}

/// Keeps the loop default and the special end-of-video Space behavior out of
/// the AVPlayer/UI layer, where both decisions are straightforward to test.
enum PlaybackLoopPolicy {
    static func defaultLoopEnabled(for mediaKind: MediaKind) -> Bool {
        mediaKind == .video
    }

    static func spaceAction(mediaKind: MediaKind, loopEnabled: Bool, playerRate: Float, currentTime: Double, duration: Double) -> PlaybackSpaceAction {
        guard mediaKind == .video,
              !loopEnabled,
              playerRate == 0,
              isAtRealEnd(currentTime: currentTime, duration: duration) else {
            return .togglePlayback
        }
        return .restartFromBeginning
    }

    private static func isAtRealEnd(currentTime: Double, duration: Double) -> Bool {
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return false }
        // AVPlayer may report the last video time one 600-timescale tick
        // before duration. This is still the completed playback position,
        // rather than a normal in-progress pause.
        return currentTime >= duration - 1.0 / Double(ABLoopExactSeekRequest.preferredTimescale)
    }
}

enum ImageNewSaveDestinationDecision: Equatable {
    case allowed
    case wouldOverwriteSource
    case destinationAlreadyExists
}

enum ImageSavePlan {
    static func suggestedSiblingURL(for sourceURL: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let source = sourceURL.standardizedFileURL
        let directory = source.deletingLastPathComponent()
        let baseName = source.deletingPathExtension().lastPathComponent
        let fileExtension = source.pathExtension
        var suffix = 1

        while true {
            var candidate = directory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: false)
            if !fileExtension.isEmpty { candidate.appendPathExtension(fileExtension) }
            if candidate.standardizedFileURL != source && !fileExists(candidate) { return candidate }
            suffix += 1
        }
    }

    static func newSaveDecision(sourceURL: URL, destinationURL: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> ImageNewSaveDestinationDecision {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        if destination == source { return .wouldOverwriteSource }
        return fileExists(destination) ? .destinationAlreadyExists : .allowed
    }
}

/// The image workflow uses the same display-space crop convention as video:
/// rotate/mirror first, then interpret the crop on that transformed canvas.
struct ImageExportPlan: Equatable {
    let displayTransform: VideoDisplayTransform
    let crop: VideoCropSelection?

    func canvasSize(for sourceSize: CGSize) -> CGSize {
        displayTransform.outputSize(for: sourceSize)
    }

    func cropRect(for sourceSize: CGSize) -> CGRect? {
        let canvasSize = canvasSize(for: sourceSize)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: canvasSize)
        guard let crop else { return bounds }
        let rect = crop.sourceRect.integral
        guard rect.width > 0, rect.height > 0, bounds.contains(rect) else { return nil }
        return rect
    }
}

enum ImageSaveError: LocalizedError {
    case sourceUnavailable
    case unsupportedFormat(String)
    case invalidCrop
    case newSaveWouldOverwriteSource
    case newSaveDestinationExists
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "无法读取原始图片，未写入任何文件。"
        case .unsupportedFormat(let type):
            return "此图片格式（\(type)）无法由 macOS 原生编码保存；原图未修改。"
        case .invalidCrop:
            return "裁切范围无效，未写入任何文件。"
        case .newSaveWouldOverwriteSource:
            return "另存为新文件不能覆盖原图；请使用“覆盖保存”确认替换原图。"
        case .newSaveDestinationExists:
            return "另存为目标已存在；请使用新的文件名，原图和现有文件均未修改。"
        case .writeFailed(let message):
            return "图片保存失败，原图未修改。\n\(message)"
        }
    }
}

enum ImageRasterExporter {
    static func renderedImage(source: CGImage, plan: ImageExportPlan) throws -> CGImage {
        let sourceSize = CGSize(width: source.width, height: source.height)
        guard let cropRect = plan.cropRect(for: sourceSize) else { throw ImageSaveError.invalidCrop }
        let sourceImage = NSImage(cgImage: source, size: sourceSize)
        let transformed = plan.displayTransform.transformedPreviewImage(sourceImage)
        guard let transformedImage = transformed.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = transformedImage.cropping(to: cropRect) else {
            throw ImageSaveError.invalidCrop
        }
        return cropped
    }

    static func write(_ image: CGImage, typeIdentifier: CFString, properties: [CFString: Any]?, to destination: URL) throws {
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as? [CFString] ?? []
        guard writableTypes.contains(where: { CFEqual($0, typeIdentifier) }) else {
            throw ImageSaveError.unsupportedFormat(typeIdentifier as String)
        }
        guard let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL, typeIdentifier, 1, nil) else {
            throw ImageSaveError.writeFailed("无法创建目标文件。")
        }
        var outputProperties = properties ?? [:]
        // The pixels above are already baked to the displayed orientation.
        outputProperties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(imageDestination, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ImageSaveError.writeFailed("macOS 未能完成图片编码。")
        }
    }
}

enum ImageJPEGSaveKind: Equatable {
    case conversion
    case compression

    var filenameTag: String {
        switch self {
        case .conversion: return "JPG"
        case .compression: return "压缩"
        }
    }
}

/// The entered unit is deliberately decimal MB, not MiB. `safeCapBytes` is
/// the hard exclusive ceiling checked before any temporary output is written.
struct ImageJPEGCompressionTarget: Equatable {
    static let decimalMegabyteBytes = 1_000_000
    static let minimumSafetyMarginBytes = 16 * 1024
    static let safetyFraction = 0.015

    let requestedBytes: Int
    let safetyMarginBytes: Int
    let safeCapBytes: Int

    init?(decimalMegabytes: Double) {
        let requested = decimalMegabytes * Double(Self.decimalMegabyteBytes)
        guard decimalMegabytes.isFinite,
              decimalMegabytes > 0,
              requested.isFinite,
              requested >= 1,
              requested <= Double(Int.max) else { return nil }
        requestedBytes = Int(requested.rounded(.down))
        let preferredMargin = max(
            Int((Double(requestedBytes) * Self.safetyFraction).rounded(.up)),
            Self.minimumSafetyMarginBytes
        )
        // Tiny but valid requested caps cannot retain the complete preferred
        // margin. Preserve at least one byte of exclusive-cap headroom so the
        // compressor can deterministically reject impossible requests.
        safetyMarginBytes = min(preferredMargin, max(0, requestedBytes - 1))
        safeCapBytes = requestedBytes - safetyMarginBytes
    }

    var exactTargetDescription: String {
        "实际 JPEG 必须严格小于 \(safeCapBytes) bytes（输入上限 \(requestedBytes) bytes；安全余量 \(safetyMarginBytes) bytes；1 MB = 1,000,000 bytes）。"
    }
}

enum ImageJPEGExportError: LocalizedError {
    case sourceUnavailable
    case invalidCompressionCap
    case impossibleCompressionCap
    case unsupportedJPEG
    case encodingFailed
    case invalidDestinationExtension
    case newSaveWouldOverwriteSource
    case newSaveDestinationExists
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "无法读取原始图片，未写入任何文件。"
        case .invalidCompressionCap:
            return "请输入正的 MB 上限（1 MB = 1,000,000 bytes）；未写入任何文件。"
        case .impossibleCompressionCap:
            return "该大小上限即使在最小 JPEG 质量和最小尺寸下也无法满足；原图和目标文件均未修改。"
        case .unsupportedJPEG:
            return "此 macOS 环境不能编码 JPEG；未写入任何文件。"
        case .encodingFailed:
            return "JPEG 编码失败；未写入任何文件。"
        case .invalidDestinationExtension:
            return "请使用 .jpg 或 .jpeg 文件名；原图和现有文件均未修改。"
        case .newSaveWouldOverwriteSource:
            return "转换和压缩只能创建新 JPEG，不能覆盖原图。"
        case .newSaveDestinationExists:
            return "目标文件已存在；转换和压缩不会覆盖它。"
        case .writeFailed(let message):
            return "JPEG 保存失败，原图未修改。\n\(message)"
        }
    }
}

enum ImageJPEGSavePlan {
    static func suggestedSiblingURL(
        for sourceURL: URL,
        kind: ImageJPEGSaveKind,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let source = sourceURL.standardizedFileURL
        let directory = source.deletingLastPathComponent()
        let baseName = source.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            let candidate = directory
                .appendingPathComponent("\(baseName)-\(kind.filenameTag)-\(suffix)", isDirectory: false)
                .appendingPathExtension("jpg")
            if candidate.standardizedFileURL != source && !fileExists(candidate) { return candidate }
            suffix += 1
        }
    }

    static func newSaveDecision(
        sourceURL: URL,
        destinationURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> ImageNewSaveDestinationDecision {
        ImageSavePlan.newSaveDecision(sourceURL: sourceURL, destinationURL: destinationURL, fileExists: fileExists)
    }
}

enum ImageJPEGExporter {
    static let conversionQuality: CGFloat = 0.95
    private static let minimumCompressionQuality: CGFloat = 0.0
    private static let maximumCompressionQuality: CGFloat = 1.0
    private static let qualityUnitsPerOne = 1_000
    private static let downscaleFactor: CGFloat = 0.85

    static func conversionData(from image: CGImage) throws -> Data {
        try jpegData(from: image, quality: conversionQuality)
    }

    /// Finds the highest tested JPEG quality that satisfies the exclusive cap
    /// at the current resolution. Only when no quality can fit do we shrink the
    /// full transformed raster and try again.
    static func compressedData(from image: CGImage, target: ImageJPEGCompressionTarget) throws -> Data {
        var candidate = image
        while true {
            if let data = try highestQualityData(from: candidate, below: target.safeCapBytes) {
                return data
            }
            guard let smaller = try downscaledImage(from: candidate) else {
                throw ImageJPEGExportError.impossibleCompressionCap
            }
            candidate = smaller
        }
    }

    static func jpegData(from image: CGImage, quality: CGFloat) throws -> Data {
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as? [CFString] ?? []
        guard writableTypes.contains(where: { CFEqual($0, UTType.jpeg.identifier as CFString) }) else {
            throw ImageJPEGExportError.unsupportedJPEG
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageJPEGExportError.encodingFailed
        }
        // Do not pass source properties: compressed output intentionally has no
        // metadata, including EXIF orientation. Its pixels are already baked.
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw ImageJPEGExportError.encodingFailed }
        return data as Data
    }

    private static func highestQualityData(from image: CGImage, below safeCap: Int) throws -> Data? {
        guard safeCap > 0 else { return nil }
        let maximumData = try jpegData(from: image, quality: maximumCompressionQuality)
        if maximumData.count < safeCap { return maximumData }

        let minimumData = try jpegData(from: image, quality: minimumCompressionQuality)
        guard minimumData.count < safeCap else { return nil }

        var lowerQuality = Int(minimumCompressionQuality * CGFloat(qualityUnitsPerOne))
        var upperQuality = Int(maximumCompressionQuality * CGFloat(qualityUnitsPerOne))
        var bestData = minimumData
        // ImageIO's lossy-quality input is quantized for JPEG. Search the full
        // 0.001 quality grid, so `bestData` is the highest supported grid value
        // that is strictly below the target rather than merely a low-quality
        // first success.
        while lowerQuality + 1 < upperQuality {
            let quality = (lowerQuality + upperQuality) / 2
            let data = try jpegData(from: image, quality: CGFloat(quality) / CGFloat(qualityUnitsPerOne))
            if data.count < safeCap {
                lowerQuality = quality
                bestData = data
            } else {
                upperQuality = quality
            }
        }
        return bestData
    }

    private static func downscaledImage(from image: CGImage) throws -> CGImage? {
        let currentSize = CGSize(width: image.width, height: image.height)
        guard currentSize.width > 1 || currentSize.height > 1 else { return nil }
        var width = image.width > 1 ? max(1, Int((CGFloat(image.width) * downscaleFactor).rounded(.down))) : 1
        var height = image.height > 1 ? max(1, Int((CGFloat(image.height) * downscaleFactor).rounded(.down))) : 1
        if width == image.width, height == image.height {
            if width >= height { width = max(1, width - 1) }
            else { height = max(1, height - 1) }
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw ImageJPEGExportError.encodingFailed }
        context.interpolationQuality = .high
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ImageJPEGExportError.encodingFailed }
        return scaled
    }
}

enum VideoFrameScreenshotError: LocalizedError {
    case frameUnavailable
    case invalidEncodedJPEG
    case cancelled
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .frameUnavailable:
            return "无法读取当前视频帧，未写入任何文件。"
        case .invalidEncodedJPEG:
            return "截图 JPEG 校验失败，未写入任何文件。"
        case .cancelled:
            return "截图已取消，未写入任何文件。"
        case .writeFailed(let message):
            return "截图保存失败，原视频和现有文件均未修改。\n\(message)"
        }
    }
}

/// The video screenshot uses a direct AVFoundation frame, never the player
/// view. The track's preferred transform is applied by the generator first;
/// this helper then bakes only the user's rotate/mirror display state.
enum VideoFrameScreenshotExporter {
    static func jpegData(from frame: CGImage, displayTransform: VideoDisplayTransform) throws -> Data {
        let rendered = try ImageRasterExporter.renderedImage(
            source: frame,
            plan: ImageExportPlan(displayTransform: displayTransform, crop: nil)
        )
        let data = try ImageJPEGExporter.conversionData(from: rendered)
        try validateJPEG(data, expectedWidth: rendered.width, expectedHeight: rendered.height)
        return data
    }

    static func validateJPEG(_ data: Data, expectedWidth: Int, expectedHeight: Int) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == expectedWidth,
              image.height == expectedHeight else {
            throw VideoFrameScreenshotError.invalidEncodedJPEG
        }
    }
}

/// The final rename is serialized with teardown invalidation. Encoding and the
/// temporary write remain off-main, while a closed preview cannot commit a
/// stale callback's file beside the source video.
final class VideoFrameScreenshotCommitToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func performIfActive<T>(_ operation: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return try operation()
    }
}

enum VideoFrameScreenshotSavePlan {
    static func candidateURL(for sourceURL: URL, number: Int) -> URL {
        let source = sourceURL.standardizedFileURL
        let filename = "\(source.deletingPathExtension().lastPathComponent)-截图-\(String(format: "%03d", number)).jpg"
        return source.deletingLastPathComponent().appendingPathComponent(filename, isDirectory: false)
    }

    static func suggestedSiblingURL(
        for sourceURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        var number = 1
        while true {
            let candidate = candidateURL(for: sourceURL, number: number).standardizedFileURL
            if candidate != sourceURL.standardizedFileURL, !fileExists(candidate) { return candidate }
            number += 1
        }
    }

    /// Writes to a same-directory temporary file and uses a non-replacing move
    /// for the final name. If another process occupies a candidate after the
    /// initial check, it advances to the next suffix instead of overwriting it.
    static func commitJPEGData(
        _ data: Data,
        beside sourceURL: URL,
        fileManager: FileManager = .default,
        authorizeFinalMove: ((() throws -> URL) throws -> URL?)? = nil
    ) throws -> URL {
        let source = sourceURL.standardizedFileURL
        var number = 1

        while true {
            let candidate = candidateURL(for: source, number: number).standardizedFileURL
            guard candidate != source else {
                throw VideoFrameScreenshotError.writeFailed("截图目标不能覆盖原视频。")
            }
            guard !fileManager.fileExists(atPath: candidate.path) else {
                number += 1
                continue
            }

            let temporaryURL = candidate.deletingLastPathComponent().appendingPathComponent(".MediaPreview-Screenshot-\(UUID().uuidString).jpg", isDirectory: false)
            do {
                try data.write(to: temporaryURL, options: .atomic)
                let move: () throws -> URL = {
                    try fileManager.moveItem(at: temporaryURL, to: candidate)
                    return candidate
                }
                let committed: URL?
                if let authorizeFinalMove {
                    committed = try authorizeFinalMove(move)
                } else {
                    committed = try move()
                }
                guard let committed else {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw VideoFrameScreenshotError.cancelled
                }
                return committed
            } catch let error as VideoFrameScreenshotError {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                if fileManager.fileExists(atPath: candidate.path) {
                    number += 1
                    continue
                }
                throw VideoFrameScreenshotError.writeFailed(error.localizedDescription)
            }
        }
    }
}

struct VideoFrameScreenshotCaptureGate: Equatable {
    private(set) var isPending = false

    mutating func begin() -> Bool {
        guard !isPending else { return false }
        isPending = true
        return true
    }

    mutating func finish() { isPending = false }
}

struct ABLoopExactSeekRequest: Equatable {
    static let preferredTimescale: CMTimeScale = 600

    let id = UUID()
    let targetSeconds: Double
    let resumeRate: Float

    var targetTime: CMTime {
        CMTime(seconds: targetSeconds, preferredTimescale: Self.preferredTimescale)
    }

    var tolerance: CMTime { .zero }
}

enum ABLoopExactSeekCommand: Equatable {
    case pauseAndSeek(ABLoopExactSeekRequest)
    case resume(Float)
}

/// Keeps A/B edits ordered. Once both markers exist, I and O can only expand
/// outward or shrink inward according to the playhead's position; they never
/// swap the endpoints or collapse the range.
struct ABMarkerState: Equatable {
    private(set) var pointA: Double?
    private(set) var pointB: Double?

    mutating func setA(at time: Double) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        guard let pointB else {
            pointA = time
            return true
        }
        guard let pointA else {
            guard time < pointB else { return false }
            self.pointA = time
            return true
        }
        guard time < pointA || (time > pointA && time < pointB) else { return false }
        self.pointA = time
        return true
    }

    mutating func setB(at time: Double) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        guard let pointA else {
            pointB = time
            return true
        }
        guard let pointB else {
            guard time > pointA else { return false }
            self.pointB = time
            return true
        }
        guard (time > pointA && time < pointB) || time > pointB else { return false }
        self.pointB = time
        return true
    }

    mutating func clear() {
        pointA = nil
        pointB = nil
    }

    func renderState(duration: Double) -> ABMarkerRenderState {
        guard duration.isFinite, duration > 0 else { return ABMarkerRenderState(a: nil, b: nil) }
        return ABMarkerRenderState(
            a: pointA.map { max(0, min(1, $0 / duration)) },
            b: pointB.map { max(0, min(1, $0 / duration)) }
        )
    }
}

/// Pure A/B export decisions kept separate from the save panel and AVFoundation
/// work so the range and suggested file name remain easy to test.
enum ABTrimExportPlan {
    static func timeRange(a: Double?, b: Double?, duration: Double) -> CMTimeRange? {
        guard let a, let b,
              a.isFinite, b.isFinite, duration.isFinite,
              duration > 0, a >= 0, b > a, b <= duration else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: a, preferredTimescale: 600),
            duration: CMTime(seconds: b - a, preferredTimescale: 600)
        )
    }

    static func suggestedFilename(for sourceURL: URL, fileExtension: String) -> String {
        "\(sourceURL.deletingPathExtension().lastPathComponent)-AB剪辑.\(fileExtension)"
    }

    static func suggestedOutputURL(for sourceURL: URL, fileExtension: String) -> URL {
        sourceURL.deletingLastPathComponent().appendingPathComponent(suggestedFilename(for: sourceURL, fileExtension: fileExtension))
    }
}

/// Audio export intentionally remuxes one existing audio stream rather than
/// decoding it. Keeping the source container extension gives FFmpeg the best
/// chance of retaining the original codec packet payload unchanged. A/B ranges
/// are consequently packet-aligned: compressed audio cannot generally be cut
/// at an arbitrary timeline sample while stream-copying.
struct FFmpegAudioExportPlan: Equatable {
    let fileExtension: String
    let timeRange: CMTimeRange?

    static func make(sourceURL: URL, timeRange: CMTimeRange?) -> FFmpegAudioExportPlan {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        // These common source containers normally hold audio that is legal in
        // M4A. Matroska Audio is the broad fallback. FFmpeg remains the final
        // authority: a mux failure is reported, never "fixed" by transcoding.
        let extensionToUse: String
        switch sourceExtension {
        case "m4a", "aac", "mp4", "m4v", "mov": extensionToUse = "m4a"
        case "mp3": extensionToUse = "mp3"
        case "wav", "wave": extensionToUse = "wav"
        default: extensionToUse = "mka"
        }
        return FFmpegAudioExportPlan(fileExtension: extensionToUse, timeRange: timeRange)
    }

    var isABExport: Bool { timeRange != nil }

    var savePanelMessage: String {
        if isABExport {
            return "保留原始音频码流、声道布局和采样率。A/B 无损导出按编码包边界切割，起止点可能与时间线相差极短一段；不会重编码。"
        }
        return "保留原始音频码流、声道布局和采样率；不会重编码。"
    }

    func suggestedFilename(for sourceURL: URL) -> String {
        let suffix = isABExport ? "-AB音频" : "-音频"
        return "\(sourceURL.deletingPathExtension().lastPathComponent)\(suffix).\(fileExtension)"
    }

    func arguments(sourceURL: URL, destinationURL: URL) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-progress", "pipe:1", "-nostats", "-loglevel", "error", "-i", sourceURL.path]
        if let timeRange {
            arguments += ["-ss", Self.timestamp(timeRange.start.seconds), "-t", Self.timestamp(timeRange.duration.seconds)]
        }
        arguments += ["-map", "0:a:0?", "-vn", "-map_metadata", "0", "-c:a", "copy", "-n", destinationURL.path]
        return arguments
    }

    private static func timestamp(_ seconds: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}

enum ABTrimExportError: LocalizedError {
    case noTracks
    case noAudioTrack
    case ffmpegUnavailable
    case destinationAlreadyExists
    case wouldOverwriteSource
    case ffmpegFailed(String)
    case audioStreamCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTracks: return "未找到可导出的音频或视频轨道。"
        case .noAudioTrack: return "未找到可导出的音频轨道。"
        case .ffmpegUnavailable: return "未找到可用的 FFmpeg。请按“使用说明”运行“一键安装 FFmpeg.command”，完成后重新打开此窗口再导出。"
        case .destinationAlreadyExists: return "目标文件已存在；请使用其他文件名。"
        case .wouldOverwriteSource: return "不能覆盖正在预览的原始文件。"
        case .ffmpegFailed(let details): return details.isEmpty ? "FFmpeg 裁切导出失败。" : "FFmpeg 裁切导出失败：\(details)"
        case .audioStreamCopyFailed(let details):
            let detail = details.isEmpty ? "目标容器可能不支持原始音频编码。" : details
            return "无法无损导出原始音频码流：\(detail) 未进行重编码或降质，请改用其他文件名/扩展名后重试。"
        }
    }
}

/// Finds optional external media tools without using a shell. The app never
/// bundles a binary. Its current user-managed installer directory wins; the
/// prior Finder Media Preview directory remains a migration fallback before
/// standard locations and PATH, so both FFmpeg and FFprobe resolve as a pair.
enum ExternalMediaToolLocator {
    static func candidateURLs(named executableName: String, environment: [String: String]) -> [URL] {
        let homeDirectory = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let applicationSupportDirectory = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let userManagedDirectory = applicationSupportDirectory
            .appendingPathComponent("AI Video Cutty/bin", isDirectory: true)
        let legacyUserManagedDirectory = applicationSupportDirectory
            .appendingPathComponent("Finder Media Preview/bin", isDirectory: true)
        let standardPaths = [
            userManagedDirectory.appendingPathComponent(executableName).path,
            legacyUserManagedDirectory.appendingPathComponent(executableName).path,
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "/usr/bin/\(executableName)"
        ]
        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init).filter { !$0.isEmpty } ?? []
        let urls = standardPaths.map(URL.init(fileURLWithPath:)) + pathEntries.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executableName) }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func executableURL(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        candidateURLs(named: executableName, environment: environment).first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

enum FFmpegLocator {
    static func candidateURLs(environment: [String: String]) -> [URL] {
        ExternalMediaToolLocator.candidateURLs(named: "ffmpeg", environment: environment)
    }

    static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL? {
        ExternalMediaToolLocator.executableURL(named: "ffmpeg", environment: environment, fileManager: fileManager)
    }
}

/// Each plan keeps the requested time range exact by placing `-ss` after the
/// input and re-encoding. Video quality is H.264 CRF 18 plus AAC 192 kb/s;
/// audio is encoded in its standard output format (AAC 256 kb/s, MP3 VBR q2,
/// or 16-bit PCM WAV). This is intentionally not a byte-for-byte lossless path.
struct FFmpegTrimExportPlan: Equatable {
    enum Kind: Equatable { case video, audio }

    let kind: Kind
    let fileExtension: String

    static func make(sourceURL: URL, mediaKind: MediaKind) -> FFmpegTrimExportPlan? {
        switch mediaKind {
        case .video:
            let sourceExtension = sourceURL.pathExtension.lowercased()
            let extensionToUse = ["mp4", "mov", "m4v", "mkv"].contains(sourceExtension) ? sourceExtension : "mp4"
            return FFmpegTrimExportPlan(kind: .video, fileExtension: extensionToUse)
        case .audio:
            let sourceExtension = sourceURL.pathExtension.lowercased()
            let extensionToUse = ["m4a", "mp3", "wav"].contains(sourceExtension) ? sourceExtension : "m4a"
            return FFmpegTrimExportPlan(kind: .audio, fileExtension: extensionToUse)
        case .image, .unsupported:
            return nil
        }
    }

    var savePanelMessage: String {
        switch kind {
        case .video:
            return "精确 A/B 帧裁切：FFmpeg 将视频以 H.264（CRF 18）和音频 AAC（192 kb/s）高质量重编码；不是原码流无损直拷贝。"
        case .audio:
            switch fileExtension {
            case "mp3": return "精确 A/B 音频裁切：导出为 MP3 VBR q2；不是原始码流直拷贝。"
            case "wav": return "精确 A/B 音频裁切：导出为 16-bit PCM WAV；不是原始码流直拷贝。"
            default: return "精确 A/B 音频裁切：导出为 AAC 256 kb/s M4A；不是原始码流直拷贝。"
            }
        }
    }

    func arguments(sourceURL: URL, destinationURL: URL, timeRange: CMTimeRange, crop: VideoCropSelection? = nil, displayTransform: VideoDisplayTransform = VideoDisplayTransform()) -> [String] {
        let start = Self.timestamp(timeRange.start.seconds)
        let duration = Self.timestamp(timeRange.duration.seconds)
        let activeCrop = kind == .video ? crop : nil
        let activeTransform = kind == .video ? displayTransform : VideoDisplayTransform()
        let videoFilters = activeTransform.ffmpegFilterComponents + (activeCrop.map { [$0.ffmpegFilter] } ?? [])
        var arguments = ["-hide_banner", "-nostdin", "-progress", "pipe:1", "-nostats", "-loglevel", "error"]
        arguments += ["-i", sourceURL.path, "-ss", start, "-t", duration]
        switch kind {
        case .video:
            arguments += ["-map", "0:v:0?", "-map", "0:a?", "-map_metadata", "0"]
            // FFmpeg's default autorotation first normalizes ordinary source
            // metadata. User rotation/mirror then runs before crop, matching
            // the preferred-transform crop-editor preview. Clear the output
            // rotation tag whenever a real filter has baked the pixels.
            if !videoFilters.isEmpty {
                arguments += ["-vf", videoFilters.joined(separator: ","), "-metadata:s:v:0", "rotate=0"]
            }
            arguments += ["-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            if ["mp4", "m4v", "mov"].contains(fileExtension) { arguments += ["-movflags", "+faststart"] }
        case .audio:
            arguments += ["-map", "0:a:0?", "-vn", "-map_metadata", "0"]
            switch fileExtension {
            case "mp3": arguments += ["-c:a", "libmp3lame", "-q:a", "2"]
            case "wav": arguments += ["-c:a", "pcm_s16le"]
            default: arguments += ["-c:a", "aac", "-b:a", "256k"]
            }
        }
        return arguments + ["-n", destinationURL.path]
    }

    private static func timestamp(_ seconds: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}

/// Buffers FFmpeg's line-oriented progress protocol. Pipes are allowed to
/// split a line anywhere, so each chunk is retained until a newline arrives.
struct FFmpegProgressParser {
    private var pending = ""

    mutating func consume(_ data: Data, totalSeconds: Double) -> [Double] {
        guard totalSeconds.isFinite, totalSeconds > 0, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return [] }
        pending += chunk
        var values: [Double] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == "out_time_us", let microseconds = Double(pair[1]) else { continue }
            // `progress=end` can be emitted before a successful process exit;
            // leave the UI below 100% until termination confirms success.
            values.append(min(0.999, max(0, microseconds / (totalSeconds * 1_000_000))))
        }
        return values
    }
}

enum FFmpegAvailability {
    static func verify(executableURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["-version"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { completed in
                continuation.resume(returning: completed.terminationReason == .exit && completed.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}

enum VideoExportStatusPresentation {
    static let cancelled = "已取消导出"

    static func completed(destination: URL) -> String {
        let filename = destination.lastPathComponent
        return filename.isEmpty ? "已完成" : "已完成 · \(filename)"
    }
}

/// Keeps FFmpeg's asynchronous pipes off the UI thread and reports machine-
/// readable `-progress pipe:1` output. No command string or shell is involved.
final class FFmpegTrimProcess: @unchecked Sendable {
    private let process = Process()
    private let progressPipe = Pipe()
    private let errorPipe = Pipe()
    private var stderr = Data()
    private let lock = NSLock()
    private var progressParser = FFmpegProgressParser()
    private let totalSeconds: Double
    private let onProgress: @MainActor (Double) -> Void
    private let onCompletion: @MainActor (Result<Void, ABTrimExportError>) -> Void

    init(executableURL: URL, arguments: [String], totalSeconds: Double, onProgress: @escaping @MainActor (Double) -> Void, onCompletion: @escaping @MainActor (Result<Void, ABTrimExportError>) -> Void) {
        self.totalSeconds = totalSeconds
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = progressPipe
        process.standardError = errorPipe
    }

    func start() throws {
        progressPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.consumeProgress(handle.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.consumeError(handle.availableData) }
        process.terminationHandler = { [weak self] completed in self?.finish(completed) }
        try process.run()
    }

    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func consumeProgress(_ data: Data) {
        lock.lock()
        let values = progressParser.consume(data, totalSeconds: totalSeconds)
        lock.unlock()
        for progress in values { Task { @MainActor [onProgress] in onProgress(progress) } }
    }

    private func consumeError(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stderr.append(data)
        // Keep enough diagnostic text for the alert without allowing a broken
        // encoder to grow memory indefinitely.
        if stderr.count > 32_768 { stderr.removeFirst(stderr.count - 32_768) }
    }

    private func finish(_ completed: Process) {
        progressPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let result: Result<Void, ABTrimExportError>
        if completed.terminationReason == .exit && completed.terminationStatus == 0 {
            result = .success(())
        } else {
            lock.lock(); let message = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; lock.unlock()
            result = .failure(.ffmpegFailed(message))
        }
        Task { @MainActor [onCompletion] in onCompletion(result) }
    }
}

/// Serializes loop seeks so a periodic observer cannot start a second seek
/// before the first exact seek has reached its completion callback.
struct ABLoopExactSeekCoordinator {
    private var pendingRequest: ABLoopExactSeekRequest?

    var isSeeking: Bool { pendingRequest != nil }

    mutating func begin(targetSeconds: Double, resumeRate: Float) -> ABLoopExactSeekCommand? {
        guard pendingRequest == nil else { return nil }
        let request = ABLoopExactSeekRequest(targetSeconds: targetSeconds, resumeRate: resumeRate)
        pendingRequest = request
        return .pauseAndSeek(request)
    }

    mutating func finish(_ request: ABLoopExactSeekRequest, completed: Bool) -> ABLoopExactSeekCommand? {
        guard pendingRequest?.id == request.id else { return nil }
        pendingRequest = nil
        guard completed, request.resumeRate != 0 else { return nil }
        return .resume(request.resumeRate)
    }

    /// Returns whether there was an A/B seek to cancel. Keeping this separate
    /// from ordinary player seeks avoids cancelling a just-issued jump or
    /// hover seek when no A/B loop operation is in flight.
    @discardableResult
    mutating func cancel() -> Bool {
        guard pendingRequest != nil else { return false }
        pendingRequest = nil
        return true
    }
}

enum UsageManualLocator {
    static let markdownName = "使用说明.md"
    static let pdfName = "使用说明.pdf"

    static func manualURL(
        bundleURL: URL = Bundle.main.bundleURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let siblingDirectory = bundleURL.deletingLastPathComponent()
        let localDocs = workingDirectory.appendingPathComponent("Docs", isDirectory: true)
        let candidates = [
            resources.appendingPathComponent(pdfName),
            siblingDirectory.appendingPathComponent(pdfName),
            localDocs.appendingPathComponent(pdfName),
            resources.appendingPathComponent(markdownName),
            siblingDirectory.appendingPathComponent(markdownName),
            localDocs.appendingPathComponent(markdownName)
        ]
        return candidates.first(where: exists)
    }
}

/// Locates the user-visible installation script. It is opened only after the
/// user presses the install action; the app never runs installers by itself.
enum FFmpegInstallScriptLocator {
    static let filename = "安装 FFmpeg.command"

    static func scriptURL(
        bundleURL: URL = Bundle.main.bundleURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let siblingDirectory = bundleURL.deletingLastPathComponent()
        let scripts = workingDirectory.appendingPathComponent("Scripts", isDirectory: true)
        return [resources.appendingPathComponent(filename), siblingDirectory.appendingPathComponent(filename), scripts.appendingPathComponent(filename)].first(where: exists)
    }
}

enum PreviewKeyRouting {
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PreviewKeyCommand? {
        let shortcut = PreviewShortcut(keyCode: keyCode, modifiers: modifiers)
        // Plain arrows are dedicated transport controls. Command-arrow stays
        // available to the configurable shortcut store for fixed percentage
        // jumps, while the hardware-added Fn flag remains normalized away.
        guard !PreviewArrowRouting.isPlainArrow(shortcut) else { return nil }
        return ShortcutStore.shared.command(for: shortcut)?.keyCommand
    }
}

enum PreviewArrowAction: Equatable {
    case stepFrame(Int)
    case startShuttle(ShuttleDirection)
    case restoreForwardPlayback
    case adjustVolume(Float)
}

/// Keeps plain-arrow behavior independent from customizable shortcuts. The
/// controller owns the actual AVPlayer calls and the rate to restore.
enum PreviewArrowRouting {
    static let shuttleRate: Float = 1.5
    static let volumeIncrement: Float = 0.10

    static func isPlainArrow(_ shortcut: PreviewShortcut) -> Bool {
        shortcut.modifiers.isEmpty && [UInt16(123), 124, 125, 126].contains(shortcut.keyCode)
    }

    static func keyDownAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, playerRate: Float) -> PreviewArrowAction? {
        let shortcut = PreviewShortcut(keyCode: keyCode, modifiers: modifiers)
        guard isPlainArrow(shortcut) else { return nil }
        switch keyCode {
        case 123:
            return playerRate == 0 ? .stepFrame(-1) : .startShuttle(.reverse)
        case 124:
            return playerRate == 0 ? .stepFrame(1) : .startShuttle(.forward)
        case 125:
            return .adjustVolume(-volumeIncrement)
        case 126:
            return .adjustVolume(volumeIncrement)
        default:
            return nil
        }
    }

    static func keyUpAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PreviewArrowAction? {
        let shortcut = PreviewShortcut(keyCode: keyCode, modifiers: modifiers)
        guard isPlainArrow(shortcut), keyCode == 123 || keyCode == 124 else { return nil }
        return .restoreForwardPlayback
    }

    static func adjustedVolume(current: Float, by delta: Float) -> Float {
        Float(VolumeControlMath.clamped(CGFloat(current + delta)))
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePlayback, close, jumpBack, jumpForward, shuttleReverse, pause, shuttleForward, setA, setB, restart, toggleLoop, clearAB, mute, zoomReset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .togglePlayback: return "播放 / 暂停"
        case .close: return "关闭预览"
        case .jumpBack: return "后退 5%（⌘←）"
        case .jumpForward: return "前进 5%（⌘→）"
        case .shuttleReverse: return "J 倒放"
        case .pause: return "K 暂停"
        case .shuttleForward: return "L 快进"
        case .setA: return "设置 A"
        case .setB: return "设置 B"
        case .restart: return "重新开始"
        case .toggleLoop: return "循环"
        case .clearAB: return "清除 A-B"
        case .mute: return "静音"
        case .zoomReset: return "重置缩放"
        }
    }
    var keyCommand: PreviewKeyCommand {
        switch self {
        case .togglePlayback: return .togglePlayback; case .close: return .close
        case .jumpBack: return .jump(-0.05); case .jumpForward: return .jump(0.05)
        case .shuttleReverse: return .shuttle(.reverse); case .pause: return .pause; case .shuttleForward: return .shuttle(.forward)
        case .setA: return .setA; case .setB: return .setB; case .restart: return .restart
        case .toggleLoop: return .toggleLoop; case .clearAB: return .clearAB; case .mute: return .mute; case .zoomReset: return .zoomReset
        }
    }
}

enum PreviewKeyCommand: Equatable { case togglePlayback, close, jump(Double), shuttle(ShuttleDirection), pause, setA, setB, restart, toggleLoop, clearAB, mute, zoomReset }

struct PreviewShortcut: Codable, Hashable, Sendable {
    let keyCode: UInt16
    let modifierFlags: UInt
    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        // macOS reports the arrow cluster with an implicit `.function` flag.
        // It is hardware-derived rather than a user-selected modifier, so keeping
        // it would make the default left/right shortcuts fail on real keyboards.
        modifierFlags = modifiers.intersection([.shift, .control, .option, .command]).rawValue
    }
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }
    var isFinderSave: Bool { keyCode == 1 && modifiers == [.command] }
    var display: String {
        let marks = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .compactMap { modifiers.contains($0.0) ? $0.1 : nil }.joined()
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
            53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return marks + (names[keyCode] ?? "Key \(keyCode)")
    }
}

final class ShortcutStore: @unchecked Sendable {
    static let storageKey = "PreviewShortcutBindings.v1"
    static let shared = ShortcutStore(defaults: .standard)
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    static let defaultBindings: [ShortcutAction: PreviewShortcut] = [
        .togglePlayback: .init(keyCode: 49, modifiers: []), .close: .init(keyCode: 12, modifiers: [.command]),
        .jumpBack: .init(keyCode: 123, modifiers: [.command]), .jumpForward: .init(keyCode: 124, modifiers: [.command]),
        .shuttleReverse: .init(keyCode: 38, modifiers: []), .pause: .init(keyCode: 40, modifiers: []), .shuttleForward: .init(keyCode: 37, modifiers: []),
        .setA: .init(keyCode: 34, modifiers: []), .setB: .init(keyCode: 31, modifiers: []), .restart: .init(keyCode: 15, modifiers: []),
        .toggleLoop: .init(keyCode: 35, modifiers: []), .clearAB: .init(keyCode: 7, modifiers: []), .mute: .init(keyCode: 46, modifiers: []), .zoomReset: .init(keyCode: 29, modifiers: [])
    ]
    var bindings: [ShortcutAction: PreviewShortcut] {
        guard let data = defaults.data(forKey: Self.storageKey), let decoded = try? JSONDecoder().decode([ShortcutAction: PreviewShortcut].self, from: data) else { return Self.defaultBindings }
        var resolved = Self.defaultBindings.merging(decoded) { _, saved in saved }
        // Older versions serialized complete bindings whenever any shortcut
        // changed, including their former plain-arrow defaults. Those arrows
        // are now reserved for frame step/shuttle, so migrate them to Cmd-arrow
        // while retaining every unrelated user customization.
        if resolved[.jumpBack] == PreviewShortcut(keyCode: 123, modifiers: []) {
            resolved[.jumpBack] = Self.defaultBindings[.jumpBack]
        }
        if resolved[.jumpForward] == PreviewShortcut(keyCode: 124, modifiers: []) {
            resolved[.jumpForward] = Self.defaultBindings[.jumpForward]
        }
        return resolved
    }
    func command(for shortcut: PreviewShortcut) -> ShortcutAction? {
        guard !shortcut.isFinderSave else { return nil }
        return bindings.first { $0.value == shortcut }?.key
    }
    func conflict(for action: ShortcutAction, shortcut: PreviewShortcut) -> ShortcutAction? { bindings.first { $0.key != action && $0.value == shortcut }?.key }
    @discardableResult func set(_ shortcut: PreviewShortcut, for action: ShortcutAction) -> ShortcutAction? {
        guard !shortcut.isFinderSave else { return .close }
        if let conflict = conflict(for: action, shortcut: shortcut) { return conflict }
        var next = bindings; next[action] = shortcut
        defaults.set(try? JSONEncoder().encode(next), forKey: Self.storageKey)
        return nil
    }
    func restoreDefaults() { defaults.removeObject(forKey: Self.storageKey) }
}

@MainActor
final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: ShortcutStore
    private let stack = NSStackView()
    private let message = NSTextField(labelWithString: "选择一个项目后，按下新的快捷键组合。⌘S 保留给 Finder。")
    private var captureAction: ShortcutAction?
    private var eventMonitor: Any?
    private var buttons: [ShortcutAction: NSButton] = [:]

    init(store: ShortcutStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { stopCapture() }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)])
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize: 12); stack.addArrangedSubview(message)
        for action in ShortcutAction.allCases {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.distribution = .fill
            let label = NSTextField(labelWithString: action.title); label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let button = NSButton(title: store.bindings[action]?.display ?? "未设置", target: self, action: #selector(beginCapture(_:)))
            button.tag = ShortcutAction.allCases.firstIndex(of: action) ?? 0; button.widthAnchor.constraint(equalToConstant: 120).isActive = true
            row.addArrangedSubview(label); row.addArrangedSubview(button); stack.addArrangedSubview(row); buttons[action] = button
        }
        let restore = NSButton(title: "恢复默认设置", target: self, action: #selector(restoreDefaults(_:)))
        stack.addArrangedSubview(restore)
    }
    @objc private func beginCapture(_ sender: NSButton) {
        guard let action = ShortcutAction.allCases[safe: sender.tag] else { return }
        stopCapture(); captureAction = action; sender.title = "按下快捷键…"; message.stringValue = "正在设置“\(action.title)”；按 Escape 取消。"
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.captureAction != nil else { return event }
            if event.keyCode == 53 { self.stopCapture(); self.refresh(); return nil }
            self.finishCapture(PreviewShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags))
            return nil
        }
    }
    private func finishCapture(_ shortcut: PreviewShortcut) {
        guard let action = captureAction else { return }
        if shortcut.isFinderSave { message.stringValue = "⌘S 固定保留给 Finder，不能使用。" }
        else if let duplicate = store.set(shortcut, for: action) { message.stringValue = "与“\(duplicate.title)”重复；未保存。" }
        else { message.stringValue = "已设置“\(action.title)”为 \(shortcut.display)。" }
        stopCapture(); refresh()
    }
    @objc private func restoreDefaults(_ sender: Any?) { stopCapture(); store.restoreDefaults(); message.stringValue = "已恢复默认快捷键。"; refresh() }
    private func stopCapture() { if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }; captureAction = nil }
    private func refresh() { for action in ShortcutAction.allCases { buttons[action]?.title = store.bindings[action]?.display ?? "未设置" } }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum ServiceInput {
    static func firstRegularFileURL(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { $0 as? URL } ?? []
        return firstRegularFileURL(from: urls)
    }

    static func firstRegularFileURL(
        from urls: [URL],
        isRegularFile: (URL) -> Bool = ServiceInput.isRegularFile
    ) -> URL? {
        urls.first { $0.isFileURL && isRegularFile($0) }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

@main
enum MediaPreviewMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

final class PreviewPanel: NSWindow {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 2,
           isTitlebarBackgroundClick(at: event.locationInWindow) {
            performZoom(nil)
            return
        }
        super.sendEvent(event)
    }

    private func isTitlebarBackgroundClick(at point: NSPoint) -> Bool {
        let titlebarButtons = [.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { standardWindowButton($0)?.frame }
        guard let titlebarBottom = titlebarButtons.map(\.minY).min(), point.y >= titlebarBottom - 6 else { return false }
        return !titlebarButtons.contains { $0.contains(point) }
    }
}

@MainActor
private final class ImageCompressionSavePanelAccessory: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    let capField = NSTextField(string: "1")
    private let targetLabel = NSTextField(wrappingLabelWithString: "")

    override init() {
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.addArrangedSubview(NSTextField(labelWithString: "大小上限（MB）："))
        capField.alignment = .right
        capField.placeholderString = "例如 1.0"
        capField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        capField.delegate = self
        row.addArrangedSubview(capField)
        row.addArrangedSubview(NSTextField(labelWithString: "MB"))
        targetLabel.maximumNumberOfLines = 3
        targetLabel.preferredMaxLayoutWidth = 340
        targetLabel.textColor = .secondaryLabelColor
        view.addArrangedSubview(row)
        view.addArrangedSubview(targetLabel)
        refreshTargetDescription()
    }

    var target: ImageJPEGCompressionTarget? {
        let raw = capField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(raw).flatMap(ImageJPEGCompressionTarget.init(decimalMegabytes:))
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshTargetDescription()
    }

    private func refreshTargetDescription() {
        targetLabel.stringValue = target?.exactTargetDescription ?? "请输入正的 MB 上限；导出前会重新校验实际 JPEG 字节数。"
    }
}

@MainActor
final class PreviewController: NSViewController {
    private let url: URL; private let mediaKind: MediaKind; private let metadataInspector: MediaMetadataInspector?; private let player = AVPlayer(); private let videoSurface = ZoomablePlayerSurface(); private var playerView: AVPlayerView { videoSurface.playerView }; private let imageSurface = ZoomableImageSurface(); private var imageView: NSImageView { imageSurface.imageView }
    private let metadataStack = NSStackView()
    private let row1 = NSStackView(); private let row2 = NSStackView(); private let mediaRow = NSStackView(); private let leftControlRail = NSStackView(); private let rightControlRail = NSStackView(); private let volumeStack = NSStackView(); private let displayTransformStack = NSStackView(); private let rotateCounterclockwiseButton = NSButton(); private let rotateClockwiseButton = NSButton(); private let mirrorButton = NSButton(); private let videoScreenshotButton = NSButton(); private let imageActionStack = NSStackView(); private let imageCropSaveButton = NSButton(); private let imageJPEGConversionButton = NSButton(); private let imageJPEGCompressionButton = NSButton(); private let speedStack = NSStackView(); private let timeline = TimelineView(); private let timeLabel = NSTextField(labelWithString: ""); private let loopButton = NSButton(); private let trimExportButton = NSButton(); private let audioExportButton = NSButton(); private let trimExportStatus = NSTextField(labelWithString: ""); private let trimExportProgress = NSProgressIndicator(); private let cancelExportButton = NSButton(); private let muteButton = NSButton(); private let volumeControl = VerticalVolumeControl(); private let topActionStack = NSStackView(); private let filenameLabel = NSTextField(wrappingLabelWithString: "")
    private var imageGenerator: AVAssetImageGenerator?; private var cropPreviewGenerator: AVAssetImageGenerator?; private var cropPreviewGenerationID = 0; private var cropPreviewCompletion: ((NSImage?) -> Void)?; private var videoScreenshotGenerator: AVAssetImageGenerator?; private var videoScreenshotGenerationID = 0; private var videoScreenshotCommitToken: VideoFrameScreenshotCommitToken?; private var videoScreenshotCaptureGate = VideoFrameScreenshotCaptureGate(); private var timeObserver: Any?; private var endObserver: NSObjectProtocol?; private var hoverWorkItem: DispatchWorkItem?; private var waveformExtraction: WaveformExtraction?
    private var hoverActive = false; private var hoverRate: Float = 0; private var oldMuted = false; private var chosenForwardRate: Float = 1; private var shuttleRate: Float = 0; private var plainArrowShuttleKeyCode: UInt16?; private var plainArrowRestoreRate: Float?; private var lastAudibleVolume: Float = 1; private var videoDisplayTransform = VideoDisplayTransform(); private var imageDisplayTransform = VideoDisplayTransform()
    private var markers = ABMarkerState(); private var loopEnabled: Bool; private var loopSeekCoordinator = ABLoopExactSeekCoordinator()
    private var speedButtons: [NSButton] = []; private var ffmpegExportProcess: FFmpegTrimProcess?; private var isPreparingExport = false; private var activeExportIsAudio = false; private var isCancellingExport = false; private var cropEditor: CropEditorSheetController?; private var imageCropEditor: CropEditorSheetController?; private var savedVideoCropSelection: VideoCropSelection?; private var savedImageCropSelection: VideoCropSelection?; private var imageSourceCGImage: CGImage?; private var imageSourceType: CFString?; private var imageSourceProperties: [CFString: Any]?
    private var metadataRowHeightConstraints: [NSLayoutConstraint] = []
    private var metadataHeightConstraint: NSLayoutConstraint?
    private var metadataProgression: MetadataProgression
    private var metadataInspectionToken = MetadataInspectionToken()
    private var nativeMetadataTask: Task<Void, Never>?
    private var imageLoadPending = false
    var onShowShortcutSettings: (() -> Void)?

    init(url: URL, mediaKind: MediaKind, metadataInspector: MediaMetadataInspector? = .live) {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = resourceValues?.fileSize.map(Int64.init)
        self.url = url
        self.mediaKind = mediaKind
        self.metadataInspector = metadataInspector
        self.metadataProgression = MetadataProgression(
            provisional: MetadataProgression.provisional(
                fileExtension: url.pathExtension,
                fallbackType: mediaKind.provisionalMetadataType,
                fileSize: fileSize
            )
        )
        self.loopEnabled = PlaybackLoopPolicy.defaultLoopEnabled(for: mediaKind)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
    override func viewDidLoad() { super.viewDidLoad(); configureUI(); loadMedia() }
    override func viewDidAppear() { super.viewDidAppear(); beginPendingImageLoad() }

    private func configureUI() {
        let root = NSStackView(); root.identifier = NSUserInterfaceItemIdentifier("preview-root"); root.orientation = .vertical; root.alignment = .centerX; root.distribution = .fill; root.spacing = 8; root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14); root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        configureTopActions()
        metadataStack.identifier = NSUserInterfaceItemIdentifier("preview-metadata-stack")
        metadataStack.orientation = .vertical
        metadataStack.alignment = .centerX
        metadataStack.distribution = .fill
        metadataStack.spacing = 2
        metadataStack.setContentHuggingPriority(.required, for: .vertical)
        metadataStack.setContentCompressionResistancePriority(.required, for: .vertical)
        [(row1, "preview-metadata-row-1"), (row2, "preview-metadata-row-2")].forEach { row, identifier in
            row.identifier = NSUserInterfaceItemIdentifier(identifier)
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY
            row.distribution = .fillProportionally
            row.setContentHuggingPriority(.required, for: .vertical)
            row.setContentCompressionResistancePriority(.required, for: .vertical)
            row.isHidden = true
            metadataStack.addArrangedSubview(row)
        }
        root.addArrangedSubview(metadataStack)
        setMetadata(metadataProgression.metadata)
        switch mediaKind {
        case .image:
            imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.imageAlignment = .alignCenter
            configureImageUI(in: root)
        case .video:
            configureVideoUI(in: root)
        case .audio:
            configureVideoUI(in: root)
        case .unsupported:
            break
        }
    }

    private func configureTopActions() {
        topActionStack.orientation = .horizontal
        topActionStack.alignment = .centerY
        topActionStack.spacing = 6
        topActionStack.translatesAutoresizingMaskIntoConstraints = false
        let manualButton = NSButton(title: "使用说明", target: self, action: #selector(showUsageManual(_:)))
        let shortcutButton = NSButton(title: "快捷键设置", target: self, action: #selector(showShortcutSettings(_:)))
        for button in [manualButton, shortcutButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.bezelStyle = .texturedRounded
            topActionStack.addArrangedSubview(button)
        }
        view.addSubview(topActionStack)
        // Reserve the native traffic-light area while keeping these actions in
        // the window's upper-left corner without changing the playback layout.
        NSLayoutConstraint.activate([
            topActionStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 84),
            topActionStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        ])
        filenameLabel.stringValue = url.lastPathComponent
        filenameLabel.toolTip = url.lastPathComponent
        filenameLabel.alignment = .right
        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        filenameLabel.textColor = .secondaryLabelColor
        filenameLabel.maximumNumberOfLines = 2
        filenameLabel.lineBreakMode = .byTruncatingTail
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filenameLabel)
        NSLayoutConstraint.activate([
            filenameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topActionStack.trailingAnchor, constant: 20),
            filenameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            filenameLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            filenameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        ])
    }

    private func configureVideoUI(in root: NSStackView) {
        mediaRow.identifier = NSUserInterfaceItemIdentifier("preview-media-row")
        mediaRow.orientation = .horizontal; mediaRow.alignment = .centerY; mediaRow.spacing = 12; mediaRow.distribution = .fill
        mediaRow.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical); mediaRow.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        videoSurface.setContentHuggingPriority(.defaultLow, for: .horizontal); videoSurface.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); videoSurface.setContentHuggingPriority(.defaultLow, for: .vertical); videoSurface.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        videoSurface.onSingleClick = { [weak self] in self?.handle(.togglePlayback) }
        videoSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        configureVideoControlRails()
        configureVolumeStack()
        leftControlRail.addArrangedSubview(volumeStack)
        if mediaKind == .video {
            configureDisplayTransformStack()
            leftControlRail.addArrangedSubview(displayTransformStack)
        }
        speedStack.orientation = .vertical; speedStack.alignment = .centerX; speedStack.spacing = 3; speedStack.distribution = .fill
        for (index, rate) in PlaybackMath.speedOrder.enumerated() {
            let button = NSButton(title: speedTitle(rate), target: self, action: #selector(selectSpeed(_:)))
            button.tag = index; configureTransportButton(button, title: speedTitle(rate), action: #selector(selectSpeed(_:)))
            speedStack.addArrangedSubview(button); speedButtons.append(button)
        }
        configureTransportButton(loopButton, title: "循环", action: #selector(toggleLoop(_:))); speedStack.addArrangedSubview(loopButton)
        speedStack.addArrangedSubview(transportButton(title: "清除 A-B", action: #selector(clearAB(_:))))
        configureTransportButton(trimExportButton, title: "裁切导出…", action: #selector(beginTrimExport(_:)), width: 96); trimExportButton.isEnabled = false; speedStack.addArrangedSubview(trimExportButton)
        configureTransportButton(audioExportButton, title: "导出音频…", action: #selector(beginAudioExport(_:)), width: 96); speedStack.addArrangedSubview(audioExportButton)
        trimExportProgress.isIndeterminate = false; trimExportProgress.minValue = 0; trimExportProgress.maxValue = 100; trimExportProgress.doubleValue = 0; trimExportProgress.controlSize = .small; trimExportProgress.isHidden = true; trimExportProgress.widthAnchor.constraint(equalToConstant: 96).isActive = true; trimExportProgress.heightAnchor.constraint(equalToConstant: 8).isActive = true; speedStack.addArrangedSubview(trimExportProgress)
        trimExportStatus.alignment = .center; trimExportStatus.font = .systemFont(ofSize: 10); trimExportStatus.textColor = .secondaryLabelColor; trimExportStatus.lineBreakMode = .byTruncatingMiddle; trimExportStatus.widthAnchor.constraint(equalToConstant: 96).isActive = true; speedStack.addArrangedSubview(trimExportStatus)
        configureTransportButton(cancelExportButton, title: "取消导出", action: #selector(cancelExport(_:)), width: 96); cancelExportButton.isHidden = true; speedStack.addArrangedSubview(cancelExportButton)
        rightControlRail.addArrangedSubview(speedStack)
        mediaRow.addArrangedSubview(leftControlRail)
        mediaRow.addArrangedSubview(videoSurface)
        mediaRow.addArrangedSubview(rightControlRail)
        root.addArrangedSubview(mediaRow)
        // Equal-width outer rails make the viewport's center independent from
        // the different controls each rail contains. With the row's equal
        // inter-item spacing, the surface is therefore centered geometrically.
        leftControlRail.widthAnchor.constraint(equalTo: rightControlRail.widthAnchor).isActive = true
        if mediaKind == .video {
            NSLayoutConstraint.activate([
                videoSurface.topAnchor.constraint(equalTo: mediaRow.topAnchor),
                videoSurface.bottomAnchor.constraint(equalTo: mediaRow.bottomAnchor)
            ])
        }
        // ZoomablePlayerSurface deliberately claims every point in its bounds so
        // video gestures stay on the canvas. Keep the left controls above it in
        // the responder hit-test order if the player view's frame reaches into
        // the adjacent stack during Auto Layout.
        mediaRow.addSubview(leftControlRail, positioned: .above, relativeTo: videoSurface)
        timeLabel.alignment = .center; timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); timeLabel.textColor = .secondaryLabelColor; timeLabel.setContentHuggingPriority(.required, for: .vertical); timeLabel.setContentCompressionResistancePriority(.required, for: .vertical); root.addArrangedSubview(timeLabel)
        root.addArrangedSubview(timeline); timeline.heightAnchor.constraint(equalToConstant: 76).isActive = true
        PreviewContentLayout.constrainToContentWidth(mediaRow, in: root)
        PreviewContentLayout.constrainToContentWidth(timeline, in: root)
        timeline.hoverStarted = { [weak self] in self?.beginHover() }; timeline.hoverEnded = { [weak self] in self?.endHover() }; timeline.hoverChanged = { [weak self] fraction in self?.scheduleHover(fraction) }
        updateSpeedButtons()
    }

    private func configureVideoControlRails() {
        leftControlRail.identifier = NSUserInterfaceItemIdentifier("preview-left-control-rail")
        leftControlRail.orientation = .horizontal
        leftControlRail.alignment = .centerY
        leftControlRail.spacing = 12
        leftControlRail.distribution = .fill
        rightControlRail.identifier = NSUserInterfaceItemIdentifier("preview-right-control-rail")
        rightControlRail.orientation = .vertical
        rightControlRail.alignment = .trailing
        rightControlRail.spacing = 0
        rightControlRail.distribution = .fill
        for rail in [leftControlRail, rightControlRail] {
            rail.setContentHuggingPriority(.required, for: .horizontal)
            rail.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    private func configureImageUI(in root: NSStackView) {
        mediaRow.orientation = .horizontal; mediaRow.alignment = .centerY; mediaRow.spacing = 12; mediaRow.distribution = .fill
        mediaRow.setContentHuggingPriority(.defaultLow, for: .vertical); mediaRow.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageSurface.setContentHuggingPriority(.defaultLow, for: .horizontal); imageSurface.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); imageSurface.setContentHuggingPriority(.defaultLow, for: .vertical); imageSurface.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        configureDisplayTransformStack()
        imageActionStack.orientation = .vertical; imageActionStack.alignment = .centerX; imageActionStack.spacing = 8; imageActionStack.distribution = .fill
        configureTransportButton(imageCropSaveButton, title: "裁切保存…", action: #selector(beginImageCropSave(_:)), width: 96)
        configureTransportButton(imageJPEGConversionButton, title: "转 JPG", action: #selector(beginImageJPEGConversion(_:)), width: 96)
        configureTransportButton(imageJPEGCompressionButton, title: "压缩图片…", action: #selector(beginImageJPEGCompression(_:)), width: 96)
        imageActionStack.addArrangedSubview(imageCropSaveButton)
        imageActionStack.addArrangedSubview(imageJPEGConversionButton)
        imageActionStack.addArrangedSubview(imageJPEGCompressionButton)
        mediaRow.addArrangedSubview(displayTransformStack)
        mediaRow.addArrangedSubview(imageSurface)
        mediaRow.addArrangedSubview(imageActionStack)
        root.addArrangedSubview(mediaRow)
        // The image canvas claims its whole bounds for pan/zoom, so retain the
        // transform and save controls as the top hit-test views.
        mediaRow.addSubview(displayTransformStack, positioned: .above, relativeTo: imageSurface)
        PreviewContentLayout.constrainToContentWidth(mediaRow, in: root)
    }

    private func configureVolumeStack() {
        volumeStack.orientation = .vertical; volumeStack.alignment = .centerX; volumeStack.spacing = 8; volumeStack.distribution = .fill
        lastAudibleVolume = max(player.volume, 0)
        volumeControl.value = player.volume
        volumeControl.valueChanged = { [weak self] value in self?.setVolume(value) }
        volumeControl.widthAnchor.constraint(equalToConstant: 42).isActive = true
        volumeControl.heightAnchor.constraint(equalToConstant: 270).isActive = true
        volumeStack.addArrangedSubview(volumeControl)
        configureTransportButton(muteButton, title: "静音", action: #selector(toggleMute(_:)), width: 64)
        volumeStack.addArrangedSubview(muteButton)
        let restartButton = transportButton(title: "↶ 开头", action: #selector(restart(_:)), width: 76)
        volumeStack.addArrangedSubview(restartButton)
    }

    private func configureDisplayTransformStack() {
        displayTransformStack.orientation = .vertical
        displayTransformStack.alignment = .centerX
        displayTransformStack.spacing = 8
        displayTransformStack.distribution = .fill
        if mediaKind == .video {
            configureCompactSymbolButton(rotateCounterclockwiseButton, title: "逆90°", symbolName: "rotate.left", action: #selector(rotateCounterclockwise(_:)))
            configureCompactSymbolButton(rotateClockwiseButton, title: "顺90°", symbolName: "rotate.right", action: #selector(rotateClockwise(_:)))
            configureCompactSymbolButton(mirrorButton, title: "镜像", symbolName: "arrow.left.and.right", action: #selector(toggleMirror(_:)))
        } else {
            // Image editing retains its existing text controls; only the video
            // playback rail is intentionally compacted into icon buttons.
            configureTransportButton(rotateCounterclockwiseButton, title: "逆90°", action: #selector(rotateCounterclockwise(_:)), width: 64)
            configureTransportButton(rotateClockwiseButton, title: "顺90°", action: #selector(rotateClockwise(_:)), width: 64)
            configureTransportButton(mirrorButton, title: "镜像", action: #selector(toggleMirror(_:)), width: 64)
        }
        [rotateCounterclockwiseButton, rotateClockwiseButton, mirrorButton].forEach(displayTransformStack.addArrangedSubview)
        if mediaKind == .video {
            configureCompactSymbolButton(videoScreenshotButton, title: "截图", symbolName: "camera", action: #selector(captureVideoScreenshot(_:)))
            displayTransformStack.addArrangedSubview(videoScreenshotButton)
            updateVideoScreenshotButton()
        }
        updateDisplayTransformControls()
    }

    private func speedTitle(_ rate: Float) -> String { rate.rounded() == rate ? "\(Int(rate))×" : "\(rate)×" }
    private func transportButton(title: String, action: Selector, width: CGFloat = 82) -> NSButton { let button = NSButton(); configureTransportButton(button, title: title, action: action, width: width); return button }
    private func configureTransportButton(_ button: NSButton, title: String, action: Selector, width: CGFloat = 82) { button.title = title; button.target = self; button.action = action; button.font = .systemFont(ofSize: 14, weight: .semibold); button.bezelStyle = .rounded; button.alignment = .center; button.widthAnchor.constraint(equalToConstant: width).isActive = true; button.heightAnchor.constraint(equalToConstant: 40).isActive = true; button.contentTintColor = .white; button.bezelColor = .darkGray }
    private func configureCompactSymbolButton(_ button: NSButton, title: String, symbolName: String, action: Selector) {
        button.target = self
        button.action = action
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.bezelStyle = .smallSquare
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 46).isActive = true
        // smallSquare contributes one point above and below its alignment rect,
        // so this produces a physical 46×46 button frame.
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.contentTintColor = .white
        button.bezelColor = .darkGray
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.setAccessibilityLabel(title)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            // System Symbols are available on the supported OS, but retain a
            // short, readable action name if a symbol is ever unavailable.
            button.title = title
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    @objc private func selectSpeed(_ sender: NSButton) {
        cancelLoopSeek()
        let rate = PlaybackMath.speedOrder[sender.tag]
        chosenForwardRate = rate; shuttleRate = 0; play(at: rate)
    }
    @objc private func restart(_ sender: Any?) { restartPlayback() }
    @objc private func toggleMute(_ sender: Any?) { toggleMutedState() }
    @objc private func toggleLoop(_ sender: Any?) { loopEnabled.toggle(); if !loopEnabled { cancelLoopSeek() }; updateSpeedButtons() }
    @objc private func clearAB(_ sender: Any?) { markers.clear(); cancelLoopSeek(); updateABMarkers() }
    @objc private func rotateCounterclockwise(_ sender: Any?) { updateDisplayTransform(by: -1) }
    @objc private func rotateClockwise(_ sender: Any?) { updateDisplayTransform(by: 1) }
    @objc private func captureVideoScreenshot(_ sender: Any?) { beginVideoScreenshotCapture() }
    @objc private func toggleMirror(_ sender: Any?) {
        switch mediaKind {
        case .video:
            videoDisplayTransform.toggleMirror()
            videoSurface.setDisplayTransform(videoDisplayTransform)
        case .image:
            imageDisplayTransform.toggleMirror()
            imageSurface.setDisplayTransform(imageDisplayTransform)
        case .audio, .unsupported:
            return
        }
        updateDisplayTransformControls()
    }

    private func updateDisplayTransform(by quarterTurns: Int) {
        switch mediaKind {
        case .video:
            videoDisplayTransform.rotate(by: quarterTurns)
            videoSurface.setDisplayTransform(videoDisplayTransform)
        case .image:
            imageDisplayTransform.rotate(by: quarterTurns)
            imageSurface.setDisplayTransform(imageDisplayTransform)
        case .audio, .unsupported:
            return
        }
        updateDisplayTransformControls()
    }

    private func updateDisplayTransformControls() {
        let transform = mediaKind == .image ? imageDisplayTransform : videoDisplayTransform
        mirrorButton.state = transform.isMirrored ? .on : .off
        mirrorButton.bezelColor = transform.isMirrored ? .systemBlue : .darkGray
        mirrorButton.contentTintColor = .white
        if mediaKind == .video {
            rotateCounterclockwiseButton.toolTip = "逆90°"
            rotateClockwiseButton.toolTip = "顺90°"
            mirrorButton.toolTip = "镜像"
        } else {
            let degrees = transform.quarterTurnsClockwise * 90
            let stateDescription = degrees == 0 ? "原始方向" : "顺时针 \(degrees)°"
            rotateCounterclockwiseButton.toolTip = "当前：\(stateDescription)；每次逆时针旋转 90°"
            rotateClockwiseButton.toolTip = "当前：\(stateDescription)；每次顺时针旋转 90°"
            mirrorButton.toolTip = transform.isMirrored ? "已镜像；再次点击关闭" : "左右镜像"
        }
    }

    private func updateVideoScreenshotButton() {
        guard mediaKind == .video else { return }
        // Keep the compact action affordance stable while capture is pending;
        // progress remains visible in trimExportStatus rather than replacing
        // the icon with a text label.
        videoScreenshotButton.toolTip = "截图"
        videoScreenshotButton.setAccessibilityLabel("截图")
        videoScreenshotButton.isEnabled = !videoScreenshotCaptureGate.isPending && !isExporting
    }

    private func beginVideoScreenshotCapture() {
        guard mediaKind == .video, videoScreenshotCaptureGate.begin() else { return }
        guard let asset = player.currentItem?.asset else {
            videoScreenshotCaptureGate.finish()
            updateVideoScreenshotButton()
            presentVideoScreenshotError(VideoFrameScreenshotError.frameUnavailable)
            return
        }

        let requestedTime = player.currentTime()
        guard requestedTime.isValid, !requestedTime.isIndefinite else {
            videoScreenshotCaptureGate.finish()
            updateVideoScreenshotButton()
            presentVideoScreenshotError(VideoFrameScreenshotError.frameUnavailable)
            return
        }

        videoScreenshotGenerator?.cancelAllCGImageGeneration()
        videoScreenshotCommitToken?.invalidate()
        videoScreenshotGenerationID += 1
        let generationID = videoScreenshotGenerationID
        let commitToken = VideoFrameScreenshotCommitToken()
        videoScreenshotCommitToken = commitToken

        let generator = AVAssetImageGenerator(asset: asset)
        // A zero maximum size asks AVFoundation for the source raster, not the
        // player view's scaled presentation. The preferred orientation is
        // baked here before the user rotate/mirror state is applied below.
        generator.maximumSize = .zero
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        videoScreenshotGenerator = generator

        let displayTransform = videoDisplayTransform
        let sourceURL = url
        updateVideoScreenshotButton()
        trimExportStatus.stringValue = "正在截图…"
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { [weak self, commitToken] _, image, _, _, error in
            guard let image else {
                DispatchQueue.main.async {
                    self?.finishVideoScreenshotCapture(
                        generationID: generationID,
                        commitToken: commitToken,
                        result: .failure(error ?? VideoFrameScreenshotError.frameUnavailable)
                    )
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<URL, Error>
                do {
                    guard commitToken.isActive else { throw VideoFrameScreenshotError.cancelled }
                    let data = try VideoFrameScreenshotExporter.jpegData(from: image, displayTransform: displayTransform)
                    guard commitToken.isActive else { throw VideoFrameScreenshotError.cancelled }
                    let destination = try VideoFrameScreenshotSavePlan.commitJPEGData(
                        data,
                        beside: sourceURL,
                        authorizeFinalMove: { operation in
                            try commitToken.performIfActive(operation)
                        }
                    )
                    result = .success(destination)
                } catch {
                    result = .failure(error)
                }
                DispatchQueue.main.async {
                    self?.finishVideoScreenshotCapture(
                        generationID: generationID,
                        commitToken: commitToken,
                        result: result
                    )
                }
            }
        }
    }

    private func finishVideoScreenshotCapture(
        generationID: Int,
        commitToken: VideoFrameScreenshotCommitToken,
        result: Result<URL, Error>
    ) {
        guard videoScreenshotGenerationID == generationID,
              videoScreenshotCommitToken === commitToken else { return }
        videoScreenshotGenerator = nil
        videoScreenshotCommitToken = nil
        videoScreenshotCaptureGate.finish()
        updateVideoScreenshotButton()

        switch result {
        case .success(let destination):
            trimExportStatus.stringValue = "已保存 \(destination.lastPathComponent)"
        case .failure(let error):
            presentVideoScreenshotError(error)
        }
    }

    private func presentVideoScreenshotError(_ error: Error) {
        trimExportStatus.stringValue = error.localizedDescription
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图保存失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func setVolume(_ requestedVolume: Float) {
        let volume = Float(VolumeControlMath.clamped(CGFloat(requestedVolume)))
        player.volume = volume
        volumeControl.value = volume
        if volume > 0 { lastAudibleVolume = volume }
        // An explicit volume gesture takes precedence over a previous mute
        // state; otherwise the bar and audible state disagree.
        if player.isMuted { player.isMuted = false }
        updateSpeedButtons()
    }

    private func toggleMutedState() {
        if player.isMuted {
            let restored = lastAudibleVolume > 0 ? lastAudibleVolume : 1
            player.volume = restored
            volumeControl.value = restored
            player.isMuted = false
        } else {
            if player.volume > 0 { lastAudibleVolume = player.volume }
            player.isMuted = true
            // Do not discard the remembered audio level: only the visible
            // level is zero while muted, so unmute can restore it exactly.
            volumeControl.value = 0
        }
        updateSpeedButtons()
    }
    @objc private func beginTrimExport(_ sender: Any?) {
        guard !isExporting, let range = currentTrimRange(), let plan = FFmpegTrimExportPlan.make(sourceURL: url, mediaKind: mediaKind) else { return }
        resetVideoExportProgress()
        activeExportIsAudio = false
        isPreparingExport = true
        setExportBusy(true, status: "正在检查 FFmpeg…")
        Task { [weak self] in
            guard let self else { return }
            guard let executableURL = FFmpegLocator.executableURL(), await FFmpegAvailability.verify(executableURL: executableURL) else {
                guard !Task.isCancelled else { return }
                self.isPreparingExport = false
                self.setExportBusy(false)
                self.presentFFmpegMissingAlert()
                return
            }
            guard !Task.isCancelled else { return }
            if plan.kind == .video {
                self.showVideoCropEditor(range: range, plan: plan, executableURL: executableURL)
            } else {
                self.showTrimSavePanel(range: range, plan: plan, crop: nil, executableURL: executableURL)
            }
        }
    }

    private func showVideoCropEditor(range: CMTimeRange, plan: FFmpegTrimExportPlan, executableURL: URL) {
        let asset = AVURLAsset(url: url)
        let displayTransform = videoDisplayTransform
        Task { [weak self] in
            guard let self else { return }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let preferredTransform = try? await track.load(.preferredTransform) else {
                self.isPreparingExport = false
                self.setExportBusy(false)
                self.resetVideoExportProgress()
                self.presentExportError(ABTrimExportError.noTracks)
                return
            }
            let preferredSize = VideoDisplayTransform.preferredDisplaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
            guard let sourceBounds = VideoCropMath.sourceBounds(for: displayTransform.outputSize(for: preferredSize)) else {
                self.isPreparingExport = false
                self.setExportBusy(false)
                self.resetVideoExportProgress()
                self.presentExportError(ABTrimExportError.noTracks)
                return
            }
            guard !Task.isCancelled else { return }
            let time = self.player.currentTime().isValid && self.player.currentTime().seconds.isFinite ? self.player.currentTime() : .zero
            self.generateCropPreview(asset: asset, at: time, displayTransform: displayTransform) { [weak self] preview in
                guard let self, self.isPreparingExport, let window = self.view.window else { return }
                let editor = CropEditorSheetController(
                    sourceSize: sourceBounds.size,
                    previewImage: preview,
                    initialSelection: self.savedVideoCropSelection
                ) { [weak self] result in
                    guard let self else { return }
                    self.cropEditor = nil
                    switch result {
                    case .cancelled:
                        self.isPreparingExport = false
                        self.resetVideoExportProgress()
                        self.setExportBusy(false)
                    case .selected(let crop):
                        self.savedVideoCropSelection = crop
                        self.showTrimSavePanel(range: range, plan: plan, crop: crop, displayTransform: displayTransform, executableURL: executableURL)
                    }
                }
                self.cropEditor = editor
                editor.present(for: window)
            }
        }
    }

    private func generateCropPreview(asset: AVAsset, at time: CMTime, displayTransform: VideoDisplayTransform, completion: @escaping (NSImage?) -> Void) {
        cropPreviewGenerator?.cancelAllCGImageGeneration()
        cropPreviewGenerationID += 1
        let generationID = cropPreviewGenerationID
        cropPreviewCompletion = completion
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        cropPreviewGenerator = generator
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, image, _, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.cropPreviewGenerationID == generationID else { return }
                self.cropPreviewGenerator = nil
                let completion = self.cropPreviewCompletion
                self.cropPreviewCompletion = nil
                completion?(image.map { displayTransform.transformedPreviewImage(NSImage(cgImage: $0, size: .zero)) })
            }
        }
    }

    private func showTrimSavePanel(range: CMTimeRange, plan: FFmpegTrimExportPlan, crop: VideoCropSelection?, displayTransform: VideoDisplayTransform = VideoDisplayTransform(), executableURL: URL) {
        guard let window = view.window else { isPreparingExport = false; resetVideoExportProgress(); setExportBusy(false); return }
        let panel = NSSavePanel()
        panel.title = "导出 A-B 裁切"
        panel.prompt = "导出"
        if let crop {
            panel.message = "\(plan.savePanelMessage)\n导出画幅：\(crop.title)（\(crop.rasterDescription)），只裁切，不缩放。"
        } else {
            panel.message = "\(plan.savePanelMessage)\n导出画幅：原始画幅（不裁切）。"
        }
        panel.nameFieldStringValue = ABTrimExportPlan.suggestedFilename(for: url, fileExtension: plan.fileExtension)
        panel.allowedContentTypes = [UTType(filenameExtension: plan.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                self.isPreparingExport = false
                self.resetVideoExportProgress()
                self.setExportBusy(false)
                return
            }
            self.startTrimExport(range: range, plan: plan, crop: crop, displayTransform: displayTransform, executableURL: executableURL, destination: destination.standardizedFileURL)
        }
    }

    @objc private func beginImageJPEGConversion(_ sender: Any?) {
        showImageJPEGSavePanel(kind: .conversion)
    }

    @objc private func beginImageJPEGCompression(_ sender: Any?) {
        showImageJPEGSavePanel(kind: .compression)
    }

    private func showImageJPEGSavePanel(kind: ImageJPEGSaveKind) {
        guard mediaKind == .image, imageSourceCGImage != nil, let window = view.window else {
            presentImageJPEGError(.sourceUnavailable)
            return
        }
        let proposedURL = ImageJPEGSavePlan.suggestedSiblingURL(for: url, kind: kind)
        let panel = NSSavePanel()
        panel.title = kind == .conversion ? "转换为 JPG" : "压缩图片"
        panel.prompt = "保存新 JPEG"
        panel.directoryURL = proposedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = proposedURL.lastPathComponent
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        switch kind {
        case .conversion:
            panel.message = "将以高质量 JPEG（质量 0.95）保存为新文件；当前显示的旋转和镜像会烘焙到完整图片中，不会裁切或覆盖原图。"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let destination = panel.url else { return }
                self.saveImageJPEG(kind: kind, target: nil, destination: destination.standardizedFileURL)
            }
        case .compression:
            let accessory = ImageCompressionSavePanelAccessory()
            panel.message = "输出为新 JPEG，不会覆盖原图。请填写正的十进制 MB 上限；下方会显示实际文件必须严格小于的安全目标。"
            panel.accessoryView = accessory.view
            panel.beginSheetModal(for: window) { [weak self, accessory] response in
                guard let self, response == .OK, let destination = panel.url else { return }
                guard let target = accessory.target else {
                    self.presentImageJPEGError(.invalidCompressionCap)
                    return
                }
                self.saveImageJPEG(kind: kind, target: target, destination: destination.standardizedFileURL)
            }
        }
    }

    private func saveImageJPEG(kind: ImageJPEGSaveKind, target: ImageJPEGCompressionTarget?, destination: URL) {
        guard let source = imageSourceCGImage else {
            presentImageJPEGError(.sourceUnavailable)
            return
        }
        let outputURL = destination.standardizedFileURL
        guard ["jpg", "jpeg"].contains(outputURL.pathExtension.lowercased()) else {
            presentImageJPEGError(.invalidDestinationExtension)
            return
        }
        switch ImageJPEGSavePlan.newSaveDecision(sourceURL: url, destinationURL: outputURL) {
        case .allowed:
            break
        case .wouldOverwriteSource:
            presentImageJPEGError(.newSaveWouldOverwriteSource)
            return
        case .destinationAlreadyExists:
            presentImageJPEGError(.newSaveDestinationExists)
            return
        }

        let fileManager = FileManager.default
        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(".MediaPreview-\(UUID().uuidString).jpg", isDirectory: false)
        do {
            // JPEG actions deliberately ignore a prior crop selection: the
            // complete source raster is transformed exactly as currently shown.
            let rendered = try ImageRasterExporter.renderedImage(
                source: source,
                plan: ImageExportPlan(displayTransform: imageDisplayTransform, crop: nil)
            )
            let data: Data
            switch kind {
            case .conversion:
                data = try ImageJPEGExporter.conversionData(from: rendered)
            case .compression:
                guard let target else { throw ImageJPEGExportError.invalidCompressionCap }
                data = try ImageJPEGExporter.compressedData(from: rendered, target: target)
                // This check is intentionally adjacent to the first filesystem
                // write. A failed encoder result can never be moved as an
                // over-limit output.
                guard data.count < target.safeCapBytes else { throw ImageJPEGExportError.impossibleCompressionCap }
            }
            try data.write(to: temporaryURL, options: .atomic)
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        } catch let error as ImageJPEGExportError {
            try? fileManager.removeItem(at: temporaryURL)
            presentImageJPEGError(error)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            presentImageJPEGError(ImageJPEGExportError.writeFailed(error.localizedDescription))
        }
    }

    private func presentImageJPEGError(_ error: ImageJPEGExportError) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "JPEG 保存失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    @objc private func beginImageCropSave(_ sender: Any?) {
        guard mediaKind == .image else { return }
        guard let source = imageSourceCGImage, let window = view.window else {
            presentImageSaveError(ImageSaveError.sourceUnavailable)
            return
        }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let displayTransform = imageDisplayTransform
        let plan = ImageExportPlan(displayTransform: displayTransform, crop: nil)
        guard plan.canvasSize(for: sourceSize).width > 0, plan.canvasSize(for: sourceSize).height > 0 else {
            presentImageSaveError(ImageSaveError.sourceUnavailable)
            return
        }
        let preview = displayTransform.transformedPreviewImage(NSImage(cgImage: source, size: sourceSize))
        let editor = CropEditorSheetController(
            sourceSize: plan.canvasSize(for: sourceSize),
            previewImage: preview,
            initialSelection: savedImageCropSelection
        ) { [weak self] result in
            guard let self else { return }
            self.imageCropEditor = nil
            guard case let .selected(crop) = result else { return }
            self.savedImageCropSelection = crop
            self.showImageSaveChoice(crop: crop)
        }
        imageCropEditor = editor
        editor.present(for: window)
    }

    private func showImageSaveChoice(crop: VideoCropSelection?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "保存裁切后的图片"
        alert.informativeText = "“另存为新文件”默认使用不覆盖原图的同目录编号文件名；只有点击“覆盖保存”才会替换原图。"
        alert.addButton(withTitle: "另存为新文件…")
        alert.addButton(withTitle: "覆盖保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.showImageSavePanel(crop: crop)
            case .alertSecondButtonReturn:
                self.saveImage(crop: crop, destination: self.url.standardizedFileURL, overwritingSource: true)
            default:
                break
            }
        }
    }

    private func showImageSavePanel(crop: VideoCropSelection?) {
        guard let window = view.window else { return }
        let proposedURL = ImageSavePlan.suggestedSiblingURL(for: url)
        let panel = NSSavePanel()
        panel.title = "另存裁切后的图片"
        panel.prompt = "保存新文件"
        panel.message = "此操作不会覆盖原图；若目标已存在，应用会停止并保留两个已有文件。"
        panel.directoryURL = proposedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = proposedURL.lastPathComponent
        if let type = imageSourceType.flatMap({ UTType($0 as String) }) ?? UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.saveImage(crop: crop, destination: destination.standardizedFileURL, overwritingSource: false)
        }
    }

    private func saveImage(crop: VideoCropSelection?, destination: URL, overwritingSource: Bool) {
        guard let source = imageSourceCGImage, let sourceType = imageSourceType else {
            presentImageSaveError(ImageSaveError.sourceUnavailable)
            return
        }
        let sourceURL = url.standardizedFileURL
        let outputURL = destination.standardizedFileURL
        if overwritingSource {
            guard outputURL == sourceURL else {
                presentImageSaveError(ImageSaveError.newSaveWouldOverwriteSource)
                return
            }
        } else {
            switch ImageSavePlan.newSaveDecision(sourceURL: sourceURL, destinationURL: outputURL) {
            case .allowed:
                break
            case .wouldOverwriteSource:
                presentImageSaveError(ImageSaveError.newSaveWouldOverwriteSource)
                return
            case .destinationAlreadyExists:
                presentImageSaveError(ImageSaveError.newSaveDestinationExists)
                return
            }
        }

        let fileManager = FileManager.default
        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(".MediaPreview-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            let rendered = try ImageRasterExporter.renderedImage(
                source: source,
                plan: ImageExportPlan(displayTransform: imageDisplayTransform, crop: crop)
            )
            var outputProperties = imageSourceProperties ?? [:]
            outputProperties[kCGImagePropertyOrientation] = 1
            try ImageRasterExporter.write(rendered, typeIdentifier: sourceType, properties: outputProperties, to: temporaryURL)
            if overwritingSource {
                _ = try fileManager.replaceItemAt(sourceURL, withItemAt: temporaryURL, backupItemName: nil, options: [])
            } else {
                // `moveItem` refuses an occupied path, so a race cannot turn a
                // normal save into an implicit replacement.
                try fileManager.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch let error as ImageSaveError {
            try? fileManager.removeItem(at: temporaryURL)
            presentImageSaveError(error)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            presentImageSaveError(ImageSaveError.writeFailed(error.localizedDescription))
        }
    }

    private func presentImageSaveError(_ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "图片保存失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    @objc private func beginAudioExport(_ sender: Any?) {
        guard !isExporting, mediaKind == .video || mediaKind == .audio else { return }
        resetVideoExportProgress()
        let plan = FFmpegAudioExportPlan.make(sourceURL: url, timeRange: currentTrimRange())
        if plan.isABExport {
            presentAudioPacketBoundaryAlert(plan: plan)
        } else {
            prepareAudioExport(plan: plan)
        }
    }

    /// Stream-copy is the only permitted audio path here. The confirmation is
    /// deliberately before FFmpeg/save-panel work so an A/B selection can never
    /// be mistaken for a sample-accurate edit or silently trigger re-encoding.
    private func presentAudioPacketBoundaryAlert(plan: FFmpegAudioExportPlan) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "A/B 音频将按原码流导出"
        alert.informativeText = "为保持原始编码、声道布局和采样率，FFmpeg 只能在音频编码包边界切割。导出起止点可能与 A/B 点相差极短一段；不会重编码。"
        alert.addButton(withTitle: "按原码流导出")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.prepareAudioExport(plan: plan)
        }
    }

    private func prepareAudioExport(plan: FFmpegAudioExportPlan) {
        activeExportIsAudio = true
        isPreparingExport = true
        setExportBusy(true, status: "正在检查 FFmpeg…")
        Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: self.url)
            guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio), !audioTracks.isEmpty else {
                guard !Task.isCancelled else { return }
                self.isPreparingExport = false
                self.setExportBusy(false)
                self.presentExportError(ABTrimExportError.noAudioTrack)
                return
            }
            guard let executableURL = FFmpegLocator.executableURL(), await FFmpegAvailability.verify(executableURL: executableURL) else {
                guard !Task.isCancelled else { return }
                self.isPreparingExport = false
                self.setExportBusy(false)
                self.presentFFmpegMissingAlert()
                return
            }
            guard !Task.isCancelled else { return }
            self.showAudioSavePanel(plan: plan, executableURL: executableURL)
        }
    }

    private func showAudioSavePanel(plan: FFmpegAudioExportPlan, executableURL: URL) {
        guard let window = view.window else { isPreparingExport = false; setExportBusy(false); return }
        let panel = NSSavePanel()
        panel.title = plan.isABExport ? "导出 A-B 音频" : "导出音频"
        panel.prompt = "导出"
        panel.message = plan.savePanelMessage
        panel.nameFieldStringValue = plan.suggestedFilename(for: url)
        // A failed remux may need a user-chosen compatible container (for
        // example, MKA). Do not lock the panel to the suggested extension or
        // retry through a lossy encoder behind the user's back.
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.isPreparingExport = false; self.setExportBusy(false); return }
            self.startAudioExport(plan: plan, executableURL: executableURL, destination: destination.standardizedFileURL)
        }
    }
    @objc private func showUsageManual(_ sender: Any?) {
        guard let manualURL = UsageManualLocator.manualURL() else { return }
        NSWorkspace.shared.open(manualURL)
    }
    @objc private func showShortcutSettings(_ sender: Any?) { onShowShortcutSettings?() }

    private func loadMedia() {
        guard mediaKind != .image else { imageLoadPending = true; return }
        let item = AVPlayerItem(url: url); player.replaceCurrentItem(with: item); player.seek(to: .zero); playerView.player = player
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            // The observer is explicitly delivered on the main queue. Do not
            // enqueue it again: a stale end event could otherwise run after a
            // newer exact seek and restart the loop a second time.
            MainActor.assumeIsolated { self?.loopAtEnd() }
        }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // This callback already runs on the main queue. Processing it in
            // place prevents a backlog of old playhead values from repeatedly
            // requesting exact loop seeks after the player has been rewound.
            MainActor.assumeIsolated { self?.updatePlayback(time) }
        }
        beginMetadataInspection()
        if mediaKind == .audio { startWaveformExtraction() }
        Task { [weak self] in
            guard let self, let currentItem = self.player.currentItem else { return }
            guard let duration = try? await currentItem.asset.load(.duration) else { return }
            if self.mediaKind == .video { self.generateFrames(asset: currentItem.asset, duration: duration.seconds) }
        }
    }

    private func startWaveformExtraction() {
        let extraction = WaveformExtraction(); waveformExtraction = extraction
        let mediaURL = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let values = WaveformReader.extract(url: mediaURL, cancellation: extraction)
            DispatchQueue.main.async {
                guard let self, self.waveformExtraction === extraction, let values else { return }
                self.timeline.setWaveform(values)
            }
        }
    }

    private func loadImage() {
        guard let preview = ImagePreview.load(url: url) else { return }
        imageView.image = preview.image
        imageSurface.setDisplayTransform(imageDisplayTransform)
        applyMetadataUpdates(metadataProgression.receiveNative(preview.metadata))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        imageSourceCGImage = image
        imageSourceType = CGImageSourceGetType(source)
        imageSourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private func beginPendingImageLoad() {
        guard imageLoadPending else { return }
        imageLoadPending = false
        loadImage()
    }

    private func beginMetadataInspection() {
        guard let metadataInspector else { return }
        let mediaURL = url
        nativeMetadataTask?.cancel()
        let token = metadataInspectionToken.begin()
        nativeMetadataTask = Task { [weak self, mediaURL, token] in
            let metadata = await metadataInspector.inspectNative(mediaURL)
            guard !Task.isCancelled, let self, self.metadataInspectionToken.accepts(token), self.url == mediaURL else { return }
            self.applyMetadataUpdates(self.metadataProgression.receiveNative(metadata))
        }
        metadataInspector.inspectEnriched(mediaURL) { [weak self, mediaURL, token] result in
            Task { @MainActor [weak self] in
                guard let self, self.metadataInspectionToken.accepts(token), self.url == mediaURL else { return }
                self.applyMetadataUpdates(self.metadataProgression.receiveFFprobe(result))
            }
        }
    }

    private func applyMetadataUpdates(_ updates: [MediaMetadataUpdate]) {
        for update in updates { setMetadata(update.metadata) }
    }

    private func setMetadata(_ metadata: MediaMetadata) { setMetadataRows(metadata.row1, metadata.row2) }
    func setMetadataRows(_ firstRow: [String], _ secondRow: [String]) {
        setRow(row1, values: firstRow)
        setRow(row2, values: secondRow)
        updateMetadataLayout()
    }
    private func setRow(_ row: NSStackView, values: [String]) {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        for value in values { let field = NSTextField(labelWithString: value); field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); field.textColor = .secondaryLabelColor; row.addArrangedSubview(field) }
        row.isHidden = values.isEmpty
    }
    private func updateMetadataLayout() {
        metadataRowHeightConstraints.forEach { $0.isActive = false }
        metadataHeightConstraint?.isActive = false
        let rows = [row1, row2]
        let rowHeights = rows.map { row -> CGFloat in
            guard !row.isHidden else { return 0 }
            return ceil(row.fittingSize.height)
        }
        metadataRowHeightConstraints = zip(rows, rowHeights).map { row, height in
            let constraint = row.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            return constraint
        }
        let visibleRowCount = rowHeights.filter { $0 > 0 }.count
        let metadataHeight = rowHeights.reduce(0, +) + (visibleRowCount > 1 ? metadataStack.spacing * CGFloat(visibleRowCount - 1) : 0)
        let heightConstraint = metadataStack.heightAnchor.constraint(equalToConstant: metadataHeight)
        heightConstraint.isActive = true
        metadataHeightConstraint = heightConstraint
    }

    private func generateFrames(asset: AVAsset, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true; generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero; imageGenerator = generator
        let times = (0..<10).map { NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / 10, preferredTimescale: 600)) }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
            guard let self, let image else { return }
            let index = min(9, max(0, Int((requested.seconds / duration * 10).rounded(.down))))
            DispatchQueue.main.async { self.timeline.setImage(NSImage(cgImage: image, size: .zero), at: index) }
        }
    }

    private func updatePlayback(_ time: CMTime) {
        guard !hoverActive, let item = player.currentItem else { return }
        let duration = item.duration.seconds; guard duration.isFinite, duration > 0 else { return }
        guard !loopSeekCoordinator.isSeeking else { return }
        if loopEnabled, player.rate != 0, let target = ABLoopMath.restartTarget(time: time.seconds, a: markers.pointA, b: markers.pointB, duration: duration) {
            let resumeRate = player.rate
            performExactLoopSeek(to: target, resumeRate: resumeRate)
            return
        }
        timeline.playheadFraction = time.seconds / duration; timeLabel.stringValue = "\(MetadataFormatter.duration(time.seconds) ?? "") / \(MetadataFormatter.duration(duration) ?? "")"
    }
    private func beginHover() { guard !hoverActive else { return }; cancelLoopSeek(); hoverActive = true; hoverRate = player.rate; oldMuted = player.isMuted; player.pause(); player.isMuted = true }
    private func endHover() { hoverWorkItem?.cancel(); hoverWorkItem = nil; hoverActive = false; player.isMuted = oldMuted; if hoverRate != 0 { play(at: hoverRate) } }
    private func scheduleHover(_ fraction: Double) { hoverWorkItem?.cancel(); let work = DispatchWorkItem { [weak self] in self?.seekForHover(fraction) }; hoverWorkItem = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: work) }
    private func seekForHover(_ fraction: Double) {
        guard hoverActive, let item = player.currentItem else { return }; let duration = item.duration.seconds; guard duration.isFinite else { return }
        let seconds = TimelineMath.time(fraction: fraction, duration: duration); player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); timeline.playheadFraction = fraction; timeLabel.stringValue = "\(MetadataFormatter.duration(seconds) ?? "") / \(MetadataFormatter.duration(duration) ?? "")"
    }

    @discardableResult
    func handlePlainArrowKeyDown(_ event: NSEvent) -> Bool {
        guard mediaKind != .image,
              let action = PreviewArrowRouting.keyDownAction(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                playerRate: player.rate
              ) else { return false }
        switch action {
        case .stepFrame(let count):
            guard mediaKind == .video else { return false }
            cancelLoopSeek()
            // AVPlayerItem performs a decoded-frame step while paused, instead
            // of approximating a frame duration through a time seek.
            player.currentItem?.step(byCount: count)
            updateSpeedButtons()
            return true
        case .startShuttle(let direction):
            guard mediaKind == .video else { return false }
            if plainArrowShuttleKeyCode != nil { return true } // key-repeat or another held arrow
            cancelLoopSeek()
            plainArrowShuttleKeyCode = event.keyCode
            plainArrowRestoreRate = chosenForwardRate
            let rate: Float = direction == .forward ? PreviewArrowRouting.shuttleRate : -PreviewArrowRouting.shuttleRate
            shuttleRate = rate
            if rate < 0, player.currentItem?.canPlayReverse != true {
                player.pause()
            } else {
                // This temporary shuttle must not replace the user's selected
                // normal forward speed, which is restored on matching key-up.
                play(at: rate, updatesChosenForwardRate: false)
            }
            updateSpeedButtons()
            return true
        case .adjustVolume(let delta):
            setVolume(PreviewArrowRouting.adjustedVolume(current: player.volume, by: delta))
            return true
        case .restoreForwardPlayback:
            return false
        }
    }

    @discardableResult
    func handlePlainArrowKeyUp(_ event: NSEvent) -> Bool {
        guard PreviewArrowRouting.keyUpAction(keyCode: event.keyCode, modifiers: event.modifierFlags) == .restoreForwardPlayback,
              plainArrowShuttleKeyCode == event.keyCode,
              let restoreRate = plainArrowRestoreRate else { return false }
        plainArrowShuttleKeyCode = nil
        plainArrowRestoreRate = nil
        shuttleRate = 0
        play(at: restoreRate, updatesChosenForwardRate: false)
        return true
    }

    func handle(_ command: PreviewKeyCommand) {
        if mediaKind == .image {
            if command == .zoomReset { imageSurface.resetZoom() }
            return
        }
        switch command {
        case .togglePlayback:
            shuttleRate = 0
            if loopSeekCoordinator.isSeeking { cancelLoopSeek(); player.pause() }
            else {
                switch PlaybackLoopPolicy.spaceAction(
                    mediaKind: mediaKind,
                    loopEnabled: loopEnabled,
                    playerRate: player.rate,
                    currentTime: player.currentTime().seconds,
                    duration: player.currentItem?.duration.seconds ?? .nan
                ) {
                case .restartFromBeginning:
                    restartPlayback()
                case .togglePlayback:
                    player.rate == 0 ? play(at: chosenForwardRate) : player.pause()
                }
            }
        case .jump(let fraction):
            jump(by: fraction)
        case .shuttle(let direction):
            cancelLoopSeek()
            let rate = PlaybackMath.nextShuttleRate(currentRate: shuttleRate, direction: direction)
            shuttleRate = rate
            if rate < 0, player.currentItem?.canPlayReverse != true { player.pause(); shuttleRate = 0 } else { play(at: rate) }
        case .pause:
            cancelLoopSeek(); player.pause(); shuttleRate = 0
        case .setA:
            setMarkerA()
        case .setB:
            setMarkerB()
        case .restart:
            restartPlayback()
        case .toggleLoop:
            loopEnabled.toggle()
            if !loopEnabled { cancelLoopSeek() }
        case .clearAB:
            markers.clear(); cancelLoopSeek(); updateABMarkers()
        case .mute:
            toggleMutedState()
        case .zoomReset:
            videoSurface.resetZoom()
        case .close:
            break
        }
        updateSpeedButtons()
    }

    private func jump(by fraction: Double) {
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds; guard duration.isFinite, duration > 0 else { return }
        cancelLoopSeek()
        let previousRate = player.rate
        let target = PlaybackMath.jump(time: player.currentTime().seconds, duration: duration, fraction: fraction)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, previousRate != 0 else { return }
                if previousRate < 0, self.player.currentItem?.canPlayReverse != true { self.player.pause() } else { self.play(at: previousRate) }
            }
        }
    }

    private func restartPlayback() {
        cancelLoopSeek()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, let self else { return }
            DispatchQueue.main.async { self.play(at: self.chosenForwardRate) }
        }
    }

    private func play(at rate: Float, updatesChosenForwardRate: Bool = true) {
        guard rate != 0 else { player.pause(); return }
        if rate > 0, updatesChosenForwardRate { chosenForwardRate = rate }
        player.playImmediately(atRate: rate)
        updateSpeedButtons()
    }

    private func updateSpeedButtons() {
        let activeRate = abs(player.rate) > 0 ? abs(player.rate) : chosenForwardRate
        for (index, button) in speedButtons.enumerated() {
            let active = abs(PlaybackMath.speedOrder[index] - activeRate) < 0.001
            button.state = active ? .on : .off
            button.bezelColor = active ? .systemBlue : .darkGray
            button.contentTintColor = .white
        }
        for (button, active) in [(muteButton, player.isMuted), (loopButton, loopEnabled)] { button.state = active ? .on : .off; button.bezelColor = active ? .systemBlue : .darkGray; button.contentTintColor = .white }
        trimExportButton.isEnabled = !isExporting && currentTrimRange() != nil
        audioExportButton.isEnabled = !isExporting && (mediaKind == .video || mediaKind == .audio)
    }

    private func setMarkerA() {
        guard markers.setA(at: player.currentTime().seconds) else { return }
        updateABMarkers()
    }

    private func setMarkerB() {
        guard markers.setB(at: player.currentTime().seconds) else { return }
        updateABMarkers()
    }

    private func updateABMarkers() {
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds
        timeline.setABMarkers(markers.renderState(duration: duration))
        updateSpeedButtons()
    }

    private var isExporting: Bool { ffmpegExportProcess != nil || isPreparingExport }

    private func currentTrimRange() -> CMTimeRange? {
        ABTrimExportPlan.timeRange(a: markers.pointA, b: markers.pointB, duration: player.currentItem?.duration.seconds ?? 0)
    }

    private func startTrimExport(range: CMTimeRange, plan: FFmpegTrimExportPlan, crop: VideoCropSelection?, displayTransform: VideoDisplayTransform, executableURL: URL, destination: URL) {
        let sourceURL = url.standardizedFileURL
        guard destination != sourceURL else { isPreparingExport = false; resetVideoExportProgress(); setExportBusy(false); return presentExportError(ABTrimExportError.wouldOverwriteSource) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { isPreparingExport = false; resetVideoExportProgress(); setExportBusy(false); return presentExportError(ABTrimExportError.destinationAlreadyExists) }
        let isVideoExport = plan.kind == .video
        let running = FFmpegTrimProcess(
            executableURL: executableURL,
            arguments: plan.arguments(sourceURL: sourceURL, destinationURL: destination, timeRange: range, crop: crop, displayTransform: displayTransform),
            totalSeconds: range.duration.seconds,
            onProgress: { [weak self] progress in
                guard let self else { return }
                if isVideoExport { self.setVideoExportProgress(progress) }
                else { self.trimExportStatus.stringValue = "正在裁切音频 \(Int((progress * 100).rounded(.down)))%" }
            },
            onCompletion: { [weak self] result in self?.finishTrimExport(destination: destination, isVideoExport: isVideoExport, result: result) }
        )
        ffmpegExportProcess = running
        isPreparingExport = false
        isCancellingExport = false
        setExportBusy(true, status: isVideoExport ? "导出：0%" : "正在裁切音频…")
        if isVideoExport { beginVideoExportProgress() }
        do {
            try running.start()
        } catch {
            ffmpegExportProcess = nil
            resetVideoExportProgress()
            setExportBusy(false)
            presentExportError(ABTrimExportError.ffmpegFailed(error.localizedDescription))
        }
    }

    private func startAudioExport(plan: FFmpegAudioExportPlan, executableURL: URL, destination: URL) {
        let sourceURL = url.standardizedFileURL
        guard destination != sourceURL else { isPreparingExport = false; setExportBusy(false); return presentExportError(ABTrimExportError.wouldOverwriteSource) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { isPreparingExport = false; setExportBusy(false); return presentExportError(ABTrimExportError.destinationAlreadyExists) }
        let totalSeconds = plan.timeRange?.duration.seconds ?? player.currentItem?.duration.seconds ?? 1
        let running = FFmpegTrimProcess(
            executableURL: executableURL,
            arguments: plan.arguments(sourceURL: sourceURL, destinationURL: destination),
            totalSeconds: totalSeconds,
            onProgress: { [weak self] progress in self?.trimExportStatus.stringValue = "正在原码流导出 \(Int((progress * 100).rounded()))%" },
            onCompletion: { [weak self] result in self?.finishAudioExport(destination: destination, result: result) }
        )
        ffmpegExportProcess = running
        isPreparingExport = false
        isCancellingExport = false
        setExportBusy(true, status: plan.isABExport ? "正在按编码包导出音频…" : "正在导出原始音频…")
        do {
            try running.start()
        } catch {
            ffmpegExportProcess = nil
            setExportBusy(false)
            presentExportError(ABTrimExportError.audioStreamCopyFailed(error.localizedDescription))
        }
    }

    private func finishTrimExport(destination: URL, isVideoExport: Bool, result: Result<Void, ABTrimExportError>) {
        guard ffmpegExportProcess != nil else { return }
        ffmpegExportProcess = nil
        let wasCancelled = isCancellingExport
        isCancellingExport = false
        if wasCancelled {
            resetVideoExportProgress()
            setExportBusy(false, status: VideoExportStatusPresentation.cancelled)
            return
        }
        switch result {
        case .success:
            if isVideoExport {
                completeVideoExportProgress()
                setExportBusy(false, status: VideoExportStatusPresentation.completed(destination: destination))
            } else {
                setExportBusy(false, status: "已导出 \(destination.lastPathComponent)")
            }
        case .failure(let error):
            if isVideoExport { resetVideoExportProgress() }
            setExportBusy(false)
            presentExportError(error)
        }
    }

    private func finishAudioExport(destination: URL, result: Result<Void, ABTrimExportError>) {
        guard ffmpegExportProcess != nil else { return }
        ffmpegExportProcess = nil
        let wasCancelled = isCancellingExport
        isCancellingExport = false
        if wasCancelled {
            setExportBusy(false, status: "已取消导出")
            return
        }
        switch result {
        case .success:
            setExportBusy(false, status: "已导出 \(destination.lastPathComponent)")
        case .failure(let error):
            setExportBusy(false)
            let details: String
            if case .ffmpegFailed(let message) = error { details = message } else { details = error.localizedDescription }
            presentExportError(ABTrimExportError.audioStreamCopyFailed(details))
        }
    }

    @objc private func cancelExport(_ sender: Any?) {
        guard let process = ffmpegExportProcess else { return }
        isCancellingExport = true
        cancelExportButton.isEnabled = false
        trimExportStatus.stringValue = "正在取消导出…"
        process.cancel()
    }

    private func beginVideoExportProgress() {
        trimExportProgress.isHidden = false
        trimExportProgress.doubleValue = 0
        cancelExportButton.isHidden = false
        cancelExportButton.isEnabled = true
        trimExportStatus.stringValue = "导出：0%"
    }

    private func setVideoExportProgress(_ progress: Double) {
        let bounded = min(0.999, max(0, progress))
        trimExportProgress.doubleValue = bounded * 100
        trimExportStatus.stringValue = "导出：\(Int((bounded * 100).rounded(.down)))%"
    }

    private func completeVideoExportProgress() {
        trimExportProgress.isHidden = false
        trimExportProgress.doubleValue = 100
        cancelExportButton.isHidden = true
    }

    private func resetVideoExportProgress() {
        trimExportProgress.doubleValue = 0
        trimExportProgress.isHidden = true
        cancelExportButton.isHidden = true
        cancelExportButton.isEnabled = true
    }

    private func setExportBusy(_ busy: Bool, status: String = "") {
        trimExportButton.title = busy && !activeExportIsAudio ? "正在导出…" : "裁切导出…"
        audioExportButton.title = busy && activeExportIsAudio ? "正在导出…" : "导出音频…"
        trimExportButton.isEnabled = !busy && currentTrimRange() != nil
        audioExportButton.isEnabled = !busy && (mediaKind == .video || mediaKind == .audio)
        updateVideoScreenshotButton()
        trimExportStatus.stringValue = status
    }

    private func presentExportError(_ error: Error) {
        trimExportStatus.stringValue = error.localizedDescription
        guard view.window != nil else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: view.window!)
    }

    private func presentFFmpegMissingAlert() {
        trimExportStatus.stringValue = ABTrimExportError.ffmpegUnavailable.localizedDescription
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "裁切需要 FFmpeg"
        alert.informativeText = "为保证视频任意帧和音频任意时间点的精确 A/B 裁切，本功能使用外部安装的 FFmpeg。应用不会自带或静默安装它。"
        alert.addButton(withTitle: "安装 FFmpeg…")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.openFFmpegInstaller()
        }
    }

    private func openFFmpegInstaller() {
        guard let scriptURL = FFmpegInstallScriptLocator.scriptURL() else {
            presentExportError(ABTrimExportError.ffmpegUnavailable)
            return
        }
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.presentExportError(ABTrimExportError.ffmpegFailed(error.localizedDescription)) }
        }
    }

    private func performExactLoopSeek(to target: Double, resumeRate: Float) {
        guard case let .pauseAndSeek(request) = loopSeekCoordinator.begin(targetSeconds: target, resumeRate: resumeRate) else { return }
        player.pause()
        player.seek(to: request.targetTime, toleranceBefore: request.tolerance, toleranceAfter: request.tolerance) { [weak self] completed in
            DispatchQueue.main.async {
                guard let self, case let .resume(rate) = self.loopSeekCoordinator.finish(request, completed: completed), self.loopEnabled else { return }
                self.play(at: rate)
            }
        }
    }

    private func cancelLoopSeek() {
        guard loopSeekCoordinator.cancel() else { return }
        player.currentItem?.cancelPendingSeeks()
    }

    private func loopAtEnd() {
        guard loopEnabled, !loopSeekCoordinator.isSeeking, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        performExactLoopSeek(to: ABLoopMath.endTarget(a: markers.pointA, b: markers.pointB, duration: duration), resumeRate: chosenForwardRate)
    }
    func tearDown() { metadataInspectionToken.invalidate(); nativeMetadataTask?.cancel(); nativeMetadataTask = nil; imageLoadPending = false; cancelLoopSeek(); hoverWorkItem?.cancel(); waveformExtraction?.cancel(); waveformExtraction = nil; imageGenerator?.cancelAllCGImageGeneration(); imageGenerator = nil; cropPreviewGenerator?.cancelAllCGImageGeneration(); cropPreviewGenerator = nil; cropPreviewGenerationID += 1; cropPreviewCompletion = nil; videoScreenshotCommitToken?.invalidate(); videoScreenshotCommitToken = nil; videoScreenshotGenerator?.cancelAllCGImageGeneration(); videoScreenshotGenerator = nil; videoScreenshotGenerationID += 1; videoScreenshotCaptureGate.finish(); cropEditor = nil; imageCropEditor = nil; imageSourceCGImage = nil; imageSourceType = nil; imageSourceProperties = nil; ffmpegExportProcess?.cancel(); ffmpegExportProcess = nil; isPreparingExport = false; isCancellingExport = false; resetVideoExportProgress(); if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }; if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }; player.pause(); player.replaceCurrentItem(with: nil) }
}
