import AppKit
import SwiftUI
import Testing
@testable import Snapzy

@MainActor
struct QuickAccessPinHoverParityTests {
  @Test("Хром pin соответствует состояниям наведения и блокировки в нативных снимках",
    arguments: [false, true], [false, true])
  func renderedChrome(isLocked: Bool, isInside: Bool) throws {
    let fixture = try Fixture(isLocked: isLocked, isInside: isInside)
    defer { fixture.panel.close() }
    let image = try fixture.bitmap()
    let pixels = TestImageFactory.rgbaRows(of: image, rowCount: image.height)
    let center = ((image.height / 2) * image.width + image.width / 2) * 4
    let background = Array(pixels[center..<(center + 4)])
    // Ячейки 24 pt в 9 pt от углов: spec-039/pin-default.json.
    // Сравниваем цвет с настоящим фоном этого же render, включая locked-hover alpha.
    func changedPixels(x: ClosedRange<Int>, y: ClosedRange<Int>) -> Int {
      y.reduce(0) { total, row in
        total + x.filter { column in
          let index = (row * image.width + column) * 4
          return (0..<4).contains { abs(Int(pixels[index + $0]) - Int(background[$0])) > 24 }
        }.count
      }
    }
    func cornerChanges(left: Bool) -> Int {
      let x = left ? 12...30 : 370...388
      return max(changedPixels(x: x, y: 12...30), changedPixels(x: x, y: 170...188))
    }
    let closePixels = cornerChanges(left: true)
    let lockPixels = cornerChanges(left: false)
    let centerChromePixels = max(changedPixels(x: 175...225, y: 12...30),
      changedPixels(x: 175...225, y: 170...188))
    // pin-default.png: без наведения unlocked не показывает хром.
    // pin-locked-pointer-away-settled.png: остаётся замок.
    // pin-locked-settled.png: под курсором видны закрытие и замок, без zoom/drag.
    if isInside { #expect(closePixels > 30) }
    else { #expect(closePixels < 5) }
    if isInside || isLocked { #expect(lockPixels > 30) }
    else { #expect(lockPixels < 5) }
    if isInside && isLocked == false { #expect(centerChromePixels > 30) }
    else { #expect(centerChromePixels < 5) }
  }

  @Test("Скрытые controls pin не забирают клики и области перетаскивания",
    arguments: [false, true], [false, true])
  func actualControlHitRegions(isLocked: Bool, isInside: Bool) throws {
    let fixture = try Fixture(isLocked: isLocked, isInside: isInside)
    defer { fixture.panel.close() }
    // Родное окно pin определяет интерактивные controls по фактическим AppKit
    // marker frames (QuickAccessPinWindow.isOverInteractiveControl), не по opacity.
    let markers = fixture.descendants(of: PinWindowDragExclusionView.self)
    func owns(_ point: CGPoint) -> Bool {
      markers.contains { marker in
        let rect = marker.convert(marker.bounds, to: fixture.host)
        return rect.contains(point)
      }
    }
    #expect(owns(CGPoint(x: 21, y: 21)) == isInside)
    #expect(owns(CGPoint(x: 379, y: 21)) == (isInside || isLocked))
    #expect(owns(CGPoint(x: 200, y: 179)) == (isInside && isLocked == false))

    // Посылаем события только в fixture NSPanel, не перемещая системный курсор.
    fixture.click(x: 21, y: 21)
    #expect(fixture.closeCount == (isInside ? 1 : 0))
    let wasLocked = fixture.state.isLocked
    fixture.click(x: 379, y: 21)
    #expect(fixture.lockCount == (isInside || isLocked ? 1 : 0))
    #expect(fixture.state.isLocked == (isInside || isLocked ? wasLocked == false : wasLocked))
  }

  @MainActor
  private final class Fixture {
    let state: QuickAccessPinWindowState
    let panel: NSPanel
    let host: NSHostingView<AnyView>
    var closeCount = 0
    var lockCount = 0

    init(isLocked: Bool, isInside: Bool) throws {
      let pixels = try #require(TestImageFactory.solidColor(width: 400, height: 200,
        red: 20, green: 89, blue: 191))
      let image = NSImage(cgImage: pixels, size: CGSize(width: 400, height: 200))
      state = QuickAccessPinWindowState(id: UUID(), url: URL(fileURLWithPath: "/tmp/pin-hover-fixture.png"),
        image: image, thumbnail: image, baseSize: image.size)
      state.isLocked = isLocked
      state.isMouseInside = isInside
      state.roundedCorners = false
      state.showsBorder = false
      state.showsShadow = false
      host = NSHostingView(rootView: AnyView(EmptyView()))
      panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      host.rootView = AnyView(QuickAccessPinWindowView(state: state,
        onClose: { [weak self] in self?.closeCount += 1 },
        onLockChanged: { [weak self] in self?.lockCount += 1 })
        .environment(\.colorScheme, .dark)
        .transaction { $0.disablesAnimations = true }
        .fixedSize())
      panel.contentView = host
      host.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
      panel.orderFrontRegardless()
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
      host.layoutSubtreeIfNeeded()
    }

    func bitmap() throws -> CGImage {
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let captured = try #require(bitmap.cgImage)
      // Нормализуем до 1 px/pt, чтобы измерения не зависели от тестового дисплея.
      let context = try #require(CGContext(data: nil, width: 400, height: 200,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(captured, in: CGRect(x: 0, y: 0, width: 400, height: 200))
      return try #require(context.makeImage())
    }

    func descendants<V: NSView>(of type: V.Type) -> [V] {
      func collect(_ view: NSView) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap(collect)
      }
      return collect(host)
    }

    func click(x: CGFloat, y: CGFloat) {
      let point = host.convert(CGPoint(x: x, y: y), to: nil)
      for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: eventType, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { continue }
        panel.sendEvent(event)
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
  }
}
