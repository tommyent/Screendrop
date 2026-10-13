//
//  RecordingStudioStyleTransfer.swift
//  Screendrop
//
//  Studio styles shared as files. They use the image editor's
//  .screendroppreset type with a format name of their own, so each editor
//  can say a file belongs to the other instead of misreading it. As there,
//  a custom wallpaper is a local file and is left out.
//

import Foundation

struct RecordingStudioStyleTransferFile: Codable {
    static let currentVersion = 1
    static let formatIdentifier = "screendrop-recording-presets"

    var format: String
    var version: Int
    var presets: [Preset]

    init(preset: RecordingStudioStylePreset) {
        let style = PortableRecordingStudioStyle(preset.value)
        format = Self.formatIdentifier
        version = Self.currentVersion
        presets = [Preset(name: preset.name, style: style, omitted: style.didOmitWallpaper ? [.wallpaper] : [])]
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The size and count limits are the image editor's.
    static func load(from url: URL) throws -> RecordingStudioStyleTransferFile {
        typealias Limits = AnnotationBackgroundPresetTransferFile
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= Limits.maximumFileSize else {
            throw AnnotationBackgroundPresetTransferError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Limits.maximumFileSize else {
            throw AnnotationBackgroundPresetTransferError.fileTooLarge
        }
        // Read the format first, so an image editor style gets its own message.
        struct Header: Decodable { var format: String }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw AnnotationBackgroundPresetTransferError.invalidJSON
        }
        guard header.format != AnnotationBackgroundPresetTransferFile.formatIdentifier else {
            throw AnnotationBackgroundPresetTransferError.screenshotStyle
        }
        guard header.format == formatIdentifier else {
            throw AnnotationBackgroundPresetTransferError.invalidRecordingFormat
        }
        let file: RecordingStudioStyleTransferFile
        do {
            file = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw AnnotationBackgroundPresetTransferError.invalidJSON
        }
        guard file.version == currentVersion else {
            throw AnnotationBackgroundPresetTransferError.unsupportedVersion(file.version)
        }
        guard !file.presets.isEmpty else { throw AnnotationBackgroundPresetTransferError.emptyFile }
        guard file.presets.count <= Limits.maximumPresetCount else {
            throw AnnotationBackgroundPresetTransferError.tooManyPresets
        }
        return file
    }

    struct Preset: Codable {
        var name: String
        var style: PortableRecordingStudioStyle
        var omitted: [AnnotationBackgroundPresetTransferFile.Omission]
    }
}

/// Everything a Studio style holds but a local wallpaper path.
struct PortableRecordingStudioStyle: Codable {
    var background: PortableBackgroundStyle
    var padding: Double
    var cornerRadius: Double
    var shadow: Double
    var cursorScale: Double
    var hidesCursor: Bool
    var cameraIsVisible: Bool
    var cameraCenterX: Double
    var cameraCenterY: Double
    var cameraSize: Double
    var cameraRoundness: Double

    private(set) var didOmitWallpaper = false

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, cursorScale, hidesCursor
        case cameraIsVisible, cameraCenterX, cameraCenterY, cameraSize, cameraRoundness
    }

    init(_ style: RecordingStudioStyle) {
        if let portable = PortableBackgroundStyle(style.background) {
            background = portable
        } else {
            background = .none
            didOmitWallpaper = true
        }
        padding = Double(style.padding)
        cornerRadius = Double(style.cornerRadius)
        shadow = Double(style.shadow)
        cursorScale = Double(style.cursorScale)
        hidesCursor = style.hidesCursor
        cameraIsVisible = style.camera.isVisible
        cameraCenterX = Double(style.camera.center.x)
        cameraCenterY = Double(style.camera.center.y)
        cameraSize = Double(style.camera.size)
        cameraRoundness = Double(style.camera.roundness)
    }

    /// Kept to the ranges Studio's controls offer, since the file came from
    /// elsewhere.
    var studioStyle: RecordingStudioStyle {
        let clamp = PortableBackgroundSettings.clamp
        return RecordingStudioStyle(
            background: background.backgroundStyle,
            padding: CGFloat(clamp(padding, 0...0.18)),
            cornerRadius: CGFloat(clamp(cornerRadius, 0...0.08)),
            shadow: CGFloat(clamp(shadow, 0...1)),
            cursorScale: CGFloat(clamp(cursorScale, 1...4)),
            hidesCursor: hidesCursor,
            camera: RecordingCameraBubbleSettings(
                isVisible: cameraIsVisible,
                center: CGPoint(x: clamp(cameraCenterX, 0...1), y: clamp(cameraCenterY, 0...1)),
                size: CGFloat(clamp(cameraSize, 0.12...0.45)),
                roundness: CGFloat(clamp(cameraRoundness, 0.05...0.5))
            )
        )
    }
}

extension AnnotationBackgroundPresetStore {
    func exportedData(for id: UUID) throws -> (data: Data, omitsWallpaper: Bool) {
        let file = try transferFile(for: id)
        return (try file.encodedData(), file.presets.first?.omitted.contains(.wallpaper) == true)
    }

    func importStyles(from url: URL) throws -> (presets: [AnnotationBackgroundPreset], omittedWallpaperCount: Int) {
        let result = try importTransferFile(AnnotationBackgroundPresetTransferFile.load(from: url))
        return (result.importedPresets, result.omittedWallpaperCount)
    }
}

extension RecordingStudioStylePresetStore {
    func exportedData(for id: UUID) throws -> (data: Data, omitsWallpaper: Bool) {
        guard let preset = preset(id: id) else { throw AnnotationBackgroundPresetTransferError.presetNotFound }
        let file = RecordingStudioStyleTransferFile(preset: preset)
        return (try file.encodedData(), file.presets.first?.omitted.contains(.wallpaper) == true)
    }

    func importStyles(from url: URL) throws -> (presets: [RecordingStudioStylePreset], omittedWallpaperCount: Int) {
        let file = try RecordingStudioStyleTransferFile.load(from: url)
        let imported = importPresets(file.presets.map { (name: $0.name, style: $0.style.studioStyle) })
        return (imported, file.presets.filter { $0.omitted.contains(.wallpaper) }.count)
    }
}
