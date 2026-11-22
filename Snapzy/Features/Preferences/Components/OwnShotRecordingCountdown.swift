import AppKit
import SwiftUI
import Combine

@MainActor
final class OwnShotRecordingCountdown: ObservableObject {
  @Published private var remaining: Int
  /// Доля прошедшего отсчёта 0…1 для кольца прогресса, как progress у CountDownOverlay эталона.
  @Published private var progress: Double = 0
  private var cancelled = false
  private var onCancel: @MainActor () -> Void = {}

  private func cancel() {
    guard !cancelled else { return }
    cancelled = true
    onCancel()
  }

  private init(seconds: Int) { remaining = seconds }

  static func wait(
    seconds: Int,
    isCurrent: @escaping @MainActor () -> Bool,
    onCancel: @escaping @MainActor () -> Void = {}
  ) async -> Bool {
    guard isCurrent(), !Task.isCancelled else { return false }
    guard seconds > 0 else { return true }
    let model = OwnShotRecordingCountdown(seconds: seconds)
    model.onCancel = onCancel
    let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53 else { return event }
      model.cancel()
      return nil
    }
    let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53 else { return }
      Task { @MainActor in model.cancel() }
    }
    defer {
      if let localMonitor { NSEvent.removeMonitor(localMonitor) }
      if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 110, height: 62),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = CountdownHostingView(rootView: CountdownView(model: model))
    CaptureChromeWindowRegistry.configure(panel, role: .captureOverlay)
    if let frame = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame {
      panel.setFrameOrigin(CGPoint(x: frame.midX - 55, y: frame.maxY - 78))
    } else { panel.center() }
    panel.orderFrontRegardless()
    defer { panel.close() }
    for second in stride(from: seconds, through: 1, by: -1) {
      model.remaining = second
      // countdown.aif эталона длится ровно секунду, звучит на каждой цифре.
      SoundManager.play(.countdown)
      for tick in 0..<10 {
        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        guard isCurrent(), !Task.isCancelled, !model.cancelled else { return false }
        model.progress = Self.progress(seconds: seconds, remaining: second, tick: tick + 1)
      }
    }
    panel.orderOut(nil)
    do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return false }
    return isCurrent() && !Task.isCancelled && !model.cancelled
  }

  /// Прогресс после tick десятых долей секунды внутри секунды remaining.
  nonisolated static func progress(seconds: Int, remaining: Int, tick: Int) -> Double {
    guard seconds > 0 else { return 1 }
    let elapsed = Double(seconds - remaining) + Double(min(max(tick, 0), 10)) / 10
    return min(1, max(0, elapsed / Double(seconds)))
  }

  private struct CountdownView: View {
    @ObservedObject var model: OwnShotRecordingCountdown
    @State private var isHovering = false
    var body: some View {
      HStack(spacing: 14) {
        // При наведении иконка таймера становится кнопкой отмены (cancelButton эталона).
        Image(systemName: isHovering ? "xmark.circle.fill" : "timer")
          .font(.system(size: 25))
          .foregroundStyle(.white.opacity(isHovering ? 0.9 : 0.4))
          .accessibilityHidden(true)
        Text("\(model.remaining)").font(.system(size: 32)).monospacedDigit()
      }
      .foregroundStyle(.white)
      .frame(width: 110, height: 62)
      .background(Color(red: 1, green: 0.29, blue: 0.25), in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 2))
      .overlay(
        Capsule()
          .inset(by: 1)
          .trim(from: 0, to: model.progress)
          .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .animation(.linear(duration: 0.1), value: model.progress)
      )
      .onHover { isHovering = $0 }
      .accessibilityLabel("Recording starts in \(model.remaining) seconds")
      .contentShape(Capsule())
      .onTapGesture { model.cancel() }
      .accessibilityAction { model.cancel() }
      .accessibilityAddTraits(.isButton)
    }
  }
}

@MainActor
private final class CountdownHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
