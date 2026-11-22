import AppKit
import SwiftUI

struct AfterCaptureMatrixView: View {
  @ObservedObject private var manager = PreferencesManager.shared

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text("Action").frame(maxWidth: .infinity, alignment: .leading)
        columnTitle("Screenshot")
        columnTitle("Recording")
      }
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(height: 40)

      actionRow(.showQuickAccess, title: "Show Quick Access Overlay")
      actionRow(.copyFile, title: "Copy file to clipboard")
      actionRow(.save, title: "Save")
      placeholderRow(title: "Upload to Cloud & copy link", feature: .cloud)
      actionRow(.openAnnotate, title: "Open Annotate tool")
      actionRow(.pinToScreen, title: "Pin to the screen")
      actionRow(.openVideoEditor, title: AfterCaptureAction.openVideoEditor.displayName)
    }
    .font(.system(size: 13))
  }

  private func columnTitle(_ title: String) -> some View {
    Text(title).frame(width: 96).offset(x: 8)
  }

  private func actionRow(_ action: AfterCaptureAction, title: String) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 0) {
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(CaptureType.allCases, id: \.self) { type in
          if PreferencesManager.applicableActions(for: type).contains(action) {
            toggleColumn(action: action, type: type, title: title)
          } else {
            unavailableColumn
          }
        }
      }
      .frame(height: 32)
    }
  }

  private func toggleColumn(action: AfterCaptureAction, type: CaptureType, title: String) -> some View {
    Toggle("", isOn: Binding(
      get: { manager.isActionEnabled(action, for: type) },
      set: { enabled in
        // Последнее включённое действие не снимается, как в эталоне
        if !enabled, manager.wouldLeaveNoActions(disabling: action, for: type) {
          showAtLeastOneActionAlert()
          return
        }
        manager.setAction(action, for: type, enabled: enabled)
      }
    ))
    .labelsHidden()
    .toggleStyle(.checkbox)
    .accessibilityLabel(L10n.AfterCapture.accessibilityLabel(title, captureKind: type.displayName))
    .frame(width: 96).offset(x: 8)
  }

  private func showAtLeastOneActionAlert() {
    let alert = NSAlert()
    alert.messageText = L10n.AfterCapture.atLeastOneActionTitle
    alert.informativeText = L10n.AfterCapture.atLeastOneActionMessage
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  private var unavailableColumn: some View {
    Text("—").foregroundStyle(.tertiary).frame(width: 96).offset(x: 8)
  }

  private func placeholderRow(title: String, feature: OwnShotDeferredFeature) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 0) {
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
        placeholderColumn(title: title, feature: feature)
        placeholderColumn(title: title, feature: feature)
      }
      .frame(height: 32)
    }
  }

  private func placeholderColumn(title: String, feature: OwnShotDeferredFeature) -> some View {
    Button { _ = OwnShotFeaturePolicy.allow(feature) } label: {
      Image(systemName: "square.fill")
        .font(.system(size: 16))
        .foregroundStyle(.quaternary)
        .frame(width: 96, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .offset(x: 8)
    .help("Coming later")
    .accessibilityLabel("\(title) · Coming later")
  }
}

#Preview {
  AfterCaptureMatrixView().padding()
}
