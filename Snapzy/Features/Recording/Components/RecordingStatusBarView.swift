//
//  RecordingStatusBarView.swift
//  Snapzy
//
//  Status bar shown during active recording with timer and controls
//  Styled to match Apple's native macOS recording toolbar aesthetic
//
//  Стоп и таймер, пауза, перезапуск, удаление, ручка перетаскивания.
//

import AppKit
import SwiftUI

// MARK: - AppKit anchor reporter

/// A transparent AppKit node is used instead of a SwiftUI PreferenceKey because native Liquid
/// Glass can isolate preferences emitted from descendants of a glass control/container.
private final class RecordingToolbarAnchorReportingView: NSView {
  var onLayout: ((CGFloat) -> Void)?
  private var lastReportedCenterX: CGFloat?

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    reportAnchorPosition()
  }

  override func layout() {
    super.layout()
    reportAnchorPosition()
  }

  func reportAnchorPosition() {
    guard let contentView = window?.contentView else { return }
    guard bounds.width > 0, bounds.height > 0 else { return }
    let frameInContentView = convert(bounds, to: contentView)
    let centerX = frameInContentView.midX
    guard centerX.isFinite else { return }
    guard lastReportedCenterX.map({ abs($0 - centerX) > 0.01 }) ?? true else { return }

    lastReportedCenterX = centerX
    onLayout?(centerX)
  }
}

private struct RecordingToolbarAnchorReporter: NSViewRepresentable {
  let onLayout: (CGFloat) -> Void

  func makeNSView(context _: Context) -> RecordingToolbarAnchorReportingView {
    let view = RecordingToolbarAnchorReportingView()
    view.onLayout = onLayout
    return view
  }

  func updateNSView(_ nsView: RecordingToolbarAnchorReportingView, context _: Context) {
    nsView.onLayout = onLayout
    nsView.reportAnchorPosition()
  }
}

struct RecordingStatusBarView: View {
  @ObservedObject var recorder: ScreenRecordingManager
  @ObservedObject var audioLevelMeter: RecordingAudioLevelMeter
  @ObservedObject var annotationState: RecordingAnnotationState
  @ObservedObject var state: RecordingToolbarState
  let onDelete: () -> Void
  let onRestart: () -> Void
  let onStop: () -> Void

  /// Reports the center-X of the annotate button relative to the hosting window's content view.
  var onAnnotateButtonLayout: ((CGFloat) -> Void)?

  private var duration: String {
    Self.formattedDuration(seconds: recorder.elapsedSeconds)
  }

  nonisolated static func formattedDuration(seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private var annotationLabel: String {
    annotationState.isAnnotationEnabled
      ? L10n.RecordingToolbar.disableAnnotations : L10n.RecordingToolbar.enableAnnotations
  }

  var body: some View {
    HStack(spacing: 4) {
      Button(action: onStop) {
        HStack(spacing: 6) {
          RecordingStopGlyph()
          Text(duration)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .frame(minWidth: 40, alignment: .leading)
            .opacity(recorder.isPaused ? 0.5 : 1)
        }
        .foregroundStyle(Color.red)
        .padding(.horizontal, 2)
        .frame(height: 28)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.RecordingToolbar.stopRecordingAccessibility(duration))
      .accessibilityHint(L10n.RecordingToolbar.stopRecordingHint)

      divider

      iconButton(
        systemName: recorder.isPaused ? "play.circle" : "pause.circle",
        label: recorder.isPaused ? L10n.RecordingToolbar.resumeRecording : L10n.RecordingToolbar.pauseRecording
      ) {
        if !recorder.isPaused { SoundManager.play(.pause) }
        recorder.togglePause()
      }

      if state.outputMode != .gif {
        ZStack {
          iconButton(
            systemName: annotationState.isAnnotationEnabled
              ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
            label: annotationLabel
          ) { annotationState.isAnnotationEnabled.toggle() }
          anchorReporter
        }
        .frame(width: 28, height: 28)
      }

      divider

      iconButton(systemName: "arrow.counterclockwise",
        label: L10n.RecordingToolbar.restartRecording,
        resourceName: "recorderControlRestart", action: onRestart)

      iconButton(systemName: "trash",
        label: L10n.RecordingToolbar.deleteRecording,
        resourceName: "recorderControlTrash", action: onDelete)

      divider

      ZStack {
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.4))
        if state.outputMode == .gif { anchorReporter }
      }
      .frame(width: 18, height: 28)
      .contentShape(Rectangle())
      .contextMenu {
        Button(annotationLabel) { annotationState.isAnnotationEnabled.toggle() }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .environment(\.colorScheme, .dark)
    .background {
      if state.captureMicrophone && state.outputMode != .gif {
        RecordingWaveformView(
          level: audioLevelMeter.level,
          isActive: recorder.isRecording && !recorder.isPaused
        )
        .opacity(recorder.isPaused ? 0.35 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.RecordingToolbar.statusBarAccessibility)
  }

  private var divider: some View {
    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
      .padding(.horizontal, 4)
  }

  private var anchorReporter: some View {
    RecordingToolbarAnchorReporter { onAnnotateButtonLayout?($0) }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func iconButton(
    systemName: String, label: String, resourceName: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Group {
        if let resourceName {
          OwnShotIcons.image(resourceName).renderingMode(.template)
        } else {
          Image(systemName: systemName).font(.system(size: 18, weight: .regular))
        }
      }
      .foregroundStyle(.white.opacity(0.85))
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(NativeToolbarButtonStyle())
    .accessibilityLabel(label)
  }
}

#Preview {
  RecordingStatusBarView(
    recorder: ScreenRecordingManager.shared,
    audioLevelMeter: ScreenRecordingManager.shared.audioLevelMeter,
    annotationState: RecordingAnnotationState(),
    state: RecordingToolbarState(),
    onDelete: {},
    onRestart: {},
    onStop: {}
  )
  .padding()
}
