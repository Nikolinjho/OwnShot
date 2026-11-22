import AppKit
import Testing
@testable import Snapzy

@MainActor
@Suite(.serialized)
struct QuickAccessPinDragRecoveryTests {
  private static var retainedStates: [QuickAccessPinWindowState] = []

  @Test("Восстановление pin после файлового drag пересчитывает hover и пропуск мыши",
    arguments: [false, true], [false, true])
  func restoringWindowRefreshesPointerState(isInside: Bool, locked: Bool) {
    let pointer = NSEvent.mouseLocation
    let requestedFrame = NSRect(
      x: pointer.x + (isInside ? -200 : 100),
      y: pointer.y + (isInside ? -100 : 100),
      width: 400, height: 200)
    let image = NSImage(size: requestedFrame.size)
    let state = QuickAccessPinWindowState(id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pin-drag-recovery-fixture.png"),
      image: image, thumbnail: image, baseSize: image.size)
    Self.retainedStates.append(state)
    state.isLocked = locked
    let window = QuickAccessPinWindow(contentRect: requestedFrame, state: state)
    defer { window.close() }
    window.setFrame(requestedFrame, display: false)
    // Файловый drag сохраняет фактический frame окна после выравнивания AppKit,
    // а не дробные координаты указателя, из которых задано положение fixture.
    let restoredFrame = window.frame
    window.setFrame(restoredFrame.offsetBy(dx: 600, dy: 600), display: false)

    // Последний hover до NSDraggingSession мог быть противоположным положению
    // pointer после drop. Никаких системных движений мыши тест не выполняет.
    state.isMouseInside = !isInside
    window.ignoresMouseEvents = locked && !isInside
    window.orderOut(nil)
    #expect(window.isVisible == false)
    // У inactive Test Host key window может отсутствовать. Его не назначаем:
    // восстановление после drop должно сохранять фактический фокус.
    let keyWindowBeforeRestore = NSApp.keyWindow
    let wasKeyWindow = window.isKeyWindow

    window.restoreAfterFileDrag(to: restoredFrame)

    #expect(window.frame == restoredFrame)
    #expect(window.isVisible)
    #expect(NSApp.keyWindow === keyWindowBeforeRestore)
    #expect(window.isKeyWindow == wasKeyWindow)
    #expect(state.isMouseInside == isInside)
    // Pointer внутри расположен в центре, вне close и расширенной unlock-зоны.
    #expect(window.ignoresMouseEvents == (locked && isInside))
  }
}
