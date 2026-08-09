import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ImpulsCore

final class FileToolsServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpulsFileToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testUniqueOutputNeverReplacesAnExistingFile() throws {
        let first = temporaryDirectory.appendingPathComponent("photo-png.png")
        try Data([0]).write(to: first)

        let output = FileToolsService.uniqueOutputURL(
            directory: temporaryDirectory,
            stem: "photo-png",
            fileExtension: "png"
        )

        XCTAssertEqual(output.lastPathComponent, "photo-png-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testConversionAndResizeCreateNewReadableImages() throws {
        let source = try makeImage(named: "source.png", width: 120, height: 60)

        let jpeg = try FileToolsService.convertImage(at: source, to: .jpeg)
        let resized = try FileToolsService.resizeImage(at: source, maxPixelSize: 40)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(jpeg.pathExtension, "jpg")
        XCTAssertNotNil(CGImageSourceCreateWithURL(jpeg as CFURL, nil))

        let resizedSource = try XCTUnwrap(CGImageSourceCreateWithURL(resized as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(resizedSource, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber)
        XCTAssertLessThanOrEqual(max(width.intValue, height.intValue), 40)
    }

    func testCombiningImagesProducesOnePagePerInput() throws {
        let first = try makeImage(named: "first.png", width: 40, height: 30)
        let second = try makeImage(named: "second.png", width: 30, height: 40)

        let output = try FileToolsService.combineImagesIntoPDF([first, second])
        let document = try XCTUnwrap(PDFDocument(url: output))

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSafeRenamePreservesExtensionAndRejectsEscapesAndCollisions() throws {
        let source = try makeImage(named: "original.png", width: 10, height: 10)
        let target = try ShelfStore.safeRenameTarget(for: source, baseName: "renamed")
        XCTAssertEqual(target.lastPathComponent, "renamed.png")

        XCTAssertThrowsError(try ShelfStore.safeRenameTarget(for: source, baseName: "../escape"))

        try Data([0]).write(to: target)
        XCTAssertThrowsError(try ShelfStore.safeRenameTarget(for: source, baseName: "renamed"))
    }

    func testResizeRefusesToUpscale() throws {
        let source = try makeImage(named: "small.png", width: 20, height: 10)
        XCTAssertThrowsError(try FileToolsService.resizeImage(at: source, maxPixelSize: 40)) { error in
            XCTAssertEqual(error as? FileToolsError, .imageAlreadyFits)
        }
    }

    func testFullImageDecodeHasAPixelSafetyLimit() throws {
        XCTAssertNoThrow(try FileToolsService.validateImageDimensions(width: 8_000, height: 8_000))
        XCTAssertThrowsError(
            try FileToolsService.validateImageDimensions(width: 10_000, height: 10_000)
        ) { error in
            XCTAssertEqual(error as? FileToolsError, .imageTooLarge)
        }
        XCTAssertThrowsError(try FileToolsService.validateImageDimensions(width: 0, height: 100))
    }

    func testPlayerArtworkIsDownsampledToItsDisplayBudget() throws {
        let source = try makeImage(named: "artwork.png", width: 2_000, height: 1_000)
        let data = try Data(contentsOf: source)
        let image = try XCTUnwrap(PlayerBridge.thumbnailArtwork(from: data))

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), CGFloat(PlayerBridge.artworkPixelSize))
    }

    func testGeneratedFileRecordDetectsAChangedFile() throws {
        let output = temporaryDirectory.appendingPathComponent("generated.bin")
        try Data([0]).write(to: output)
        let record = try GeneratedFileRecord.capture(output)

        XCTAssertTrue(record.matchesCurrentFile())

        try Data([0, 1, 2]).write(to: output)
        XCTAssertFalse(record.matchesCurrentFile())
    }

    func testGeneratedFileRecordDetectsSameSizeChangeWithRestoredTimestamp() throws {
        let output = temporaryDirectory.appendingPathComponent("generated-same-size.bin")
        try Data([0, 1, 2]).write(to: output)
        let record = try GeneratedFileRecord.capture(output)

        try Data([2, 1, 0]).write(to: output)
        try FileManager.default.setAttributes(
            [.modificationDate: record.modificationDate],
            ofItemAtPath: output.path
        )

        XCTAssertFalse(record.matchesCurrentFile())
    }

    func testRenameCanBeRestoredAndSelectionSurvives() async throws {
        let source = try makeImage(named: "restore-me.png", width: 10, height: 10)
        try await MainActor.run {
            UserDefaults.standard.removeObject(forKey: "shelf.urls")
            defer { UserDefaults.standard.removeObject(forKey: "shelf.urls") }

            let store = ShelfStore()
            store.add([source])
            let original = try XCTUnwrap(store.items.first)
            store.selectAll()

            let renamed = try store.rename(original, baseName: "renamed")
            XCTAssertEqual(renamed.name, "renamed.png")

            let restored = try store.restoreName(
                itemID: renamed.id,
                currentURL: renamed.url,
                originalURL: source
            )
            XCTAssertEqual(restored.url, source)
            XCTAssertTrue(store.selection.contains(restored.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            store.clear()
        }
    }

    private func makeImage(named name: String, width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let url = temporaryDirectory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
