//
//  ScreenshotLastAreaStoreTests.swift
//  SnapzyTests
//
//  Unit tests for repeat-area screenshot rect persistence.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class ScreenshotLastAreaStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.screenshotLastAreaRect)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.screenshotLastAreaRect)
    super.tearDown()
  }

  func testLoadReturnsNilWhenNothingStored() {
    XCTAssertEqual(ScreenshotLastAreaStore.lookup(), .missing)
    XCTAssertNil(ScreenshotLastAreaStore.load())
  }

  func testSaveThenLoadRoundTripsRect() {
    let screenFrame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let rect = screenFrame.insetBy(dx: 100, dy: 100)

    ScreenshotLastAreaStore.save(rect)

    XCTAssertEqual(ScreenshotLastAreaStore.lookup(), .available(rect))
    XCTAssertEqual(ScreenshotLastAreaStore.load(), rect)
  }

  func testLoadReturnsNilForCorruptedPayload() {
    UserDefaults.standard.set(["x": "not-a-number"], forKey: PreferencesKeys.screenshotLastAreaRect)

    XCTAssertEqual(ScreenshotLastAreaStore.lookup(), .missing)
    XCTAssertNil(ScreenshotLastAreaStore.load())
  }

  func testВырожденнаяИНеконечнаяОбластьСчитаетсяОтсутствующей() {
    let valid: [String: CGFloat] = ["x": 20, "y": 30, "width": 50, "height": 60]
    let corruptions: [(String, CGFloat)] = [
      ("x", .infinity), ("y", .nan), ("width", 0), ("width", .infinity), ("height", -10),
    ]
    for (key, value) in corruptions {
      var fields = valid
      fields[key] = value
      XCTAssertNil(ScreenshotLastAreaStore.decode(fields), "\(key)=\(value)")
    }
  }

  func testДробныйИдентификаторИНеконечнаяПривязкаНеЗаменяютГлобальнуюОбласть() {
    let rect = CGRect(x: 20, y: 30, width: 50, height: 60)
    let fields: [String: CGFloat] = ["x": 20, "y": 30, "width": 50, "height": 60]
    let display = ScreenshotLastAreaStore.ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let invalidMetadata: [[String: CGFloat]] = [
      ["screenID": 1.5, "localX": 180, "localY": 190],
      ["screenID": -1, "localX": 180, "localY": 190],
      ["screenID": .greatestFiniteMagnitude, "localX": 180, "localY": 190],
      ["screenID": 1, "localX": .infinity, "localY": 190],
    ]
    for metadata in invalidMetadata {
      let result = ScreenshotLastAreaStore.decode(fields.merging(metadata) { _, local in local })
      XCTAssertEqual(result?.rect, rect)
      XCTAssertNil(result?.localOrigin)
      XCTAssertEqual(result.flatMap { ScreenshotLastAreaStore.resolve($0, screens: [display]) }, rect)
    }
  }

  func testLoadReturnsNilWhenRectIsOffAllScreens() {
    let offscreen = CGRect(x: -1_000_000, y: -1_000_000, width: 200, height: 200)
    ScreenshotLastAreaStore.save(offscreen)

    XCTAssertEqual(ScreenshotLastAreaStore.lookup(), .offscreen)
    XCTAssertNil(ScreenshotLastAreaStore.load())
  }
}
