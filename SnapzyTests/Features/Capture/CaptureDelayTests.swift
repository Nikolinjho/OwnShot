//
//  CaptureDelayTests.swift
//  SnapzyTests
//
//  Delayed Capture countdown setting resolution and the whole-second
//  countdown state machine behind the countdown HUD.
//

import AppKit
import XCTest
@testable import Snapzy

final class CaptureDelayTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "CaptureDelayTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - CaptureDelayOption

  func testOptionsAreTwoFiveTenFifteenSeconds() {
    XCTAssertEqual(CaptureDelayOption.allCases.map(\.seconds), [2, 5, 10, 15])
  }

  func testCurrentDefaultsToFiveSecondsWhenUnset() {
    XCTAssertEqual(CaptureDelayOption.current(defaults: defaults), .fiveSeconds)
  }

  func testLegacyThreeSecondsMigratesToDefault() {
    // 3 секунды из прежних версий не ломают импорт и чтение настройки.
    XCTAssertEqual(CaptureDelayOption.migrating(3), .fiveSeconds)
    XCTAssertEqual(CaptureDelayOption.migrating(15), .fifteenSeconds)
    XCTAssertNil(CaptureDelayOption.migrating(7))
    defaults.set(3, forKey: PreferencesKeys.screenshotDelayedCaptureSeconds)
    XCTAssertEqual(CaptureDelayOption.current(defaults: defaults), .fiveSeconds)
  }

  func testCurrentReadsStoredSeconds() {
    defaults.set(10, forKey: PreferencesKeys.screenshotDelayedCaptureSeconds)
    XCTAssertEqual(CaptureDelayOption.current(defaults: defaults), .tenSeconds)
  }

  func testUnknownStoredValueFallsBackToDefault() {
    defaults.set(7, forKey: PreferencesKeys.screenshotDelayedCaptureSeconds)
    XCTAssertEqual(CaptureDelayOption.current(defaults: defaults), .fiveSeconds)
    XCTAssertEqual(CaptureDelayOption.resolve(0), .fiveSeconds)
  }

  // MARK: - CaptureDelayCountdown

  func testCountdownFinishesExactlyOnceAfterAllSeconds() {
    var countdown = CaptureDelayCountdown(seconds: 3)
    XCTAssertFalse(countdown.tick())
    XCTAssertEqual(countdown.remainingSeconds, 2)
    XCTAssertFalse(countdown.tick())
    XCTAssertEqual(countdown.remainingSeconds, 1)
    XCTAssertTrue(countdown.tick())
    XCTAssertTrue(countdown.isFinished)
    XCTAssertFalse(countdown.tick(), "A finished countdown must not fire again")
    XCTAssertEqual(countdown.remainingSeconds, 0)
  }

  func testNegativeSecondsClampToFinished() {
    var countdown = CaptureDelayCountdown(seconds: -2)
    XCTAssertTrue(countdown.isFinished)
    XCTAssertFalse(countdown.tick())
  }

  // MARK: - CaptureDelayTarget

  func testAreaTargetKeepsTheOriginalCountdownLayout() {
    XCTAssertEqual(CaptureDelayTarget.area.logName, "delayedArea")
    XCTAssertNil(CaptureDelayTarget.area.hudDetail)
  }

  func testFullscreenTargetNamesTheCaptureAndLabelsTheHUD() {
    XCTAssertEqual(CaptureDelayTarget.fullscreen.logName, "delayedFullscreen")
    XCTAssertEqual(
      CaptureDelayTarget.fullscreen.hudDetail,
      L10n.ScreenCapture.captureDelayFullscreenHint
    )
    XCTAssertFalse(CaptureDelayTarget.fullscreen.hudDetail?.isEmpty ?? true)
  }

  func testDelayedFullscreenShortcutShipsUnbound() {
    XCTAssertEqual(GlobalShortcutKind.delayedFullscreen.configKey, "delayed_fullscreen")
    XCTAssertFalse(GlobalShortcutKind.delayedFullscreen.isSystemConflictRelevant)
    XCTAssertFalse(GlobalShortcutKind.delayedFullscreen.displayName.isEmpty)
  }

  @MainActor
  func testТаймерПоказываетКомпактнуюКапсулуУВерхнегоКрая() throws {
    let controller = CaptureDelayCountdownController.shared
    controller.start(seconds: 10, captureName: "test", detail: "test") {}
    defer { controller.cancel() }
    let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "OwnShotCountdown" })
    XCTAssertEqual(panel.frame.size, CGSize(width: 110, height: 62))
    XCTAssertGreaterThanOrEqual(panel.level.rawValue, 2147483630)
    let screen = try XCTUnwrap(panel.screen)
    XCTAssertEqual(panel.frame.midX, screen.frame.midX, accuracy: 1)
    XCTAssertLessThan(screen.visibleFrame.maxY - panel.frame.maxY, 40)
    controller.cancel()
    XCTAssertFalse(controller.isActive)
    XCTAssertFalse(panel.isVisible)
  }

  @MainActor
  func testОтменаТаймераУбираетЗатемнениеБезЗахвата() throws {
    let controller = CaptureDelayCountdownController.shared
    var captured = false
    controller.start(seconds: 10, captureName: "test", highlightRect: CGRect(x: 100, y: 100, width: 300, height: 200)) {
      captured = true
    }
    defer { controller.cancel() }
    let overlays = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "OwnShotCountdownOverlay" }
    XCTAssertEqual(overlays.count, NSScreen.screens.count)
    XCTAssertTrue(overlays.allSatisfy { $0.level.rawValue == 2147483630 })
    controller.cancel()
    XCTAssertFalse(captured)
    XCTAssertFalse(controller.isActive)
    XCTAssertTrue(overlays.allSatisfy { !$0.isVisible })
  }

  @MainActor
  func testСтарыйТикНеУменьшаетНовыйОтсчётПослеОтмены() async throws {
    let controller = CaptureDelayCountdownController.shared
    defer { controller.cancel() }
    var captured = false
    controller.start(seconds: 5, captureName: "first") { captured = true }
    let oldTimer = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "timer" }?.value as? Timer)
    oldTimer.fire()
    controller.cancel()
    controller.start(seconds: 5, captureName: "second") { captured = true }

    try await Task.sleep(for: .milliseconds(60))

    let countdown = try XCTUnwrap(Mirror(reflecting: controller).children
      .first { $0.label == "countdown" }?.value as? CaptureDelayCountdown)
    XCTAssertEqual(countdown.remainingSeconds, 5)
    XCTAssertTrue(controller.isActive)
    XCTAssertFalse(captured)

    let currentTimer = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "timer" }?.value as? Timer)
    currentTimer.fire()
    try await Task.sleep(for: .milliseconds(60))

    let ticked = try XCTUnwrap(Mirror(reflecting: controller).children
      .first { $0.label == "countdown" }?.value as? CaptureDelayCountdown)
    XCTAssertEqual(ticked.remainingSeconds, 4)
    XCTAssertFalse(captured)
  }

  @MainActor
  func testЗахватНачинаетсяПослеИсчезновенияКапсулыИЗатемнения() async {
    let controller = CaptureDelayCountdownController.shared
    let captured = expectation(description: "Захват после скрытия окон")
    controller.start(seconds: 1, captureName: "test", highlightRect: CGRect(x: 100, y: 100, width: 300, height: 200)) {
      XCTAssertFalse(NSApp.windows.contains {
        $0.isVisible && ($0.identifier?.rawValue == "OwnShotCountdown" || $0.identifier?.rawValue == "OwnShotCountdownOverlay")
      })
      captured.fulfill()
    }
    await fulfillment(of: [captured], timeout: 4)
    controller.cancel()
  }
}
