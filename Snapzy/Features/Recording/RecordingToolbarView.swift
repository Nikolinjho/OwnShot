import SwiftUI

struct RecordingToolbarView: View {
  @ObservedObject var state: RecordingToolbarState
  let onRecord: () -> Void
  let onCapture: () -> Void
  let onCancel: () -> Void

  var body: some View {
    // Зазор между карточками – 10 pt (R29, ref-record-options-panel.png y186..205).
    VStack(spacing: OwnShotHUDStyle.panelSpacing) {
      controls
      VStack(spacing: 0) {
        recordButton(.gif)
        Rectangle().fill(separatorColor).frame(height: OwnShotHUDStyle.edgeWidth)
        recordButton(.video)
      }
      .modifier(RecordingCaptureSurface())
      Button { _ = OwnShotFeaturePolicy.allow(.studio) } label: {
        HStack(spacing: 10) {
          Image(systemName: "movieclapper.fill").font(.system(size: 18))
          Text("Record in Studio Mode").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(valueColor)
          Spacer(minLength: 0)
          // recorderInfoButton эталона, 15×15 pt.
          OwnShotSymbols.image("recorderInfoButton").frame(width: 15, height: 15)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background {
        RoundedRectangle(cornerRadius: 18)
          .stroke(Color(red: 0.6, green: 0.15, blue: 0.45).opacity(0.35), lineWidth: 3)
          .blur(radius: 7)
          .offset(x: 2, y: 2)
      }
      .modifier(RecordingCaptureSurface())
      .overlay(RoundedRectangle(cornerRadius: 18).stroke(.purple.opacity(0.12), lineWidth: 1))
    }
    .foregroundStyle(.white)
    // Карточки HUD всегда тёмные (R28): системные цвета внутри берутся из тёмной темы.
    .environment(\.colorScheme, .dark)
    .frame(width: 254)
    .padding(.horizontal, 8.5)
    .padding(.top, 11.5)
    .padding(.bottom, 5.5)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.RecordingToolbar.toolbarAccessibility)
    .onExitCommand(perform: onCancel)
  }

  private var controls: some View {
    ZStack(alignment: .topLeading) {
      ToolbarOptionsMenu(state: state, iconOnly: true)
        .frame(width: 50, height: 40)
        .position(x: 25, y: 20)
      OwnShotCaptureSizeView(
        rect: state.selectionRect,
        onResize: { state.onResizeSelection?($0, $1, $2) },
        onAspectRatio: { state.onAspectRatioChanged?($0) },
        ratioGlyph: AnyView(RecordingRatioGlyph())
      )
      .position(x: 127, y: 20)
      .disabled(state.isPreparingToRecord)
      Button {
        state.captureMode = .area
        state.onCaptureModeChanged?(.area)
      } label: {
        // Кнопка повторного выделения – вторичный значок #949393 (R31).
        Image(systemName: "crop").font(.system(size: 16)).frame(width: 32, height: 32)
          .foregroundStyle(Color(nsColor: OwnShotHUDStyle.inactiveForeground))
      }
      .buttonStyle(.plain)
      .help("Select Area")
      .accessibilityLabel("Select Area")
      .contextMenu {
        Button("Select Area") { state.captureMode = .area; state.onCaptureModeChanged?(.area) }
        Button("Select Window") { state.captureMode = .application; state.onCaptureModeChanged?(.application) }
        Button("Fullscreen") { state.captureMode = .fullscreen; state.onCaptureModeChanged?(.fullscreen) }
        Divider()
        Button("Capture Screenshot", action: onCapture)
        Button("Cancel", action: onCancel)
      }
      .frame(width: 40, height: 40)
      .position(x: 229, y: 20)
      Rectangle().fill(separatorColor).frame(height: OwnShotHUDStyle.edgeWidth).position(x: 127, y: 40.5)
      separator(x: 50.5, y: 20, height: 40)
      separator(x: 203.5, y: 20, height: 40)
      HStack(spacing: 0) {
        ToolbarMicToggleButton(state: state).frame(width: 50.8, height: 41)
          .overlay(alignment: .bottom) {
            RecordingSetupVUMeterView(meter: state.audioMonitor.microphoneMeter, isEnabled: state.captureMicrophone)
              .padding(.bottom, 5)
          }
        ToolbarSystemAudioToggleButton(state: state).frame(width: 50.8, height: 41)
          .overlay(alignment: .bottom) {
            RecordingSetupVUMeterView(meter: state.audioMonitor.systemAudioMeter, isEnabled: state.captureAudio)
              .padding(.bottom, 5)
          }
        RecordingToolbarCameraToggleButton(state: state).frame(width: 50.8, height: 41)
        captureToggle("recorderHighlightCursor", label: "Highlight Clicks", value: $state.highlightClicks, preferenceKey: PreferencesKeys.recordingHighlightClicks)
        captureToggle("recorderShowKeystrokes", label: "Show Keystrokes", value: $state.showKeystrokes, preferenceKey: PreferencesKeys.recordingShowKeystrokes)
      }.position(x: 127, y: 61.5)
      ForEach(1..<5) { index in separator(x: CGFloat(index) * 50.8, y: 61.5, height: 41) }
    }
    .frame(width: 254, height: 82)
    // Утопленная ячейка в нижнем ряду не должна выходить за скругление карточки.
    .clipShape(RoundedRectangle(cornerRadius: RecordingCaptureSurface.cornerRadius, style: .continuous))
    .modifier(RecordingCaptureSurface())
  }

  /// Разделители того же цвета, что внутренняя кромка карточки, #333231 (R07).
  private var separatorColor: Color { Color(nsColor: OwnShotHUDStyle.innerEdge(.recording)) }
  private var valueColor: Color { Color(nsColor: OwnShotHUDStyle.valueForeground) }

  private func separator(x: CGFloat, y: CGFloat, height: CGFloat) -> some View {
    Rectangle().fill(separatorColor).frame(width: OwnShotHUDStyle.edgeWidth, height: height).position(x: x, y: y)
  }

  /// resourceName – глиф эталона: recorderHighlightCursor 17×17, recorderShowKeystrokes 18×18 pt,
  /// отметка включения recorderTick 7×6 pt.
  private func captureToggle(_ resourceName: String, label: String, value: Binding<Bool>, preferenceKey: String) -> some View {
    Button {
      value.wrappedValue.toggle()
      UserDefaults.standard.set(value.wrappedValue, forKey: preferenceKey)
    } label: {
      VStack(spacing: 2) {
        OwnShotSymbols.image(resourceName).renderingMode(.template)
        if value.wrappedValue { OwnShotSymbols.image("recorderTick").renderingMode(.template) }
      }
      .foregroundStyle(Color(nsColor: Self.toggleForeground(isOn: value.wrappedValue)))
      .frame(width: 50.8, height: 41)
      // Включённая ячейка утоплена во всю ширину между разделителями: #201F1E (R30).
      .background(Color(nsColor: Self.toggleBackground(isOn: value.wrappedValue)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityValue(value.wrappedValue ? "On" : "Off")
  }

  /// Включённая ячейка – белый значок с галочкой, выключенная – #949393 (R31).
  static func toggleForeground(isOn: Bool) -> NSColor {
    isOn ? OwnShotHUDStyle.primaryForeground : OwnShotHUDStyle.inactiveForeground
  }

  /// Фон ячейки: включённая утоплена (#201F1E), выключенная прозрачна (R30).
  static func toggleBackground(isOn: Bool) -> NSColor {
    isOn ? OwnShotHUDStyle.recessed(.recording) : .clear
  }

  private func recordButton(_ mode: RecordingOutputMode) -> some View {
    Button { record(mode) } label: {
      HStack(spacing: 10) {
        // Глифы эталона: цветной recorderGifButton 19×12 pt и recorderVideoButton 19×10 pt.
        if mode == .gif {
          OwnShotSymbols.image("recorderGifButton").frame(width: 20)
        } else {
          OwnShotSymbols.image("recorderVideoButton").renderingMode(.template).frame(width: 20)
        }
        Text(mode == .gif ? "Record GIF" : "Record Video")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(valueColor)
        Spacer()
        Text(mode == .gif ? "⌥↩" : "↩").font(.system(size: 18))
          .foregroundStyle(Color(nsColor: OwnShotHUDStyle.secondaryForeground))
      }
      .padding(.horizontal, 14)
      .frame(height: 40.5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.return, modifiers: mode == .gif ? .option : [])
    .disabled(state.isPreparingToRecord)
  }

  private func record(_ mode: RecordingOutputMode) {
    guard !state.isPreparingToRecord else { return }
    state.outputMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: PreferencesKeys.recordingOutputMode)
    onRecord()
  }
}

/// Карточка записи: непрозрачная #282726 с двойной кромкой (R28, R07).
private struct RecordingCaptureSurface: ViewModifier {
  static let cornerRadius: CGFloat = 18

  func body(content: Content) -> some View {
    content.modifier(OwnShotHUDPanelSurface(surface: .recording, cornerRadius: Self.cornerRadius))
  }
}
