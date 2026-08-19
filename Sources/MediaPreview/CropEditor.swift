import AppKit

enum VideoCropOrientation: Int, CaseIterable, Equatable {
    case horizontal
    case vertical

    var title: String {
        switch self {
        case .horizontal: return "横向"
        case .vertical: return "纵向"
        }
    }
}

/// The fixed preset identities shown in the export crop editor. The three
/// non-square identities use the sheet's single horizontal/vertical control
/// for their displayed title and ratio; this avoids a second preset row.
enum VideoCropPreset: Int, CaseIterable, Equatable {
    case original
    case square
    case standardFourByThree
    case widescreenSixteenByNine
    case cinema239
    case free

    var usesOrientation: Bool {
        switch self {
        case .standardFourByThree, .widescreenSixteenByNine, .cinema239: return true
        case .original, .square, .free: return false
        }
    }

    func title(for orientation: VideoCropOrientation) -> String {
        switch self {
        case .original: return "原始画幅"
        case .square: return "1:1"
        case .standardFourByThree: return orientation == .horizontal ? "4:3" : "3:4"
        case .widescreenSixteenByNine: return orientation == .horizontal ? "16:9" : "9:16"
        case .cinema239: return orientation == .horizontal ? "2.39:1" : "1:2.39"
        case .free: return "自由框选"
        }
    }

    /// Width divided by height. Free intentionally does not lock a ratio. An
    /// active `original` frame takes its ratio from the source canvas so its
    /// four handles can resize predictably without changing the source shape.
    func aspectRatio(for orientation: VideoCropOrientation) -> CGFloat? {
        switch self {
        case .square: return 1
        case .standardFourByThree: return orientation == .horizontal ? 4.0 / 3.0 : 3.0 / 4.0
        case .widescreenSixteenByNine: return orientation == .horizontal ? 16.0 / 9.0 : 9.0 / 16.0
        case .cinema239: return orientation == .horizontal ? 2.39 : 1.0 / 2.39
        case .original, .free: return nil
        }
    }
}

/// A crop rectangle is always represented in *encoded source-pixel*
/// coordinates, whose origin is the top-left corner as expected by FFmpeg.
/// A nil selection is more intentional than a full-frame crop: it preserves
/// the original video geometry and does not add a filter graph.
struct VideoCropSelection: Equatable {
    let preset: VideoCropPreset
    /// Stored with a non-square fixed selection, so reopening the editor does
    /// not reinterpret 9:16 as 16:9 (or vice versa).
    let orientation: VideoCropOrientation?
    let sourceRect: CGRect
    /// The transformed canvas on which `sourceRect` was selected. This lets a
    /// reopened editor preserve its focus when a quarter-turn swaps dimensions.
    let canvasSize: CGSize?

    init(preset: VideoCropPreset, orientation: VideoCropOrientation? = nil, sourceRect: CGRect, canvasSize: CGSize? = nil) {
        self.preset = preset
        self.orientation = preset.usesOrientation ? (orientation ?? .horizontal) : nil
        self.sourceRect = sourceRect
        self.canvasSize = canvasSize
    }

    var title: String { preset.title(for: orientation ?? .horizontal) }

    /// Original is normally represented by `nil` at export time. While it is
    /// active in the editor, however, it is a full-source fixed-ratio frame so
    /// users always have visible, usable corner handles on first open.
    var aspectRatio: CGFloat? {
        if preset == .original {
            guard let canvasSize, let bounds = VideoCropMath.sourceBounds(for: canvasSize) else {
                return VideoCropMath.displayRatio(for: sourceRect)
            }
            return VideoCropMath.displayRatio(for: bounds)
        }
        return preset.aspectRatio(for: orientation ?? .horizontal)
    }

    var effectiveWidth: Int { Int(sourceRect.width.rounded()) }
    var effectiveHeight: Int { Int(sourceRect.height.rounded()) }
    var effectiveX: Int { Int(sourceRect.minX.rounded()) }
    var effectiveY: Int { Int(sourceRect.minY.rounded()) }

    var rasterDescription: String {
        "\(effectiveWidth)×\(effectiveHeight)  @ \(effectiveX),\(effectiveY)"
    }

    /// Keep the complete filter graph in one argument. `setsar=1` avoids
    /// exporting a crop whose display ratio inherits a non-square input SAR.
    var ffmpegFilter: String {
        "crop=w=\(effectiveWidth):h=\(effectiveHeight):x=\(effectiveX):y=\(effectiveY):exact=1,setsar=1"
    }

    /// Restores a session selection on a possibly rotated/reoriented canvas.
    /// A fixed selection must always keep its stored ratio, even when its old
    /// coordinates no longer fit the current source dimensions.
    func restored(in sourceSize: CGSize) -> VideoCropSelection? {
        guard let aligned = VideoCropMath.aligned(sourceRect, in: sourceSize) else { return nil }
        guard let expectedRatio = aspectRatio else {
            return VideoCropSelection(preset: preset, orientation: orientation, sourceRect: aligned, canvasSize: sourceSize)
        }
        let actualRatio = VideoCropMath.displayRatio(for: aligned) ?? 0
        let relativeError = expectedRatio > 0 ? abs(actualRatio - expectedRatio) / expectedRatio : .infinity
        if relativeError < 0.02 {
            return VideoCropSelection(preset: preset, orientation: orientation, sourceRect: aligned, canvasSize: sourceSize)
        }
        guard let rect = VideoCropMath.maximumCrop(in: sourceSize, aspectRatio: expectedRatio, centeredAt: restoredFocus(in: sourceSize)) else { return nil }
        return VideoCropSelection(preset: preset, orientation: orientation, sourceRect: rect, canvasSize: sourceSize)
    }

    /// Switches the fixed non-square family to its horizontal/vertical
    /// counterpart, keeping the previous crop center when possible.
    func reoriented(to newOrientation: VideoCropOrientation, in sourceSize: CGSize) -> VideoCropSelection? {
        guard preset.usesOrientation,
              let ratio = preset.aspectRatio(for: newOrientation),
              let rect = VideoCropMath.maximumCrop(in: sourceSize, aspectRatio: ratio, centeredAt: restoredFocus(in: sourceSize)) else {
            return self
        }
        return VideoCropSelection(preset: preset, orientation: newOrientation, sourceRect: rect, canvasSize: sourceSize)
    }

    private func restoredFocus(in destinationSize: CGSize) -> CGPoint? {
        guard let canvasSize, canvasSize.width > 0, canvasSize.height > 0,
              destinationSize.width > 0, destinationSize.height > 0 else { return nil }
        return CGPoint(
            x: sourceRect.midX / canvasSize.width * destinationSize.width,
            y: sourceRect.midY / canvasSize.height * destinationSize.height
        )
    }
}

/// One transient display state is shared by the live preview, the crop-editor
/// current frame, and the FFmpeg export graph. Its filters intentionally apply
/// rotation first, then display-space mirroring, then the crop filter.
struct VideoDisplayTransform: Equatable {
    private(set) var quarterTurnsClockwise: Int
    private(set) var isMirrored: Bool

    init(quarterTurnsClockwise: Int = 0, isMirrored: Bool = false) {
        self.quarterTurnsClockwise = Self.normalized(quarterTurnsClockwise)
        self.isMirrored = isMirrored
    }

    var isIdentity: Bool { quarterTurnsClockwise == 0 && !isMirrored }
    var swapsDimensions: Bool { quarterTurnsClockwise % 2 != 0 }

    mutating func rotate(by quarterTurns: Int) {
        quarterTurnsClockwise = Self.normalized(quarterTurnsClockwise + quarterTurns)
    }

    mutating func toggleMirror() { isMirrored.toggle() }

    func outputSize(for sourceSize: CGSize) -> CGSize {
        swapsDimensions ? CGSize(width: sourceSize.height, height: sourceSize.width) : sourceSize
    }

    /// AVFoundation's normal player display applies a track's preferred
    /// transform. Use the same normalized dimensions before applying this
    /// user-controlled transform, so the editor/FFmpeg coordinate canvas is
    /// the same one the viewer sees.
    static func preferredDisplaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    /// FFmpeg applies the source rotation before `-vf`; the explicit filters
    /// below bake the user-controlled display state rather than metadata.
    var ffmpegFilterComponents: [String] {
        var filters: [String]
        switch quarterTurnsClockwise {
        case 0: filters = []
        case 1: filters = ["transpose=1"]
        case 2: filters = ["hflip", "vflip"]
        default: filters = ["transpose=2"]
        }
        if isMirrored { filters.append("hflip") }
        return filters
    }

    /// Maps an FFmpeg top-left-coordinate source rect into the post-transform
    /// canvas. It is used by tests and documents exactly which raster the crop
    /// editor is addressing after a quarter-turn/mirror operation.
    func transformedRect(_ rect: CGRect, in sourceSize: CGSize) -> CGRect {
        let rotated: CGRect
        switch quarterTurnsClockwise {
        case 0:
            rotated = rect
        case 1:
            rotated = CGRect(x: sourceSize.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 2:
            rotated = CGRect(x: sourceSize.width - rect.maxX, y: sourceSize.height - rect.maxY, width: rect.width, height: rect.height)
        default:
            rotated = CGRect(x: rect.minY, y: sourceSize.width - rect.maxX, width: rect.height, height: rect.width)
        }
        guard isMirrored else { return rotated }
        let output = outputSize(for: sourceSize)
        return CGRect(x: output.width - rotated.maxX, y: rotated.minY, width: rotated.width, height: rotated.height)
    }

    /// AppKit uses a bottom-left coordinate system while image pixels/FFmpeg
    /// crop coordinates use top-left. This transform is only for drawing the
    /// crop editor's current-frame preview; `transformedRect` remains the
    /// source-of-truth mapping for FFmpeg coordinates.
    func appKitAffineTransform(for sourceSize: CGSize) -> CGAffineTransform {
        let rotation: CGAffineTransform
        switch quarterTurnsClockwise {
        case 0:
            rotation = .identity
        case 1:
            rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: sourceSize.width)
        case 2:
            rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: sourceSize.width, ty: sourceSize.height)
        default:
            rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: sourceSize.height, ty: 0)
        }
        guard isMirrored else { return rotation }
        let output = outputSize(for: sourceSize)
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: output.width, ty: 0)
        return rotation.concatenating(mirror)
    }

    func transformedPreviewImage(_ image: NSImage) -> NSImage {
        guard !isIdentity,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let outputSize = outputSize(for: sourceSize)
        let rendered = NSImage(size: outputSize)
        rendered.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.concatenate(appKitAffineTransform(for: sourceSize))
            NSImage(cgImage: cgImage, size: sourceSize).draw(in: CGRect(origin: .zero, size: sourceSize))
            context.restoreGState()
        }
        rendered.unlockFocus()
        return rendered
    }

    private static func normalized(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }
}

enum CropResizeHandle: CaseIterable, Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct CropEditorHandleGeometry: Equatable {
    let handle: CropResizeHandle
    let center: NSPoint
    let drawingRect: NSRect
    let hitRect: NSRect
}

/// Keeps the interactive editor's preset contract explicit and testable:
/// every active crop frame has corner handles; fixed presets retain their
/// ratio while free mode retains independent width/height resizing.
enum VideoCropEditorInteraction: Equatable {
    case pan
    case resize

    static func allowsResize(for preset: VideoCropPreset) -> Bool {
        true
    }

    func resultingPreset(from currentPreset: VideoCropPreset) -> VideoCropPreset {
        switch self {
        case .pan:
            return currentPreset
        case .resize:
            return currentPreset
        }
    }
}

/// Pure source-pixel crop maths shared by the editor and export-plan tests.
/// The output is always even because the app's video exporter encodes
/// yuv420p. It intentionally does not round to macroblocks: doing so would
/// change a user's requested frame more than chroma alignment requires.
enum VideoCropMath {
    static let minimumDimension: CGFloat = 32

    static func sourceBounds(for sourceSize: CGSize) -> CGRect? {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite else { return nil }
        let width = evenFloor(sourceSize.width)
        let height = evenFloor(sourceSize.height)
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    static func maximumCrop(in sourceSize: CGSize, aspectRatio: CGFloat, centeredAt focus: CGPoint? = nil) -> CGRect? {
        guard aspectRatio.isFinite, aspectRatio > 0, let bounds = sourceBounds(for: sourceSize) else { return nil }
        let sourceRatio = bounds.width / bounds.height
        let rawSize: CGSize
        if sourceRatio > aspectRatio {
            rawSize = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        } else {
            rawSize = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        }

        // The closer even integer is more faithful to a named aspect ratio
        // than unconditional flooring (for example 1080 / 2.39 -> 452).
        let width = min(bounds.width, max(2, evenNearest(rawSize.width)))
        let height = min(bounds.height, max(2, evenNearest(rawSize.height)))
        let center = focus ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let rawRect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return aligned(rawRect, in: sourceSize)
    }

    static func aligned(_ proposed: CGRect, in sourceSize: CGSize) -> CGRect? {
        guard let bounds = sourceBounds(for: sourceSize) else { return nil }
        let width = min(bounds.width, max(2, evenFloor(proposed.width)))
        let height = min(bounds.height, max(2, evenFloor(proposed.height)))
        let maxX = max(0, bounds.width - width)
        let maxY = max(0, bounds.height - height)
        let x = min(maxX, max(0, evenFloor(proposed.minX)))
        let y = min(maxY, max(0, evenFloor(proposed.minY)))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func moved(_ sourceRect: CGRect, by delta: CGPoint, in sourceSize: CGSize) -> CGRect? {
        guard let bounds = sourceBounds(for: sourceSize),
              let rect = aligned(sourceRect, in: sourceSize) else { return nil }
        let x = min(max(0, rect.minX + delta.x), bounds.width - rect.width)
        let y = min(max(0, rect.minY + delta.y), bounds.height - rect.height)
        return aligned(CGRect(x: x, y: y, width: rect.width, height: rect.height), in: sourceSize)
    }

    static func resized(_ sourceRect: CGRect, handle: CropResizeHandle, by delta: CGPoint, in sourceSize: CGSize) -> CGRect? {
        guard let bounds = sourceBounds(for: sourceSize),
              let rect = aligned(sourceRect, in: sourceSize) else { return nil }
        let minimumWidth = min(bounds.width, max(2, evenNearest(minimumDimension)))
        let minimumHeight = min(bounds.height, max(2, evenNearest(minimumDimension)))

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .topLeft:
            minX = min(max(0, minX + delta.x), maxX - minimumWidth)
            minY = min(max(0, minY + delta.y), maxY - minimumHeight)
        case .topRight:
            maxX = max(min(bounds.width, maxX + delta.x), minX + minimumWidth)
            minY = min(max(0, minY + delta.y), maxY - minimumHeight)
        case .bottomLeft:
            minX = min(max(0, minX + delta.x), maxX - minimumWidth)
            maxY = max(min(bounds.height, maxY + delta.y), minY + minimumHeight)
        case .bottomRight:
            maxX = max(min(bounds.width, maxX + delta.x), minX + minimumWidth)
            maxY = max(min(bounds.height, maxY + delta.y), minY + minimumHeight)
        }
        return aligned(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), in: sourceSize)
    }

    /// Resizes a fixed-ratio crop from one corner while leaving the diagonal
    /// corner exactly where it was. The requested size is selected from the
    /// dominant drag axis, then made even deterministically for yuv420p.
    static func resizedFixed(_ sourceRect: CGRect, handle: CropResizeHandle, by delta: CGPoint, aspectRatio: CGFloat, in sourceSize: CGSize) -> CGRect? {
        guard aspectRatio.isFinite, aspectRatio > 0,
              let bounds = sourceBounds(for: sourceSize),
              let rect = aligned(sourceRect, in: sourceSize) else { return nil }
        guard delta.x != 0 || delta.y != 0 else { return rect }

        let expansion: (width: CGFloat, height: CGFloat)
        let anchor: CGPoint
        let maximumSize: CGSize
        switch handle {
        case .topLeft:
            expansion = (-delta.x, -delta.y)
            anchor = CGPoint(x: rect.maxX, y: rect.maxY)
            maximumSize = CGSize(width: anchor.x - bounds.minX, height: anchor.y - bounds.minY)
        case .topRight:
            expansion = (delta.x, -delta.y)
            anchor = CGPoint(x: rect.minX, y: rect.maxY)
            maximumSize = CGSize(width: bounds.maxX - anchor.x, height: anchor.y - bounds.minY)
        case .bottomLeft:
            expansion = (-delta.x, delta.y)
            anchor = CGPoint(x: rect.maxX, y: rect.minY)
            maximumSize = CGSize(width: anchor.x - bounds.minX, height: bounds.maxY - anchor.y)
        case .bottomRight:
            expansion = (delta.x, delta.y)
            anchor = CGPoint(x: rect.minX, y: rect.minY)
            maximumSize = CGSize(width: bounds.maxX - anchor.x, height: bounds.maxY - anchor.y)
        }

        let horizontalScale = (rect.width + expansion.width) / rect.width
        let verticalScale = (rect.height + expansion.height) / rect.height
        let scale = abs(horizontalScale - 1) >= abs(verticalScale - 1) ? horizontalScale : verticalScale
        guard let size = fixedSize(
            desiredHeight: rect.height * scale,
            aspectRatio: aspectRatio,
            maximumSize: maximumSize
        ) else { return nil }

        switch handle {
        case .topLeft:
            return CGRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        case .topRight:
            return CGRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        case .bottomLeft:
            return CGRect(x: anchor.x - size.width, y: anchor.y, width: size.width, height: size.height)
        case .bottomRight:
            return CGRect(x: anchor.x, y: anchor.y, width: size.width, height: size.height)
        }
    }

    static func displayRatio(for rect: CGRect) -> CGFloat? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect.width / rect.height
    }

    private static func fixedSize(desiredHeight: CGFloat, aspectRatio: CGFloat, maximumSize: CGSize) -> CGSize? {
        let maximumWidth = evenFloor(maximumSize.width)
        var maximumHeight = evenFloor(min(maximumSize.height, maximumWidth / aspectRatio))
        while maximumHeight >= 2 && fixedWidth(forHeight: maximumHeight, aspectRatio: aspectRatio) > maximumWidth {
            maximumHeight -= 2
        }
        guard maximumHeight >= 2 else { return nil }

        let requestedMinimum = max(2, evenNearest(minimumDimension))
        var minimumHeight = max(2, evenNearest(max(requestedMinimum, requestedMinimum / aspectRatio)))
        while minimumHeight <= maximumHeight && fixedWidth(forHeight: minimumHeight, aspectRatio: aspectRatio) < requestedMinimum {
            minimumHeight += 2
        }
        if minimumHeight > maximumHeight {
            minimumHeight = 2
        }

        let requestedHeight = max(2, evenNearest(desiredHeight))
        let height = min(maximumHeight, max(minimumHeight, requestedHeight))
        let width = fixedWidth(forHeight: height, aspectRatio: aspectRatio)
        guard width >= 2, width <= maximumWidth else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func fixedWidth(forHeight height: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        max(2, evenNearest(height * aspectRatio))
    }

    private static func evenFloor(_ value: CGFloat) -> CGFloat {
        let integer = Int(value.rounded(.down))
        return CGFloat(integer - integer % 2)
    }

    private static func evenNearest(_ value: CGFloat) -> CGFloat {
        let integer = Int((value / 2).rounded()) * 2
        return CGFloat(integer)
    }
}

enum CropEditorResult: Equatable {
    case cancelled
    case selected(VideoCropSelection?)
}

/// A small visual editor rather than a numeric crop form. Its drawing space is
/// letterboxed, but edits are immediately mapped back to source pixels.
final class CropEditorView: NSView {
    var sourceSize: CGSize = .zero { didSet { redrawAndInvalidateInteraction() } }
    var previewImage: NSImage? { didSet { needsDisplay = true } }
    var selection: VideoCropSelection? { didSet { redrawAndInvalidateInteraction() } }
    var selectionChanged: ((CGRect, VideoCropEditorInteraction) -> Void)?

    private enum DragMode { case pan(CGRect), resize(CropResizeHandle, CGRect, CGFloat?) }
    private var dragMode: DragMode?
    private var dragStart = NSPoint.zero
    private let handleSize: CGFloat = 12
    private let handleHitSize: CGFloat = 26

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = "拖动画面内移动；拖动四角调整画幅。固定画幅保持比例，自由框选可独立调整宽高。"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        bounds.fill()
        let previewRect = displayedImageRect
        if let previewImage {
            previewImage.draw(in: previewRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            previewRect.fill()
            let placeholder = NSAttributedString(
                string: "当前帧预览不可用；仍可设置导出画幅",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            )
            placeholder.draw(at: NSPoint(x: previewRect.midX - placeholder.size().width / 2, y: previewRect.midY - placeholder.size().height / 2))
        }

        guard let cropRect = selection?.sourceRect else { return }
        let renderedCrop = displayRect(forSourceRect: cropRect)
        let shade = NSColor.black.withAlphaComponent(0.54)
        shade.setFill()
        NSRect(x: previewRect.minX, y: previewRect.minY, width: previewRect.width, height: max(0, renderedCrop.minY - previewRect.minY)).fill()
        NSRect(x: previewRect.minX, y: renderedCrop.maxY, width: previewRect.width, height: max(0, previewRect.maxY - renderedCrop.maxY)).fill()
        NSRect(x: previewRect.minX, y: renderedCrop.minY, width: max(0, renderedCrop.minX - previewRect.minX), height: renderedCrop.height).fill()
        NSRect(x: renderedCrop.maxX, y: renderedCrop.minY, width: max(0, previewRect.maxX - renderedCrop.maxX), height: renderedCrop.height).fill()

        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: renderedCrop)
        path.lineWidth = 2
        path.stroke()
        for geometry in cropHandleGeometries {
            NSColor.black.withAlphaComponent(0.78).setFill()
            geometry.drawingRect.insetBy(dx: -1, dy: -1).fill()
            NSColor.systemYellow.setFill()
            geometry.drawingRect.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let handlePath = NSBezierPath(rect: geometry.drawingRect.insetBy(dx: 0.5, dy: 0.5))
            handlePath.lineWidth = 1
            handlePath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let selection else { return }
        let point = convert(event.locationInWindow, from: nil)
        let cropRect = displayRect(forSourceRect: selection.sourceRect)
        if let handle = resizeHandle(at: point) {
            dragMode = .resize(handle, selection.sourceRect, selection.aspectRatio)
        } else if cropRect.contains(point) {
            dragMode = .pan(selection.sourceRect)
        } else {
            dragMode = nil
        }
        dragStart = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, sourceSize.width > 0, sourceSize.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = displayedImageRect.width / sourceSize.width
        guard scale.isFinite, scale > 0 else { return }
        // AppKit's Y axis rises upward; FFmpeg source Y grows downward.
        let sourceDelta = CGPoint(x: (point.x - dragStart.x) / scale, y: -(point.y - dragStart.y) / scale)
        let updated: CGRect?
        let interaction: VideoCropEditorInteraction
        switch dragMode {
        case .pan(let original):
            updated = VideoCropMath.moved(original, by: sourceDelta, in: sourceSize)
            interaction = .pan
        case .resize(let handle, let original, let aspectRatio):
            if let aspectRatio {
                updated = VideoCropMath.resizedFixed(original, handle: handle, by: sourceDelta, aspectRatio: aspectRatio, in: sourceSize)
            } else {
                updated = VideoCropMath.resized(original, handle: handle, by: sourceDelta, in: sourceSize)
            }
            interaction = .resize
        }
        guard let updated else { return }
        selectionChanged?(updated, interaction)
    }

    override func mouseUp(with event: NSEvent) { dragMode = nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let selection else { return }
        let cropRect = displayRect(forSourceRect: selection.sourceRect)
        addCursorRect(cropRect, cursor: .openHand)
        for geometry in cropHandleGeometries {
            addCursorRect(geometry.hitRect, cursor: .crosshair)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    private var displayedImageRect: CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds.insetBy(dx: 8, dy: 8) }
        let inset = bounds.insetBy(dx: 8, dy: 8)
        let scale = min(inset.width / sourceSize.width, inset.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func displayRect(forSourceRect rect: CGRect) -> CGRect {
        let previewRect = displayedImageRect
        guard sourceSize.width > 0 else { return .zero }
        let scale = previewRect.width / sourceSize.width
        return CGRect(
            x: previewRect.minX + rect.minX * scale,
            y: previewRect.maxY - (rect.minY + rect.height) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    var cropHandleGeometries: [CropEditorHandleGeometry] {
        guard let selection else { return [] }
        return handleGeometries(for: displayRect(forSourceRect: selection.sourceRect))
    }

    func resizeHandle(at point: NSPoint) -> CropResizeHandle? {
        cropHandleGeometries.first { $0.hitRect.contains(point) }?.handle
    }

    private func handleGeometries(for rect: CGRect) -> [CropEditorHandleGeometry] {
        let previewRect = displayedImageRect
        let centerInset = min(handleSize / 2, min(previewRect.width, previewRect.height) / 2)
        let visibleCenterBounds = previewRect.insetBy(dx: centerInset, dy: centerInset)
        let handles: [(CropResizeHandle, NSPoint)] = [
            (.topLeft, NSPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, NSPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, NSPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, NSPoint(x: rect.maxX, y: rect.minY))
        ]
        return handles.map { handle, rawCenter in
            let center = NSPoint(
                x: min(max(rawCenter.x, visibleCenterBounds.minX), visibleCenterBounds.maxX),
                y: min(max(rawCenter.y, visibleCenterBounds.minY), visibleCenterBounds.maxY)
            )
            return CropEditorHandleGeometry(
                handle: handle,
                center: center,
                drawingRect: NSRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2, width: handleSize, height: handleSize),
                hitRect: NSRect(x: center.x - handleHitSize / 2, y: center.y - handleHitSize / 2, width: handleHitSize, height: handleHitSize)
            )
        }
    }

    private func redrawAndInvalidateInteraction() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

/// Hosts CropEditorView in a document-modal sheet. It does not save anything;
/// the caller continues into the existing NSSavePanel only after an explicit
/// export confirmation.
@MainActor
final class CropEditorSheetController: NSViewController {
    private static let presetTagOffset = 10_000
    private let sourceSize: CGSize
    private let previewImage: NSImage?
    private let resultHandler: (CropEditorResult) -> Void
    private let editorView = CropEditorView()
    private let rasterLabel = NSTextField(labelWithString: "")
    private var orientationControl: NSSegmentedControl?
    private var currentOrientation: VideoCropOrientation = .horizontal
    private var currentSelection: VideoCropSelection?
    private var sheet: NSWindow?
    private var didFinish = false

    init(sourceSize: CGSize, previewImage: NSImage?, initialSelection: VideoCropSelection?, resultHandler: @escaping (CropEditorResult) -> Void) {
        self.sourceSize = sourceSize
        self.previewImage = previewImage
        let restoredSelection = initialSelection.flatMap { $0.restored(in: sourceSize) }
        self.currentSelection = restoredSelection ?? Self.originalSelection(in: sourceSize)
        self.currentOrientation = restoredSelection?.orientation ?? .horizontal
        self.resultHandler = resultHandler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let heading = NSTextField(labelWithString: "导出画幅")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(heading)

        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        presetRow.alignment = .centerY

        let orientation = NSSegmentedControl(labels: VideoCropOrientation.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(changeOrientation(_:)))
        orientation.selectedSegment = currentOrientation.rawValue
        orientation.segmentStyle = .texturedRounded
        orientation.setWidth(42, forSegment: VideoCropOrientation.horizontal.rawValue)
        orientation.setWidth(42, forSegment: VideoCropOrientation.vertical.rawValue)
        orientationControl = orientation
        presetRow.addArrangedSubview(orientation)

        for preset in VideoCropPreset.allCases {
            let button = NSButton(title: preset.title(for: currentOrientation), target: self, action: #selector(selectPreset(_:)))
            button.tag = Self.presetTagOffset + preset.rawValue
            button.bezelStyle = .rounded
            button.setButtonType(.toggle)
            button.font = .systemFont(ofSize: 12, weight: .medium)
            presetRow.addArrangedSubview(button)
        }
        root.addArrangedSubview(presetRow)

        editorView.sourceSize = sourceSize
        editorView.previewImage = previewImage
        editorView.selection = currentSelection
        editorView.widthAnchor.constraint(equalToConstant: 720).isActive = true
        editorView.heightAnchor.constraint(equalToConstant: 430).isActive = true
        editorView.selectionChanged = { [weak self] rect, interaction in
            guard let self else { return }
            let oldSelection = self.currentSelection
            let currentPreset = oldSelection?.preset ?? .free
            let nextPreset = interaction.resultingPreset(from: currentPreset)
            let nextOrientation = nextPreset.usesOrientation ? (oldSelection?.orientation ?? self.currentOrientation) : nil
            self.setSelection(VideoCropSelection(preset: nextPreset, orientation: nextOrientation, sourceRect: rect, canvasSize: self.sourceSize))
        }
        root.addArrangedSubview(editorView)

        rasterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rasterLabel.textColor = .secondaryLabelColor
        rasterLabel.alignment = .center
        root.addArrangedSubview(rasterLabel)

        let description = NSTextField(wrappingLabelWithString: "拖动画面内可平移取景；四角均可调整画幅。横向/纵向切换会保留固定比例和取景中心；固定比例保持比例，自由框选可独立调整宽高。只裁切，不放大。")
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 2
        description.alignment = .center
        description.widthAnchor.constraint(equalToConstant: 720).isActive = true
        root.addArrangedSubview(description)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        let export = NSButton(title: "继续导出…", target: self, action: #selector(accept(_:)))
        export.keyEquivalent = "\r"
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(export)
        root.addArrangedSubview(actions)

        view = root
        updateControls()
    }

    func present(for parent: NSWindow) {
        // `loadViewIfNeeded()` is macOS 14+. Accessing `view` has the same
        // eager-load behavior on the app's macOS 13 deployment target.
        _ = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 575), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "导出画幅"
        window.isReleasedWhenClosed = false
        window.contentViewController = self
        sheet = window
        parent.beginSheet(window) { [weak self] _ in
            guard let self, !self.didFinish else { return }
            self.finish(.cancelled)
        }
    }

    @objc private func selectPreset(_ sender: NSButton) {
        guard let preset = VideoCropPreset(rawValue: sender.tag - Self.presetTagOffset) else { return }
        switch preset {
        case .original:
            setSelection(Self.originalSelection(in: sourceSize))
        case .free:
            let rect = currentSelection?.sourceRect ?? VideoCropMath.sourceBounds(for: sourceSize)
            guard let rect else { return }
            setSelection(VideoCropSelection(preset: .free, sourceRect: rect, canvasSize: sourceSize))
        default:
            guard let ratio = preset.aspectRatio(for: currentOrientation), let rect = VideoCropMath.maximumCrop(in: sourceSize, aspectRatio: ratio) else { return }
            setSelection(VideoCropSelection(preset: preset, orientation: currentOrientation, sourceRect: rect, canvasSize: sourceSize))
        }
    }

    @objc private func changeOrientation(_ sender: NSSegmentedControl) {
        guard let nextOrientation = VideoCropOrientation(rawValue: sender.selectedSegment), nextOrientation != currentOrientation else { return }
        currentOrientation = nextOrientation
        if let selection = currentSelection, selection.preset.usesOrientation,
           let reoriented = selection.reoriented(to: nextOrientation, in: sourceSize) {
            setSelection(reoriented)
        } else {
            updateControls()
        }
    }

    @objc private func accept(_ sender: Any?) { finish(.selected(exportSelection)) }
    @objc private func cancel(_ sender: Any?) { finish(.cancelled) }

    private func setSelection(_ selection: VideoCropSelection?) {
        currentSelection = selection
        editorView.selection = selection
        updateControls()
    }

    private func updateControls() {
        let activePreset = currentSelection?.preset ?? .original
        orientationControl?.selectedSegment = currentOrientation.rawValue
        for button in descendantButtons(in: view) where VideoCropPreset(rawValue: button.tag - Self.presetTagOffset) != nil {
            guard let preset = VideoCropPreset(rawValue: button.tag - Self.presetTagOffset) else { continue }
            button.title = preset.title(for: currentOrientation)
            button.state = button.tag == Self.presetTagOffset + activePreset.rawValue ? .on : .off
        }
        if let selection = currentSelection {
            let ratio = VideoCropMath.displayRatio(for: selection.sourceRect) ?? 0
            rasterLabel.stringValue = "\(selection.title)  ·  \(selection.rasterDescription)  ·  \(String(format: "%.3f:1", locale: Locale(identifier: "en_US_POSIX"), ratio))"
        } else if let bounds = VideoCropMath.sourceBounds(for: sourceSize) {
            rasterLabel.stringValue = "原始画幅（不裁切）  ·  \(Int(bounds.width))×\(Int(bounds.height))"
        } else {
            rasterLabel.stringValue = "无法读取源画幅"
        }
    }

    private func descendantButtons(in view: NSView) -> [NSButton] {
        var buttons: [NSButton] = []
        if let button = view as? NSButton { buttons.append(button) }
        for subview in view.subviews { buttons += descendantButtons(in: subview) }
        return buttons
    }

    private static func originalSelection(in sourceSize: CGSize) -> VideoCropSelection? {
        guard let bounds = VideoCropMath.sourceBounds(for: sourceSize) else { return nil }
        return VideoCropSelection(preset: .original, sourceRect: bounds, canvasSize: sourceSize)
    }

    private var exportSelection: VideoCropSelection? {
        guard let selection = currentSelection else { return nil }
        guard selection.preset == .original,
              let bounds = VideoCropMath.sourceBounds(for: sourceSize),
              selection.sourceRect == bounds else {
            return selection
        }
        return nil
    }

    private func finish(_ result: CropEditorResult) {
        guard !didFinish else { return }
        didFinish = true
        let sheet = self.sheet
        self.sheet = nil
        if let sheet, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet?.orderOut(nil)
        }
        resultHandler(result)
    }
}
