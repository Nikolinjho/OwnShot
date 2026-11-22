//
//  RecordingCameraFullscreenToggleTests.swift
//  SnapzyTests
//
//  «Toggle Camera Fullscreen»: камера на весь записываемый дисплей и возврат прежнего фрейма.
//

import CoreGraphics
import XCTest
@testable import Snapzy

@MainActor
final class RecordingCameraFullscreenToggleTests: XCTestCase {
  private let overlayFrame = CGRect(x: 1500, y: 40, width: 280, height: 158)
  private let displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  func testToggleEntersFullscreenAndRestoresPreviousFrame() {
    var toggle = RecordingCameraFullscreenToggle()
    XCTAssertFalse(toggle.isFullscreen)

    let fullscreen = toggle.toggle(currentFrame: overlayFrame, fullscreenFrame: displayFrame)
    XCTAssertEqual(fullscreen, displayFrame)
    XCTAssertTrue(toggle.isFullscreen)
    XCTAssertEqual(toggle.restoreFrame, overlayFrame)

    let restored = toggle.toggle(currentFrame: displayFrame, fullscreenFrame: displayFrame)
    XCTAssertEqual(restored, overlayFrame)
    XCTAssertFalse(toggle.isFullscreen)
    XCTAssertNil(toggle.restoreFrame)
  }

  func testConfigurationChangeInFullscreenUpdatesRestoreFrame() {
    var toggle = RecordingCameraFullscreenToggle()
    _ = toggle.toggle(currentFrame: overlayFrame, fullscreenFrame: displayFrame)

    let resized = CGRect(x: 1600, y: 40, width: 180, height: 180)
    toggle.updateRestoreFrame(resized)
    XCTAssertEqual(toggle.toggle(currentFrame: displayFrame, fullscreenFrame: displayFrame), resized)
  }

  func testUpdateRestoreFrameIgnoredOutsideFullscreen() {
    var toggle = RecordingCameraFullscreenToggle()
    toggle.updateRestoreFrame(overlayFrame)
    XCTAssertFalse(toggle.isFullscreen)
    XCTAssertNil(toggle.restoreFrame)
  }

  func testFullscreenFrameUsesDisplayWithLargestOverlap() {
    let secondDisplay = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let recordingRect = CGRect(x: 1800, y: 100, width: 800, height: 600)

    XCTAssertEqual(
      RecordingCameraFullscreenToggle.fullscreenFrame(
        for: recordingRect,
        screenFrames: [displayFrame, secondDisplay]
      ),
      secondDisplay
    )
  }

  func testFullscreenFrameFallsBackToRecordingRectWithoutScreens() {
    let recordingRect = CGRect(x: 10, y: 10, width: 400, height: 300)
    XCTAssertEqual(
      RecordingCameraFullscreenToggle.fullscreenFrame(for: recordingRect, screenFrames: []),
      recordingRect
    )
  }

  func testShortcutWithoutActiveSessionDoesNothing() {
    XCTAssertFalse(RecordingCoordinator().toggleCameraFullscreenFromShortcut())
  }
}
