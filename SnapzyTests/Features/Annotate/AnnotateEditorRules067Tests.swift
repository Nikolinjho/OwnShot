//
//  AnnotateEditorRules067Tests.swift
//  SnapzyTests
//
//  Правила дизайна редактора из spec-066 (evidence/spec-066-patterns/design-rules.md):
//  акцент по теме, неактивное окно, разделители группы, разделитель баров,
//  ручки выделения, поля Image Size.
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

final class AnnotateEditorRules067Tests: XCTestCase {
  @MainActor private static var retainedStates: [AnnotateState] = []

  @MainActor
  func testВыборНумерацииСохраняетПравыйОтступDoneПриМинимальнойШиринеОкна() throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    var margins: [CGFloat] = []
    for tool in [AnnotationToolType.arrow, .counter, .rectangle, .counter] {
      state.activateTool(tool)
      // Измеряем собственный рендер тулбара. Экран и рабочие окна не снимаются.
      let renderer = ImageRenderer(content: AnnotateToolbarView(state: state)
        .frame(width: 990)
        .environment(\.annotateEditorBarBackdrop, Color.gray)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key))
      renderer.scale = 2
      let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
      var rightmostAccent: Int?
      for x in (max(0, rep.pixelsWide - 200)..<rep.pixelsWide).reversed() {
        for y in 0..<rep.pixelsHigh {
          var pixel = [UInt](repeating: 0, count: 4)
          rep.getPixel(&pixel, atX: x, y: y)
          if pixel[0] > 150 && pixel[1] < 130 && pixel[2] < 150 && pixel[3] > 128 {
            rightmostAccent = x
            break
          }
        }
        if rightmostAccent != nil { break }
      }
      let rightEdge = try XCTUnwrap(rightmostAccent, "В правой части панели должна быть кнопка Done")
      let margin = CGFloat(rep.pixelsWide - rightEdge - 1) / 2
      margins.append(margin)
      XCTAssertEqual(margin, 13, accuracy: 1,
        "\(tool): Done должен сохранять правый отступ 13 pt")
    }
    XCTAssertEqual(margins[0], margins[1], accuracy: 1)
  }

  // MARK: - R04 акцент по теме

  func testАкцентТемыСовпадаетСКадрамиЭталона() {
    // Raw #CE4745 (Light) и #EC5F5D (Dark) в профиле дисплея – это sRGB #E0383E и #FF5257
    // (решение C1; spec-063-live/ref-bottombar-active-on-808080.png, spec-050-visual/dark/editor-idle-on-000000.png).
    XCTAssertEqual(OwnShotEditorChrome.accentRGB(for: .light), 0xE0383E)
    XCTAssertEqual(OwnShotEditorChrome.accentRGB(for: .dark), 0xFF5257)
  }

  func testКареткаНаХолстеБерётАкцентТемы() throws {
    // Каретка эталона на тёмном холсте – raw #EC5F5D, sRGB #FF5257 (b3r-text-ref-1.png, b3r-text-ref-4.png).
    XCTAssertEqual(try resolvedRGB(OwnShotEditorChrome.accentNSColor, appearance: .darkAqua), 0xFF5257)
    XCTAssertEqual(try resolvedRGB(OwnShotEditorChrome.accentNSColor, appearance: .aqua), 0xE0383E)
  }

  @MainActor
  func testОсновнаяКнопкаАктивногоОкнаЗалитаАкцентомТемы() throws {
    let light = try renderToolbar(scheme: .light, activeState: .key)
    XCTAssertGreaterThan(count(light, rgb: 0xE0383E), 1500,
      "Светлая тема: основная кнопка – акцент #E0383E (raw #CE4745 на ref-bottombar-active-on-808080.png)")
    let dark = try renderToolbar(scheme: .dark, activeState: .key)
    XCTAssertGreaterThan(count(dark, rgb: 0xFF5257), 1500,
      "Тёмная тема: основная кнопка – акцент #FF5257 (raw #EC5F5D на spec-050-visual/dark/editor-idle-on-000000.png)")
  }

  // MARK: - R14 и R15 неактивное окно

  @MainActor
  func testНеактивноеСветлоеОкноГаситАкцентыВСерыйКакЭталон() throws {
    // spec-063-live/ref-bottombar-inactive-on-808080.png: Save as… #BFBFBF, выбранный инструмент
    // #C0C0C0 с глифом #606060, глифы остальных инструментов #787878.
    let rep = try renderToolbar(scheme: .light, activeState: .inactive)
    XCTAssertGreaterThan(count(rep, rgb: 0xBFBFBF), 1500, "Основная кнопка неактивного окна – #BFBFBF")
    XCTAssertGreaterThan(count(rep, rgb: 0xC0C0C0), 1000, "Выбранный инструмент неактивного окна – #C0C0C0")
    XCTAssertGreaterThan(count(rep, rgb: 0x606060), 20, "Глиф выбранного инструмента – #606060")
    XCTAssertGreaterThan(count(rep, rgb: 0x787878), 100, "Глифы невыбранных инструментов – #787878")
    XCTAssertEqual(count(rep, rgb: 0xE0383E), 0, "Акцента в неактивном окне нет")
  }

  @MainActor
  func testНеактивноеТёмноеОкноНеПриглушаетКнопкиЗахвата() throws {
    // spec-051-pairs/reference-dark/editor-inactive-on-000000.png: выбранный инструмент #656463 с глифом
    // #C9C9C8, глифы группы #BBBBBB, кнопки захвата сохраняют #E5E5E5 – прежнего #B8B7B7 нет.
    let rep = try renderToolbar(scheme: .dark, activeState: .inactive)
    XCTAssertGreaterThan(count(rep, rgb: 0x656463), 1000)
    XCTAssertGreaterThan(count(rep, rgb: 0xC9C9C8), 20)
    XCTAssertGreaterThan(count(rep, rgb: 0xBBBBBB), 100)
    XCTAssertGreaterThan(count(rep, rgb: 0x545251), 1500, "Основная кнопка неактивного тёмного окна – #545251")
    // Глиф primary (белый 85 %) на капсуле #545251 даёт #E5E5E5, как у эталона в обоих состояниях.
    XCTAssertGreaterThan(count(rep, rgb: 0xE5E5E5), 200, "Глифы кнопок захвата остаются #E5E5E5")
  }

  // MARK: - R18 разделители группы инструментов

  func testРазделителиПрячутсяСОбеихСторонВыбраннойИНаведённойЯчейки() {
    // spec-050-visual/light/editor-idle-on-000000.png: выбрана ячейка 5, нет разделителей 5 и 6.
    // spec-050-visual/dark/editor-hover-tool-on-000000.png: выбрана 3, наведена 5 – нет 3, 4, 5, 6.
    func visible(selected: Int?, hovered: Int?) -> [Int] {
      (0..<12).filter {
        OwnShotEditorChrome.showsToolSeparator(beforeIndex: $0, selectedIndex: selected, hoveredIndex: hovered)
      }
    }
    XCTAssertEqual(visible(selected: 5, hovered: nil), [1, 2, 3, 4, 7, 8, 9, 10, 11])
    XCTAssertEqual(visible(selected: 3, hovered: 5), [1, 2, 7, 8, 9, 10, 11])
    XCTAssertEqual(visible(selected: 0, hovered: nil), [2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
      "spec-051-pairs/reference-*/editor-inactive-on-000000.png: справа от выбранного курсора разделителя нет")
  }

  func testРазделительИHoverГруппыПоЗамерамЭталона() {
    // 1×14 pt (2×28 px), чёрный/белый 10 %: #ADADAD на #C0C0C0 и #4B4A49 на #373635.
    XCTAssertEqual(OwnShotEditorChrome.toolSeparatorSize, CGSize(width: 1, height: 14))
    XCTAssertEqual(192 * (1 - OwnShotEditorChrome.toolSeparatorOpacity), 0xAD, accuracy: 1)
    XCTAssertEqual(55 + 200 * OwnShotEditorChrome.toolSeparatorOpacity, 0x4B, accuracy: 1)
    // Hover (N07): #C0C0C0 → #B3B3B3 и #373635 → #454443.
    XCTAssertEqual(192 * (1 - OwnShotEditorChrome.toolHoverOpacity), 0xB3, accuracy: 1)
    XCTAssertEqual(55 + 200 * OwnShotEditorChrome.toolHoverOpacity, 0x45, accuracy: 1)
  }

  // MARK: - R11 разделитель баров в тёмной теме

  @MainActor
  func testТёмныйРазделительБаровПовторяетДвеСтрокиЭталона() throws {
    // spec-050-visual/dark/editor-idle-on-000000.png: под тулбаром строка 221 #444342 (половина
    // со стороны панели), строка 222 #4C4A49 (линия окна). Прежняя линия #676665 светлее.
    let active = try renderDivider(barEdge: .top, isActive: true, backdrop: .black)
    XCTAssertEqual(red(active, x: 4, y: 0), 0x44, accuracy: 1)
    XCTAssertEqual(red(active, x: 4, y: 1), 0x4C, accuracy: 1)
    // На белом половина панели просвечивает: #737271 (editor-idle-on-FFFFFF.png, строка 1018).
    let onWhite = try renderDivider(barEdge: .bottom, isActive: true, backdrop: .white)
    XCTAssertEqual(red(onWhite, x: 4, y: 0), 0x4C, accuracy: 1)
    XCTAssertEqual(red(onWhite, x: 4, y: 1), 0x73, accuracy: 1)
    // Неактивное окно: #4C4A49 (spec-051-pairs/reference-dark/editor-inactive-on-000000.png).
    let inactive = try renderDivider(barEdge: .top, isActive: false, backdrop: .black)
    XCTAssertEqual(red(inactive, x: 4, y: 0), 0x4C, accuracy: 1)
    XCTAssertEqual(red(inactive, x: 4, y: 1), 0x4C, accuracy: 1)
  }

  // MARK: - R22 ручки выделенного объекта

  func testРучкиВыделенияПоЗамерамЭталона() {
    // ref-rect-selected-3eq.png (2×): ядро 24 px #3982F7, белая кайма по 4 px – 16 pt всего.
    XCTAssertEqual(AnnotateSelectionChromeMetrics.handleCoreSize, 12)
    XCTAssertEqual(AnnotateSelectionChromeMetrics.handleBorderWidth, 2)
    XCTAssertEqual(AnnotateSelectionChromeMetrics.handleSize,
      AnnotateSelectionChromeMetrics.handleCoreSize + 2 * AnnotateSelectionChromeMetrics.handleBorderWidth)
    XCTAssertEqual(AnnotateSelectionChromeMetrics.endpointHandleSize, AnnotateSelectionChromeMetrics.handleSize)
    XCTAssertEqual(AnnotateSelectionChromeMetrics.handleCoreRGB, 0x3982F7)
    XCTAssertEqual(AnnotateSelectionChromeMetrics.lineSelectionBandInset, 3)
  }

  @MainActor
  func testУголПрямоугольникаБерётсяКруглойРучкой16pt() throws {
    // Ручка 16 pt ловит нажатие в 6 pt от угла: прежний квадрат 8 pt его пропускал.
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    state.loadImage(NSImage(size: CGSize(width: 400, height: 300)))
    let item = AnnotationItem(type: .rectangle, bounds: CGRect(x: 100, y: 100, width: 200, height: 100),
      properties: AnnotationProperties())
    state.annotations = [item]
    state.selectedTool = .selection
    state.selectedAnnotationId = item.id
    let canvas = DrawingCanvasNSView(state: state)
    canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    canvas.displayScale = 1
    canvas.canvasBounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 94, y: 94)))
    canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 60, y: 60)))
    canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 60, y: 60)))

    let resized = try XCTUnwrap(state.annotations.first)
    XCTAssertLessThan(resized.bounds.minX, 90, "Угол прямоугольника потянулся за ручкой")
    XCTAssertEqual(resized.bounds.maxX, 300, accuracy: 0.5)
  }

  // MARK: - R30/R32 поля Image Size

  func testПоляImageSizeПлоскиеИУтопленные() {
    // ref-imagesize-popover.png (2×): поле #C8C8C8 на #DEDEDE – чёрный ≈10 %, 200×42 px, без рамки.
    XCTAssertEqual(AnnotateImageSizeFieldMetrics.size, CGSize(width: 100, height: 21))
    XCTAssertEqual(222 * (1 - AnnotateImageSizeFieldMetrics.fillBlackOpacity(for: .light)), 0xC8, accuracy: 1)
    XCTAssertEqual(AnnotateImageSizeFieldMetrics.fillBlackOpacity(for: .dark), 0.2, "R30, решение C4")
    XCTAssertEqual(AnnotateImageSizeFieldMetrics.cornerRadius, 6)
  }

  // MARK: - Помощники

  private func resolvedRGB(_ color: NSColor, appearance name: NSAppearance.Name) throws -> UInt32 {
    let appearance = try XCTUnwrap(NSAppearance(named: name))
    var rgb: UInt32 = 0
    appearance.performAsCurrentDrawingAppearance {
      guard let srgb = color.usingColorSpace(.sRGB) else { return }
      rgb = UInt32((srgb.redComponent * 255).rounded()) << 16
        | UInt32((srgb.greenComponent * 255).rounded()) << 8
        | UInt32((srgb.blueComponent * 255).rounded())
    }
    return rgb
  }

  @MainActor
  private func renderToolbar(scheme: ColorScheme, activeState: ControlActiveState) throws -> NSBitmapImageRep {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    state.activateTool(.arrow)
    let renderer = ImageRenderer(content: AnnotateToolbarView(state: state)
      .frame(width: 990)
      .environment(\.annotateEditorBarBackdrop, Color.gray)
      .environment(\.colorScheme, scheme)
      .environment(\.controlActiveState, activeState))
    renderer.scale = 2
    return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
  }

  @MainActor
  private func renderDivider(
    barEdge: AnnotateEditorDivider.BarEdge,
    isActive: Bool,
    backdrop: Color
  ) throws -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: AnnotateEditorDivider(barEdge: barEdge, isActive: isActive, colorScheme: .dark)
      .frame(width: 8)
      .background(backdrop))
    renderer.scale = 2
    return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
  }

  private func red(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Int {
    var pixel = [UInt](repeating: 0, count: 4)
    rep.getPixel(&pixel, atX: x, y: y)
    return Int(pixel[0])
  }

  /// Число пикселей цвета `rgb` с допуском ±1 на канал (округление при рендере).
  private func count(_ rep: NSBitmapImageRep, rgb: UInt32) -> Int {
    let target = [Int((rgb >> 16) & 255), Int((rgb >> 8) & 255), Int(rgb & 255)]
    var pixel = [UInt](repeating: 0, count: 4)
    var total = 0
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide {
        rep.getPixel(&pixel, atX: x, y: y)
        if pixel[3] > 250, (0..<3).allSatisfy({ abs(Int(pixel[$0]) - target[$0]) <= 1 }) { total += 1 }
      }
    }
    return total
  }

  private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )!
  }
}
