//
//  PreferencesCaptureSettingsView.swift
//  Snapzy
//
//  Capture preferences tab combining screenshot behavior, recording settings, and post-capture actions
//

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Raw values are referenced by `PreferencesSearchIndex` to open the right segment.
enum CaptureSettingsPane: String, CaseIterable, Hashable, Identifiable {
  case general
  case wallpaper
  case screenshot
  case recording
  case ocr

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .wallpaper: "Wallpaper"
    case .general:
      L10n.Preferences.generalTab
    case .screenshot:
      CaptureType.screenshot.displayName
    case .recording:
      CaptureType.recording.displayName
    case .ocr:
      L10n.PreferencesCapture.ocrTab
    }
  }

  var previewScene: CaptureSettingsPreviewScene {
    switch self {
    case .wallpaper: .general
    case .general: .general
    case .screenshot: .screenshot
    case .recording: .recording
    case .ocr: .ocr
    }
  }
}

struct CaptureSettingsView: View {
  @AppStorage("ownshot.capture.export.convertToSRGB") private var convertToSRGB = false
  @AppStorage("ownshot.capture.export.scaleRetinaTo1x") private var scaleRetinaTo1x = false
  @AppStorage("ownshot.capture.export.addPixelBorder") private var addPixelBorder = false
  let fixedPane: CaptureSettingsPane?

  init(pane: CaptureSettingsPane? = nil) {
    fixedPane = pane
    _selectedPane = State(initialValue: pane ?? .general)
  }

  // Screenshot behavior
  @AppStorage(PreferencesKeys.hideDesktopIcons) private var hideDesktopIcons = false
  @AppStorage(PreferencesKeys.hideDesktopWidgets) private var hideDesktopWidgets = false
  @AppStorage(PreferencesKeys.screenshotIncludeOwnApp) private var includeOwnAppInScreenshots = false
  @AppStorage(PreferencesKeys.screenshotShowCursor) private var screenshotShowCursor = false
  @AppStorage(PreferencesKeys.captureIncludeWindowShadow) private var captureIncludeWindowShadow = true
  @AppStorage(PreferencesKeys.screenshotFreezeArea) private var freezeAreaCapture = false
  @AppStorage(PreferencesKeys.screenshotDelayedCaptureSeconds)
  private var delayedCaptureSeconds = CaptureDelayOption.defaultValue.seconds
  @AppStorage(PreferencesKeys.screenshotLivePassthrough) private var livePassthrough = true
  @State private var livePassthroughAccessibilityGranted = AXIsProcessTrusted()
  @AppStorage(PreferencesKeys.screenshotShowSelectionAreaOverlay) private var showSelectionAreaOverlay = OwnShotSelectionOverlayDefaults.showsSelectionAreaOverlay
  @AppStorage(PreferencesKeys.screenshotReverseMagnifierZoomDirection) private var reverseMagnifierZoomDirection = false
  @AppStorage(PreferencesKeys.screenshotAutoDetectWindowUnderCursor) private var autoDetectWindowUnderCursor = false
  @AppStorage(PreferencesKeys.screenshotAutoDetectElementUnderCursor) private var autoDetectElementUnderCursor = false
  @AppStorage(PreferencesKeys.screenshotShowMagnifierByDefault) private var showMagnifierByDefault = false
  @AppStorage(PreferencesKeys.screenshotShowMagnifierColorPanel) private var showMagnifierColorPanel = true
  @AppStorage(PreferencesKeys.screenshotMagnifierSize)
  private var magnifierSize = MagnifierSizeOption.defaultValue.rawValue

  @AppStorage(PreferencesKeys.screenshotFormat) private var screenshotFormat = "png"
  @AppStorage(PreferencesKeys.clipboardImageContent)
  private var clipboardImageContent = ClipboardImageContentOption.defaultValue.rawValue
  @AppStorage(PreferencesKeys.scrollingCaptureShowHints) private var scrollingCaptureShowHints = true
  @AppStorage(PreferencesKeys.backgroundCutoutAutoCropEnabled) private var backgroundCutoutAutoCropEnabled = true
  @AppStorage(PreferencesKeys.ocrSuccessNotificationEnabled) private var ocrSuccessNotification = true
  @AppStorage(PreferencesKeys.ocrLinkDetectionEnabled) private var ocrLinkDetection = true
  /// Starts as `.authorized` so the hint never flashes before the async check resolves.
  @State private var notificationAuthorization: SystemNotificationAuthorization = .authorized
  @AppStorage(PreferencesKeys.screenshotFileNameTemplate)
  private var screenshotFileNameTemplate = CaptureOutputKind.screenshot.defaultTemplate

  /// Recording settings
  @AppStorage(PreferencesKeys.recordingFormat) private var format = "mov"
  @AppStorage(PreferencesKeys.recordingFileNameTemplate)
  private var recordingFileNameTemplate = CaptureOutputKind.recording.defaultTemplate
  @AppStorage(PreferencesKeys.recordingFPS) private var fps = 30
  @AppStorage(PreferencesKeys.recordingQuality) private var quality = "high"
  @AppStorage(PreferencesKeys.recordingMaxResolution) private var maxResolution = "auto"
  @AppStorage(PreferencesKeys.recordingCaptureAudio) private var captureAudio = true
  @AppStorage(PreferencesKeys.recordingCaptureMicrophone) private var captureMicrophone = false
  @AppStorage(PreferencesKeys.recordingMicrophoneDeviceID)
  private var microphoneDeviceID = RecordingMicrophoneDevice.systemDefaultID
  @AppStorage(PreferencesKeys.recordingRememberLastArea) private var rememberLastArea = true
  @AppStorage(PreferencesKeys.recordingIncludeOwnApp) private var includeOwnAppInRecordings = false
  @AppStorage(PreferencesKeys.recordingShowCursor) private var recordingShowCursor = true
  @AppStorage(PreferencesKeys.recordingDimNonSelectedArea) private var recordingDimNonSelectedArea = true
  @AppStorage(PreferencesKeys.recordingHoverBarVisible) private var recordingHoverBarVisible = true
  @AppStorage(PreferencesKeys.recordingShowTimeOnMenuBar) private var recordingShowTimeOnMenuBar = true

  // Mouse Highlight settings
  @AppStorage(PreferencesKeys.mouseHighlightSize) private var mouseHighlightSize: Double = 50
  @AppStorage(PreferencesKeys.mouseHighlightAnimationDuration) private var mouseHighlightAnimDuration: Double = 0.7
  @AppStorage(PreferencesKeys.mouseHighlightRippleCount) private var mouseHighlightRippleCount: Int = 3
  @AppStorage(PreferencesKeys.mouseHighlightOpacity) private var mouseHighlightOpacity: Double = 0.5

  // Keystroke Overlay settings
  @AppStorage(PreferencesKeys.keystrokeFontSize) private var keystrokeFontSize: Double = 16
  @AppStorage(PreferencesKeys.keystrokePosition) private var keystrokePosition: String = KeystrokeOverlayPosition
    .bottomCenter.rawValue
  @AppStorage(PreferencesKeys.keystrokeDisplayDuration) private var keystrokeDisplayDuration: Double = 1.5

  @State private var showPermissionDeniedAlert = false
  @State private var selectedPane: CaptureSettingsPane = .general
  @State private var microphoneDevices: [RecordingMicrophoneDevice] = []

  /// SwiftUI Color binding backed by archived NSColor in UserDefaults
  private var mouseHighlightSwiftColor: Binding<Color> {
    Binding<Color>(
      get: {
        if let data = UserDefaults.standard.data(forKey: PreferencesKeys.mouseHighlightColor),
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
          return Color(nsColor: nsColor)
        }
        return Color(nsColor: MouseHighlightConfiguration.defaultHighlightColor)
      },
      set: { newColor in
        let nsColor = NSColor(newColor)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: true) {
          UserDefaults.standard.set(data, forKey: PreferencesKeys.mouseHighlightColor)
        }
      }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        if selectedPane == .general {
          Section(L10n.PreferencesCapture.appWindowsSection) {
            SettingRow(
              title: L10n.PreferencesCapture.includeInScreenshotsTitle,
              description: L10n.PreferencesCapture.includeInScreenshotsDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.includeInScreenshotsTitle, isOn: $includeOwnAppInScreenshots)
            }

            SettingRow(
              title: L10n.PreferencesCapture.includeInRecordingsTitle,
              description: L10n.PreferencesCapture.includeInRecordingsDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.includeInRecordingsTitle, isOn: $includeOwnAppInRecordings)
            }
          }
        }

        // MARK: - Desktop

        if selectedPane == .wallpaper {
          Section(L10n.PreferencesCapture.desktopSection) {
            SettingRow(
              title: L10n.PreferencesCapture.hideDesktopIconsTitle,
              description: L10n.PreferencesCapture.hideDesktopIconsDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.hideDesktopIconsTitle, isOn: $hideDesktopIcons)
            }

            SettingRow(
              title: L10n.PreferencesCapture.hideDesktopWidgetsTitle,
              description: L10n.PreferencesCapture.hideDesktopWidgetsDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.hideDesktopWidgetsTitle, isOn: $hideDesktopWidgets)
            }
          }

        }
        if selectedPane == .general {
          Section(L10n.PreferencesCapture.overlaySection) {
            SettingRow(
              title: L10n.PreferencesCapture.showSelectionAreaOverlayTitle,
              description: L10n.PreferencesCapture.showSelectionAreaOverlayDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.showSelectionAreaOverlayTitle, isOn: $showSelectionAreaOverlay)
            }

            SettingRow(
              title: L10n.PreferencesCapture.autoDetectWindowUnderCursorTitle,
              description: L10n.PreferencesCapture.autoDetectWindowUnderCursorDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.autoDetectWindowUnderCursorTitle, isOn: $autoDetectWindowUnderCursor)
                .onChange(of: autoDetectWindowUnderCursor) { isOn in
                  if !isOn {
                    autoDetectElementUnderCursor = false
                  }
                }
            }

            SettingRow(
              title: L10n.PreferencesCapture.autoDetectElementUnderCursorTitle,
              description: L10n.PreferencesCapture.autoDetectElementUnderCursorDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.autoDetectElementUnderCursorTitle, isOn: $autoDetectElementUnderCursor)
                .disabled(!autoDetectWindowUnderCursor)
            }
          }

          Section(L10n.PreferencesCapture.magnifierZoomSection) {
            SettingRow(
              title: L10n.PreferencesCapture.showMagnifierByDefaultTitle,
              description: L10n.PreferencesCapture.showMagnifierByDefaultDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.showMagnifierByDefaultTitle, isOn: $showMagnifierByDefault)
            }

            SettingRow(
              title: L10n.PreferencesCapture.reverseMagnifierZoomDirectionTitle,
              description: L10n.PreferencesCapture.reverseMagnifierZoomDirectionDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.reverseMagnifierZoomDirectionTitle, isOn: $reverseMagnifierZoomDirection)
            }

            SettingRow(
              title: L10n.PreferencesCapture.showMagnifierColorPanelTitle,
              description: L10n.PreferencesCapture.showMagnifierColorPanelDescription
            ) {
              // Independent of "show magnifier by default": the panel also shows on a
              // magnifier opened with ⌘+scroll.
              PreferencesToggle(L10n.PreferencesCapture.showMagnifierColorPanelTitle, isOn: $showMagnifierColorPanel)
            }

            SettingRow(
              title: L10n.PreferencesCapture.magnifierSizeTitle,
              description: L10n.PreferencesCapture.magnifierSizeDescription
            ) {
              Picker("", selection: $magnifierSize) {
                ForEach(MagnifierSizeOption.allCases) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
          }
        }

        // MARK: - Screenshot Format

        if selectedPane == .screenshot {
          Section("Output") {
            SettingRow(
              title: L10n.PreferencesCapture.imageFormatTitle,
              description: L10n.PreferencesCapture.imageFormatDescription
            ) {
              Picker("", selection: $screenshotFormat) {
                ForEach(ImageFormatOption.allCases, id: \.self) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }


            SettingRow(title: "Convert to sRGB profile", description: nil) {
              PreferencesToggle("Convert to sRGB profile", isOn: $convertToSRGB)
            }
            SettingRow(title: "Scale Retina screenshots to 1×", description: nil) {
              PreferencesToggle("Scale Retina screenshots to 1×", isOn: $scaleRetinaTo1x)
            }
            SettingRow(title: "Add 1px border to all screenshots", description: nil) {
              PreferencesToggle("Add 1px border to all screenshots", isOn: $addPixelBorder)
            }
          }
          Section("Capture") {
            SettingRow(
              title: L10n.PreferencesCapture.showCursorTitle,
              description: L10n.PreferencesCapture.showCursorDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.showCursorTitle, isOn: $screenshotShowCursor)
            }

            SettingRow(
              title: L10n.PreferencesCapture.includeWindowShadowTitle,
              description: L10n.PreferencesCapture.includeWindowShadowDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.includeWindowShadowTitle, isOn: $captureIncludeWindowShadow)
            }

            SettingRow(
              title: L10n.PreferencesCapture.freezeAreaTitle,
              description: L10n.PreferencesCapture.freezeAreaDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.freezeAreaTitle, isOn: $freezeAreaCapture)
            }

            SettingRow(
              title: L10n.PreferencesCapture.delayedCaptureTitle,
              description: L10n.PreferencesCapture.delayedCaptureDescription
            ) {
              Picker("", selection: $delayedCaptureSeconds) {
                ForEach(CaptureDelayOption.allCases) { option in
                  Text(option.displayName).tag(option.seconds)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            SettingRow(
              title: L10n.PreferencesCapture.livePassthroughTitle,
              description: L10n.PreferencesCapture.livePassthroughDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.livePassthroughTitle, isOn: $livePassthrough)
            }

            if livePassthrough, !livePassthroughAccessibilityGranted {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundColor(.orange)
                  .font(.system(size: 12))
                  .padding(.top, 1)
                Text(L10n.PreferencesCapture.livePassthroughPermissionHint)
                  .font(.system(size: 11))
                  .foregroundColor(.orange)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.Common.openSettings) {
                  if let url =
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                  }
                }
                .controlSize(.regular)
              }
              .padding(.vertical, 4)
              .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                livePassthroughAccessibilityGranted = AXIsProcessTrusted()
              }
            }

            if screenshotFormat == ImageFormatOption.webp.rawValue {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundColor(.orange)
                  .font(.system(size: 12))
                  .padding(.top, 1)
                Text(L10n.PreferencesCapture.webpWarning)
                  .font(.system(size: 11))
                  .foregroundColor(.orange)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 4)
            }

            if screenshotFormat == ImageFormatOption.jpeg.rawValue {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                  .foregroundColor(.blue)
                  .font(.system(size: 12))
                  .padding(.top, 1)
                Text(L10n.PreferencesCapture.jpegCutoutNote)
                  .font(.system(size: 11))
                  .foregroundColor(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 4)
            }

            SettingRow(
              title: L10n.PreferencesCapture.clipboardContentTitle,
              description: L10n.PreferencesCapture.clipboardContentDescription
            ) {
              Picker("", selection: $clipboardImageContent) {
                ForEach(ClipboardImageContentOption.allCases) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
          }
        }

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.screenshotPresetSection) {
            PreferencesScreenshotDefaultPresetPicker()
          }
        }

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.scrollingCaptureSection) {
            SettingRow(
              title: L10n.PreferencesCapture.showSessionHintsTitle,
              description: L10n.PreferencesCapture.showSessionHintsDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.showSessionHintsTitle, isOn: $scrollingCaptureShowHints)
            }

            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
                .font(.system(size: 12))
                .padding(.top, 1)
              Text(L10n.PreferencesCapture.scrollingCaptureInfo)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
          }
        }

        // MARK: - OCR

        if selectedPane == .ocr {
          PreferencesOCRModelListView()

          Section(L10n.PreferencesCapture.ocrNotificationsSection) {
            SettingRow(
              title: L10n.PreferencesCapture.ocrSuccessNotificationTitle,
              description: L10n.PreferencesCapture.ocrSuccessNotificationDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.ocrSuccessNotificationTitle, isOn: $ocrSuccessNotification)
            }

            if ocrSuccessNotification {
              ocrNotificationPermissionHint
            }
          }

          Section(L10n.PreferencesCapture.ocrTextActionsSection) {
            SettingRow(
              title: L10n.PreferencesCapture.ocrLinkDetectionTitle,
              description: L10n.PreferencesCapture.ocrLinkDetectionDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.ocrLinkDetectionTitle, isOn: $ocrLinkDetection)
            }
          }
        }

        if selectedPane == .general {
          Section(L10n.PreferencesCapture.outputNamingSection) {
            SettingRow(
              title: L10n.PreferencesCapture.screenshotTemplateTitle,
              description: L10n.PreferencesCapture.screenshotTemplateDescription
            ) {
              TextField("", text: $screenshotFileNameTemplate)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }

            SettingRow(
              title: L10n.PreferencesCapture.recordingTemplateTitle,
              description: L10n.PreferencesCapture.recordingTemplateDescription
            ) {
              TextField("", text: $recordingFileNameTemplate)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }

            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
                .padding(.top, 1)
              Text(L10n.PreferencesCapture.availableTokens)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
              Text(L10n.PreferencesCapture.screenshotPreview(screenshotFilenamePreview))
              Text(L10n.PreferencesCapture.recordingPreview(recordingFilenamePreview))
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.top, 2)

            HStack {
              Spacer()
              Button(L10n.PreferencesCapture.resetNamingDefaults) {
                resetOutputNamingDefaults()
              }
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .buttonStyle(.plain)
            }
          }
        }

        // MARK: - Recording

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingFormatSection) {
            SettingRow(
              title: L10n.PreferencesCapture.videoFormatTitle,
              description: L10n.PreferencesCapture.videoFormatDescription
            ) {
              Picker("", selection: $format) {
                Text(verbatim: "MOV").tag("mov")
                Text(verbatim: "MP4").tag("mp4")
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingQualitySection) {
            SettingRow(
              title: L10n.PreferencesCapture.frameRateTitle,
              description: L10n.PreferencesCapture.frameRateDescription
            ) {
              Picker("", selection: $fps) {
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            SettingRow(
              title: L10n.PreferencesCapture.maxResolutionTitle,
              description: L10n.PreferencesCapture.maxResolutionDescription
            ) {
              Picker("", selection: $maxResolution) {
                ForEach(RecordingMaxResolution.allCases, id: \.self) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            SettingRow(
              title: L10n.PreferencesCapture.qualityTitle,
              description: L10n.PreferencesCapture.qualityDescription
            ) {
              Picker("", selection: $quality) {
                ForEach(VideoQuality.allCases, id: \.self) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingBehaviorSection) {
            SettingRow(
              title: L10n.PreferencesCapture.showCursorTitle,
              description: L10n.PreferencesCapture.recordingShowCursorDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.showCursorTitle, isOn: $recordingShowCursor)
            }

            SettingRow(
              title: L10n.PreferencesCapture.recordingDimNonSelectedAreaTitle,
              description: L10n.PreferencesCapture.recordingDimNonSelectedAreaDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.recordingDimNonSelectedAreaTitle, isOn: $recordingDimNonSelectedArea)
            }

            SettingRow(
              title: L10n.PreferencesCapture.rememberLastAreaTitle,
              description: L10n.PreferencesCapture.rememberLastAreaDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.rememberLastAreaTitle, isOn: $rememberLastArea)
            }
          }
        }

        // MARK: - Recording Controls

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingControlsSection) {
            SettingRow(
              title: L10n.PreferencesCapture.hoverBarVisibleTitle,
              description: L10n.PreferencesCapture.hoverBarVisibleDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.hoverBarVisibleTitle, isOn: $recordingHoverBarVisible)
            }

            SettingRow(
              title: L10n.PreferencesCapture.menuBarTimeTitle,
              description: L10n.PreferencesCapture.menuBarTimeDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.menuBarTimeTitle, isOn: $recordingShowTimeOnMenuBar)
            }
          }
        }

        // MARK: - Recording Overlays

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.mouseHighlightSection) {
            SettingRow(
              title: L10n.PreferencesCapture.highlightSizeTitle,
              description: L10n.PreferencesCapture.highlightSizeDescription(Int(mouseHighlightSize))
            ) {
              Slider(value: $mouseHighlightSize.stepped(by: 2, in: 30 ... 100), in: 30 ... 100)
                .frame(width: 140)
            }

            SettingRow(
              title: L10n.PreferencesCapture.animationDurationTitle,
              description: L10n.PreferencesCapture.animationDurationDescription(
                String(format: "%.1f", mouseHighlightAnimDuration)
              )
            ) {
              Slider(value: $mouseHighlightAnimDuration.stepped(by: 0.1, in: 0.3 ... 2.0), in: 0.3 ... 2.0)
                .frame(width: 140)
            }

            SettingRow(
              title: L10n.PreferencesCapture.rippleCountTitle,
              description: L10n.PreferencesCapture.rippleCountDescription
            ) {
              Picker("", selection: $mouseHighlightRippleCount) {
                ForEach(1 ... 5, id: \.self) { count in
                  Text("\(count)").tag(count)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(width: 80)
            }

            SettingRow(
              title: L10n.PreferencesCapture.highlightColorTitle,
              description: L10n.PreferencesCapture.highlightColorDescription
            ) {
              ColorPicker("", selection: mouseHighlightSwiftColor, supportsOpacity: false)
                .labelsHidden()
            }

            SettingRow(
              title: L10n.PreferencesCapture.opacityTitle,
              description: L10n.PreferencesCapture.opacityDescription(Int(mouseHighlightOpacity * 100))
            ) {
              Slider(value: $mouseHighlightOpacity.stepped(by: 0.05, in: 0.2 ... 1.0), in: 0.2 ... 1.0)
                .frame(width: 140)
            }

            HStack {
              Spacer()
              Button(L10n.Common.resetToDefault) {
                resetMouseHighlightDefaults()
              }
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .buttonStyle(.plain)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.keystrokeOverlaySection) {
            SettingRow(
              title: L10n.PreferencesCapture.fontSizeTitle,
              description: L10n.PreferencesCapture.fontSizeDescription(Int(keystrokeFontSize))
            ) {
              Slider(value: $keystrokeFontSize.stepped(by: 1, in: 12 ... 32), in: 12 ... 32)
                .frame(width: 140)
            }

            SettingRow(
              title: L10n.PreferencesCapture.positionTitle,
              description: L10n.PreferencesCapture.positionDescription
            ) {
              Picker("", selection: $keystrokePosition) {
                ForEach(KeystrokeOverlayPosition.allCases) { pos in
                  Text(pos.displayName).tag(pos.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(width: 140)
            }

            SettingRow(
              title: L10n.PreferencesCapture.displayDurationTitle,
              description: L10n.PreferencesCapture.displayDurationDescription(
                String(format: "%.1f", keystrokeDisplayDuration)
              )
            ) {
              Slider(value: $keystrokeDisplayDuration.stepped(by: 0.5, in: 0.5 ... 5.0), in: 0.5 ... 5.0)
                .frame(width: 140)
            }

            HStack {
              Spacer()
              Button(L10n.Common.resetToDefault) {
                resetKeystrokeDefaults()
              }
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .buttonStyle(.plain)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.audioSection) {
            SettingRow(
              title: L10n.PreferencesCapture.systemAudioTitle,
              description: L10n.PreferencesCapture.systemAudioDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.systemAudioTitle, isOn: $captureAudio)
            }

            SettingRow(
              title: L10n.Onboarding.microphone,
              description: L10n.PreferencesCapture.microphoneDescription
            ) {
              PreferencesToggle(L10n.Onboarding.microphone, isOn: Binding(
                get: { captureMicrophone },
                set: { newValue in
                  if newValue {
                    handleMicrophoneEnable()
                  } else {
                    captureMicrophone = false
                  }
                }
              ))
              .labelsHidden()
            }

            SettingRow(
              title: L10n.PreferencesCapture.microphoneInputTitle,
              description: L10n.PreferencesCapture.microphoneInputDescription
            ) {
              Picker("", selection: $microphoneDeviceID) {
                ForEach(microphoneDevices) { device in
                  Text(device.displayName).tag(device.id)
                }
              }
              .labelsHidden()
              .frame(width: 220)
            }
          }
          .alert(L10n.Microphone.accessRequiredTitle, isPresented: $showPermissionDeniedAlert) {
            Button(L10n.Common.openSystemSettings) {
              openMicrophoneSettings()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
          } message: {
            Text(L10n.Microphone.preferencesMessage)
          }
        }

        // MARK: - After Capture

        if selectedPane == .general {
          Section(L10n.PreferencesCapture.afterCaptureSection) {
            AfterCaptureMatrixView()

            Text(L10n.PreferencesCapture.removeBackground)
              .font(.caption)
              .foregroundColor(.secondary)

            SettingRow(
              title: L10n.PreferencesCapture.autoCropSubjectTitle,
              description: L10n.PreferencesCapture.autoCropSubjectDescription
            ) {
              PreferencesToggle(L10n.PreferencesCapture.autoCropSubjectTitle, isOn: $backgroundCutoutAutoCropEnabled)
            }
          }
        }
      }
      .formStyle(.grouped)
      .onReceive(PreferencesNavigationState.shared.$revealRequest) { request in
        if let pane = request?.pane.flatMap(CaptureSettingsPane.init(rawValue:)) {
          selectedPane = pane
        }
      }
    }
    .onAppear(perform: refreshMicrophoneDevices)
    .task {
      await refreshNotificationAuthorization()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      // Picks up the change after the user flips the switch in System Settings.
      Task { await refreshNotificationAuthorization() }
    }
  }

  // MARK: - OCR notification permission

  /// Surfaces the macOS-level notification permission only when it would actually block
  /// the feature the user just turned on, so a healthy setup shows no clutter.
  @ViewBuilder
  private var ocrNotificationPermissionHint: some View {
    switch notificationAuthorization {
    case .notDetermined:
      permissionHintRow(
        icon: "bell.badge.circle.fill",
        iconColor: .accentColor,
        textColor: .secondary,
        message: L10n.PreferencesCapture.ocrNotificationAllowHint,
        actionTitle: L10n.PreferencesCapture.ocrNotificationAllowAction
      ) {
        Task {
          await SystemNotificationService.shared.requestAuthorization()
          await refreshNotificationAuthorization()
        }
      }
    case .denied:
      permissionHintRow(
        icon: "exclamationmark.triangle.fill",
        iconColor: .orange,
        textColor: .orange,
        message: L10n.PreferencesCapture.ocrNotificationDeniedHint,
        actionTitle: L10n.Common.openSettings
      ) {
        SystemNotificationService.shared.openSystemSettings()
      }
    case .authorized, .unavailable:
      EmptyView()
    }
  }

  private func permissionHintRow(
    icon: String,
    iconColor: Color,
    textColor: Color,
    message: String,
    actionTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: icon)
        .foregroundColor(iconColor)
        .font(.system(size: 12))
        .padding(.top, 1)
      Text(message)
        .font(.system(size: 11))
        .foregroundColor(textColor)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button(actionTitle, action: action)
        .controlSize(.regular)
    }
    .padding(.vertical, 4)
  }

  private func refreshNotificationAuthorization() async {
    notificationAuthorization = await SystemNotificationService.shared.authorizationStatus()
  }

  // MARK: - Helpers

  private var screenshotFilenamePreview: String {
    let sampleContext = CaptureContext(appName: "Safari", windowTitle: "GitHub")
    let baseName = CaptureOutputNaming.resolveTemplateBaseName(
      previewTemplate(screenshotFileNameTemplate, kind: .screenshot),
      kind: .screenshot,
      context: sampleContext
    )
    return "\(baseName).\(screenshotFileExtension)"
  }

  private var recordingFilenamePreview: String {
    let sampleContext = CaptureContext(appName: "Safari", windowTitle: "GitHub")
    let baseName = CaptureOutputNaming.resolveTemplateBaseName(
      previewTemplate(recordingFileNameTemplate, kind: .recording),
      kind: .recording,
      context: sampleContext
    )
    return "\(baseName).\(recordingFileExtension)"
  }

  private func previewTemplate(_ template: String, kind: CaptureOutputKind) -> String {
    template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? kind.defaultTemplate
      : template
  }

  private var screenshotFileExtension: String {
    ImageFormatOption(rawValue: screenshotFormat)?.format.fileExtension ?? "png"
  }

  private var recordingFileExtension: String {
    VideoFormat(rawValue: format)?.fileExtension ?? "mov"
  }

  private func handleMicrophoneEnable() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)

    switch status {
    case .notDetermined:
      Task {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
          if granted {
            captureMicrophone = true
          } else {
            showPermissionDeniedAlert = true
          }
        }
      }
    case .authorized:
      captureMicrophone = true
    case .denied, .restricted:
      showPermissionDeniedAlert = true
    @unknown default:
      captureMicrophone = true
    }
  }

  private func openMicrophoneSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
      NSWorkspace.shared.open(url)
    }
  }

  private func refreshMicrophoneDevices() {
    microphoneDevices = RecordingMicrophoneDeviceProvider.availableDevices(
      selectedDeviceID: microphoneDeviceID
    )
  }

  // MARK: - Reset Defaults

  private func resetOutputNamingDefaults() {
    screenshotFileNameTemplate = CaptureOutputKind.screenshot.defaultTemplate
    recordingFileNameTemplate = CaptureOutputKind.recording.defaultTemplate
  }

  private func resetMouseHighlightDefaults() {
    mouseHighlightSize = MouseHighlightConfiguration.defaultHighlightSize
    mouseHighlightAnimDuration = MouseHighlightConfiguration.defaultAnimationDuration
    mouseHighlightRippleCount = MouseHighlightConfiguration.defaultRippleCount
    mouseHighlightOpacity = MouseHighlightConfiguration.defaultHighlightOpacity
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.mouseHighlightColor)
  }

  private func resetKeystrokeDefaults() {
    keystrokeFontSize = KeystrokeOverlayConfiguration.defaultFontSize
    keystrokePosition = KeystrokeOverlayConfiguration.defaultPosition.rawValue
    keystrokeDisplayDuration = KeystrokeOverlayConfiguration.defaultDisplayDuration
  }
}

#Preview {
  CaptureSettingsView()
    .frame(width: 600, height: 550)
}


struct OwnShotWallpaperSettingsView: View {
  @AppStorage("ownshot.capture.wallpaper.mode") private var mode = "system"
  @AppStorage("ownshot.capture.wallpaper.imagePath") private var imagePath = ""
  @AppStorage("ownshot.capture.wallpaper.updateOnSpaces") private var updateOnSpaces = false

  var body: some View {
    Form {
      Section("Desktop") {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Wallpaper")
            Spacer()
            Picker("Wallpaper", selection: $mode) {
              Text("Desktop wallpaper").tag("system")
              Text("Custom wallpaper").tag("image")
              Text("Plain color").tag("color")
            }
            .labelsHidden().fixedSize().tint(.primary)
          }
          Text("Set a custom wallpaper used to hide desktop icons and as the background behind window screenshots.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if mode == "image" {
            HStack {
              Text("Wallpaper image")
              Spacer()
              if !imagePath.isEmpty {
                Text(verbatim: URL(fileURLWithPath: imagePath).lastPathComponent)
                  .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              }
              Button("Choose…") { chooseImage() }
            }.padding(.top, 8)
          }
          if mode == "color" {
            ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
              .padding(.top, 8)
          }
        }
        // Как в эталоне: переключатель есть только у Desktop wallpaper.
        if mode == "system" {
          SettingRow(title: "Update wallpaper when switching Spaces", description: nil) {
            PreferencesToggle("Update wallpaper when switching Spaces", isOn: $updateOnSpaces)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: updateOnSpaces) { updates in
      if !updates {
        UserDefaults.standard.removeObject(forKey: "ownshot.capture.wallpaper.desktopPaths")
        for screen in NSScreen.screens { _ = OwnShotCaptureWallpaper.loadDesktop(screen: screen) }
      }
    }
    .onAppear {
      if mode == "system", !updateOnSpaces {
        for screen in NSScreen.screens { _ = OwnShotCaptureWallpaper.loadDesktop(screen: screen) }
      }
    }
  }

  private var colorBinding: Binding<Color> {
    Binding(get: {
      let rgb = UserDefaults.standard.array(forKey: "ownshot.capture.wallpaper.colorRGB") as? [Double] ?? [0, 0, 0]
      guard rgb.count == 3 else { return .black }
      return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
    }, set: { color in
      guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
      UserDefaults.standard.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent], forKey: "ownshot.capture.wallpaper.colorRGB")
    })
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    imagePath = url.path
    UserDefaults.standard.set(try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "ownshot.capture.wallpaper.imageBookmark")
    mode = "image"
  }
}
