//
//  OwnShotEditorParity059Tests.swift
//  SnapzyTests
//
//  Паритет редактора и Crop со CleanShot X 5.0.1 (сверка 059).
//

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import Vision
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotEditorParity059Tests: XCTestCase {
  // AnnotateState живёт до конца процесса: деинициализация в XCTest падает.
  private static var retainedAnnotateStates: [AnnotateState] = []
  private let rgbaBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

  private func makeState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  // MARK: - Rotate Image

  func testRotateImageВПанелиCropПоворачиваетПротивЧасовой() throws {
    XCTAssertFalse(CropToolbarView.rotatesClockwise)

    // Слева красный, справа синий: после 90° против часовой правая половина уходит наверх.
    let source = try XCTUnwrap(makeHalvesImage(width: 4, height: 2))
    let image = NSImage(cgImage: source, size: NSSize(width: 4, height: 2))
    let rotated = try XCTUnwrap(image.rotated90(clockwise: CropToolbarView.rotatesClockwise))
    let cgImage = try XCTUnwrap(rotated.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(cgImage.width, 2)
    XCTAssertEqual(cgImage.height, 4)
    let bytes = try rgbaBytes(from: cgImage)
    // Строка 0 буфера – верх изображения.
    XCTAssertGreaterThan(pixel(bytes, x: 0, y: 0, width: 2)[2], 200, "верх должен быть синим")
    XCTAssertGreaterThan(pixel(bytes, x: 0, y: 3, width: 2)[0], 200, "низ должен быть красным")
  }

  func testRotateImageМеняетРазмеры800x400На400x800() throws {
    let state = makeState()
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 800, height: 400))
    state.loadImage(NSImage(cgImage: cg, size: NSSize(width: 800, height: 400)))
    state.rotateImage(clockwise: CropToolbarView.rotatesClockwise)
    XCTAssertEqual(state.imageWidth, 400)
    XCTAssertEqual(state.imageHeight, 800)
  }


  func testПоляOriginalRatioПоказываютПропорцииИсходникаПослеПоворота() throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make(),
      appliesDefaultCanvasPresetOnNewImages: false)
    Self.retainedAnnotateStates.append(state)
    let pixels = try XCTUnwrap(TestImageFactory.solidColor(width: 338, height: 190))
    state.loadImage(NSImage(cgImage: pixels, size: NSSize(width: 169, height: 95)))
    state.rotateImage(clockwise: CropToolbarView.rotatesClockwise)
    state.beginCropInteraction()

    for scheme in [ColorScheme.light, .dark] {
      state.applyCropAspectRatio(.free)
      let host = NSHostingView(rootView: CropToolbarView(state: state)
        .environment(\.colorScheme, scheme)
        .transaction { $0.disablesAnimations = true }
        .fixedSize()
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor)))
      host.frame = NSRect(origin: .zero, size: host.fittingSize)
      let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.contentView = host
      panel.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
      panel.orderFrontRegardless()
      defer { panel.close() }
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

      state.applyOriginalCropRatio()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let snapshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      snapshot.name = scheme == .light ? "crop-original-ratio-light" : "crop-original-ratio-dark"
      snapshot.lifetime = .keepAlways
      add(snapshot)

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
      let tokens = (request.results ?? [])
        .filter { $0.boundingBox.midX < 0.54 }
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
        .split { !$0.isNumber }
      XCTAssertEqual(tokens, ["169", "95"], "Тема \(scheme), OCR: \(tokens)")
    }
    state.cancelCrop()
  }

  // MARK: - Image Size

  func testНольВImageSizeПоднимаетсяДоОдного() {
    XCTAssertEqual(AnnotateResizeUnit.pixels.pixels(value: 0, reference: 800), 1)
    XCTAssertEqual(AnnotateResizeUnit.pixels.pixels(value: -5, reference: 800), 1)
    XCTAssertEqual(AnnotateResizeUnit.percent.pixels(value: 0, reference: 800), 1)
    // 0 + Tab при закреплённых пропорциях 800 × 400 даёт 1 × 1, как у эталона.
    let width = AnnotateResizeUnit.pixels.pixels(value: 0, reference: 800)
    let dimensions = AnnotateResizeDimensions.editWidth(width, ratio: 2, locked: true, height: 400)
    XCTAssertEqual(dimensions.width, 1)
    XCTAssertEqual(dimensions.height, 1)
  }

  // MARK: - Counter

  func testУCounterНетУгловыхРучекРазмера() {
    XCTAssertFalse(AnnotationType.counter(1).showsCornerResizeHandles)
    XCTAssertTrue(AnnotationType.rectangle.showsCornerResizeHandles)
    XCTAssertEqual(AnnotateInlineProperties.counterSettingsTitle, "Counter settings")
  }

  // MARK: - Highlighter

  func testHighlighterСмешиваетсяОбычноСПрозрачностью03() throws {
    // Живой замер эталона (spec-062-live): на чёрном и на белом фоне видна одна и та же
    // полупрозрачная краска, multiply дал бы на чёрном чёрное.
    let black = try renderHighlight(over: 0)
    XCTAssertEqual(Int(black[0]), 77, accuracy: 2, "на чёрном – цвет маркера с α 0,3")
    XCTAssertEqual(Int(black[1]), 77, accuracy: 2)
    XCTAssertEqual(Int(black[2]), 0, accuracy: 2)

    let white = try renderHighlight(over: 255)
    XCTAssertEqual(Int(white[0]), 255, accuracy: 2)
    XCTAssertEqual(Int(white[2]), 179, accuracy: 2, "на белом фон просвечивает на 70 %")
  }

  func testHighlighterНеЧитаетСохранённуюOpacity() throws {
    // У владельца в defaults осталась opacity 0,65: штрих всё равно с α 0,3.
    let black = try renderHighlight(over: 0, opacity: 0.65)
    XCTAssertEqual(Int(black[0]), 77, accuracy: 2)
  }

  func testHighlighterТолщинаПоУмолчаниюКакУЭталона() {
    XCTAssertEqual(AnnotationRenderer.highlightAlpha, 0.3)
    let width = AnnotationRenderer.highlightLineWidth(
      forStrokeWidth: AnnotationProperties.defaultHighlighterStrokeWidth)
    XCTAssertGreaterThanOrEqual(width, 20, "штрих эталона ≈40 px на 2x-снимке")
  }

  // MARK: - Crop Background color

  func testBackgroundColorЗаливаетРамкуЗаИзображением() throws {
    let state = makeState()
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 100, height: 100))
    state.loadImage(NSImage(cgImage: cg, size: NSSize(width: 100, height: 100)))
    state.padding = 0
    state.shadowIntensity = 0
    state.cornerRadius = 0
    state.aspectRatio = .free
    state.backgroundStyle = .none
    state.initializeCrop()
    state.updateCropRect(CGRect(x: -20, y: -20, width: 140, height: 140))
    state.applyCrop()

    let transparent = try renderedBytes(state)
    XCTAssertEqual(transparent.width, 140)
    XCTAssertEqual(pixel(transparent.bytes, x: 2, y: 2, width: 140)[3], 0, "без цвета рамка прозрачная")

    state.cropFillColor = CropFillColor.normalized(.red)
    let filled = try renderedBytes(state)
    let corner = pixel(filled.bytes, x: 2, y: 2, width: 140)
    XCTAssertGreaterThan(Int(corner[0]), 240)
    XCTAssertLessThan(Int(corner[1]), 20)
    XCTAssertEqual(corner[3], 255)
    let center = pixel(filled.bytes, x: 70, y: 70, width: 140)
    XCTAssertEqual(Int(center[0]), 128, accuracy: 3, "изображение лежит поверх заливки")
  }

  func testПрозрачныйЦветРамкиХранитсяКакNil() {
    XCTAssertNil(CropFillColor.normalized(.clear))
    XCTAssertNil(CropFillColor.normalized(nil))
    XCTAssertNotNil(CropFillColor.normalized(.white))
  }

  // MARK: - Печать

  func testПечатьБезФлажкаИдётНаНесколькоСтраниц() {
    let info = NSPrintInfo()
    AnnotatePrintPagination.apply(scalesToFitOnePage: false, to: info)
    XCTAssertEqual(info.horizontalPagination, .fit)
    XCTAssertEqual(info.verticalPagination, .automatic)

    AnnotatePrintPagination.apply(scalesToFitOnePage: true, to: info)
    XCTAssertEqual(info.verticalPagination, .fit)
  }

  func testФлажокМасштабаПечатиМеняетРазбиение() {
    let info = NSPrintInfo()
    let accessory = AnnotatePrintAccessoryController(printInfo: info, scalesToFitOnePage: false)
    XCTAssertEqual(info.verticalPagination, .automatic)
    accessory.scalesToFitOnePage = true
    XCTAssertEqual(info.verticalPagination, .fit)
    XCTAssertEqual(accessory.keyPathsForValuesAffectingPreview(), ["scalesToFitOnePage"])
    XCTAssertEqual(AnnotatePrintAccessoryController.checkboxTitle, "Scale image to fit on one page")
    accessory.scalesToFitOnePage = false
  }

  // MARK: - DPI

  func testФайлБезDPIОткрываетсяКак1pxНа1pt() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OwnShotParity059_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nodpi.png")
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 800, height: 400))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, cg, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let image = try XCTUnwrap(AnnotateState.loadImageWithCorrectScale(from: url))
    XCTAssertEqual(image.size.width, 800, accuracy: 0.5)
    XCTAssertEqual(image.size.height, 400, accuracy: 0.5)
  }

  // MARK: - Option и Save as

  func testOptionМеняетКнопкуSaveAs() {
    XCTAssertTrue(AnnotateOptionKeyMonitor.isOptionHeld([.option]))
    XCTAssertTrue(AnnotateOptionKeyMonitor.isOptionHeld([.option, .capsLock]))
    XCTAssertFalse(AnnotateOptionKeyMonitor.isOptionHeld([.option, .command]))
    XCTAssertFalse(AnnotateOptionKeyMonitor.isOptionHeld([]))
    XCTAssertEqual(AnnotateOptionKeyMonitor.saveButtonTitle(optionHeld: false), L10n.Common.saveAs)
    XCTAssertEqual(AnnotateOptionKeyMonitor.saveButtonTitle(optionHeld: true), L10n.Common.save)
  }

  // MARK: - Материал панелей

  func testТонПанелейСовпадаетСЗамерамиЭталона() {
    let light = AnnotateEditorBarMetrics.lightBarAlpha
    // Байты PNG эталона без конвертации профиля: #CCCCCC на чёрном, #FFFFFF на белом.
    XCTAssertEqual(AnnotateEditorBarMetrics.composite(barColor: 255, alpha: light, over: 0), 0xCC, accuracy: 1)
    XCTAssertEqual(AnnotateEditorBarMetrics.composite(barColor: 255, alpha: light, over: 255), 0xFF, accuracy: 1)

    // Тёмная тема: #21201F на чёрном, #504F4E на белом.
    let dark = AnnotateEditorBarMetrics.darkBarAlpha
    let darkRed = CGFloat((AnnotateEditorBarMetrics.darkBarColor >> 16) & 255)
    XCTAssertEqual(AnnotateEditorBarMetrics.composite(barColor: darkRed, alpha: dark, over: 0), 0x21, accuracy: 1)
    XCTAssertEqual(AnnotateEditorBarMetrics.composite(barColor: darkRed, alpha: dark, over: 255), 0x50, accuracy: 1)
    XCTAssertEqual(AnnotateEditorBarMetrics.dragMeSize, CGSize(width: 117, height: 33))
  }

  // MARK: - Helpers

  private func renderHighlight(over gray: UInt8, opacity: CGFloat = 1) throws -> [UInt8] {
    let size = 40
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: rgbaBitmapInfo.rawValue))
      context.setFillColor(CGColor(gray: CGFloat(gray) / 255, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: size, height: size))
      let renderer = AnnotationRenderer(context: context, drawsObjectShadow: false)
      renderer.draw(AnnotationItem(
        type: .highlight([CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20)]),
        bounds: CGRect(x: 0, y: 10, width: 40, height: 20),
        properties: AnnotationProperties(
          strokeColor: Color(.sRGB, red: 1, green: 1, blue: 0, opacity: 1), strokeWidth: 4, opacity: opacity)
      ))
    }
    return pixel(bytes, x: 20, y: 20, width: size)
  }

  private func renderedBytes(_ state: AnnotateState) throws -> (bytes: [UInt8], width: Int) {
    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let cg = try XCTUnwrap(AnnotateExporter.bestCGImage(from: rendered))
    return (try rgbaBytes(from: cg), cg.width)
  }

  private func makeHalvesImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: rgbaBitmapInfo.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return context.makeImage()
  }

  private func rgbaBytes(from image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: rgbaBitmapInfo.rawValue))
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
    let index = (y * width + x) * 4
    return Array(bytes[index..<(index + 4)])
  }
}
