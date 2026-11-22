import SwiftUI

struct OwnShotAnnotateSettingsView: View {
  @AppStorage(OwnShotAnnotatePreferenceKeys.inverseArrowDirection) private var inverseArrow = false
  @AppStorage(OwnShotAnnotatePreferenceKeys.smoothDrawing) private var smoothDrawing = true
  @AppStorage(OwnShotAnnotatePreferenceKeys.rememberBackground) private var rememberBackground = false
  @AppStorage(OwnShotAnnotatePreferenceKeys.drawObjectShadow) private var drawObjectShadow = true
  @AppStorage(OwnShotAnnotatePreferenceKeys.automaticallyExpandCanvas) private var expandCanvas = false
  @AppStorage(OwnShotAnnotatePreferenceKeys.alwaysOnTop) private var alwaysOnTop = false
  @AppStorage(OwnShotAnnotatePreferenceKeys.showDockIcon) private var showDockIcon = true
  @AppStorage(OwnShotAnnotatePreferenceKeys.showColorNames) private var showColorNames = false
  @State private var showsMoreOptions = false

  var body: some View {
    Form {
      Section("Tools") {
        row("Inverse arrow direction", hint: "Press ⌥ (option) when drawing to invert the behavior.", value: $inverseArrow)
        row("Smooth drawing", value: $smoothDrawing)
        row("Remember if background tool was opened", value: $rememberBackground)
        row("Draw shadow on objects", value: $drawObjectShadow)
        row("Automatically expand canvas", hint: "Ensures all annotations fit by dynamically resizing canvas.", value: $expandCanvas)
      }
      Section("Window") {
        row("Always on top", value: $alwaysOnTop)
        row("Show Dock icon", value: $showDockIcon)
      }
      Section {
        row("Show color names", value: $showColorNames)
      } header: {
        Text("Accessibility")
      } footer: {
        Button("More options…") { showsMoreOptions = true }
          .buttonStyle(.link)
          .padding(.top, 8)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showsMoreOptions) {
      VStack(alignment: .trailing, spacing: 0) {
        AnnotateSettingsView()
        Button("Done") { showsMoreOptions = false }
          .keyboardShortcut(.defaultAction)
          .padding()
      }
      .frame(width: 640, height: 620)
    }
  }

  private func row(_ title: String, hint: String? = nil, value: Binding<Bool>) -> some View {
    SettingRow(title: title, description: hint, descriptionStyle: .subtitle) {
      PreferencesToggle(title, isOn: value)
    }
  }
}
