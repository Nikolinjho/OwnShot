import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

final class OwnShotExtraShortcutCommandsTests: XCTestCase {
  // MARK: - Глобальные extra-команды

  @MainActor
  func testExtraКомандыИмпортируютсяЭкспортируютсяИОчищаются() throws {
    let manager = KeyboardShortcutManager.shared
    let original = SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make())
    let wasEnabled = manager.isEnabled
    manager.disable()
    addTeardownBlock { @MainActor in
      _ = SnapzyConfigurationImporter.importTOML(original, defaults: UserDefaultsFactory.make())
      if wasEnabled { manager.enable() }
    }

    for kind in GlobalShortcutKind.extraKinds {
      let key = kind.configKey
      let source = "[shortcuts.global.\(key)]\nkey = \"J\"\nmodifiers = [\"command\", \"option\", \"shift\"]"
      let result = SnapzyConfigurationImporter.importTOML(source, defaults: UserDefaultsFactory.make())
      XCTAssertFalse(result.hasErrors, "Ошибка импорта \(key)")
      XCTAssertEqual(
        manager.shortcut(for: kind),
        ShortcutConfig(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey | shiftKey)),
        "Сочетание не применилось для \(key)"
      )

      let exported = try SimpleTOMLParser.parse(SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make()))
      XCTAssertEqual(exported.value(at: "shortcuts", "global", key, "key")?.stringValue, "J", "Нет экспорта \(key)")

      _ = SnapzyConfigurationImporter.importTOML("[shortcuts.global.\(key)]\nkey = \"\"", defaults: UserDefaultsFactory.make())
      XCTAssertNil(manager.shortcut(for: kind), "Сочетание не очистилось для \(key)")
    }
  }

  func testExtraКомандыПоУмолчаниюНеНазначены() throws {
    let defaults = try SimpleTOMLParser.parse(SnapzyConfigurationDefaultDocument.toml())
    for kind in GlobalShortcutKind.extraKinds {
      XCTAssertEqual(defaults.value(at: "shortcuts", "global", kind.configKey, "key")?.stringValue, "", kind.configKey)
    }
  }

  func testКлючиExtraКомандУникальны() {
    let keys = GlobalShortcutKind.extraKinds.map(\.configKey)
    XCTAssertEqual(Set(keys).count, keys.count)
    XCTAssertTrue(GlobalShortcutKind.extraKinds.allSatisfy(\.isExtraKind))
    XCTAssertFalse(GlobalShortcutKind.area.isExtraKind)
  }

  @MainActor
  func testOpenFileПанельПринимаетПроектыИзображенияИВидео() {
    let panel = OwnShotShortcutCommands.makeOpenFilePanel()

    XCTAssertTrue(panel.allowedContentTypes.contains(OwnShotProjectFormat.contentType), "Open File должен принимать проекты OwnShot")
    XCTAssertTrue(panel.allowedContentTypes.contains(.image))
    XCTAssertTrue(panel.allowedContentTypes.contains(.movie))
    XCTAssertFalse(panel.allowedContentTypes.contains(.plainText))
  }

  // MARK: - Действия редактора

  func testДефолтыДействийРедактора() {
    let command = UInt32(cmdKey)
    let commandShift = UInt32(cmdKey | shiftKey)
    let expected: [AnnotateActionShortcutKind: ShortcutConfig] = [
      .copyObject: ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: command),
      .duplicateObject: ShortcutConfig(keyCode: UInt32(kVK_ANSI_D), modifiers: command),
      .save: ShortcutConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: command),
      .saveAs: ShortcutConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: commandShift),
      .print: ShortcutConfig(keyCode: UInt32(kVK_ANSI_P), modifiers: command),
      .addNewScreenshot: ShortcutConfig(keyCode: UInt32(kVK_ANSI_I), modifiers: commandShift),
      .addScreenshotFromFile: ShortcutConfig(keyCode: UInt32(kVK_ANSI_I), modifiers: command),
      .increaseToolSize: ShortcutConfig(keyCode: UInt32(kVK_ANSI_Equal), modifiers: 0),
      .decreaseToolSize: ShortcutConfig(keyCode: UInt32(kVK_ANSI_Minus), modifiers: 0),
    ]
    for (kind, config) in expected {
      XCTAssertEqual(AnnotateShortcutManager.defaultShortcut(for: kind), config, kind.rawValue)
    }
  }

  @MainActor
  func testДействияРедактораЭкспортируютсяИИмпортируются() throws {
    let original = SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make())
    addTeardownBlock { @MainActor in
      _ = SnapzyConfigurationImporter.importTOML(original, defaults: UserDefaultsFactory.make())
    }
    let manager = AnnotateShortcutManager.shared
    let exported = try SimpleTOMLParser.parse(original)
    for kind in AnnotateActionShortcutKind.allCases {
      XCTAssertNotNil(
        exported.value(at: "shortcuts", "annotate_actions", kind.configKey, "enabled"),
        "Нет секции \(kind.configKey)"
      )
    }

    let source = "[shortcuts.annotate_actions.print]\nkey = \"P\"\nmodifiers = [\"command\", \"option\"]"
    let result = SnapzyConfigurationImporter.importTOML(source, defaults: UserDefaultsFactory.make())
    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(manager.shortcut(for: .print), ShortcutConfig(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)))

    let roundTrip = try SimpleTOMLParser.parse(SnapzyConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make()))
    XCTAssertEqual(roundTrip.value(at: "shortcuts", "annotate_actions", "increase_tool_size", "key")?.stringValue, "=")
    XCTAssertEqual(roundTrip.value(at: "shortcuts", "annotate_actions", "decrease_tool_size", "key")?.stringValue, "-")
  }

  // MARK: - Запуск записи

  func testRecordingStartВыбираетРежимПоКлавише() {
    let previous = RecordingStartShortcutSettings.defaults
    let suite = "OwnShotExtraShortcutCommandsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    RecordingStartShortcutSettings.defaults = defaults
    defer {
      RecordingStartShortcutSettings.defaults = previous
      defaults.removePersistentDomain(forName: suite)
    }

    let returnKey = UInt16(kVK_Return)
    XCTAssertEqual(RecordingStartShortcutSettings.outputMode(keyCode: returnKey, modifiers: []), .video)
    XCTAssertEqual(RecordingStartShortcutSettings.outputMode(keyCode: returnKey, modifiers: .option), .gif)
    XCTAssertEqual(RecordingStartShortcutSettings.outputMode(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: []), .video)
    XCTAssertNil(RecordingStartShortcutSettings.outputMode(keyCode: returnKey, modifiers: .command))

    RecordingStartShortcutSettings.setShortcut(nil, for: .gif)
    XCTAssertNil(RecordingStartShortcutSettings.shortcut(for: .gif))
    XCTAssertNil(RecordingStartShortcutSettings.outputMode(keyCode: returnKey, modifiers: .option))

    let custom = ShortcutConfig(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey))
    RecordingStartShortcutSettings.setShortcut(custom, for: .gif)
    XCTAssertEqual(RecordingStartShortcutSettings.outputMode(keyCode: UInt16(kVK_ANSI_G), modifiers: .command), .gif)

    RecordingStartShortcutSettings.reset(.gif)
    XCTAssertEqual(RecordingStartShortcutSettings.shortcut(for: .gif), RecordingStartShortcutKind.gif.defaultShortcut)
  }
}
