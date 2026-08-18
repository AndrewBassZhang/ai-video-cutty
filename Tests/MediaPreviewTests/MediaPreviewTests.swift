import AppKit
import AVKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaPreview

final class MediaPreviewTests: XCTestCase {
    private func syntheticWaveformFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic-waveform-12s.m4a")
    }

    @MainActor
    private func firstDescendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: type, in: subview) { return match }
        }
        return nil
    }

    @MainActor
    private func firstDescendant<T: NSView>(of type: T.Type, in view: NSView, where matches: (T) -> Bool) -> T? {
        if let match = view as? T, matches(match) { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: type, in: subview, where: matches) { return match }
        }
        return nil
    }

    @MainActor
    private func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let match = button(titled: title, in: subview) { return match }
        }
        return nil
    }

    @MainActor
    private func identifier(_ value: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == value { return view }
        for subview in view.subviews {
            if let match = identifier(value, in: subview) { return match }
        }
        return nil
    }

    private func screenshotFixtureImage(width: Int, height: Int) throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8((x * 31 + y * 17) % 255)
                bytes[offset + 1] = UInt8((x * 11 + y * 43) % 255)
                bytes[offset + 2] = UInt8((x * 47 + y * 7) % 255)
                bytes[offset + 3] = 255
            }
        }
        return try XCTUnwrap(bitmap.cgImage)
    }

    func testLaunchInputParsesFilesystemPath() {
        XCTAssertEqual(
            LaunchInput.mediaURL(from: ["MediaPreview", "/tmp/example movie.mp4"]),
            URL(fileURLWithPath: "/tmp/example movie.mp4").standardizedFileURL
        )
    }

    func testLaunchInputParsesFileURL() {
        XCTAssertEqual(
            LaunchInput.mediaURL(from: ["MediaPreview", "file:///tmp/example%20movie.mp4"]),
            URL(fileURLWithPath: "/tmp/example movie.mp4").standardizedFileURL
        )
    }

    func testLaunchInputSkipsAppKitProcessSerialArgument() {
        XCTAssertEqual(
            LaunchInput.mediaURL(from: ["MediaPreview", "-psn_0_12345", "/tmp/example movie.mp4"]),
            URL(fileURLWithPath: "/tmp/example movie.mp4").standardizedFileURL
        )
    }

    func testLaunchInputRejectsMissingAndNonFileURL() {
        XCTAssertNil(LaunchInput.mediaURL(from: ["MediaPreview"]))
        XCTAssertNil(LaunchInput.mediaURL(from: ["MediaPreview", ""]))
        XCTAssertNil(LaunchInput.mediaURL(from: ["MediaPreview", "https://example.com/movie.mp4"]))
    }

    func testPreviewPanelSizeUsesScreenFractionOnLargeScreen() {
        let size = PreviewPanelLayout.size(for: CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(size.width, 1_305.6, accuracy: 0.001)
        XCTAssertEqual(size.height, 734.4, accuracy: 0.001)
    }

    func testPreviewPanelSizeUsesMinimumWhenScreenCanFitIt() {
        XCTAssertEqual(PreviewPanelLayout.size(for: CGSize(width: 1_200, height: 800)), CGSize(width: 960, height: 680))
    }

    func testPreviewPanelSizeSkipsMinimumAndRespectsMarginsOnSmallScreen() {
        let screenSize = CGSize(width: 900, height: 600)
        let size = PreviewPanelLayout.size(for: screenSize)
        XCTAssertEqual(size.width, 612, accuracy: 0.001)
        XCTAssertEqual(size.height, 408, accuracy: 0.001)
        XCTAssertLessThanOrEqual(size.width, screenSize.width - 2 * PreviewPanelLayout.screenMargin)
        XCTAssertLessThanOrEqual(size.height, screenSize.height - 2 * PreviewPanelLayout.screenMargin)
    }

    func testPreviewPanelVisibleFramePrefersPrimaryThenMainThenFallback() {
        let primary = NSRect(x: -2_560, y: 0, width: 2_560, height: 1_440)
        let main = NSRect(x: 0, y: 24, width: 1_920, height: 1_056)
        let fallback = NSRect(x: 20, y: 30, width: 960, height: 680)

        XCTAssertEqual(
            PreviewPanelLayout.selectedVisibleFrame(primaryScreen: primary, mainScreen: main, fallback: fallback),
            primary
        )
        XCTAssertEqual(
            PreviewPanelLayout.selectedVisibleFrame(primaryScreen: nil, mainScreen: main, fallback: fallback),
            main
        )
        XCTAssertEqual(
            PreviewPanelLayout.selectedVisibleFrame(primaryScreen: nil, mainScreen: nil, fallback: fallback),
            fallback
        )
    }

    func testPreviewPanelTargetFrameCentersTheRecomputedWindowFrame() {
        let visibleFrame = NSRect(x: -2_560, y: 0, width: 2_560, height: 1_400)
        let contentSize = PreviewPanelLayout.size(for: visibleFrame.size)
        let windowFrameSize = CGSize(width: contentSize.width, height: contentSize.height + 28)

        let targetFrame = PreviewPanelLayout.targetFrame(for: visibleFrame, windowFrameSize: windowFrameSize)

        XCTAssertEqual(targetFrame.size, windowFrameSize)
        XCTAssertEqual(targetFrame.midX, visibleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(targetFrame.midY, visibleFrame.midY, accuracy: 0.001)
    }

    @MainActor
    func testPreviewPanelRestoresComputedContentSizeAfterControllerAssignment() throws {
        let expectedSize = PreviewPanelLayout.size(for: CGSize(width: 1_920, height: 998))
        let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        panel.contentViewController = controller
        panel.setContentSize(expectedSize)

        let contentView = try XCTUnwrap(panel.contentView)
        XCTAssertEqual(contentView.frame.size.width, expectedSize.width.rounded(), accuracy: 0.001)
        XCTAssertEqual(contentView.frame.size.height, expectedSize.height.rounded(), accuracy: 0.001)
    }

    @MainActor
    func testPlayerWidthFillsCenteredStackContentWidth() {
        let root = NSStackView(frame: NSRect(x: 0, y: 0, width: 1_306, height: 700))
        root.orientation = .vertical
        root.alignment = .centerX
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let player = AVPlayerView(frame: .zero)
        player.heightAnchor.constraint(equalToConstant: 430).isActive = true
        root.addArrangedSubview(player)
        PreviewContentLayout.constrainToContentWidth(player, in: root)

        root.layoutSubtreeIfNeeded()

        XCTAssertEqual(player.frame.width, 1_278, accuracy: 0.001)
        XCTAssertEqual(player.frame.midX, root.bounds.midX, accuracy: 0.001)
    }

    @MainActor
    func testVideoLayoutKeepsHeaderCompactAndExpandsCenteredViewportAtLargeSizes() throws {
        let contentSizes = [
            CGSize(width: 1_306, height: 700),
            CGSize(width: 1_920, height: 1_080)
        ]
        var headerHeights: [CGFloat] = []
        var mediaSizes: [CGSize] = []
        var surfaceSizes: [CGSize] = []

        for contentSize in contentSizes {
            let controller = PreviewController(url: URL(fileURLWithPath: "/tmp/example.mp4"), mediaKind: .video)
            controller.loadViewIfNeeded()
            controller.view.frame = NSRect(origin: .zero, size: contentSize)

            controller.setMetadataRows(
                ["1920×1080 · H.264 · 24 fps"],
                ["00:00:12 · 48 Mbps"]
            )
            controller.view.layoutSubtreeIfNeeded()

            let root = try XCTUnwrap(identifier("preview-root", in: controller.view))
            let metadataStack = try XCTUnwrap(identifier("preview-metadata-stack", in: controller.view) as? NSStackView)
            let mediaRow = try XCTUnwrap(identifier("preview-media-row", in: controller.view) as? NSStackView)
            let surface = try XCTUnwrap(firstDescendant(of: ZoomablePlayerSurface.self, in: controller.view))
            let playerView = try XCTUnwrap(firstDescendant(of: AVPlayerView.self, in: surface))
            let timeline = try XCTUnwrap(firstDescendant(of: TimelineView.self, in: controller.view))
            let volume = try XCTUnwrap(firstDescendant(of: VerticalVolumeControl.self, in: controller.view))
            let mute = try XCTUnwrap(button(titled: "静音", in: controller.view))
            let rotate = try XCTUnwrap(button(titled: "逆90°", in: controller.view))
            let mirror = try XCTUnwrap(button(titled: "镜像", in: controller.view))
            let screenshot = try XCTUnwrap(button(titled: "截图", in: controller.view))
            let speed = try XCTUnwrap(button(titled: "8×", in: controller.view))

            let rootFrame = root.convert(root.bounds, to: controller.view)
            let headerFrame = metadataStack.convert(metadataStack.bounds, to: controller.view)
            let mediaFrame = mediaRow.convert(mediaRow.bounds, to: controller.view)
            let surfaceFrame = surface.convert(surface.bounds, to: controller.view)
            let timelineFrame = timeline.convert(timeline.bounds, to: controller.view)

            XCTAssertEqual(rootFrame.width, contentSize.width, accuracy: 0.5)
            XCTAssertEqual(rootFrame.height, contentSize.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(headerFrame.height, metadataStack.fittingSize.height + 0.5, "Metadata may use only its intrinsic two-row height")
            XCTAssertLessThan(headerFrame.height, 50, "The header must not absorb maximized-window height")
            XCTAssertEqual(headerFrame.maxY, rootFrame.maxY - 12, accuracy: 0.5)
            XCTAssertEqual(surfaceFrame.minY, mediaFrame.minY, accuracy: 0.5)
            XCTAssertEqual(surfaceFrame.maxY, mediaFrame.maxY, accuracy: 0.5)
            XCTAssertEqual(playerView.frame.midX, surface.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(playerView.frame.midY, surface.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(playerView.videoGravity, .resizeAspect)
            XCTAssertEqual(timelineFrame.height, 76, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(timelineFrame.minY, rootFrame.minY + 11.5)
            XCTAssertLessThan(timelineFrame.maxY, mediaFrame.minY)

            for control in [volume, mute, rotate, mirror, screenshot, speed] {
                let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: controller.view)
                XCTAssertTrue(controller.view.hitTest(point) === control, "\(String(describing: control)) must remain hit-testable")
            }
            let mirrorCenter = mirror.convert(NSPoint(x: mirror.bounds.midX, y: mirror.bounds.midY), to: controller.view)
            let screenshotCenter = screenshot.convert(NSPoint(x: screenshot.bounds.midX, y: screenshot.bounds.midY), to: controller.view)
            XCTAssertLessThan(screenshotCenter.y, mirrorCenter.y, "截图 must be the next vertical control below 镜像")

            headerHeights.append(headerFrame.height)
            mediaSizes.append(mediaFrame.size)
            surfaceSizes.append(surfaceFrame.size)
        }

        XCTAssertEqual(headerHeights[1], headerHeights[0], accuracy: 0.5)
        XCTAssertGreaterThan(mediaSizes[1].height, mediaSizes[0].height)
        XCTAssertGreaterThan(surfaceSizes[1].width, surfaceSizes[0].width)
        XCTAssertGreaterThan(surfaceSizes[1].height, surfaceSizes[0].height)
    }

    @MainActor
    func testImageCanvasMagnificationClampsToOneAndResets() {
        let canvas = ZoomableImageSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.applyMagnification(by: -4, centeredAt: NSPoint(x: 200, y: 150))
        XCTAssertEqual(canvas.magnification, 1)

        canvas.applyMagnification(by: 2, centeredAt: NSPoint(x: 200, y: 150))
        XCTAssertEqual(canvas.magnification, 3)

        canvas.resetZoom()
        XCTAssertEqual(canvas.magnification, 1)
    }

    func testServiceInputUsesFirstRegularFileURL() {
        let directory = URL(fileURLWithPath: "/tmp/directory")
        let firstFile = URL(fileURLWithPath: "/tmp/first.mp4")
        let secondFile = URL(fileURLWithPath: "/tmp/second.mp4")
        XCTAssertEqual(
            ServiceInput.firstRegularFileURL(
                from: [URL(string: "https://example.com/movie.mp4")!, directory, firstFile, secondFile],
                isRegularFile: { $0 == firstFile || $0 == secondFile }
            ),
            firstFile
        )
    }

    func testServiceInputRejectsSelectionsWithoutRegularFiles() {
        XCTAssertNil(
            ServiceInput.firstRegularFileURL(
                from: [URL(string: "https://example.com/movie.mp4")!, URL(fileURLWithPath: "/tmp/directory")],
                isRegularFile: { _ in false }
            )
        )
    }

    func testBitratePrefersVideoStreamThenContainerFallback() {
        XCTAssertEqual(MetadataFormatter.preferredVideoBitrate(video: 1_000_000, format: 2_000_000), 1_000_000)
        XCTAssertEqual(MetadataFormatter.preferredVideoBitrate(video: nil, format: 2_000_000), 2_000_000)
        XCTAssertEqual(MetadataFormatter.preferredVideoBitrate(video: 0, format: 2_000_000), 2_000_000)
        XCTAssertNil(MetadataFormatter.preferredVideoBitrate(video: nil, format: nil))
    }

    func testPlaybackMathJumpAndShuttle() {
        XCTAssertEqual(PlaybackMath.jump(time: 95, duration: 100, fraction: 0.05), 100)
        XCTAssertEqual(PlaybackMath.jump(time: 2, duration: 100, fraction: -0.05), 0)
        XCTAssertEqual(PlaybackMath.jump(time: 40, duration: 100, fraction: 0.05), 45)
        XCTAssertEqual(PlaybackMath.nextShuttleRate(currentRate: 0, direction: .forward), 1)
        XCTAssertEqual(PlaybackMath.nextShuttleRate(currentRate: 1, direction: .forward), 2)
        XCTAssertEqual(PlaybackMath.nextShuttleRate(currentRate: 4, direction: .forward), 8)
        XCTAssertEqual(PlaybackMath.nextShuttleRate(currentRate: 8, direction: .forward), 8)
        XCTAssertEqual(PlaybackMath.nextShuttleRate(currentRate: 4, direction: .reverse), -1)
        XCTAssertEqual(PlaybackMath.nextShuttleRate(currentRate: -1, direction: .reverse), -2)
    }

    func testVerticalVolumeControlClampsValues() {
        XCTAssertEqual(VolumeControlMath.clamped(-0.2), 0)
        XCTAssertEqual(VolumeControlMath.clamped(0.6), 0.6)
        XCTAssertEqual(VolumeControlMath.clamped(1.2), 1)
    }

    @MainActor
    func testLeftPlaybackControlsWinHitTestingOverVideoCanvas() throws {
        let controller = PreviewController(url: URL(fileURLWithPath: "/tmp/example.mp4"), mediaKind: .video)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_306, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        let volume = try XCTUnwrap(firstDescendant(of: VerticalVolumeControl.self, in: controller.view))
        let mute = try XCTUnwrap(button(titled: "静音", in: controller.view))
        let restart = try XCTUnwrap(button(titled: "↶ 开头", in: controller.view))
        let counterclockwise = try XCTUnwrap(button(titled: "逆90°", in: controller.view))
        let clockwise = try XCTUnwrap(button(titled: "顺90°", in: controller.view))
        let mirror = try XCTUnwrap(button(titled: "镜像", in: controller.view))
        let screenshot = try XCTUnwrap(button(titled: "截图", in: controller.view))
        let transformStack = try XCTUnwrap(counterclockwise.superview as? NSStackView)
        let surface = try XCTUnwrap(firstDescendant(of: ZoomablePlayerSurface.self, in: controller.view))
        let playerView = try XCTUnwrap(firstDescendant(of: AVPlayerView.self, in: controller.view))
        let player = try XCTUnwrap(playerView.player)

        for control in [volume, mute, restart, counterclockwise, clockwise, mirror, screenshot] {
            XCTAssertFalse(control.frame.isEmpty)
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: controller.view)
            XCTAssertTrue(controller.view.hitTest(point) === control)
        }

        let volumeCenter = volume.convert(NSPoint(x: volume.bounds.midX, y: volume.bounds.midY), to: controller.view)
        let counterclockwiseCenter = counterclockwise.convert(NSPoint(x: counterclockwise.bounds.midX, y: counterclockwise.bounds.midY), to: controller.view)
        let clockwiseCenter = clockwise.convert(NSPoint(x: clockwise.bounds.midX, y: clockwise.bounds.midY), to: controller.view)
        let mirrorCenter = mirror.convert(NSPoint(x: mirror.bounds.midX, y: mirror.bounds.midY), to: controller.view)
        let screenshotCenter = screenshot.convert(NSPoint(x: screenshot.bounds.midX, y: screenshot.bounds.midY), to: controller.view)
        let transformStackCenter = transformStack.convert(NSPoint(x: transformStack.bounds.midX, y: transformStack.bounds.midY), to: controller.view)
        let surfaceCenter = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: controller.view)
        XCTAssertFalse(transformStack.frame.isEmpty, "The transform controls must have an arranged, laid-out frame")
        XCTAssertGreaterThan(counterclockwiseCenter.x, volumeCenter.x)
        XCTAssertGreaterThan(transformStackCenter.x, volumeCenter.x)
        XCTAssertLessThan(transformStackCenter.x, surfaceCenter.x)
        XCTAssertGreaterThan(counterclockwiseCenter.y, clockwiseCenter.y)
        XCTAssertGreaterThan(clockwiseCenter.y, mirrorCenter.y)
        XCTAssertGreaterThan(mirrorCenter.y, screenshotCenter.y)
        XCTAssertEqual(surface.displayTransform, VideoDisplayTransform())

        volume.valueChanged?(0.35)
        XCTAssertEqual(player.volume, 0.35, accuracy: 0.001)
        XCTAssertFalse(player.isMuted)
        mute.performClick(nil)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(volume.value, 0, accuracy: 0.001)
        mute.performClick(nil)
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(player.volume, 0.35, accuracy: 0.001)
        XCTAssertEqual(volume.value, 0.35, accuracy: 0.001)

        mute.performClick(nil)
        volume.valueChanged?(0.7)
        XCTAssertFalse(player.isMuted, "An explicit volume adjustment must leave the audible state coherent")
        XCTAssertEqual(player.volume, 0.7, accuracy: 0.001)
        XCTAssertEqual(volume.value, 0.7, accuracy: 0.001)

        clockwise.performClick(nil)
        XCTAssertEqual(surface.displayTransform.quarterTurnsClockwise, 1)
        XCTAssertEqual(surface.playerView.frame.size, CGSize(width: surface.bounds.height, height: surface.bounds.width))
        counterclockwise.performClick(nil)
        XCTAssertEqual(surface.displayTransform.quarterTurnsClockwise, 0)
        mirror.performClick(nil)
        XCTAssertTrue(surface.displayTransform.isMirrored)
        mirror.performClick(nil)
        XCTAssertFalse(surface.displayTransform.isMirrored)
    }

    @MainActor
    func testAudioExportButtonIsAvailableBelowTrimExportForMediaPreview() throws {
        let controller = PreviewController(url: URL(fileURLWithPath: "/tmp/example.mp4"), mediaKind: .video)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_306, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        let trim = try XCTUnwrap(button(titled: "裁切导出…", in: controller.view))
        let audio = try XCTUnwrap(button(titled: "导出音频…", in: controller.view))
        XCTAssertLessThan(audio.frame.midY, trim.frame.midY)
        XCTAssertTrue(audio.isEnabled)

        let audioOnlyController = PreviewController(url: URL(fileURLWithPath: "/tmp/example.m4a"), mediaKind: .audio)
        audioOnlyController.loadViewIfNeeded()
        XCTAssertNil(button(titled: "逆90°", in: audioOnlyController.view))
        XCTAssertNil(button(titled: "顺90°", in: audioOnlyController.view))
        XCTAssertNil(button(titled: "镜像", in: audioOnlyController.view))
        XCTAssertNil(button(titled: "截图", in: audioOnlyController.view))
    }

    func testVideoLoopDefaultsOnWithoutChangingAudioOrImageDefaults() {
        XCTAssertTrue(PlaybackLoopPolicy.defaultLoopEnabled(for: .video))
        XCTAssertFalse(PlaybackLoopPolicy.defaultLoopEnabled(for: .audio))
        XCTAssertFalse(PlaybackLoopPolicy.defaultLoopEnabled(for: .image))
    }

    func testSpaceAtCompletedVideoRestartsOnlyWhenLoopIsOff() {
        XCTAssertEqual(
            PlaybackLoopPolicy.spaceAction(mediaKind: .video, loopEnabled: false, playerRate: 0, currentTime: 10, duration: 10),
            .restartFromBeginning
        )
        XCTAssertEqual(
            PlaybackLoopPolicy.spaceAction(mediaKind: .video, loopEnabled: false, playerRate: 0, currentTime: 9.5, duration: 10),
            .togglePlayback
        )
        XCTAssertEqual(
            PlaybackLoopPolicy.spaceAction(mediaKind: .video, loopEnabled: true, playerRate: 0, currentTime: 10, duration: 10),
            .togglePlayback
        )
        XCTAssertEqual(
            PlaybackLoopPolicy.spaceAction(mediaKind: .audio, loopEnabled: false, playerRate: 0, currentTime: 10, duration: 10),
            .togglePlayback
        )
    }

    func testImageSavePlanUsesNumberedSiblingAndRejectsAnyImplicitOverwrite() {
        let source = URL(fileURLWithPath: "/tmp/画面.jpg")
        let first = URL(fileURLWithPath: "/tmp/画面-1.jpg")
        let second = URL(fileURLWithPath: "/tmp/画面-2.jpg")
        let proposed = ImageSavePlan.suggestedSiblingURL(for: source, fileExists: { $0 == first || $0 == second })

        XCTAssertEqual(proposed, URL(fileURLWithPath: "/tmp/画面-3.jpg"))
        XCTAssertEqual(
            ImageSavePlan.newSaveDecision(sourceURL: source, destinationURL: source, fileExists: { _ in false }),
            .wouldOverwriteSource
        )
        XCTAssertEqual(
            ImageSavePlan.newSaveDecision(sourceURL: source, destinationURL: first, fileExists: { $0 == first }),
            .destinationAlreadyExists
        )
        XCTAssertEqual(
            ImageSavePlan.newSaveDecision(sourceURL: source, destinationURL: proposed, fileExists: { _ in false }),
            .allowed
        )
    }

    func testImageJPEGSavePlanUsesDistinctNumberedNamesAndRejectsImplicitOverwrite() {
        let source = URL(fileURLWithPath: "/tmp/画面.png")
        let conversionOne = URL(fileURLWithPath: "/tmp/画面-JPG-1.jpg")
        let conversionTwo = URL(fileURLWithPath: "/tmp/画面-JPG-2.jpg")
        let compressionOne = URL(fileURLWithPath: "/tmp/画面-压缩-1.jpg")
        let conversion = ImageJPEGSavePlan.suggestedSiblingURL(
            for: source,
            kind: .conversion,
            fileExists: { $0 == conversionOne || $0 == conversionTwo }
        )
        let compression = ImageJPEGSavePlan.suggestedSiblingURL(
            for: source,
            kind: .compression,
            fileExists: { $0 == compressionOne }
        )

        XCTAssertEqual(conversion, URL(fileURLWithPath: "/tmp/画面-JPG-3.jpg"))
        XCTAssertEqual(compression, URL(fileURLWithPath: "/tmp/画面-压缩-2.jpg"))
        XCTAssertEqual(
            ImageJPEGSavePlan.newSaveDecision(sourceURL: source, destinationURL: source, fileExists: { _ in false }),
            .wouldOverwriteSource
        )
        XCTAssertEqual(
            ImageJPEGSavePlan.newSaveDecision(sourceURL: source, destinationURL: conversionOne, fileExists: { $0 == conversionOne }),
            .destinationAlreadyExists
        )
    }

    func testImageJPEGConversionAndCompressionAreReadableStrictlyCappedAndUseTransformedFullRaster() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 60,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<60 {
            for x in 0..<100 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8((x * 31 + y * 17) % 255)
                bytes[offset + 1] = UInt8((x * 11 + y * 43) % 255)
                bytes[offset + 2] = UInt8((x * 47 + y * 7) % 255)
                bytes[offset + 3] = 255
            }
        }
        let transformed = try ImageRasterExporter.renderedImage(
            source: try XCTUnwrap(bitmap.cgImage),
            plan: ImageExportPlan(displayTransform: VideoDisplayTransform(quarterTurnsClockwise: 1, isMirrored: true), crop: nil)
        )
        XCTAssertEqual(transformed.width, 60)
        XCTAssertEqual(transformed.height, 100)

        XCTAssertGreaterThanOrEqual(ImageJPEGExporter.conversionQuality, 0.95)
        let conversion = try ImageJPEGExporter.conversionData(from: transformed)
        let conversionSource = try XCTUnwrap(CGImageSourceCreateWithData(conversion as CFData, nil))
        let conversionImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(conversionSource, 0, nil))
        XCTAssertEqual(CGImageSourceGetType(conversionSource) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(conversionImage.width, 60)
        XCTAssertEqual(conversionImage.height, 100)

        let target = try XCTUnwrap(ImageJPEGCompressionTarget(decimalMegabytes: 0.020))
        XCTAssertEqual(target.requestedBytes, 20_000)
        XCTAssertEqual(target.safetyMarginBytes, 16 * 1024)
        XCTAssertEqual(target.safeCapBytes, 3_616)
        XCTAssertTrue(target.exactTargetDescription.contains("严格小于 3616 bytes"))
        let compressed = try ImageJPEGExporter.compressedData(from: transformed, target: target)
        XCTAssertLessThan(compressed.count, target.safeCapBytes)
        let compressedSource = try XCTUnwrap(CGImageSourceCreateWithData(compressed as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(compressedSource) as String?, UTType.jpeg.identifier)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(compressedSource, 0, nil))
        let compressedProperties = CGImageSourceCopyPropertiesAtIndex(compressedSource, 0, nil) as? [CFString: Any] ?? [:]
        let compressedEXIF = compressedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // ImageIO may synthesize pixel dimensions for a JPEG, but it must not
        // carry user EXIF/TIFF metadata or a stale orientation tag forward.
        XCTAssertNil(compressedEXIF[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(compressedProperties[kCGImagePropertyTIFFDictionary])
        XCTAssertNil(compressedProperties[kCGImagePropertyOrientation])
    }

    func testVideoScreenshotNamingStartsAt001AndSkipsOccupiedSiblings() {
        let source = URL(fileURLWithPath: "/tmp/旅行片段.mov")
        let first = URL(fileURLWithPath: "/tmp/旅行片段-截图-001.jpg")
        let second = URL(fileURLWithPath: "/tmp/旅行片段-截图-002.jpg")

        XCTAssertEqual(VideoFrameScreenshotSavePlan.candidateURL(for: source, number: 1), first)
        XCTAssertEqual(
            VideoFrameScreenshotSavePlan.suggestedSiblingURL(for: source, fileExists: { $0 == first || $0 == second }),
            URL(fileURLWithPath: "/tmp/旅行片段-截图-003.jpg")
        )
    }

    func testVideoScreenshotJPEGIsReadableAtFullTransformedFrameResolution() throws {
        // AVAssetImageGenerator applies the source preferred orientation before
        // this exporter sees its CGImage. A 100×60 natural track with that
        // orientation therefore arrives as 60×100; the user turn swaps it back
        // to 100×60 without dropping pixels or taking a viewport crop.
        let preferredSize = VideoDisplayTransform.preferredDisplaySize(
            naturalSize: CGSize(width: 100, height: 60),
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 60, ty: 0)
        )
        XCTAssertEqual(preferredSize, CGSize(width: 60, height: 100))

        let data = try VideoFrameScreenshotExporter.jpegData(
            from: screenshotFixtureImage(width: 60, height: 100),
            displayTransform: VideoDisplayTransform(quarterTurnsClockwise: 1, isMirrored: true)
        )
        try VideoFrameScreenshotExporter.validateJPEG(data, expectedWidth: 100, expectedHeight: 60)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(image.width * image.height, 60 * 100)
        XCTAssertGreaterThanOrEqual(ImageJPEGExporter.conversionQuality, 0.95)
    }

    func testVideoScreenshotCommitNeverOverwritesSourceOrOccupiedSibling() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MediaPreviewTests.VideoScreenshot.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("原视频.mov", isDirectory: false)
        let occupied = directory.appendingPathComponent("原视频-截图-001.jpg", isDirectory: false)
        let originalSourceData = Data("source movie remains untouched".utf8)
        let occupiedData = Data("existing screenshot remains untouched".utf8)
        try originalSourceData.write(to: source)
        try occupiedData.write(to: occupied)

        let jpegData = try VideoFrameScreenshotExporter.jpegData(
            from: screenshotFixtureImage(width: 80, height: 48),
            displayTransform: VideoDisplayTransform()
        )
        let output = try VideoFrameScreenshotSavePlan.commitJPEGData(jpegData, beside: source)

        XCTAssertEqual(output.lastPathComponent, "原视频-截图-002.jpg")
        XCTAssertEqual(try Data(contentsOf: source), originalSourceData)
        XCTAssertEqual(try Data(contentsOf: occupied), occupiedData)
        try VideoFrameScreenshotExporter.validateJPEG(try Data(contentsOf: output), expectedWidth: 80, expectedHeight: 48)
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".MediaPreview-Screenshot-") })
    }

    func testVideoScreenshotCaptureGateRejectsConcurrentRequestUntilFinished() {
        var gate = VideoFrameScreenshotCaptureGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isPending)
        XCTAssertFalse(gate.begin())
        gate.finish()
        XCTAssertFalse(gate.isPending)
        XCTAssertTrue(gate.begin())
    }

    func testImageJPEGCompressionRejectsAnImpossibleExclusiveCap() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let target = try XCTUnwrap(ImageJPEGCompressionTarget(decimalMegabytes: 0.0001))
        XCTAssertEqual(target.safeCapBytes, 1)
        XCTAssertThrowsError(try ImageJPEGExporter.compressedData(from: try XCTUnwrap(bitmap.cgImage), target: target)) { error in
            guard case .impossibleCompressionCap = error as? ImageJPEGExportError else {
                return XCTFail("Expected a clear impossible-cap rejection, got \(error)")
            }
        }
    }

    func testImageExportPlanAppliesCropOnTheTransformedDisplayCanvas() throws {
        let source = CGSize(width: 20, height: 10)
        let crop = VideoCropSelection(
            preset: .free,
            sourceRect: CGRect(x: 2, y: 4, width: 6, height: 8),
            canvasSize: CGSize(width: 10, height: 20)
        )
        let plan = ImageExportPlan(displayTransform: VideoDisplayTransform(quarterTurnsClockwise: 1, isMirrored: true), crop: crop)

        XCTAssertEqual(plan.canvasSize(for: source), CGSize(width: 10, height: 20))
        XCTAssertEqual(try XCTUnwrap(plan.cropRect(for: source)), crop.sourceRect)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 20,
            pixelsHigh: 10,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let rendered = try ImageRasterExporter.renderedImage(source: try XCTUnwrap(bitmap.cgImage), plan: plan)
        XCTAssertEqual(rendered.width, 6)
        XCTAssertEqual(rendered.height, 8)
        XCTAssertNil(
            ImageExportPlan(
                displayTransform: VideoDisplayTransform(quarterTurnsClockwise: 1),
                crop: VideoCropSelection(preset: .free, sourceRect: CGRect(x: 8, y: 18, width: 4, height: 4))
            ).cropRect(for: source)
        )
    }

    func testImageRasterExporterWritesTransformedCropAsValidPNG() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("MediaPreviewTests.ImageExport.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 6,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytesPerPixel = 4
        let bytesPerRow = bitmap.bytesPerRow
        let data = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<6 {
            for x in 0..<8 {
                let offset = y * bytesPerRow + x * bytesPerPixel
                data[offset] = UInt8(x * 29)
                data[offset + 1] = UInt8(y * 41)
                data[offset + 2] = UInt8((x + y) * 17)
                data[offset + 3] = 255
            }
        }

        let plan = ImageExportPlan(
            displayTransform: VideoDisplayTransform(quarterTurnsClockwise: 1, isMirrored: true),
            crop: VideoCropSelection(preset: .free, sourceRect: CGRect(x: 1, y: 2, width: 4, height: 4), canvasSize: CGSize(width: 6, height: 8))
        )
        let rendered = try ImageRasterExporter.renderedImage(source: try XCTUnwrap(bitmap.cgImage), plan: plan)
        let outputURL = temporaryDirectory.appendingPathComponent("transformed-crop.png", isDirectory: false)
        try ImageRasterExporter.write(rendered, typeIdentifier: UTType.png.identifier as CFString, properties: nil, to: outputURL)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let readback = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(readback.width, 4)
        XCTAssertEqual(readback.height, 4)
    }

    @MainActor
    func testImagePreviewAddsImageTransformAndRightSideSaveControls() throws {
        let controller = PreviewController(url: URL(fileURLWithPath: "/tmp/example.jpg"), mediaKind: .image)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_306, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        let counterclockwise = try XCTUnwrap(button(titled: "逆90°", in: controller.view))
        let clockwise = try XCTUnwrap(button(titled: "顺90°", in: controller.view))
        let mirror = try XCTUnwrap(button(titled: "镜像", in: controller.view))
        let cropSave = try XCTUnwrap(button(titled: "裁切保存…", in: controller.view))
        let convertJPEG = try XCTUnwrap(button(titled: "转 JPG", in: controller.view))
        let compressJPEG = try XCTUnwrap(button(titled: "压缩图片…", in: controller.view))
        XCTAssertNil(button(titled: "截图", in: controller.view))
        let surface = try XCTUnwrap(firstDescendant(of: ZoomableImageSurface.self, in: controller.view))

        let counterclockwiseCenter = counterclockwise.convert(NSPoint(x: counterclockwise.bounds.midX, y: counterclockwise.bounds.midY), to: controller.view)
        let cropSaveCenter = cropSave.convert(NSPoint(x: cropSave.bounds.midX, y: cropSave.bounds.midY), to: controller.view)
        let convertJPEGCenter = convertJPEG.convert(NSPoint(x: convertJPEG.bounds.midX, y: convertJPEG.bounds.midY), to: controller.view)
        let compressJPEGCenter = compressJPEG.convert(NSPoint(x: compressJPEG.bounds.midX, y: compressJPEG.bounds.midY), to: controller.view)
        let surfaceCenter = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: controller.view)
        XCTAssertLessThan(counterclockwiseCenter.x, surfaceCenter.x)
        XCTAssertGreaterThan(cropSaveCenter.x, surfaceCenter.x)
        XCTAssertGreaterThan(convertJPEGCenter.x, surfaceCenter.x)
        XCTAssertGreaterThan(compressJPEGCenter.x, surfaceCenter.x)
        XCTAssertTrue(controller.view.hitTest(counterclockwiseCenter) === counterclockwise)
        XCTAssertTrue(controller.view.hitTest(cropSaveCenter) === cropSave)
        XCTAssertTrue(controller.view.hitTest(convertJPEGCenter) === convertJPEG)
        XCTAssertTrue(controller.view.hitTest(compressJPEGCenter) === compressJPEG)
        XCTAssertNil(button(titled: "循环", in: controller.view))
        XCTAssertNil(button(titled: "裁切导出…", in: controller.view))
        XCTAssertNil(button(titled: "导出音频…", in: controller.view))

        clockwise.performClick(nil)
        XCTAssertEqual(surface.displayTransform.quarterTurnsClockwise, 1)
        XCTAssertEqual(surface.imageView.frame.size, CGSize(width: surface.bounds.height, height: surface.bounds.width))
        counterclockwise.performClick(nil)
        mirror.performClick(nil)
        XCTAssertTrue(surface.displayTransform.isMirrored)
    }

    func testABLoopNormalizationAndWaveform() {
        XCTAssertEqual(ABLoopMath.normalized(a: 8, b: 2, duration: 10), 2...8)
        XCTAssertNil(ABLoopMath.normalized(a: 2, b: 2, duration: 10))
        XCTAssertNil(ABLoopMath.normalized(a: 2, b: 4, duration: 0))
        XCTAssertEqual(WaveformMath.bars(count: 12).count, 12)
        XCTAssertTrue(WaveformMath.bars(count: 12).allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testABTrimExportPlanAcceptsOnlyAValidOrderedRangeWithinDuration() throws {
        let range = try XCTUnwrap(ABTrimExportPlan.timeRange(a: 2.25, b: 7.5, duration: 10))
        XCTAssertEqual(range.start.seconds, 2.25, accuracy: 0.001)
        XCTAssertEqual(range.duration.seconds, 5.25, accuracy: 0.001)
        XCTAssertNil(ABTrimExportPlan.timeRange(a: nil, b: 7.5, duration: 10))
        XCTAssertNil(ABTrimExportPlan.timeRange(a: 7.5, b: 7.5, duration: 10))
        XCTAssertNil(ABTrimExportPlan.timeRange(a: 2, b: 11, duration: 10))
        XCTAssertNil(ABTrimExportPlan.timeRange(a: 2, b: 7, duration: 0))
    }

    func testABTrimExportPlanSuggestsSiblingMovieWithoutChangingSource() {
        let source = URL(fileURLWithPath: "/tmp/采访最终版.mp4")
        XCTAssertEqual(ABTrimExportPlan.suggestedFilename(for: source, fileExtension: "mp4"), "采访最终版-AB剪辑.mp4")
        XCTAssertEqual(ABTrimExportPlan.suggestedOutputURL(for: source, fileExtension: "mp4"), URL(fileURLWithPath: "/tmp/采访最终版-AB剪辑.mp4"))
    }

    func testFFmpegTrimPlanUsesAValidOutputExtensionAndExplicitVideoQuality() throws {
        let video = try XCTUnwrap(FFmpegTrimExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/original.avi"), mediaKind: .video))
        XCTAssertEqual(video.fileExtension, "mp4")
        XCTAssertTrue(video.savePanelMessage.contains("CRF 18"))
        let arguments = video.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/input video.avi"),
            destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            timeRange: CMTimeRange(start: CMTime(seconds: 2.25, preferredTimescale: 600), duration: CMTime(seconds: 4.5, preferredTimescale: 600))
        )
        XCTAssertEqual(Array(arguments.suffix(2)), ["-n", "/tmp/output.mp4"])
        XCTAssertTrue(arguments.contains("libx264"))
        XCTAssertTrue(arguments.contains("-ss"))
        XCTAssertTrue(arguments.contains("2.250000"))
        XCTAssertTrue(arguments.contains("-t"))
        XCTAssertTrue(arguments.contains("4.500000"))
        XCTAssertFalse(arguments.contains("-vf"), "No crop must preserve the existing unfiltered export path")
        XCTAssertFalse(arguments.contains("-noautorotate"))
    }

    func testVideoCropPresetsUseCenteredMaximumEvenSourceRasters() throws {
        let source = CGSize(width: 1_920, height: 1_080)
        let square = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 1))
        XCTAssertEqual(square, CGRect(x: 420, y: 0, width: 1_080, height: 1_080))

        let standard = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 4.0 / 3.0))
        XCTAssertEqual(standard, CGRect(x: 240, y: 0, width: 1_440, height: 1_080))

        let verticalStandard = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 3.0 / 4.0))
        XCTAssertEqual(verticalStandard, CGRect(x: 554, y: 0, width: 810, height: 1_080))

        let widescreen = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 16.0 / 9.0))
        XCTAssertEqual(widescreen, CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        let cinema = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 2.39))
        XCTAssertEqual(cinema, CGRect(x: 0, y: 138, width: 1_920, height: 804))

        let portraitSource = CGSize(width: 1_080, height: 1_920)
        let portraitWidescreen = try XCTUnwrap(VideoCropMath.maximumCrop(in: portraitSource, aspectRatio: 16.0 / 9.0))
        XCTAssertEqual(portraitWidescreen, CGRect(x: 0, y: 656, width: 1_080, height: 608))
    }

    func testCropOrientationTitlesReorientationAndRestorePreserveTheFixedRatio() throws {
        XCTAssertEqual(VideoCropPreset.standardFourByThree.title(for: .horizontal), "4:3")
        XCTAssertEqual(VideoCropPreset.standardFourByThree.title(for: .vertical), "3:4")
        XCTAssertEqual(VideoCropPreset.widescreenSixteenByNine.title(for: .horizontal), "16:9")
        XCTAssertEqual(VideoCropPreset.widescreenSixteenByNine.title(for: .vertical), "9:16")
        XCTAssertEqual(VideoCropPreset.cinema239.title(for: .horizontal), "2.39:1")
        XCTAssertEqual(VideoCropPreset.cinema239.title(for: .vertical), "1:2.39")

        let source = CGSize(width: 1_920, height: 1_080)
        let horizontalRect = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 4.0 / 3.0))
        let pannedRect = try XCTUnwrap(VideoCropMath.moved(horizontalRect, by: CGPoint(x: 120, y: 0), in: source))
        let horizontal = VideoCropSelection(
            preset: .standardFourByThree,
            orientation: .horizontal,
            sourceRect: pannedRect,
            canvasSize: source
        )

        let vertical = try XCTUnwrap(horizontal.reoriented(to: .vertical, in: source))
        XCTAssertEqual(vertical.preset, .standardFourByThree)
        XCTAssertEqual(vertical.orientation, .vertical)
        XCTAssertEqual(try XCTUnwrap(vertical.aspectRatio), 3.0 / 4.0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(VideoCropMath.displayRatio(for: vertical.sourceRect)), 3.0 / 4.0, accuracy: 0.000_001)

        let reopened = try XCTUnwrap(vertical.restored(in: source))
        XCTAssertEqual(reopened.preset, .standardFourByThree)
        XCTAssertEqual(reopened.orientation, .vertical)
        XCTAssertEqual(try XCTUnwrap(reopened.aspectRatio), 3.0 / 4.0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(VideoCropMath.displayRatio(for: reopened.sourceRect)), 3.0 / 4.0, accuracy: 0.000_001)
    }

    func testFreeCropClampsAndAlignsAllYUV420CoordinatesToEvenPixels() throws {
        let source = CGSize(width: 1_920, height: 1_080)
        let aligned = try XCTUnwrap(VideoCropMath.aligned(CGRect(x: 3, y: 5, width: 1_079, height: 803), in: source))
        XCTAssertEqual(aligned, CGRect(x: 2, y: 4, width: 1_078, height: 802))

        let moved = try XCTUnwrap(VideoCropMath.moved(aligned, by: CGPoint(x: 2_000, y: 2_000), in: source))
        XCTAssertEqual(moved, CGRect(x: 842, y: 278, width: 1_078, height: 802))

        let resized = try XCTUnwrap(VideoCropMath.resized(moved, handle: .topLeft, by: CGPoint(x: -2_000, y: -2_000), in: source))
        XCTAssertEqual(resized.minX, 0)
        XCTAssertEqual(resized.minY, 0)
        XCTAssertEqual(Int(resized.width) % 2, 0)
        XCTAssertEqual(Int(resized.height) % 2, 0)
        XCTAssertEqual(Int(resized.minX) % 2, 0)
        XCTAssertEqual(Int(resized.minY) % 2, 0)
        XCTAssertLessThanOrEqual(resized.maxX, source.width)
        XCTAssertLessThanOrEqual(resized.maxY, source.height)
    }

    func testFixedCropPresetRemainsLockedAfterPanAndFreeModeIsRequiredToResize() throws {
        let source = CGSize(width: 1_920, height: 1_080)
        let cinema = try XCTUnwrap(VideoCropMath.maximumCrop(in: source, aspectRatio: 2.39))
        let panned = try XCTUnwrap(VideoCropMath.moved(cinema, by: CGPoint(x: 120, y: -40), in: source))

        XCTAssertFalse(VideoCropEditorInteraction.allowsResize(for: .cinema239))
        XCTAssertEqual(VideoCropEditorInteraction.pan.resultingPreset(from: .cinema239), .cinema239)
        XCTAssertEqual(
            try XCTUnwrap(VideoCropMath.displayRatio(for: panned)),
            try XCTUnwrap(VideoCropMath.displayRatio(for: cinema)),
            accuracy: 0.000_001
        )

        XCTAssertTrue(VideoCropEditorInteraction.allowsResize(for: .free))
        XCTAssertEqual(VideoCropEditorInteraction.resize.resultingPreset(from: .free), .free)
        let freeResized = try XCTUnwrap(VideoCropMath.resized(panned, handle: .bottomRight, by: CGPoint(x: -120, y: -100), in: source))
        XCTAssertNotEqual(
            try XCTUnwrap(VideoCropMath.displayRatio(for: freeResized)),
            try XCTUnwrap(VideoCropMath.displayRatio(for: cinema))
        )
    }

    func testVideoCropFilterIsAppliedOnlyToVideoExportWithoutScaling() throws {
        let plan = try XCTUnwrap(FFmpegTrimExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/original.mp4"), mediaKind: .video))
        let crop = VideoCropSelection(
            preset: .cinema239,
            orientation: .horizontal,
            sourceRect: CGRect(x: 120, y: 200, width: 800, height: 600),
            canvasSize: CGSize(width: 1_080, height: 1_920)
        )
        let transform = VideoDisplayTransform(quarterTurnsClockwise: 1, isMirrored: true)
        let arguments = plan.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/original.mp4"),
            destinationURL: URL(fileURLWithPath: "/tmp/export.mp4"),
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)),
            crop: crop,
            displayTransform: transform
        )
        let filterIndex = try XCTUnwrap(arguments.firstIndex(of: "-vf"))
        XCTAssertEqual(arguments[filterIndex + 1], "transpose=1,hflip,crop=w=800:h=600:x=120:y=200:exact=1,setsar=1")
        XCTAssertFalse(arguments.contains("-noautorotate"))
        let metadataIndex = try XCTUnwrap(arguments.firstIndex(of: "-metadata:s:v:0"))
        XCTAssertEqual(arguments[metadataIndex + 1], "rotate=0")
        XCTAssertFalse(arguments.contains { $0.contains("scale=") })
        XCTAssertTrue(arguments.contains("libx264"))
    }

    func testVideoDisplayTransformMapsQuarterTurnsAndMirrorBeforeCrop() {
        let source = CGSize(width: 1_920, height: 1_080)
        let rect = CGRect(x: 100, y: 200, width: 400, height: 600)

        let identity = VideoDisplayTransform()
        XCTAssertTrue(identity.isIdentity)
        XCTAssertEqual(identity.outputSize(for: source), source)
        XCTAssertEqual(identity.ffmpegFilterComponents, [])
        XCTAssertEqual(identity.transformedRect(rect, in: source), rect)

        let clockwise = VideoDisplayTransform(quarterTurnsClockwise: 1)
        XCTAssertEqual(clockwise.outputSize(for: source), CGSize(width: 1_080, height: 1_920))
        XCTAssertEqual(clockwise.ffmpegFilterComponents, ["transpose=1"])
        XCTAssertEqual(clockwise.transformedRect(rect, in: source), CGRect(x: 280, y: 100, width: 600, height: 400))

        let upsideDown = VideoDisplayTransform(quarterTurnsClockwise: 2)
        XCTAssertEqual(upsideDown.ffmpegFilterComponents, ["hflip", "vflip"])
        XCTAssertEqual(upsideDown.transformedRect(rect, in: source), CGRect(x: 1_420, y: 280, width: 400, height: 600))

        let counterclockwise = VideoDisplayTransform(quarterTurnsClockwise: -1)
        XCTAssertEqual(counterclockwise.ffmpegFilterComponents, ["transpose=2"])
        XCTAssertEqual(counterclockwise.transformedRect(rect, in: source), CGRect(x: 200, y: 1_420, width: 600, height: 400))

        let clockwiseMirrored = VideoDisplayTransform(quarterTurnsClockwise: 1, isMirrored: true)
        XCTAssertEqual(clockwiseMirrored.ffmpegFilterComponents, ["transpose=1", "hflip"])
        XCTAssertEqual(clockwiseMirrored.transformedRect(rect, in: source), CGRect(x: 200, y: 100, width: 600, height: 400))
    }

    func testVideoExportCompletionPresentationOnlyMarksSuccessComplete() {
        let completed = VideoExportStatusPresentation.completed(destination: URL(fileURLWithPath: "/tmp/镜头-AB剪辑.mp4"))
        XCTAssertEqual(completed, "已完成 · 镜头-AB剪辑.mp4")
        XCTAssertEqual(VideoExportStatusPresentation.cancelled, "已取消导出")
        XCTAssertFalse(VideoExportStatusPresentation.cancelled.contains("已完成"))
    }

    func testFFmpegProgressParserBuffersPartialLinesAndNeverReportsCompletionEarly() {
        var parser = FFmpegProgressParser()
        XCTAssertEqual(parser.consume(Data("out_time_us=500".utf8), totalSeconds: 1), [])
        XCTAssertEqual(parser.consume(Data("000\nprogress=continue\nout_time_us=2000000\n".utf8), totalSeconds: 1), [0.5, 0.999])
        XCTAssertEqual(parser.consume(Data("out_time_us=N/A\n".utf8), totalSeconds: 1), [])
    }

    @MainActor
    func testVideoExportProgressAndCropEditorControlsArePresent() throws {
        let controller = PreviewController(url: URL(fileURLWithPath: "/tmp/example.mp4"), mediaKind: .video)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_306, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        let progress = try XCTUnwrap(firstDescendant(of: NSProgressIndicator.self, in: controller.view))
        XCTAssertFalse(progress.isIndeterminate)
        XCTAssertEqual(progress.minValue, 0)
        XCTAssertEqual(progress.maxValue, 100)
        XCTAssertTrue(progress.isHidden)
        XCTAssertNotNil(button(titled: "取消导出", in: controller.view))

        let editor = CropEditorSheetController(sourceSize: CGSize(width: 1_920, height: 1_080), previewImage: nil, initialSelection: nil) { _ in }
        _ = editor.view
        for title in ["原始画幅", "1:1", "4:3", "16:9", "2.39:1", "自由框选", "继续导出…"] {
            XCTAssertNotNil(button(titled: title, in: editor.view), "Missing crop editor control: \(title)")
        }
        let orientation = try XCTUnwrap(firstDescendant(of: NSSegmentedControl.self, in: editor.view))
        XCTAssertEqual(orientation.label(forSegment: 0), "横向")
        XCTAssertEqual(orientation.label(forSegment: 1), "纵向")
        XCTAssertEqual(orientation.segmentCount, 2)
    }

    func testFFmpegTrimPlanSupportsM4AMP3AndWAVAudio() throws {
        let fixtures: [(String, String, String)] = [("m4a", "aac", "256k"), ("mp3", "libmp3lame", "2"), ("wav", "pcm_s16le", "pcm_s16le")]
        for (extensionName, codec, expectedArgument) in fixtures {
            let plan = try XCTUnwrap(FFmpegTrimExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/audio.\(extensionName)"), mediaKind: .audio))
            XCTAssertEqual(plan.fileExtension, extensionName)
            XCTAssertTrue(plan.savePanelMessage.contains("精确 A/B 音频裁切"))
            let arguments = plan.arguments(sourceURL: URL(fileURLWithPath: "/tmp/input.\(extensionName)"), destinationURL: URL(fileURLWithPath: "/tmp/output.\(extensionName)"), timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)))
            XCTAssertTrue(arguments.contains(codec))
            XCTAssertTrue(arguments.contains(expectedArgument))
            XCTAssertTrue(arguments.contains("-vn"))
        }
        XCTAssertEqual(FFmpegTrimExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/audio.flac"), mediaKind: .audio)?.fileExtension, "m4a")
        XCTAssertTrue(ABTrimExportError.ffmpegUnavailable.localizedDescription.contains("安装 FFmpeg.command"))
    }

    func testFFmpegAudioExportPlanPreservesAudioByStreamCopyForFullExport() {
        let source = URL(fileURLWithPath: "/tmp/input movie.mp4")
        let destination = URL(fileURLWithPath: "/tmp/input movie-音频.m4a")
        let plan = FFmpegAudioExportPlan.make(sourceURL: source, timeRange: nil)

        XCTAssertEqual(plan.fileExtension, "m4a")
        XCTAssertFalse(plan.isABExport)
        XCTAssertEqual(plan.suggestedFilename(for: source), "input movie-音频.m4a")
        XCTAssertTrue(plan.savePanelMessage.contains("不会重编码"))
        let arguments = plan.arguments(sourceURL: source, destinationURL: destination)
        XCTAssertTrue(arguments.contains("0:a:0?"))
        XCTAssertTrue(arguments.contains("-vn"))
        XCTAssertTrue(arguments.contains("copy"))
        XCTAssertFalse(arguments.contains("-ss"), "Whole-file export must not seek or truncate")
        XCTAssertFalse(arguments.contains("-t"), "Whole-file export must not seek or truncate")
        XCTAssertEqual(Array(arguments.suffix(2)), ["-n", destination.path])
    }

    func testFFmpegAudioExportPlanUsesPacketBoundedABRangeWithoutTranscoding() {
        let source = URL(fileURLWithPath: "/tmp/interview.mp3")
        let range = CMTimeRange(start: CMTime(seconds: 2.25, preferredTimescale: 600), duration: CMTime(seconds: 4.5, preferredTimescale: 600))
        let plan = FFmpegAudioExportPlan.make(sourceURL: source, timeRange: range)
        let arguments = plan.arguments(sourceURL: source, destinationURL: URL(fileURLWithPath: "/tmp/interview-AB音频.mp3"))

        XCTAssertEqual(plan.fileExtension, "mp3")
        XCTAssertTrue(plan.isABExport)
        XCTAssertEqual(plan.suggestedFilename(for: source), "interview-AB音频.mp3")
        XCTAssertTrue(plan.savePanelMessage.contains("编码包边界"))
        XCTAssertTrue(arguments.contains("-ss"))
        XCTAssertTrue(arguments.contains("2.250000"))
        XCTAssertTrue(arguments.contains("-t"))
        XCTAssertTrue(arguments.contains("4.500000"))
        XCTAssertTrue(arguments.contains("-c:a"))
        XCTAssertTrue(arguments.contains("copy"))
        XCTAssertFalse(arguments.contains("aac"))
        XCTAssertFalse(arguments.contains("libmp3lame"))
    }

    func testFFmpegAudioExportPlanChoosesAudioFriendlyContainersAndReportsStreamCopyFailures() {
        XCTAssertEqual(FFmpegAudioExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), timeRange: nil).fileExtension, "m4a")
        XCTAssertEqual(FFmpegAudioExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/source.wav"), timeRange: nil).fileExtension, "wav")
        XCTAssertEqual(FFmpegAudioExportPlan.make(sourceURL: URL(fileURLWithPath: "/tmp/source.flac"), timeRange: nil).fileExtension, "mka")
        XCTAssertTrue(ABTrimExportError.noAudioTrack.localizedDescription.contains("音频轨道"))
        XCTAssertTrue(ABTrimExportError.audioStreamCopyFailed("muxer does not support codec").localizedDescription.contains("未进行重编码"))
    }

    func testFFmpegAndFFprobeLocatorsPrioritizeUserManagedDirectoryThenStandardAndPATHWithoutDuplicates() {
        let home = "/Users/example"
        let managedDirectory = "\(home)/Library/Application Support/Finder Media Preview/bin"
        let environment = [
            "HOME": home,
            "PATH": "/custom/bin:\(managedDirectory):/opt/homebrew/bin:/custom/bin"
        ]

        let ffmpeg = FFmpegLocator.candidateURLs(environment: environment)
        XCTAssertEqual(ffmpeg.first?.path, "\(managedDirectory)/ffmpeg")
        XCTAssertTrue(ffmpeg.contains(URL(fileURLWithPath: "/custom/bin/ffmpeg")))
        XCTAssertEqual(ffmpeg.filter { $0.path == "\(managedDirectory)/ffmpeg" }.count, 1)
        XCTAssertEqual(ffmpeg.filter { $0.path == "/opt/homebrew/bin/ffmpeg" }.count, 1)

        let ffprobe = FFprobe.candidateURLs(environment: environment)
        XCTAssertEqual(ffprobe.first?.path, "\(managedDirectory)/ffprobe")
        XCTAssertTrue(ffprobe.contains(URL(fileURLWithPath: "/custom/bin/ffprobe")))
        XCTAssertEqual(ffprobe.filter { $0.path == "\(managedDirectory)/ffprobe" }.count, 1)
        XCTAssertEqual(ffprobe.filter { $0.path == "/opt/homebrew/bin/ffprobe" }.count, 1)
    }

    func testABMarkersRenderIndividuallyBeforeTheRangeIsComplete() {
        var markers = ABMarkerState()
        XCTAssertTrue(markers.setA(at: 2.5))
        XCTAssertEqual(markers.renderState(duration: 10), ABMarkerRenderState(a: 0.25, b: nil))
        XCTAssertNil(markers.renderState(duration: 10).range)

        markers.clear()
        XCTAssertTrue(markers.setB(at: 7.5))
        XCTAssertEqual(markers.renderState(duration: 10), ABMarkerRenderState(a: nil, b: 0.75))
        XCTAssertNil(markers.renderState(duration: 10).range)
    }

    func testABMarkerEditsWithBothMarkersFollowStrictPositionRules() {
        var markers = ABMarkerState()
        XCTAssertTrue(markers.setA(at: 3))
        XCTAssertTrue(markers.setB(at: 7))

        XCTAssertTrue(markers.setA(at: 1), "Before A, I moves A left")
        XCTAssertEqual(markers.pointA, 1)
        XCTAssertFalse(markers.setB(at: 0), "Before A, O is ignored")
        XCTAssertEqual(markers.pointB, 7)

        XCTAssertTrue(markers.setA(at: 4), "Inside the range, I moves A right")
        XCTAssertEqual(markers.pointA, 4)
        XCTAssertTrue(markers.setB(at: 6), "Inside the range, O moves B left")
        XCTAssertEqual(markers.pointB, 6)

        XCTAssertFalse(markers.setA(at: 8), "After B, I is ignored")
        XCTAssertEqual(markers.pointA, 4)
        XCTAssertTrue(markers.setB(at: 9), "After B, O moves B right")
        XCTAssertEqual(markers.pointB, 9)
        XCTAssertEqual(markers.renderState(duration: 10).range, 0.4...0.9)
    }

    func testABMarkerEditsRejectCrossingAndPreserveExistingPoints() {
        var markers = ABMarkerState()
        XCTAssertTrue(markers.setA(at: 3))
        XCTAssertTrue(markers.setB(at: 7))

        XCTAssertFalse(markers.setA(at: 7))
        XCTAssertFalse(markers.setB(at: 3))
        XCTAssertFalse(markers.setA(at: 3))
        XCTAssertFalse(markers.setB(at: 7))
        XCTAssertEqual(markers, ABMarkerState(pointA: 3, pointB: 7))
    }

    func testABMarkerInitialAndClearBehaviorKeepsPotentialRangesValid() {
        var markers = ABMarkerState()
        XCTAssertTrue(markers.setB(at: 6))
        XCTAssertFalse(markers.setA(at: 6))
        XCTAssertFalse(markers.setA(at: 8))
        XCTAssertTrue(markers.setA(at: 2))
        XCTAssertEqual(markers, ABMarkerState(pointA: 2, pointB: 6))

        markers.clear()
        XCTAssertEqual(markers, ABMarkerState())
        XCTAssertTrue(markers.setA(at: 4))
        XCTAssertFalse(markers.setB(at: 4))
        XCTAssertFalse(markers.setB(at: 1))
        XCTAssertTrue(markers.setB(at: 8))
        XCTAssertEqual(markers, ABMarkerState(pointA: 4, pointB: 8))
    }

    func testABLoopRestartTargetNormalizesReversedAndFallsBackForInvalidRanges() {
        XCTAssertEqual(ABLoopMath.restartTarget(time: 8, a: 8, b: 2, duration: 10), 2)
        XCTAssertNil(ABLoopMath.restartTarget(time: 7.9, a: 8, b: 2, duration: 10))
        XCTAssertEqual(ABLoopMath.restartTarget(time: 10, a: 2, b: 2, duration: 10), 0)
        XCTAssertEqual(ABLoopMath.restartTarget(time: 10, a: nil, b: 4, duration: 10), 0)
        XCTAssertEqual(ABLoopMath.endTarget(a: 8, b: 2, duration: 10), 2)
    }

    func testABLoopExactSeekPausesThenSeeksOnceAndResumesOnlyAfterSuccessfulCompletion() {
        var coordinator = ABLoopExactSeekCoordinator()
        let target = try? XCTUnwrap(ABLoopMath.restartTarget(time: 8, a: 8, b: 2, duration: 10))
        let command = coordinator.begin(targetSeconds: target ?? -1, resumeRate: 1.25)

        let request: ABLoopExactSeekRequest
        guard case let .pauseAndSeek(value)? = command else {
            return XCTFail("A loop crossing must pause before starting its exact seek")
        }
        request = value
        XCTAssertEqual(request.targetSeconds, 2)
        XCTAssertEqual(request.targetTime.timescale, 600)
        XCTAssertEqual(CMTimeCompare(request.targetTime, CMTime(seconds: 2, preferredTimescale: 600)), 0)
        XCTAssertEqual(CMTimeCompare(request.tolerance, .zero), 0)
        XCTAssertTrue(coordinator.isSeeking)
        XCTAssertNil(coordinator.begin(targetSeconds: 2, resumeRate: 1.25), "Periodic observer reentrance must not start another seek")
        XCTAssertNil(coordinator.finish(request, completed: false), "A failed seek must not resume playback")
        XCTAssertFalse(coordinator.isSeeking)

        guard case let .pauseAndSeek(successfulRequest)? = coordinator.begin(targetSeconds: 2, resumeRate: 1.25) else {
            return XCTFail("A new loop should be accepted after the previous completion")
        }
        XCTAssertEqual(coordinator.finish(successfulRequest, completed: true), .resume(1.25))
        XCTAssertNil(coordinator.finish(successfulRequest, completed: true), "A completion can resume playback only once")
    }

    func testCancellingABLoopSeekOnlyReportsAnActualPendingRequest() {
        var coordinator = ABLoopExactSeekCoordinator()
        XCTAssertFalse(coordinator.cancel())

        guard case let .pauseAndSeek(request)? = coordinator.begin(targetSeconds: 2, resumeRate: 1) else {
            return XCTFail("A valid loop target must create a pending seek")
        }
        XCTAssertTrue(coordinator.cancel())
        XCTAssertFalse(coordinator.isSeeking)
        XCTAssertNil(coordinator.finish(request, completed: true), "A callback from a cancelled seek must not restart playback")
        XCTAssertFalse(coordinator.cancel())
    }

    func testUsageManualLocatorPrefersPDFThenFallsBackToMarkdown() {
        let bundle = URL(fileURLWithPath: "/Applications/Finder Media Preview.app", isDirectory: true)
        let workingDirectory = URL(fileURLWithPath: "/project", isDirectory: true)
        let localMarkdown = workingDirectory.appendingPathComponent("Docs/使用说明.md")
        XCTAssertEqual(
            UsageManualLocator.manualURL(bundleURL: bundle, workingDirectory: workingDirectory, exists: { $0 == localMarkdown }),
            localMarkdown
        )

        let siblingPDF = bundle.deletingLastPathComponent().appendingPathComponent("使用说明.pdf")
        XCTAssertEqual(
            UsageManualLocator.manualURL(bundleURL: bundle, workingDirectory: workingDirectory, exists: { $0 == siblingPDF || $0 == localMarkdown }),
            siblingPDF
        )
    }

    func testFFmpegInstallScriptLocatorFindsBundledOrDevelopmentScript() {
        let bundle = URL(fileURLWithPath: "/Applications/Finder Media Preview.app", isDirectory: true)
        let workingDirectory = URL(fileURLWithPath: "/project", isDirectory: true)
        let developmentScript = workingDirectory.appendingPathComponent("Scripts/安装 FFmpeg.command")
        XCTAssertEqual(
            FFmpegInstallScriptLocator.scriptURL(bundleURL: bundle, workingDirectory: workingDirectory, exists: { $0 == developmentScript }),
            developmentScript
        )
        let bundledScript = bundle.appendingPathComponent("Contents/Resources/安装 FFmpeg.command")
        XCTAssertEqual(
            FFmpegInstallScriptLocator.scriptURL(bundleURL: bundle, workingDirectory: workingDirectory, exists: { $0 == bundledScript || $0 == developmentScript }),
            bundledScript
        )
    }

    @MainActor
    func testFilenameDisplayIsTopRightTwoLineAndProvidesFullNameTooltip() throws {
        let filename = "一份特别特别特别长的媒体文件名称，用于检查右上角显示不会遮挡其他控件.mp4"
        let controller = PreviewController(url: URL(fileURLWithPath: "/tmp/\(filename)"), mediaKind: .video)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_306, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(firstDescendant(of: NSTextField.self, in: controller.view) { $0.stringValue == filename })
        XCTAssertEqual(label.toolTip, filename)
        XCTAssertEqual(label.maximumNumberOfLines, 2)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
        XCTAssertGreaterThan(label.frame.maxX, controller.view.bounds.midX)
        XCTAssertLessThanOrEqual(label.frame.maxX, controller.view.bounds.maxX)
    }

    func testSpeedOrderAndKeyboardRouting() {
        XCTAssertEqual(PlaybackMath.speedOrder, [8, 4, 2, 1.5, 1.25, 1, 0.75, 0.5])
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 49, modifiers: []), .togglePlayback)
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 12, modifiers: [.command]), .close)
        XCTAssertNil(PreviewKeyRouting.command(keyCode: 123, modifiers: []))
        XCTAssertNil(PreviewKeyRouting.command(keyCode: 124, modifiers: []))
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 123, modifiers: [.command]), .jump(-0.05))
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 124, modifiers: [.command]), .jump(0.05))
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 38, modifiers: []), .shuttle(.reverse))
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 40, modifiers: []), .pause)
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 37, modifiers: []), .shuttle(.forward))
        XCTAssertNil(PreviewKeyRouting.command(keyCode: 53, modifiers: []))
        XCTAssertNil(PreviewKeyRouting.command(keyCode: 123, modifiers: [.function]))
        XCTAssertNil(PreviewKeyRouting.command(keyCode: 124, modifiers: [.function]))
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 123, modifiers: [.function, .command]), .jump(-0.05))
        XCTAssertEqual(PreviewKeyRouting.command(keyCode: 124, modifiers: [.function, .command]), .jump(0.05))
        XCTAssertEqual(ShortcutStore.defaultBindings[.jumpBack]?.display, "⌘←")
        XCTAssertEqual(ShortcutStore.defaultBindings[.jumpForward]?.display, "⌘→")
    }

    func testPlainArrowBehaviorSeparatesPausedFramesPlayingShuttleReleaseAndVolume() {
        XCTAssertEqual(
            PreviewArrowRouting.keyDownAction(keyCode: 123, modifiers: [], playerRate: 0),
            .stepFrame(-1)
        )
        XCTAssertEqual(
            PreviewArrowRouting.keyDownAction(keyCode: 124, modifiers: [], playerRate: 0),
            .stepFrame(1)
        )
        XCTAssertEqual(
            PreviewArrowRouting.keyDownAction(keyCode: 123, modifiers: [], playerRate: 1),
            .startShuttle(.reverse)
        )
        XCTAssertEqual(
            PreviewArrowRouting.keyDownAction(keyCode: 124, modifiers: [], playerRate: 1.25),
            .startShuttle(.forward)
        )
        XCTAssertEqual(
            PreviewArrowRouting.keyUpAction(keyCode: 123, modifiers: []),
            .restoreForwardPlayback
        )
        XCTAssertEqual(
            PreviewArrowRouting.keyUpAction(keyCode: 124, modifiers: []),
            .restoreForwardPlayback
        )
        XCTAssertNil(PreviewArrowRouting.keyDownAction(keyCode: 123, modifiers: [.command], playerRate: 0))
        XCTAssertNil(PreviewArrowRouting.keyUpAction(keyCode: 124, modifiers: [.command]))
        XCTAssertEqual(PreviewArrowRouting.shuttleRate, 1.5)
        XCTAssertEqual(PreviewArrowRouting.keyDownAction(keyCode: 126, modifiers: [], playerRate: 0), .adjustVolume(0.10))
        XCTAssertEqual(PreviewArrowRouting.keyDownAction(keyCode: 125, modifiers: [], playerRate: 0), .adjustVolume(-0.10))
        XCTAssertEqual(PreviewArrowRouting.adjustedVolume(current: 0.95, by: 0.10), 1, accuracy: 0.0001)
        XCTAssertEqual(PreviewArrowRouting.adjustedVolume(current: 0.05, by: -0.10), 0, accuracy: 0.0001)
        XCTAssertEqual(PreviewArrowRouting.adjustedVolume(current: 0.40, by: 0.10), 0.50, accuracy: 0.0001)
    }

    func testShortcutStoreDefaultsSerializeAndRoute() throws {
        let suite = "MediaPreviewTests.shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)

        XCTAssertEqual(store.bindings, ShortcutStore.defaultBindings)
        let custom = PreviewShortcut(keyCode: 18, modifiers: [.option, .command])
        XCTAssertNil(store.set(custom, for: .mute))
        XCTAssertEqual(store.bindings[.mute], custom)
        XCTAssertEqual(store.command(for: custom), .mute)
        XCTAssertNotNil(defaults.data(forKey: ShortcutStore.storageKey))
        XCTAssertEqual(PreviewShortcut(keyCode: 9, modifiers: []).display, "V")
        XCTAssertEqual(PreviewShortcut(keyCode: 14, modifiers: [.command, .shift]).display, "⇧⌘E")
    }

    func testShortcutStoreMigratesFormerPlainArrowDefaultsToCommandArrows() throws {
        let suite = "MediaPreviewTests.shortcuts.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = ShortcutStore.defaultBindings
        legacy[.jumpBack] = PreviewShortcut(keyCode: 123, modifiers: [])
        legacy[.jumpForward] = PreviewShortcut(keyCode: 124, modifiers: [])
        defaults.set(try JSONEncoder().encode(legacy), forKey: ShortcutStore.storageKey)

        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.bindings[.jumpBack], PreviewShortcut(keyCode: 123, modifiers: [.command]))
        XCTAssertEqual(store.bindings[.jumpForward], PreviewShortcut(keyCode: 124, modifiers: [.command]))
    }

    func testShortcutStoreRejectsDuplicatesAndFinderSaveThenRestoresDefaults() throws {
        let suite = "MediaPreviewTests.shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        let mute = try XCTUnwrap(store.bindings[.mute])

        XCTAssertEqual(store.set(mute, for: .restart), .mute)
        XCTAssertEqual(store.bindings[.restart], ShortcutStore.defaultBindings[.restart])
        XCTAssertEqual(store.set(PreviewShortcut(keyCode: 1, modifiers: [.command]), for: .mute), .close)
        XCTAssertEqual(store.bindings[.mute], mute)
        XCTAssertNil(store.command(for: PreviewShortcut(keyCode: 1, modifiers: [.command])))
        XCTAssertNil(store.set(PreviewShortcut(keyCode: 18, modifiers: []), for: .mute))
        store.restoreDefaults()
        XCTAssertEqual(store.bindings, ShortcutStore.defaultBindings)
    }

    func testWaveformNormalizationIsBoundedAndPreservesSilence() {
        XCTAssertEqual(WaveformMath.normalized([0, 0, 0]), [0, 0, 0])
        XCTAssertEqual(WaveformMath.normalized([0.2, 0.5, 1.0]), [0.2, 0.5, 1.0])
        XCTAssertEqual(WaveformMath.normalized([0.5, 1.0, 2.0]), [0.25, 0.5, 1.0])
    }

    func testWaveformReaderDecodesKnownAmplitudeSections() throws {
        let url = syntheticWaveformFixtureURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing synthetic waveform fixture at \(url.path)")
        let values = try XCTUnwrap(WaveformReader.extract(url: url, cancellation: WaveformExtraction()))
        XCTAssertEqual(values.count, WaveformReader.preferredBarCount)
        let quarter = values.count / 4
        func mean(_ slice: ArraySlice<CGFloat>) -> CGFloat { slice.reduce(0, +) / CGFloat(slice.count) }
        let low = mean(values[0..<quarter])
        let high = mean(values[quarter..<(quarter * 2)])
        let medium = mean(values[(quarter * 2)..<(quarter * 3)])
        let silent = mean(values[(quarter * 3)..<values.count])
        XCTAssertGreaterThan(high, medium)
        XCTAssertGreaterThan(medium, low)
        XCTAssertLessThan(silent, 0.02)
    }

    func testNativeMetadataFallbackReadsAudioFixture() async throws {
        let url = syntheticWaveformFixtureURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing synthetic waveform fixture at \(url.path)")
        let metadata = await NativeMediaMetadata.inspect(url: url)
        XCTAssertTrue(metadata.row1.contains("M4A"))
        XCTAssertTrue(metadata.row1.contains("00:12"))
        XCTAssertTrue(metadata.row2.contains("AAC"))
        XCTAssertTrue(metadata.row2.contains("48.0 kHz"))
        XCTAssertTrue(metadata.row2.contains("Stereo"))
    }

    func testMediaRouteAndImageMetadata() {
        XCTAssertEqual(MediaRoute.kind(for: .jpeg), .image)
        XCTAssertEqual(MediaRoute.kind(for: .mpeg4Movie), .video)
        XCTAssertEqual(MediaRoute.kind(for: .plainText), .unsupported)
        XCTAssertNil(MediaRoute.preflight(kind: .image, imageIsDecodable: false))
        XCTAssertEqual(MediaRoute.preflight(kind: .image, imageIsDecodable: true), .image)
        XCTAssertEqual(MediaRoute.preflight(kind: .unsupported, imageIsDecodable: true), .image)
        let metadata = ImageMetadata.parse(
            properties: [
                "PixelWidth": 6000,
                "PixelHeight": 4000,
                "Depth": 12,
                "ColorModel": "RGB",
                "ProfileName": "Display P3",
                "HasAlpha": true,
                "Orientation": 1,
                "DPIWidth": 300,
                "{TIFF}": ["Make": "Canon", "Model": "R5"],
                "{Exif}": ["LensModel": "RF50mm F1.2", "FocalLength": 50, "FNumber": 1.2, "ExposureTime": 0.008, "ISOSpeedRatings": [100], "DateTimeOriginal": "2026:07:30 00:00:00"]
            ],
            fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            typeIdentifier: "public.jpeg"
        )
        XCTAssertTrue(metadata.row1.contains("JPEG"))
        XCTAssertTrue(metadata.row1.contains("6000×4000"))
        XCTAssertTrue(metadata.row1.contains("24.0 MP"))
        XCTAssertTrue(metadata.row2.contains("Canon R5"))
        XCTAssertTrue(metadata.row2.contains("ISO 100"))
    }

    func testPixelFormatMappings() {
        XCTAssertEqual(MetadataFormatter.bitDepth(from: "yuv420p10le"), "10-bit")
        XCTAssertEqual(MetadataFormatter.bitDepth(from: "yuv422p12le"), "12-bit")
        XCTAssertEqual(MetadataFormatter.bitDepth(from: "yuv444p"), "8-bit")
        XCTAssertEqual(MetadataFormatter.chromaSubsampling(from: "yuv420p10le"), "4:2:0")
        XCTAssertEqual(MetadataFormatter.chromaSubsampling(from: "yuv422p"), "4:2:2")
        XCTAssertEqual(MetadataFormatter.chromaSubsampling(from: "yuv444p12le"), "4:4:4")
    }
    func testColorMappings() {
        XCTAssertEqual(MetadataFormatter.primaries(from: "bt2020"), "Rec.2020")
        XCTAssertEqual(MetadataFormatter.transfer(from: "smpte2084"), "PQ")
        XCTAssertEqual(MetadataFormatter.transfer(from: "arib-std-b67"), "HLG")
        XCTAssertEqual(MetadataFormatter.transfer(from: "bt709"), "SDR")
        XCTAssertEqual(MetadataFormatter.range(from: "pc"), "Full")
        XCTAssertEqual(MetadataFormatter.range(from: "tv"), "Limited")
    }
    func testNativeCodecAliases() {
        XCTAssertEqual(MetadataFormatter.codec("avc1"), "H.264")
        XCTAssertEqual(MetadataFormatter.codec("hvc1"), "H.265")
        XCTAssertEqual(MetadataFormatter.codec("hev1"), "H.265")
        XCTAssertEqual(MetadataFormatter.codec("mp4a"), "AAC")
    }
    func testHoverFractionToTime() {
        XCTAssertEqual(TimelineMath.time(fraction: -1, duration: 100), 0)
        XCTAssertEqual(TimelineMath.time(fraction: 0.25, duration: 100), 25)
        XCTAssertEqual(TimelineMath.time(fraction: 2, duration: 100), 100)
    }
    @MainActor
    func testTimelineHoverCallbacksRespondToTrackingEventsWithoutClick() {
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var started = 0
        var ended = 0
        var fractions: [Double] = []
        timeline.hoverStarted = { started += 1 }
        timeline.hoverChanged = { fractions.append($0) }
        timeline.hoverEnded = { ended += 1 }

        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 25, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let moved = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 75, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: NSPoint(x: 75, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!

        timeline.mouseEntered(with: entered)
        timeline.mouseMoved(with: moved)
        timeline.mouseExited(with: exited)

        XCTAssertEqual(started, 1)
        XCTAssertEqual(fractions, [0.25, 0.75])
        XCTAssertEqual(ended, 1)
    }
    func testThumbnailCropUsesCenteredAspectFill() {
        let wideCrop = ThumbnailCropMath.sourceCrop(imageSize: CGSize(width: 1920, height: 1080), filling: CGSize(width: 100, height: 100))
        XCTAssertEqual(wideCrop, CGRect(x: 420, y: 0, width: 1080, height: 1080))
        let tallCrop = ThumbnailCropMath.sourceCrop(imageSize: CGSize(width: 1000, height: 2000), filling: CGSize(width: 16, height: 9))
        XCTAssertEqual(tallCrop, CGRect(x: 0, y: 718.75, width: 1000, height: 562.5))
    }

    func testProvisionalMetadataUsesExtensionFallbackAndChineseLoadingRow() {
        XCTAssertEqual(
            MetadataProgression.provisional(fileExtension: "", fallbackType: "video", fileSize: nil),
            MediaMetadata(row1: ["VIDEO"], row2: ["正在读取媒体信息…"])
        )

        let withExtension = MetadataProgression.provisional(fileExtension: "mov", fallbackType: "video", fileSize: 1_024)
        XCTAssertEqual(withExtension.row1.first, "MOV")
        XCTAssertEqual(withExtension.row1.count, 2)
        XCTAssertEqual(withExtension.row2, ["正在读取媒体信息…"])
    }

    func testMetadataProgressionIsMonotonicAndFFprobeFailureKeepsNative() {
        let provisional = MetadataProgression.provisional(fileExtension: "mp4", fallbackType: "VIDEO", fileSize: nil)
        let native = MediaMetadata(row1: ["MP4", "00:02"], row2: ["H.264"])
        let enriched = MediaMetadata(row1: ["MP4", "00:02", "1920×1080"], row2: ["H.264", "10-bit"])
        var progression = MetadataProgression(provisional: provisional)

        XCTAssertEqual(progression.receiveNative(native).map(\.stage), [.native])
        let visibleNative = progression.metadata
        XCTAssertEqual(progression.receiveFFprobe(.failure(.unavailable)), [])
        XCTAssertEqual(progression.metadata, visibleNative)
        XCTAssertEqual(progression.receiveFFprobe(.success(enriched)).map(\.stage), [.enriched])
        XCTAssertEqual(progression.metadata, enriched)
        XCTAssertEqual(progression.receiveNative(MediaMetadata(row1: ["OLD"], row2: ["OLD"])), [])
    }

    func testMetadataProgressionLetsEarlyEnrichedResultWinWithoutWaitingForNative() {
        var progression = MetadataProgression(
            provisional: MetadataProgression.provisional(fileExtension: "m4a", fallbackType: "AUDIO", fileSize: nil)
        )
        let enriched = MediaMetadata(row1: ["M4A", "00:03"], row2: ["AAC"])

        XCTAssertEqual(progression.receiveFFprobe(.success(enriched)).map(\.stage), [.enriched])
        XCTAssertEqual(progression.stage, .enriched)
        XCTAssertEqual(progression.metadata, enriched)
        XCTAssertEqual(progression.receiveNative(MediaMetadata(row1: ["M4A"], row2: ["Native"])), [])
    }

    func testMetadataInspectionTokenRejectsLateCallbacksAfterInvalidation() {
        var token = MetadataInspectionToken()
        let first = token.begin()
        XCTAssertTrue(token.accepts(first))
        token.invalidate()
        XCTAssertFalse(token.accepts(first))
        let second = token.begin()
        XCTAssertTrue(token.accepts(second))
        XCTAssertNotEqual(first, second)
    }

    @MainActor
    func testProvisionalMetadataHeaderIsVisibleAndCompactOnFirstLayout() throws {
        let controller = PreviewController(
            url: URL(fileURLWithPath: "/tmp/provisional-preview.mp4"),
            mediaKind: .video,
            metadataInspector: nil
        )
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        controller.view.layoutSubtreeIfNeeded()

        let metadata = try XCTUnwrap(identifier("preview-metadata-stack", in: controller.view) as? NSStackView)
        let firstRow = try XCTUnwrap(identifier("preview-metadata-row-1", in: controller.view) as? NSStackView)
        let secondRow = try XCTUnwrap(identifier("preview-metadata-row-2", in: controller.view) as? NSStackView)
        XCTAssertFalse(firstRow.isHidden)
        XCTAssertFalse(secondRow.isHidden)
        XCTAssertEqual(firstRow.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["MP4"])
        XCTAssertEqual(secondRow.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["正在读取媒体信息…"])
        XCTAssertGreaterThan(metadata.frame.height, 0)
        XCTAssertLessThan(metadata.frame.height, 50)
    }

    @MainActor
    func testImagePlaceholderSurvivesFailedImageIOLoad() throws {
        let controller = PreviewController(
            url: URL(fileURLWithPath: "/tmp/missing-provisional-image.jpeg"),
            mediaKind: .image,
            metadataInspector: nil
        )
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        controller.view.layoutSubtreeIfNeeded()

        let secondRow = try XCTUnwrap(identifier("preview-metadata-row-2", in: controller.view) as? NSStackView)
        XCTAssertEqual(secondRow.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["正在读取媒体信息…"])
        controller.viewDidAppear()
        XCTAssertEqual(secondRow.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["正在读取媒体信息…"])
    }
}
