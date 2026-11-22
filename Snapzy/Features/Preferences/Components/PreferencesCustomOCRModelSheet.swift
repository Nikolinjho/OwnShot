//
//  PreferencesCustomOCRModelSheet.swift
//  Snapzy
//
//  Add/edit sheet for custom OpenAI-compatible OCR endpoints.
//

import SwiftUI

/// Add or edit a `CustomOCRModel`. A blank API key field while editing keeps
/// the existing Keychain key; a newly typed key overwrites it on save.
struct PreferencesCustomOCRModelSheet: View {
  let store: CustomOCRModelStore
  let editing: CustomOCRModel?
  let onDismiss: () -> Void

  @State private var name: String
  @State private var baseURL: String
  @State private var modelIdentifier: String
  @State private var apiKey = ""
  @State private var prompt: String
  @State private var isSaving = false
  @State private var isTesting = false
  @State private var testSucceeded: Bool?
  @State private var testMessage: String?
  @State private var saveError: String?

  init(store: CustomOCRModelStore, editing: CustomOCRModel?, onDismiss: @escaping () -> Void) {
    self.store = store
    self.editing = editing
    self.onDismiss = onDismiss
    _name = State(initialValue: editing?.name ?? "")
    _baseURL = State(initialValue: editing?.baseURL ?? "")
    _modelIdentifier = State(initialValue: editing?.modelIdentifier ?? "")
    _prompt = State(initialValue: editing?.prompt ?? "")
  }

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 8) {
        Image(systemName: "server.rack")
          .font(.system(size: 30))
          .foregroundColor(.accentColor)
        Text(editing == nil
          ? L10n.PreferencesCapture.ocrModelSheetAddTitle
          : L10n.PreferencesCapture.ocrModelSheetEditTitle)
          .font(.headline)
        Text(L10n.PreferencesCapture.ocrModelSheetDescription)
          .font(.system(size: 12))
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(alignment: .leading, spacing: 12) {
        field(L10n.PreferencesCapture.ocrModelSheetName) {
          TextField("", text: $name)
        }

        field(L10n.PreferencesCapture.ocrModelSheetBaseURL) {
          TextField("", text: $baseURL, prompt: Text(verbatim: "https://api.example.com/v1"))
        }

        field(L10n.PreferencesCapture.ocrModelSheetModelIdentifier) {
          TextField("", text: $modelIdentifier, prompt: Text(verbatim: "gpt-4o-mini"))
        }

        field(L10n.PreferencesCapture.ocrModelSheetAPIKey) {
          SecureField("", text: $apiKey)
          if editing?.hasAPIKey == true {
            Text(L10n.PreferencesCapture.ocrModelSheetAPIKeyKeepHint)
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }
        }

        field(L10n.PreferencesCapture.ocrModelSheetPrompt) {
          TextEditor(text: $prompt)
            .font(.system(size: 12))
            .frame(height: 60)
            .overlay(
              Radius.controlRect(forHeight: 60)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }

        if let testMessage {
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: testSucceeded == true ? "checkmark.circle.fill" : "xmark.circle.fill")
              .font(.system(size: 12))
              .foregroundColor(testSucceeded == true ? .green : .red)
            Text(testMessage)
              .font(.system(size: 11))
              .foregroundColor(testSucceeded == true ? .green : .red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        if let saveError {
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 12))
              .foregroundColor(.red)
            Text(saveError)
              .font(.system(size: 11))
              .foregroundColor(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .disabled(isSaving)

      HStack(spacing: 12) {
        Button(action: testConnection) {
          if isTesting {
            ProgressView()
              .controlSize(.small)
          } else {
            Text(L10n.PreferencesCapture.ocrModelTestConnection)
          }
        }
        .disabled(!isInputValid || isTesting || isSaving)

        Spacer()

        Button(L10n.Common.cancel) {
          guard !isSaving else { return }
          onDismiss()
        }
        .keyboardShortcut(.escape, modifiers: [])
        .disabled(isSaving)

        Button(action: save) {
          HStack(spacing: 6) {
            if isSaving {
              ProgressView()
                .controlSize(.small)
            }
            Text(L10n.Common.save)
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(!isInputValid || isSaving)
      }
    }
    .padding(24)
    .frame(width: 420)
    .interactiveDismissDisabled(isSaving)
  }

  // MARK: - Fields

  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
      content()
        .textFieldStyle(.roundedBorder)
    }
  }

  // MARK: - Validation

  private var isInputValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && Self.isValidBaseURL(baseURL)
  }

  /// Basic validation: parseable http(s) URL with a host.
  static func isValidBaseURL(_ string: String) -> Bool {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil
    else { return false }
    return true
  }

  /// Current field values as a model, used for both saving and test probes.
  private var draftModel: CustomOCRModel {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return CustomOCRModel(
      id: editing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      modelIdentifier: modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
      prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
      hasAPIKey: editing?.hasAPIKey ?? false,
      createdAt: editing?.createdAt ?? Date()
    )
  }

  // MARK: - Test Connection

  private func testConnection() {
    guard isInputValid, !isTesting, !isSaving else { return }
    isTesting = true
    testSucceeded = nil
    testMessage = nil

    // Введённый ключ используется только для запроса. С пустым полем запрос
    // к изменённому адресу выполняется без сохранённого ключа.
    let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = draftModel
    let provider: RemoteOCRProvider
    if typedKey.isEmpty, editing != nil {
      provider = RemoteOCRProvider(model: model, readStoredKey: { [store] in
        await store.storedAPIKey(for: model)
      })
    } else {
      provider = RemoteOCRProvider(
        model: model,
        keychainStore: EphemeralOCRKeychainStore(key: typedKey.isEmpty ? nil : typedKey)
      )
    }

    Task {
      let result = await provider.testConnection()
      isTesting = false
      switch result {
      case .success(let latency):
        testSucceeded = true
        testMessage = L10n.PreferencesCapture.ocrModelTestSuccessLatency(Int(latency * 1000))
      case .failure(let error):
        testSucceeded = false
        testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  // MARK: - Save

  private func save() {
    guard isInputValid, !isSaving else { return }
    let model = draftModel
    let isEditing = editing != nil
    let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

    isSaving = true
    saveError = nil
    Task {
      defer { isSaving = false }
      do {
        try await store.saveChanges(model, editing: isEditing, newAPIKey: typedKey)
        onDismiss()
      } catch {
        saveError = error.localizedDescription
      }
    }
  }
}

/// In-memory keychain used to probe a connection with unsaved credentials.
private struct EphemeralOCRKeychainStore: OCRKeychainStoring {
  let key: String?

  func readKey(for modelID: UUID) -> String? {
    key
  }

  func saveKey(_ key: String, for modelID: UUID) throws {}

  func deleteKey(for modelID: UUID) {}
}

#Preview {
  PreferencesCustomOCRModelSheet(store: .shared, editing: nil) {}
}
