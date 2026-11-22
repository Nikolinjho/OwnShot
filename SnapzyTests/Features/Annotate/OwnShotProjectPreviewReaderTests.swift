//
//  OwnShotProjectPreviewReaderTests.swift
//  SnapzyTests
//
//  Разбор .ownshot для Quick Look Preview и Thumbnail: preview.png и thumbnail.png из ZIP.
//

import AppKit
import ImageIO
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotProjectPreviewReaderTests: XCTestCase {
  func testEntryPathsMatchProjectFormat() {
    XCTAssertEqual(OwnShotProjectPreviewReader.previewEntry, OwnShotProjectFormat.previewEntry)
    XCTAssertEqual(OwnShotProjectPreviewReader.thumbnailEntry, OwnShotProjectFormat.thumbnailEntry)
  }

  func testPreviewDataReadsPreviewFromProjectWrittenByStore() throws {
    let preview = try makeImage(width: 600, height: 300)
    let entries = try OwnShotProjectStore.entries(for: makeSessionData(), preview: preview)
    let archive = try archiveData(entries)

    let data = try OwnShotProjectPreviewReader.previewData(fromArchive: archive)
    let expected = try XCTUnwrap(entries.first { $0.name == OwnShotProjectFormat.previewEntry }?.data)
    XCTAssertEqual(data, expected)
    XCTAssertEqual(OwnShotProjectPreviewReader.pixelSize(of: data), CGSize(width: 600, height: 300))
  }

  func testThumbnailPrefersSmallThumbnailWhenItCoversRequestedSize() throws {
    let entries = try OwnShotProjectStore.entries(for: makeSessionData(), preview: makeImage(width: 600, height: 300))
    let archive = try archiveData(entries)

    let small = try OwnShotProjectPreviewReader.thumbnailData(fromArchive: archive, maximumPixelSide: 128)
    XCTAssertEqual(OwnShotProjectPreviewReader.pixelSize(of: small), CGSize(width: 256, height: 128))

    // Для крупной иконки thumbnail.png мала, берётся итоговый рендер.
    let large = try OwnShotProjectPreviewReader.thumbnailData(fromArchive: archive, maximumPixelSide: 512)
    XCTAssertEqual(OwnShotProjectPreviewReader.pixelSize(of: large), CGSize(width: 600, height: 300))
  }

  func testThumbnailFallsBackToThumbnailWithoutPreviewAndToPreviewWithoutThumbnail() throws {
    let thumbnail = try pngData(width: 64, height: 32)
    let onlyThumbnail = try archiveData([entry(OwnShotProjectFormat.thumbnailEntry, thumbnail)])
    XCTAssertEqual(try OwnShotProjectPreviewReader.thumbnailData(fromArchive: onlyThumbnail, maximumPixelSide: 512), thumbnail)

    let preview = try pngData(width: 40, height: 20)
    let onlyPreview = try archiveData([entry(OwnShotProjectFormat.previewEntry, preview)])
    XCTAssertEqual(try OwnShotProjectPreviewReader.thumbnailData(fromArchive: onlyPreview, maximumPixelSide: 16), preview)
  }

  func testProjectWithoutPreviewThrowsMissingPreview() throws {
    // Проект, сохранённый без рендера: Quick Look должен отдать ошибку, а не пустую картинку.
    let entries = try OwnShotProjectStore.entries(for: makeSessionData(), preview: nil)
    let archive = try archiveData(entries)

    XCTAssertThrowsError(try OwnShotProjectPreviewReader.previewData(fromArchive: archive)) { error in
      XCTAssertEqual(error as? OwnShotProjectPreviewReader.PreviewError, .missingPreview)
    }
    XCTAssertThrowsError(try OwnShotProjectPreviewReader.thumbnailData(fromArchive: archive, maximumPixelSide: 64)) { error in
      XCTAssertEqual(error as? OwnShotProjectPreviewReader.PreviewError, .missingPreview)
    }
  }

  func testNonArchiveDataThrowsReaderError() {
    XCTAssertThrowsError(try OwnShotProjectPreviewReader.previewData(fromArchive: Data("not a zip".utf8))) { error in
      XCTAssertEqual(error as? ZipArchiveReader.ReadError, .notAnArchive)
    }
  }

  func testAspectFitKeepsProportionsAndDoesNotUpscale() {
    XCTAssertEqual(
      OwnShotProjectPreviewReader.aspectFitSize(CGSize(width: 600, height: 300), in: CGSize(width: 128, height: 128)),
      CGSize(width: 128, height: 64)
    )
    XCTAssertEqual(
      OwnShotProjectPreviewReader.aspectFitSize(CGSize(width: 100, height: 400), in: CGSize(width: 256, height: 200)),
      CGSize(width: 50, height: 200)
    )
    XCTAssertEqual(
      OwnShotProjectPreviewReader.aspectFitSize(CGSize(width: 40, height: 20), in: CGSize(width: 512, height: 512)),
      CGSize(width: 40, height: 20)
    )
    XCTAssertEqual(OwnShotProjectPreviewReader.aspectFitSize(.zero, in: CGSize(width: 10, height: 10)), .zero)
  }

  func testThumbnailContextSizeConvertsPixelsToPointsAndFitsMaximumSize() {
    // Finder, вид значков 256 на Retina: картинка 1200×600 px вписывается в 256×256 pt.
    XCTAssertEqual(
      OwnShotProjectPreviewReader.thumbnailContextSize(
        imagePixelSize: CGSize(width: 1200, height: 600),
        maximumSize: CGSize(width: 256, height: 256),
        scale: 2
      ),
      CGSize(width: 256, height: 128)
    )
    // Картинка меньше рамки остаётся в своих пикселях: 300 px на scale 2 – 150 pt.
    XCTAssertEqual(
      OwnShotProjectPreviewReader.thumbnailContextSize(
        imagePixelSize: CGSize(width: 300, height: 100),
        maximumSize: CGSize(width: 256, height: 256),
        scale: 2
      ),
      CGSize(width: 150, height: 50)
    )
    // scale меньше 1 не увеличивает картинку.
    XCTAssertEqual(
      OwnShotProjectPreviewReader.thumbnailContextSize(
        imagePixelSize: CGSize(width: 64, height: 32),
        maximumSize: CGSize(width: 256, height: 256),
        scale: 0
      ),
      CGSize(width: 64, height: 32)
    )
  }

  func testThumbnailDrawRectCoversWholeBitmap() {
    // Контекст без масштаба в CTM: рисуем на весь битмап в пикселях, а не в точках.
    XCTAssertEqual(
      OwnShotProjectPreviewReader.thumbnailDrawRect(
        contextPixelSize: CGSize(width: 512, height: 256),
        userSpaceToDevice: .identity
      ),
      CGRect(x: 0, y: 0, width: 512, height: 256)
    )
    // Масштаб уже в CTM: тот же битмап в пользовательских координатах – точки.
    XCTAssertEqual(
      OwnShotProjectPreviewReader.thumbnailDrawRect(
        contextPixelSize: CGSize(width: 512, height: 256),
        userSpaceToDevice: CGAffineTransform(scaleX: 2, y: 2)
      ),
      CGRect(x: 0, y: 0, width: 256, height: 128)
    )
  }

  func testThumbnailDrawRectFillsRealBitmapContext() throws {
    // Настоящий битмап-контекст как у QLThumbnailReply: 256×128 pt на scale 2.
    let pixelSize = CGSize(width: 512, height: 256)
    let context = try XCTUnwrap(CGContext(
      data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let rect = OwnShotProjectPreviewReader.thumbnailDrawRect(
      contextPixelSize: CGSize(width: context.width, height: context.height),
      userSpaceToDevice: context.userSpaceToDeviceSpaceTransform
    )
    XCTAssertEqual(rect.applying(context.userSpaceToDeviceSpaceTransform), CGRect(origin: .zero, size: pixelSize))
  }

  // MARK: - Вспомогательное

  private func archiveData(_ entries: [ZipArchiveWriter.Entry]) throws -> Data {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_OwnShotPreview_\(UUID().uuidString).ownshot")
    defer { try? FileManager.default.removeItem(at: url) }
    try ZipArchiveWriter.write(entries: entries, to: url)
    return try Data(contentsOf: url)
  }

  private func entry(_ name: String, _ data: Data) -> ZipArchiveWriter.Entry {
    ZipArchiveWriter.Entry(name: name, data: data, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func makeSessionData() throws -> AnnotationSessionData {
    AnnotationSessionData(
      originalImageData: try pngData(width: 80, height: 40),
      annotations: [],
      canvasEffects: AnnotationCanvasEffects(),
      selectedCanvasPresetId: nil,
      isSelectedCanvasPresetDirty: false,
      cropRect: nil,
      isCutoutApplied: false,
      cutoutImageData: nil,
      embeddedImageAssetsData: [:],
      sourceLogicalSize: nil
    )
  }

  private func makeImage(width: Int, height: Int) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
  }

  private func pngData(width: Int, height: Int) throws -> Data {
    try XCTUnwrap(AnnotateExporter.imageData(from: makeImage(width: width, height: height), for: "png"))
  }
}
