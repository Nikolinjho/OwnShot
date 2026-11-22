import AppKit
import SwiftUI
import Testing
@testable import Snapzy

@MainActor
@Suite(.serialized)
struct AnnotateWindowLifecycleParityTests {
  @Test("Always on top фиксируется при создании каждого редактора", arguments: [false, true])
  func editorLevelIsCapturedAtCreation(initiallyOnTop: Bool) {
    let defaults = UserDefaults.standard
    let key = OwnShotAnnotatePreferenceKeys.alwaysOnTop
    let saved = defaults.object(forKey: key)
    defer { defaults.set(saved, forKey: key) }
    defaults.set(initiallyOnTop, forKey: key)
    let first = AnnotateWindow(contentRect: NSRect(x: 0, y: 0, width: 990, height: 500))
    defer { first.close() }
    let originalLevel = initiallyOnTop ? NSWindow.Level(rawValue: 103) : .normal
    #expect(first.level == originalLevel)
    defaults.set(!initiallyOnTop, forKey: key)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    first.syncLevelWithFocusState()
    first.applyActiveEditorLevel()
    first.restoreRestingLevel()
    #expect(first.level == originalLevel, "Настройка не меняет уже открытое окно")
    let second = AnnotateWindow(contentRect: first.frame)
    defer { second.close() }
    #expect(second.level == (initiallyOnTop ? .normal : NSWindow.Level(rawValue: 103)))
    defaults.set(initiallyOnTop, forKey: key)
    second.syncLevelWithFocusState()
    #expect(first.level == originalLevel)
    #expect(second.level != first.level, "У двух редакторов независимые уровни")
  }

  @Test("Палитра сохраняется при деактивации в обеих темах и размерах",
    arguments: [false, true], [false, true])
  func paletteSurvivesDeactivation(dark: Bool, expanded: Bool) throws {
    let suiteName = "ownshot.palette.lifecycle.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 990, height: 500),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    parent.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let anchor = NSView(frame: NSRect(x: 600, y: 440, width: 42, height: 28))
    parent.contentView?.addSubview(anchor)
    let controller = AnnotateColorPaletteController(store: AnnotateSavedColorStore(defaults: defaults))
    defer { controller.invalidate(); parent.close() }
    controller.show(relativeTo: anchor)
    controller.model.setExpanded(expanded)
    let panel = try #require(controller.panel)
    let frame = panel.frame
    let appearance = panel.appearance
    var closes = 0
    controller.onClose = { closes += 1 }
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    #expect(controller.panel === panel, "Деактивация сохраняет тот же экземпляр палитры")
    #expect(panel.isVisible)
    #expect(panel.frame == frame)
    #expect(panel.appearance === appearance)
    #expect(closes == 0)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    #expect(controller.panel === panel, "Возврат в приложение не создаёт вторую палитру")
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parent)
    #expect(controller.panel == nil, "Закрытие владельца убирает его палитру")
    #expect(closes == 1)
  }
  @Test("Клик по холсту закрывает палитру и у редактора поверх окон", arguments: [false, true])
  func canvasClickClosesPalette(onTop: Bool) throws {
    let key = OwnShotAnnotatePreferenceKeys.alwaysOnTop
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(onTop, forKey: key)
    let parent = AnnotateWindow(contentRect: NSRect(x: 100, y: 100, width: 990, height: 500))
    let anchor = NSView(frame: NSRect(x: 600, y: 440, width: 42, height: 28))
    parent.contentView?.addSubview(anchor)
    let name = "ownshot.palette.click.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = AnnotateColorPaletteController(store: AnnotateSavedColorStore(defaults: defaults))
    defer { controller.invalidate(); parent.close() }
    controller.show(relativeTo: anchor)
    #expect(controller.panel != nil)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50),
      modifierFlags: [], timestamp: 0, windowNumber: parent.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    NSApp.sendEvent(event)
    #expect(controller.panel == nil, "Высокий уровень редактора не превращает его в контекстное меню")
  }

  @Test("History уходит вверх за экран, сохраняя режим Reduce Motion",
    arguments: [CGSize(width: 920, height: 240), CGSize(width: 1040, height: 680)])
  func topHistoryDismissesAboveScreen(size: CGSize) async throws {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let previousIDs = Set(NSApp.windows.map(\.windowNumber))
    let controller = HistoryFloatingPanelController()
    controller.show(Color.clear, size: size,
      position: .topCenter, cornerRadius: 20)
    try await Task.sleep(for: .milliseconds(400))
    let panel = try #require(NSApp.windows.first { $0 is HistoryFloatingPanel && $0.isVisible && !previousIDs.contains($0.windowNumber) })
    let start = panel.frame
    let screenTop = try #require(panel.screen).frame.maxY
    defer { controller.hide() }
    controller.hide()
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(12))
    }
    if reduceMotion {
      #expect(panel.frame == start, "Reduce Motion сохраняет затухание без перемещения")
    } else {
      #expect(panel.frame.minY >= screenTop, "History полностью уходит за верхний край, а не вниз на 18 pt")
      #expect(panel.frame.minY > start.minY)
    }
    #expect(controller.isVisible == false)
  }

  @Test("Меню удаления цвета доступно поверх редактора Always on top", arguments: [0, 103])
  func savedColorDeleteMenuStaysAboveEditor(ownerLevel: Int) throws {
    let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 990, height: 500),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    parent.level = NSWindow.Level(rawValue: ownerLevel)
    let oldIDs = Set(NSApp.windows.map(\.windowNumber))
    let popup = AnnotateSavedColorDeletePopup()
    defer { popup.dismiss(); parent.close() }
    popup.show(at: NSPoint(x: 300, y: 300), parent: parent) {}
    let menu = try #require(NSApp.windows.first { !oldIDs.contains($0.windowNumber) && $0.isVisible })
    #expect(menu.level.rawValue >= max(ownerLevel, NSWindow.Level.popUpMenu.rawValue), "Delete не должен оказаться под редактором")
    #expect(menu.parent === parent, "Меню принадлежит палитре и следует за её окном")
    #expect(parent.level.rawValue == ownerLevel)
    let unrelated = NSWindow()
    unrelated.isReleasedWhenClosed = false
    defer { unrelated.close() }
    popup.dismiss(ownedBy: unrelated)
    #expect(menu.isVisible)
    popup.dismiss(ownedBy: parent)
    #expect(menu.parent == nil)
    #expect(menu.isVisible == false)
  }

  @Test("Клик по палитре второго редактора закрывает первую", arguments: [false, true])
  func anotherEditorPaletteCountsAsOutsideClick(onTop: Bool) throws {
    let key = OwnShotAnnotatePreferenceKeys.alwaysOnTop
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(onTop, forKey: key)
    let name = "ownshot.palette.multieditor.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = AnnotateWindow(contentRect: NSRect(x: 100, y: 100, width: 990, height: 500))
    let second = AnnotateWindow(contentRect: first.frame.offsetBy(dx: 60, dy: 60))
    let firstAnchor = NSView(frame: NSRect(x: 600, y: 440, width: 42, height: 28))
    let secondAnchor = NSView(frame: firstAnchor.frame)
    first.contentView?.addSubview(firstAnchor)
    second.contentView?.addSubview(secondAnchor)
    let a = AnnotateColorPaletteController(store: AnnotateSavedColorStore(defaults: defaults))
    let b = AnnotateColorPaletteController(store: AnnotateSavedColorStore(defaults: defaults))
    defer { a.invalidate(); b.invalidate(); first.close(); second.close() }
    a.show(relativeTo: firstAnchor)
    b.show(relativeTo: secondAnchor)
    #expect(a.panel != nil)
    let other = try #require(b.panel)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 2, y: 2),
      modifierFlags: [], timestamp: 0, windowNumber: other.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    NSApp.sendEvent(event)
    #expect(a.panel == nil)
    #expect(b.panel === other)
  }

}
