//
//  OwnShotRecordingOverlayOptionsSheets.swift
//  Snapzy
//
//  Sheet «Options…» у Highlight clicks и Show keystrokes в составе эталона:
//  поля сверху, нижняя панель с Done (и Preview у клавиш).
//

import AppKit
import SwiftUI

// MARK: - Общая раскладка листов

/// Размеры листов по AX эталона (live 062): 4 строки дают группу 150 pt, 5 строк – 188 pt,
/// превью – группа 380×160, лист Highlight 420×417, лист Keystrokes 420×286.
enum OverlayOptionsLayout {
  /// Высота содержимого строки. Строка grouped Form добавляет к ней 21 pt (последняя – 20),
  /// поэтому попапы 24 pt не растягивают строку до 45 pt, а шаг строк выходит 37–38 pt.
  static let rowContentHeight: CGFloat = 16.75
  /// Содержимое превью без внутренних отступов строки (10 pt сверху и снизу).
  static let previewHeight: CGFloat = 140
  static let clickSheetHeight: CGFloat = 417
  static let keystrokeSheetHeight: CGFloat = 286
  /// Ширина слайдера Size у эталона.
  static let sliderWidth: CGFloat = 198
}

/// Строка листа: высота строки не зависит от высоты контрола, как у эталона.
private struct OverlayOptionsRow<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    SettingRow(title: title, description: nil) {
      content()
        .frame(height: OverlayOptionsLayout.rowContentHeight)
    }
  }
}

/// Слайдер с подписью: без неё grouped Form сжимает слайдер до 110 pt, игнорируя frame.
private struct OverlayOptionsSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double? = nil

  init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
  }

  var body: some View {
    Group {
      if let step {
        Slider(value: $value, in: range, step: step) { Text(title) }
      } else {
        Slider(value: $value, in: range) { Text(title) }
      }
    }
    .labelsHidden()
    .frame(width: OverlayOptionsLayout.sliderWidth)
  }
}

// MARK: - Highlight clicks

struct OwnShotClickHighlightOptionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage(PreferencesKeys.mouseHighlightSize) private var size = 50.0
  @AppStorage(RecordingOverlayPreferenceKeys.clickStyle) private var style = RecordingClickStyle.outline.rawValue
  @AppStorage(RecordingOverlayPreferenceKeys.clickAnimate) private var animate = true
  @State private var color = RecordingOverlayOptions.clickColor().map(\.rawValue) ?? Self.customColorTag
  @State private var marks: [ClickPreviewMark] = []

  private static let customColorTag = "custom"

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          OverlayOptionsRow(title: L10n.RecordingParity.size) {
            OverlayOptionsSlider(
              title: L10n.RecordingParity.size,
              value: clampedSize,
              range: RecordingOverlayOptions.clickSizeRange
            )
          }
          OverlayOptionsRow(title: L10n.RecordingParity.color) {
            Picker(L10n.RecordingParity.color, selection: colorBinding) {
              ForEach(RecordingClickColor.allCases) { Text($0.title).tag($0.rawValue) }
              if color == Self.customColorTag {
                Divider()
                Text(L10n.RecordingParity.customColor).tag(Self.customColorTag)
              }
            }.labelsHidden().fixedSize()
          }
          OverlayOptionsRow(title: L10n.RecordingParity.style) {
            Picker(L10n.RecordingParity.style, selection: $style) {
              ForEach(RecordingClickStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }.labelsHidden().fixedSize()
          }
          OverlayOptionsRow(title: L10n.RecordingParity.animateClicks) {
            PreferencesToggle(L10n.RecordingParity.animateClicks, isOn: $animate)
          }
        }
        Section {
          previewArea
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      Divider()
      HStack {
        Spacer()
        Button(L10n.RecordingParity.done) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
    .frame(width: 420, height: OverlayOptionsLayout.clickSheetHeight)
  }

  /// Область «Click here to preview»: клик рисует эффект с текущими параметрами.
  private var previewArea: some View {
    ZStack {
      Text(L10n.RecordingParity.clickToPreview)
        .foregroundStyle(.secondary)
      ForEach(marks) { mark in
        ClickPreviewMarkView(
          mark: mark,
          diameter: CGFloat(RecordingOverlayOptions.clampedClickSize(size)),
          color: previewColor,
          style: RecordingClickStyle(rawValue: style) ?? .outline,
          animate: animate
        )
      }
    }
    .frame(maxWidth: .infinity, minHeight: OverlayOptionsLayout.previewHeight)
    .contentShape(Rectangle())
    .clipped()
    .gesture(SpatialTapGesture().onEnded { value in addMark(at: value.location) })
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(L10n.RecordingParity.clickToPreview)
  }

  private var clampedSize: Binding<Double> {
    Binding(get: { RecordingOverlayOptions.clampedClickSize(size) }, set: { size = $0 })
  }

  private var colorBinding: Binding<String> {
    Binding(get: { color }, set: { newValue in
      color = newValue
      guard newValue != Self.customColorTag else { return }
      UserDefaults.standard.set(newValue, forKey: RecordingOverlayPreferenceKeys.clickColor)
    })
  }

  private var previewColor: Color {
    Color(nsColor: MouseHighlightConfiguration().highlightColor)
  }

  private func addMark(at point: CGPoint) {
    let mark = ClickPreviewMark(point: point)
    marks.append(mark)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      marks.removeAll { $0.id == mark.id }
    }
  }
}

private struct ClickPreviewMark: Identifiable {
  let id = UUID()
  let point: CGPoint
}

/// Один клик в превью: расходящееся кольцо или, без анимации, затухающий круг.
private struct ClickPreviewMarkView: View {
  let mark: ClickPreviewMark
  let diameter: CGFloat
  let color: Color
  let style: RecordingClickStyle
  let animate: Bool
  @State private var expanded = false

  var body: some View {
    shape
      .frame(width: diameter, height: diameter)
      .scaleEffect(animate ? (expanded ? 1 : 0.15) : 0.72)
      .opacity(expanded ? 0 : 0.9)
      .position(mark.point)
      .allowsHitTesting(false)
      .onAppear {
        withAnimation(.easeOut(duration: animate ? MouseHighlightConfiguration.defaultAnimationDuration : 0.6)) {
          expanded = true
        }
      }
  }

  @ViewBuilder private var shape: some View {
    switch style {
    case .outline: Circle().stroke(color.opacity(0.8), lineWidth: MouseHighlightConfiguration.defaultRingWidth)
    case .filled: Circle().fill(color.opacity(0.5))
    }
  }
}

// MARK: - Show keystrokes

struct OwnShotKeystrokeOptionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage(RecordingOverlayPreferenceKeys.keystrokeAppearance)
  private var appearance = KeystrokeOverlayAppearance.dark.rawValue
  @AppStorage(PreferencesKeys.keystrokePosition)
  private var position = KeystrokeOverlayConfiguration.defaultPosition.rawValue
  @AppStorage(RecordingOverlayPreferenceKeys.keystrokeKeys)
  private var keys = KeystrokeOverlayKeysMode.commandOnly.rawValue
  @AppStorage(RecordingOverlayPreferenceKeys.keystrokeBlur) private var blur = true
  @State private var size = RecordingOverlayOptions.keystrokeSize()
  @State private var previewWindow: KeystrokeOverlayWindow?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          OverlayOptionsRow(title: L10n.RecordingParity.size) {
            OverlayOptionsSlider(
              title: L10n.RecordingParity.size,
              value: sizeBinding,
              range: RecordingOverlayOptions.keystrokeSizeRange,
              step: 9
            )
          }
          OverlayOptionsRow(title: L10n.RecordingParity.appearance) {
            Picker(L10n.RecordingParity.appearance, selection: $appearance) {
              ForEach(KeystrokeOverlayAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }.labelsHidden().fixedSize()
          }
          OverlayOptionsRow(title: L10n.RecordingParity.position) {
            Picker(L10n.RecordingParity.position, selection: $position) {
              ForEach(KeystrokeOverlayPosition.allCases) { Text($0.hyphenatedTitle).tag($0.rawValue) }
            }.labelsHidden().fixedSize()
          }
          OverlayOptionsRow(title: L10n.RecordingParity.keys) {
            Picker(L10n.RecordingParity.keys, selection: $keys) {
              ForEach(KeystrokeOverlayKeysMode.allCases) { Text($0.title).tag($0.rawValue) }
            }.labelsHidden().fixedSize()
          }
          OverlayOptionsRow(title: L10n.RecordingParity.blurBackground) {
            PreferencesToggle(L10n.RecordingParity.blurBackground, isOn: $blur)
          }
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      Divider()
      HStack {
        Button(L10n.RecordingParity.preview, action: showPreview)
        Spacer()
        Button(L10n.RecordingParity.done) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
    .frame(width: 420, height: OverlayOptionsLayout.keystrokeSheetHeight)
    .onDisappear(perform: closePreview)
  }

  private var sizeBinding: Binding<Double> {
    Binding(get: { size }, set: { newValue in
      size = RecordingOverlayOptions.clampedKeystrokeSize(newValue)
      UserDefaults.standard.set(size, forKey: RecordingOverlayPreferenceKeys.keystrokeSize)
    })
  }

  /// Preview показывает настоящий бейдж записи поверх экрана с окном настроек.
  private func showPreview() {
    closePreview()
    guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
    let window = KeystrokeOverlayWindow(recordingRect: screen.visibleFrame)
    window.orderFrontRegardless()
    window.showKeystroke("⌘ ⇧ 5")
    previewWindow = window
    let duration = KeystrokeOverlayConfiguration().displayDuration + 0.6
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard previewWindow === window else { return }
      closePreview()
    }
  }

  private func closePreview() {
    previewWindow?.orderOut(nil)
    previewWindow?.close()
    previewWindow = nil
  }
}
