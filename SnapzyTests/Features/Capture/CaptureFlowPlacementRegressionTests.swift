import AppKit
import ImageIO
import ScreenCaptureKit
import XCTest
@testable import Snapzy

@MainActor
final class CaptureFlowPlacementRegressionTests: XCTestCase {
  func testКонфигурацияСвежегоЗахватаПоддерживаетВключённыйИВыключенныйКурсор() async throws {
    try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Требуется разрешение Screen Recording для Test Host")
    let screen = try XCTUnwrap(NSScreen.main)
    let rect = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 32, height: 32)
    for showCursor in [true, false] {
      let prepared = try await ScreenCaptureManager.shared.prepareAreaCapture(rect: rect, showCursor: showCursor)
      XCTAssertEqual(prepared.configuration.showsCursor, showCursor)
    }
  }
  override func tearDown() {
    AreaSelectionController.shared.cancelSelection()
    CaptureDelayCountdownController.shared.cancel()
    super.tearDown()
  }

  func testПанельAllInOneСтрогоВышеИнтерактивныхСлоёв() throws {
    try skipIfRunningInCI("Требуется окно All-in-One")
    let model = ScreenCaptureViewModel()
    let controller = OwnShotAllInOneController.shared
    controller.present(viewModel: model)
    defer { controller.dismiss() }
    let fields = Mirror(reflecting: controller).children
    let panel = try XCTUnwrap(fields.first { $0.label == "panel" }?.value as? NSPanel)
    let overlays = try XCTUnwrap(fields.first { $0.label == "overlays" }?.value as? [RecordingRegionOverlayWindow])
    XCTAssertFalse(overlays.isEmpty)
    for overlay in overlays {
      XCTAssertGreaterThan(panel.level.rawValue, overlay.level.rawValue)
    }
  }

  func testAllInOneИспользуетДисплейСБольшейЧастьюВыделенияНаСтыке() async throws {
    try skipIfRunningInCI("Требуется оконный сервер")
    let screens = NSScreen.screens
    try XCTSkipUnless(screens.count >= 2, "Требуется пара дисплеев")
    let first = screens[0].frame
    let expected = screens[1]
    let second = expected.frame
    let sharedX = (max(first.minX, second.minX) + min(first.maxX, second.maxX)) / 2
    let sharedY = (max(first.minY, second.minY) + min(first.maxY, second.maxY)) / 2
    let candidates = [
      CGRect(x: sharedX - 40, y: second.minY - 20, width: 80, height: 100),
      CGRect(x: sharedX - 40, y: second.maxY - 80, width: 80, height: 100),
      CGRect(x: second.minX - 20, y: sharedY - 40, width: 100, height: 80),
      CGRect(x: second.maxX - 80, y: sharedY - 40, width: 100, height: 80),
    ]
    guard let crossing = candidates.first(where: { rect in
      let firstOverlap = first.intersection(rect)
      let secondOverlap = second.intersection(rect)
      return !firstOverlap.isEmpty && !secondOverlap.isEmpty
        && secondOverlap.width * secondOverlap.height > firstOverlap.width * firstOverlap.height
    }) else { throw XCTSkip("Дисплеи не дают подходящего стыка") }
    let previous = UserDefaults.standard.object(forKey: PreferencesKeys.screenshotLastAreaRect)
    let model = ScreenCaptureViewModel()
    let controller = OwnShotAllInOneController.shared
    let theme = ThemeManager.shared
    let previousAppearance = theme.preferredAppearance
    defer {
      controller.dismiss()
      theme.preferredAppearance = previousAppearance
      UserDefaults.standard.set(previous, forKey: PreferencesKeys.screenshotLastAreaRect)
    }
    let starting = CGRect(x: second.midX - 90, y: second.midY - 55, width: 180, height: 110)
    controller.present(viewModel: model, on: expected, selection: starting)
    let toolbar = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "OwnShotAllInOne" })
    let overlay = try XCTUnwrap(NSApp.windows.compactMap { $0 as? RecordingRegionOverlayWindow }
      .first { $0.isVisible && $0.identifier?.rawValue == "OwnShotAllInOneOverlay" })

    controller.overlay(overlay, didReselectWithRect: crossing)

    XCTAssertEqual(controller.rect, crossing)
    let dictionary = UserDefaults.standard.dictionary(forKey: PreferencesKeys.screenshotLastAreaRect)
    let stored = try XCTUnwrap(ScreenshotLastAreaStore.decode(dictionary))
    XCTAssertEqual(stored.screenID, ScreenUtility.displayID(of: expected))
    XCTAssertEqual(toolbar.frame.origin, OwnShotCaptureGeometry.toolbarOrigin(
      for: crossing, panelSize: toolbar.frame.size, visibleFrame: expected.visibleFrame
    ))

    controller.expandToScreen()

    XCTAssertEqual(controller.rect, expected.frame)
    XCTAssertTrue(toolbar.isVisible)
    XCTAssertFalse(model.isCapturing)
    XCTAssertNil(model.lastCaptureResult)
    XCTAssertEqual(toolbar.frame.origin, OwnShotCaptureGeometry.toolbarOrigin(
      for: expected.frame, panelSize: toolbar.frame.size, visibleFrame: expected.visibleFrame
    ))
    let content = try XCTUnwrap(toolbar.contentView)
    for appearance in [AppearanceMode.light, .dark] {
      theme.preferredAppearance = appearance
      try await Task.sleep(for: .milliseconds(150))
      content.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "all-in-one-display-crossing-\(appearance.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testURLЗахватаОбластиОткрываетВыделениеПриСтороннемПути() throws {
    try skipIfRunningInCI("Требуется окно выделения")
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShot URL Fixture \(UUID()).png")
    defer {
      AreaSelectionController.shared.cancelSelection()
      for case let window as AnnotateWindow in NSApp.windows where window.interactionState?.sourceURL == file {
        window.close()
      }
      CaptureHistoryStore.shared.removeByFilePath(file.path)
      try? FileManager.default.removeItem(at: file)
      defaults.set(previous, forKey: PreferencesKeys.urlSchemeEnabled)
    }
    let source = try XCTUnwrap(TestImageFactory.solidColor(width: 14, height: 9))
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
    try png.write(to: file)
    let model = ScreenCaptureViewModel()
    model.hasPermission = true
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: model)
    var components = URLComponents()
    components.scheme = "ownshot"
    components.host = "capture-area"
    components.queryItems = [URLQueryItem(name: "action", value: "copy"),
      URLQueryItem(name: "filepath", value: file.path)]

    handler.handle(try XCTUnwrap(components.url))

    XCTAssertTrue(AreaSelectionController.shared.isPresenting)
    XCTAssertFalse(NSApp.windows.compactMap { $0 as? AnnotateWindow }
      .contains { $0.isVisible && $0.interactionState?.sourceURL == file })
    XCTAssertNil(model.lastCaptureResult)
  }

  func testURLИГорячаяКлавишаКопированияУчитываютЗаморозкуЭкрана() async throws {
    try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Требуется разрешение Screen Recording для Test Host")
    try skipIfRunningInCI("Требуется окно выделения")
    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.urlSchemeEnabled, PreferencesKeys.screenshotFreezeArea]
    let values = keys.map { defaults.object(forKey: $0) }
    let selector = AreaSelectionController.shared
    defer {
      selector.cancelSelection()
      for (key, value) in zip(keys, values) { defaults.set(value, forKey: key) }
    }
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.screenshotFreezeArea)

    for useShortcut in [false, true] {
      let model = ScreenCaptureViewModel()
      model.hasPermission = true
      let route = useShortcut ? "Capture Area & Copy" : "URL Capture Area"
      if useShortcut {
        model.shortcutTriggered(.captureAreaCopy)
      } else {
        let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: model)
        handler.handle(try XCTUnwrap(URL(string: "ownshot://capture-area?action=copy")))
      }
      let deadline = ContinuousClock.now + .seconds(5)
      while !selector.isPresenting, model.lastCaptureResult == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }

      XCTAssertTrue(selector.isPresenting, route)
      let backdrops = try XCTUnwrap(Mirror(reflecting: selector).children
        .first { $0.label == "selectionBackdrops" }?.value as? [CGDirectDisplayID: AreaSelectionBackdrop])
      XCTAssertFalse(backdrops.isEmpty, route)
      XCTAssertNil(model.lastCaptureResult, route)
      selector.cancelSelection()
      guard case .failure(.cancelled)? = model.lastCaptureResult else {
        return XCTFail("\(route): отмена должна завершить сеанс без снимка")
      }
    }
  }

  func testНеудачныйSaveПослеВыделенияПоказываетСообщение() async throws {
    try skipIfRunningInCI("Требуется окно уведомления")
    let manager = AppToastManager.shared
    let initial = Mirror(reflecting: manager).children.first { $0.label == "activePresentationID" }?.value as? UUID
    let model = ScreenCaptureViewModel()
    let failure = CaptureError.saveFailed("OwnShot Save fixture")

    model.completeAreaCapture(.failure(failure), action: "save")

    let fields = Mirror(reflecting: manager).children
    let presentation = try XCTUnwrap(fields.first { $0.label == "activePresentationID" }?.value as? UUID)
    XCTAssertNotEqual(presentation, initial)
    let panel = fields.first { $0.label == "panel" }?.value as? NSPanel
    XCTAssertTrue(panel?.isVisible == true)
    defer { panel?.orderOut(nil) }
    guard case .failure(let error)? = model.lastCaptureResult else { return XCTFail("Ожидалась ошибка сохранения") }
    XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
  }

  func testURLЗахватаОкнаСДействиемУчитываетНастройкиВыделения() async throws {
    try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Требуется разрешение Screen Recording для Test Host")
    try skipIfRunningInCI("Требуется окно выделения")
    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.urlSchemeEnabled, PreferencesKeys.screenshotFreezeArea,
      PreferencesKeys.screenshotIncludeOwnApp]
    let values = keys.map { defaults.object(forKey: $0) }
    let selector = AreaSelectionController.shared
    defer {
      selector.cancelSelection()
      for (key, value) in zip(keys, values) { defaults.set(value, forKey: key) }
    }
    keys.forEach { defaults.set(true, forKey: $0) }
    let model = ScreenCaptureViewModel()
    model.hasPermission = true
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: model)
    handler.handle(try XCTUnwrap(URL(string: "ownshot://capture-window?action=save")))
    let deadline = ContinuousClock.now + .seconds(5)
    while !selector.isPresenting, model.lastCaptureResult == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(selector.isPresenting)
    let fields = Mirror(reflecting: selector).children
    XCTAssertEqual(fields.first { $0.label == "interactionMode" }?.value as? AreaSelectionInteractionMode,
      .applicationWindow)
    let backdrops = try XCTUnwrap(fields.first { $0.label == "selectionBackdrops" }?.value
      as? [CGDirectDisplayID: AreaSelectionBackdrop])
    XCTAssertFalse(backdrops.isEmpty)
    let configuration = try XCTUnwrap(fields.first { $0.label == "applicationConfiguration" }?.value
      as? AreaSelectionApplicationConfiguration)
    XCTAssertFalse(configuration.excludeOwnApplication)
    XCTAssertNil(model.lastCaptureResult)
    selector.cancelSelection()
    guard case .failure(.cancelled)? = model.lastCaptureResult else {
      return XCTFail("Отмена должна завершить штатный сеанс без снимка")
    }
  }

  func testURLAllInOneОткрываетРамкуСПереданнымиКоординатами() throws {
    try skipIfRunningInCI("Требуется окно All-in-One")
    let screen = try XCTUnwrap(NSScreen.screens.last)
    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.urlSchemeEnabled, PreferencesKeys.screenshotLastAreaRect]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
    }
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.removeObject(forKey: PreferencesKeys.screenshotLastAreaRect)
    let model = ScreenCaptureViewModel()
    model.hasPermission = true
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: model)
    let controller = OwnShotAllInOneController.shared
    defer { controller.dismiss() }
    let target = try XCTUnwrap(URL(string:
      "ownshot://all-in-one?x=105&y=77&width=280&height=180&display=\(NSScreen.screens.count)"))

    handler.handle(target)

    XCTAssertTrue(NSApp.windows.contains { $0.identifier?.rawValue == "OwnShotAllInOne" && $0.isVisible })
    XCTAssertEqual(controller.rect, CGRect(x: screen.frame.minX + 105, y: screen.frame.minY + 77,
      width: 280, height: 180))
  }

  func testURLRecordScreenГотовитЗаписьНаПереданнойОбласти() async throws {
    try skipIfRunningInCI("Требуется окно подготовки записи")
    let screen = try XCTUnwrap(NSScreen.screens.last)
    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.urlSchemeEnabled, PreferencesKeys.recordingRememberLastArea,
      PreferencesKeys.recordingLastAreaRect, PreferencesKeys.recordingCaptureCamera,
      PreferencesKeys.recordingCaptureMicrophone, PreferencesKeys.recordingCaptureAudio]
    let saved = keys.map { defaults.object(forKey: $0) }
    let coordinator = RecordingCoordinator.shared
    defer {
      AreaSelectionController.shared.cancelSelection()
      if coordinator.isActive { coordinator.cancel() }
      for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
    }
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(false, forKey: PreferencesKeys.recordingRememberLastArea)
    defaults.set(false, forKey: PreferencesKeys.recordingCaptureCamera)
    defaults.set(false, forKey: PreferencesKeys.recordingCaptureMicrophone)
    defaults.set(false, forKey: PreferencesKeys.recordingCaptureAudio)
    let model = ScreenCaptureViewModel()
    model.hasPermission = true
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: model)
    let originalWindowIDs = Set(NSApp.windows.map(\.windowNumber))
    let target = try XCTUnwrap(URL(string:
      "ownshot://record-screen?x=110&y=90&width=320&height=180&display=\(NSScreen.screens.count)"))

    handler.handle(target)
    try await Task.sleep(for: .milliseconds(400))

    let toolbar = NSApp.windows.compactMap { $0 as? RecordingToolbarWindow }
      .first { $0.isVisible && !originalWindowIDs.contains($0.windowNumber) }
    XCTAssertEqual(toolbar?.state.selectionRect, CGRect(x: screen.frame.minX + 110, y: screen.frame.minY + 90,
      width: 320, height: 180))
    XCTAssertFalse(AreaSelectionController.shared.isPresenting)
    XCTAssertNil(model.lastCaptureResult)
    XCTAssertEqual(ScreenRecordingManager.shared.state, .idle)
    if let cleanup = coordinator.cancel() { await cleanup.value }
  }

  func testURLИзБуфераНеДобавляетКарточкуУдалённойЗаписи() async throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    let defaults = UserDefaults.standard
    let previousURL = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    let manager = QuickAccessManager.shared
    let previousEnabled = manager.isEnabled
    manager.isEnabled = true
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Missing Clip \(UUID()).mp4")
    let pasteboard = ClipboardHelper.pasteboard
    defer {
      for item in manager.items where item.url == url { manager.removeItem(id: item.id) }
      manager.isEnabled = previousEnabled
      pasteboard.clearContents()
      defaults.set(previousURL, forKey: PreferencesKeys.urlSchemeEnabled)
      try? FileManager.default.removeItem(at: url)
    }
    try Data([0]).write(to: url)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
    try FileManager.default.removeItem(at: url)
    let model = ScreenCaptureViewModel()
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: model)

    handler.handle(try XCTUnwrap(URL(string: "ownshot://open-from-clipboard")))

    let deadline = ContinuousClock.now + .seconds(1)
    while !manager.items.contains(where: { $0.url == url }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(manager.items.contains { $0.url == url })
  }

  func testURLИзБуфераНеДобавляетПовреждённуюЗапись() async throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    let defaults = UserDefaults.standard
    let previousURL = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    let manager = QuickAccessManager.shared
    let previousEnabled = manager.isEnabled
    manager.isEnabled = true
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("Corrupted Clip \(UUID()).mp4")
    let control = directory.appendingPathComponent("Readable Clip \(UUID()).mp4")
    let pasteboard = ClipboardHelper.pasteboard
    defer {
      for item in manager.items where item.url == url || item.url == control { manager.removeItem(id: item.id) }
      manager.isEnabled = previousEnabled
      pasteboard.clearContents()
      defaults.set(previousURL, forKey: PreferencesKeys.urlSchemeEnabled)
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: control)
    }
    let contents = Data("OwnShot unreadable movie fixture".utf8)
    try contents.write(to: url)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())

    handler.handle(try XCTUnwrap(URL(string: "ownshot://open-from-clipboard")))

    let deadline = ContinuousClock.now + .seconds(1)
    while !manager.items.contains(where: { $0.url == url }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(manager.items.contains { $0.url == url })
    XCTAssertEqual(try Data(contentsOf: url), contents)

    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Recording/quick-access-url.mp4")
    let video = try Data(contentsOf: fixture)
    try video.write(to: control)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([control as NSURL]))
    handler.handle(try XCTUnwrap(URL(string: "ownshot://open-from-clipboard")))

    let controlDeadline = ContinuousClock.now + .seconds(3)
    while !manager.items.contains(where: { $0.url == control }), ContinuousClock.now < controlDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let card = try XCTUnwrap(manager.items.first { $0.url == control })
    XCTAssertTrue(card.isVideo)
    XCTAssertEqual(card.duration ?? 0, 2, accuracy: 0.001)
    XCTAssertEqual(try Data(contentsOf: control), video)
  }

  func testURLИзБуфераОткрываетПикселиПослеУдаленияФайла() throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    try skipIfRunningInCI("Требуется окно редактора")
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard Fixture \(UUID()).png")
    defer {
      defaults.set(previous, forKey: PreferencesKeys.urlSchemeEnabled)
      ClipboardHelper.pasteboard.clearContents()
      try? FileManager.default.removeItem(at: file)
    }
    let original = try XCTUnwrap(TestImageFactory.solidColor(width: 28, height: 19, red: 24, green: 171, blue: 39))
    let image = NSBitmapImageRep(cgImage: original)
    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    try png.write(to: file)
    XCTAssertTrue(ClipboardHelper.copyImage(from: file, content: .imageAndFile))
    try FileManager.default.removeItem(at: file)
    let oldWindows = Set(NSApp.windows.map(\.windowNumber))
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())

    handler.handle(try XCTUnwrap(URL(string: "ownshot://open-from-clipboard")))

    let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? AnnotateWindow }
      .first { $0.isVisible && !oldWindows.contains($0.windowNumber) })
    let state = try XCTUnwrap(window.interactionState)
    let snapshot = try XCTUnwrap(state.sourceURL)
    defer {
      window.close()
      try? FileManager.default.removeItem(at: snapshot)
    }
    XCTAssertTrue(snapshot.lastPathComponent.hasPrefix("OwnShot-Clipboard-"))
    XCTAssertNotEqual(snapshot, file)
    XCTAssertEqual(try Data(contentsOf: snapshot), png)
    let source = try XCTUnwrap(state.sourceImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(source.width, original.width)
    XCTAssertEqual(source.height, original.height)
    let expected = try XCTUnwrap(NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let expectedPixel = try XCTUnwrap(
      NSBitmapImageRep(cgImage: expected).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
    let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: source).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(pixel.redComponent, expectedPixel.redComponent, accuracy: 0.01)
    XCTAssertEqual(pixel.greenComponent, expectedPixel.greenComponent, accuracy: 0.01)
    XCTAssertEqual(pixel.blueComponent, expectedPixel.blueComponent, accuracy: 0.01)
  }

  func testURLИзБуфераСохраняетPNGССобственнымиМетаданными() throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    try skipIfRunningInCI("Требуется окно редактора")
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    let pasteboard = ClipboardHelper.pasteboard
    pasteboard.clearContents()
    defer {
      defaults.set(previous, forKey: PreferencesKeys.urlSchemeEnabled)
      pasteboard.clearContents()
    }
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 19, height: 12, red: 137, green: 29, blue: 80))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    let description = "OwnShot PNG metadata fixture"
    let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let encoded = data as Data
    let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
    let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let pngMetadata = metadata?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
    XCTAssertEqual(pngMetadata?[kCGImagePropertyPNGDescription] as? String, description)
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())
    for withPrecedingText in [false, true] {
      let item = NSPasteboardItem()
      XCTAssertTrue(item.setData(encoded, forType: .png))
      let text = NSPasteboardItem()
      XCTAssertTrue(text.setString("Clipboard text fixture", forType: .string))
      pasteboard.clearContents()
      XCTAssertTrue(pasteboard.writeObjects(withPrecedingText ? [text, item] : [item]))
      let oldWindows = Set(NSApp.windows.map(\.windowNumber))

      handler.handle(try XCTUnwrap(URL(string: "ownshot://open-from-clipboard")))

      let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? AnnotateWindow }
        .first { $0.isVisible && !oldWindows.contains($0.windowNumber) })
      let state = try XCTUnwrap(window.interactionState)
      let url = try XCTUnwrap(state.sourceURL)
      defer {
        window.close()
        try? FileManager.default.removeItem(at: url)
      }
      XCTAssertEqual(state.sourceImage?.size, CGSize(width: 19, height: 12))
      XCTAssertEqual(try Data(contentsOf: url), encoded, "withPrecedingText=\(withPrecedingText)")
    }
  }

  func testURLOCRИзФайлаСохраняетНастройкуПереносовБезЯвногоПараметра() async throws {
    try XCTSkipUnless(ClipboardHelper.pasteboardName != .general, "Требуется буфер OwnShot Test Host")
    let defaults = UserDefaults.standard
    let keys = [
      PreferencesKeys.urlSchemeEnabled, PreferencesKeys.ocrSelectedModel,
      PreferencesKeys.ocrSuccessNotificationEnabled, OwnShotAdvancedPreferenceKeys.keepLineBreaks,
    ]
    let previous = keys.map { defaults.object(forKey: $0) }
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(OCRModelSelection.builtIn.persistedValue, forKey: PreferencesKeys.ocrSelectedModel)
    defaults.set(false, forKey: PreferencesKeys.ocrSuccessNotificationEnabled)
    defaults.set(false, forKey: OwnShotAdvancedPreferenceKeys.keepLineBreaks)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShot OCR Lines \(UUID()).png")
    let pasteboard = ClipboardHelper.pasteboard
    defer {
      for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
      pasteboard.clearContents()
      try? FileManager.default.removeItem(at: file)
    }
    let image = NSImage(size: NSSize(width: 500, height: 190))
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black,
    ]
    ("First line" as NSString).draw(at: NSPoint(x: 40, y: 88), withAttributes: attributes)
    ("Second line" as NSString).draw(at: NSPoint(x: 40, y: 34), withAttributes: attributes)
    image.unlockFocus()
    let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
    try png.write(to: file)
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())
    let cases: [(keep: Bool, parameter: String?, expected: String)] = [
      (false, "true", "First line\nSecond line"),
      (false, "false", "First line Second line"),
      (false, nil, "First line Second line"),
      (true, nil, "First line\nSecond line"),
    ]

    for entry in cases {
      defaults.set(entry.keep, forKey: OwnShotAdvancedPreferenceKeys.keepLineBreaks)
      pasteboard.clearContents()
      var components = URLComponents()
      components.scheme = "ownshot"
      components.host = "capture-text"
      var items = [URLQueryItem(name: "filepath", value: file.path), URLQueryItem(name: "language", value: "en")]
      if let parameter = entry.parameter { items.append(URLQueryItem(name: "linebreaks", value: parameter)) }
      components.queryItems = items

      handler.handle(try XCTUnwrap(components.url))

      let deadline = ContinuousClock.now + .seconds(3)
      while pasteboard.string(forType: .string) == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(pasteboard.string(forType: .string), entry.expected,
        "keep=\(entry.keep) linebreaks=\(entry.parameter ?? "по умолчанию")")
    }
  }

  func testПереходКЗаписиПересчитываетПозициюПоРазмеруКомпактнойПлашки() throws {
    try skipIfRunningInCI("Требуется окно панели записи")
    let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
    for y in [screen.minY + 20, screen.minY + 300] {
      let rect = CGRect(x: screen.midX - 200, y: y, width: 400, height: 300)
      let window = RecordingToolbarWindow(anchorRect: rect)
      defer { window.close() }
      window.state.outputMode = .gif
      window.showRecordingStatusBar(recorder: .shared)
      let expected = RecordingToolbarPlacement.frameOrigin(toolbarSize: window.frame.size,
        anchorRect: rect, screenFrame: screen)
      XCTAssertEqual(window.frame.origin.x, expected.x, accuracy: 1)
      XCTAssertEqual(window.frame.origin.y, expected.y, accuracy: 1)
    }
  }

  func testПовторныйПоказВСеансеСохраняетРучноеПоложениеВместоСтарогоГлобального() throws {
    try skipIfRunningInCI("Требуется окно панели записи")
    let key = PreferencesKeys.recordingHoverBarFrameOrigin
    let old = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(old, forKey: key) }
    UserDefaults.standard.set(NSStringFromPoint(CGPoint(x: 20, y: 30)), forKey: key)
    let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
    let window = RecordingToolbarWindow(anchorRect: screen.insetBy(dx: 100, dy: 100))
    defer { window.close() }
    window.showRecordingStatusBar(recorder: .shared)
    let moved = CGPoint(x: screen.midX - 100, y: screen.midY)
    window.setFrameOrigin(moved)
    window.showRecordingStatusBar(recorder: .shared, visible: false)
    window.showRecordingStatusBar(recorder: .shared, visible: true)
    XCTAssertEqual(window.frame.origin.x, moved.x, accuracy: 1)
    XCTAssertEqual(window.frame.origin.y, moved.y, accuracy: 1)
  }

  func testCapturePreviousAreaБезИсторииОткрываетВыборИПоддерживаетОтмену() throws {
    try skipIfRunningInCI("Требуется окно выделения области")
    let defaults = UserDefaults.standard
    let areaKey = PreferencesKeys.screenshotLastAreaRect
    let freezeKey = PreferencesKeys.screenshotFreezeArea
    let savedArea = defaults.object(forKey: areaKey)
    let savedFreeze = defaults.object(forKey: freezeKey)
    defer {
      defaults.set(savedArea, forKey: areaKey)
      defaults.set(savedFreeze, forKey: freezeKey)
    }
    defaults.removeObject(forKey: areaKey)
    defaults.set(false, forKey: freezeKey)

    let model = ScreenCaptureViewModel()
    let selector = AreaSelectionController.shared
    model.isCapturing = true
    model.shortcutTriggered(.captureRepeatArea)
    XCTAssertFalse(selector.isPresenting)
    model.isCapturing = false

    model.shortcutTriggered(.captureRepeatArea)
    XCTAssertTrue(selector.isPresenting)
    XCTAssertTrue(NSApp.windows.contains { $0 is AreaSelectionWindow && $0.isVisible })
    XCTAssertFalse(model.isCapturing)
    XCTAssertNil(ScreenshotLastAreaStore.load())

    selector.cancelSelection()
    XCTAssertFalse(selector.isPresenting)
    guard case .failure(.cancelled)? = model.lastCaptureResult else {
      return XCTFail("Отмена выбора должна завершать штатный сценарий захвата")
    }
    XCTAssertNil(ScreenshotLastAreaStore.load())
  }

  func testCapturePreviousAreaСПовреждённойОбластьюОткрываетОбычноеВыделение() throws {
    try skipIfRunningInCI("Требуется окно выделения области")
    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.screenshotLastAreaRect, PreferencesKeys.screenshotFreezeArea]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
    }
    let fields: [String: CGFloat] = ["x": 120, "y": 120, "width": 0, "height": 160]
    defaults.set(fields, forKey: PreferencesKeys.screenshotLastAreaRect)
    defaults.set(false, forKey: PreferencesKeys.screenshotFreezeArea)
    let model = ScreenCaptureViewModel()

    model.shortcutTriggered(.captureRepeatArea)

    let selector = AreaSelectionController.shared
    XCTAssertTrue(selector.isPresenting)
    XCTAssertFalse(model.isCapturing)
    selector.cancelSelection()
    guard case .failure(.cancelled)? = model.lastCaptureResult else {
      return XCTFail("Отмена должна завершать обычное выделение")
    }
    XCTAssertEqual(ScreenshotLastAreaStore.lookup(), .missing)
  }

  func testСначалаВыделениеОбластиПотомТаймерБезПреждевременногоЗахвата() throws {
    try skipIfRunningInCI("Требуется окно выделения области")
    for explicitAction in [false, true] {
      CaptureDelayCountdownController.shared.cancel()
      let model = ScreenCaptureViewModel()
      if explicitAction { model.captureDelayedArea(action: "copy") }
      else { model.captureDelayed() }
      XCTAssertTrue(AreaSelectionController.shared.isPresenting)
      XCTAssertFalse(CaptureDelayCountdownController.shared.isActive)
      let window = try XCTUnwrap(NSApp.windows.first { $0 is AreaSelectionWindow && $0.isVisible } as? AreaSelectionWindow)
      let rect = CGRect(x: window.frame.minX + 100, y: window.frame.minY + 100, width: 320, height: 180)
      AreaSelectionController.shared.completeSelection(rect: rect, from: window)
      XCTAssertFalse(AreaSelectionController.shared.isPresenting)
      XCTAssertTrue(CaptureDelayCountdownController.shared.isActive)
      XCTAssertFalse(model.isCapturing)
      XCTAssertNil(model.lastCaptureResult)
      CaptureDelayCountdownController.shared.cancel()
    }
  }

  func testОтменаВыделенияНеЗапускаетТаймер() {
    let model = ScreenCaptureViewModel()
    model.captureDelayed()
    AreaSelectionController.shared.cancelSelection()
    XCTAssertFalse(CaptureDelayCountdownController.shared.isActive)
    XCTAssertFalse(model.isCapturing)
    XCTAssertNil(model.lastCaptureResult)
  }

  func testСтандартныйЖестУбираетПревьюВДвиженииПальцевККраюЭкрана() {
    for reset in [false, true] {
      let suite = "ownshot-swipe-default-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = QuickAccessTrackpadSwipeModeStore(defaults: defaults)
      if reset {
        store.setMode(.inverted)
        store.resetToDefault()
      }
      // Правая карточка: пальцы вправо. Левая: пальцы влево.
      let cases: [(edge: CGFloat, naturalScroll: Bool, outward: CGFloat)] = [
        (1, true, 1.2), (1, false, -1.2),
        (-1, true, -1.2), (-1, false, 1.2)
      ]
      for sample in cases {
        var actions: [QuickAccessSwipeDirection] = []
        let view = QuickAccessDragMonitorView(
          fileURL: URL(fileURLWithPath: "/tmp/ownshot-swipe-fixture.png"),
          thumbnail: NSImage(size: CGSize(width: 210, height: 150)), dismissDirection: sample.edge,
          dragDropEnabled: true, twoFingerSwipeToDismissEnabled: true, swipeMode: store.mode,
          swipeSensitivity: 1, onDragStarted: {}, onDragEnded: { _ in },
          onSwipeChanged: { _ in }, onSwipeEnded: { _, _ in })
        view.frame = CGRect(x: 0, y: 0, width: 210, height: 150)
        view.onTrackpadSwipe = { actions.append($0) }
        view.handleScrollWheel(SwipeEvent(delta: -sample.outward, phase: .began, inverted: sample.naturalScroll))
        XCTAssertTrue(actions.isEmpty, "Движение пальцев к центру сохраняет превью")
        view.handleScrollWheel(SwipeEvent(delta: 0, phase: .ended, inverted: sample.naturalScroll))
        actions.removeAll()
        view.handleScrollWheel(SwipeEvent(delta: sample.outward, phase: .began, inverted: sample.naturalScroll))
        XCTAssertEqual(actions, [sample.edge > 0 ? .right : .left], "Движение пальцев к краю убирает превью")
      }
    }
  }

  func testСвайпКарточкиЗапускаетУходТолькоККраюПриОбеихНастройкахПрокрутки() {
    for direction: CGFloat in [1, -1] {
      for inverted in [false, true] {
        for mode in QuickAccessTrackpadSwipeMode.allCases {
          var offsets: [CGFloat] = []
          var endings: [CGFloat] = []
          var actions: [QuickAccessSwipeDirection] = []
          let view = QuickAccessDragMonitorView(fileURL: URL(fileURLWithPath: "/tmp/ownshot-swipe-fixture.png"),
            thumbnail: NSImage(size: CGSize(width: 210, height: 150)), dismissDirection: direction,
            dragDropEnabled: true, twoFingerSwipeToDismissEnabled: true, swipeMode: mode,
            swipeSensitivity: 1, onDragStarted: {}, onDragEnded: { _ in },
            onSwipeChanged: { offsets.append($0) }, onSwipeEnded: { translation, _ in endings.append(translation) })
          view.onTrackpadSwipe = { actions.append($0) }
          view.frame = CGRect(x: 0, y: 0, width: 210, height: 150)
          let delta = direction * (inverted ? 1 : -1) * (mode == .natural ? 1 : -1)
          view.handleScrollWheel(SwipeEvent(delta: -delta, phase: .began, inverted: inverted))
          view.handleScrollWheel(SwipeEvent(delta: 0, phase: .ended, inverted: inverted))
          XCTAssertTrue(actions.isEmpty, "Жест к центру не закрывает карточку")
          view.handleScrollWheel(SwipeEvent(delta: delta, phase: .began, inverted: inverted))
          XCTAssertEqual(actions, [direction > 0 ? .right : .left], "Уход начинается до отпускания")
          view.handleScrollWheel(SwipeEvent(delta: delta, phase: .changed, inverted: inverted))
          view.handleScrollWheel(SwipeEvent(delta: 0, phase: .ended, inverted: inverted))
          XCTAssertEqual(actions.count, 1)
          XCTAssertTrue(offsets.isEmpty, "Карточка не следует за пальцем")
          XCTAssertTrue(endings.isEmpty, "Порог мышиного перетаскивания не управляет жестом трекпада")
        }
      }
    }
  }

}

private final class SwipeEvent: NSEvent {
  let delta: CGFloat
  let eventPhase: NSEvent.Phase
  let inverted: Bool
  init(delta: CGFloat, phase: NSEvent.Phase, inverted: Bool = false) {
    self.delta = delta; eventPhase = phase; self.inverted = inverted; super.init()
  }
  required init?(coder: NSCoder) { fatalError() }
  override var type: NSEvent.EventType { .scrollWheel }
  override var deltaX: CGFloat { delta }
  override var scrollingDeltaX: CGFloat { delta * 10 }
  override var isDirectionInvertedFromDevice: Bool { inverted }
  override var scrollingDeltaY: CGFloat { 0 }
  override var hasPreciseScrollingDeltas: Bool { true }
  override var phase: NSEvent.Phase { eventPhase }
  override var momentumPhase: NSEvent.Phase { [] }
  override var modifierFlags: NSEvent.ModifierFlags { [] }
  override var locationInWindow: NSPoint { NSPoint(x: 50, y: 50) }
  override var timestamp: TimeInterval { eventPhase == .ended ? 2 : 1 }
}
