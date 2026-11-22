import XCTest
@testable import Snapzy

final class OwnShotCaptureInteractionTests: XCTestCase {
  @MainActor
  func testЗапросЗакрепленияПринадлежитОдномуФайлуИПотребляетсяОдинРаз() {
    let store = OwnShotScreenshotCaptureMetadata()
    let url = URL(fileURLWithPath: "/tmp/ownshot-pin-test.png")
    store.register(url: url, bypassesDefaultPreset: true, pinsToScreen: true)
    XCTAssertTrue(store.consumePin(for: url))
    XCTAssertFalse(store.consumePin(for: url))
    XCTAssertTrue(store.consumeBypass(for: url))
    XCTAssertFalse(store.consumeBypass(for: url))
    XCTAssertTrue(CaptureContext.empty.requestingPin(true).withoutNamePrompt().pinsToScreen)
    XCTAssertFalse(CaptureContext.empty.requestingPin(true).requestingPin(false).pinsToScreen)
  }

  @MainActor
  func testScreenshotMetadataReregisterClearsOldSourceAndKeepsNewFlags() {
    let metadata = OwnShotScreenshotCaptureMetadata()
    let url = URL(fileURLWithPath: "/tmp/ownshot-reregister-test.png")
    metadata.register(
      url: url, bypassesDefaultPreset: true, pinsToScreen: true, sourceAppBundleID: "com.apple.finder"
    )
    metadata.register(url: url, bypassesDefaultPreset: false, copiesToClipboard: true)
    XCTAssertNil(metadata.consumeSourceAppBundleID(for: url))
    XCTAssertFalse(metadata.consumeBypass(for: url))
    XCTAssertFalse(metadata.consumePin(for: url))
    XCTAssertTrue(metadata.consumeClipboardCopy(for: url))
    XCTAssertFalse(metadata.consumeClipboardCopy(for: url))

    metadata.register(
      url: url, bypassesDefaultPreset: true, pinsToScreen: true,
      copiesToClipboard: true, sourceAppBundleID: "com.apple.Safari"
    )
    XCTAssertEqual(metadata.consumeSourceAppBundleID(for: url), "com.apple.Safari")
    XCTAssertNil(metadata.consumeSourceAppBundleID(for: url))
    XCTAssertTrue(metadata.consumeBypass(for: url))
    XCTAssertTrue(metadata.consumePin(for: url))
    XCTAssertTrue(metadata.consumeClipboardCopy(for: url))
  }

  @MainActor
  func testПереименованиеRetinaСохраняетВключённыйСуффикс() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(true, forKey: OwnShotAdvancedPreferenceKeys.askForName)
    XCTAssertEqual(OwnShotCaptureNamePrompt.resolve(suggested: "original@2x", scaleFactor: 2,
      defaults: defaults, prompt: { _ in "Example.png" }), "Example@2x")
    XCTAssertEqual(OwnShotCaptureNamePrompt.resolve(suggested: "original", scaleFactor: 1,
      defaults: defaults, prompt: { _ in "Example.png" }), "Example")
    defaults.set(false, forKey: OwnShotAdvancedPreferenceKeys.addRetinaSuffix)
    XCTAssertEqual(OwnShotCaptureNamePrompt.resolve(suggested: "original", scaleFactor: 2,
      defaults: defaults, prompt: { _ in "Example.png" }), "Example")
  }

  @MainActor
  func testShiftПривязанККонкретномуФайлуИПотребляетсяОдинРаз() {
    let store = OwnShotScreenshotCaptureMetadata()
    let first = URL(fileURLWithPath: "/tmp/first.png")
    let second = URL(fileURLWithPath: "/tmp/second.png")
    store.register(url: first, bypassesDefaultPreset: true)
    store.register(url: second, bypassesDefaultPreset: false)
    XCTAssertTrue(store.consumeBypass(for: first))
    XCTAssertFalse(store.consumeBypass(for: first))
    XCTAssertFalse(store.consumeBypass(for: second))
  }

  @MainActor
  func testИмяСпрашиваетсяТолькоПриВключённойНастройкеИИнтерактивномЗахвате() {
    let name = "OwnShotCaptureInteractionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    var prompts = 0
    let prompt: (String) -> String? = { _ in prompts += 1; return "User name.png" }
    XCTAssertEqual(OwnShotCaptureNamePrompt.resolve(suggested: "original", defaults: defaults, prompt: prompt), "original")
    defaults.set(true, forKey: OwnShotAdvancedPreferenceKeys.askForName)
    XCTAssertEqual(OwnShotCaptureNamePrompt.resolve(suggested: "original", isInteractive: false, defaults: defaults, prompt: prompt), "original")
    XCTAssertEqual(prompts, 0)
    XCTAssertEqual(OwnShotCaptureNamePrompt.resolve(suggested: "original", defaults: defaults, prompt: prompt), "User name")
    XCTAssertEqual(prompts, 1)
    XCTAssertNil(OwnShotCaptureNamePrompt.resolve(suggested: "original", defaults: defaults, prompt: { _ in nil }))
  }
}
