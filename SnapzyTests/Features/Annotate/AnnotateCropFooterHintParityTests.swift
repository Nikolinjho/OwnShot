import AppKit
import SwiftUI
import Testing
import Vision
@testable import Snapzy

@MainActor
@Suite(.serialized)
struct AnnotateCropFooterHintParityTests {
  @Test("Footer Crop показывает Command после zoom и Snap в обеих темах без обрезания",
    arguments: [false, true], [false, true])
  func visibleHintFollowsZoom(dark: Bool, modified: Bool) throws {
    let defaults = UserDefaultsFactory.make()
    let state = AnnotateState(defaults: defaults)
    let source = try #require(TestImageFactory.solidColor(width: 800, height: 500))
    state.loadImage(NSImage(cgImage: source, size: NSSize(width: 800, height: 500)))
    state.beginCropInteraction()
    if modified { state.applyCropRatioFields(width: 1, height: 1) }
    state.isCropEdgeSnappingEnabled = true
    let editor = AnnotateWindow(contentRect: NSRect(x: 0, y: 0, width: 990, height: 500))
    defer { editor.close() }
    // Фактический минимум окна проверяется отдельно от фиксированного контракта 990.
    for width in [editor.minSize.width, 990, 1200] {
      let host = NSHostingView(rootView: AnnotateBottomBarView(state: state,
        eventRouter: AnnotateWindowEventRouter(window: editor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .active)
        .transaction { $0.disablesAnimations = true })
      let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 50),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      panel.contentView = host
      host.frame = NSRect(x: 0, y: 0, width: width, height: 50)
      panel.orderFrontRegardless()
      defer { panel.close() }
      state.isCropEdgeSnappingEnabled = true
      let enabledImage = try capture(host)
      let enabled = try recognize(enabledImage)
      let command = try bounds(of: "Command", in: enabled)
      let disable = try bounds(of: "disable snapping", in: enabled)
      let snap = try bounds(of: "Snap to edges", in: enabled)
      let zoom = try bounds(of: "%", in: enabled)
      #expect(zoom.maxX < snap.minX)
      #expect(snap.maxX < command.minX)
      #expect(command.minX < 0.45, "Подсказка должна оставаться слева после zoom")
      #expect(disable.maxX < 0.8, "Конец строки не обрезан правыми действиями")
      #expect(abs(command.midY - snap.midY) < 0.08, "Подсказка и checkbox в одной строке")
      let revert = try optionalBounds(of: "Revert to Original", in: enabled)
      #expect((revert != nil) == modified)
      if let revert { #expect(revert.minX > disable.maxX) }

      state.isCropEdgeSnappingEnabled.toggle()
      let disabledImage = try capture(host)
      let disabled = try recognize(disabledImage)
      _ = try bounds(of: "Command", in: disabled)
      _ = try bounds(of: "enable snapping", in: disabled)
      #expect(try optionalBounds(of: "disable snapping", in: disabled) == nil)
      // Проверяем изменение самого checkbox, исключая подпись и динамический hint.
      let checkbox = CGRect(x: max(0, snap.minX * CGFloat(enabledImage.width) - 40),
        y: (1 - snap.maxY) * CGFloat(enabledImage.height) - 4,
        width: 32, height: snap.height * CGFloat(enabledImage.height) + 8).integral
      let on = try #require(enabledImage.cropping(to: checkbox))
      let off = try #require(disabledImage.cropping(to: checkbox))
      #expect(on.dataProvider?.data as Data? != off.dataProvider?.data as Data?,
        "Checkbox должен менять отметку вместе с подсказкой")
    }
  }

  private func capture<V: View>(_ host: NSHostingView<V>) throws -> CGImage {
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return try #require(bitmap.cgImage)
  }

  private func recognize(_ image: CGImage) throws -> [VNRecognizedText] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first }
  }

  private func bounds(of text: String, in lines: [VNRecognizedText]) throws -> CGRect {
    try #require(try optionalBounds(of: text, in: lines),
      "Не найден видимый текст \(text). OCR: \(lines.map(\.string))")
  }

  private func optionalBounds(of text: String, in lines: [VNRecognizedText]) throws -> CGRect? {
    for line in lines {
      if let range = line.string.range(of: text, options: .caseInsensitive) {
        return try line.boundingBox(for: range)?.boundingBox
      }
    }
    return nil
  }
}
