import Carbon.HIToolbox
import XCTest
@testable import Snapzy

final class OwnShotShortcutsParityTests: XCTestCase {
  @MainActor
  func testНовыеКомандыСохраняютсяИмпортируютсяИОчищаются() throws {
    let manager = KeyboardShortcutManager.shared
    let entries = [("toggleDesktopIcons", "toggle_desktop_icons"), ("restoreLastCapture", "restore_last_capture"), ("areaCopy", "area_copy"), ("areaSave", "area_save"), ("areaPin", "area_pin")]
    for (raw, key) in entries {
      let kind = try XCTUnwrap(GlobalShortcutKind(rawValue: raw), "Нет команды \(raw)")
      let original = manager.shortcut(for: kind)
      let enabled = manager.isShortcutEnabled(for: kind)
      addTeardownBlock { @MainActor in
        let source = "[shortcuts.global.\(key)]\nkey = \"\(original.map { SnapzyConfigurationShortcutCodec.exportKey($0) } ?? "")\"\nmodifiers = [\(original.map { SnapzyConfigurationShortcutCodec.exportModifiers($0).map { "\"\($0)\"" }.joined(separator: ",") } ?? "")]\nenabled = \(enabled)"
        _ = SnapzyConfigurationImporter.importTOML(source, defaults: UserDefaultsFactory.make())
      }
      let source = "[shortcuts.global.\(key)]\nkey = \"J\"\nmodifiers = [\"command\", \"option\"]\nenabled = false"
      let result = SnapzyConfigurationImporter.importTOML(source, defaults: UserDefaultsFactory.make())
      XCTAssertFalse(result.hasErrors)
      XCTAssertEqual(manager.shortcut(for: kind), ShortcutConfig(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey)))
      XCTAssertFalse(manager.isShortcutEnabled(for: kind))
      let document = try SimpleTOMLParser.parse(SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make()))
      XCTAssertEqual(document.value(at: "shortcuts", "global", key, "key")?.stringValue, "J")
      _ = SnapzyConfigurationImporter.importTOML("[shortcuts.global.\(key)]\nkey = \"\"", defaults: UserDefaultsFactory.make())
      XCTAssertNil(manager.shortcut(for: kind))
      let defaults = try SimpleTOMLParser.parse(SnapzyConfigurationDefaultDocument.toml())
      XCTAssertEqual(defaults.value(at: "shortcuts", "global", key, "key")?.stringValue, "")
    }
  }
  @MainActor
  func testОтменаСистемныхСочетанийНичегоНеМеняет() {
    let before = SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make())
    var invoked = false
    XCTAssertFalse(SystemScreenshotShortcutManager.shared.assignOwnShotDefaults(confirmed: false) { _ in invoked = true; return true })
    XCTAssertFalse(invoked)
    XCTAssertEqual(SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make()), before)
  }

  @MainActor
  func testСистемныеСочетанияНазначаютТриЧетыреИПятьПравильнымКомандам() {
    let manager = KeyboardShortcutManager.shared
    let original = SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make())
    let wasEnabled = manager.isEnabled
    manager.disable()
    defer {
      _ = SnapzyConfigurationImporter.importTOML(original, defaults: UserDefaultsFactory.make())
      if wasEnabled { manager.enable() }
    }
    var allInOne: ShortcutConfig?
    XCTAssertTrue(SystemScreenshotShortcutManager.shared.assignOwnShotDefaults(confirmed: true) { allInOne = $0; return true })
    XCTAssertEqual(manager.shortcut(for: .fullscreen), .defaultFullscreen)
    XCTAssertEqual(manager.shortcut(for: .area), .defaultArea)
    XCTAssertEqual(allInOne, .defaultRecording)
    XCTAssertNil(manager.shortcut(for: .recording))
    XCTAssertTrue(manager.isShortcutEnabled(for: .fullscreen))
    XCTAssertTrue(manager.isShortcutEnabled(for: .area))
  }

  func testПоискСопоставляетСловаБезУчётаРегистраИПробелов() {
    XCTAssertTrue(OwnShotShortcutSearch.matches("  AREA  copy ", title: "Capture Area & Copy"))
    XCTAssertFalse(OwnShotShortcutSearch.matches("pin", title: "Capture Area & Copy"))
    XCTAssertTrue(OwnShotShortcutSearch.matches("", title: "Capture Area & Copy"))
  }

}
