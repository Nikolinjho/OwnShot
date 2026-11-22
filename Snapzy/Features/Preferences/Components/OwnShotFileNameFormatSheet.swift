import SwiftUI
import UniformTypeIdentifiers

/// Sheet Advanced → File name format → Customize… по образцу CleanShot X:
/// поле формата, Preview, палитра элементов, Remove illegal characters,
/// Use UTC time zone, Restore Defaults / Cancel / OK.
/// Изменения копятся в черновике и сохраняются только по OK.
struct OwnShotFileNameFormatSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// Какой шаблон сейчас правится. У OwnShot отдельные шаблоны снимков и записей.
  @State private var kind: OwnShotFileNameFormatDraft.Kind = .screenshot
  @State private var draft = OwnShotFileNameFormatDraft.load()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Type text and drag elements to create a custom format:")
        Spacer()
        Picker("Format", selection: $kind) {
          Text("Screenshots").tag(OwnShotFileNameFormatDraft.Kind.screenshot)
          Text("Recordings").tag(OwnShotFileNameFormatDraft.Kind.recording)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }

      TextField("", text: templateBinding)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
        .accessibilityLabel("File name format")
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
          insertDroppedText(from: providers)
        }

      HStack(spacing: 8) {
        Text("Preview:")
        Text(verbatim: previewName)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      tokenPalette

      if CaptureOutputNaming.usesAutoIncrement(draft.template(for: kind)) {
        HStack(spacing: 8) {
          Text("Auto-increment next number:")
          TextField("", value: $draft.nextAutoIncrement, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .accessibilityLabel("Auto-increment next number")
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Toggle("Remove illegal characters", isOn: $draft.options.removesIllegalCharacters)
        Toggle("Use UTC time zone", isOn: $draft.options.usesUTC)
      }
      .toggleStyle(.checkbox)

      HStack {
        Button("Restore Defaults") { draft.restoreDefaults() }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("OK") {
          draft.save()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  // MARK: - Палитра

  private var tokenPalette: some View {
    HStack(alignment: .top, spacing: 40) {
      paletteColumn(CaptureFileNameToken.paletteLeftColumn)
      paletteColumn(CaptureFileNameToken.paletteRightColumn)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
    .background(
      Radius.rect(Radius.card)
        .fill(Color.primary.opacity(0.04))
    )
  }

  private func paletteColumn(_ tokens: [CaptureFileNameToken]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(tokens) { token in
        HStack {
          Text(token.title)
          Spacer(minLength: 12)
          OwnShotFileNameTokenChip(code: token.code) {
            append(token.code)
          }
        }
        .frame(width: 200)
      }
    }
  }

  // MARK: - Черновик

  private var templateBinding: Binding<String> {
    Binding(
      get: { draft.template(for: kind) },
      set: { draft.setTemplate($0, for: kind) }
    )
  }

  private var previewName: String {
    let template = draft.template(for: kind)
    let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
    let sampleContext = CaptureContext(appName: "Safari", windowTitle: "GitHub")
    let baseName = CaptureOutputNaming.resolveTemplateBaseName(
      trimmed.isEmpty ? kind.outputKind.defaultTemplate : trimmed,
      kind: kind.outputKind,
      context: sampleContext,
      options: draft.options,
      autoIncrement: max(1, draft.nextAutoIncrement)
    )
    return baseName
  }

  private func append(_ code: String) {
    draft.setTemplate(draft.template(for: kind) + code, for: kind)
  }

  /// Бросок в поле без активного редактирования дописывает элемент в конец.
  /// Во время редактирования строку на место курсора вставляет сам field editor.
  private func insertDroppedText(from providers: [NSItemProvider]) -> Bool {
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
      guard let text = object as? String, !text.isEmpty else { return }
      Task { @MainActor in append(text) }
    }
    return true
  }
}

/// Перетаскиваемый элемент формата: голубая плашка с кодом токена.
/// Клик тоже добавляет элемент в конец поля.
private struct OwnShotFileNameTokenChip: View {
  let code: String
  let onInsert: () -> Void

  var body: some View {
    Text(verbatim: code)
      .font(.system(size: 13))
      .frame(minWidth: 44)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(
        Radius.rect(Radius.controlXS)
          .fill(Color(red: 0.75, green: 0.87, blue: 1.0))
      )
      .foregroundStyle(Color.black)
      .contentShape(Rectangle())
      .onTapGesture(perform: onInsert)
      .onDrag { NSItemProvider(object: code as NSString) }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(code)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { onInsert() }
  }
}

/// Черновик sheet Customize…: шаблоны, флажки и следующий номер %i.
struct OwnShotFileNameFormatDraft: Equatable {
  enum Kind: Hashable {
    case screenshot
    case recording

    var outputKind: CaptureOutputKind {
      switch self {
      case .screenshot: return .screenshot
      case .recording: return .recording
      }
    }
  }

  var screenshotTemplate: String
  var recordingTemplate: String
  var options: CaptureFileNameOptions
  var nextAutoIncrement: Int

  static func load(defaults: UserDefaults = .standard) -> OwnShotFileNameFormatDraft {
    OwnShotFileNameFormatDraft(
      screenshotTemplate: defaults.string(forKey: PreferencesKeys.screenshotFileNameTemplate)
        ?? CaptureOutputKind.screenshot.defaultTemplate,
      recordingTemplate: defaults.string(forKey: PreferencesKeys.recordingFileNameTemplate)
        ?? CaptureOutputKind.recording.defaultTemplate,
      options: .current(defaults: defaults),
      nextAutoIncrement: CaptureOutputNaming.nextAutoIncrement(defaults: defaults)
    )
  }

  func template(for kind: Kind) -> String {
    switch kind {
    case .screenshot: return screenshotTemplate
    case .recording: return recordingTemplate
    }
  }

  mutating func setTemplate(_ template: String, for kind: Kind) {
    switch kind {
    case .screenshot: screenshotTemplate = template
    case .recording: recordingTemplate = template
    }
  }

  /// Restore Defaults сбрасывает форматы и флажки. Счётчик %i не трогается.
  mutating func restoreDefaults() {
    screenshotTemplate = CaptureOutputKind.screenshot.defaultTemplate
    recordingTemplate = CaptureOutputKind.recording.defaultTemplate
    options = .defaults
  }

  func save(to defaults: UserDefaults = .standard) {
    defaults.set(screenshotTemplate, forKey: PreferencesKeys.screenshotFileNameTemplate)
    defaults.set(recordingTemplate, forKey: PreferencesKeys.recordingFileNameTemplate)
    options.save(to: defaults)
    CaptureOutputNaming.setNextAutoIncrement(nextAutoIncrement, defaults: defaults)
  }
}
