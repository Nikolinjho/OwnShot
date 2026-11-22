//
//  PreferencesOCRModelListViewModel.swift
//  Snapzy
//
//  Selection and custom endpoint state for the OCR model list in Capture
//  preferences.
//

import Combine
import Foundation

/// View model behind `PreferencesOCRModelListView`.
@MainActor
final class PreferencesOCRModelListViewModel: ObservableObject {
  /// Identifiable payload for the add/edit custom model sheet; `editing == nil` means add.
  struct SheetRequest: Identifiable {
    let id = UUID()
    let editing: CustomOCRModel?
  }

  /// Identifiable payload for the connection-test result alert.
  struct ConnectionTestResult: Identifiable {
    let id = UUID()
    let title: String
    let message: String
  }

  @Published private(set) var selection: OCRModelSelection
  @Published var sheetRequest: SheetRequest?
  @Published var removeCustomCandidate: CustomOCRModel?
  @Published var connectionTestResult: ConnectionTestResult?
  @Published private(set) var testingConnectionModelID: UUID?
  @Published private(set) var removingModelIDs: Set<UUID> = []

  let customModelStore: CustomOCRModelStore
  private let defaults: UserDefaults
  private var cancellables: Set<AnyCancellable> = []

  init(
    defaults: UserDefaults = .standard,
    customModelStore: CustomOCRModelStore? = nil
  ) {
    self.defaults = defaults
    self.customModelStore = customModelStore ?? .shared
    selection = Self.storedSelection(defaults: defaults)

    // Forward store changes so the single @StateObject in the view re-renders.
    self.customModelStore.objectWillChange
      .sink { [weak self] in self?.objectWillChange.send() }
      .store(in: &cancellables)
    // Store-side selection resets (for example after config import or custom
    // model removal) land in UserDefaults; mirror them into the published
    // selection.
    self.customModelStore.$models
      .dropFirst()
      .sink { [weak self] _ in self?.refreshSelection() }
      .store(in: &cancellables)
  }

  static func storedSelection(defaults: UserDefaults) -> OCRModelSelection {
    guard let rawValue = defaults.string(forKey: PreferencesKeys.ocrSelectedModel) else { return .builtIn }
    let selection = OCRModelSelection(persistedValue: rawValue)
    if selection == .builtIn, rawValue != OCRModelSelection.builtIn.persistedValue {
      defaults.set(OCRModelSelection.builtIn.persistedValue, forKey: PreferencesKeys.ocrSelectedModel)
    }
    return selection
  }

  /// Re-reads the persisted selection after store-side resets.
  func refreshSelection() {
    selection = Self.storedSelection(defaults: defaults)
  }

  // MARK: - Selection

  func isSelected(_ selection: OCRModelSelection) -> Bool {
    self.selection == selection
  }

  /// Built-in is always selectable; custom endpoints are selectable while
  /// their configuration still exists.
  func isSelectable(_ selection: OCRModelSelection) -> Bool {
    switch selection {
    case .builtIn:
      true
    case .custom(let id):
      customModelStore.model(for: id) != nil && !removingModelIDs.contains(id)
    }
  }

  /// Persists the selection immediately; taps on missing custom rows are ignored.
  func select(_ selection: OCRModelSelection) {
    guard isSelectable(selection) else { return }
    self.selection = selection
    defaults.set(selection.persistedValue, forKey: PreferencesKeys.ocrSelectedModel)
  }

  // MARK: - Custom endpoints

  func removeCustom(_ model: CustomOCRModel) async {
    guard removingModelIDs.insert(model.id).inserted else { return }
    defer { removingModelIDs.remove(model.id) }
    // The store deletes the Keychain key and resets the persisted selection
    // when the removed model was active.
    await customModelStore.remove(id: model.id)
    refreshSelection()
  }

  func testConnection(for model: CustomOCRModel) {
    guard testingConnectionModelID == nil else { return }
    testingConnectionModelID = model.id
    let provider = RemoteOCRProvider(model: model, readStoredKey: { [customModelStore] in
      await customModelStore.storedAPIKey(for: model)
    })
    Task { [weak self] in
      let result = await provider.testConnection()
      guard let self else { return }
      testingConnectionModelID = nil
      switch result {
      case .success(let latency):
        connectionTestResult = ConnectionTestResult(
          title: L10n.PreferencesCapture.ocrModelTestSuccessTitle,
          message: L10n.PreferencesCapture.ocrModelTestSuccessLatency(Int(latency * 1000))
        )
      case .failure(let error):
        connectionTestResult = ConnectionTestResult(
          title: L10n.PreferencesCapture.ocrModelTestFailedTitle,
          message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
      }
    }
  }
}
