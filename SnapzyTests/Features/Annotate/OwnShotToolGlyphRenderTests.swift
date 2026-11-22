import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

final class OwnShotToolGlyphRenderTests: XCTestCase {
  @MainActor private static var retainedStates: [AnnotateState] = []

  @MainActor
  func testАктивнаяТёмнаяПанельПовторяетИзмеренныеЦветаЭталона() throws {
    // Офскрин материала нет: панель рисуется поверх фиксированной подложки.
    // #BEBEBE – фон, при котором полупрозрачная панель эталона даёт цвета reference-arrow-active.png.
    let rep = try renderActiveDarkToolbar(over: 0xBE)
    for (x, y, expected) in [(1000, 10, [68, 67, 66, 255]),
      (200, 52, [105, 105, 104, 255]), (520, 52, [87, 86, 85, 255])] {
      var actual = [UInt](repeating: 0, count: 4)
      rep.getPixel(&actual, atX: x, y: y)
      XCTAssertEqual(actual.map { Int($0) }, expected,
        "Цвет (\(x),\(y)) измерен в reference-arrow-active.png при 2×, без повторной конвертации профиля")
    }
  }

  @MainActor
  func testАктивнаяТёмнаяПанельПросвечиваетКакЭталонНаЧёрномИБелом() throws {
    // В парах эталона окно стоит в (120, 120) px, здесь те же точки в координатах панели.
    let measured: [(UInt8, [(Int, Int, [Int])])] = [
      (0x00, [(1000, 10, [33, 32, 31]), (200, 52, [77, 77, 76]), (520, 52, [55, 54, 53])]),
      (0xFF, [(1000, 10, [80, 79, 78]), (200, 52, [115, 114, 113]), (520, 52, [97, 97, 96])])
    ]
    for (backdrop, points) in measured {
      let rep = try renderActiveDarkToolbar(over: backdrop)
      for (x, y, expected) in points {
        var actual = [UInt](repeating: 0, count: 4)
        rep.getPixel(&actual, atX: x, y: y)
        for channel in 0..<3 {
          // ±1 – округление при наложении двух полупрозрачных слоёв в 8 бит.
          XCTAssertEqual(Int(actual[channel]), expected[channel], accuracy: 1,
            "Фон #\(String(format: "%02X", backdrop)), точка (\(x),\(y)): evidence/spec-050-visual/dark/editor-idle-on-*.png")
        }
      }
    }
  }

  @MainActor
  func testТинтСветлойПанелиЛежитПодЗонойСветофораИКапсулойИнструментов() throws {
    // Покрытие точки по паре подложек: 1 − (на белом − на чёрном) / 255.
    // Дыра в тинте даёт 0 (видно окно позади), тинт белого с alpha 0,8 – 0,8.
    let onBlack = try renderToolbar(scheme: .light, backdrop: .black)
    let onWhite = try renderToolbar(scheme: .light, backdrop: .white)
    func coverage(_ x: Int, _ y: Int) -> Double {
      var black = [UInt](repeating: 0, count: 4), white = [UInt](repeating: 0, count: 4)
      onBlack.getPixel(&black, atX: x, y: y)
      onWhite.getPixel(&white, atX: x, y: y)
      return 1 - Double(Int(white[0]) - Int(black[0])) / 255
    }
    // Пустое место между More и Save as… (760 pt): эталонные 204 на чёрном и 255 на белом.
    var empty = [UInt](repeating: 0, count: 4)
    onBlack.getPixel(&empty, atX: 1520, y: 50)
    XCTAssertEqual(Int(empty[0]), 204, accuracy: 1, "Пустое место светлой панели на чёрном – 204, как у эталона")
    onWhite.getPixel(&empty, atX: 1520, y: 50)
    XCTAssertEqual(Int(empty[0]), 255, accuracy: 1, "Пустое место светлой панели на белом – 255, как у эталона")
    let emptyCoverage = coverage(1520, 50)
    XCTAssertEqual(emptyCoverage, Double(AnnotateEditorBarMetrics.lightBarAlpha), accuracy: 0.01)

    // Зона светофора (0–90 pt) и центры Rectangle, Ellipse, Text внутри капсулы инструментов
    // (ячейки по 36 pt от 263 pt, как в AX окна, evidence/spec-062-live/own-bg-panel.txt).
    let points = [(20, 30, "светофор слева"), (90, 60, "светофор, середина"), (170, 50, "светофор справа"),
      (562, 50, "Rectangle"), (706, 50, "Ellipse"), (922, 50, "Text")]
    for (x, y, name) in points {
      XCTAssertGreaterThanOrEqual(coverage(x, y), emptyCoverage - 0.02,
        "\(name) (\(x),\(y)): тинт должен лежать так же, как в пустом месте панели, без дыры в окно позади")
    }
  }

  @MainActor
  func testПанельБезПодложкиНигдеНеИмеетНулевойАльфы() throws {
    // С прозрачной подложкой остаются только тинт и содержимое панели. Пиксель с альфой 0
    // в живом окне пропускает клик в окно позади.
    for scheme in [ColorScheme.light, .dark] {
      let rep = try renderToolbar(scheme: scheme, backdrop: .clear)
      var transparent: [(Int, Int)] = []
      var pixel = [UInt](repeating: 0, count: 4)
      for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
          rep.getPixel(&pixel, atX: x, y: y)
          if pixel[3] == 0 { transparent.append((x, y)) }
        }
      }
      XCTAssertTrue(transparent.isEmpty,
        "\(scheme): \(transparent.count) прозрачных пикселей, первые \(transparent.prefix(5))")
    }
  }

  @MainActor
  func testПодложкаОкнаНеПрозрачнаИНеМеняетЗамерыЭталона() throws {
    let window = AnnotateWindow(contentRect: NSRect(x: 0, y: 0, width: 990, height: 600))
    defer { window.close() }
    XCTAssertFalse(window.isOpaque)
    for (appearance, bar, barAlpha, measured) in [
      (NSAppearance.Name.aqua, CGFloat(255), AnnotateEditorBarMetrics.lightBarAlpha, [(0.0, 204.0), (255, 255)]),
      (.darkAqua, CGFloat(0x28), AnnotateEditorBarMetrics.darkBarAlpha, [(0, 33), (255, 80)])
    ] {
      var floor = NSColor.clear
      try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
        floor = window.backgroundColor.usingColorSpace(.sRGB) ?? .clear
      }
      XCTAssertGreaterThanOrEqual((floor.alphaComponent * 255).rounded(), 1,
        "\(appearance): альфа подложки окна в 8 битах не ноль, иначе клики уходят в окно позади")
      for (backdrop, expected) in measured {
        let underTint = AnnotateEditorBarMetrics.composite(barColor: floor.redComponent * 255,
          alpha: floor.alphaComponent, over: CGFloat(backdrop))
        let result = AnnotateEditorBarMetrics.composite(barColor: bar, alpha: barAlpha, over: underTint)
        XCTAssertEqual(Double(result).rounded(), expected, accuracy: 0.5,
          "\(appearance) на \(backdrop): подложка не сдвигает тон панели эталона")
      }
    }
  }

  @MainActor
  private func renderToolbar(scheme: ColorScheme, backdrop: Color) throws -> NSBitmapImageRep {
    let defaults = UserDefaults(suiteName: "ownshot.strict.floor.\(UUID().uuidString)")!
    let state = AnnotateState(defaults: defaults)
    Self.retainedStates.append(state)
    let renderer = ImageRenderer(content: AnnotateToolbarView(state: state)
      .frame(width: 990)
      .environment(\.annotateEditorBarBackdrop, backdrop)
      .environment(\.colorScheme, scheme)
      .environment(\.controlActiveState, .key))
    renderer.scale = 2
    return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
  }

  @MainActor
  private func renderActiveDarkToolbar(over backdrop: UInt8) throws -> NSBitmapImageRep {
    let defaults = UserDefaults(suiteName: "ownshot.strict.active.\(UUID().uuidString)")!
    let state = AnnotateState(defaults: defaults)
    Self.retainedStates.append(state)
    state.activateTool(.arrow)
    let gray = UInt32(backdrop)
    let renderer = ImageRenderer(content: AnnotateToolbarView(state: state)
      .frame(width: 990)
      .environment(\.annotateEditorBarBackdrop, OwnShotEditorChrome.color(gray << 16 | gray << 8 | gray))
      .environment(\.colorScheme, .dark)
      .environment(\.controlActiveState, .key))
    renderer.scale = 2
    return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
  }

  @MainActor
  func testНеактивнаяПанельНеОставляетКрасноеВыделениеИнструмента() throws {
    let defaults = UserDefaults(suiteName: "ownshot.strict.toolbar.\(UUID().uuidString)")!
    let state = AnnotateState(defaults: defaults)
    Self.retainedStates.append(state)
    state.activateTool(.blur)
    let renderer = ImageRenderer(content: AnnotateToolbarView(state: state)
      .frame(width: 990)
      .environment(\.colorScheme, .dark)
      .environment(\.controlActiveState, .inactive))
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage)
    let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    var redPixels = 0
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide {
        let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        if c.alphaComponent > 0.5 && c.redComponent - c.greenComponent > 0.3 { redPixels += 1 }
      }
    }
    XCTAssertEqual(redPixels, 0,
      "На парном снимке неактивного CleanShot выделение серое, красный акцент отсутствует")
    XCTAssertEqual(rep.pixelsHigh, 101,
      "Панель эталона при масштабе 2× занимает 101 пиксель до разделителя на строках 101–102")
  }

}
