//
//  PostCaptureActionHandlerTests.swift
//  SnapzyTests
//
//  Unit tests for PostCaptureActionHandler routing logic.
//

import AppKit
import GRDB
import ImageIO
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class PostCaptureActionHandlerTests: XCTestCase {

  private var defaults: UserDefaults!
  private var preferences: PreferencesManager!
  private var tempDirectory: URL!
  private var tempFileURL: URL!
  private var canvasPresetStore: AnnotateCanvasPresetStore!
  private var screenshotPresetAutoApplier: ScreenshotPresetAutoApplier!

  override func setUp() async throws {
    try await super.setUp()
    defaults = UserDefaultsFactory.make()
    preferences = PreferencesManager(defaults: defaults)
    canvasPresetStore = AnnotateCanvasPresetStore(defaults: defaults)
    screenshotPresetAutoApplier = ScreenshotPresetAutoApplier(presetStore: canvasPresetStore)
    resetAfterCaptureActionsToDefaults()

    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_PostCapture_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    // Create a minimal test image file
    tempFileURL = tempDirectory.appendingPathComponent("test_capture.png")
    guard let image = TestImageFactory.solidColor(width: 10, height: 10) else {
      XCTFail("Failed to create test image")
      return
    }
    let bitmapRep = NSBitmapImageRep(cgImage: image)
    let pngData = bitmapRep.representation(using: .png, properties: [:])
    try pngData?.write(to: tempFileURL)
  }

  override func tearDown() async throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    try await super.tearDown()
  }

  private func resetAfterCaptureActionsToDefaults() {
    preferences.afterCaptureActions = Self.defaultAfterCaptureActions()
  }

  private static func defaultAfterCaptureActions() -> [AfterCaptureAction: [CaptureType: Bool]] {
    var defaults: [AfterCaptureAction: [CaptureType: Bool]] = [:]
    for action in AfterCaptureAction.allCases {
      defaults[action] = [:]
      for captureType in CaptureType.allCases {
        defaults[action]?[captureType] = defaultValue(for: action)
      }
    }
    return defaults
  }

  private static func defaultValue(for action: AfterCaptureAction) -> Bool {
    switch action {
    case .showQuickAccess, .save, .copyFile:
      return true
    case .openAnnotate, .pinToScreen, .openVideoEditor:
      return false
    }
  }

  private func makeHandler(
    quickAccess: QuickAccessManaging,
    history: CaptureHistoryStore = .shared
  ) -> PostCaptureActionHandler {
    PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared,
      screenshotPresetAutoApplier: screenshotPresetAutoApplier,
      history: history
    )
  }

  private func writeTestImage(to url: URL, width: Int = 100, height: Int = 100) throws {
    guard let image = TestImageFactory.solidColor(width: width, height: height) else {
      XCTFail("Failed to create test image")
      return
    }
    let bitmapRep = NSBitmapImageRep(cgImage: image)
    let pngData = bitmapRep.representation(using: .png, properties: [:])
    try pngData?.write(to: url)
  }

  private func imagePixelSize(at url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat else {
      return nil
    }
    return CGSize(width: width, height: height)
  }

  private func saveDefaultPreset(
    padding: CGFloat = 10,
    backgroundStyle: Snapzy.BackgroundStyle = .solidColor(SwiftUI.Color.red)
  ) -> AnnotateCanvasPreset {
    let preset = AnnotateCanvasPreset(
      name: "Default Share",
      payload: AnnotateCanvasPresetPayload(
        backgroundStyle: CodableBackgroundStyle(from: backgroundStyle)!,
        padding: padding,
        shadowIntensity: 0,
        cornerRadius: 0
      )
    )
    canvasPresetStore.savePresets([preset])
    canvasPresetStore.saveDefaultPresetId(preset.id)
    return preset
  }

  // MARK: - PreferencesManager Routing Logic

  func testIsActionEnabled_defaultValues() {
    // Default: showQuickAccess and copyFile are ON for both types
    XCTAssertTrue(preferences.isActionEnabled(.showQuickAccess, for: .screenshot))
    XCTAssertTrue(preferences.isActionEnabled(.showQuickAccess, for: .recording))
    XCTAssertTrue(preferences.isActionEnabled(.copyFile, for: .screenshot))
    XCTAssertTrue(preferences.isActionEnabled(.copyFile, for: .recording))
    XCTAssertTrue(preferences.isActionEnabled(.save, for: .screenshot))
    XCTAssertTrue(preferences.isActionEnabled(.save, for: .recording))

    // Default: openAnnotate is OFF
    XCTAssertFalse(preferences.isActionEnabled(.openAnnotate, for: .screenshot))
    XCTAssertFalse(preferences.isActionEnabled(.openAnnotate, for: .recording))
  }

  func testSetAndCheckActionEnabled() {
    // Disable quickAccess for screenshots
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    XCTAssertFalse(preferences.isActionEnabled(.showQuickAccess, for: .screenshot))

    // Re-enable
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: true)
    XCTAssertTrue(preferences.isActionEnabled(.showQuickAccess, for: .screenshot))
  }

  func testScreenshotHistoryUsesSourceFromTheSavedCapture() async throws {
    let database = try DatabaseManager.openDatabase(at: tempDirectory.appendingPathComponent("history.sqlite"))
    defer { XCTAssertNoThrow(try database.dbPool.close()) }
    let history = CaptureHistoryStore(databasePool: database.dbPool)
    history.userDefaults = defaults
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let oldSource = CaptureSourceApplication.currentBundleID
    defer { CaptureSourceApplication.note(bundleID: oldSource) }

    let finder = "com.apple.finder"
    let safari = "com.apple.Safari"
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess, history: history)
    CaptureSourceApplication.note(bundleID: finder)
    let first = try await saveScreenshotForAttribution(named: "first", appName: "Finder", bundleID: finder)
    CaptureSourceApplication.note(bundleID: safari)
    let second = try await saveScreenshotForAttribution(named: "second", appName: "Safari", bundleID: safari)
    quickAccess.onAddScreenshot = { url in
      if url == first {
        CaptureSourceApplication.note(bundleID: "com.apple.TextEdit")
      }
    }

    await handler.handleScreenshotCapture(url: first)
    await handler.handleScreenshotCapture(url: second)

    history.refreshRecords()
    let firstRecord = try XCTUnwrap(history.records.first { $0.filePath == first.path })
    let secondRecord = try XCTUnwrap(history.records.first { $0.filePath == second.path })
    XCTAssertEqual(firstRecord.sourceAppBundleID, finder)
    XCTAssertEqual(secondRecord.sourceAppBundleID, safari)
    XCTAssertEqual(firstRecord.fileName, "first.png")
    XCTAssertEqual(secondRecord.fileName, "second.png")
  }

  func testScreenshotBatchAttributesEachFileAndDoesNotBorrowUnknownSource() async throws {
    let database = try DatabaseManager.openDatabase(at: tempDirectory.appendingPathComponent("history.sqlite"))
    defer { XCTAssertNoThrow(try database.dbPool.close()) }
    let history = CaptureHistoryStore(databasePool: database.dbPool)
    history.userDefaults = defaults
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let oldSource = CaptureSourceApplication.currentBundleID
    defer { CaptureSourceApplication.note(bundleID: oldSource) }

    let safari = "com.apple.Safari"
    // Scrolling captures supply only attribution metadata, without changing filename tokens.
    let scrolling = try await saveScreenshotForAttribution(named: "scrolling", appName: nil, bundleID: safari)
    let unknown = try await saveScreenshotForAttribution(named: "unknown", appName: nil, bundleID: nil)
    let quickAccess = FakeQuickAccessManager()
    quickAccess.onAddScreenshot = { _ in CaptureSourceApplication.note(bundleID: "com.apple.TextEdit") }
    let handler = makeHandler(quickAccess: quickAccess, history: history)

    await handler.handleScreenshotCaptures(urls: [scrolling, unknown])

    history.refreshRecords()
    let scrollingRecord = try XCTUnwrap(history.records.first { $0.filePath == scrolling.path })
    let unknownRecord = try XCTUnwrap(history.records.first { $0.filePath == unknown.path })
    XCTAssertEqual(scrollingRecord.sourceAppBundleID, safari)
    XCTAssertNil(unknownRecord.sourceAppBundleID)
    XCTAssertEqual(scrollingRecord.fileName, "scrolling.png")
  }

  private func saveScreenshotForAttribution(named name: String, appName: String?, bundleID: String?) async throws -> URL {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 32, height: 16))
    let context = CaptureContext(appName: appName, windowTitle: nil, sourceAppBundleID: bundleID).withoutNamePrompt()
    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      image,
      to: tempDirectory,
      fileName: name,
      format: .png,
      emitCompletion: false,
      context: context,
      outputAlreadyProcessed: true
    )
    guard case .success(let url) = result else { throw CocoaError(.fileWriteUnknown) }
    // Do not let physical Ctrl state route this synthetic capture to the system clipboard.
    _ = OwnShotScreenshotCaptureMetadata.shared.consumeClipboardCopy(for: url)
    return url
  }

  // MARK: - Missing File Safety

  func testHandleScreenshotCapture_missingFile_doesNotAddToQuickAccess() async {
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)
    let nonexistentURL = tempDirectory.appendingPathComponent("does_not_exist.png")

    await handler.handleScreenshotCapture(url: nonexistentURL)

    XCTAssertEqual(fakeQuickAccess.addedScreenshots.count, 0)
  }

  func testHandleVideoCapture_missingFile_doesNotAddToQuickAccess() async {
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)
    let nonexistentURL = tempDirectory.appendingPathComponent("does_not_exist.mov")

    await handler.handleVideoCapture(url: nonexistentURL)

    XCTAssertEqual(fakeQuickAccess.addedVideos.count, 0)
  }

  func testHandleScreenshotCaptures_multipleFiles_addsAllToQuickAccess() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let secondURL = tempDirectory.appendingPathComponent("test_capture_2.png")
    try FileManager.default.copyItem(at: tempFileURL, to: secondURL)
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleScreenshotCaptures(urls: [tempFileURL, secondURL])

    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL, secondURL])
  }

  func testПакетСкриншотовЗакрепляетКаждыйЭкранПоНастройке() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    preferences.setAction(.pinToScreen, for: .screenshot, enabled: true)
    let secondURL = tempDirectory.appendingPathComponent("second_screen.png")
    try FileManager.default.copyItem(at: tempFileURL, to: secondURL)
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess)
    await handler.handleScreenshotCaptures(urls: [tempFileURL, secondURL])
    XCTAssertEqual(quickAccess.pinnedScreenshotIDs.count, 2)
    XCTAssertTrue(quickAccess.pinnedScreenshotURLs.isEmpty)
  }

  func testПакетЗакрепляетсяБезОверлеяБыстрогоДоступа() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    preferences.setAction(.pinToScreen, for: .screenshot, enabled: true)
    let secondURL = tempDirectory.appendingPathComponent("second_screen.png")
    try FileManager.default.copyItem(at: tempFileURL, to: secondURL)
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess)
    await handler.handleScreenshotCaptures(urls: [tempFileURL, secondURL])
    XCTAssertEqual(quickAccess.pinnedScreenshotURLs, [tempFileURL, secondURL])
  }

  func testHandleScreenshotCaptures_filtersMissingFiles() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let missingURL = tempDirectory.appendingPathComponent("missing.png")
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleScreenshotCaptures(urls: [missingURL, tempFileURL])

    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL])
  }

  func testCaptureAreaAndCopyКопируетПриВыключенномАвтокопированииБезQuickAccessИЗакрепления() async throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    let database = try DatabaseManager.openDatabase(at: tempDirectory.appendingPathComponent("copy-history.sqlite"))
    defer { XCTAssertNoThrow(try database.dbPool.close()) }
    let history = CaptureHistoryStore(databasePool: database.dbPool)
    history.userDefaults = defaults
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: true)
    preferences.setAction(.pinToScreen, for: .screenshot, enabled: true)
    let pasteboard = ClipboardHelper.pasteboard
    pasteboard.clearContents()
    pasteboard.setString("Последнее значение", forType: .string)
    defer { pasteboard.clearContents() }
    preferences.setAction(.openAnnotate, for: .screenshot, enabled: true)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 12, height: 10))
    let context = CaptureContext.empty.withoutNamePrompt().requestingCopyOnly(true)
    let result = await ScreenCaptureManager.shared.saveProcessedImage(image, to: tempDirectory,
      fileName: "clipboard-only", emitCompletion: false, context: context)
    guard case .success(let savedURL) = result else { return XCTFail("Не удалось сохранить PNG фикстуры") }
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess, history: history)
    let editorWindows = {
      NSApp.windows.compactMap { $0 as? AnnotateWindow }.filter { $0.interactionState?.sourceURL == savedURL }
    }
    defer { editorWindows().forEach { $0.close() } }

    let card = await handler.handleScreenshotCapture(url: savedURL)

    XCTAssertNil(card)
    XCTAssertTrue(editorWindows().isEmpty)
    XCTAssertNotNil(pasteboard.data(forType: .png))
    XCTAssertTrue(quickAccess.addedScreenshots.isEmpty)
    XCTAssertTrue(quickAccess.pinnedScreenshotURLs.isEmpty)
    XCTAssertTrue(quickAccess.pinnedScreenshotIDs.isEmpty)
    history.refreshRecords()
    XCTAssertEqual(history.records.map(\.fileURL), [savedURL])
  }

  func testЯвныйCopyСохраняетФорматИВыполняетсяОдинРазПриЛюбомAutoCopy() async throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    let pasteboard = ClipboardHelper.pasteboard
    let systemDefaults = UserDefaults.standard
    let preference = PreferencesKeys.clipboardImageContent
    let previousPreference = systemDefaults.object(forKey: preference)
    defer {
      pasteboard.clearContents()
      systemDefaults.set(previousPreference, forKey: preference)
    }
    let model = ScreenCaptureViewModel()
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 14, height: 9, red: 10, green: 190, blue: 30))
    let context = CaptureContext.empty.withoutNamePrompt().requestingCopy(true)

    for autoCopyEnabled in [false, true] {
      preferences.setAction(.copyFile, for: .screenshot, enabled: autoCopyEnabled)
      for option in ClipboardImageContentOption.allCases {
        systemDefaults.set(option.rawValue, forKey: preference)
        let result = await ScreenCaptureManager.shared.saveProcessedImage(image, to: tempDirectory,
          fileName: "url-copy-\(autoCopyEnabled)-\(option.rawValue)", emitCompletion: false, context: context)
        guard case .success(let url) = result else { return XCTFail("Не удалось сохранить PNG фикстуры") }
        defer { CaptureHistoryStore.shared.removeByFilePath(url.path) }
        let data = try Data(contentsOf: url)
        let quickAccess = FakeQuickAccessManager()
        let handler = makeHandler(quickAccess: quickAccess)

        pasteboard.clearContents()
        let beforeSample = pasteboard.changeCount
        XCTAssertTrue(ClipboardHelper.copyImage(from: url))
        let changesForOneCopy = pasteboard.changeCount - beforeSample
        XCTAssertGreaterThan(changesForOneCopy, 0)

        pasteboard.clearContents()
        let beforeCapture = pasteboard.changeCount
        model.completeAreaCapture(result, action: "copy")
        await handler.handleScreenshotCapture(url: url)

        XCTAssertEqual(pasteboard.changeCount - beforeCapture, changesForOneCopy)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        let fileURL = item.string(forType: .fileURL).flatMap(URL.init(string:))
        XCTAssertEqual(fileURL?.standardizedFileURL, option == .imageOnly ? nil : url.standardizedFileURL)
        XCTAssertEqual(item.data(forType: .png), option == .fileOnly ? nil : data)
        XCTAssertEqual(quickAccess.addedScreenshots, [url])
      }
    }
  }

  func testЯвныйAnnotateОткрываетОдноОкноПриЛюбомAutoAnnotate() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 24, height: 16))
    let model = ScreenCaptureViewModel()
    let handler = makeHandler(quickAccess: FakeQuickAccessManager())
    let context = CaptureContext.empty.withoutNamePrompt().requestingAnnotation(true)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)

    for autoAnnotateEnabled in [false, true] {
      preferences.setAction(.openAnnotate, for: .screenshot, enabled: autoAnnotateEnabled)
      let result = await ScreenCaptureManager.shared.saveProcessedImage(image, to: tempDirectory,
        fileName: "url-annotate-\(autoAnnotateEnabled)", emitCompletion: false, context: context)
      guard case .success(let url) = result else { return XCTFail("Не удалось сохранить PNG фикстуры") }

      func editorsForCapture() -> [AnnotateWindow] {
        NSApp.windows.compactMap { $0 as? AnnotateWindow }
          .filter { $0.interactionState?.sourceURL == url }
      }
      defer {
        editorsForCapture().forEach { $0.close() }
        CaptureHistoryStore.shared.removeByFilePath(url.path)
      }

      model.completeAreaCapture(result, action: "annotate")
      await handler.handleScreenshotCapture(url: url)

      let editors = editorsForCapture().filter(\.isVisible)
      XCTAssertEqual(editors.count, 1)
      XCTAssertEqual(editors.first?.interactionState?.sourceImage?.size, CGSize(width: 24, height: 16))
    }
  }

  func testЯвныйAnnotateСAutoPinСохраняетРедактируемыйПресет() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let url = try XCTUnwrap(tempFileURL)
    let history = CaptureHistoryStore.shared
    let previousDefaults = history.userDefaults
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    history.userDefaults = defaults
    defer {
      history.userDefaults = previousDefaults
      AnnotationSessionStore.shared.deleteSession(for: url)
    }
    XCTAssertFalse(AnnotationSessionStore.shared.shouldPersist(for: url))
    let originalSize = try XCTUnwrap(imagePixelSize(at: url))
    _ = saveDefaultPreset(padding: 12)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    preferences.setAction(.openAnnotate, for: .screenshot, enabled: false)
    preferences.setAction(.pinToScreen, for: .screenshot, enabled: true)
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess)
    OwnShotScreenshotCaptureMetadata.shared.register(url: url, bypassesDefaultPreset: false, opensInAnnotate: true)

    await handler.handleScreenshotCapture(url: url)

    let editors = NSApp.windows.compactMap { $0 as? AnnotateWindow }
      .filter { $0.interactionState?.sourceURL == url }
    defer { editors.forEach { $0.close() } }
    XCTAssertEqual(quickAccess.pinnedScreenshotURLs, [url])
    XCTAssertTrue(quickAccess.addedScreenshots.isEmpty)
    XCTAssertEqual(editors.filter(\.isVisible).count, 1)
    let state = try XCTUnwrap(editors.first?.interactionState)
    XCTAssertEqual(state.padding, 12)
    XCTAssertEqual(state.sourceImage?.size, originalSize)
    let exportedSize = try XCTUnwrap(imagePixelSize(at: url))
    XCTAssertGreaterThan(exportedSize.width, originalSize.width)
  }

  func testHandleScreenshotCapture_copiesToClipboardBeforeQuickAccess() async throws {
    let pasteboard = ClipboardHelper.pasteboard
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)

    let expectedURL = try XCTUnwrap(tempFileURL)
    let fakeQuickAccess = FakeQuickAccessManager()
    fakeQuickAccess.onAddScreenshot = { url in
      XCTAssertEqual(url, expectedURL)
      let item = ClipboardHelper.pasteboard.pasteboardItems?.first
      XCTAssertTrue(item?.types.contains(.fileURL) ?? false)
      XCTAssertTrue(item?.types.contains(.png) ?? false)
      XCTAssertEqual(
        (ClipboardHelper.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.standardizedFileURL,
        expectedURL.standardizedFileURL
      )
    }
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleScreenshotCapture(url: tempFileURL)

    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL])
  }

  func testHandleVideoCapture_copiesMediaFileToClipboardBeforeQuickAccess() async throws {
    let videoURL = tempDirectory.appendingPathComponent("test_recording.mp4")
    try Data([0, 1, 2, 3]).write(to: videoURL)

    let pasteboard = ClipboardHelper.pasteboard
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)

    let fakeQuickAccess = FakeQuickAccessManager()
    fakeQuickAccess.onAddVideo = { url in
      XCTAssertEqual(url, videoURL)
      let item = ClipboardHelper.pasteboard.pasteboardItems?.first
      XCTAssertTrue(item?.types.contains(.fileURL) ?? false)
      XCTAssertTrue(item?.types.contains(.URL) ?? false)
      XCTAssertTrue(item?.types.contains(.string) ?? false)
      XCTAssertEqual(item?.string(forType: .URL), videoURL.absoluteString)
      XCTAssertEqual(item?.string(forType: .string), videoURL.path)
      XCTAssertEqual(
        (ClipboardHelper.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.standardizedFileURL,
        videoURL.standardizedFileURL
      )
    }
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleVideoCapture(url: videoURL)

    XCTAssertEqual(fakeQuickAccess.addedVideos, [videoURL])
  }

  func testГотовыйGifОткрываетРедакторТолькоПослеВключенияНастройки() async throws {
    try XCTSkipIf(NSScreen.screens.isEmpty)
    let manager = VideoEditorManager.shared
    defer { manager.closeAll() }
    let gifURL = tempDirectory.appendingPathComponent("finished_recording.gif")
    try TestImageFactory.writeAnimatedGIF(to: gifURL)
    preferences.setAction(.copyFile, for: .recording, enabled: false)
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess)

    await handler.handleVideoCapture(url: gifURL, skipQuickAccess: true)
    XCTAssertFalse(manager.isEditingFile(at: gifURL))

    preferences.setAction(.openVideoEditor, for: .recording, enabled: true)
    await handler.handleVideoCapture(url: gifURL, skipQuickAccess: true)

    XCTAssertTrue(manager.isEditingFile(at: gifURL))
    XCTAssertTrue(quickAccess.addedVideos.isEmpty)
  }

  func testГотовыйGifОткрываетсяЧерезСуществующуюКарточку() async throws {
    try XCTSkipIf(NSScreen.screens.isEmpty)
    let editor = VideoEditorManager.shared
    let quickAccess = QuickAccessManager.shared
    let wasEnabled = quickAccess.isEnabled
    quickAccess.isEnabled = true
    defer { quickAccess.isEnabled = wasEnabled }
    let gifURL = tempDirectory.appendingPathComponent("finished_recording_with_card.gif")
    try TestImageFactory.writeAnimatedGIF(to: gifURL)
    let addedItem = await quickAccess.addVideo(url: gifURL)
    let item = try XCTUnwrap(addedItem)
    defer {
      editor.closeAll()
      quickAccess.removeItem(id: item.id)
    }
    preferences.setAction(.openVideoEditor, for: .recording, enabled: true)
    preferences.setAction(.copyFile, for: .recording, enabled: false)

    await makeHandler(quickAccess: quickAccess).handleVideoCapture(url: gifURL, skipQuickAccess: true)

    let matchingItems = quickAccess.items.filter { $0.url == gifURL }
    XCTAssertEqual(matchingItems.map(\.id), [item.id])
    XCTAssertEqual(matchingItems.first?.isWindowOpen, true)
  }

  func testНастройкаРедактораЗаписейЗагружаетсяПоверхСтарыхНастроек() throws {
    defaults.set(Data(#"{"save":{"recording":false},"copyFile":{"recording":true}}"#.utf8), forKey: "afterCaptureActions")
    let manager = PreferencesManager(defaults: defaults)
    let action = AfterCaptureAction.openVideoEditor

    XCTAssertFalse(manager.isActionEnabled(action, for: .recording))
    XCTAssertFalse(manager.isActionEnabled(.save, for: .recording))
    XCTAssertTrue(manager.isActionEnabled(.copyFile, for: .recording))

    manager.setAction(action, for: .recording, enabled: true)
    XCTAssertTrue(PreferencesManager(defaults: defaults).isActionEnabled(action, for: .recording))
    XCTAssertFalse(PreferencesManager.applicableActions(for: .screenshot).contains(action))
    XCTAssertTrue(PreferencesManager.applicableActions(for: .recording).contains(action))

    manager.setAction(action, for: .screenshot, enabled: true)
    XCTAssertFalse(manager.isActionEnabled(action, for: .screenshot))
  }

  func testScreenshotPresetAutoApplier_noDefaultPreset_preservesOriginalFile() throws {
    let beforeData = try Data(contentsOf: tempFileURL)

    let sessionData = screenshotPresetAutoApplier.applyDefaultPresetIfNeeded(to: tempFileURL)

    XCTAssertNil(sessionData)
    XCTAssertEqual(try Data(contentsOf: tempFileURL), beforeData)
  }

  func testScreenshotPresetAutoApplier_validPresetRendersFileAndReturnsEditableSession() throws {
    let preset = saveDefaultPreset(padding: 12)
    let beforeSize = try XCTUnwrap(imagePixelSize(at: tempFileURL))
    let beforeData = try Data(contentsOf: tempFileURL)

    let sessionData = try XCTUnwrap(
      screenshotPresetAutoApplier.applyDefaultPresetIfNeeded(to: tempFileURL)
    )
    let afterSize = try XCTUnwrap(imagePixelSize(at: tempFileURL))

    XCTAssertGreaterThan(afterSize.width, beforeSize.width)
    XCTAssertGreaterThan(afterSize.height, beforeSize.height)
    XCTAssertEqual(sessionData.originalImageData, beforeData)
    XCTAssertEqual(sessionData.selectedCanvasPresetId, preset.id)
    XCTAssertEqual(sessionData.canvasEffects.padding, 12)
    XCTAssertEqual(sessionData.annotations.count, 0)
  }

  func testScreenshotPresetAutoApplier_stalePresetClearsDefaultAndPreservesFile() throws {
    defaults.set(UUID().uuidString, forKey: PreferencesKeys.annotateDefaultCanvasPresetId)
    let beforeData = try Data(contentsOf: tempFileURL)

    let sessionData = screenshotPresetAutoApplier.applyDefaultPresetIfNeeded(to: tempFileURL)

    XCTAssertNil(sessionData)
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.annotateDefaultCanvasPresetId))
    XCTAssertEqual(try Data(contentsOf: tempFileURL), beforeData)
  }

  func testHandleScreenshotCapture_appliesPresetBeforeQuickAccessReceivesURL() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    _ = saveDefaultPreset(padding: 12)
    let beforeSize = try XCTUnwrap(imagePixelSize(at: tempFileURL))
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleScreenshotCapture(url: tempFileURL)
    let afterSize = try XCTUnwrap(imagePixelSize(at: tempFileURL))

    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL])
    XCTAssertGreaterThan(afterSize.width, beforeSize.width)
    XCTAssertGreaterThan(afterSize.height, beforeSize.height)
  }

  func testHandleScreenshotCapture_cachesAutoAppliedPresetSessionForQuickAccessItem() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let preset = saveDefaultPreset(padding: 12)
    let beforeData = try Data(contentsOf: tempFileURL)
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleScreenshotCapture(url: tempFileURL)

    let item = try XCTUnwrap(fakeQuickAccess.createdScreenshotItems.first)
    let sessionData = try XCTUnwrap(AnnotateManager.shared.getSessionData(for: item.id))
    XCTAssertEqual(sessionData.originalImageData, beforeData)
    XCTAssertEqual(sessionData.selectedCanvasPresetId, preset.id)
    XCTAssertEqual(sessionData.canvasEffects.padding, 12)

    AnnotateManager.shared.clearSessionData(for: item.id)
  }

  func testHandleScreenshotCapture_pinToScreenPinsCreatedQuickAccessItem() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    let returnedItem = await handler.handleScreenshotCapture(url: tempFileURL, pinToScreen: true)

    let item = try XCTUnwrap(fakeQuickAccess.createdScreenshotItems.first)
    XCTAssertEqual(returnedItem?.id, item.id)
    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL])
    XCTAssertEqual(fakeQuickAccess.pinnedScreenshotIDs, [item.id])
    XCTAssertTrue(fakeQuickAccess.pinnedScreenshotURLs.isEmpty)
  }

  func testHandleScreenshotCapture_pinToScreenPinsURLWhenQuickAccessActionDisabled() async throws {
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    let returnedItem = await handler.handleScreenshotCapture(url: tempFileURL, pinToScreen: true)

    XCTAssertNotNil(returnedItem)
    XCTAssertTrue(fakeQuickAccess.addedScreenshots.isEmpty)
    XCTAssertTrue(fakeQuickAccess.pinnedScreenshotIDs.isEmpty)
    XCTAssertEqual(fakeQuickAccess.pinnedScreenshotURLs, [tempFileURL])
  }

  func testНастройкаЗакрепленияНеДублируетЯвноеЗакрепление() async throws {
    preferences.setAction(.pinToScreen, for: .screenshot, enabled: true)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess)
    await handler.handleScreenshotCapture(url: tempFileURL, pinToScreen: true)
    XCTAssertEqual(quickAccess.pinnedScreenshotIDs.count, 1)
  }

  func testЗапросЗахватаЗакрепляетОдинРазБезQuickAccessПриОбоихЗначенияхНастройки() async throws {
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    for automaticPin in [false, true] {
      preferences.setAction(.pinToScreen, for: .screenshot, enabled: automaticPin)
      let quickAccess = FakeQuickAccessManager()
      let handler = makeHandler(quickAccess: quickAccess)
      OwnShotScreenshotCaptureMetadata.shared.register(url: tempFileURL,
        bypassesDefaultPreset: false, pinsToScreen: true)
      await handler.handleScreenshotCapture(url: tempFileURL)
      XCTAssertEqual(quickAccess.pinnedScreenshotURLs, [tempFileURL])
      XCTAssertTrue(quickAccess.pinnedScreenshotIDs.isEmpty)
      XCTAssertTrue(quickAccess.addedScreenshots.isEmpty)
      XCTAssertFalse(OwnShotScreenshotCaptureMetadata.shared.consumePin(for: tempFileURL))
    }
  }

  func testНастройкаЗакрепляетСкриншотБезЯвногоЗапроса() async throws {
    preferences.setAction(.pinToScreen, for: .screenshot, enabled: true)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let quickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: quickAccess)
    await handler.handleScreenshotCapture(url: tempFileURL)
    XCTAssertEqual(quickAccess.pinnedScreenshotIDs.count, 1)
  }

  // MARK: - AfterCaptureAction Properties

  func testAfterCaptureAction_allCases() {
    let allCases = AfterCaptureAction.allCases
    XCTAssertEqual(allCases.count, 6)
    XCTAssertTrue(allCases.contains(.showQuickAccess))
    XCTAssertTrue(allCases.contains(.copyFile))
    XCTAssertTrue(allCases.contains(.save))
    XCTAssertTrue(allCases.contains(.openAnnotate))
    XCTAssertTrue(allCases.contains(.pinToScreen))
    XCTAssertTrue(allCases.contains(.openVideoEditor))
  }

  func testAfterCaptureAction_displayNames_nonEmpty() {
    for action in AfterCaptureAction.allCases {
      XCTAssertFalse(action.displayName.isEmpty, "\(action.rawValue) has empty displayName")
    }
  }

  // MARK: - CaptureType Properties

  func testCaptureType_allCases() {
    XCTAssertEqual(CaptureType.allCases.count, 2)
    XCTAssertTrue(CaptureType.allCases.contains(.screenshot))
    XCTAssertTrue(CaptureType.allCases.contains(.recording))
  }

  func testCaptureType_rawValues() {
    XCTAssertEqual(CaptureType.screenshot.rawValue, "screenshot")
    XCTAssertEqual(CaptureType.recording.rawValue, "recording")
  }

  func testCaptureType_displayNames_nonEmpty() {
    for type in CaptureType.allCases {
      XCTAssertFalse(type.displayName.isEmpty, "\(type.rawValue) has empty displayName")
    }
  }
}
