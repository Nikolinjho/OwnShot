import AppKit
import Testing
@testable import Snapzy

@MainActor
struct QuickAccessPinLockedControlRoutingTests {
  private static var retainedStates: [QuickAccessPinWindowState] = []

  @Test("Заблокированный pin принимает мышь над закрытием и разблокировкой",
    arguments: [false, true])
  func visibleCornerControlsAcceptClicks(close: Bool) {
    let (window, state) = makeWindow()
    defer { window.close() }
    state.isLocked = true
    let point = CGPoint(x: close ? window.frame.minX + 21 : window.frame.maxX - 21,
      y: window.frame.maxY - 21)
    window.updateMousePassthrough(at: point)
    #expect(state.isMouseInside)
    #expect(window.ignoresMouseEvents == false)
  }

  @Test("Середина заблокированного pin пропускает мышь, уход восстанавливает окно")
  func imageRemainsClickThroughAndPointerExitResetsRouting() {
    let (window, state) = makeWindow()
    defer { window.close() }
    state.isLocked = true
    window.updateMousePassthrough(at: CGPoint(x: window.frame.midX, y: window.frame.midY))
    #expect(state.isMouseInside)
    #expect(window.ignoresMouseEvents)
    window.updateMousePassthrough(at: CGPoint(x: window.frame.maxX + 10, y: window.frame.maxY + 10))
    #expect(state.isMouseInside == false)
    #expect(window.ignoresMouseEvents == false)
    state.isLocked = false
    window.updateMousePassthrough(at: CGPoint(x: window.frame.midX, y: window.frame.midY))
    #expect(window.ignoresMouseEvents == false)
  }

  private func makeWindow() -> (QuickAccessPinWindow, QuickAccessPinWindowState) {
    let image = NSImage(size: CGSize(width: 400, height: 200))
    let state = QuickAccessPinWindowState(id: UUID(), url: URL(fileURLWithPath: "/tmp/pin-routing-fixture.png"),
      image: image, thumbnail: image, baseSize: image.size)
    Self.retainedStates.append(state)
    let window = QuickAccessPinWindow(contentRect: CGRect(x: 400, y: 300, width: 400, height: 200), state: state)
    return (window, state)
  }
}
