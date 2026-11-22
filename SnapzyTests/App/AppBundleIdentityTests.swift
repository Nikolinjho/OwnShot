import Foundation
import XCTest
@testable import Snapzy

@MainActor
final class AppBundleIdentityTests: XCTestCase {
  func testOwnShotCapturePathResolvesUnderTestStorage() {
    let environment = ProcessInfo.processInfo.environment
    let captures = TempCaptureManager.tempCaptureRootDirectory().standardizedFileURL.path
    if let rootPath = environment["OWNSHOT_TEST_ROOT"] {
      let root = URL(fileURLWithPath: rootPath, isDirectory: true)
      XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.nikoko.ownshot.test-host")
      XCTAssertEqual(captures, root.appendingPathComponent(
        "Library/Application Support/OwnShot/Captures"
      ).standardizedFileURL.path)
      XCTAssertNil(environment["CFFIXED_USER_HOME"])
      let accountHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
      XCTAssertFalse((accountHome + "/").hasPrefix(root.standardizedFileURL.path + "/"))
      print("OwnShot test storage root: \(root.path)")
    } else {
      let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShotTests", isDirectory: true)
      XCTAssertTrue(captures.hasPrefix(fallback.standardizedFileURL.path + "/"))
    }
  }

  func testТестовыйХостРазрешёнТолькоВXCTest() {
    XCTAssertFalse(AppBundleIdentity.matches("dev.nikoko.ownshot.test-host"))
    XCTAssertTrue(AppBundleIdentity.matches("dev.nikoko.ownshot.test-host", isRunningUnderXCTest: true))
    XCTAssertFalse(AppBundleIdentity.matches("dev.nikoko.ownshot.other", isRunningUnderXCTest: true))
  }
  func testПринимаетТолькоСвоюИдентичность() async {
    for debug in [true, false] {
      XCTAssertTrue(AppBundleIdentity.matches("dev.nikoko.ownshot", debugBuild: debug))
      for identifier in [nil, "", "com.trongduong.snapzy", "com.trongduong.snapzy.debug", "dev.nikoko.ownshot.other"] as [String?] {
        XCTAssertFalse(AppBundleIdentity.matches(identifier, debugBuild: debug))
      }
    }
  }

  func testСборкаИспользуетСвоюИдентичность() async {
    XCTAssertTrue(AppBundleIdentity.matches(AppBundleIdentity.expected))
  }
}
