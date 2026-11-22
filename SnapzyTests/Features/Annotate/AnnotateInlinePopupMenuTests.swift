import AppKit
import XCTest
@testable import Snapzy

/// Размеры выпадающих меню inline-панели против AX эталона
/// (evidence/spec-062-live/popups/ref-*.txt): ширина меню, высоты строк, состав.
final class AnnotateInlinePopupMenuTests: XCTestCase {
  // MARK: - Font size

  @MainActor
  func testМенюFontSizeСовпадаетСЭталономПоШиринеИВысотамСтрок() {
    let controller = AnnotateValueMenuController()
    controller.layout = AnnotateInlineMenuContent.fontSizeLayout
    controller.items = AnnotateInlineMenuContent.fontSizeItems(current: 30)
    let menu = controller.makeMenu()

    XCTAssertEqual(menu.size, NSSize(width: 121, height: 489))
    XCTAssertEqual(menu.items.map(\.title), ["10 pt", "13 pt", "16 pt", "20 pt", "24 pt", "30 pt", "36 pt",
      "48 pt", "72 pt", "96 pt", "144 pt", "216 pt", "288 pt"])
    XCTAssertEqual(rowHeights(of: menu), [24, 27, 28, 30, 33, 35, 37, 39, 41, 43, 46, 47, 49],
      "Высоты строк сняты AX с меню эталона")
    XCTAssertTrue(menu.items.allSatisfy { $0.state == .off },
      "Галочки нет, как у эталона: текущий кегль выделен яркостью превью")
    XCTAssertEqual(controller.items.map(\.isOn), (0..<13).map { $0 == 5 })
    XCTAssertTrue(menu.items.allSatisfy { $0.view == nil }, "Подсветку и клавиатуру обрабатывает штатная строка")
    XCTAssertFalse(menu.showsStateColumn)
  }

  @MainActor
  func testКегльПревьюFontSizeРастётОт11До32() {
    let sizes = (0..<13).map { AnnotateInlineMenuContent.fontSizePreviewPointSize(at: $0) }
    XCTAssertEqual(sizes, [11, 13, 14, 16, 18, 20, 22, 23, 25, 27, 29, 30, 32])
  }

  @MainActor
  func testВыборFontSizeПередаётИндексПункта() {
    var selected: Int?
    let controller = AnnotateValueMenuController()
    controller.layout = AnnotateInlineMenuContent.fontSizeLayout
    controller.items = AnnotateInlineMenuContent.fontSizeItems(current: 31)
    controller.onSelect = { selected = $0 }
    let menu = controller.makeMenu()
    XCTAssertFalse(controller.items.contains { $0.isOn }, "Кегль вне списка не отмечается")
    menu.performActionForItem(at: 7)
    XCTAssertEqual(selected, 7)
  }

  // MARK: - Text style

  @MainActor
  func testМенюTextStyleСовпадаетСЭталоном() {
    let controller = AnnotateValueMenuController()
    controller.layout = AnnotateInlineMenuContent.textStyleLayout
    controller.items = AnnotateInlineMenuContent.textStyleItems(current: .box)
    let menu = controller.makeMenu()

    XCTAssertEqual(menu.size, NSSize(width: 192, height: 304))
    XCTAssertEqual(menu.items.map(\.title),
      ["Standard", "Rounded", "Outlined", "Mono", "Box", "Mono Box", "Rounded Box"])
    XCTAssertEqual(rowHeights(of: menu), Array(repeating: 42, count: 7))
    XCTAssertEqual(controller.items.map(\.isOn), [false, false, false, false, true, false, false])
    XCTAssertTrue(menu.items.allSatisfy { $0.view == nil && $0.image != nil })
  }

  @MainActor
  func testПревьюСтилейТекстаРисуютсяИОтличаютсяДругОтДруга() throws {
    let previews = try AnnotationTextStyle.allCases.map {
      try pixels(of: AnnotateInlineMenuContent.textStylePreview($0, emphasized: true))
    }
    for (style, data) in zip(AnnotationTextStyle.allCases, previews) {
      XCTAssertGreaterThan(data.inked, 40, "\(style.title): превью пустое")
    }
    XCTAssertEqual(Set(previews.map(\.bytes)).count, AnnotationTextStyle.allCases.count,
      "Каждый стиль даёт своё превью")
    // Подложка Box закрашивает больше площади, чем голый текст Standard.
    XCTAssertGreaterThan(previews[4].inked, previews[0].inked)
  }

  // MARK: - Spotlight shape

  @MainActor
  func testМенюSpotlightShapeБезПодписейСAXМетками() {
    let controller = AnnotateValueMenuController()
    controller.layout = AnnotateInlineMenuContent.spotlightShapeLayout
    controller.items = AnnotateInlineMenuContent.spotlightShapeItems(current: .roundedRectangle)
    let menu = controller.makeMenu()

    XCTAssertEqual(menu.size, NSSize(width: 58, height: 118))
    XCTAssertEqual(rowHeights(of: menu), [36, 36, 36])
    XCTAssertEqual(menu.items.map(\.title), ["", "", ""])
    XCTAssertEqual(menu.items.map { $0.accessibilityLabel() }, ["Rectangle", "Rounded Rectangle", "Ellipse"])
    XCTAssertEqual(controller.items.map(\.isOn), [false, true, false])
    XCTAssertEqual(menu.items.map { $0.image?.size },
      Array(repeating: AnnotateInlineMenuContent.spotlightShapeImageSize, count: 3))
  }

  // MARK: - Counter settings

  @MainActor
  func testМенюCounterSettingsСовпадаетСЭталоном() throws {
    let controller = AnnotateCounterMenuController()
    controller.configuration.format = .upperAlpha
    let menu = controller.makeMenu()

    XCTAssertEqual(menu.size, NSSize(width: 226, height: 230))
    XCTAssertEqual(rowHeights(of: menu), [36, 36, 36, 36, 11, 30, 11, 24])
    XCTAssertEqual(menu.items.prefix(4).map(\.title),
      ["1, 2, 3, 4 ...", "A, B, C, D ...", "I, II, III, IV ...", "a, b, c, d ..."])
    XCTAssertEqual(menu.items.prefix(4).map(\.state), [.off, .on, .off, .off],
      "Галочка текущего формата остаётся в штатной колонке")
    XCTAssertTrue(menu.showsStateColumn)
    XCTAssertTrue(menu.items.prefix(4).allSatisfy { $0.view == nil && $0.image == nil })
    XCTAssertEqual(menu.items.last?.title, "Size:")
    XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title),
      ["11 pt", "14 pt", "20 pt", "24 pt", "31 pt", "45 pt"])
  }

  @MainActor
  func testВыборФорматаCounterПрименяется() {
    var selected: CounterNumberFormat?
    let controller = AnnotateCounterMenuController()
    controller.configuration.onFormat = { selected = $0 }
    let menu = controller.makeMenu()
    menu.performActionForItem(at: 2)
    XCTAssertEqual(selected, CounterNumberFormat.allCases[2])
  }

  // MARK: - Помощники

  /// Высота каждой строки: тот же пункт в отдельном меню того же вида,
  /// минус поля меню 5 + 5 pt.
  @MainActor
  private func rowHeights(of menu: NSMenu) -> [CGFloat] {
    menu.items.map { item in
      let single = NSMenu()
      single.font = menu.font
      single.showsStateColumn = menu.showsStateColumn
      single.addItem(item.copy() as! NSMenuItem)
      return single.size.height - 10
    }
  }

  private struct Pixels {
    let bytes: Data
    let inked: Int
  }

  @MainActor
  private func pixels(of image: NSImage) throws -> Pixels {
    let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * 2,
      pixelsHigh: Int(image.size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
      image.draw(in: NSRect(origin: .zero, size: image.size))
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = Data(bytes: try XCTUnwrap(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
    var inked = 0
    for index in stride(from: 3, to: data.count, by: 4) where data[index] > 32 { inked += 1 }
    return Pixels(bytes: data, inked: inked)
  }
}
