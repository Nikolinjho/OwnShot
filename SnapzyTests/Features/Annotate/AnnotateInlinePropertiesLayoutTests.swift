import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

/// Реальные frame контролов и растр inline-панели против AX эталона spec-039-live.
@MainActor
final class AnnotateInlinePropertiesLayoutTests: XCTestCase {
  private static var retainedStates: [AnnotateState] = []

  func testКапсулыArrowCounterИTextИмеютЧетыреПунктаМеждуСоседями() throws {
    for dark in [false, true] {
      var fontWidths: [CGFloat] = []
      for (tool, fontSize) in [(AnnotationToolType.arrow, CGFloat(30)), (.counter, 30), (.text, 30), (.text, 216)] {
        let state = makeState(tool: tool)
        state.quickTextFontSizeBinding.wrappedValue = fontSize
        try withRenderedControls(state: state, dark: dark) { host, bitmap in
          let frames = capsuleFrames(in: host)
          XCTAssertEqual(frames.count, 3, "Должны быть отрисованы три настоящие капсулы: \(frames)")
          guard frames.count == 3 else { return }
          for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.height, 28, accuracy: 0.5)
            if tool != .text || index != 1 { XCTAssertEqual(frame.width, 42, accuracy: 0.5) }
            try assertVisibleCapsule(frame, bitmap: bitmap, host: host)
          }
          for (left, right) in zip(frames, frames.dropFirst()) {
            // spec039 Arrow/Counter: 1039+42, 1085+42, 1131+42; Text: 1039,1085,1147.
            XCTAssertEqual(right.minX - left.maxX, 4, accuracy: 0.5, "\(tool): \(frames)")
            XCTAssertEqual(right.midY, left.midY, accuracy: 0.5)
          }
          if tool == .text { fontWidths.append(frames[1].width) }
        }
      }
      XCTAssertEqual(fontWidths.count, 2)
      if fontWidths.count == 2 {
        XCTAssertGreaterThan(fontWidths[1], fontWidths[0], "Капсула кегля растёт вместе с подписью 30 pt → 216 pt")
      }

    }
  }

  func testSpotlightИRedactИмеютЗазорДевятьИСлайдер102На16ПоЦентруКапсулы() throws {
    for dark in [false, true] {
      for style in [BlurType?.none, .some(.pixelated), .some(.secure), .some(.gaussian)] {
        let state = makeState(tool: style == nil ? .spotlight : .blur)
        if let style { state.blurType = style }
        try withRenderedControls(state: state, dark: dark) { host, bitmap in
          let frames = capsuleFrames(in: host)
          XCTAssertEqual(frames.count, 1, "Перед слайдером одна капсула формы или стиля: \(frames)")
          let capsule = try XCTUnwrap(frames.first)
          // SwiftUI 27 рисует Slider сам: его нативный KeyViewProxy и focus ring
          // имеют реальный frame контрола, NSSlider в дереве отсутствует.
          let sliderFrames = platformSliderFrames(in: host, after: capsule)
          XCTAssertEqual(sliderFrames.count, 1, "Должен существовать один настоящий платформенный frame слайдера")
          let frame = try XCTUnwrap(sliderFrames.first)
          XCTAssertEqual(capsule.size.width, 42, accuracy: 0.5)
          XCTAssertEqual(capsule.size.height, 28, accuracy: 0.5)
          try assertVisibleCapsule(capsule, bitmap: bitmap, host: host)
          // spec039 Spotlight: shape x1039,w42,y273,h28; slider x1090,w102,y279,h16.
          XCTAssertEqual(frame.minX - capsule.maxX, 9, accuracy: 0.5, "\(String(describing: style)): \(capsule), \(frame)")
          XCTAssertEqual(frame.width, 102, accuracy: 0.5)
          XCTAssertEqual(frame.height, 16, accuracy: 0.5)
          XCTAssertEqual(frame.midY, capsule.midY, accuracy: 0.5)
          if style == nil {
            state.quickSpotlightOpacityBinding.wrappedValue = 0.9
          } else {
            let controls = AnnotateInlineProperties(state: state)
            controls.redactionSizeBinding.wrappedValue = controls.redactionSizeRange.upperBound
          }
          host.layoutSubtreeIfNeeded()
          RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
          let changed = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: changed)
          XCTAssertGreaterThan(try changedPixelCount(in: frame, before: bitmap, after: changed, host: host), 20,
            "Платформенный frame действительно содержит слайдер: новое значение меняет положение бегунка в растре")
        }
      }

    }
  }

  func testСмешанныйВыборTextИSpotlightОставляетЧетыреМеждуКапсуламиИДевятьПередСлайдером() throws {
    for dark in [false, true] {
      let state = makeState(tool: .selection)
      let text = AnnotationItem(type: .text("Текст"), bounds: CGRect(x: 5, y: 5, width: 80, height: 30),
        properties: AnnotationProperties(fontSize: 30))
      let spotlight = AnnotationItem(type: .spotlight, bounds: CGRect(x: 10, y: 40, width: 70, height: 40),
        properties: AnnotationProperties())
      state.annotations = [text, spotlight]
      state.setSelectedAnnotationIds([text.id, spotlight.id])
      XCTAssertTrue(state.quickPropertiesSupportsTextBackground)
      XCTAssertTrue(state.quickPropertiesSupportsSpotlightShape)
      try withRenderedControls(state: state, dark: dark) { host, bitmap in
        let frames = capsuleFrames(in: host)
        XCTAssertEqual(frames.count, 4, "Одновременно видны Color, Font size, Text style и Spotlight shape: \(frames)")
        guard frames.count == 4 else { return }
        for frame in frames {
          XCTAssertEqual(frame.height, 28, accuracy: 0.5)
          try assertVisibleCapsule(frame, bitmap: bitmap, host: host)
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
          XCTAssertEqual(right.minX - left.maxX, 4, accuracy: 0.5,
            "Обычные капсулы сохраняют свой зазор при смешанном выборе: \(frames)")
          XCTAssertEqual(right.midY, left.midY, accuracy: 0.5)
        }
        let shape = frames[3]
        let sliders = platformSliderFrames(in: host, after: shape)
        XCTAssertEqual(sliders.count, 1)
        let slider = try XCTUnwrap(sliders.first)
        XCTAssertEqual(slider.minX - shape.maxX, 9, accuracy: 0.5)
        XCTAssertEqual(slider.width, 102, accuracy: 0.5)
        XCTAssertEqual(slider.height, 16, accuracy: 0.5)
        XCTAssertEqual(slider.midY, shape.midY, accuracy: 0.5)
      }
    }
  }

  func testДобавочныеСтилиRedactСохраняютШестьПунктовИМалыйСлайдерABlackOutБезСлайдера() throws {
    for dark in [false, true] {
      for style in [BlurType.hexagonal, .crystallized, .pointillism, .halftone, .tape, .washi, .blackOut] {
        let state = makeState(tool: .blur)
        state.blurType = style
        try withRenderedControls(state: state, dark: dark) { host, bitmap in
          let capsules = capsuleFrames(in: host)
          XCTAssertEqual(capsules.count, 1)
          let capsule = try XCTUnwrap(capsules.first)
          try assertVisibleCapsule(capsule, bitmap: bitmap, host: host)
          let sliders = platformSliderFrames(in: host, after: capsule)
          if style == .blackOut {
            XCTAssertTrue(sliders.isEmpty, "BlackOut оставляет только меню стиля")
          } else {
            XCTAssertEqual(sliders.count, 1)
            let slider = try XCTUnwrap(sliders.first)
            XCTAssertEqual(slider.minX - capsule.maxX, 6, accuracy: 0.5)
            XCTAssertEqual(slider.width, 80, accuracy: 0.5)
            XCTAssertEqual(slider.height, 14, accuracy: 0.5)
            XCTAssertEqual(slider.midY, capsule.midY, accuracy: 0.5)
          }
        }
      }

    }
  }

  func testDrawИHighlighterСохраняютЗамок38На28СЗазоромЧетыре() throws {
    for dark in [false, true] {
      for tool in [AnnotationToolType.pencil, .highlighter] {
        try withRenderedControls(state: makeState(tool: tool), dark: dark) { host, bitmap in
          let frames = descendants(in: host)
            .filter { NSStringFromClass(type(of: $0)) == "SwiftUI.KeyViewProxy" }
            .map { $0.convert($0.bounds, to: host) }.sorted { $0.minX < $1.minX }
          XCTAssertEqual(frames.count, 3, "Настоящие платформенные frame Color, Thickness и Lock: \(frames)")
          guard frames.count == 3 else { return }
          for (index, frame) in frames.enumerated() {
            try assertVisibleCapsule(frame, bitmap: bitmap, host: host)
            XCTAssertEqual(frame.width, index == 2 ? 38 : 42, accuracy: 0.5)
            XCTAssertEqual(frame.height, 28, accuracy: 0.5)
            if index > 0 {
              XCTAssertEqual(frame.minX - frames[index - 1].maxX, 4, accuracy: 0.5)
              XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 0.5)
            }
          }
        }
      }

    }
  }

  private func makeState(tool: AnnotationToolType) -> AnnotateState {
    let state = AnnotateState(image: NSImage(size: CGSize(width: 100, height: 100)),
      url: URL(fileURLWithPath: "/tmp/ownshot-inline-layout.png"), defaults: UserDefaultsFactory.make())
    Self.retainedStates.append(state)
    state.selectedTool = tool
    return state
  }

  private func withRenderedControls(state: AnnotateState, dark: Bool,
    inspect: (NSView, NSBitmapImageRep) throws -> Void) throws {
    let host = NSHostingView(rootView: AnnotateInlineProperties(state: state)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .padding(.leading, 20)
      .background(dark ? Color.black : Color.white)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.controlActiveState, .active)
      .transaction { $0.disablesAnimations = true })
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 50),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    panel.contentView = host
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 50)
    panel.orderFrontRegardless()
    defer { panel.close(); panel.contentView = nil }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try validateBitmap(bitmap)
    if state.selectedTool == .arrow || state.selectedTool == .spotlight
      || (state.selectedTool == .text && state.quickTextFontSizeBinding.wrappedValue == 216) {
      let name = String(describing: state.selectedTool)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: "/private/tmp/ownshot-inline-\(name)-\(dark ? "dark" : "light").png"))
    }
    try inspect(host, bitmap)
  }

  private func descendants(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(in: $0) }
  }

  private func platformSliderFrames(in host: NSView, after capsule: CGRect) -> [CGRect] {
    let views = descendants(in: host)
    let semantic = views.filter { $0.accessibilityRole() == .slider }
    // Характеризация SwiftUI 27: если публичная роль не опубликована на NSView,
    // берём настоящий платформенный focus proxy, а не придуманную геометрию.
    let candidates = semantic.isEmpty
      ? views.filter { NSStringFromClass(type(of: $0)) == "SwiftUI.KeyViewProxy" } : semantic
    return candidates.map { $0.convert($0.bounds, to: host) }
      .filter { $0.minX > capsule.maxX && $0.height < capsule.height }
  }

  private func capsuleFrames(in host: NSView) -> [CGRect] {
    // Нативные anchors уже обслуживают настоящие меню и палитру; AX-процесс не нужен.
    descendants(in: host).filter { NSStringFromClass(type(of: $0)).contains("AnchorView") }
      .map { $0.convert($0.bounds, to: host) }.filter { $0.width > 0 && $0.height > 0 }
      .sorted { $0.minX < $1.minX }
  }

  private func changedPixelCount(in frame: CGRect, before: NSBitmapImageRep,
    after: NSBitmapImageRep, host: NSView) throws -> Int {
    try validateBitmap(before)
    try validateBitmap(after)
    guard before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh,
          host.bounds.width > 0, host.bounds.height > 0, frame.width > 0, frame.height > 0,
          host.bounds.contains(frame) else {
      XCTFail("Геометрия растра изменилась или ROI вне host: \(frame), \(host.bounds)")
      throw NSError(domain: "OwnShotInlineBitmapGeometry", code: 1)
    }
    let lhs = try XCTUnwrap(before.bitmapData)
    let rhs = try XCTUnwrap(after.bitmapData)
    let scale = CGFloat(before.pixelsWide) / host.bounds.width
    let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
    guard abs(CGFloat(before.pixelsHigh) / host.bounds.height - scale) < 0.001,
          Int(top * scale) >= 0, Int((top + frame.height) * scale) <= before.pixelsHigh,
          Int(frame.minX * scale) >= 0, Int(frame.maxX * scale) <= before.pixelsWide else {
      XCTFail("ROI не соответствует масштабу и границам настоящего bitmap")
      throw NSError(domain: "OwnShotInlineBitmapGeometry", code: 2)
    }
    var count = 0
    for y in Int(top * scale)..<Int((top + frame.height) * scale) {
      for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
        let left = y * before.bytesPerRow + x * before.samplesPerPixel
        let right = y * after.bytesPerRow + x * after.samplesPerPixel
        if (0..<3).contains(where: { abs(Int(lhs[left + $0]) - Int(rhs[right + $0])) > 20 }) { count += 1 }
      }
    }
    return count
  }

  private func validateBitmap(_ bitmap: NSBitmapImageRep) throws {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0, bitmap.bitsPerSample == 8,
          !bitmap.isPlanar, !bitmap.bitmapFormat.contains(.alphaFirst),
          [3, 4].contains(bitmap.samplesPerPixel), bitmap.bitsPerPixel == bitmap.samplesPerPixel * 8,
          bitmap.bytesPerRow >= bitmap.pixelsWide * bitmap.samplesPerPixel else {
      XCTFail("Ожидается непустой interleaved RGB(A)8 bitmap без alphaFirst")
      throw NSError(domain: "OwnShotInlineBitmapFormat", code: 1)
    }
    _ = try XCTUnwrap(bitmap.bitmapData)
  }

  private func assertVisibleCapsule(_ frame: CGRect, bitmap: NSBitmapImageRep, host: NSView) throws {
    try validateBitmap(bitmap)
    let x = Int(frame.midX * CGFloat(bitmap.pixelsWide) / host.bounds.width)
    let yInView = frame.minY + 2
    let top = host.isFlipped ? yInView : host.bounds.height - yInView
    let y = Int(top * CGFloat(bitmap.pixelsHigh) / host.bounds.height)
    let bytes = try XCTUnwrap(bitmap.bitmapData)
    XCTAssertFalse(bitmap.isPlanar)
    XCTAssertGreaterThanOrEqual(bitmap.samplesPerPixel, 3)
    guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y) else {
      return XCTFail("Frame капсулы вне настоящего растра: \(frame)")
    }
    let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
    let contrast = (0..<3).reduce(0) { $0 + abs(Int(bytes[offset + $1]) - Int(bytes[$1])) }
    XCTAssertGreaterThan(contrast, 6, "Подложка капсулы должна отличаться от пустого фона в том же растре")
  }
}
