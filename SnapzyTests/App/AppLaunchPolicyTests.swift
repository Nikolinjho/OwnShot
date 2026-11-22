//
//  AppLaunchPolicyTests.swift
//  SnapzyTests
//
//  Unit tests for deciding whether the host app should start interactive UI.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class AppLaunchPolicyTests: XCTestCase {
  func testShouldStartInteractiveApplication_underXCTestSkipsBeforeScreenAccess() {
    var didRequestScreenCount = false
    let policy = AppLaunchPolicy(
      environment: ["XCTestConfigurationFilePath": "/tmp/SnapzyTests.xctestconfiguration"],
      screenCountProvider: {
        didRequestScreenCount = true
        return 1
      }
    )

    XCTAssertFalse(policy.shouldStartInteractiveApplication)
    XCTAssertFalse(didRequestScreenCount)
  }

  func testShouldStartInteractiveApplication_headlessDisplaySessionReturnsFalse() {
    let policy = AppLaunchPolicy(
      environment: [:],
      screenCountProvider: { 0 }
    )

    XCTAssertTrue(policy.isHeadlessDisplaySession)
    XCTAssertFalse(policy.shouldStartInteractiveApplication)
  }

  func testShouldStartInteractiveApplication_interactiveDisplaySessionReturnsTrue() {
    let policy = AppLaunchPolicy(
      environment: [:],
      screenCountProvider: { 1 }
    )

    XCTAssertFalse(policy.isRunningUnderXCTest)
    XCTAssertFalse(policy.isHeadlessDisplaySession)
    XCTAssertTrue(policy.shouldStartInteractiveApplication)
  }

  func testShouldStartInteractiveApplication_canOptInInteractiveXCTestHost() {
    let policy = AppLaunchPolicy(
      environment: [
        "XCTestConfigurationFilePath": "/tmp/SnapzyTests.xctestconfiguration",
        "SNAPZY_ALLOW_INTERACTIVE_XCTEST_HOST": "1",
      ],
      screenCountProvider: { 1 }
    )

    XCTAssertTrue(policy.shouldStartInteractiveApplication)
  }

  func testAppDelegate_skippedLaunchKeepsOpenFilesQueued() {
    let delegate = AppDelegate(
      launchPolicyProvider: {
        AppLaunchPolicy(environment: [:], screenCountProvider: { 0 })
      }
    )
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("png")

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )
    delegate.application(NSApplication.shared, open: [fileURL])

    XCTAssertFalse(delegate.didFinishLaunchingForTesting)
    XCTAssertFalse(delegate.hasCoordinatorForTesting)
    XCTAssertEqual(delegate.pendingOpenFileURLCountForTesting, 1)
  }

  func testInstanceLock_второйВладелецНеПолучаетБлокировку() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("instance.lock")
    let first = try AppInstanceLock(url: url)
    let second = try AppInstanceLock(url: url)

    XCTAssertTrue(first.isOwner)
    XCTAssertFalse(second.isOwner)
    withExtendedLifetime(first) {}
  }

  func testInstanceLock_послеВыходаВладельцаМожноЗапуститьсяСнова() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("instance.lock")
    var first: AppInstanceLock? = try AppInstanceLock(url: url)
    XCTAssertTrue(first?.isOwner == true)
    first = nil

    let next = try AppInstanceLock(url: url)
    XCTAssertTrue(next.isOwner)
  }

  func testInstanceLock_ошибкаФайлаНеРазрешаетВторойЗапуск() {
    let url = URL(fileURLWithPath: "/dev/null/instance.lock")
    XCTAssertThrowsError(try AppInstanceLock(url: url))
  }


  func testProductionLaunch_сборкаПередаётЗапускУстановленнойКопии() {
    let installed = URL(fileURLWithPath: "/Users/test/Applications/OwnShot.app")
    let build = URL(fileURLWithPath: "/Users/test/OwnShot/.build/Debug/OwnShot.app")
    XCTAssertEqual(
      AppLaunchPolicy.redirectApplicationURL(bundleURL: build, installedApplicationURL: installed),
      installed
    )
    XCTAssertNil(AppLaunchPolicy.redirectApplicationURL(bundleURL: installed, installedApplicationURL: installed))
  }

  func testCommandLineLaunch_передаётТолькоСсылкиOwnShotИПоддерживаемыеФайлы() {
    let urls = AppLaunchPolicy.commandLineOpenURLs(
      arguments: [
        "Snapzy", "-NSDocumentRevisionsDebugMode", "YES", "/tmp/settings.json",
        "ownshot://capture/area", "/tmp/image.png", "file:///tmp/project.ownshot",
        "https://example.com/image.png", "relative.jpg",
      ],
      currentDirectoryURL: URL(fileURLWithPath: "/tmp/work", isDirectory: true)
    )
    XCTAssertEqual(urls, [
      URL(string: "ownshot://capture/area")!,
      URL(fileURLWithPath: "/tmp/image.png"),
      URL(fileURLWithPath: "/tmp/project.ownshot"),
      URL(fileURLWithPath: "/tmp/work/relative.jpg"),
    ])
  }

}
