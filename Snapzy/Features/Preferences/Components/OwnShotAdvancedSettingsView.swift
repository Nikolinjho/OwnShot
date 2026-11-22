import SwiftUI

struct OwnShotAdvancedSettingsView: View {
  @AppStorage(OwnShotAdvancedPreferenceKeys.askForName) private var askForName = false
  @AppStorage(OwnShotAdvancedPreferenceKeys.addRetinaSuffix) private var addRetinaSuffix = true
  @AppStorage(PreferencesKeys.clipboardImageContent)
  private var clipboardContent = ClipboardImageContentOption.defaultValue.rawValue
  @AppStorage(PreferencesKeys.historyRetentionDays) private var historyRetentionDays = 30
  @AppStorage(PreferencesKeys.historyEnabled) private var historyEnabled = true
  @AppStorage(OwnShotAdvancedPreferenceKeys.recognitionLanguage) private var recognitionLanguage = "auto"
  @AppStorage(OwnShotAdvancedPreferenceKeys.keepLineBreaks) private var keepLineBreaks = false
  @AppStorage(PreferencesKeys.ocrLinkDetectionEnabled) private var detectLinks = true
  @AppStorage(OwnShotAdvancedPreferenceKeys.rememberAllInOneSelection) private var rememberSelection = true
  @AppStorage(OwnShotAdvancedPreferenceKeys.pinnedRoundedCorners) private var roundedCorners = true
  @AppStorage(OwnShotAdvancedPreferenceKeys.pinnedShadow) private var pinnedShadow = true
  @AppStorage(OwnShotAdvancedPreferenceKeys.pinnedBorder) private var pinnedBorder = true
  @AppStorage(PreferencesKeys.urlSchemeEnabled) private var urlSchemeEnabled = true
  @State private var showNaming = false
  @State private var showMoreOptions = false
  @State private var warningsReset = false

  var body: some View {
    Form {
      Section("File Name") {
        toggleRow("Ask for name after every capture", isOn: $askForName)
        HStack {
          Text("File name format")
          Spacer()
          Button("Customize…") { showNaming = true }
        }
        explainedRow(
          "Add \"@2x\" suffix to Retina screenshots",
          description: "This option improves compatibility with displaying Retina screenshots in third-party apps."
        ) {
          PreferencesToggle("Add @2x suffix to Retina screenshots", isOn: $addRetinaSuffix)
        }
      }

      Section("Clipboard") {
        explainedRow(
          "Copy to clipboard",
          description: "Adjust this option if you've encountered any issues with pasting from clipboard or clipboard managers."
        ) {
          Picker("Copy to clipboard", selection: $clipboardContent) {
            Text("File & Image (default)").tag(ClipboardImageContentOption.imageAndFile.rawValue)
            Text("Image only").tag(ClipboardImageContentOption.imageOnly.rawValue)
            Text("File only").tag(ClipboardImageContentOption.fileOnly.rawValue)
          }
          .labelsHidden()
          .fixedSize()
          .settingsPopupRow()
        }
      }

      Section("Capture History") {
        explainedRow(
          "Keep history",
          description: "You can restore old files with \"Capture History\" option from the menu bar."
        ) {
          Picker("Keep history", selection: historySelection) {
            Text("Disabled").tag(-1)
            ForEach(retentionOptions, id: \.self) { days in
              Text(OwnShotHistoryRetentionOption.title(forDays: days)).tag(days)
            }
          }
          .labelsHidden()
          .fixedSize()
          .settingsPopupRow()
        }
      }

      Section("Text Recognition") {
        HStack {
          Text("Language")
          Spacer()
          Picker("Language", selection: $recognitionLanguage) {
            ForEach(OwnShotRecognitionLanguageOption.all) { option in
              Text(option.title).tag(option.id)
            }
          }
          .labelsHidden()
          .fixedSize()
          .settingsPopupRow()
        }
        toggleRow("Keep line breaks", isOn: $keepLineBreaks)
        toggleRow("Detect links", isOn: $detectLinks)
      }

      Section("All-In-One") {
        toggleRow("Remember last selection", isOn: $rememberSelection)
      }

      Section("Pinned Screenshots") {
        toggleRow("Rounded corners", isOn: $roundedCorners)
        toggleRow("Shadow", isOn: $pinnedShadow)
        toggleRow("Border", isOn: $pinnedBorder)
      }

      Section("API") {
        // Подпись с AXLink «URL scheme API», как у эталона.
        explainedRow(
          "Allow URL scheme API",
          description: L10n.SettingsParity.urlSchemeDescription,
          rendersMarkdown: true
        ) {
          PreferencesToggle("Allow URL scheme API", isOn: $urlSchemeEnabled)
        }
      }

      Section("Other") {
        HStack {
          Spacer()
          // Сбрасывает все флажки «Don't ask/warn again», затем подтверждение эталона.
          Button("Reset All Warning Dialogs") {
            OwnShotWarningDialogs.resetAll()
            warningsReset = true
          }
          .alert(OwnShotWarningDialogs.resetTitle, isPresented: $warningsReset) {
            Button(L10n.Common.ok) {}
          } message: {
            Text(OwnShotWarningDialogs.resetMessage)
          }
        }
        HStack {
          Spacer()
          Button("More options…") { showMoreOptions = true }
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showNaming) {
      OwnShotFileNameFormatSheet()
    }
    .sheet(isPresented: $showMoreOptions) {
      VStack(spacing: 0) {
        HStack {
          Text("More Options").font(.headline)
          Spacer()
          Button("Done") { showMoreOptions = false }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        AdvancedSettingsView()
      }
      .frame(width: 640, height: 660)
    }
  }

  private var historySelection: Binding<Int> {
    Binding(
      get: { historyEnabled ? historyRetentionDays : -1 },
      set: { value in
        historyEnabled = value != -1
        if value >= 0 { historyRetentionDays = value }
      }
    )
  }

  private var retentionOptions: [Int] {
    OwnShotHistoryRetentionOption.options(including: historyRetentionDays)
  }

  private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
    HStack {
      Text(title)
      Spacer()
      PreferencesToggle(title, isOn: isOn)
    }
  }

  private func explainedRow<Control: View>(
    _ title: String,
    description: String,
    rendersMarkdown: Bool = false,
    @ViewBuilder control: () -> Control
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        control()
      }
      Group {
        if rendersMarkdown { Text(LocalizedStringKey(description)) } else { Text(description) }
      }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Пункты Keep history как в CleanShot X: Disabled, 1 day, 3 days, 1 week, 1 month.
/// Нестандартное сохранённое значение (например, Forever или 14 дней) остаётся в списке.
enum OwnShotHistoryRetentionOption {
  static let standardDays = [1, 3, 7, 30]

  static func options(including current: Int) -> [Int] {
    var days = standardDays
    if current >= 0, !days.contains(current) { days.append(current) }
    // Forever (0) идёт последним.
    return days.sorted { lhs, rhs in
      if lhs == 0 { return false }
      if rhs == 0 { return true }
      return lhs < rhs
    }
  }

  static func title(forDays days: Int) -> String {
    switch days {
    case 0: return "Forever"
    case 1: return "1 day"
    case 7: return "1 week"
    case 30: return "1 month"
    default: return "\(days) days"
    }
  }
}

/// Меню Language в Text Recognition, порядок как в CleanShot X 5.0.1.
struct OwnShotRecognitionLanguageOption: Identifiable, Equatable {
  let id: String
  let title: String

  static let all: [OwnShotRecognitionLanguageOption] = [
    .init(id: "auto", title: "Automatically Detect Language"),
    .init(id: "ar", title: "Arabic"),
    .init(id: "ars", title: "Arabic (Najdi)"),
    .init(id: "zh-Hans", title: "Chinese (Simplified)"),
    .init(id: "zh-Hant", title: "Chinese (Traditional)"),
    .init(id: "cs", title: "Czech"),
    .init(id: "da", title: "Danish"),
    .init(id: "nl", title: "Dutch"),
    .init(id: "en", title: "English"),
    .init(id: "fr", title: "French"),
    .init(id: "de", title: "German"),
    .init(id: "id", title: "Indonesian"),
    .init(id: "it", title: "Italian"),
    .init(id: "ja", title: "Japanese"),
    .init(id: "ko", title: "Korean"),
    .init(id: "ms", title: "Malay"),
    .init(id: "no", title: "Norwegian"),
    .init(id: "nb", title: "Norwegian (Bokmål)"),
    .init(id: "nn", title: "Norwegian (Nynorsk)"),
    .init(id: "pl", title: "Polish"),
    .init(id: "pt", title: "Portuguese"),
    .init(id: "ro", title: "Romanian"),
    .init(id: "ru", title: "Russian"),
    .init(id: "es", title: "Spanish"),
    .init(id: "sv", title: "Swedish"),
    .init(id: "th", title: "Thai"),
    .init(id: "tr", title: "Turkish"),
    .init(id: "uk", title: "Ukrainian"),
    .init(id: "vi", title: "Vietnamese"),
  ]
}
