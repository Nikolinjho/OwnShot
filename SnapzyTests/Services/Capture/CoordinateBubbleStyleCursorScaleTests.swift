//
//  CoordinateBubbleStyleCursorScaleTests.swift
//  SnapzyTests
//
//  Подпись координат при выключенном прицеле растёт вместе с системным курсором (CAP-109).
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class CoordinateBubbleStyleCursorScaleTests: XCTestCase {
  func testМасштабКурсораИзНастройкиУниверсальногоДоступа() {
    XCTAssertEqual(CoordinateBubbleStyle.cursorScale(fromPreference: nil), 1)
    XCTAssertEqual(CoordinateBubbleStyle.cursorScale(fromPreference: "2"), 1)
    XCTAssertEqual(CoordinateBubbleStyle.cursorScale(fromPreference: NSNumber(value: 0.5)), 1)
    XCTAssertEqual(CoordinateBubbleStyle.cursorScale(fromPreference: NSNumber(value: 2.094911336898804)), 2.094911336898804, accuracy: 0.0001)
    XCTAssertEqual(CoordinateBubbleStyle.cursorScale(fromPreference: NSNumber(value: 9)), CoordinateBubbleStyle.maximumCursorScale)
    XCTAssertEqual(CoordinateBubbleStyle.cursorScale(fromPreference: NSNumber(value: Double.nan)), 1)
  }

  func testПодписьРастётВместеСКурсоромВоВсехРежимах() {
    XCTAssertEqual(CoordinateBubbleStyle.coordinateLabelScale(crosshairMode: .disabled, cursorScale: 2), 2)
    XCTAssertEqual(CoordinateBubbleStyle.coordinateLabelScale(crosshairMode: .disabled, cursorScale: 1), 1)
    // R26: прицел один во всех режимах, подпись растёт вместе с ним
    // (spec-063-live/ref-area-open-cursor.png, spec-062-live/ref-capture-area-cursor.png).
    XCTAssertEqual(CoordinateBubbleStyle.coordinateLabelScale(crosshairMode: .always, cursorScale: 2), 2)
    XCTAssertEqual(CoordinateBubbleStyle.coordinateLabelScale(crosshairMode: .command, cursorScale: 2), 2)
  }

  func testСдвигИТеньЦифрКакУЭталонаПриРазмереУказателя209() {
    // На кадрах эталона при размере указателя 2,09: цифры на 31×14 px (2×) от центра,
    // светлая тень сдвинута на 5 px вправо-вниз, белый ≈85 %.
    let scale: CGFloat = 2.09
    XCTAssertEqual(CoordinateBubbleStyle.labelOffset.width * scale, 15.5, accuracy: 0.25)
    XCTAssertEqual(CoordinateBubbleStyle.labelOffset.height * scale, 7, accuracy: 0.25)
    XCTAssertEqual(CoordinateBubbleStyle.shadowOffset.width * scale, 2.5, accuracy: 0.1)
    XCTAssertEqual(CoordinateBubbleStyle.shadowOffset.height * scale, -2.5, accuracy: 0.1)
    XCTAssertEqual(CoordinateBubbleStyle.shadowOpacity, 0.85, accuracy: 0.001)
    // Цифры тёмные, тень светлая.
    XCTAssertLessThan(CoordinateBubbleStyle.textColor.whiteComponent, 0.1)
    XCTAssertEqual(CoordinateBubbleStyle.shadowColor, .white)
  }

  func testШрифтПодписиМасштабируется() {
    XCTAssertEqual(CoordinateBubbleStyle.font(scale: 1), CoordinateBubbleStyle.font)
    XCTAssertEqual(CoordinateBubbleStyle.font(scale: 2).pointSize, CoordinateBubbleStyle.font.pointSize * 2)
    XCTAssertEqual(CoordinateBubbleStyle.font(scale: 0.3).pointSize, CoordinateBubbleStyle.font.pointSize)
  }
}
