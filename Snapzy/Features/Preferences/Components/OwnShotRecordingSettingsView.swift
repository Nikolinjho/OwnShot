import AVFoundation
import SwiftUI

struct OwnShotRecordingSettingsView: View {
  @AppStorage(PreferencesKeys.recordingHoverBarVisible) private var showControls = true
  @AppStorage(PreferencesKeys.recordingRememberLastArea) private var rememberSelection = true
  @AppStorage(PreferencesKeys.recordingShowTimeOnMenuBar) private var showTime = true
  @AppStorage(PreferencesKeys.recordingDimNonSelectedArea) private var dimScreen = true
  @AppStorage(PreferencesKeys.recordingShowCursor) private var showCursor = true
  @AppStorage(PreferencesKeys.recordingHighlightClicks) private var highlightClicks = false
  @AppStorage(PreferencesKeys.recordingShowKeystrokes) private var showKeystrokes = false
  @AppStorage(PreferencesKeys.recordingFPS) private var fps = 30
  @AppStorage(PreferencesKeys.recordingMaxResolution) private var maxResolution = "auto"
  @AppStorage(PreferencesKeys.recordingCaptureAudio) private var systemAudio = true
  @AppStorage(PreferencesKeys.recordingFormat) private var format = "mov"
  @AppStorage(PreferencesKeys.recordingQuality) private var quality = "high"
  @AppStorage(PreferencesKeys.recordingCaptureMicrophone) private var microphone = false
  @AppStorage(PreferencesKeys.recordingMicrophoneDeviceID)
  private var microphoneDeviceID = RecordingMicrophoneDevice.systemDefaultID
  @AppStorage(OwnShotRecordingPreferenceKeys.showCountdown) private var showCountdown = false
  @AppStorage(OwnShotRecordingPreferenceKeys.doNotDisturb) private var doNotDisturb = false
  @AppStorage(OwnShotRecordingPreferenceKeys.scaleRetina) private var scaleRetina = false
  @AppStorage(OwnShotRecordingPreferenceKeys.mono) private var mono = false
  @AppStorage(OwnShotRecordingPreferenceKeys.separateTracks) private var separateTracks = false
  @AppStorage(OwnShotRecordingPreferenceKeys.gifFPS) private var gifFPS = 15
  @AppStorage(OwnShotRecordingPreferenceKeys.gifWidth) private var gifWidth = 800
  @AppStorage(OwnShotRecordingPreferenceKeys.gifOptimize) private var gifOptimize = true
  @AppStorage(OwnShotRecordingPreferenceKeys.gifQuality) private var gifQuality = 1.0
  @State private var showClickOptions = false
  @State private var showKeyOptions = false
  @State private var showRecordingOptions = false
  @State private var showMicrophonePermissionAlert = false
  @State private var microphoneDevices: [RecordingMicrophoneDevice] = []
  @State private var showFocusSetupAlert = false
  @State private var showFocusInstallPrompt = false

  var body: some View {
    Form {
      Section("General") {
        toggleRow("Show controls while recording", isOn: $showControls)
        toggleRow("Remember last selection", isOn: $rememberSelection)
        toggleRow("Display recording time in menu bar", isOn: $showTime)
        toggleRow("Dim screen while recording", isOn: $dimScreen)
        toggleRow("Show countdown", isOn: $showCountdown)
        // Как у эталона: только переключатель. Команды Shortcuts предлагаются при включении.
        SettingRow(title: "\"Do Not Disturb\" while recording", description: nil) {
          PreferencesToggle("Do Not Disturb while recording", isOn: doNotDisturbBinding)
        }
      }
      Section("Cursor") {
        toggleRow("Show cursor", isOn: $showCursor)
        SettingRow(title: "Highlight clicks", description: nil) {
          Button("Options…") { showClickOptions = true }
            .sheet(isPresented: $showClickOptions) { OwnShotClickHighlightOptionsSheet() }
          PreferencesToggle("Highlight clicks", isOn: $highlightClicks)
        }
      }
      Section("Keystrokes") {
        SettingRow(title: "Show keystrokes", description: nil) {
          Button("Options…") { showKeyOptions = true }
            .sheet(isPresented: $showKeyOptions) { OwnShotKeystrokeOptionsSheet() }
          PreferencesToggle("Show keystrokes", isOn: $showKeystrokes)
        }
      }
      Section("Video") {
        SettingRow(title: "Frame rate", description: nil) {
          Picker("Video frame rate", selection: $fps) {
            ForEach(OwnShotRecordingPreferences.videoFrameRates, id: \.self) { rate in
              Text("\(rate) fps").tag(rate)
            }
          }.labelsHidden().settingsPopupRow()
        }
        SettingRow(title: "Max resolution",
                   description: "Set maximum resolution to reduce file size and upload time.",
                   descriptionStyle: .subtitle) {
          // Auto сохраняет наше ограничение совместимости; Original хранит native.
          Picker("Max resolution", selection: $maxResolution) {
            Text("Auto").tag(RecordingMaxResolution.auto.rawValue)
            Text("Original").tag(RecordingMaxResolution.native.rawValue)
            Divider()
            ForEach(RecordingMaxResolution.allCases.filter { $0.box != nil }, id: \.self) { resolution in
              Text(resolution.displayName).tag(resolution.rawValue)
            }
          }.labelsHidden().settingsPopupRow()
        }
        toggleRow("Scale Retina videos to 1x", isOn: $scaleRetina)
      }
      Section("Audio") {
        toggleRow("Record audio in mono", isOn: $mono)
        SettingRow(title: "Record system audio",
                   description: "Enable this option to record sound that comes from other applications.",
                   descriptionStyle: .subtitle) {
          PreferencesToggle("Record system audio", isOn: $systemAudio)
        }
        SettingRow(title: "Audio tracks",
                   description: "Choose separate tracks to edit the microphone and system audio independently in video editing software.",
                   descriptionStyle: .subtitle) {
          Picker("Audio tracks", selection: $separateTracks) {
            Text("Single track").tag(false)
            Text("Separate tracks").tag(true)
          }.labelsHidden().settingsPopupRow()
        }
      }
      Section("GIF") {
        SettingRow(title: "Frame rate", description: nil) {
          Picker("GIF frame rate", selection: $gifFPS) {
            ForEach(OwnShotRecordingPreferences.gifFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
          }.labelsHidden().settingsPopupRow()
        }
        SettingRow(title: "Resolution", description: nil) {
          Picker("GIF resolution", selection: $gifWidth) {
            ForEach(OwnShotRecordingPreferences.gifWidths, id: \.self) { width in
              Text(gifWidthTitle(width)).tag(width)
            }
          }.labelsHidden().settingsPopupRow()
        }
        toggleRow("Optimize GIFs", isOn: $gifOptimize)
        SettingRow(title: "Quality", description: nil) {
          OwnShotGIFQualityControl(quality: $gifQuality)
        }
      }
      Section {
        HStack {
          Spacer()
          Button("Recording options…") { showRecordingOptions = true }
            .popover(isPresented: $showRecordingOptions) { recordingOptions }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      refreshMicrophoneDevices()
      normalizeGIFSelection()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshMicrophoneDevices()
    }
    .alert(L10n.RecordingParity.microphoneNoAccessTitle, isPresented: $showMicrophonePermissionAlert) {
      Button(L10n.Common.openSystemSettings) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(url)
        }
      }
      Button(L10n.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.RecordingParity.microphoneNoAccessMessage)
    }
    .alert(L10n.RecordingParity.focusSetupTitle, isPresented: $showFocusInstallPrompt) {
      Button(L10n.RecordingParity.focusSetupButton) { openFocusShortcuts() }
      Button(L10n.Common.cancel, role: .cancel) { doNotDisturb = false }
    } message: {
      Text(L10n.RecordingParity.focusSetupMessage)
    }
    .alert("Focus setup unavailable", isPresented: $showFocusSetupAlert) {
      Button(L10n.Common.ok) {}
    } message: {
      Text("The Focus shortcuts could not be opened. Reinstall OwnShot and try again.")
    }
  }

  /// Включение проверяет команды Shortcuts и при нехватке предлагает Set Up….
  private var doNotDisturbBinding: Binding<Bool> {
    Binding(get: { doNotDisturb }, set: { enabled in
      doNotDisturb = enabled
      guard enabled else { return }
      Task {
        guard let output = await RecordingFocusSetup.listInstalledShortcuts() else { return }
        if !RecordingFocusSetup.missingShortcuts(inListOutput: output).isEmpty {
          showFocusInstallPrompt = true
        }
      }
    })
  }

  private func openFocusShortcuts() {
    let names = [RecordingFocusShortcut.status, .on, .off]
    let urls = names.compactMap { shortcut in
      Bundle.main.url(forResource: shortcut.rawValue, withExtension: "shortcut", subdirectory: "FocusShortcuts")
        ?? Bundle.main.url(forResource: shortcut.rawValue, withExtension: "shortcut")
    }
    guard urls.count == names.count else {
      showFocusSetupAlert = true
      return
    }
    for url in urls {
      if !NSWorkspace.shared.open(url) { showFocusSetupAlert = true }
    }
  }

  private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
    SettingRow(title: title, description: nil) {
      PreferencesToggle(title, isOn: isOn)
    }
  }


  private func gifWidthTitle(_ width: Int) -> String {
    if width == OwnShotRecordingPreferences.gifOriginalWidth { return "Original" }
    return width == OwnShotRecordingPreferences.defaultGIFWidth ? "\(width) x auto (default)" : "\(width) x auto"
  }

  /// Старые значения GIF (24/48 fps, 400/600/1000/1600/1920 px) переводятся в пункты эталона.
  private func normalizeGIFSelection() {
    let fps = OwnShotRecordingPreferences.normalizedGIFFPS(gifFPS)
    if fps != gifFPS { gifFPS = fps }
    let width = OwnShotRecordingPreferences.normalizedGIFWidth(gifWidth)
    if width != gifWidth { gifWidth = width }
  }

  private var recordingOptions: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Recording options").font(.headline)
      SettingRow(title: "Video format", description: nil) {
        Picker("Video format", selection: $format) {
          Text("MOV").tag("mov")
          Text("MP4").tag("mp4")
        }.labelsHidden()
      }
      SettingRow(title: "Video quality", description: nil) {
        Picker("Video quality", selection: $quality) {
          ForEach(VideoQuality.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
        }.labelsHidden()
      }
      SettingRow(title: "Resolution limit", description: "Auto limits resolution for browser playback. Original keeps source pixels.", descriptionStyle: .subtitle) {
        Picker("Resolution limit", selection: $maxResolution) {
          Text("Original").tag("native")
          Text("Auto (browser compatible)").tag("auto")
          ForEach(RecordingMaxResolution.allCases.filter { $0.box != nil }, id: \.self) {
            Text($0.displayName).tag($0.rawValue)
          }
        }.labelsHidden()
      }
      toggleRow("Microphone", isOn: Binding(get: { microphone }, set: { enabled in
        if enabled { enableMicrophone() } else { microphone = false }
      }))
      SettingRow(title: "Microphone input", description: nil) {
        Picker("Microphone input", selection: $microphoneDeviceID) {
          ForEach(microphoneDevices) { Text($0.displayName).tag($0.id) }
        }.labelsHidden().frame(maxWidth: 220)
      }
    }.padding(20).frame(width: 420)
  }

  private func refreshMicrophoneDevices() {
    microphoneDevices = RecordingMicrophoneDeviceProvider.availableDevices(selectedDeviceID: microphoneDeviceID)
  }

  private func enableMicrophone() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
      Task {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
          if granted { microphone = true } else { showMicrophonePermissionAlert = true }
        }
      }
    case .authorized:
      microphone = true
    case .denied, .restricted:
      showMicrophonePermissionAlert = true
    @unknown default:
      microphone = true
    }
  }
}

struct OwnShotGIFQualityControl: View {
  @Binding var quality: Double

  var body: some View {
    let percentage = OwnShotRecordingPreferences.percentageBinding($quality)
    HStack(spacing: 8) {
      Button("Low") { percentage.wrappedValue = 0 }
        .controlSize(.small)
      Slider(value: percentage, in: 0...100)
        .frame(width: 140)
        .accessibilityLabel("GIF quality")
      Button("High") { percentage.wrappedValue = 100 }
        .controlSize(.small)
    }
    .buttonStyle(.bordered)
  }
}
