//
//  CardChromeParity067Tests.swift
//  SnapzyTests
//
//  Карточки, History, сайдбар Settings и радиус окон по правилам spec-066 (волна 067).
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class CardChromeParity067Tests: XCTestCase {
  // MARK: - R20 угловые кнопки превью

  func testУгловыеКнопкиQAКруги22ptСОтступом6() {
    // audit-020/reference-quick-hover.png: круг 44 px, начинается в 12 px от края карточки
    XCTAssertEqual(QuickAccessLayout.cornerButtonSize, 22)
    XCTAssertEqual(QuickAccessLayout.cornerButtonInset, 6)
    XCTAssertEqual(QuickAccessLayout.cornerGlyphHex, 0x151515)
  }

  func testПодложкаКнопокКарточкиПолупрозрачныйБелый78() {
    // #CECDCF на #2D2C2D и #CFD6E3 на #314B77: фон просвечивает, α≈0.75–0.78
    XCTAssertEqual(QuickAccessLayout.buttonFillOpacity, 0.78, accuracy: 0.001)
    XCTAssertLessThan(QuickAccessLayout.buttonFillOpacity, 1)
    let onDark = 255 * QuickAccessLayout.buttonFillOpacity + 0x2D * (1 - QuickAccessLayout.buttonFillOpacity)
    XCTAssertEqual(onDark, Double(0xCE), accuracy: 4)
    XCTAssertGreaterThan(QuickAccessLayout.buttonFillHoverOpacity, QuickAccessLayout.buttonFillOpacity)
  }

  func testКнопкиPinВидимыйКруг22ptВ10ptОтУгла() {
    // spec-062-live/ref-pin-hover.png: круг 44 px с x = 20 px
    XCTAssertEqual(QuickAccessPinChromeMetrics.visibleButtonSize, 22)
    let visibleInset = QuickAccessPinChromeMetrics.controlInset
      + (QuickAccessPinChromeMetrics.buttonSize - QuickAccessPinChromeMetrics.visibleButtonSize) / 2
    XCTAssertEqual(visibleInset, 10)
    XCTAssertEqual(QuickAccessPinChromeMetrics.glyphOpacity, 0.45, accuracy: 0.001)
  }

  // MARK: - R21 текстовые капсулы

  func testКапсулыCopySaveКакУЭталона() {
    // Видимая капсула 22 pt внутри ячейки 29 pt, шаг центров 37 pt (74 px @2x)
    XCTAssertEqual(QuickAccessLayout.textButtonHeight, 22)
    XCTAssertEqual(QuickAccessLayout.textButtonHitHeight, 29)
    XCTAssertEqual(QuickAccessLayout.textButtonHitHeight + QuickAccessLayout.textButtonSpacing, 37)
    XCTAssertEqual(QuickAccessLayout.textButtonFontSize, 12)
    XCTAssertEqual(QuickAccessLayout.textButtonTextHex, 0x1F1F20)
  }

  func testRestoreКапсула25pt() {
    // spec-062-live/ref-history-full.png: Restore 50 px по высоте
    XCTAssertEqual(HistoryChrome.restoreButtonHeight, 25)
    XCTAssertEqual(HistoryChrome.restoreHorizontalPadding, 10)
  }

  // MARK: - R04 акцент History

  func testАкцентHistoryЗависитОтТемыИНеSystemRed() throws {
    XCTAssertEqual(HistoryChrome.accentHex(isDark: false), 0xE0383E)
    XCTAssertEqual(HistoryChrome.accentHex(isDark: true), 0xFF5257)
    for (name, hex) in [(NSAppearance.Name.aqua, 0xE0383E), (.darkAqua, 0xFF5257)] {
      let appearance = try XCTUnwrap(NSAppearance(named: name))
      XCTAssertEqual(HistoryChrome.accentHex(for: appearance), UInt32(hex))
      var resolved: NSColor?
      var systemRed: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        resolved = HistoryChrome.selectionAccentNSColor.usingColorSpace(.sRGB)
        systemRed = NSColor.systemRed.usingColorSpace(.sRGB)
      }
      let color = try XCTUnwrap(resolved)
      XCTAssertEqual(Int((color.redComponent * 255).rounded()), (hex >> 16) & 255)
      XCTAssertEqual(Int((color.greenComponent * 255).rounded()), (hex >> 8) & 255)
      XCTAssertEqual(Int((color.blueComponent * 255).rounded()), hex & 255)
      XCTAssertNotEqual(color, systemRed)
    }
  }

  // MARK: - R06/R16/R17 сайдбар Settings

  func testВыборВСайдбареНейтральный() {
    XCTAssertEqual(PreferencesSidebarChrome.selectionHex(isDark: false, isActive: true), 0xDCDCDC)
    XCTAssertEqual(PreferencesSidebarChrome.selectionHex(isDark: true, isActive: true), 0x3D3A39)
    XCTAssertEqual(PreferencesSidebarChrome.selectionHex(isDark: false, isActive: false), 0xEAE9E8)
    XCTAssertEqual(PreferencesSidebarChrome.selectionHex(isDark: true, isActive: false), 0x333130)
    // Нейтральный: каналы отличаются не больше чем на 4 (тёплый серый #3D3A39), без акцентного оттенка
    for dark in [false, true] {
      for active in [false, true] {
        let hex = PreferencesSidebarChrome.selectionHex(isDark: dark, isActive: active)
        let r = Int((hex >> 16) & 255), g = Int((hex >> 8) & 255), b = Int(hex & 255)
        XCTAssertLessThanOrEqual(max(r, g, b) - min(r, g, b), 4)
      }
    }
  }

  func testСветлыйСайдбарВНеактивномОкнеСветлеет() {
    XCTAssertEqual(PreferencesSidebarBackground.hex(isDark: false, isActive: true), 0xECECEB)
    XCTAssertEqual(PreferencesSidebarBackground.hex(isDark: false, isActive: false), 0xF3F2F1)
    XCTAssertEqual(PreferencesSidebarBackground.hex(isDark: true, isActive: false), 0x2C2928)
  }

  func testПодписиИЗначкиСайдбараГаснутВдвое() {
    XCTAssertEqual(PreferencesSidebarChrome.labelOpacity(isDark: false, isActive: true), 0.77)
    XCTAssertEqual(PreferencesSidebarChrome.labelOpacity(isDark: false, isActive: false), 0.35)
    XCTAssertEqual(PreferencesSidebarChrome.labelOpacity(isDark: true, isActive: true), 0.92)
    XCTAssertEqual(PreferencesSidebarChrome.labelOpacity(isDark: true, isActive: false), 0.45)
    XCTAssertEqual(PreferencesSidebarChrome.iconOpacity(isActive: false), 0.5)
    XCTAssertEqual(PreferencesSidebarChrome.iconOpacity(isActive: true), 1)
    // #9D9D9C на #F3F2F1: чёрный 0.35
    let label = 0xF3 * (1 - PreferencesSidebarChrome.labelOpacity(isDark: false, isActive: false))
    XCTAssertEqual(label, Double(0x9D), accuracy: 2)
  }

  // MARK: - R10 радиус окон

  func testРадиусОконПоУмолчанию16pt() {
    // Профиль угла Settings и редактора @2x совпадает с дугой 32 px (spec-050-visual/light/*-on-000000.png)
    XCTAssertEqual(NSWindow.defaultCornerRadius, 16)
  }
}
