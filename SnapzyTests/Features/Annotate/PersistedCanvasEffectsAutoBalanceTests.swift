//
//  PersistedCanvasEffectsAutoBalanceTests.swift
//  SnapzyTests
//
//  Auto-balance в сохранённых сессиях: старый ключ с прежним дефолтом true не включает
//  выравнивание отступов, новое значение переживает round-trip.
//

import Foundation
import XCTest
@testable import Snapzy

final class PersistedCanvasEffectsAutoBalanceTests: XCTestCase {
  private func encodedObject(autoBalance: Bool) throws -> [String: Any] {
    var effects = AnnotationCanvasEffects()
    effects.autoBalance = autoBalance
    let data = try JSONEncoder().encode(PersistedCanvasEffects(effects: effects))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testRoundTrip_keepsEnabledAutoBalance() throws {
    var effects = AnnotationCanvasEffects()
    effects.autoBalance = true
    let data = try JSONEncoder().encode(PersistedCanvasEffects(effects: effects))
    let decoded = try JSONDecoder().decode(PersistedCanvasEffects.self, from: data)
    XCTAssertTrue(decoded.autoBalance)
  }

  func testEncode_writesNewKeyOnly() throws {
    let object = try encodedObject(autoBalance: true)
    XCTAssertEqual(object["autoBalanceEnabled"] as? Bool, true)
    XCTAssertNil(object["autoBalance"])
  }

  func testDecode_legacyKeyWithOldDefaultIsIgnored() throws {
    var object = try encodedObject(autoBalance: false)
    object.removeValue(forKey: "autoBalanceEnabled")
    object["autoBalance"] = true
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PersistedCanvasEffects.self, from: data)
    XCTAssertFalse(decoded.autoBalance)
  }
}
