import AppKit
import Carbon.HIToolbox
import GRDB
import XCTest
@testable import Snapzy

/// Страница Shortcuts: группы эталона, запись и отмена сочетания, тексты конфликтов,
/// Start/Stop Capturing для Scrolling Capture.
@MainActor
final class OwnShotShortcutsParity060Tests: XCTestCase {
  private let combo = ShortcutConfig(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))

  // MARK: - Группы страницы

  func testГруппыИдутВПорядкеЭталона() {
    let titles = ShortcutsPage.allCases.prefix(9).map(\.title)
    XCTAssertEqual(titles, [
      "General", "Screenshots", "Screen Recording", "Scrolling Capture", "OCR",
      "Quick Access Overlay", "Pin", "Annotate", "Annotate tools",
    ])
  }

  func testСтрокиГруппСовпадаютСЭталоном() {
    XCTAssertEqual(ShortcutsGroup.general.rowTitles, [
      "All-In-One", "Toggle Desktop Icons", "Open Capture History", "Restore Last Capture",
    ])
    XCTAssertEqual(ShortcutsGroup.screenshots.rowTitles, [
      "Capture Area", "Capture Previous Area", "Capture Fullscreen", "Capture Window", "Self-Timer",
    ])
    XCTAssertEqual(ShortcutsGroup.screenshotActions.rowTitles, [
      "Capture Area & Copy to Clipboard", "Capture Area & Save", "Capture Area & Upload to Cloud",
      "Capture Area & Annotate", "Capture Area & Pin to the Screen",
    ])
    XCTAssertEqual(ShortcutsGroup.screenRecording.rowTitles, [
      "Record Screen / Stop Recording", "Select Window", "Start Video Recording", "Start GIF Recording",
      "Pause/Resume Recording", "Restart Recording", "Toggle Camera Fullscreen",
    ])
    XCTAssertEqual(ShortcutsGroup.scrollingCapture.rowTitles, ["Scrolling Capture", "Start/Stop Capturing"])
    XCTAssertEqual(ShortcutsGroup.ocr.rowTitles, [
      "Capture Text", "Capture Text With Line Breaks", "Capture Text Without Line Breaks",
    ])
    XCTAssertEqual(ShortcutsGroup.quickAccessOverlay.rowTitles, [
      "Hide/Show Overlays", "Save All Overlays", "Close All Overlays",
    ])
    XCTAssertEqual(ShortcutsGroup.pin.rowTitles, [
      "Choose and Pin an Image", "Toggle Pins Visibility", "Close All Pins", "Pin Last Screenshot",
    ])
    XCTAssertEqual(ShortcutsGroup.annotate.rowTitles, [
      "Open File", "Open From Clipboard", "Annotate Last Screenshot", "Copy Object to Clipboard",
      "Duplicate Object", "Save", "Save as", "Copy Screenshot to Clipboard", "Upload to Cloud", "Print",
      "Pin to the Screen", "Add New Screenshot", "Add Screenshot From File",
    ])
    XCTAssertEqual(Array(ShortcutsGroup.annotateTools.rowTitles.prefix(16)), [
      "Increase Tool Size", "Decrease Tool Size", "Background Tool", "Move Tool", "Crop & Resize Tool",
      "Draw Tool", "Highlighter Tool", "Line Tool", "Text Tool", "Arrow Tool", "Counter Tool",
      "Ellipse Tool", "Redaction Tool", "Spotlight Tool", "Rectangle Tool", "Filled Rectangle Tool",
    ])
  }

  func testКаждаяГруппаВходитВОднуСтраницу() {
    let grouped = ShortcutsPage.allCases.flatMap { ShortcutsPage.groups(for: $0) }
    XCTAssertEqual(grouped.count, Set(grouped).count)
    XCTAssertEqual(Set(grouped), Set(ShortcutsGroup.allCases))
  }

  func testВсеНастраиваемыеИнструментыОстаютсяНаСтранице() {
    XCTAssertEqual(Set(ShortcutsGroup.orderedTools), Set(AnnotateShortcutManager.configurableTools))
  }

  func testПоследнийСнимокНаходитсяЗаСвежимиЗаписямиВидео() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try DatabaseManager.openDatabase(at: root.appendingPathComponent("history.sqlite"))
    defer { XCTAssertNoThrow(try database.dbPool.close()) }
    let history = CaptureHistoryStore(databasePool: database.dbPool)
    let defaults = UserDefaultsFactory.make()
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    history.userDefaults = defaults

    func addCapture(_ name: String, type: CaptureHistoryType, time: TimeInterval,
                    exists: Bool = true, deleted: Bool = false) throws -> URL {
      let url = root.appendingPathComponent(name)
      if exists { try Data([1]).write(to: url) }
      history.add(CaptureHistoryRecord(
        id: UUID(), filePath: url.path, fileName: name, captureType: type,
        fileSize: 1, capturedAt: Date(timeIntervalSinceReferenceDate: time), isDeleted: deleted
      ))
      return url
    }

    _ = try addCapture("older.png", type: .screenshot, time: 1)
    let expected = try addCapture("last.png", type: .screenshot, time: 2)
    _ = try addCapture("deleted.png", type: .screenshot, time: 3, deleted: true)
    _ = try addCapture("missing.png", type: .screenshot, time: 4, exists: false)
    for number in 5...25 {
      _ = try addCapture("recording-\(number).mov", type: .video, time: TimeInterval(number))
    }
    history.refreshRecords()
    XCTAssertEqual(history.records.count, 25)
    XCTAssertEqual(OwnShotShortcutCommands.latestScreenshotURL(in: history), expected)
  }

  // MARK: - Запись и отмена

  func testEscapeОтменяетЗапись() {
    XCTAssertEqual(ShortcutRecordingRules.decision(keyCode: UInt16(kVK_Escape), modifiers: [], allowsSingleKey: false), .cancel)
    XCTAssertEqual(ShortcutRecordingRules.decision(keyCode: UInt16(kVK_Escape), modifiers: [], allowsSingleKey: true), .cancel)
  }

  func testDeleteОчищаетСочетание() {
    XCTAssertEqual(ShortcutRecordingRules.decision(keyCode: UInt16(kVK_Delete), modifiers: [], allowsSingleKey: false), .clear)
    XCTAssertEqual(ShortcutRecordingRules.decision(keyCode: UInt16(kVK_ForwardDelete), modifiers: [], allowsSingleKey: true), .clear)
  }

  func testСочетаниеСМодификаторомЗаписывается() {
    XCTAssertEqual(
      ShortcutRecordingRules.decision(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .shift, .capsLock], allowsSingleKey: false),
      .record(ShortcutConfig(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey)))
    )
    XCTAssertEqual(
      ShortcutRecordingRules.decision(keyCode: UInt16(kVK_Delete), modifiers: [.command], allowsSingleKey: false),
      .record(ShortcutConfig(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey)))
    )
  }

  func testКлавишаБезМодификатораЖдётИлиЗаписываетсяПоРежиму() {
    XCTAssertEqual(ShortcutRecordingRules.decision(keyCode: UInt16(kVK_ANSI_A), modifiers: [], allowsSingleKey: false), .ignore)
    XCTAssertEqual(
      ShortcutRecordingRules.decision(keyCode: UInt16(kVK_Return), modifiers: [], allowsSingleKey: true),
      .record(ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: 0))
    )
  }

  func testКликМимоПоляОтменяетЗапись() {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 30)
    XCTAssertFalse(ShortcutRecordingRules.shouldCancelOnClick(at: CGPoint(x: 100, y: 15), recorderFrame: frame))
    XCTAssertTrue(ShortcutRecordingRules.shouldCancelOnClick(at: CGPoint(x: 260, y: 15), recorderFrame: frame))
    XCTAssertTrue(ShortcutRecordingRules.shouldCancelOnClick(at: CGPoint(x: 10, y: 10), recorderFrame: .zero))
  }

  func testУдерживаемыеМодификаторыВПорядкеMacOS() {
    XCTAssertEqual(ShortcutRecordingRules.heldModifierSymbols([.command, .shift]), "⇧⌘")
    XCTAssertEqual(ShortcutRecordingRules.heldModifierSymbols([.control, .option, .capsLock]), "⌃⌥")
    XCTAssertEqual(ShortcutRecordingRules.heldModifierSymbols([]), "")
  }

  func testКонтроллерЗаписиОстанавливаетсяИСнимаетПриостановку() {
    let manager = KeyboardShortcutManager.shared
    let wasSuspended = manager.isTemporarilySuspended
    let controller = ShortcutRecordingController()
    controller.start { _ in }
    XCTAssertTrue(controller.isRecording)
    XCTAssertTrue(manager.isTemporarilySuspended)
    controller.stop()
    XCTAssertFalse(controller.isRecording)
    XCTAssertEqual(manager.isTemporarilySuspended, wasSuspended)
    // Повторная остановка ничего не ломает.
    controller.stop()
    XCTAssertEqual(manager.isTemporarilySuspended, wasSuspended)
  }

  // MARK: - Конфликты

  func testДубликатПоказываетТекстЭталона() {
    let validator = ShortcutValidationService(allInOneShortcut: { self.combo }, isReservedBySystem: { _ in false })
    guard case .reject(let issue) = validator.validateAnnotateActionShortcut(combo, for: .copyAndClose) else {
      return XCTFail("Сочетание All-In-One должно отклоняться")
    }
    XCTAssertEqual(issue.title, "Shortcut is used for another action")
    // Буква зависит от раскладки, поэтому берётся из самого сочетания.
    XCTAssertEqual(issue.message, "\(combo.menuSymbolString) is assigned to \"All-In-One\".")
    XCTAssertTrue(combo.menuSymbolString.hasPrefix("⌃⌥⇧⌘"))
  }

  func testСистемноеСочетаниеMacOSНеНазначается() {
    let reserved = ShortcutConfig(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
    let validator = ShortcutValidationService(allInOneShortcut: { nil }, isReservedBySystem: { $0 == reserved })
    guard case .reject(let issue) = validator.validateGlobalShortcut(reserved, for: .toggleDesktopIcons) else {
      return XCTFail("Сочетание macOS должно отклоняться")
    }
    XCTAssertEqual(issue.title, "Shortcut is reserved for macOS")
    XCTAssertEqual(issue.message, "⌃⌥⇧⌘␣ is used by macOS and cannot be assigned.")
    guard case .reject = validator.validateRecordedAllInOneShortcut(reserved) else {
      return XCTFail("Строка All-In-One тоже не берёт сочетание macOS")
    }
    // Use System Default Shortcuts назначает All-In-One в обход запрета.
    guard case .accept = validator.validateAllInOneShortcut(reserved) else {
      return XCTFail("Программное назначение All-In-One не блокируется")
    }
  }

  func testДефолтOwnShotСовпадающийСMacOSПринимаетсяСПредупреждением() {
    guard case .accept(let issue) = ShortcutValidationService.systemReservedDecision(.defaultArea, isDefault: true) else {
      return XCTFail("Сброс к дефолту должен оставаться доступным")
    }
    XCTAssertEqual(issue?.severity, .warning)
    XCTAssertEqual(issue?.title, "Shortcut is reserved for macOS")
    guard case .reject = ShortcutValidationService.systemReservedDecision(.defaultArea, isDefault: false) else {
      return XCTFail("Новое сочетание macOS отклоняется")
    }
    XCTAssertEqual(ShortcutValidationService.defaultGlobalShortcut(for: .area), .defaultArea)
    XCTAssertNil(ShortcutValidationService.defaultGlobalShortcut(for: .toggleDesktopIcons))
  }

  func testВключённыеСочетанияMacOSЧитаютсяИзSymbolicHotKeys() {
    let hotkeys: [String: Any] = [
      // ⌃Space — Select the previous input source, включено.
      "60": ["enabled": true, "value": ["parameters": [32, 49, 262144], "type": "standard"]],
      // Выключенное сочетание не считается занятым.
      "61": ["enabled": false, "value": ["parameters": [32, 49, 786432], "type": "standard"]],
      // Запись без клавиши пропускается.
      "79": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]],
    ]
    let configs = SystemScreenshotShortcutManager.enabledSystemShortcuts(in: hotkeys)
    XCTAssertEqual(configs, [ShortcutConfig(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))])
  }

  func testСочетаниеВТекстеВПорядкеМенюMacOS() {
    XCTAssertEqual(ShortcutConfig(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)).menuSymbolString, "⇧⌘␣")
  }

  // MARK: - Start/Stop Capturing

  func testStartStopПоУмолчаниюReturnИСохраняется() {
    let original = ScrollingCaptureShortcutSettings.defaults
    let defaults = UserDefaultsFactory.make()
    ScrollingCaptureShortcutSettings.defaults = defaults
    defer { ScrollingCaptureShortcutSettings.defaults = original }

    XCTAssertEqual(ScrollingCaptureShortcutSettings.startStopShortcut, ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: 0))
    XCTAssertTrue(ScrollingCaptureShortcutSettings.matchesStartStop(keyCode: UInt16(kVK_Return), modifiers: []))
    XCTAssertTrue(ScrollingCaptureShortcutSettings.matchesStartStop(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: []))
    XCTAssertFalse(ScrollingCaptureShortcutSettings.matchesStartStop(keyCode: UInt16(kVK_Return), modifiers: [.option]))

    let custom = ShortcutConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
    ScrollingCaptureShortcutSettings.setStartStopShortcut(custom)
    XCTAssertEqual(ScrollingCaptureShortcutSettings.startStopShortcut, custom)
    XCTAssertFalse(ScrollingCaptureShortcutSettings.matchesStartStop(keyCode: UInt16(kVK_Return), modifiers: []))

    ScrollingCaptureShortcutSettings.setStartStopShortcut(nil)
    XCTAssertNil(ScrollingCaptureShortcutSettings.startStopShortcut)

    ScrollingCaptureShortcutSettings.reset()
    XCTAssertEqual(ScrollingCaptureShortcutSettings.startStopShortcut, ScrollingCaptureShortcutSettings.defaultStartStopShortcut)
  }

  func testStartStopРегистрируетсяГлобальноНаВремяСессии() {
    var registered: [(UInt32, UInt32, UInt32)] = []
    var released: [UInt32] = []
    let hotKey = ScrollingCaptureSessionHotKey(
      shortcutProvider: { ScrollingCaptureShortcutSettings.defaultStartStopShortcut },
      register: { keyCode, modifiers, id in registered.append((keyCode, modifiers, id)); return true },
      unregister: { released.append($0) }
    )
    var triggers = 0
    XCTAssertTrue(hotKey.activate { triggers += 1 })
    XCTAssertTrue(hotKey.isActive)
    // Return и Enter цифрового блока.
    XCTAssertEqual(registered.map(\.0), [UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter)])
    hotKey.handleHotKey(id: registered[1].2)
    XCTAssertEqual(triggers, 1)

    hotKey.deactivate()
    XCTAssertFalse(hotKey.isActive)
    XCTAssertEqual(Set(released), Set(registered.map(\.2)))
    hotKey.handleHotKey(id: registered[0].2)
    XCTAssertEqual(triggers, 1, "После сессии клавиша свободна")
  }

  func testЗапоздалыйStartStopОтПредыдущегоСеансаНеЗапускаетНовый() {
    var registeredIDs: [UInt32] = []
    var newSessionTriggers = 0
    let hotKey = ScrollingCaptureSessionHotKey(
      shortcutProvider: { ScrollingCaptureShortcutSettings.defaultStartStopShortcut },
      register: { _, _, id in
        registeredIDs.append(id)
        return true
      },
      unregister: { _ in }
    )
    XCTAssertTrue(hotKey.activate {})
    let obsoleteIDs = registeredIDs
    registeredIDs.removeAll()
    hotKey.deactivate()

    XCTAssertTrue(hotKey.activate { newSessionTriggers += 1 })
    for id in obsoleteIDs { hotKey.handleHotKey(id: id) }
    XCTAssertEqual(newSessionTriggers, 0)

    for id in registeredIDs { hotKey.handleHotKey(id: id) }
    XCTAssertEqual(newSessionTriggers, registeredIDs.count)
    XCTAssertFalse(registeredIDs.isEmpty)
  }

  func testStartStopБезСочетанияИлиСFnНеРегистрируется() {
    var attempts = 0
    let cleared = ScrollingCaptureSessionHotKey(shortcutProvider: { nil }, register: { _, _, _ in attempts += 1; return true }, unregister: { _ in })
    XCTAssertFalse(cleared.activate {})
    let fn = ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: ShortcutConfig.functionCarbonModifier)
    let withFn = ScrollingCaptureSessionHotKey(shortcutProvider: { fn }, register: { _, _, _ in attempts += 1; return true }, unregister: { _ in })
    XCTAssertFalse(withFn.activate {})
    XCTAssertEqual(attempts, 0)
  }
}
