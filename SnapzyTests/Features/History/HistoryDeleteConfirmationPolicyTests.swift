//
//  HistoryDeleteConfirmationPolicyTests.swift
//  SnapzyTests
//
//  Подтверждение удаления одной записи History.
//

import XCTest
@testable import Snapzy

@MainActor
final class HistoryDeleteConfirmationPolicyTests: XCTestCase {
  private func makeDefaults() -> UserDefaults {
    let suite = "HistoryDeleteConfirmationPolicyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  func testПоУмолчаниюСпрашивает() {
    XCTAssertTrue(HistoryDeleteConfirmationPolicy.shouldAsk(defaults: makeDefaults()))
  }

  func testФлажокDontAskОтключаетВопрос() {
    let defaults = makeDefaults()
    HistoryDeleteConfirmationPolicy.setSuppressed(true, defaults: defaults)
    XCTAssertFalse(HistoryDeleteConfirmationPolicy.shouldAsk(defaults: defaults))
    HistoryDeleteConfirmationPolicy.setSuppressed(false, defaults: defaults)
    XCTAssertTrue(HistoryDeleteConfirmationPolicy.shouldAsk(defaults: defaults))
  }

  func testЗаголовокБезРасширения() {
    let record = CaptureHistoryRecord(
      id: UUID(),
      filePath: "/tmp/OwnShot-History-delete-b87fe5ad.png",
      fileName: "OwnShot-History-delete-b87fe5ad.png",
      captureType: .screenshot,
      fileSize: 1,
      capturedAt: Date(),
      width: 1,
      height: 1,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false
    )
    XCTAssertEqual(
      HistoryDeleteConfirmationPolicy.title(for: record),
      "Are you sure you want to delete \"OwnShot-History-delete-b87fe5ad\" from history?"
    )
  }
}
