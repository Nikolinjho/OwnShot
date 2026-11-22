import AppKit
import AVFoundation
import ImageIO
import SwiftUI

struct VideoEditorGIFPreview: View {
  @ObservedObject var state: VideoEditorState
  @State private var isPlaying = true
  @State private var previewFrame = 0
  @State private var trimGesture: TrimGesture?

  private struct TrimGesture {
    let isStart: Bool
    let previous: CMTime
  }

  private struct Playback: Equatable {
    let frames: ClosedRange<Int>?
    let isPlaying: Bool
  }

  private var playback: Playback {
    Playback(frames: state.gifSelectedFrames, isPlaying: isPlaying && !state.isExporting)
  }

  var body: some View {
    VStack(spacing: 12) {
      GIFPreviewFrameView(url: state.editingSourceURL, index: visibleFrame)
        .frame(minHeight: 190)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)

      if let frames = playback.frames {
        VStack(spacing: 6) {
          HStack {
            Button {
              isPlaying.toggle()
            } label: {
              Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 19)
            }
            .help(isPlaying ? L10n.VideoEditorGIFTrim.pause : L10n.VideoEditorGIFTrim.play)
            .accessibilityLabel(isPlaying ? L10n.VideoEditorGIFTrim.pause : L10n.VideoEditorGIFTrim.play)
            .keyboardShortcut(.space, modifiers: [])

            Text("\(state.trimmedDuration.seconds, specifier: "%.2f") s")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Spacer()
            Text(L10n.VideoEditorGIFTrim.frames(frames.count))
              .foregroundStyle(.secondary)
          }

          trimSlider(frames, isStart: true)
          trimSlider(frames, isStart: false)
        }
        .padding(.horizontal, 20)
        .disabled(state.isExporting)
      }
    }
    .task(id: playback) {
      guard let frames = playback.frames else { return }
      if !frames.contains(previewFrame) { previewFrame = frames.lowerBound }
      guard playback.isPlaying, frames.count > 1 else { return }
      while !Task.isCancelled {
        let delay = state.gifFrameOffsets[previewFrame + 1] - state.gifFrameOffsets[previewFrame]
        do {
          try await Task.sleep(for: .seconds(delay))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        previewFrame = previewFrame < frames.upperBound ? previewFrame + 1 : frames.lowerBound
      }
    }
  }

  private var visibleFrame: Int {
    guard let frames = playback.frames else { return 0 }
    return min(max(previewFrame, frames.lowerBound), frames.upperBound)
  }

  private func trimSlider(_ frames: ClosedRange<Int>, isStart: Bool) -> some View {
    let label = isStart ? L10n.VideoEditorGIFTrim.start : L10n.VideoEditorGIFTrim.end
    let time = isStart ? state.trimStart.seconds : state.trimEnd.seconds
    let value = Binding(
      get: {
        let current = state.gifSelectedFrames ?? frames
        return Double(isStart ? current.lowerBound : current.upperBound)
      },
      set: { proposed in
        isPlaying = false
        state.setGIFTrimFrame(Int(proposed), isStart: isStart, recordUndo: trimGesture == nil)
        if let selected = state.gifSelectedFrames {
          previewFrame = isStart ? selected.lowerBound : selected.upperBound
        }
      }
    )

    return HStack(spacing: 10) {
      Text(label)
        .font(.caption)
        .frame(minWidth: 65, alignment: .leading)
        .accessibilityHidden(true)
      Slider(value: value, in: 0...Double(max(1, state.gifFrameCount - 1)), step: 1) { editing in
        if editing {
          isPlaying = false
          trimGesture = TrimGesture(isStart: isStart, previous: isStart ? state.trimStart : state.trimEnd)
        } else if let gesture = trimGesture {
          trimGesture = nil
          state.finishGIFTrimGesture(isStart: gesture.isStart, previous: gesture.previous)
        }
      }
      .disabled(state.gifFrameCount < 2)
      .accessibilityLabel(label)
      .accessibilityValue(time.formatted(.number.precision(.fractionLength(2))))
      Text(time, format: .number.precision(.fractionLength(2)))
        .font(.caption.monospacedDigit())
        .frame(minWidth: 45, alignment: .trailing)
        .accessibilityHidden(true)
    }
  }
}

private struct GIFPreviewFrameView: NSViewRepresentable {
  let url: URL
  let index: Int

  final class Coordinator {
    var url: URL?
    var source: CGImageSource?
    var index: Int?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSImageView {
    let imageView = NSImageView()
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    return imageView
  }

  func updateNSView(_ view: NSImageView, context: Context) {
    let reader = context.coordinator
    if reader.url != url {
      reader.url = url
      reader.source = SandboxFileAccessManager.shared.withScopedAccess(to: url) {
        CGImageSourceCreateWithURL(url as CFURL, nil)
      }
      reader.index = nil
    }
    guard reader.index != index else { return }
    reader.index = index

    let image = reader.source.flatMap { CGImageSourceCreateImageAtIndex($0, index, nil) }
    view.image = image.map { NSImage(cgImage: $0, size: .zero) }
  }
}

extension L10n {
  enum VideoEditorGIFTrim {
    static func frames(_ count: Int) -> String {
      if count == 1 {
        return L10n.string("video-editor.gif-trim.one-frame", defaultValue: "1 frame", comment: "One selected GIF frame")
      }
      return L10n.VideoEditor.framesCount(count)
    }

    static var start: String {
      L10n.string("video-editor.gif-trim.start", defaultValue: "Start", comment: "GIF trim start frame")
    }

    static var end: String {
      L10n.string("video-editor.gif-trim.end", defaultValue: "End", comment: "GIF trim end frame")
    }

    static var play: String {
      L10n.string("video-editor.gif-trim.play", defaultValue: "Play GIF", comment: "Play the selected GIF frames")
    }

    static var pause: String {
      L10n.string("video-editor.gif-trim.pause", defaultValue: "Pause GIF", comment: "Pause GIF preview")
    }

    static var saveTitle: String {
      L10n.string("video-editor.gif-trim.save-title", defaultValue: "Trim GIF", comment: "Title for saving a trimmed GIF")
    }

    static var saveEditsTitle: String {
      L10n.string("video-editor.gif-trim.save-edits-title", defaultValue: "Save GIF", comment: "Title for saving an edited GIF")
    }

    static func saveEditsMessage(_ name: String) -> String {
      L10n.format("video-editor.gif-trim.save-edits-message", defaultValue: "Save changes to %@?",
        comment: "Confirmation before replacing or copying an edited GIF", name)
    }

    static var exporting: String {
      L10n.string("video-editor.gif-trim.exporting", defaultValue: "Trimming GIF…", comment: "Progress while trimming GIF frames")
    }

    static func saveMessage(_ name: String) -> String {
      L10n.format("video-editor.gif-trim.save-message", defaultValue: "Save the selected part of %@ as a GIF?",
        comment: "Confirmation before replacing or copying a trimmed GIF", name)
    }
  }
}
