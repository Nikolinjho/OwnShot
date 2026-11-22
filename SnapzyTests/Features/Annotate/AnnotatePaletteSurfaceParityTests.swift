import AppKit
import SwiftUI
import Testing
@testable import Snapzy

@MainActor
@Suite(.serialized)
struct AnnotatePaletteSurfaceParityTests {
  @Test("Нативный рендер Dark Custom Color повторяет три измеренные подложки")
  func darkExpandedSurfaces() throws {
    let bitmap = try render(dark: true)
    // ANN-392: точки в нативном эталоне 632×800, без границ и текста.
    try expectGray(bitmap, x: 8, y: 350, value: 41)
    try expectGray(bitmap, x: 180, y: 600, value: 31)
    try expectGray(bitmap, x: 220, y: 560, value: 53)
  }

  @Test("Light Custom Color сохраняет измеренные подложки")
  func lightExpandedSurfaces() throws {
    let bitmap = try render(dark: false)
    try expectGray(bitmap, x: 8, y: 350, value: 245)
    try expectGray(bitmap, x: 180, y: 600, value: 232)
    try expectGray(bitmap, x: 220, y: 560, value: 220)
  }

  @Test("Глиф Alpha 100 соответствует нативным размерам эталона в обеих темах",
    arguments: [false, true])
  func alphaGlyphBounds(dark: Bool) throws {
    let bitmap = try render(dark: dark)
    var minX = Int.max
    var minY = Int.max
    var maxX = -1
    var maxY = -1
    // ROI из ANN-394/392: только число, без скруглений поля и подписи Alpha.
    for y in 552..<592 {
      for x in 498..<570 {
        let color = try pixel(bitmap, x: x, y: y)
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        let isGlyph = dark ? components.min()! > 180.0 / 255 : components.max()! < 130.0 / 255
        if isGlyph {
          minX = min(minX, x)
          minY = min(minY, y)
          maxX = max(maxX, x)
          maxY = max(maxY, y)
        }
      }
    }
    try #require(maxX >= minX, "Поле Alpha должно содержать видимый текст 100")
    let width = maxX - minX + 1
    let height = maxY - minY + 1
    #expect(abs(width - (dark ? 35 : 36)) <= 1, "Ширина Alpha 100: \(width) px")
    #expect(abs(height - 16) <= 1, "Высота Alpha 100: \(height) px")
  }

  private func render(dark: Bool) throws -> NSBitmapImageRep {
    let name = "ownshot.palette.surface.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AnnotateColorPickerModel(store: AnnotateSavedColorStore(defaults: defaults))
    model.synchronize(Color(red: 0.2, green: 0.4, blue: 0.6))
    model.setExpanded(true)
    let host = NSHostingView(rootView: AnnotateColorPaletteView(model: model, actions: .init())
      .environment(\.colorScheme, dark ? .dark : .light)
      .transaction { $0.disablesAnimations = true })
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 316, height: 400),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    panel.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 316, height: 400)
    panel.orderFrontRegardless()
    defer { panel.close() }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    // Фиксируем формат RGBA и нативный масштаб без ресэмплинга.
    let storage = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 632,
      pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let bitmap = try #require(storage.retagging(with: .sRGB))
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    // Замеры шрифта валидны только при исходном масштабе 2×, без ресэмплинга.
    try #require(bitmap.pixelsWide == 632 && bitmap.pixelsHigh == 800)
    return bitmap
  }

  private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
    // cacheDisplay записывает sRGB-байты, но заменяет профиль на NSCalibratedRGB.
    // Конвертация colorAt в sRGB повторно меняет гамму, поэтому читаем исходный RGBA.
    let bytes = try #require(bitmap.bitmapData)
    let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
    return NSColor(srgbRed: CGFloat(bytes[offset]) / 255,
      green: CGFloat(bytes[offset + 1]) / 255, blue: CGFloat(bytes[offset + 2]) / 255,
      alpha: CGFloat(bytes[offset + 3]) / 255)
  }

  private func expectGray(_ bitmap: NSBitmapImageRep, x: Int, y: Int, value: Int) throws {
    let color = try pixel(bitmap, x: x, y: y)
    for component in [color.redComponent, color.greenComponent, color.blueComponent] {
      #expect(abs(component * 255 - Double(value)) <= 1,
        "Подложка в (\(x), \(y)): \(color), ожидается серый \(value)")
    }
  }
}
