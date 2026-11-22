//
//  HeadlessCaptureFileTests.swift
//  SnapzyTests
//
//  Staging folder naming/retention and the max-dimension post-processor.
//

import ImageIO
import Testing
@testable import Snapzy
import UniformTypeIdentifiers
import XCTest

final class HeadlessCaptureStagingTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HeadlessCaptureStagingTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testDirectoryIsOutsideTempCaptureRoot() {
    let path = HeadlessCaptureStaging.directory.path

    XCTAssertTrue(path.hasSuffix("OwnShot/CLI/Captures"), path)
    XCTAssertFalse(path.contains("OwnShot/Captures"), "TempCaptureManager sweeps OwnShot/Captures at launch")
  }

  func testFileNameShape() throws {
    let date = try XCTUnwrap(DateComponents(
      calendar: .current,
      year: 2026,
      month: 10,
      day: 25,
      hour: 9,
      minute: 30,
      second: 12
    ).date)
    let name = HeadlessCaptureStaging.makeFileName(now: date)

    XCTAssertTrue(name.hasPrefix("snapzy-cli-20261025-093012-"), name)
    XCTAssertEqual(name.count, "snapzy-cli-20261025-093012-".count + 6)
    XCTAssertNotEqual(name, HeadlessCaptureStaging.makeFileName(now: date))
  }

  func testPrepareCreatesPrivateDirectoryAndSweepsExpiredFiles() throws {
    let now = Date()
    try HeadlessCaptureStaging.prepare(in: directory, now: now)
    let fresh = directory.appendingPathComponent("fresh.png")
    let expired = directory.appendingPathComponent("expired.png")
    try Data("a".utf8).write(to: fresh)
    try Data("b".utf8).write(to: expired)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-HeadlessCaptureStaging.retention - 60)],
      ofItemAtPath: expired.path
    )

    try HeadlessCaptureStaging.prepare(in: directory, now: now)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o700)
  }
}

final class HeadlessCapturePostProcessorTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HeadlessCapturePostProcessorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// A solid image written at `scale`× (DPI = 72 × scale), like Snapzy's saver.
  private func writeImage(width: Int, height: Int, scale: Double, type: UTType, name: String) throws -> URL {
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())

    let url = directory.appendingPathComponent(name)
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    let dpi = scale * 72
    CGImageDestinationAddImage(destination, image, [
      kCGImagePropertyDPIWidth: dpi,
      kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  func testFileInfoReadsSizeAndScale() throws {
    let url = try writeImage(width: 400, height: 200, scale: 2, type: .png, name: "a.png")

    let info = try HeadlessCapturePostProcessor.fileInfo(at: url)

    XCTAssertEqual(info.pixelWidth, 400)
    XCTAssertEqual(info.pixelHeight, 200)
    XCTAssertEqual(info.scale, 2, accuracy: 0.001)
    XCTAssertGreaterThan(info.byteCount, 0)
  }

  func testDownscaleKeepsAspectRatioAndAdjustsScale() throws {
    let url = try writeImage(width: 400, height: 200, scale: 2, type: .png, name: "b.png")

    try HeadlessCapturePostProcessor.downscale(fileAt: url, format: .png, maxDimension: 100)
    let info = try HeadlessCapturePostProcessor.fileInfo(at: url)

    XCTAssertEqual(info.pixelWidth, 100)
    XCTAssertEqual(info.pixelHeight, 50)
    XCTAssertEqual(info.scale, 0.5, accuracy: 0.001)
  }

  func testProcessKeepsDPIScaleForPNG() throws {
    let url = try writeImage(width: 400, height: 200, scale: 2, type: .png, name: "e.png")

    let info = try HeadlessCapturePostProcessor.process(fileAt: url, format: .png, maxDimension: 200, displayScale: 3)

    XCTAssertEqual(info.pixelWidth, 200)
    XCTAssertEqual(info.scale, 1, accuracy: 0.01, "PNG scale comes from its DPI, not the display")
  }

  func testWebPReportsActualOneXCaptureScaleInsteadOfRetinaDisplayScale() throws {
    // Метаданные WebP не содержат DPI. Для чтения размеров подходит тот же растр.
    let url = try writeImage(width: 200, height: 100, scale: 1, type: .png, name: "one-x.webp")
    let info = try HeadlessCapturePostProcessor.process(fileAt: url, format: .webp,
      maxDimension: nil, displayScale: 2, captureScale: 1)
    XCTAssertEqual(info.scale, 1)
    XCTAssertEqual(info.pixelWidth, 200)
  }

  func testDownscaleNeverUpscales() throws {
    let url = try writeImage(width: 80, height: 40, scale: 1, type: .png, name: "c.png")

    try HeadlessCapturePostProcessor.downscale(fileAt: url, format: .png, maxDimension: 1568)

    XCTAssertEqual(try HeadlessCapturePostProcessor.fileInfo(at: url).pixelWidth, 80)
  }

  func testDownscaleKeepsJPEG() throws {
    let url = try writeImage(width: 300, height: 600, scale: 2, type: .jpeg, name: "d.jpg")

    try HeadlessCapturePostProcessor.downscale(fileAt: url, format: .jpeg(quality: 0.8), maxDimension: 150)

    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    let info = try HeadlessCapturePostProcessor.fileInfo(at: url)
    XCTAssertEqual(info.pixelWidth, 75)
    XCTAssertEqual(info.pixelHeight, 150)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
    XCTAssertEqual(leftovers, [])
  }
}


struct HeadlessCaptureBorderParityTests {
  @Test("Рамка headless использует итоговую плотность без резерва внешних пикселей",
    arguments: [200, 400])
  func borderAfterFinalResize(maxDimension: Int) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HeadlessBorderParity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let fixture = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    fixture.setFillColor(CGColor(srgbRed: 120 / 255, green: 130 / 255, blue: 140 / 255, alpha: 1))
    fixture.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    let sourceImage = try #require(fixture.makeImage())
    let url = directory.appendingPathComponent("source.png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, sourceImage,
      [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    let info = try HeadlessCapturePostProcessor.process(fileAt: url, format: .png,
      maxDimension: maxDimension, displayScale: 3, captureScale: 2, addPixelBorder: true)
    #expect(info.pixelWidth == maxDimension)
    #expect(info.pixelHeight == maxDimension / 2)
    let scale = Double(maxDimension) / 200
    #expect(abs(info.scale - scale) < 0.01)
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let decoded = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    decoded.setBlendMode(.copy)
    decoded.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(decoded.data)
    let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    let width = image.width
    let thickness = maxDimension / 200
    var mismatchedPixels = 0
    for y in 0..<image.height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        let actual = Array(pixels[index..<(index + 4)])
        let isEdge = min(x, y, width - x - 1, image.height - y - 1) < thickness
        if actual != (isEdge ? [124, 129, 134, 255] : [120, 130, 140, 255]) { mismatchedPixels += 1 }
      }
    }
    #expect(mismatchedPixels == 0)
  }
}
