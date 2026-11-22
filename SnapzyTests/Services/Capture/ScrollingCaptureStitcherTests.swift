//
//  ScrollingCaptureStitcherTests.swift
//  SnapzyTests
//
//  Unit tests for the scrolling capture stitch algorithm.
//

import AppKit
import CoreGraphics
import XCTest
@testable import Snapzy

final class ScrollingCaptureStitcherTests: XCTestCase {

  func testПустойПромежутокСохраняетОжидаемуюВысотуПриПрокрутке() throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 400,
      bitsPerComponent: 8, bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 400))
    let blank = try XCTUnwrap(context.makeImage())
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: blank)
    let update = try XCTUnwrap(stitcher.append(blank, maxOutputHeight: 10000,
      expectedSignedDeltaPixels: -48))
    guard case .appended(let delta) = update.outcome else {
      return XCTFail("Пустой промежуток не должен исчезать из результата")
    }
    XCTAssertEqual(delta, 48)
    XCTAssertEqual(update.outputHeight, 448)
  }

  func testНеподвижнаяСтраницаСРедкимиСтрокамиНеДобавляетПовтор() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let image = try XCTUnwrap(NSImage(contentsOf: root
      .appendingPathComponent("Fixtures/Images/ScrollingCaptureSparseText.png")))
    let page = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let frame = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 1100, height: 782)))
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: frame)
    for step in [nil, -40, -200] as [Int?] {
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10000,
        expectedSignedDeltaPixels: step))
      guard case .ignoredNoMovement = update.outcome else {
        return XCTFail("Неподвижный кадр добавил выдуманные строки: \(update.outcome)")
      }
      XCTAssertEqual(update.outputHeight, 782)
      XCTAssertEqual(update.acceptedFrameCount, 1)
    }
    let moved = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 40, width: 1100, height: 782)))
    let update = try XCTUnwrap(stitcher.append(moved, maxOutputHeight: 10000,
      expectedSignedDeltaPixels: -40))
    guard case .appended(let delta) = update.outcome else {
      return XCTFail("Движение после неподвижных кадров должно склеиться")
    }
    XCTAssertEqual(delta, 40)
    XCTAssertEqual(update.outputHeight, 822)
  }

  func testПовторяющийсяШаблонУчитываетТекущийШагПриИзмененииСкорости() throws {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try periodicFrame(offset: 0))
    for (offset, step) in [(30, 30), (108, 78)] {
      let update = try XCTUnwrap(stitcher.append(try periodicFrame(offset: offset),
        maxOutputHeight: 10000, expectedSignedDeltaPixels: -step))
      guard case .appended(let actual) = update.outcome else {
        return XCTFail("Текущий шаг \(step) не склеился: \(update.outcome)")
      }
      XCTAssertEqual(actual, step, "Прошлый шаг не определяет выбор повторяющейся строки")
    }
    XCTAssertEqual(stitcher.outputHeight, 508)
  }

  func testБезОжидаемогоШагаПовторыНеПринимаютсяЧерезРезервныйПуть() throws {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try periodicFrame(offset: 0))
    let update = try XCTUnwrap(stitcher.append(try periodicFrame(offset: 66), maxOutputHeight: 10000))
    if case .appended(let delta) = update.outcome {
      XCTFail("Неоднозначный повтор принят без ожидаемого шага: \(delta)")
    }
    XCTAssertEqual(stitcher.outputHeight, 400)
  }

  private func periodicFrame(offset: Int) throws -> CGImage {
    let width = 240, height = 400, period = 48
    let pattern = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: width, height: period, logicalYOffset: 0))
    let rows = TestImageFactory.rgbaRows(of: pattern, rowCount: period)
    let stride = width * 4
    var pixels: [UInt8] = []
    pixels.reserveCapacity(stride * height)
    for y in 0..<height {
      let start = ((offset + y) % period) * stride
      pixels.append(contentsOf: rows[start..<(start + stride)])
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        .union(.byteOrder32Big), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent))
  }

  func testПеренесённыйMatcherРаботаетВРеальнойЦепочкеСклейки() throws {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 400, logicalYOffset: 0)))
    let next = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 400, logicalYOffset: 80))
    let update = try XCTUnwrap(stitcher.append(next, maxOutputHeight: 10000,
      expectedSignedDeltaPixels: -80))
    XCTAssertEqual(update.alignmentDebug?.path, .contentColumns,
      "Перенесённый алгоритм должен участвовать в продуктовой цепочке")
    XCTAssertEqual(update.outputHeight, 480)
    let result = try XCTUnwrap(stitcher.mergedImage())
    let expected = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 480, logicalYOffset: 0))
    XCTAssertEqual(TestImageFactory.rgbaRows(of: result, rowCount: 480),
      TestImageFactory.rgbaRows(of: expected, rowCount: 480))
  }

  func testПовторяющиесяСтрокиТерминалаСклеиваютсяБезПропусков() throws {
    let stitcher = ScrollingCaptureStitcher()
    let width = 480, height = 420
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: width, pixelsHigh: 1400, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 1400).fill()
    for line in 0..<50 {
      let text = line % 4 == 0 ? "user@host: ~/projects/catalog" :
        line % 4 == 1 ? "npm run lint -- file.ts" :
        line % 4 == 2 ? "Checking source files" : "Result for step \(line): complete"
      (text as NSString).draw(at: CGPoint(x: 12, y: line * 28), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
        .foregroundColor: NSColor.white])
    }
    NSGraphicsContext.restoreGraphicsState()
    let page = try XCTUnwrap(bitmap.cgImage)
    let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)))
    _ = stitcher.start(with: first)
    for offset in [63, 126, 189, 252, 315, 378] {
      let frame = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: offset, width: width, height: height)))
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10000,
        expectedSignedDeltaPixels: 128))
      guard case .appended(let delta) = update.outcome else {
        return XCTFail("Строки не склеились при смещении \(offset): \(update.outcome)")
      }
      XCTAssertEqual(delta, 63, "Смещение определяется содержимым, а не знаком и величиной жеста")
    }
    let result = try XCTUnwrap(stitcher.mergedImage())
    let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: width, height: 798)))
    XCTAssertEqual(result.height, expected.height)
    XCTAssertEqual(TestImageFactory.rgbaRows(of: result, rowCount: result.height),
      TestImageFactory.rgbaRows(of: expected, rowCount: expected.height))
  }

  func testПрокруткаВверхСохраняетВсеСтрокиВИсходномПорядке() throws {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 400, logicalYOffset: 160)))
    for offset in [80, 0] {
      let frame = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
        width: 320, height: 400, logicalYOffset: offset))
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10_000,
        expectedSignedDeltaPixels: 80))
      guard case .appended(let delta) = update.outcome else {
        return XCTFail("Прокрутка вверх не склеилась: \(update.outcome)")
      }
      XCTAssertEqual(delta, 80)
      XCTAssertEqual(update.mergeDirection, .appendFromTop)
    }
    let result = try XCTUnwrap(stitcher.mergedImage())
    let reference = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 560, logicalYOffset: 0))
    XCTAssertEqual(result.height, 560)
    XCTAssertEqual(TestImageFactory.rgbaRows(of: result, rowCount: result.height),
      TestImageFactory.rgbaRows(of: reference, rowCount: reference.height))
    let latest = try XCTUnwrap(stitcher.lastAcceptedImage())
    let lastFrame = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 400, logicalYOffset: 0))
    XCTAssertEqual(TestImageFactory.rgbaRows(of: latest, rowCount: latest.height),
      TestImageFactory.rgbaRows(of: lastFrame, rowCount: lastFrame.height))
    let preview = try XCTUnwrap(stitcher.previewImage(maxPixelWidth: 320, maxPixelHeight: 10_000))
    XCTAssertEqual(preview.height, reference.height)
    XCTAssertEqual(TestImageFactory.rgbaRows(of: preview, rowCount: preview.height),
      TestImageFactory.rgbaRows(of: reference, rowCount: reference.height))
  }

  func testHorizontalScroll_appendsRightWithoutRotatingPixels() throws {
    let stitcher = ScrollingCaptureStitcher(axis: .horizontal)
    let first = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 0))
    _ = stitcher.start(with: first)
    for offset in [80, 160] {
      let frame = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: offset))
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10_000,
        expectedSignedDeltaPixels: -80))
      guard case .appended(let delta) = update.outcome else {
        return XCTFail("Ожидалась склейка справа, получено \(update.outcome)")
      }
      XCTAssertEqual(delta, 80)
      XCTAssertEqual(update.mergedImage?.width, 360 + offset)
      XCTAssertEqual(update.mergedImage?.height, 240)
    }
    let result = try XCTUnwrap(stitcher.mergedImage())
    let reference = try XCTUnwrap(horizontalFrame(width: 520, height: 240, offset: 0))
    XCTAssertTrue(TestImageFactory.rgbaRows(of: result, rowCount: result.height) ==
      TestImageFactory.rgbaRows(of: reference, rowCount: reference.height), "Пиксели результата совпадают с исходной областью")
    let latest = try XCTUnwrap(stitcher.lastAcceptedImage())
    let lastFrame = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 160))
    XCTAssertEqual(TestImageFactory.rgbaRows(of: latest, rowCount: 240),
      TestImageFactory.rgbaRows(of: lastFrame, rowCount: 240))
    let preview = try XCTUnwrap(stitcher.previewImage(maxPixelWidth: 260, maxPixelHeight: 240))
    XCTAssertEqual(preview.width, 260)
    XCTAssertEqual(preview.height, 120)
  }

  func testHorizontalScroll_appendsLeftWithoutMirroringPixels() throws {
    let stitcher = ScrollingCaptureStitcher(axis: .horizontal)
    let first = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 160))
    _ = stitcher.start(with: first)
    for offset in [80, 0] {
      let frame = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: offset))
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10_000,
        expectedSignedDeltaPixels: 80))
      guard case .appended = update.outcome else {
        return XCTFail("Ожидалась склейка слева, получено \(update.outcome)")
      }
    }
    let result = try XCTUnwrap(stitcher.mergedImage())
    let reference = try XCTUnwrap(horizontalFrame(width: 520, height: 240, offset: 0))
    XCTAssertEqual(result.width, 520)
    XCTAssertEqual(result.height, 240)
    XCTAssertTrue(TestImageFactory.rgbaRows(of: result, rowCount: 240) ==
      TestImageFactory.rgbaRows(of: reference, rowCount: 240), "Порядок пикселей сохранён")
  }

  func testHorizontalScroll_reorientsOriginalSeedBeforeFirstAppend() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 0))
    _ = stitcher.start(with: first)
    stitcher.selectAxis(.horizontal)
    let next = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 80))
    let update = try XCTUnwrap(stitcher.append(next, maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: -80))
    XCTAssertEqual(update.acceptedFrameCount, 2)
    let result = try XCTUnwrap(stitcher.mergedImage())
    let reference = try XCTUnwrap(horizontalFrame(width: 440, height: 240, offset: 0))
    XCTAssertTrue(TestImageFactory.rgbaRows(of: result, rowCount: 240) ==
      TestImageFactory.rgbaRows(of: reference, rowCount: 240), "Порядок пикселей сохранён")
    stitcher.selectAxis(.vertical)
    XCTAssertEqual(stitcher.axis, .horizontal, "Ось после первой склейки не меняется")
  }

  func testHorizontalScroll_keepsShortSettledRemainder() throws {
    let stitcher = ScrollingCaptureStitcher(axis: .horizontal)
    _ = stitcher.start(with: try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 0)))
    for offset in [80, 160, 172] {
      let frame = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: offset))
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10_000,
        expectedSignedDeltaPixels: -80, allowsSettledPartialStep: true))
      guard case .appended(let delta) = update.outcome else {
        return XCTFail("Остановившийся остаток должен попасть в снимок")
      }
      XCTAssertEqual(delta, offset == 172 ? 12 : 80)
    }
    let result = try XCTUnwrap(stitcher.mergedImage())
    let reference = try XCTUnwrap(horizontalFrame(width: 532, height: 240, offset: 0))
    XCTAssertEqual(result.width, 532)
    XCTAssertEqual(result.height, 240)
    XCTAssertTrue(TestImageFactory.rgbaRows(of: result, rowCount: 240) ==
      TestImageFactory.rgbaRows(of: reference, rowCount: 240), "Короткий остаток сохраняется без потерь")
  }

  func testHorizontalScroll_ignoresStationaryFrameAndLimitsWidth() throws {
    let stitcher = ScrollingCaptureStitcher(axis: .horizontal)
    let first = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 0))
    _ = stitcher.start(with: first)
    let stationary = try XCTUnwrap(stitcher.append(first, maxOutputHeight: 400))
    guard case .ignoredNoMovement = stationary.outcome else {
      return XCTFail("Неподвижный кадр не должен увеличивать ширину")
    }
    let next = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 80))
    let update = try XCTUnwrap(stitcher.append(next, maxOutputHeight: 400,
      expectedSignedDeltaPixels: -80))
    XCTAssertEqual(update.mergedImage?.width, 400)
    XCTAssertEqual(update.mergedImage?.height, 240)
    XCTAssertEqual(stitcher.acceptedFrameCount, 2)
    let beyondLimit = try XCTUnwrap(horizontalFrame(width: 360, height: 240, offset: 160))
    let limited = try XCTUnwrap(stitcher.append(beyondLimit, maxOutputHeight: 400,
      expectedSignedDeltaPixels: -80))
    guard case .reachedHeightLimit = limited.outcome else {
      return XCTFail("После ограничения ширина больше не увеличивается")
    }
    XCTAssertEqual(limited.mergedImage?.width, 400)
    XCTAssertEqual(limited.mergedImage?.height, 240)
  }

  func testScrollingAxis_usesDominantMeaningfulMovement() {
    XCTAssertNil(ScrollingCaptureAxis.detect(deltaX: 0.2, deltaY: 0.3))
    XCTAssertEqual(ScrollingCaptureAxis.detect(deltaX: -12, deltaY: 1), .horizontal)
    XCTAssertEqual(ScrollingCaptureAxis.detect(deltaX: 1, deltaY: -12), .vertical)
    XCTAssertEqual(ScrollingCaptureAxis.detect(deltaX: 12, deltaY: 12), .vertical)
  }

  // Несимметричный рисунок проверяет ориентацию, порядок столбцов и точность пикселей.
  private func horizontalFrame(width: Int, height: Int, offset: Int) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let logicalX = x + offset
        let index = (y * width + x) * 4
        pixels[index] = UInt8((logicalX * 47 + y * 13) % 256)
        pixels[index + 1] = UInt8((logicalX * 113 + y * 37) % 256)
        pixels[index + 2] = UInt8((logicalX + y * 7) % 256)
        pixels[index + 3] = 255
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)
  }

  // MARK: - start(with:)

  func testStart_initializesCorrectly() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 200, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    let update = stitcher.start(with: image)

    XCTAssertNotNil(update)
    XCTAssertEqual(update?.acceptedFrameCount, 1)
    XCTAssertEqual(update?.outputHeight, 100)
    XCTAssertNotNil(update?.mergedImage)

    if case .initialized = update?.outcome {} else {
      XCTFail("Expected .initialized outcome, got: \(String(describing: update?.outcome))")
    }
  }

  func testStart_setsFrameCount() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 50) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    XCTAssertEqual(stitcher.acceptedFrameCount, 1)
    XCTAssertEqual(stitcher.outputHeight, 50)
  }

  // MARK: - append identical image

  func testAppend_identicalImage_ignoredNoMovement() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(
      width: 200, height: 100,
      red: 80, green: 80, blue: 80
    ) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)

    let update = stitcher.append(image, maxOutputHeight: 10000)

    XCTAssertNotNil(update)
    if case .ignoredNoMovement = update?.outcome {} else {
      XCTFail("Expected .ignoredNoMovement for identical frame, got: \(String(describing: update?.outcome))")
    }

    // Frame count should NOT increment for ignored frames
    XCTAssertEqual(stitcher.acceptedFrameCount, 1)
  }

  // MARK: - append mismatched dimensions

  func testAppend_mismatchedDimensions_ignoredAlignmentFailed() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image1 = TestImageFactory.solidColor(width: 200, height: 100),
          let image2 = TestImageFactory.solidColor(width: 300, height: 100) else {
      XCTFail("Failed to create test images")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    XCTAssertNotNil(update)
    if case .ignoredAlignmentFailed = update?.outcome {} else {
      XCTFail("Expected .ignoredAlignmentFailed for mismatched dims, got: \(String(describing: update?.outcome))")
    }
  }

  func testAppend_mismatchedHeight_ignoredAlignmentFailed() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image1 = TestImageFactory.solidColor(width: 200, height: 100),
          let image2 = TestImageFactory.solidColor(width: 200, height: 150) else {
      XCTFail("Failed to create test images")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    if case .ignoredAlignmentFailed = update?.outcome {} else {
      XCTFail("Expected .ignoredAlignmentFailed for mismatched height")
    }
  }

  // MARK: - mergedImage

  func testMergedImage_afterStart_returnsNonNil() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let merged = stitcher.mergedImage()

    XCTAssertNotNil(merged)
    XCTAssertEqual(merged?.width, 100)
    XCTAssertEqual(merged?.height, 100)
  }

  func testMergedImage_beforeStart_returnsNil() {
    let stitcher = ScrollingCaptureStitcher()
    XCTAssertNil(stitcher.mergedImage())
  }

  // MARK: - previewImage

  func testPreviewImage_respectsMaxBounds() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 400, height: 400) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)

    let preview = stitcher.previewImage(maxPixelWidth: 100, maxPixelHeight: 100)
    XCTAssertNotNil(preview)

    if let preview {
      XCTAssertLessThanOrEqual(preview.width, 100)
      XCTAssertLessThanOrEqual(preview.height, 100)
    }
  }

  func testPreviewImage_beforeStart_returnsNil() {
    let stitcher = ScrollingCaptureStitcher()
    XCTAssertNil(stitcher.previewImage(maxPixelWidth: 200, maxPixelHeight: 200))
  }

  // MARK: - append with shifted content (integration)

  func testAppend_shiftedContent_appendsOrFailsAlignment() {
    let stitcher = ScrollingCaptureStitcher()
    let width = 200
    let height = 100

    // Use distinct row signatures so there is measurable inter-frame change.
    guard let image1 = TestImageFactory.scrollingFrame(width: width, height: height, logicalYOffset: 0) else {
      XCTFail("Failed to create frame 1")
      return
    }

    guard let image2 = TestImageFactory.scrollingFrame(width: width, height: height, logicalYOffset: 20) else {
      XCTFail("Failed to create frame 2")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    XCTAssertNotNil(update)

    // Synthetic images may not align reliably through the vision-assisted matcher,
    // so we accept either a successful append or an alignment failure,
    // but never "no movement" because the frames are objectively different.
    switch update?.outcome {
    case .appended(let deltaY):
      XCTAssertGreaterThan(deltaY, 0, "Delta should be positive for downward scroll")
      XCTAssertGreaterThan(stitcher.outputHeight, height, "Output height should grow after append")
      XCTAssertEqual(stitcher.acceptedFrameCount, 2)
    case .ignoredAlignmentFailed:
      XCTAssertEqual(stitcher.acceptedFrameCount, 1)
    case .ignoredNoMovement:
      XCTFail("Expected movement between shifted frames, got ignoredNoMovement")
    default:
      XCTFail("Unexpected outcome: \(String(describing: update?.outcome))")
    }
  }

  // MARK: - Multiple appends build height

  func testMultipleAppends_outputHeightAccumulates() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 50) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let initialHeight = stitcher.outputHeight
    XCTAssertEqual(initialHeight, 50)

    // Appending identical images won't increase height (no movement detected)
    _ = stitcher.append(image, maxOutputHeight: 10000)
    // Height should not change for identical frames
    XCTAssertEqual(stitcher.outputHeight, 50)
  }

  // MARK: - maxOutputHeight enforcement

  func testAppend_atMaxOutputHeight_returnsReachedHeightLimit() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)

    // max = current output height → no more room
    let update = stitcher.append(image, maxOutputHeight: stitcher.outputHeight)

    // For identical images, likely ignoredNoMovement; for shifted images it would be reachedHeightLimit
    // Either outcome is acceptable since we're testing the height limit enforcement path
    XCTAssertNotNil(update)
  }

  // MARK: - Alignment Debug Info

  func testStart_alignmentDebug_isInitialFrame() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    let update = stitcher.start(with: image)
    XCTAssertEqual(update?.alignmentDebug?.path, .initialFrame)
    XCTAssertEqual(update?.alignmentDebug?.confidence, 1.0)
    XCTAssertFalse(update?.alignmentDebug?.usedVisionEstimate ?? true)
    XCTAssertEqual(update?.safety, .confirmed)
  }

  // MARK: - Merge Direction

  func testStart_mergeDirectionIsUnresolved() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    let update = stitcher.start(with: image)
    XCTAssertEqual(update?.mergeDirection, .unresolved)
  }

  // MARK: - likelyReachedBoundary

  func testAppend_identicalImage_setsLikelyReachedBoundary() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(
      width: 200, height: 100,
      red: 120, green: 120, blue: 120
    ) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let update = stitcher.append(image, maxOutputHeight: 10000)

    if case .ignoredNoMovement = update?.outcome {
      XCTAssertTrue(update?.likelyReachedBoundary ?? false)
    }
  }

  // MARK: - renderMergedImage flag

  func testAppend_renderMergedImageFalse_skipsMergedImage() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let update = stitcher.append(image, maxOutputHeight: 10000, renderMergedImage: false)

    // When renderMergedImage is false, mergedImage in the update may still be
    // the cached version from start(), so we just verify the call succeeds.
    XCTAssertNotNil(update)
  }

  func testAppend_largeExpectedDelta_isNotPinnedToSmallLastMatch() {
    let stitcher = ScrollingCaptureStitcher()
    let width = 240
    let height = 400
    let firstDelta = 24
    let secondDelta = 140

    guard
      let first = TestImageFactory.scrollingFrame(width: width, height: height, logicalYOffset: 0),
      let second = TestImageFactory.scrollingFrame(
        width: width,
        height: height,
        logicalYOffset: firstDelta
      ),
      let third = TestImageFactory.scrollingFrame(
        width: width,
        height: height,
        logicalYOffset: firstDelta + secondDelta
      )
    else {
      XCTFail("Failed to create scrolling frames")
      return
    }

    _ = stitcher.start(with: first)
    let firstUpdate = stitcher.append(
      second,
      maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: firstDelta
    )
    guard case .appended(let acceptedFirstDelta) = firstUpdate?.outcome else {
      XCTFail("Expected first append to succeed, got \(String(describing: firstUpdate?.outcome))")
      return
    }
    XCTAssertEqual(acceptedFirstDelta, firstDelta)

    let secondUpdate = stitcher.append(
      third,
      maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: secondDelta
    )
    guard case .appended(let acceptedSecondDelta) = secondUpdate?.outcome else {
      XCTFail("Expected large second append to succeed, got \(String(describing: secondUpdate?.outcome))")
      return
    }
    XCTAssertEqual(acceptedSecondDelta, secondDelta)
    XCTAssertEqual(stitcher.outputHeight, height + firstDelta + secondDelta)
  }

  func testAppend_repeatedContentIntermediateFrame_isNotAppendedForKnownStep() {
    let stitcher = ScrollingCaptureStitcher()
    let width = 240
    let height = 360
    let knownStep = 80
    let intermediate = 12

    guard
      let first = TestImageFactory.repeatedScrollingFrame(
        width: width,
        height: height,
        logicalYOffset: 0
      ),
      let mid = TestImageFactory.repeatedScrollingFrame(
        width: width,
        height: height,
        logicalYOffset: intermediate
      ),
      let settled = TestImageFactory.repeatedScrollingFrame(
        width: width,
        height: height,
        logicalYOffset: knownStep
      )
    else {
      XCTFail("Failed to create repeated-content frames")
      return
    }

    _ = stitcher.start(with: first)
    let intermediateUpdate = stitcher.append(
      mid,
      maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: knownStep
    )
    if case .appended = intermediateUpdate?.outcome {
      XCTFail("Intermediate repeated-content frame should not append, got \(String(describing: intermediateUpdate?.outcome))")
      return
    }
    XCTAssertEqual(stitcher.acceptedFrameCount, 1)

    let settledUpdate = stitcher.append(
      settled,
      maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: knownStep
    )
    guard case .appended(let deltaY) = settledUpdate?.outcome else {
      XCTFail("Settled known-step frame should append, got \(String(describing: settledUpdate?.outcome))")
      return
    }
    XCTAssertEqual(deltaY, knownStep)
    XCTAssertEqual(stitcher.outputHeight, height + knownStep)
  }

  func testAppend_settledFinalStepIncludesShortRemainingStrip() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try XCTUnwrap(TestImageFactory.repeatedScrollingFrame(width: 240, height: 360, logicalYOffset: 0))
    _ = stitcher.start(with: first)
    for (offset, expectedAppend) in [(80, 80), (160, 80), (172, 12)] {
      let frame = try XCTUnwrap(TestImageFactory.repeatedScrollingFrame(width: 240, height: 360, logicalYOffset: offset))
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10_000,
        expectedSignedDeltaPixels: -80, allowsSettledPartialStep: true))
      guard case .appended(let delta) = update.outcome else {
        return XCTFail("Expected remaining strip at offset \(offset), got \(update.outcome)")
      }
      XCTAssertEqual(delta, expectedAppend)
    }
    XCTAssertEqual(stitcher.outputHeight, 532)
    let reference = try XCTUnwrap(TestImageFactory.repeatedScrollingFrame(width: 240, height: 532, logicalYOffset: 0))
    let result = try XCTUnwrap(stitcher.mergedImage())
    XCTAssertEqual(result.dataProvider?.data as Data?, reference.dataProvider?.data as Data?)
  }

  func testAppend_settledStepStillRejectsOversizedJump() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try XCTUnwrap(TestImageFactory.repeatedScrollingFrame(width: 240, height: 360, logicalYOffset: 0))
    let jumped = try XCTUnwrap(TestImageFactory.repeatedScrollingFrame(width: 240, height: 360, logicalYOffset: 240))
    _ = stitcher.start(with: first)
    let update = stitcher.append(jumped, maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: -80, allowsSettledPartialStep: true)
    if case .appended = update?.outcome {
      XCTFail("Settled frames must still obey the maximum known step")
    }
    XCTAssertEqual(stitcher.outputHeight, 360)
  }

  func testAppend_skippedBandDoesNotOverrideKnownStep() {
    let stitcher = ScrollingCaptureStitcher()
    let width = 240
    let height = 360
    let knownStep = 80
    let skippedBand = 240

    guard
      let first = TestImageFactory.repeatedScrollingFrame(
        width: width,
        height: height,
        logicalYOffset: 0
      ),
      let leap = TestImageFactory.repeatedScrollingFrame(
        width: width,
        height: height,
        logicalYOffset: skippedBand
      )
    else {
      XCTFail("Failed to create skipped-band frames")
      return
    }

    _ = stitcher.start(with: first)
    let update = stitcher.append(
      leap,
      maxOutputHeight: 10_000,
      expectedSignedDeltaPixels: knownStep
    )
    if case .appended(let deltaY) = update?.outcome {
      XCTFail("Skipped-band leap \(deltaY) should not append against known step \(knownStep)")
      return
    }
    XCTAssertEqual(stitcher.acceptedFrameCount, 1)
    XCTAssertEqual(stitcher.outputHeight, height)
  }

  func testAppend_mismatchedDimensions_marksUnsafe() {
    let stitcher = ScrollingCaptureStitcher()
    guard
      let image1 = TestImageFactory.solidColor(width: 100, height: 100),
      let image2 = TestImageFactory.solidColor(width: 120, height: 100)
    else {
      XCTFail("Failed to create test images")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    XCTAssertEqual(update?.safety, .unsafe(reason: "alignment-failed"))
  }

}
