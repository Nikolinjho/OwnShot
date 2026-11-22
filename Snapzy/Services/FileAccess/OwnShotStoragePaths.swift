import Foundation

/// Keeps app-owned files isolated in XCTest without changing the macOS account seen by frameworks.
nonisolated enum OwnShotStoragePaths {
  static let testRoot: URL? = {
    let isTestHost = Bundle.main.bundleIdentifier == "dev.nikoko.ownshot.test-host"
    let environment = ProcessInfo.processInfo.environment
    #if DEBUG
    let isHostedXCTest = environment["XCTestConfigurationFilePath"] != nil
    #else
    let isHostedXCTest = false
    #endif
    guard isTestHost || isHostedXCTest else { return nil }

    if let path = environment["OWNSHOT_TEST_ROOT"], path.hasPrefix("/") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }

    return FileManager.default.temporaryDirectory
      .appendingPathComponent("OwnShotTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }()

  static var applicationSupportDirectory: URL? {
    if let testRoot {
      return testRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  }

  static var libraryDirectory: URL? {
    if let testRoot {
      return testRoot.appendingPathComponent("Library", isDirectory: true)
    }
    return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
  }

  static var desktopDirectory: URL? {
    if let testRoot {
      return testRoot.appendingPathComponent("Desktop", isDirectory: true)
    }
    return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
  }
}
