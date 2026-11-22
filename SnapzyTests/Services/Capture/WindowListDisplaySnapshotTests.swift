//
//  WindowListDisplaySnapshotTests.swift
//  SnapzyTests
//
//  Unit tests for choosing which on-screen windows a chrome-free snapshot composites.
//

import XCTest
@testable import Snapzy

final class WindowListDisplaySnapshotTests: XCTestCase {
  func testРазрешениеТребующееПерезапускаНеДопускаетЗахват() {
    XCTAssertNotNil(ScreenCaptureManager.captureAvailabilityError(
      permissionStatus: .granted, requiresRelaunch: true))
    XCTAssertNil(ScreenCaptureManager.captureAvailabilityError(
      permissionStatus: .granted, requiresRelaunch: false))
    XCTAssertNotNil(ScreenCaptureManager.captureAvailabilityError(
      permissionStatus: .notGranted, requiresRelaunch: false))
  }
  func testБезАктивногоРазрешенияНеЗапрашиваетИНеВозвращаетКадр() throws {
    var captured = false
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 2, height: 2))
    let result = WindowListDisplaySnapshot.captureIfAuthorized(hasAccess: { false }) {
      captured = true
      return image
    }
    XCTAssertNil(result)
    XCTAssertFalse(captured)
  }

  func testСАктивнымРазрешениемВозвращаетИсходныйКадр() throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 2, height: 2))
    let result = WindowListDisplaySnapshot.captureIfAuthorized(hasAccess: { true }) { image }
    XCTAssertTrue(result === image)
  }

  func testCompositedWindowIDs_dropsExcludedAndKeepsOrder() {
    let result = WindowListDisplaySnapshot.compositedWindowIDs(
      onScreenWindowIDs: [40, 12, 7, 99],
      excluding: [12, 99]
    )

    XCTAssertEqual(result, [40, 7])
  }

  func testCompositedWindowIDs_returnsNilWhenNoExcludedWindowIsOnScreen() {
    XCTAssertNil(
      WindowListDisplaySnapshot.compositedWindowIDs(onScreenWindowIDs: [1, 2, 3], excluding: [42])
    )
  }

  func testCompositedWindowIDs_returnsNilForEmptyExclusion() {
    XCTAssertNil(
      WindowListDisplaySnapshot.compositedWindowIDs(onScreenWindowIDs: [1, 2, 3], excluding: [])
    )
  }
}
