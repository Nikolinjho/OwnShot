import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Snapzy

@MainActor
final class VideoEditorShortcutSettingsTests: XCTestCase {
  func testДефолтыВидеоредактораСовпадаютСЭталоном() throws {
    try withSettings { settings, _ in
      XCTAssertEqual(
        VideoEditorShortcutAction.allCases.compactMap { settings.shortcut(for: $0)?.menuSymbolString },
        ["V", "B", "⌘B", "⇧⌘B", "⇧⌘A", "⌘=", "⌘-", "⇧Z", "⌘F", "⌘E", "⌘U", "⇧⌘E",
         "←", "→", "⇧←", "⇧→", "⌥←", "⌥→", "⌘←", "⌘→"]
      )
      XCTAssertEqual(settings.activeShortcuts.count, 19)
    }
  }

  func testОчищениеИПереназначениеСохраняютсяДоСброса() throws {
    try withSettings { settings, defaults in
      XCTAssertTrue(settings.setShortcut(nil, for: .splitClip))
      let shortcut = ShortcutConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
      XCTAssertTrue(settings.setShortcut(shortcut, for: .exportVideo))
      let reopened = VideoEditorShortcutSettings(defaults: defaults)
      XCTAssertNil(reopened.shortcut(for: .splitClip))
      XCTAssertEqual(reopened.shortcut(for: .exportVideo), shortcut)
      reopened.resetToDefaults()
      let restored = VideoEditorShortcutSettings(defaults: defaults)
      XCTAssertEqual(restored.shortcut(for: .splitClip), VideoEditorShortcutAction.splitClip.defaultShortcut)
      XCTAssertEqual(restored.shortcut(for: .exportVideo), VideoEditorShortcutAction.exportVideo.defaultShortcut)
    }
  }

  func testДубликатыИКлавишиПостоянныхДействийОтклоняются() throws {
    try withSettings { settings, _ in
      let other = VideoEditorShortcutAction.splitClip.defaultShortcut
      let space = ShortcutConfig(keyCode: UInt32(kVK_Space), modifiers: 0)
      let tab = ShortcutConfig(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
      XCTAssertFalse(settings.setShortcut(other, for: .exportVideo))
      XCTAssertFalse(settings.setShortcut(space, for: .exportVideo))
      XCTAssertFalse(settings.setShortcut(tab, for: .exportVideo))
      XCTAssertEqual(settings.shortcut(for: .exportVideo), VideoEditorShortcutAction.exportVideo.defaultShortcut)
    }
  }

  func testСтрелкиУчитываютМодификаторыИФункциональныеФлаги() throws {
    try withSettings { settings, _ in
      let left = try keyDown(kVK_LeftArrow, [.numericPad, .function])
      let previousClip = try keyDown(kVK_LeftArrow, [.option, .numericPad, .function])
      let unrelated = try keyDown(kVK_LeftArrow, [.control, .numericPad, .function])
      let cloud = try keyDown(kVK_ANSI_U, [.command])
      XCTAssertEqual(settings.action(for: left), .previousFrame)
      XCTAssertEqual(settings.action(for: previousClip), .previousClipEdge)
      XCTAssertNil(settings.action(for: unrelated))
      XCTAssertNil(settings.action(for: cloud))
    }
  }

  func testКонфигурацияПозволяетПоменятьНазначенияМестамиЗаОдинИмпорт() throws {
    try withSettings { _, defaults in
      let result = SnapzyConfigurationImporter.importTOML(
        """
        [shortcuts.video_editor.split_clip]
        key = "E"
        modifiers = ["command"]

        [shortcuts.video_editor.export_video]
        key = "B"
        modifiers = ["command"]

        [shortcuts.video_editor.next_frame]
        key = ""
        modifiers = []
        """,
        defaults: defaults
      )
      XCTAssertFalse(result.hasErrors)
      let restored = VideoEditorShortcutSettings(defaults: defaults)
      XCTAssertEqual(restored.shortcut(for: .splitClip), VideoEditorShortcutAction.exportVideo.defaultShortcut)
      XCTAssertEqual(restored.shortcut(for: .exportVideo), VideoEditorShortcutAction.splitClip.defaultShortcut)
      XCTAssertNil(restored.shortcut(for: .nextFrame))
    }
  }

  func testTOMLСохраняетКодКлавишиЦифровогоБлока() throws {
    try withSettings { settings, defaults in
      let keypad = ShortcutConfig(keyCode: UInt32(kVK_ANSI_Keypad1), modifiers: UInt32(cmdKey))
      XCTAssertTrue(settings.setShortcut(keypad, for: .exportVideo))
      var writer = SimpleTOMLWriter()
      SnapzyConfigurationExporter.writeVideoEditorShortcuts(&writer) { settings.shortcut(for: $0) }
      let source = writer.output
      let document = try SimpleTOMLParser.parse(source)
      XCTAssertEqual(
        document.value(at: ["shortcuts", "video_editor", "export_video", "key_code"]),
        .integer(kVK_ANSI_Keypad1)
      )

      settings.resetToDefaults()
      XCTAssertFalse(SnapzyConfigurationImporter.importTOML(source, defaults: defaults).hasErrors)
      XCTAssertEqual(VideoEditorShortcutSettings(defaults: defaults).shortcut(for: .exportVideo), keypad)
    }
  }

  func testКонфликтВКонфигурацииОтклоняетВесьИмпорт() throws {
    try withSettings { _, defaults in
      let result = SnapzyConfigurationImporter.importTOML(
        """
        [shortcuts.video_editor.split_clip]
        key = "E"
        modifiers = ["command"]

        [shortcuts.video_editor.next_frame]
        key = ""
        """,
        defaults: defaults
      )
      XCTAssertTrue(result.hasErrors)
      XCTAssertEqual(result.appliedChangeCount, 0)
      let restored = VideoEditorShortcutSettings(defaults: defaults)
      XCTAssertNotNil(restored.shortcut(for: .nextFrame))
    }
  }

  func testДокументДефолтовСодержитСтрелкиИСочетанияРедактора() throws {
    let document = try SimpleTOMLParser.parse(SnapzyConfigurationDefaultDocument.toml())
    XCTAssertEqual(document.value(at: ["shortcuts", "video_editor", "split_clip", "key"]), .string("B"))
    XCTAssertEqual(document.value(at: ["shortcuts", "video_editor", "playhead_end", "key"]), .string("→"))
  }

  private func withSettings(
    _ run: (VideoEditorShortcutSettings, UserDefaults) throws -> Void
  ) throws {
    let suite = "VideoEditorShortcutSettingsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try run(VideoEditorShortcutSettings(defaults: defaults), defaults)
  }

  private func keyDown(_ code: Int, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: UInt16(code)
    ))
  }
}
