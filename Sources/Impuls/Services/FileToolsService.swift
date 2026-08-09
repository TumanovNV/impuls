import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        }
    }

    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

enum ImageResizePreset: Int, CaseIterable, Identifiable, Sendable {
    case pixels1920 = 1920
    case pixels1280 = 1280
    case pixels800 = 800

    var id: Int { rawValue }
    var title: String { localized("Fit Within %d px", rawValue) }
}

enum FileToolsError: LocalizedError, Equatable, Sendable {
    case notAnImage
    case couldNotReadImage
    case couldNotWriteImage
    case imageAlreadyFits
    case noTextFound
    case noForegroundFound
    case requiresTwoImages
    case couldNotCreatePDF
    case sharingUnavailable
    case generatedFileChanged
    case undoUnavailable

    var errorDescription: String? {
        switch self {
        case .notAnImage: return localized("The selected file is not a supported image.")
        case .couldNotReadImage: return localized("Impuls could not read this image.")
        case .couldNotWriteImage: return localized("Impuls could not write the converted image.")
        case .imageAlreadyFits: return localized("The image is already within the selected size.")
        case .noTextFound: return localized("No text was found in the image.")
        case .noForegroundFound: return localized("No foreground object was found.")
        case .requiresTwoImages: return localized("Select at least two images.")
        case .couldNotCreatePDF: return localized("Impuls could not create the PDF.")
        case .sharingUnavailable: return localized("The macOS sharing service is not available.")
        case .generatedFileChanged: return localized("A generated file changed after the operation and was not moved to the Trash.")
        case .undoUnavailable: return localized("The last file operation can no longer be undone.")
        }
    }
}

/// A lightweight identity snapshot used to make Undo conservative. Impuls only
/// trashes a generated file when it is still the same file, with the same size
/// and modification date, that the operation just created. If the user edits or
/// replaces it, Undo refuses to touch it.
struct GeneratedFileRecord: Equatable, Sendable {
    let url: URL
    let fileSize: Int
    let modificationDate: Date
    let resourceIdentifier: String?

    static func capture(_ url: URL) throws -> GeneratedFileRecord {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        guard let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            throw FileToolsError.undoUnavailable
        }
        return GeneratedFileRecord(
            url: url,
            fileSize: fileSize,
            modificationDate: modificationDate,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    func matchesCurrentFile() -> Bool {
        guard let current = try? Self.capture(url) else { return false }
        return fileSize == current.fileSize
            && modificationDate == current.modificationDate
            && resourceIdentifier == current.resourceIdentifier
    }
}

/// Local image and document operations used by the shelf. Every transforming
/// operation writes to a new unique URL next to the source and never replaces
/// the original file.
enum FileToolsService {
    static func isImage(_ url: URL) -> Bool {
        ClipboardContentClassifier.kind(for: url) == .image
    }

    static func imageURLs(_ urls: [URL]) -> [URL] {
        urls.filter(isImage)
    }

    static func recognizeText(in url: URL) throws -> String {
        let image = try loadImage(at: url)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let verticalDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if verticalDistance < 0.02 { return lhs.boundingBox.minX < rhs.boundingBox.minX }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileToolsError.noTextFound
        }
        return text
    }

    static func convertImage(at source: URL, to format: ImageOutputFormat) throws -> URL {
        let image = try loadImage(at: source)
        let stem = source.deletingPathExtension().lastPathComponent + "-" + format.rawValue
        let output = uniqueOutputURL(
            directory: source.deletingLastPathComponent(),
            stem: stem,
            fileExtension: format.fileExtension
        )
        do {
            try write(image, to: output, as: format)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func resizeImage(at source: URL, maxPixelSize: Int) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw FileToolsError.couldNotReadImage
        }
        guard max(width.intValue, height.intValue) > maxPixelSize else {
            throw FileToolsError.imageAlreadyFits
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw FileToolsError.couldNotReadImage
        }

        let sourceFormat = outputFormat(for: source) ?? .png
        let stem = source.deletingPathExtension().lastPathComponent + "-" + String(maxPixelSize) + "px"
        let output = uniqueOutputURL(
            directory: source.deletingLastPathComponent(),
            stem: stem,
            fileExtension: sourceFormat.fileExtension
        )
        do {
            try write(image, to: output, as: sourceFormat)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func combineImagesIntoPDF(_ sources: [URL]) throws -> URL {
        let images = imageURLs(sources)
        guard images.count >= 2 else { throw FileToolsError.requiresTwoImages }

        let first = images[0]
        let output = uniqueOutputURL(
            directory: first.deletingLastPathComponent(),
            stem: first.deletingPathExtension().lastPathComponent + "-combined",
            fileExtension: "pdf"
        )
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FileToolsError.couldNotCreatePDF
        }

        do {
            for url in images {
                let image = try loadImage(at: url)
                context.beginPDFPage(nil)
                let inset = mediaBox.insetBy(dx: 24, dy: 24)
                let scale = min(
                    inset.width / CGFloat(image.width),
                    inset.height / CGFloat(image.height)
                )
                let size = CGSize(
                    width: CGFloat(image.width) * scale,
                    height: CGFloat(image.height) * scale
                )
                let rect = CGRect(
                    x: mediaBox.midX - size.width / 2,
                    y: mediaBox.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                context.interpolationQuality = .high
                context.draw(image, in: rect)
                context.endPDFPage()
            }
            context.closePDF()
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    static func removeBackground(from source: URL) throws -> URL {
        let image = try loadImage(at: source)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw FileToolsError.noForegroundFound
        }

        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let foreground = CIImage(cgImage: image)
        let mask = CIImage(cvPixelBuffer: buffer)
        let transparent = CIImage(color: .clear).cropped(to: foreground.extent)
        guard let blended = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: foreground,
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask,
            ]
        )?.outputImage,
        let result = CIContext().createCGImage(blended, from: foreground.extent) else {
            throw FileToolsError.noForegroundFound
        }

        let output = uniqueOutputURL(
            directory: source.deletingLastPathComponent(),
            stem: source.deletingPathExtension().lastPathComponent + "-no-background",
            fileExtension: "png"
        )
        do {
            try write(result, to: output, as: .png)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func uniqueOutputURL(directory: URL, stem: String, fileExtension: String) -> URL {
        let normalizedExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(normalizedExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem)-\(index)")
                .appendingPathExtension(normalizedExtension)
            index += 1
        }
        return candidate
    }

    /// Moves files created by the last Impuls operation to the macOS Trash. A
    /// complete preflight happens before the first move so one edited result
    /// cannot leave a batch half-undone.
    static func moveGeneratedFilesToTrash(_ records: [GeneratedFileRecord]) throws {
        guard !records.isEmpty else { throw FileToolsError.undoUnavailable }
        guard records.allSatisfy({ $0.matchesCurrentFile() }) else {
            throw FileToolsError.generatedFileChanged
        }
        for record in records {
            try FileManager.default.trashItem(at: record.url, resultingItemURL: nil)
        }
    }

    private static func loadImage(at url: URL) throws -> CGImage {
        guard isImage(url) else { throw FileToolsError.notAnImage }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true,
              ] as CFDictionary) else {
            throw FileToolsError.couldNotReadImage
        }
        return image
    }

    private static func outputFormat(for url: URL) -> ImageOutputFormat? {
        let ext = url.pathExtension.lowercased()
        if ext == "png" { return .png }
        if ext == "jpg" || ext == "jpeg" { return .jpeg }
        if ext == "heic" || ext == "heif" { return .heic }
        return nil
    }

    private static func write(_ image: CGImage, to url: URL, as format: ImageOutputFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.type.identifier as CFString,
            1,
            nil
        ) else { throw FileToolsError.couldNotWriteImage }

        let options: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw FileToolsError.couldNotWriteImage
        }
    }
}
