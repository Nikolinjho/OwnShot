import Carbon.HIToolbox
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotAllInOneShortcutTests: XCTestCase {
  private let combo = ShortcutConfig(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))

  func testAllInOneНеЗабираетВключённоеСочетаниеАннотации() {
    let annotations = AnnotateShortcutManager.shared
    let original = annotations.copyAndCloseShortcut
    let enabled = annotations.isActionShortcutEnabled(for: .copyAndClose)
    defer {
      annotations.setCopyAndCloseShortcut(original)
      annotations.setActionShortcutEnabled(enabled, for: .copyAndClose)
    }
    annotations.setCopyAndCloseShortcut(combo)
    annotations.setActionShortcutEnabled(true, for: .copyAndClose)
    let defaults = UserDefaultsFactory.make()
    let shortcut = OwnShotAllInOneShortcut(defaults: defaults, registerShortcut: { _ in true })
    let before = defaults.data(forKey: "ownshot.allInOneShortcut")
    XCTAssertFalse(shortcut.update(combo))
    XCTAssertNil(shortcut.shortcut)
    XCTAssertEqual(defaults.data(forKey: "ownshot.allInOneShortcut"), before)
  }

  func testАннотацияНеЗабираетСочетаниеAllInOne() {
    let validator = ShortcutValidationService(allInOneShortcut: { self.combo })
    let original = AnnotateShortcutManager.shared.copyAndCloseShortcut
    guard case .reject(let issue) = validator.validateAnnotateActionShortcut(combo, for: .copyAndClose) else {
      return XCTFail("Сочетание All-In-One должно оставаться зарезервированным")
    }
    XCTAssertEqual(issue.severity, .error)
    XCTAssertTrue(issue.message.contains("All-In-One"))
    XCTAssertEqual(AnnotateShortcutManager.shared.copyAndCloseShortcut, original)
  }

  func testОтключениеИВложеннаяЗаписьОсвобождаютГлобальноеСочетание() {
    let manager = KeyboardShortcutManager.shared
    let enabled = manager.isEnabled
    defer { if enabled { manager.enable() } else { manager.disable() } }
    manager.enable()
    var registrations = 0
    var releases = 0
    let shortcut = OwnShotAllInOneShortcut(defaults: UserDefaultsFactory.make(), registerShortcut: { _ in registrations += 1; return true }, unregisterShortcut: { releases += 1 })
    XCTAssertTrue(shortcut.update(combo))
    XCTAssertTrue(shortcut.isHotkeyRegistered)
    manager.beginTemporaryShortcutSuppression()
    XCTAssertFalse(shortcut.isHotkeyRegistered)
    XCTAssertEqual(releases, 1)
    manager.beginTemporaryShortcutSuppression()
    manager.endTemporaryShortcutSuppression()
    XCTAssertFalse(shortcut.isHotkeyRegistered)
    manager.endTemporaryShortcutSuppression()
    XCTAssertTrue(shortcut.isHotkeyRegistered)
    manager.disable()
    XCTAssertFalse(shortcut.isHotkeyRegistered)
    XCTAssertEqual(releases, 2)
    XCTAssertEqual(registrations, 2)
    XCTAssertEqual(shortcut.shortcut, combo)
  }
  func testСистемныеСочетанияНеСоздаютДубликатыСАннотацией() {
    let annotations = AnnotateShortcutManager.shared
    let original = annotations.copyAndCloseShortcut
    let enabled = annotations.isActionShortcutEnabled(for: .copyAndClose)
    let defaults = UserDefaultsFactory.make()
    let originalConfig = SnapzyConfigurationExporter.exportTOML(defaults: defaults)
    defer {
      _ = SnapzyConfigurationImporter.importTOML(originalConfig, defaults: defaults)
      annotations.setCopyAndCloseShortcut(original)
      annotations.setActionShortcutEnabled(enabled, for: .copyAndClose)
    }
    for reserved in [ShortcutConfig.defaultFullscreen, .defaultArea, .defaultRecording] {
      annotations.setCopyAndCloseShortcut(reserved)
      annotations.setActionShortcutEnabled(true, for: .copyAndClose)
      let before = SnapzyConfigurationExporter.exportTOML(defaults: defaults)
      var assigned = false
      XCTAssertFalse(SystemScreenshotShortcutManager.shared.assignOwnShotDefaults(confirmed: true) { _ in assigned = true; return true })
      XCTAssertFalse(assigned)
      XCTAssertEqual(SnapzyConfigurationExporter.exportTOML(defaults: defaults), before)
    }
  }

  func testОшибкаРегистрацииСистемныхСочетанийСохраняетОтключённыйМастерИНастройки() {
    let manager = KeyboardShortcutManager.shared
    let wasEnabled = manager.isEnabled
    let defaults = UserDefaultsFactory.make()
    let original = SnapzyConfigurationExporter.exportTOML(defaults: defaults)
    manager.disable()
    defer {
      _ = SnapzyConfigurationImporter.importTOML(original, defaults: defaults)
      if wasEnabled { manager.enable() } else { manager.disable() }
    }
    let before = SnapzyConfigurationExporter.exportTOML(defaults: defaults)
    var attempts = 0
    let allInOne = OwnShotAllInOneShortcut(defaults: UserDefaultsFactory.make(), registerShortcut: { _ in attempts += 1; return false })
    XCTAssertFalse(SystemScreenshotShortcutManager.shared.assignOwnShotDefaults(confirmed: true) { allInOne.update($0) })
    XCTAssertEqual(attempts, 1)
    XCTAssertFalse(manager.isEnabled)
    XCTAssertNil(allInOne.shortcut)
    XCTAssertEqual(SnapzyConfigurationExporter.exportTOML(defaults: defaults), before)
  }

}
