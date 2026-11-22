import AppKit
import SwiftUI
import Testing
@testable import Snapzy

@MainActor
struct AnnotateRedactionParityTests {
  // Сохраняем состояние до конца процесса: общий AnnotateState содержит MainActor-ресурсы.
  private static var retainedStates: [AnnotateState] = []

  @Test("Все маски Redact имеют непрерывную широкую полупрозрачную рамку",
    arguments: [BlurType.pixelated, .secure, .gaussian, .blackOut])
  func maskSelectionFrame(style: BlurType) throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    let item = AnnotationItem(type: .blur(style),
      bounds: CGRect(x: 40, y: 50, width: 160, height: 80),
      properties: AnnotationProperties(strokeWidth: 8))
    state.annotations = [item]
    state.setSelectedAnnotationIds([item.id])
    let canvas = DrawingCanvasNSView(state: state)
    canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
    canvas.canvasBounds = canvas.bounds
    let chrome = try #require(canvas.subviews.compactMap { $0 as? CanvasLayerView }.last)
    let context = try #require(CGContext(data: nil, width: 240, height: 180,
      bitsPerComponent: 8, bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    chrome.drawBody?(canvas.bounds)
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    // ANN-722…749: сплошная рамка. Проверяем целый пролёт вдали от ручек,
    // чтобы периодические 4/4 разрывы не могли пройти тест одной точкой.
    let edgeAlpha = (70..<170).map { x in pixels[(50 * 240 + x) * 4 + 3] }
    #expect(edgeAlpha.allSatisfy { $0 > 64 })
    #expect(edgeAlpha.allSatisfy { $0 < 200 })
    // ref-mask-pixelate-light-active-native.png: y607…614 при масштабе 2×,
    // то есть широкая полоса около 4 экранных pt, а не тонкий 1 pt пунктир.
    let thickness = (45...55).filter { y in pixels[(y * 240 + 110) * 4 + 3] > 64 }.count
    #expect(thickness >= 4)
  }

  @Test("Pixelate переводит отображаемый диапазон в прежние значения документа",
    arguments: [CGFloat(3), 12, 21, 30])
  func pixelateSliderRangeAndBinding(displayValue: CGFloat) {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    state.selectedTool = .blur
    state.blurType = .pixelated
    let controls = AnnotateInlineProperties(state: state)
    let storedValue = 1 + (displayValue - 3) * 24 / 27
    state.quickStrokeWidthBinding.wrappedValue = storedValue
    #expect(abs(controls.redactionSizeBinding.wrappedValue - displayValue) < 0.0001)
    #expect(controls.redactionSizeRange.contains(30))
    #expect(controls.redactionSizeRange.contains(1) == false)
    controls.redactionSizeBinding.wrappedValue = displayValue
    #expect(abs(state.quickStrokeWidthBinding.wrappedValue - storedValue) < 0.0001)
  }

  @Test("Secure и Smooth сохраняют существующее преобразование силы",
    arguments: [BlurType.secure, .gaussian])
  func secureAndSmoothStorageIsPreserved(style: BlurType) {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    state.selectedTool = .blur
    state.blurType = style
    let controls = AnnotateInlineProperties(state: state)
    state.quickStrokeWidthBinding.wrappedValue = 20
    #expect(controls.redactionSizeBinding.wrappedValue == 30)
    controls.redactionSizeBinding.wrappedValue = 3
    #expect(state.quickStrokeWidthBinding.wrappedValue == 1)
  }

  @Test("Скрытые старые стили сохраняют прежнюю шкалу размера")
  func legacyBlurStorageIsPreserved() {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    state.selectedTool = .blur
    state.blurType = .hexagonal
    let controls = AnnotateInlineProperties(state: state)
    controls.redactionSizeBinding.wrappedValue = 25
    #expect(state.quickStrokeWidthBinding.wrappedValue == 25)
    #expect(controls.redactionSizeBinding.wrappedValue == 25)
    #expect(controls.redactionSizeRange == 1...25)
  }
}
