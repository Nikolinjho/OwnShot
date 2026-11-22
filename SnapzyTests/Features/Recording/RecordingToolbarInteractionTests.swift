//
//  RecordingToolbarInteractionTests.swift
//  SnapzyTests
//
//  Regression coverage for recording toolbar hit targets.
//

import AppKit
@testable import Snapzy
import SwiftUI
import XCTest

@MainActor
final class RecordingToolbarInteractionTests: XCTestCase {
  func testRecordButton_dispatchesFromPaddedSurface() throws {
    try skipIfRunningInCI("Requires an onscreen hosting window and synthetic mouse events")
    var didRecord = false
    let state = RecordingToolbarState()
    let host = NSHostingView(
      rootView: RecordButtonWithBadge(state: state, onRecord: { didRecord = true })
    )
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(
      contentRect: host.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    // Без этого close() освобождает окно второй раз поверх ARC.
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    window.makeKey()
    defer { window.close() }

    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

    let clickPoint = CGPoint(x: 2, y: host.bounds.midY)
    try window.sendEvent(XCTUnwrap(mouseEvent(.leftMouseDown, at: clickPoint, window: window)))
    try window.sendEvent(XCTUnwrap(mouseEvent(.leftMouseUp, at: clickPoint, window: window)))

    XCTAssertTrue(didRecord)
  }

  func testКнопкиGIFQualityВыбираютКрайниеЗначенияВОбеихТемах() throws {
    try skipIfRunningInCI("Требуется локальное окно SwiftUI для событий мыши")
    for scheme in [ColorScheme.light, .dark] {
      var quality = 0.375
      let binding = Binding(get: { quality }, set: { quality = $0 })
      let host = NSHostingView(rootView: OwnShotGIFQualityControl(quality: binding)
        .environment(\.colorScheme, scheme)
        .transaction { $0.disablesAnimations = true }
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor)))
      host.frame = NSRect(origin: .zero, size: host.fittingSize)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
      window.orderFrontRegardless()
      window.makeKey()
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

      XCTAssertEqual(quality, 0.375)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let snapshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      snapshot.name = scheme == .light ? "gif-quality-light" : "gif-quality-dark"
      snapshot.lifetime = .keepAlways
      add(snapshot)

      for (x, expected) in [(12.0, 0.0), (host.bounds.width - 12, 1.0)] {
        let point = host.convert(CGPoint(x: x, y: host.bounds.midY), to: nil)
        try window.sendEvent(XCTUnwrap(mouseEvent(.leftMouseDown, at: point, window: window)))
        try window.sendEvent(XCTUnwrap(mouseEvent(.leftMouseUp, at: point, window: window)))
        XCTAssertEqual(quality, expected, "Тема \(scheme)")
      }
    }
  }

  private func mouseEvent(
    _ type: NSEvent.EventType,
    at location: CGPoint,
    window: NSWindow
  ) -> NSEvent? {
    NSEvent.mouseEvent(
      with: type,
      location: location,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )
  }
}
