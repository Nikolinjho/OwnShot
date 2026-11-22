//
//  AnnotateArrowShapesTests.swift
//  SnapzyTests
//
//  Контуры стрелок и слои Spotlight по живому замеру CleanShot X 5.0.1
//  (evidence/spec-064-live/ref-arrows-style*.png, ref-spotlight-layers.png).
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateArrowShapesTests: XCTestCase {
  private static var retainedAnnotateStates: [AnnotateState] = []

  // MARK: - Формулы

  func testФормулыStandardСовпадаютСЗамеромТолщины25() {
    let metrics = AnnotateArrowShapes.standardMetrics(thickness: 25, chordLength: 300)
    // Замер: хвост 10 pt, тело у наконечника 29,4, наконечник 83,4 в ширину и 82,2 до основания.
    XCTAssertEqual(metrics.outlineWidth, 10, accuracy: 0.01)
    XCTAssertEqual(metrics.neckHalfWidth * 2 + metrics.outlineWidth, 30, accuracy: 1)
    XCTAssertEqual((metrics.headHalfWidth + metrics.outlineWidth / 2) * 2, 83.4, accuracy: 1)
    XCTAssertEqual(metrics.headLength + metrics.outlineWidth / 2, 82.2, accuracy: 1.5)
  }

  func testФормулыFancyСовпадаютСЗамером() {
    // Замер: ус 9,5 / 20 / 52 pt над осью при толщине 1 / 7 / 25, на 19,75 / 42,25 / 109 от острия.
    let expected: [(CGFloat, CGFloat, CGFloat)] = [(1, 9.5, 19.75), (7, 20, 42.25), (25, 52, 109)]
    for (thickness, barb, distance) in expected {
      let metrics = AnnotateArrowShapes.fancyMetrics(thickness: thickness, chordLength: 300)
      XCTAssertEqual(metrics.barbHalfWidth, barb, accuracy: 0.8, "толщина \(thickness)")
      XCTAssertEqual(metrics.barbDistance, distance, accuracy: 1.5, "толщина \(thickness)")
      XCTAssertLessThan(metrics.notchDistance, metrics.barbDistance)
    }
  }

  func testФормулыЛинииCurvedСовпадаютСЗамером() {
    // Замер ширины линии: 1,69 / 3,11 / 5,91 / 11,49 / 18,49 pt.
    let expected: [(CGFloat, CGFloat)] = [(1, 1.69), (3, 3.11), (7, 5.91), (15, 11.49), (25, 18.49)]
    for (thickness, width) in expected {
      let metrics = AnnotateArrowShapes.lineMetrics(thickness: thickness, chordLength: 300)
      XCTAssertEqual(metrics.lineWidth, width, accuracy: 0.15, "толщина \(thickness)")
    }
    let thick = AnnotateArrowShapes.lineMetrics(thickness: 25, chordLength: 300)
    // Шеврон: внешний полуразмах 37,5 pt, плечо назад ≈ 29,8 pt.
    XCTAssertEqual(thick.armSpread + thick.lineWidth / 2, 37.5, accuracy: 1)
    XCTAssertEqual(thick.armBack, 29.8, accuracy: 1.5)
  }

  func testКороткаяСтрелкаУменьшаетсяЦеликом() {
    // Эталон: при длине 20 pt Standard одинаков для всех толщин, наконечник ≈ 6 pt.
    let thin = AnnotateArrowShapes.standardMetrics(thickness: 7, chordLength: 20)
    let thick = AnnotateArrowShapes.standardMetrics(thickness: 25, chordLength: 20)
    XCTAssertEqual((thick.headHalfWidth + thick.outlineWidth / 2) * 2, 6.1, accuracy: 0.6)
    XCTAssertEqual(thin.headHalfWidth, thick.headHalfWidth, accuracy: 0.5)
    XCTAssertLessThan(thick.headLength, 20 * 0.4)
    // Линия Curved при длине 20: 3,92 pt у толщины 25, 3,21 у толщины 7.
    XCTAssertEqual(AnnotateArrowShapes.lineMetrics(thickness: 25, chordLength: 20).lineWidth, 3.92, accuracy: 0.3)
    XCTAssertEqual(AnnotateArrowShapes.lineMetrics(thickness: 7, chordLength: 20).lineWidth, 3.21, accuracy: 0.3)
    // Длина 60: 9,75 у толщины 25.
    XCTAssertEqual(AnnotateArrowShapes.lineMetrics(thickness: 25, chordLength: 60).lineWidth, 9.75, accuracy: 0.4)
  }

  // MARK: - Пресеты и создание

  func testПресетыДаютВидЭталона() {
    let expected: [AnnotateArrowPreset: AnnotateArrowShapeKind] = [
      .standard: .standard, .fancy: .fancy, .curved: .line, .double: .line,
    ]
    for preset in AnnotateArrowPreset.allCases {
      let item = try? XCTUnwrap(makeArrow(preset: preset, from: CGPoint(x: 10, y: 40), to: CGPoint(x: 210, y: 90)))
      guard case .arrow(let geometry)? = item?.type else { return XCTFail("\(preset): нет стрелки") }
      XCTAssertEqual(geometry.shapeKind, expected[preset], "\(preset)")
    }
  }

  func testCurvedИDoubleПослеDragПрямые() throws {
    for preset in [AnnotateArrowPreset.curved, .double] {
      let start = CGPoint(x: 10, y: 40)
      let end = CGPoint(x: 210, y: 90)
      let item = try XCTUnwrap(makeArrow(preset: preset, from: start, to: end))
      guard case .arrow(let geometry) = item.type else { return XCTFail("нет стрелки") }
      XCTAssertNotEqual(geometry.style, .straight, "\(preset): стиль с ручкой изгиба")
      let control = try XCTUnwrap(geometry.resolvedControlPoint)
      XCTAssertEqual(control.x, 110, accuracy: 0.001)
      XCTAssertEqual(control.y, 65, accuracy: 0.001)
      for point in geometry.sampledPoints() {
        XCTAssertEqual(ArrowGeometry.distance(from: point, toSegmentFrom: start, to: end), 0, accuracy: 0.001)
      }
    }
  }

  func testПопаданиеПоУсуНаконечникаFancy() throws {
    let item = try XCTUnwrap(makeArrow(preset: .fancy, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 340, y: 100), thickness: 25))
    // Ус Fancy при толщине 25 – около 52 pt от оси, за пределами допуска по оси.
    XCTAssertTrue(item.containsPoint(CGPoint(x: 235, y: 145), baseTolerance: 0))
    XCTAssertFalse(item.containsPoint(CGPoint(x: 100, y: 145), baseTolerance: 0))
  }

  // MARK: - Рендер

  func testРендерСтрелокСовпадаетСЗамеромИСохраняетсяДляСверки() throws {
    let canvas = CGSize(width: 800, height: 450)
    let rows: [(CGFloat, CGFloat)] = [(1, 45), (3, 125), (7, 205), (15, 295), (25, 395)]
    var masks: [AnnotateArrowPreset: [Bool]] = [:]
    for preset in AnnotateArrowPreset.allCases {
      var items: [AnnotationItem] = []
      for (thickness, y) in rows {
        for (x0, x1) in [(CGFloat(40), CGFloat(340)), (430, 490), (590, 610)] {
          items.append(try XCTUnwrap(makeArrow(preset: preset, from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), thickness: thickness)))
        }
      }
      let image = try renderTopDown(items, size: canvas, scale: 2)
      try writePNG(image, name: "own-arrows-\(preset.rawValue.lowercased()).png")
      masks[preset] = blueMask(image)
    }

    let standard = try XCTUnwrap(masks[.standard])
    let width = 1600
    // Standard, толщина 25, длина 300: наконечник ≈ 83 pt в высоту, хвост ≈ 10 pt.
    XCTAssertEqual(columnHeight(standard, x: 2 * 262, rowY: 395, width: width), 83.4, accuracy: 3)
    XCTAssertEqual(columnHeight(standard, x: 2 * 41, rowY: 395, width: width), 10, accuracy: 1.5)
    // Curved, толщина 25: линия ≈ 18,5 pt и прямая (одинаковая ширина по всей длине).
    let curved = try XCTUnwrap(masks[.curved])
    XCTAssertEqual(columnHeight(curved, x: 2 * 100, rowY: 395, width: width), 18.5, accuracy: 1)
    XCTAssertEqual(columnHeight(curved, x: 2 * 250, rowY: 395, width: width), 18.5, accuracy: 1)
    // Короткие стрелки Standard одинаковы при толщине 7 и 25.
    for x in stride(from: 2 * 588, to: 2 * 612, by: 1) {
      XCTAssertEqual(
        columnHeight(standard, x: x, rowY: 205, width: width),
        columnHeight(standard, x: x, rowY: 395, width: width),
        accuracy: 0.6
      )
    }
  }

  func testПолупрозрачнаяСтрелкаБезТёмныхНаложений() throws {
    let color = Color(.sRGB, red: 64 / 255, green: 101 / 255, blue: 149 / 255, opacity: 0.5)
    var item = try XCTUnwrap(makeArrow(preset: .curved, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), thickness: 15))
    item.properties.strokeColor = color
    let image = try renderTopDown([item], size: CGSize(width: 200, height: 100), scale: 1)
    let shaft = pixel(image, x: 100, y: 50)
    let apex = pixel(image, x: 178, y: 50)
    for channel in 0..<3 {
      XCTAssertEqual(Int(shaft[channel]), Int(apex[channel]), accuracy: 2, "канал \(channel)")
    }
  }

  // MARK: - Spotlight

  /// ANN-118: у эталона все объекты, созданные до и после Spotlight, лежат поверх
  /// затемнения (ref-spotlight-layers.png: стрелки, рамки и текст вне области – (64,101,149)).
  /// Затемнение по умолчанию 0,45 превращает фон 220 в 121.
  func testЭкспортSpotlightОбъектыПоверхЗатемненияФон121() throws {
    let label = AnnotationItem(
      type: .text(""),
      bounds: CGRect(x: 10, y: 10, width: 50, height: 180),
      properties: AnnotationProperties(
        strokeColor: .black,
        fillColor: Color(.sRGB, red: 1, green: 0.8, blue: 0, opacity: 1),
        strokeWidth: 3,
        textPresentation: .label
      )
    )
    let spotlight = AnnotationItem(
      type: .spotlight,
      bounds: CGRect(x: 120, y: 20, width: 60, height: 160),
      properties: AnnotationProperties(
        strokeColor: .clear,
        strokeWidth: 0,
        cornerRadius: 0,
        spotlightOpacity: AnnotateState.defaultSpotlightOpacity
      )
    )
    let withSpotlight = try exportPixels([label, spotlight])
    let withoutSpotlight = try exportPixels([label])

    let background = withSpotlight.pixel(90, 100)
    XCTAssertEqual(Int(background[0]), 121, accuracy: 1)
    XCTAssertEqual(Int(withSpotlight.pixel(150, 100)[0]), 220, accuracy: 1)
    let labelWith = withSpotlight.pixel(35, 100)
    let labelWithout = withoutSpotlight.pixel(35, 100)
    for channel in 0..<3 {
      XCTAssertEqual(Int(labelWith[channel]), Int(labelWithout[channel]), accuracy: 1, "канал \(channel)")
    }
    XCTAssertGreaterThan(labelWith[0], 240)
  }

  // MARK: - Вспомогательное

  private func makeArrow(
    preset: AnnotateArrowPreset,
    from start: CGPoint,
    to end: CGPoint,
    thickness: CGFloat = 7
  ) throws -> AnnotationItem? {
    let context = AnnotationFactory.CreationContext(
      properties: AnnotationProperties(
        strokeColor: Color(.sRGB, red: 64 / 255, green: 101 / 255, blue: 149 / 255, opacity: 1),
        fillColor: .clear,
        strokeWidth: thickness
      ),
      arrowStyle: preset.style,
      arrowType: preset.arrowType,
      arrowStartHead: preset.startHead,
      arrowEndHead: .arrow,
      blurType: .pixelated,
      counterValue: 1,
      watermarkText: "",
      activeAnnotationBounds: CGRect(x: 0, y: 0, width: 800, height: 450)
    )
    return AnnotationFactory.createAnnotation(tool: .arrow, from: start, to: end, path: [start, end], context: context)
  }

  /// Холст 220 серого, координаты сверху вниз, как у снимка экрана эталона.
  private func renderTopDown(_ items: [AnnotationItem], size: CGSize, scale: CGFloat) throws -> CGImage {
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 220 / 255, green: 220 / 255, blue: 220 / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    let renderer = AnnotationRenderer(context: context, drawsObjectShadow: false)
    for item in items { renderer.draw(item) }
    return try XCTUnwrap(context.makeImage())
  }

  private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let bytes = rgba(image)
    let offset = (y * image.width + x) * 4
    return Array(bytes[offset..<offset + 4])
  }

  /// Маска синего, как в разборе снимков эталона: B − R > 30.
  private func blueMask(_ image: CGImage) -> [Bool] {
    let bytes = rgba(image)
    return (0..<(image.width * image.height)).map { index in
      Int(bytes[index * 4 + 2]) - Int(bytes[index * 4]) > 30
    }
  }

  /// Высота маски в столбце `x` (пиксели 2x) в полосе ±44 pt вокруг строки, в pt.
  private func columnHeight(_ mask: [Bool], x: Int, rowY: CGFloat, width: Int) -> CGFloat {
    let top = Int((rowY - 44) * 2)
    let bottom = Int((rowY + 44) * 2)
    var count = 0
    for y in top..<bottom where mask[y * width + x] { count += 1 }
    return CGFloat(count) / 2
  }

  private func writePNG(_ image: CGImage, name: String) throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = environment["OWNSHOT_ARROW_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  private struct Pixels {
    let bytes: [UInt8]
    let width: Int
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
      let offset = (y * width + x) * 4
      return Array(bytes[offset..<offset + 4])
    }
  }

  private func exportPixels(_ annotations: [AnnotationItem]) throws -> Pixels {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    let source = try XCTUnwrap(TestImageFactory.solidColor(width: 200, height: 200, red: 220, green: 220, blue: 220))
    state.loadImage(NSImage(cgImage: source, size: NSSize(width: 200, height: 200)))
    state.padding = 0
    state.shadowIntensity = 0
    state.cornerRadius = 0
    state.aspectRatio = .free
    state.backgroundStyle = .none
    state.annotations = annotations
    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let image = try XCTUnwrap(AnnotateExporter.bestCGImage(from: rendered))
    XCTAssertEqual(image.width, 200)
    return Pixels(bytes: rgba(image), width: image.width)
  }
}
