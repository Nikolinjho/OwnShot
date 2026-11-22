//
//  CustomOCRModelStoreTests.swift
//  SnapzyTests
//
//  CRUD, persistence, Keychain cleanup, and selection-reset coverage.
//

import Foundation
import XCTest
@testable import Snapzy

@MainActor
final class CustomOCRModelStoreTests: XCTestCase {
  private var defaults: UserDefaults!
  private var keychain: FakeOCRKeychainStore!
  private var store: CustomOCRModelStore!

  override func setUp() {
    super.setUp()
    defaults = UserDefaultsFactory.make()
    keychain = FakeOCRKeychainStore()
    store = CustomOCRModelStore(defaults: defaults, keychainStore: keychain)
  }

  private func makeModel(
    id: UUID = UUID(),
    name: String = "Test Model",
    baseURL: String = "https://api.example.com",
    modelIdentifier: String = "test-model",
    prompt: String? = nil,
    hasAPIKey: Bool = false,
    updatedAt: Date = Date()
  ) -> CustomOCRModel {
    CustomOCRModel(
      id: id,
      name: name,
      baseURL: baseURL,
      modelIdentifier: modelIdentifier,
      prompt: prompt,
      hasAPIKey: hasAPIKey,
      updatedAt: updatedAt
    )
  }

  // MARK: - CRUD

  func testAddPersistsModelToDefaults() throws {
    let model = makeModel()
    store.add(model)

    XCTAssertEqual(store.models, [model])
    let data = try XCTUnwrap(defaults.data(forKey: PreferencesKeys.ocrCustomModels))
    XCTAssertEqual(try JSONDecoder().decode([CustomOCRModel].self, from: data), [model])
  }

  func testUpdateRenamesModelAndBumpsUpdatedAt() throws {
    let model = makeModel(name: "Old Name", updatedAt: Date(timeIntervalSince1970: 1000))
    store.add(model)

    var renamed = model
    renamed.name = "New Name"
    store.update(renamed)

    let stored = try XCTUnwrap(store.model(for: model.id))
    XCTAssertEqual(stored.name, "New Name")
    XCTAssertGreaterThan(stored.updatedAt, model.updatedAt)
    XCTAssertEqual(store.models.count, 1)
  }

  func testUpdateIgnoresUnknownModel() {
    store.add(makeModel())
    store.update(makeModel(name: "Ghost"))
    XCTAssertEqual(store.models.count, 1)
    XCTAssertEqual(store.models.first?.name, "Test Model")
  }

  func testRemoveDeletesModelAndKeychainEntry() async {
    let model = makeModel()
    store.add(model)
    keychain.seedKey("sk-secret", for: model.id)

    await store.remove(id: model.id)

    XCTAssertTrue(store.models.isEmpty)
    XCTAssertEqual(keychain.deletedIDs, [model.id])
    XCTAssertNil(keychain.readKey(for: model.id))
  }

  // MARK: - Selection reset

  func testRemoveResetsSelectionWhenRemovedModelWasActive() async {
    let model = makeModel()
    store.add(model)
    defaults.set("custom:\(model.id.uuidString)", forKey: PreferencesKeys.ocrSelectedModel)

    await store.remove(id: model.id)

    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.ocrSelectedModel), "builtin")
  }

  func testRemoveKeepsSelectionWhenOtherModelIsActive() async {
    let model = makeModel()
    store.add(model)
    defaults.set("dl:demo-model", forKey: PreferencesKeys.ocrSelectedModel)

    await store.remove(id: model.id)

    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.ocrSelectedModel), "dl:demo-model")
  }

  // MARK: - Persistence

  func testModelsPersistAcrossStoreInstances() {
    store.add(makeModel(name: "Alpha"))
    store.add(makeModel(name: "Beta"))

    let reloaded = CustomOCRModelStore(defaults: defaults, keychainStore: keychain)

    XCTAssertEqual(reloaded.models.map(\.name), ["Alpha", "Beta"])
  }

  func testCorruptPersistedJSONLoadsEmptyAndClearsKey() {
    defaults.set(Data("not json".utf8), forKey: PreferencesKeys.ocrCustomModels)

    let corruptStore = CustomOCRModelStore(defaults: defaults, keychainStore: keychain)

    XCTAssertTrue(corruptStore.models.isEmpty)
    XCTAssertNil(defaults.data(forKey: PreferencesKeys.ocrCustomModels))
  }

  /// The Phase 1 availability checker decodes stored models by their `"id"`
  /// key — the JSON encoding must keep it stable.
  func testStoredJSONKeepsIDKeyForAvailabilityChecker() throws {
    let model = makeModel()
    store.add(model)

    let data = try XCTUnwrap(defaults.data(forKey: PreferencesKeys.ocrCustomModels))
    let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    XCTAssertEqual(entries.first?["id"] as? String, model.id.uuidString)
    XCTAssertTrue(UserDefaultsOCRModelAvailability(defaults: defaults).customModelExists(id: model.id))
  }

  // MARK: - API key sync

  func testSetAPIKeyStoresKeyAndUpdatesFlag() async throws {
    let model = makeModel()
    store.add(model)

    try await store.setAPIKey("sk-live", for: model.id)

    XCTAssertEqual(keychain.readKey(for: model.id), "sk-live")
    XCTAssertEqual(store.model(for: model.id)?.hasAPIKey, true)
  }

  func testSetAPIKeyNilDeletesKeyAndClearsFlag() async throws {
    let model = makeModel(hasAPIKey: true)
    store.add(model)
    keychain.seedKey("sk-live", for: model.id)

    try await store.setAPIKey(nil, for: model.id)

    XCTAssertEqual(keychain.deletedIDs, [model.id])
    XCTAssertNil(keychain.readKey(for: model.id))
    XCTAssertEqual(store.model(for: model.id)?.hasAPIKey, false)
  }

  // MARK: - Keychain failure

  func testSetAPIKeyFailureKeepsFlagFalseAndModelIntact() async throws {
    let model = makeModel()
    store.add(model)
    keychain.saveError = OCRKeychainError.saveFailed(-25299)

    do {
      try await store.setAPIKey("sk-live", for: model.id)
      XCTFail("Ожидался отказ записи ключа")
    } catch let error as OCRKeychainError {
      XCTAssertEqual(error, .saveFailed(-25299))
    }

    XCTAssertEqual(store.model(for: model.id)?.hasAPIKey, false)
    XCTAssertNil(keychain.readKey(for: model.id))
    XCTAssertEqual(store.models.count, 1)

    // The store stays consistent, so a retry after recovery succeeds.
    keychain.saveError = nil
    try await store.setAPIKey("sk-live", for: model.id)
    XCTAssertEqual(store.model(for: model.id)?.hasAPIKey, true)
    XCTAssertEqual(keychain.readKey(for: model.id), "sk-live")
  }

  func testSaveChangesDoesNotPersistNewModelWhenKeychainFails() async throws {
    let model = makeModel()
    keychain.saveError = OCRKeychainError.saveFailed(-25299)

    do {
      try await store.saveChanges(model, editing: false, newAPIKey: "fixture-key")
      XCTFail("Ожидался отказ записи ключа")
    } catch let error as OCRKeychainError {
      XCTAssertEqual(error, .saveFailed(-25299))
    }
    XCTAssertTrue(store.models.isEmpty)
    XCTAssertNil(defaults.data(forKey: PreferencesKeys.ocrCustomModels))

    keychain.saveError = nil
    try await store.saveChanges(model, editing: false, newAPIKey: "fixture-key")
    XCTAssertEqual(store.models.count, 1)
    XCTAssertEqual(store.model(for: model.id)?.hasAPIKey, true)
    XCTAssertEqual(keychain.readKey(for: model.id), "fixture-key")
  }

  func testSaveChangesKeepsPreviousModelAndKeyWhenKeychainFails() async throws {
    let original = makeModel(name: "Original", hasAPIKey: true)
    store.add(original)
    keychain.seedKey("original-fixture", for: original.id)
    let originalData = defaults.data(forKey: PreferencesKeys.ocrCustomModels)
    var edited = original
    edited.name = "Edited"
    edited.baseURL = "https://edited.invalid"
    keychain.saveError = OCRKeychainError.saveFailed(-25299)

    do {
      try await store.saveChanges(edited, editing: true, newAPIKey: "replacement-fixture")
      XCTFail("Ожидался отказ записи ключа")
    } catch let error as OCRKeychainError {
      XCTAssertEqual(error, .saveFailed(-25299))
    }

    XCTAssertEqual(store.model(for: original.id), original)
    XCTAssertEqual(defaults.data(forKey: PreferencesKeys.ocrCustomModels), originalData)
    XCTAssertEqual(keychain.readKey(for: original.id), "original-fixture")
  }

  func testSaveChangesWithoutNewKeyKeepsStoredKey() async throws {
    let original = makeModel(name: "Original", hasAPIKey: true)
    store.add(original)
    keychain.seedKey("original-fixture", for: original.id)
    keychain.saveError = OCRKeychainError.saveFailed(-25299)
    var edited = original
    edited.name = "Edited"
    edited.hasAPIKey = false

    try await store.saveChanges(edited, editing: true, newAPIKey: nil)

    XCTAssertEqual(store.model(for: original.id)?.name, "Edited")
    XCTAssertEqual(store.model(for: original.id)?.hasAPIKey, true)
    XCTAssertEqual(keychain.readKey(for: original.id), "original-fixture")
  }

  func testSaveChangesDoesNotRestoreADeletedModel() async throws {
    let deleted = makeModel()
    keychain.saveError = OCRKeychainError.saveFailed(-25299)

    try await store.saveChanges(deleted, editing: true, newAPIKey: "fixture-key")

    XCTAssertTrue(store.models.isEmpty)
    XCTAssertNil(defaults.data(forKey: PreferencesKeys.ocrCustomModels))
    XCTAssertNil(keychain.readKey(for: deleted.id))
  }

  func testСохранениеИУдалениеКлючаНеЗанимаютГлавныйПоток() async throws {
    let store = CustomOCRModelStore(defaults: defaults, keychainStore: ThreadCheckingKeychain())
    let model = makeModel()

    try await store.saveChanges(model, editing: false, newAPIKey: "fixture-key")
    XCTAssertEqual(store.model(for: model.id)?.hasAPIKey, true)

    await store.remove(id: model.id)
    XCTAssertNil(store.model(for: model.id))
  }

  func testИмпортЖдётСохраненияНовойМоделиИУдаляетЕёКлюч() async throws {
    let model = makeModel()
    let saveEntered = expectation(description: "Keychain начал сохранение")
    let importReady = expectation(description: "Импорт вошёл в очередь")
    let keychain = PausedSaveKeychain(backing: keychain, saveEntered: saveEntered)
    let store = CustomOCRModelStore(defaults: defaults, keychainStore: keychain)
    let save = Task { try await store.saveChanges(model, editing: false, newAPIKey: "fixture-key") }
    await fulfillment(of: [saveEntered], timeout: 5)

    let replace = Task {
      importReady.fulfill()
      return await store.withModelMutation {
        let result = SnapzyConfigurationImporter.importTOML(
          """
          schema_version = 1
          [capture.ocr]
          custom_models = "[]"
          """,
          defaults: defaults,
          keychainStore: keychain
        )
        store.reloadFromDefaults()
        return result
      }
    }
    await fulfillment(of: [importReady], timeout: 5)
    keychain.resumeSave.signal()
    try await save.value
    let importResult = await replace.value

    XCTAssertFalse(importResult.hasErrors)
    XCTAssertNil(store.model(for: model.id))
    XCTAssertNil(keychain.readKey(for: model.id))
    XCTAssertEqual(keychain.backing.deletedIDs, [model.id])
  }

  private struct ThreadCheckingKeychain: OCRKeychainStoring {
    func readKey(for modelID: UUID) -> String? { nil }

    func saveKey(_ key: String, for modelID: UUID) throws {
      XCTAssertFalse(Thread.isMainThread)
    }

    func deleteKey(for modelID: UUID) {
      XCTAssertFalse(Thread.isMainThread)
    }
  }

  private struct PausedSaveKeychain: OCRKeychainStoring {
    let backing: FakeOCRKeychainStore
    let saveEntered: XCTestExpectation
    let resumeSave = DispatchSemaphore(value: 0)

    func readKey(for modelID: UUID) -> String? { backing.readKey(for: modelID) }

    func saveKey(_ key: String, for modelID: UUID) throws {
      saveEntered.fulfill()
      guard resumeSave.wait(timeout: .now() + 10) == .success else {
        XCTFail("Тест не возобновил запись ключа")
        throw OCRKeychainError.saveFailed(-1)
      }
      try backing.saveKey(key, for: modelID)
    }

    func deleteKey(for modelID: UUID) { backing.deleteKey(for: modelID) }
  }

  // MARK: - External reload

  func testReloadFromDefaultsPicksUpExternallyWrittenModels() throws {
    let external = makeModel(name: "External")
    defaults.set(try JSONEncoder().encode([external]), forKey: PreferencesKeys.ocrCustomModels)
    XCTAssertTrue(store.models.isEmpty)

    store.reloadFromDefaults()

    XCTAssertEqual(store.models, [external])
  }

  // MARK: - Router wiring

  func testResolverBuildsRemoteProviderForStoredCustomModel() {
    let model = makeModel()
    store.add(model)
    defaults.set("custom:\(model.id.uuidString)", forKey: PreferencesKeys.ocrSelectedModel)

    let resolution = OCRModelResolver(defaults: defaults).resolveStoredSelection()

    XCTAssertEqual(resolution.selection, .custom(model.id))
    XCTAssertEqual(resolution.provider.engine, .remote)
  }
}
