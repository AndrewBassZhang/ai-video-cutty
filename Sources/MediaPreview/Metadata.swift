import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaMetadata: Equatable, Sendable {
    let row1: [String]
    let row2: [String]
    static let empty = MediaMetadata(row1: [], row2: [])
}

enum MetadataFormatter {
    static func bitDepth(from pixelFormat: String?, fallback: String? = nil) -> String? {
        if let fallback, let depth = Int(fallback), depth > 0 { return "\(depth)-bit" }
        guard let pixelFormat else { return nil }
        let format = pixelFormat.lowercased()
        for pattern in ["p(\\d{2})(?:le|be)?$", "(\\d{2})(?:le|be)$"] {
            if let match = format.range(of: pattern, options: .regularExpression) {
                let digits = String(format[match]).filter(\.isNumber)
                if let depth = Int(digits), depth >= 8 { return "\(depth)-bit" }
            }
        }
        return (format.contains("yuv420p") || format.contains("yuv422p") || format.contains("yuv444p")) ? "8-bit" : nil
    }
    static func chromaSubsampling(from pixelFormat: String?) -> String? {
        guard let value = pixelFormat?.lowercased() else { return nil }
        if value.contains("420") { return "4:2:0" }
        if value.contains("422") { return "4:2:2" }
        if value.contains("444") { return "4:4:4" }
        if value.contains("411") { return "4:1:1" }
        return nil
    }
    static func transfer(from value: String?) -> String? {
        switch value?.lowercased() {
        case "smpte2084", "pq": return "PQ"
        case "arib-std-b67", "hlg": return "HLG"
        case "bt709", "bt470bg", "smpte170m", "iec61966-2-1": return "SDR"
        default: return nil
        }
    }
    static func primaries(from value: String?) -> String? {
        switch value?.lowercased() {
        case "bt2020": return "Rec.2020"
        case "bt709": return "Rec.709"
        case "smpte432": return "P3-D65"
        case "smpte170m": return "Rec.601"
        default: return nil
        }
    }
    static func range(from value: String?) -> String? {
        switch value?.lowercased() { case "pc", "jpeg": return "Full"; case "tv", "mpeg": return "Limited"; default: return nil }
    }
    static func codec(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "h264": return "H.264"
        case "avc1": return "H.264"
        case "hevc": return "H.265"
        case "hvc1", "hev1": return "H.265"
        case "mp4a": return "AAC"
        case "prores": return "ProRes"
        case let value?: return value.uppercased()
        case nil: return nil
        }
    }
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        if total < 3600 { return String(format: "%02d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
    static func fileSize(_ bytes: Int64?) -> String? { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } }
    static func bitrate(_ bitsPerSecond: Int64?) -> String? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        if bitsPerSecond < 500_000 { return String(format: "%.0f kb/s", Double(bitsPerSecond) / 1_000) }
        return String(format: "%.2f Mb/s", Double(bitsPerSecond) / 1_000_000)
    }
    static func preferredVideoBitrate(video: Int64?, format: Int64?) -> Int64? {
        [video, format].first { ($0 ?? 0) > 0 } ?? nil
    }
    static func fps(_ raw: String?) -> String? {
        guard let raw, raw != "0/0" else { return nil }
        let parts = raw.split(separator: "/")
        let value = parts.count == 2 ? (Double(parts[0]) ?? 0) / max(Double(parts[1]) ?? 0, 1) : Double(raw) ?? 0
        guard value > 0 else { return nil }
        return String(format: value.rounded() == value ? "%.0f fps" : "%.3g fps", value)
    }
}

enum ImagePreview {
    static func load(url: URL) -> (image: NSImage, metadata: MediaMetadata)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:])
            .reduce(into: [String: Any]()) { $0[$1.key as String] = $1.value }
        let typeIdentifier = CGImageSourceGetType(source).map { $0 as String }
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), ImageMetadata.parse(properties: properties, fileURL: url, typeIdentifier: typeIdentifier))
    }

    static func canDecode(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

enum ImageMetadata {
    static func parse(properties: [String: Any], fileURL: URL, typeIdentifier: String? = nil) -> MediaMetadata {
        func number(_ dictionary: [String: Any], _ key: String) -> Double? {
            let value = dictionary[key]
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            if let array = value as? [Any], let first = array.first {
                if let number = first as? NSNumber { return number.doubleValue }
                if let string = first as? String { return Double(string) }
            }
            return nil
        }
        func text(_ dictionary: [String: Any], _ key: String) -> String? {
            dictionary[key] as? String
        }
        func dictionary(_ key: String) -> [String: Any] {
            properties[key] as? [String: Any] ?? [:]
        }
        let tiff = dictionary("{TIFF}")
        let exif = dictionary("{Exif}")
        let width = number(properties, "PixelWidth")
        let height = number(properties, "PixelHeight")
        let format = typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension }?.uppercased() ?? (fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension.uppercased())
        let dimensions = width.flatMap { width in height.map { "\(Int(width))×\(Int($0))" } }
        let megapixels = width.flatMap { width in height.map { String(format: "%.1f MP", width * $0 / 1_000_000) } }
        let dpi = number(properties, "DPIWidth").map { String(format: "%.0f dpi", $0) }
        let orientation = number(properties, "Orientation").map { "Orientation \(Int($0))" }
        let alpha = (properties["HasAlpha"] as? NSNumber)?.boolValue == true ? "Alpha" : nil
        let row1 = [format, MetadataFormatter.fileSize((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value), dimensions, megapixels, number(properties, "Depth").map { "\(Int($0))-bit" }, text(properties, "ColorModel"), text(properties, "ProfileName"), alpha, orientation, dpi].compactMap { $0 }
        let camera = [text(tiff, "Make"), text(tiff, "Model")].compactMap { $0 }.joined(separator: " ")
        let focalLength = number(exif, "FocalLength").map { String(format: "%.0f mm", $0) }
        let aperture = number(exif, "FNumber").map { String(format: "f/%.1f", $0) }
        let exposure = number(exif, "ExposureTime").map { $0 > 0 && $0 < 1 ? "1/\(Int((1 / $0).rounded())) s" : String(format: "%.2f s", $0) }
        let iso = number(exif, "ISOSpeedRatings").map { "ISO \(Int($0))" }
        let row2 = [camera.isEmpty ? nil : camera, text(exif, "LensModel"), focalLength, aperture, exposure, iso, text(exif, "DateTimeOriginal")].compactMap { $0 }
        return MediaMetadata(row1: row1, row2: row2)
    }
}

enum MetadataError: Error, LocalizedError, Sendable { case unavailable, timedOut, oversized, invalidOutput
    var errorDescription: String? { switch self { case .unavailable: return "ffprobe is unavailable"; case .timedOut: return "ffprobe timed out"; case .oversized: return "ffprobe output exceeded 2 MB"; case .invalidOutput: return "ffprobe returned invalid JSON" } }
}

enum FFprobe {
    static let executable = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    static let outputLimit = 2 * 1024 * 1024

    static func inspect(url: URL, completion: @escaping @Sendable (Result<MediaMetadata, MetadataError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try inspectBlocking(url: url)))
            } catch let error as MetadataError {
                completion(.failure(error))
            } catch {
                completion(.failure(.invalidOutput))
            }
        }
    }

    private static func inspectBlocking(url: URL) throws -> MediaMetadata {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MetadataError.unavailable }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("media-preview-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        process.standardOutput = handle; process.standardError = handle
        do { try process.run() } catch { throw MetadataError.unavailable }
        let deadline = Date().addingTimeInterval(5)
        var oversized = false
        while process.isRunning && Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > outputLimit { oversized = true; process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        if Date() >= deadline && !oversized { throw MetadataError.timedOut }
        if oversized { throw MetadataError.oversized }
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        guard data.count <= outputLimit else { throw MetadataError.oversized }
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MetadataError.invalidOutput }
        return parse(object, fileURL: url)
    }

    static func parse(_ object: [String: Any], fileURL: URL) -> MediaMetadata {
        let format = object["format"] as? [String: Any] ?? [:]
        let streams = object["streams"] as? [[String: Any]] ?? []
        let video = streams.first { ($0["codec_type"] as? String) == "video" } ?? [:]
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" } ?? [:]
        func string(_ dict: [String: Any], _ key: String) -> String? { dict[key] as? String }
        func int(_ dict: [String: Any], _ key: String) -> Int64? { (dict[key] as? NSNumber)?.int64Value ?? Int64(string(dict, key) ?? "") }
        let codec = [MetadataFormatter.codec(string(video, "codec_name")), string(video, "profile")].compactMap { $0 }.joined(separator: " ")
        let channels: String? = int(audio, "channels").map { $0 == 1 ? "Mono" : $0 == 2 ? "Stereo" : "\($0) ch" }
        let row1 = [fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension.uppercased(), MetadataFormatter.fileSize(int(format, "size")), MetadataFormatter.duration(Double(string(format, "duration") ?? "")), MetadataFormatter.bitrate(MetadataFormatter.preferredVideoBitrate(video: int(video, "bit_rate"), format: int(format, "bit_rate"))), MetadataFormatter.fps(string(video, "r_frame_rate")), { guard let width = int(video, "width"), let height = int(video, "height") else { return nil }; return "\(width)×\(height)" }()].compactMap { $0 }
        let row2 = [codec.isEmpty ? nil : codec, MetadataFormatter.bitDepth(from: string(video, "pix_fmt"), fallback: string(video, "bits_per_raw_sample")), MetadataFormatter.chromaSubsampling(from: string(video, "pix_fmt")), MetadataFormatter.primaries(from: string(video, "color_primaries")), MetadataFormatter.transfer(from: string(video, "color_transfer")), MetadataFormatter.range(from: string(video, "color_range")), MetadataFormatter.codec(string(audio, "codec_name")), string(audio, "sample_rate").flatMap(Int.init).map { String(format: "%.1f kHz", Double($0) / 1_000) }, channels].compactMap { $0 }
        return MediaMetadata(row1: row1, row2: row2)
    }
}

/// The bundled app must remain useful on machines without Homebrew/ffprobe.  This
/// intentionally uses only AVFoundation data that macOS exposes for the asset.
enum NativeMediaMetadata {
    static func inspect(url: URL) async -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        async let durationValue = try? asset.load(.duration)
        async let videoTracks = try? asset.loadTracks(withMediaType: .video)
        async let audioTracks = try? asset.loadTracks(withMediaType: .audio)
        let duration = await durationValue?.seconds
        let video = await videoTracks?.first
        let audio = await audioTracks?.first
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        let size = try? await video?.load(.naturalSize)
        let fps = try? await video?.load(.nominalFrameRate)
        let videoBitrateValue = try? await video?.load(.estimatedDataRate)
        let audioBitrateValue = try? await audio?.load(.estimatedDataRate)
        let videoFormat = try? await video?.load(.formatDescriptions).first
        let audioFormat = try? await audio?.load(.formatDescriptions).first

        let videoDescription = videoFormat
        let audioDescription = audioFormat
        let videoCodec = videoDescription.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        let audioCodec = audioDescription.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        let extensions = videoDescription.flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] } ?? [:]
        let colorPrimaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let ycbcr = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let audioDescriptionPointer = audioDescription.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
        let sampleRate = audioDescriptionPointer.map { $0.pointee.mSampleRate }
        let channels = audioDescriptionPointer.map { Int($0.pointee.mChannelsPerFrame) }
        let dimensions = size.flatMap { $0.width > 0 && $0.height > 0 ? "\(Int($0.width.rounded()))×\(Int($0.height.rounded()))" : nil }
        let channelLabel = channels.map { $0 == 1 ? "Mono" : $0 == 2 ? "Stereo" : "\($0) ch" }
        let row1 = [
            url.pathExtension.isEmpty ? "Media" : url.pathExtension.uppercased(),
            MetadataFormatter.fileSize(fileSize),
            MetadataFormatter.duration(duration),
            MetadataFormatter.bitrate((videoBitrateValue ?? audioBitrateValue).map(Int64.init)),
            fps.flatMap { $0 > 0 ? String(format: $0.rounded() == $0 ? "%.0f fps" : "%.3g fps", $0) : nil },
            dimensions
        ].compactMap { $0 }
        let row2: [String] = [
            videoCodec.flatMap(MetadataFormatter.codec),
            MetadataFormatter.primaries(from: colorPrimaries),
            MetadataFormatter.transfer(from: transfer),
            ycbcr.map { "YCbCr \($0)" },
            audioCodec.flatMap(MetadataFormatter.codec),
            sampleRate.map { String(format: "%.1f kHz", $0 / 1_000) },
            channelLabel
        ].compactMap { $0 }
        return MediaMetadata(row1: row1, row2: row2)
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        let text = String(bytes: bytes, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? String(format: "0x%08X", value) : text
    }
}
