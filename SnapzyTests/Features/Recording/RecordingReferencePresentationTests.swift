import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Snapzy

@MainActor
final class RecordingReferencePresentationTests: XCTestCase {
  func testПанельЗаписиСохраняетТёмнуюПодложкуВСветлойТеме() throws {
    let window = RecordingToolbarWindow(anchorRect: CGRect(x: 100, y: 100, width: 320, height: 180))
    defer { window.close() }
    window.appearance = NSAppearance(named: .aqua)
    window.showRecordingStatusBar(recorder: .shared, visible: false)
    let effect = try XCTUnwrap(window.contentView as? NSVisualEffectView)
    XCTAssertEqual(effect.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
  }

  func testТаймерПанелиНеДобавляетВедущийНольМинут() {
    for (seconds, expected) in [(0, "0:00"), (5, "0:05"), (65, "1:05"), (3601, "60:01")] {
      XCTAssertEqual(RecordingStatusBarView.formattedDuration(seconds: seconds), expected)
    }
  }

  func testПанельGIFКомпактнаяИСтопСКраснымТаймеромСлева() throws {
    let state = RecordingToolbarState(selectionRect: CGRect(x: 0, y: 0, width: 320, height: 180))
    state.outputMode = .gif
    let view = RecordingStatusBarView(recorder: .shared, audioLevelMeter: .init(),
      annotationState: .init(), state: state, onDelete: {}, onRestart: {}, onStop: {})
    let image = try render(view, name: "recording-status")
    XCTAssertLessThanOrEqual(image.width / 2, 260)
    XCTAssertLessThanOrEqual(image.height / 2, 36)
    let pixels = TestImageFactory.rgbaRows(of: image, rowCount: image.height)
    var redTotal = 0
    var redOnLeft = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let i = (y * image.width + x) * 4
        if pixels[i] > 150 && Int(pixels[i]) > Int(pixels[i + 1]) * 2 && pixels[i + 2] < 140 {
          redTotal += 1
          if x < image.width / 3 { redOnLeft += 1 }
        }
      }
    }
    XCTAssertGreaterThan(redTotal, 50)
    XCTAssertGreaterThan(Double(redOnLeft) / Double(max(1, redTotal)), 0.9)
  }

  func testСозданиеGIFПоказываетЗаголовокИНепрозрачнуюКарточку() throws {
    let manager = QuickAccessManager.shared
    let originalScale = manager.overlayScale
    manager.overlayScale = 1
    defer { manager.overlayScale = originalScale }
    let thumb = try XCTUnwrap(TestImageFactory.solidColor(width: 210, height: 150, red: 240, green: 20, blue: 20))
    var item = QuickAccessItem(url: URL(fileURLWithPath: "/tmp/ownshot-render-fixture.mov"),
      thumbnail: NSImage(cgImage: thumb, size: CGSize(width: 210, height: 150)), duration: 5)
    item.processingState = .processing(progress: 0.65)
    let image = try render(QuickAccessCardView(item: item, manager: manager), name: "creating-gif")
    XCTAssertTrue(try text(in: image).contains("Creating GIF"))
    let pixels = TestImageFactory.rgbaRows(of: image, rowCount: image.height)
    let i = (40 * image.width + 40) * 4
    XCTAssertLessThan(abs(Int(pixels[i]) - Int(pixels[i + 1])), 12,
      "Красное превью не должно просвечивать сквозь карточку создания GIF")
  }

  func testОбщийПрогрессСохраняетПроцентыДляЗагрузкиВОблако() throws {
    let image = try render(QuickAccessProgressView(state: .processing(progress: 0.65))
      .frame(width: 210, height: 150), name: "cloud-progress")
    XCTAssertTrue(try text(in: image).contains("65"))
  }

  func testПолосаGIFЛинейноЗаполняетсяИОграничиваетНекорректныйПрогресс() throws {
    for (index, progress) in [0.0, 0.5, 0.65, 1.0, Double.nan, Double.infinity].enumerated() {
      let image = try render(QuickAccessGIFProgressView(progress: progress, onCancel: {})
        .frame(width: 210, height: 150), name: "gif-progress-\(index)")
      let pixels = TestImageFactory.rgbaRows(of: image, rowCount: image.height)
      var longest = 0
      // Проверяем обе ориентации bitmap, выбирая строки на высоте полосы, без текста и отмены.
      for y in Array(31...39) + Array((image.height - 39)...(image.height - 31)) {
        var run = 0
        for x in 26..<356 {
          let i = (y * image.width + x) * 4
          if min(pixels[i], pixels[i + 1], pixels[i + 2]) > 120 { run += 1 }
          else { run = 0 }
          longest = max(longest, run)
        }
      }
      let expected = progress.isFinite ? Int(330 * progress) : 0
      XCTAssertEqual(longest, expected, accuracy: 3, "progress=\(progress)")
    }
  }

  private func render<V: View>(_ view: V, name: String) throws -> CGImage {
    // NSHostingView нужен для AppKit-якорей и контекстного меню: ImageRenderer заменяет их заглушками.
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark)
      .transaction { $0.disablesAnimations = true }.fixedSize())
    let size = host.fittingSize
    let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = host
    host.frame = CGRect(origin: .zero, size: size)
    panel.orderFrontRegardless()
    defer { panel.close() }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let captured = try XCTUnwrap(bitmap.cgImage)
    // Одинаковые 2 px/pt на Retina и обычном дисплее, без выхода за границы bitmap.
    let normalized = try XCTUnwrap(CGContext(data: nil,
      width: Int((size.width * 2).rounded()), height: Int((size.height * 2).rounded()),
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    normalized.draw(captured, in: CGRect(x: 0, y: 0, width: normalized.width, height: normalized.height))
    let image = try XCTUnwrap(normalized.makeImage())
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let directory = root.appendingPathComponent("build/recording-reference-render")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      .write(to: directory.appendingPathComponent(name + ".png"))
    return image
  }

  private func text(in image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
  }
}
