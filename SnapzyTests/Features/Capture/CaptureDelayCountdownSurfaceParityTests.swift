import AppKit
import Testing
@testable import Snapzy

@MainActor
@Suite(.serialized)
struct CaptureDelayCountdownSurfaceParityTests {
  @Test("Настоящий HUD таймера сохраняет непрозрачную заливку эталона и не забирает фокус",
    arguments: [false, true])
  func countdownSurfacePreservesFillAndFocus(dark: Bool) throws {
    let controller = CaptureDelayCountdownController.shared
    // Не отменяем чужой отсчёт, если другой тест уже использует singleton.
    try #require(controller.isActive == false, "Для проверки нужен свободный controller таймера")
    let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    defer { owner.close() }
    owner.orderFront(nil)
    owner.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    // Inactive Test Host вправе не иметь key window: не активируем приложение
    // ради fixture, а проверяем сохранность фактического состояния.
    let keyWindowBeforeCountdown = NSApp.keyWindow

    var completed = false
    controller.start(seconds: 30, captureName: "countdown-surface-parity") { completed = true }
    defer { controller.cancel() }
    let panel = try #require(NSApp.windows.first {
      $0.isVisible && $0.identifier?.rawValue == "OwnShotCountdown"
    })
    let previousAppearance = panel.appearance
    defer { panel.appearance = previousAppearance }
    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    content.layoutSubtreeIfNeeded()
    #expect(NSApp.keyWindow === keyWindowBeforeCountdown)
    #expect(panel.isKeyWindow == false)
    #expect(panel.canBecomeKey == false)
    #expect(panel.frame.size == CGSize(width: 110, height: 62))

    // Настоящий content render при 2×. В cacheDisplay проверяем исходные RGBA:
    // AppKit может переименовать профиль bitmap в calibrated RGB после записи.
    let storage = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: 220, pixelsHigh: 124, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    let bitmap = try #require(storage.retagging(with: .sRGB))
    bitmap.size = content.bounds.size
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try #require(bitmap.samplesPerPixel == 4 && bitmap.bitsPerSample == 8)
    let bytes = try #require(bitmap.bitmapData)
    // CAP-134: reference-timer.png и desktop содержат 19 433 непрозрачных
    // пикселя 255/79/67. Области сверху и снизу числа исключают glyph и stroke.
    for pointY in [8, 54] {
      for pointX in [45, 55, 65] {
        for y in (pointY * 2)..<(pointY * 2 + 2) {
          for x in (pointX * 2)..<(pointX * 2 + 2) {
            let offset = y * bitmap.bytesPerRow + x * 4
            let rgba = (0..<4).map { bytes[offset + $0] }
            #expect(rgba == [255, 79, 67, 255],
              "Заливка HUD в (\(x), \(y)): \(rgba), Dark=\(dark)")
          }
        }
      }
    }

    controller.cancel()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    #expect(controller.isActive == false)
    #expect(panel.isVisible == false)
    #expect(completed == false, "Отмена не должна запускать отложенный захват")
    #expect(NSApp.keyWindow === keyWindowBeforeCountdown)
  }
}
