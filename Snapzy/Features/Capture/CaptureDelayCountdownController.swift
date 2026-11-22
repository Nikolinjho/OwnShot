//
//  CaptureDelayCountdownController.swift
//  Snapzy
//
//  Shows a small non-activating countdown HUD before a delayed screenshot.
//  The HUD never takes focus, so menus and hover states opened in other apps
//  stay open until the capture fires. Esc or clicking the HUD cancels.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureDelayCountdownController {
  static let shared = CaptureDelayCountdownController()

  /// Time for the HUD to leave the screen before the capture starts.
  private let hudDismissSettleDelay: TimeInterval = 0.15

  private let model = CaptureDelayCountdownModel()
  private var panel: NSPanel?
  private var overlays: [RecordingRegionOverlayWindow] = []
  private var timer: Timer?
  private var timerID: UUID?
  private var countdown = CaptureDelayCountdown(seconds: 0)
  private var onFinish: (@MainActor () -> Void)?
  /// The capture scheduled after the HUD settles; still part of the countdown.
  private var pendingCapture: Task<Void, Never>?
  private var globalKeyMonitor: Any?
  private var localKeyMonitor: Any?

  private init() {}

  var isActive: Bool { onFinish != nil || pendingCapture != nil }

  /// Count down `seconds`, then run `onFinish`. Ignored while another
  /// countdown is running. `detail` is an optional line under the digits
  /// (used by delayed fullscreen so the HUD says what will be captured).
  func start(
    seconds: Int,
    captureName: String,
    detail: String? = nil,
    highlightRect: CGRect? = nil,
    onFinish: @escaping @MainActor () -> Void
  ) {
    guard !isActive else {
      DiagnosticLogger.shared.log(.debug, .capture, "Capture delay ignored: countdown already running", context: [
        "capture": captureName,
      ])
      return
    }
    guard seconds > 0 else {
      onFinish()
      return
    }

    DiagnosticLogger.shared.log(.info, .capture, "Capture delay started", context: [
      "capture": captureName,
      "seconds": "\(seconds)",
    ])
    self.onFinish = onFinish
    countdown = CaptureDelayCountdown(seconds: seconds)
    model.remainingSeconds = seconds
    model.detail = detail
    if let highlightRect {
      overlays = NSScreen.screens.map { screen in
        let overlay = RecordingRegionOverlayWindow(screen: screen, highlightRect: highlightRect, chromeRole: .captureOverlay)
        overlay.identifier = NSUserInterfaceItemIdentifier("OwnShotCountdownOverlay")
        overlay.level = NSWindow.Level(rawValue: 2147483630)
        overlay.setInteractionEnabled(false)
        overlay.orderFrontRegardless()
        return overlay
      }
    }
    showPanel()
    installKeyMonitors()

    let timerID = UUID()
    self.timerID = timerID
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
      Task { @MainActor in CaptureDelayCountdownController.shared.tick(timerID: timerID) }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func cancel() {
    guard isActive else { return }
    DiagnosticLogger.shared.log(.info, .capture, "Capture delay cancelled")
    onFinish = nil
    pendingCapture?.cancel()
    pendingCapture = nil
    tearDown()
  }

  private func tick(timerID: UUID) {
    guard self.timerID == timerID else { return }
    let didFinish = countdown.tick()
    model.remainingSeconds = countdown.remainingSeconds
    guard didFinish, let onFinish else { return }

    self.onFinish = nil
    tearDown()
    // Let the HUD disappear so it never ends up in the screenshot.
    let settleDelay = UInt64(hudDismissSettleDelay * 1_000_000_000)
    pendingCapture = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: settleDelay)
      guard let self, !Task.isCancelled else { return }
      self.pendingCapture = nil
      onFinish()
    }
  }

  private func tearDown() {
    timer?.invalidate()
    timer = nil
    timerID = nil
    removeKeyMonitors()
    panel?.orderOut(nil)
    overlays.forEach { $0.close() }
    overlays = []
  }

  // MARK: - Panel

  private func showPanel() {
    let panel = self.panel ?? makePanel()
    self.panel = panel

    let size = Self.panelSize(showsDetail: model.detail != nil)
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
    if let visibleFrame = screen?.visibleFrame {
      panel.setFrame(
        NSRect(
          x: visibleFrame.midX - size.width / 2,
          y: visibleFrame.maxY - size.height - 16,
          width: size.width,
          height: size.height
        ),
        display: false
      )
    } else {
      panel.setContentSize(size)
    }
    panel.orderFrontRegardless()
  }

  private static func panelSize(showsDetail: Bool) -> NSSize {
    NSSize(width: 110, height: 62)
  }

  private func makePanel() -> NSPanel {
    let size = Self.panelSize(showsDetail: false)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isFloatingPanel = true
    // Above menus, so the countdown stays visible over an open menu.
    panel.level = NSWindow.Level(rawValue: 2147483630)
    panel.identifier = NSUserInterfaceItemIdentifier("OwnShotCountdown")
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    CaptureChromeWindowRegistry.configure(panel, role: .captureOverlay)
    panel.contentView = FirstMouseHostingView(rootView: CaptureDelayCountdownView(model: model) { [weak self] in
      self?.cancel()
    })
    return panel
  }

  // MARK: - Esc to cancel

  private func installKeyMonitors() {
    // Global monitor covers the usual case (another app is frontmost); it only
    // delivers events when Snapzy has Accessibility permission. The local
    // monitor covers Snapzy itself being active.
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return }
      Task { @MainActor in self?.cancel() }
    }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53, self?.isActive == true else { return event }
      self?.cancel()
      return nil
    }
  }

  private func removeKeyMonitors() {
    if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
    if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    globalKeyMonitor = nil
    localKeyMonitor = nil
  }
}

// MARK: - HUD view

/// The panel never becomes key, so the first click must reach SwiftUI directly.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class CaptureDelayCountdownModel: ObservableObject {
  @Published var remainingSeconds = 0
  @Published var detail: String?
}

private struct CaptureDelayCountdownView: View {
  @ObservedObject var model: CaptureDelayCountdownModel
  let onCancel: () -> Void
  /// Как SelfTimerOverlay.cancelButton (FadingButton) в эталоне: на наведении
  /// вместо часов плавно появляется кнопка отмены.
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        timerGlyph
          .opacity(isHovered ? 0 : 1)
        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .help(L10n.ScreenCapture.captureDelayCancelHint)
        .accessibilityLabel("Cancel")
      }
      .frame(width: 26, height: 26)
      Text(verbatim: "\(model.remainingSeconds)")
        .font(.system(size: 32, weight: .regular))
        .monospacedDigit()
    }
    .foregroundStyle(.white)
    .offset(x: -6)
    .frame(width: 110, height: 62)
    .background(Color(.sRGB, red: 1, green: 79.0 / 255, blue: 67.0 / 255), in: Capsule())
    .overlay(
      Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 2)
    )
    .contentShape(Capsule())
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
    }
    .onTapGesture(perform: onCancel)
    .help(L10n.ScreenCapture.captureDelayCancelHint)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Timer: \(model.remainingSeconds)")
    .accessibilityAction { onCancel() }
    .accessibilityAddTraits(.isButton)
  }

  private var timerGlyph: some View {
    Canvas { context, _ in
      var ring = Path()
      ring.addArc(center: CGPoint(x: 13, y: 13), radius: 11,
        startAngle: .degrees(-90), endAngle: .degrees(210), clockwise: false)
      ring.move(to: CGPoint(x: 13, y: 2))
      ring.addLine(to: CGPoint(x: 13, y: 6))
      ring.move(to: CGPoint(x: 7, y: 9))
      ring.addLine(to: CGPoint(x: 13, y: 13))
      context.stroke(ring, with: .foreground,
        style: StrokeStyle(lineWidth: 3.3, lineCap: .round, lineJoin: .round))
    }
      .frame(width: 26, height: 26)
      .foregroundStyle(.white.opacity(0.4))
  }
}
