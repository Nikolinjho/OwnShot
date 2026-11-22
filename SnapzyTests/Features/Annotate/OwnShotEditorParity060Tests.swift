//
//  OwnShotEditorParity060Tests.swift
//  SnapzyTests
//
//  Паритет редактора со CleanShot X 5.0.1 (волна 060): зоны размещения
//  перетащенного изображения, числа Background по наведению, пипетка-лупа.
//

import AppKit
import CoreGraphics
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotEditorParity060Tests: XCTestCase {
  // AnnotateState живёт до конца процесса: деинициализация в XCTest падает.
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeState(width: Int = 200, height: Int = 100) throws -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    state.loadImage(NSImage(cgImage: cg, size: NSSize(width: width, height: height)))
    return state
  }

  private func makeImage(width: Int, height: Int) throws -> NSImage {
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height, red: 10))
    return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
  }

  // MARK: - Четыре зоны перетаскивания

  func testБлижайшаяСторонаПоКурсору() {
    let size = CGSize(width: 400, height: 300)
    XCTAssertEqual(AnnotateImageDropEdge.closest(to: CGPoint(x: 200, y: 10), in: size), .top)
    XCTAssertEqual(AnnotateImageDropEdge.closest(to: CGPoint(x: 200, y: 290), in: size), .bottom)
    XCTAssertEqual(AnnotateImageDropEdge.closest(to: CGPoint(x: 15, y: 150), in: size), .left)
    XCTAssertEqual(AnnotateImageDropEdge.closest(to: CGPoint(x: 390, y: 150), in: size), .right)
    XCTAssertNil(AnnotateImageDropEdge.closest(to: .zero, in: .zero))
  }

  func testПодписиЗонКакУЭталона() {
    XCTAssertEqual(AnnotateImageDropEdge.top.title, "Place on the top")
    XCTAssertEqual(AnnotateImageDropEdge.bottom.title, "Place on the bottom")
    XCTAssertEqual(AnnotateImageDropEdge.left.title, "Place on the left")
    XCTAssertEqual(AnnotateImageDropEdge.right.title, "Place on the right")
  }

  func testРамкаУСтороныСодержимого() {
    let content = CGRect(x: 0, y: 0, width: 200, height: 100)
    let image = CGSize(width: 100, height: 50)
    // Слева и справа – по высоте содержимого.
    XCTAssertEqual(
      AnnotateImageDropEdge.right.placementBounds(imageSize: image, contentBounds: content, gap: 10),
      CGRect(x: 210, y: 0, width: 200, height: 100)
    )
    XCTAssertEqual(
      AnnotateImageDropEdge.left.placementBounds(imageSize: image, contentBounds: content, gap: 10),
      CGRect(x: -210, y: 0, width: 200, height: 100)
    )
    // Сверху и снизу – по ширине; y координат изображения растёт вверх.
    XCTAssertEqual(
      AnnotateImageDropEdge.top.placementBounds(imageSize: image, contentBounds: content, gap: 0),
      CGRect(x: 0, y: 100, width: 200, height: 100)
    )
    XCTAssertEqual(
      AnnotateImageDropEdge.bottom.placementBounds(imageSize: image, contentBounds: content, gap: 0),
      CGRect(x: 0, y: -100, width: 200, height: 100)
    )
  }

  func testПеретаскиваниеСправаСклеиваетВРядИСтавитПоследним() throws {
    let state = try makeState()
    XCTAssertTrue(state.importImage(try makeImage(width: 60, height: 40), sourceData: nil, placingOn: .right))
    XCTAssertTrue(state.isCombineMode)
    XCTAssertEqual(state.combineDirection, .horizontal)
    XCTAssertEqual(state.combineImageCount, 2)
    XCTAssertEqual(state.sourceImage?.size, NSSize(width: 200, height: 100))
  }

  func testПеретаскиваниеСлеваСтавитИзображениеПервым() throws {
    let state = try makeState()
    XCTAssertTrue(state.importImage(try makeImage(width: 60, height: 40), sourceData: nil, placingOn: .left))
    XCTAssertEqual(state.combineDirection, .horizontal)
    XCTAssertEqual(state.sourceImage?.size, NSSize(width: 60, height: 40))
  }

  func testПеретаскиваниеСверхуИСнизуСклеиваетВСтолбец() throws {
    let top = try makeState()
    XCTAssertTrue(top.importImage(try makeImage(width: 60, height: 40), sourceData: nil, placingOn: .top))
    XCTAssertEqual(top.combineDirection, .vertical)
    XCTAssertEqual(top.sourceImage?.size, NSSize(width: 200, height: 100))

    let bottom = try makeState()
    XCTAssertTrue(bottom.importImage(try makeImage(width: 60, height: 40), sourceData: nil, placingOn: .bottom))
    XCTAssertEqual(bottom.combineDirection, .vertical)
    XCTAssertEqual(bottom.sourceImage?.size, NSSize(width: 60, height: 40))
  }

  func testСвободныйХолстСтавитИзображениеУСтороны() throws {
    let state = try makeState()
    state.activateCombineMode(preferredMode: .freeCanvas)
    XCTAssertTrue(state.importImage(try makeImage(width: 60, height: 40), sourceData: nil, placingOn: .left))
    let embedded = try XCTUnwrap(state.annotations.first {
      if case .embeddedImage = $0.type { return true }
      return false
    })
    XCTAssertEqual(embedded.bounds.maxX, -state.combineGap, accuracy: 0.001)
    XCTAssertEqual(embedded.bounds.height, 100, accuracy: 0.001)
    XCTAssertLessThan(state.combineContentBounds.minX, 0)
  }

  func testБезИзображенияПеретаскиваниеЗагружаетЕго() throws {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    XCTAssertTrue(state.importImage(try makeImage(width: 60, height: 40), sourceData: nil, placingOn: .top))
    XCTAssertTrue(state.hasImage)
    XCTAssertFalse(state.isCombineMode)
  }

  // MARK: - Числа Background

  func testЧислоBackgroundВидноПоНаведениюФокусуИПеретаскиванию() {
    XCTAssertFalse(CompactSliderRow.showsValueField(revealsOnHover: true, isHovering: false, isFocused: false, isDragging: false))
    XCTAssertTrue(CompactSliderRow.showsValueField(revealsOnHover: true, isHovering: true, isFocused: false, isDragging: false))
    XCTAssertTrue(CompactSliderRow.showsValueField(revealsOnHover: true, isHovering: false, isFocused: true, isDragging: false))
    XCTAssertTrue(CompactSliderRow.showsValueField(revealsOnHover: true, isHovering: false, isFocused: false, isDragging: true))
    // Остальные слайдеры редактора показывают число всегда.
    XCTAssertTrue(CompactSliderRow.showsValueField(revealsOnHover: false, isHovering: false, isFocused: false, isDragging: false))
  }

  func testСтрелкиМеняютЧислоНаЕдиницуВПределахДиапазона() {
    XCTAssertEqual(AnnotateBackgroundSliderValue.stepped(10, by: 1, in: 0 ... 60), 11)
    XCTAssertEqual(AnnotateBackgroundSliderValue.stepped(10.4, by: -1, in: 0 ... 60), 9)
    XCTAssertEqual(AnnotateBackgroundSliderValue.stepped(60, by: 1, in: 0 ... 60), 60)
    XCTAssertEqual(AnnotateBackgroundSliderValue.stepped(0, by: -1, in: 0 ... 60), 0)
  }

  // MARK: - Пипетка-лупа

  func testЛупаЦентрированаНаКурсореПодписьНиже() {
    let geometry = AnnotateScreenColorPickerGeometry.self
    XCTAssertEqual(geometry.gridSize % 2, 1, "центральная ячейка должна существовать")
    let frame = geometry.windowFrame(cursor: CGPoint(x: 500, y: 400))
    XCTAssertEqual(frame.midX, 500, accuracy: 0.001)
    // Центр лупы (верхняя часть окна) – в точке курсора.
    XCTAssertEqual(frame.maxY - geometry.loupeDiameter / 2, 400, accuracy: 0.001)
    XCTAssertEqual(frame.height, geometry.loupeDiameter + geometry.labelGap + geometry.labelHeight, accuracy: 0.001)
  }

  func testПрямоугольникЗахватаВыровненПоПикселюПодКурсором() {
    let geometry = AnnotateScreenColorPickerGeometry.self
    let half = CGFloat(geometry.gridSize / 2)
    // 1x: курсор (100.6, 799.2) на экране высотой 1000 – пиксель (100, 200) в координатах CG.
    let rect1x = geometry.captureRect(cursor: CGPoint(x: 100.6, y: 799.2), primaryScreenHeight: 1000, backingScale: 1)
    XCTAssertEqual(rect1x, CGRect(x: 100 - half, y: 200 - half, width: CGFloat(geometry.gridSize), height: CGFloat(geometry.gridSize)))
    // 2x: та же точка – пиксель (201, 401), сторона в точках вдвое меньше.
    let rect2x = geometry.captureRect(cursor: CGPoint(x: 100.6, y: 799.2), primaryScreenHeight: 1000, backingScale: 2)
    XCTAssertEqual(rect2x.origin.x, (201 - half) / 2, accuracy: 0.0001)
    XCTAssertEqual(rect2x.origin.y, (401 - half) / 2, accuracy: 0.0001)
    XCTAssertEqual(rect2x.width, CGFloat(geometry.gridSize) / 2, accuracy: 0.0001)
  }

  func testЦентральныйПиксельСнимкаИПодписьHex() throws {
    let side = AnnotateScreenColorPickerGeometry.gridSize
    let image = try XCTUnwrap(makeGrid(side: side, center: (0x3F, 0xD6, 0x51), other: (0, 0, 0)))
    let pixels = try XCTUnwrap(AnnotateScreenColorPickerGeometry.pixels(of: image))
    XCTAssertEqual(pixels.count, side * side)
    let center = try XCTUnwrap(AnnotateScreenColorPickerGeometry.centerColor(of: pixels))
    XCTAssertEqual(AnnotateScreenColorPickerGeometry.hexString(center), "#3FD651")
    XCTAssertEqual(center.alpha, 1)
    XCTAssertEqual(AnnotateScreenColorPickerGeometry.hexString(pixels[0]), "#000000")
  }

  func testВерхняяСтрокаСнимкаИдётПервой() throws {
    let side = AnnotateScreenColorPickerGeometry.gridSize
    let image = try XCTUnwrap(makeTopRowImage(side: side))
    let pixels = try XCTUnwrap(AnnotateScreenColorPickerGeometry.pixels(of: image))
    XCTAssertEqual(AnnotateScreenColorPickerGeometry.hexString(pixels[0]), "#FF0000")
    XCTAssertEqual(AnnotateScreenColorPickerGeometry.hexString(pixels[side * side - 1]), "#0000FF")
  }

  // MARK: - Помощники

  private func makeGrid(side: Int, center: (UInt8, UInt8, UInt8), other: (UInt8, UInt8, UInt8)) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    for index in 0..<(side * side) {
      let isCenter = index == (side / 2) * side + side / 2
      let color = isCenter ? center : other
      bytes[index * 4] = color.0
      bytes[index * 4 + 1] = color.1
      bytes[index * 4 + 2] = color.2
      bytes[index * 4 + 3] = 255
    }
    return makeImage(bytes: bytes, side: side)
  }

  /// Верхняя строка красная, остальное синее.
  private func makeTopRowImage(side: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    for index in 0..<(side * side) {
      let isTopRow = index < side
      bytes[index * 4] = isTopRow ? 255 : 0
      bytes[index * 4 + 2] = isTopRow ? 0 : 255
      bytes[index * 4 + 3] = 255
    }
    return makeImage(bytes: bytes, side: side)
  }

  private func makeImage(bytes: [UInt8], side: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    // Первая строка данных CGImage – верх изображения.
    return CGImage(
      width: side,
      height: side,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: side * 4,
      space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
