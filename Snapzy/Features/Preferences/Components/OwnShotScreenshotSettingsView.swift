import SwiftUI

struct OwnShotScreenshotSettingsView: View {
  @AppStorage(PreferencesKeys.screenshotFormat) private var screenshotFormat = "png"
  @AppStorage("ownshot.capture.export.convertToSRGB") private var convertToSRGB = false
  @AppStorage("ownshot.capture.export.scaleRetinaTo1x") private var scaleRetinaTo1x = false
  @AppStorage("ownshot.capture.export.addPixelBorder") private var addPixelBorder = false
  @AppStorage(PreferencesKeys.screenshotDelayedCaptureSeconds)
  private var delayedCaptureSeconds = CaptureDelayOption.defaultValue.seconds
  @AppStorage(PreferencesKeys.screenshotShowCursor) private var showCursor = false
  @AppStorage(PreferencesKeys.screenshotFreezeArea) private var freezeScreen = false
  @AppStorage(PreferencesKeys.captureIncludeWindowShadow) private var includeWindowShadow = true
  @AppStorage(PreferencesKeys.screenshotShowMagnifierByDefault) private var showMagnifier = false
  @AppStorage(OwnShotScreenshotPreferenceKeys.windowBackground) private var windowBackground = "wallpaper"
  @AppStorage(OwnShotScreenshotPreferenceKeys.windowPadding)
  private var windowPadding = OwnShotWindowScreenshotOptions.defaultPadding
  @AppStorage(OwnShotScreenshotPreferenceKeys.crosshairMode) private var crosshairMode = OwnShotSelectionOverlayDefaults.crosshairMode.rawValue

  @State private var presets: [AnnotateCanvasPreset] = []
  @State private var selectedPresetRawValue = ""

  private let presetStore = AnnotateCanvasPresetStore.shared

  var body: some View {
    Form {
      Section {
        SettingRow(title: "File format", description: nil) {
          Picker("File format", selection: $screenshotFormat) {
            ForEach(ImageFormatOption.allCases, id: \.self) { option in
              // В эталоне форматы подписаны заглавными: PNG, JPEG, WEBP.
              Text(verbatim: option.rawValue.uppercased()).tag(option.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .settingsPopupRow()
        }
      } header: {
        Text("Output")
      }

      Section {
        SettingRow(title: "Convert to sRGB profile", description: nil) {
          PreferencesToggle("Convert to sRGB profile", isOn: $convertToSRGB)
        }
        SettingRow(title: "Scale Retina screenshots to 1x", description: nil) {
          PreferencesToggle("Scale Retina screenshots to 1x", isOn: $scaleRetinaTo1x)
        }
        SettingRow(title: "Add 1px border to all screenshots", description: nil) {
          PreferencesToggle("Add 1px border to all screenshots", isOn: $addPixelBorder)
        }
      }

      Section {
        VStack(alignment: .leading, spacing: 4) {
          SettingRow(title: "Background preset", description: nil) {
            Picker("Background preset", selection: presetSelection) {
              Text(L10n.Common.none).tag("")
              ForEach(presets) { preset in
                Text(preset.name).tag(preset.id.uuidString)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .settingsPopupRow()
          }
          Text("Apply Background Tool preset to all screenshots. You can create presets in Annotate.\nHold ⇧ Shift while capturing a screenshot to disable this option.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("Capture") {
        SettingRow(title: "Self-Timer interval", description: nil) {
          Picker("Self-Timer interval", selection: $delayedCaptureSeconds) {
            ForEach(CaptureDelayOption.allCases) { option in
              Text("\(option.seconds) Seconds").tag(option.seconds)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .settingsPopupRow()
        }
        SettingRow(
          title: "Show cursor on screenshots",
          description: "This works in Fullscreen or Self-Timer modes only.",
          descriptionStyle: .subtitle
        ) {
          PreferencesToggle("Show cursor on screenshots", isOn: $showCursor)
        }
        SettingRow(title: "Freeze screen when taking a screenshot", description: nil) {
          PreferencesToggle("Freeze screen when taking a screenshot", isOn: $freezeScreen)
        }
      }

      Section {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Background")
            Text("Hold ⇧ Shift while taking a screenshot to get a transparent background. You can customize the wallpaper in [wallpaper settings](ownshot://preferences/wallpaper).")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .environment(\.openURL, OpenURLAction { _ in
                PreferencesNavigationState.shared.selectedTab = .wallpaper
                return .handled
              })
          }
          Spacer(minLength: 0)
          windowBackgroundOption(.wallpaper, title: "With wallpaper")
          windowBackgroundOption(.transparent, title: "Transparent")
        }
        .padding(.vertical, 4)
        SettingRow(title: "Padding", description: nil) {
          VStack(spacing: 0) {
            Slider(value: $windowPadding, in: OwnShotWindowScreenshotOptions.paddingRange, step: 20)
              .accessibilityLabel("Window screenshot padding")
              .accessibilityValue("\(Int(windowPadding)) points")
            HStack {
              ForEach(0..<7) { index in
                if index > 0 { Spacer() }
                Circle().fill(.secondary.opacity(0.5)).frame(width: 2, height: 2)
              }
            }
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
          }
          .frame(width: 170)
        }
        SettingRow(title: "Capture window shadow", description: nil) {
          PreferencesToggle("Capture window shadow", isOn: $includeWindowShadow)
        }
      } header: {
        Text("Window Screenshots")
      } footer: {
        HStack {
          Spacer()
          Button("Reset Defaults") {
            windowBackground = "wallpaper"
            windowPadding = OwnShotWindowScreenshotOptions.defaultPadding
            includeWindowShadow = WindowShadowPreference.defaultIncludeShadow
          }
          .buttonStyle(.bordered)
        }
        .padding(.top, 4)
      }

      Section("Crosshair") {
        SettingRow(title: "Crosshair Mode", description: nil) {
          Picker("Crosshair Mode", selection: $crosshairMode) {
            ForEach(OwnShotCrosshairMode.allCases, id: \.self) { mode in
              Text(mode.title).tag(mode.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .settingsPopupRow()
        }
        SettingRow(title: "Show magnifier", description: nil) {
          PreferencesToggle("Show magnifier", isOn: $showMagnifier)
            .disabled(crosshairMode == OwnShotCrosshairMode.disabled.rawValue)
        }
        if crosshairMode == OwnShotCrosshairMode.disabled.rawValue {
          Text("To enable magnifier, you must enable Crosshair Mode first.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      // Промоблок PixelSnap под Crosshair, как у эталона. Логотип – SF Symbol, не ассет.
      Section {
        OwnShotPixelSnapPromo()
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: reloadPresets)
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      reloadPresets()
    }
  }

  private func windowBackgroundOption(_ background: OwnShotWindowScreenshotBackground, title: String) -> some View {
    Button {
      windowBackground = background.rawValue
    } label: {
      VStack(spacing: 6) {
        OwnShotScreenshotWindowPreview(wallpaper: background == .wallpaper)
          .frame(width: 80, height: 60)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .padding(2)
          .overlay {
            RoundedRectangle(cornerRadius: 10)
              .strokeBorder(windowBackground == background.rawValue ? Color.accentColor : .clear, lineWidth: 2)
          }
        Text(title)
          .foregroundStyle(windowBackground == background.rawValue ? .primary : .secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(windowBackground == background.rawValue ? .isSelected : [])
  }

  private var presetSelection: Binding<String> {
    Binding(
      get: { selectedPresetRawValue },
      set: { rawValue in
        selectedPresetRawValue = rawValue
        guard !rawValue.isEmpty else {
          presetStore.clearDefaultPresetId()
          return
        }
        guard let id = UUID(uuidString: rawValue),
              presets.contains(where: { $0.id == id }) else {
          reloadPresets()
          return
        }
        presetStore.saveDefaultPresetId(id)
      }
    )
  }

  private func reloadPresets() {
    let loadedPresets = presetStore.loadPresets()
    let selectedID = presetStore.loadDefaultPresetId(validating: loadedPresets)
    presets = loadedPresets
    selectedPresetRawValue = selectedID?.uuidString ?? ""
  }
}

private struct OwnShotScreenshotWindowPreview: View {
  let wallpaper: Bool

  private var wallpaperImage: NSImage? {
    let image = OwnShotCaptureWallpaper.load()
      ?? NSScreen.main.flatMap { OwnShotCaptureWallpaper.loadDesktop(screen: $0) }
    return image.map { NSImage(cgImage: $0, size: .zero) }
  }

  var body: some View {
    ZStack {
      if wallpaper, let image = wallpaperImage {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Canvas { context, size in
          for row in 0..<8 {
            for column in 0..<10 {
              let rect = CGRect(x: column * 8, y: row * 8, width: 8, height: 8)
              context.fill(Path(rect), with: .color((row + column).isMultiple(of: 2) ? .gray.opacity(0.5) : .gray.opacity(0.3)))
            }
          }
        }
      }
      VStack(spacing: 0) {
        HStack(spacing: 3) {
          ForEach([Color.red, .yellow, .green], id: \.self) { color in
            Circle().fill(color).frame(width: 4, height: 4)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 10)
        .background(.white)
        Rectangle().fill(Color(white: 0.95))
      }
      .frame(width: 50, height: 36)
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
  }
}

struct OwnShotPixelSnapPromo: View {
  static let url = URL(string: "https://pixelsnap.com")!

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "ruler")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.SettingsParity.pixelSnapTitle).font(.system(size: 13, weight: .semibold))
        Text(L10n.SettingsParity.pixelSnapBody)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Link(L10n.SettingsParity.learnMore, destination: Self.url)
          .font(.system(size: 11))
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }
}
