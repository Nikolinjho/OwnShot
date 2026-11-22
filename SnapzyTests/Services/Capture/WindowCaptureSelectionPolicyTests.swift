//
//  WindowCaptureSelectionPolicyTests.swift
//  SnapzyTests
//

import CoreGraphics
import XCTest
@testable import Snapzy

final class WindowCaptureSelectionPolicyTests: XCTestCase {
  private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876)
  private let menuBarPopoverFrame = CGRect(x: 1100, y: 500, width: 300, height: 376)

  func testПолноэкранныйСлужебныйДиалогНеСчитаетсяОкномПриложения() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    XCTAssertFalse(WindowCaptureSelectionPolicy.isMatchingAccessibleApplicationWindow(
      role: "AXWindow", subrole: "AXDialog", frame: display, expectedFrame: display
    ))
    XCTAssertFalse(WindowCaptureSelectionPolicy.isMatchingAccessibleApplicationWindow(
      role: "AXWindow", subrole: nil, frame: display, expectedFrame: display
    ))
  }

  func testНастоящееПолноэкранноеAXОкноТребуетСовпаденияГраниц() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    XCTAssertTrue(WindowCaptureSelectionPolicy.isMatchingAccessibleApplicationWindow(
      role: "AXWindow", subrole: "AXStandardWindow", frame: display, expectedFrame: display
    ))
    XCTAssertFalse(WindowCaptureSelectionPolicy.isMatchingAccessibleApplicationWindow(
      role: "AXWindow", subrole: "AXStandardWindow", frame: display.offsetBy(dx: 10, dy: 0), expectedFrame: display
    ))
  }

  func testПолноэкраннаяБезымяннаяПоверхностьВспомогательногоПроцессаНеВыбирается() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    XCTAssertFalse(WindowCaptureSelectionPolicy.isEligibleApplicationWindow(frame: display, displayFrames: [display], title: "", isRegularApplication: false, hasMatchingAccessibleWindow: false))
  }

  func testНастоящиеОкнаСохраняютВозможностьВыбора() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let panel = CGRect(x: 414, y: 526, width: 230, height: 408)
    XCTAssertTrue(WindowCaptureSelectionPolicy.isEligibleApplicationWindow(frame: display, displayFrames: [display], title: nil, isRegularApplication: true, hasMatchingAccessibleWindow: false))
    XCTAssertTrue(WindowCaptureSelectionPolicy.isEligibleApplicationWindow(frame: panel, displayFrames: [display], title: nil, isRegularApplication: false, hasMatchingAccessibleWindow: false))
    XCTAssertTrue(WindowCaptureSelectionPolicy.isEligibleApplicationWindow(frame: display, displayFrames: [display], title: nil, isRegularApplication: false, hasMatchingAccessibleWindow: true))
    XCTAssertTrue(WindowCaptureSelectionPolicy.isEligibleApplicationWindow(frame: display, displayFrames: [display], title: "Presentation", isRegularApplication: false, hasMatchingAccessibleWindow: false))
  }

  func testLayerZeroWindowRemainsNormalCandidate() {
    XCTAssertEqual(
      WindowCaptureSelectionPolicy.targetKind(
        windowLayer: 0,
        frame: CGRect(x: 80, y: 80, width: 800, height: 600),
        visibleFrame: visibleFrame,
        alpha: 1,
        isOwnApplication: false,
        isSystemOwned: false
      ),
      .normal
    )
  }

  func testTopAnchoredThirdPartyNonZeroLayerIsMenuBarPopover() {
    XCTAssertEqual(
      WindowCaptureSelectionPolicy.targetKind(
        windowLayer: 25,
        frame: menuBarPopoverFrame,
        visibleFrame: visibleFrame,
        alpha: 1,
        isOwnApplication: false,
        isSystemOwned: false
      ),
      .menuBarPopover
    )
  }

  func testNonZeroLayerExcludesUnanchoredTransparentSmallOwnAndSystemWindows() {
    let cases: [(CGRect, Double, Bool, Bool)] = [
      (CGRect(x: 400, y: 300, width: 300, height: 300), 1, false, false),
      (menuBarPopoverFrame, 0, false, false),
      (CGRect(x: 1100, y: 840, width: 32, height: 36), 1, false, false),
      (menuBarPopoverFrame, 1, true, false),
      (menuBarPopoverFrame, 1, false, true),
    ]

    for (frame, alpha, isOwnApplication, isSystemOwned) in cases {
      XCTAssertNil(
        WindowCaptureSelectionPolicy.targetKind(
          windowLayer: 25,
          frame: frame,
          visibleFrame: visibleFrame,
          alpha: alpha,
          isOwnApplication: isOwnApplication,
          isSystemOwned: isSystemOwned
        )
      )
    }
  }

  func testSystemOwnerDetectionExcludesDedicatedMacOSUI() {
    XCTAssertTrue(WindowCaptureSelectionPolicy.isSystemOwned(bundleIdentifier: "com.apple.dock", ownerName: "Dock"))
    XCTAssertTrue(WindowCaptureSelectionPolicy.isSystemOwned(bundleIdentifier: "com.apple.controlcenter", ownerName: "Control Center"))
    XCTAssertTrue(WindowCaptureSelectionPolicy.isSystemOwned(bundleIdentifier: "com.apple.notificationcenterui", ownerName: "Notification Center"))
    XCTAssertFalse(WindowCaptureSelectionPolicy.isSystemOwned(bundleIdentifier: "com.example.codexbar", ownerName: "CodexBar"))
  }

  func testImagePathPrefersScreenCaptureKitThenRetainedMenuBarPopover() {
    XCTAssertEqual(
      WindowCaptureImagePath.resolve(targetKind: .menuBarPopover, hasShareableWindow: true),
      .screenCaptureKit
    )
    XCTAssertEqual(
      WindowCaptureImagePath.resolve(
        targetKind: .menuBarPopover,
        hasShareableWindow: false,
        hasRetainedMenuBarPopover: true
      ),
      .retainedMenuBarPopover
    )
    XCTAssertEqual(
      WindowCaptureImagePath.resolve(
        targetKind: .menuBarPopover,
        hasShareableWindow: false,
        hasRetainedMenuBarPopover: false
      ),
      .coreGraphicsWindow
    )
    XCTAssertEqual(
      WindowCaptureImagePath.resolve(targetKind: .normal, hasShareableWindow: false),
      .areaFallback
    )
  }

  func testDisplaySnapshotCropFlipsAppKitYAxisAtRetinaScale() {
    let crop = WindowCaptureSelectionPolicy.displaySnapshotCropRect(
      frame: CGRect(x: 1100, y: 500, width: 300, height: 376),
      displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      imagePixelWidth: 2880,
      imagePixelHeight: 1800
    )

    XCTAssertEqual(crop, CGRect(x: 2200, y: 48, width: 600, height: 752))
  }

  func testDisplaySnapshotCropHandlesOffsetDisplayAndClampsToItsBounds() {
    let crop = WindowCaptureSelectionPolicy.displaySnapshotCropRect(
      frame: CGRect(x: -120, y: 650, width: 300, height: 250),
      displayFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
      imagePixelWidth: 1440,
      imagePixelHeight: 900
    )

    XCTAssertEqual(crop, CGRect(x: 1320, y: 0, width: 120, height: 250))
  }

  func testDisplaySnapshotCropRejectsFrameOutsideDisplay() {
    XCTAssertNil(
      WindowCaptureSelectionPolicy.displaySnapshotCropRect(
        frame: CGRect(x: 1500, y: 300, width: 200, height: 200),
        displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        imagePixelWidth: 2880,
        imagePixelHeight: 1800
      )
    )
  }

  func testRetainedPopoverCandidateStaysAheadAndDeduplicatesLiveCandidate() {
    let target = WindowCaptureTarget(
      windowID: 42,
      frame: menuBarPopoverFrame,
      displayID: CGMainDisplayID(),
      title: nil,
      bundleIdentifier: "com.example.codexbar",
      ownerPID: 123,
      kind: .menuBarPopover
    )
    let secondTarget = WindowCaptureTarget(
      windowID: 41,
      frame: CGRect(x: 700, y: 500, width: 300, height: 376),
      displayID: CGMainDisplayID(),
      title: nil,
      bundleIdentifier: "com.example.otherbar",
      ownerPID: 122,
      kind: .menuBarPopover
    )
    let retained = WindowSelectionSnapshot(
      orderedCandidates: [
        WindowSelectionCandidate(target: target, ownerName: "CodexBar", windowLayer: 25),
        WindowSelectionCandidate(target: secondTarget, ownerName: "OtherBar", windowLayer: 25),
      ]
    )
    let live = WindowSelectionSnapshot(
      orderedCandidates: [
        WindowSelectionCandidate(target: target, ownerName: "CodexBar", windowLayer: 25),
        WindowSelectionCandidate(
          target: WindowCaptureTarget(
            windowID: 43,
            frame: CGRect(x: 100, y: 100, width: 500, height: 400),
            displayID: CGMainDisplayID(),
            title: "Other",
            bundleIdentifier: "com.example.other",
            ownerPID: 124
          ),
          ownerName: "Other",
          windowLayer: 0
        ),
      ]
    )

    let merged = retained.merging(live)

    XCTAssertEqual(merged.orderedCandidates.map(\.target.windowID), [42, 41, 43])
  }

  func testRetainedPopoverIsOnlyPresentedWhenOriginalWindowHasClosed() {
    XCTAssertTrue(WindowCaptureSelectionPolicy.shouldShowRetainedMenuBarPopover(isWindowStillOnScreen: false))
    XCTAssertFalse(WindowCaptureSelectionPolicy.shouldShowRetainedMenuBarPopover(isWindowStillOnScreen: true))
  }

  func testMenuBarPopoverMaskMakesCornersTransparent() {
    let source = solidImage(width: 40, height: 40)
    let masked = WindowCaptureSelectionPolicy.alphaMaskedMenuBarPopoverImage(
      source,
      cornerRadiusInPoints: 12,
      scaleFactor: 1
    )

    XCTAssertNotNil(masked)
    guard let masked else { return }
    XCTAssertEqual(alpha(in: masked, x: 0, y: 0), 0)
    XCTAssertEqual(alpha(in: masked, x: 20, y: 20), 255)
  }

  private func solidImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  private func alpha(in image: CGImage, x: Int, y: Int) -> UInt8 {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return pixel[3]
  }
}
