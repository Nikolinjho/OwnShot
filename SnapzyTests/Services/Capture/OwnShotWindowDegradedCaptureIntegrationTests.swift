import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import XCTest
@testable import Snapzy

/// Запускается отдельно: использует настоящий WindowServer и разрешение тестового host.
@MainActor
final class OwnShotWindowDegradedCaptureIntegrationTests: XCTestCase {
  private enum FixtureError: Error {
    case screenCapturePermissionMissing
    case shiftPressed
    case prefetchedContentUnavailable
    case captureFailed(String)
  }

  private let preferenceKeys = [
    OwnShotScreenshotPreferenceKeys.windowBackground,
    OwnShotScreenshotPreferenceKeys.windowPadding,
    PreferencesKeys.captureIncludeWindowShadow,
    "ownshot.capture.wallpaper.mode",
    "ownshot.capture.wallpaper.colorRGB",
    "ownshot.capture.export.convertToSRGB",
    "ownshot.capture.export.scaleRetinaTo1x",
    "ownshot.capture.export.addPixelBorder",
  ]

  func testЖивоеОкноСохраняетAlphaПриОтказеПредзагрузкиSCK() async throws {
    let screen = try requireLiveCapture()
    let preferences = configurePreferences(background: .transparent)
    defer { restorePreferences(preferences) }
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let window = makeWindow(on: screen, transparentEdges: true)
    defer { window.close() }
    await settleWindowServer()
    let target = try makeTarget(window: window, screen: screen)

    // Отказывает существующая предзагрузка. Следующий изолированный CG-захват настоящий.
    let prefetch = ShareableContentPrefetchTask { throw FixtureError.prefetchedContentUnavailable }
    let resolvedWindow = await WindowSelectionQueryService.resolveWindow(
      windowID: target.windowID, prefetchedContentTask: prefetch
    )
    XCTAssertNil(resolvedWindow)
    let result = await ScreenCaptureManager.shared.captureWindow(
      target: target, saveDirectory: directory, fileName: "isolated-alpha", format: .png,
      prefetchedContentTask: prefetch, context: .empty.withoutNamePrompt(), invocation: .interactive
    )
    let image = try loadSuccessfulImage(result)
    let scale = screen.backingScaleFactor
    XCTAssertEqual(image.width, Int((window.frame.width + 40) * scale))
    XCTAssertEqual(image.height, Int((window.frame.height + 40) * scale))
    XCTAssertEqual(try pixel(image, x: 0, y: 0)[3], 0)
    // Проверяем alpha внутри исходных границ окна, а не только добавленный отступ.
    XCTAssertEqual(try pixel(image, x: Int(24 * scale), y: Int(24 * scale))[3], 0)
    assertRed(try pixel(image, x: image.width / 2, y: image.height / 2))
  }

  func testЗакрытоеОкноВозвращаетОшибкуБезФайлаВПрозрачномРежиме() async throws {
    let screen = try requireLiveCapture()
    let preferences = configurePreferences(background: .transparent)
    defer { restorePreferences(preferences) }
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = try await makeDestroyedWindowTarget(on: screen)
    try await assertWindowIsUnavailable(target)

    let result = await ScreenCaptureManager.shared.captureWindow(
      target: target, saveDirectory: directory, fileName: "closed-transparent", format: .png,
      context: .empty.withoutNamePrompt(), invocation: .interactive
    )
    guard case .failure(.captureFailed(let message)) = result else {
      return XCTFail("Недоступное прозрачное окно должно завершаться явной ошибкой захвата")
    }
    XCTAssertTrue(message.contains("transparent background"), message)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  func testЗакрытоеОкноИспользуетСнимокОбластиСОбоямиИОтступом() async throws {
    let screen = try requireLiveCapture()
    let preferences = configurePreferences(background: .wallpaper)
    defer { restorePreferences(preferences) }
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // После закрытия цели в её области остаётся принадлежащее тесту красное окно.
    let backdrop = makeWindow(on: screen)
    defer { backdrop.close() }
    let target = try await makeDestroyedWindowTarget(on: screen)
    try await assertWindowIsUnavailable(target)

    let result = await ScreenCaptureManager.shared.captureWindow(
      target: target, saveDirectory: directory, fileName: "closed-wallpaper", format: .png,
      context: .empty.withoutNamePrompt(), invocation: .interactive
    )
    let image = try loadSuccessfulImage(result)
    let scale = screen.backingScaleFactor
    XCTAssertEqual(image.width, Int((target.frame.width + 40) * scale))
    XCTAssertEqual(image.height, Int((target.frame.height + 40) * scale))
    let corner = try pixel(image, x: 0, y: 0)
    XCTAssertLessThan(corner[0], 10)
    XCTAssertLessThan(corner[1], 10)
    XCTAssertGreaterThan(corner[2], 245)
    XCTAssertEqual(corner[3], 255)
    assertRed(try pixel(image, x: image.width / 2, y: image.height / 2))
    // За границей отступа должны начинаться видимые пиксели области.
    assertRed(try pixel(image, x: Int(24 * scale), y: image.height / 2))
  }

  private func requireLiveCapture() throws -> NSScreen {
    guard ProcessInfo.processInfo.environment["OWN_SHOT_LIVE_CAPTURE_TESTS"] == "1" else {
      throw XCTSkip("Настоящий захват включается через OWN_SHOT_LIVE_CAPTURE_TESTS=1")
    }
    guard CGPreflightScreenCaptureAccess() else {
      XCTFail("У явно запрошенного live-прогона нет Screen Recording. Разрешение не запрашивается.")
      throw FixtureError.screenCapturePermissionMissing
    }
    guard !NSEvent.modifierFlags.contains(.shift) else {
      XCTFail("Перед live-прогоном нужно отпустить Shift: он меняет фон интерактивного захвата")
      throw FixtureError.shiftPressed
    }
    return try XCTUnwrap(NSScreen.main)
  }

  private func configurePreferences(background: OwnShotWindowScreenshotBackground) -> [String: Any] {
    let defaults = UserDefaults.standard
    let domain = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier!) ?? [:]
    let snapshot = domain.filter { preferenceKeys.contains($0.key) }
    defaults.set(background.rawValue, forKey: OwnShotScreenshotPreferenceKeys.windowBackground)
    defaults.set(20.0, forKey: OwnShotScreenshotPreferenceKeys.windowPadding)
    defaults.set(false, forKey: PreferencesKeys.captureIncludeWindowShadow)
    defaults.set("color", forKey: "ownshot.capture.wallpaper.mode")
    defaults.set([0.0, 0.0, 1.0], forKey: "ownshot.capture.wallpaper.colorRGB")
    for key in preferenceKeys.filter({ $0.hasPrefix("ownshot.capture.export.") }) {
      defaults.set(false, forKey: key)
    }
    return snapshot
  }

  private func restorePreferences(_ snapshot: [String: Any]) {
    for key in preferenceKeys {
      if let value = snapshot[key] { UserDefaults.standard.set(value, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeWindow(on screen: NSScreen, transparentEdges: Bool = false) -> NSWindow {
    let frame = CGRect(x: screen.visibleFrame.midX - 120, y: screen.visibleFrame.midY - 80,
      width: 240, height: 160)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = !transparentEdges
    window.backgroundColor = transparentEdges ? .clear : .red
    window.hasShadow = false
    window.level = .floating
    if transparentEdges { window.contentView = AlphaFixtureView(frame: CGRect(origin: .zero, size: frame.size)) }
    window.orderFrontRegardless()
    window.displayIfNeeded()
    return window
  }

  private func makeTarget(window: NSWindow, screen: NSScreen) throws -> WindowCaptureTarget {
    let displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
    return WindowCaptureTarget(windowID: CGWindowID(window.windowNumber), frame: window.frame,
      displayID: displayID.uint32Value, title: "OwnShot S14 fixture",
      bundleIdentifier: Bundle.main.bundleIdentifier, ownerPID: ProcessInfo.processInfo.processIdentifier,
      kind: .normal)
  }

  private func settleWindowServer() async {
    try? await Task.sleep(nanoseconds: 300_000_000)
  }

  private func makeDestroyedWindowTarget(on screen: NSScreen) async throws -> WindowCaptureTarget {
    let executable = try XCTUnwrap(
      ProcessInfo.processInfo.environment["OWN_SHOT_WINDOW_FIXTURE_EXECUTABLE"],
      "Для закрытых целей нужен отдельный тестовый процесс OWN_SHOT_WINDOW_FIXTURE_EXECUTABLE"
    )
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable))
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptorURL = directory.appendingPathComponent("window.json")
    let frame = CGRect(x: screen.visibleFrame.midX - 120, y: screen.visibleFrame.midY - 80,
      width: 240, height: 160)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [descriptorURL.path, String(Double(frame.minX)), String(Double(frame.minY)),
      String(Double(frame.width)), String(Double(frame.height))]
    // Завершается только созданный здесь процесс. Окна пользователя не затрагиваются.
    defer { if process.isRunning { process.terminate() } }
    try process.run()
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: descriptorURL.path) { break }
      guard process.isRunning else { throw FixtureError.captureFailed("Процесс тестового окна завершился до готовности") }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    struct Descriptor: Decodable {
      let windowID: UInt32
      let x: Double
      let y: Double
      let width: Double
      let height: Double
    }
    let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: descriptorURL))
    let displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
    let target = WindowCaptureTarget(windowID: descriptor.windowID,
      frame: CGRect(x: descriptor.x, y: descriptor.y, width: descriptor.width, height: descriptor.height),
      displayID: displayID.uint32Value, title: "OwnShot S14 child fixture", bundleIdentifier: nil,
      ownerPID: process.processIdentifier, kind: .normal)
    await settleWindowServer()
    process.terminate()
    for _ in 0..<100 {
      if !process.isRunning { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard !process.isRunning else { throw FixtureError.captureFailed("Процесс тестового окна не завершился") }
    process.waitUntilExit()
    await settleWindowServer()
    return target
  }

  private func assertWindowIsUnavailable(_ target: WindowCaptureTarget) async throws {
    let resolved = await WindowSelectionQueryService.resolveWindow(windowID: target.windowID, prefetchedContentTask: nil)
    XCTAssertNil(resolved, "Закрытая цель не должна разрешаться через ScreenCaptureKit")
    let isolated = WindowListDisplaySnapshot.captureWindow(target.windowID, includeWindowShadow: false)
    XCTAssertNil(isolated, "Закрытая цель должна вызвать реальный отказ изолированного CG-захвата")
    guard resolved == nil, isolated == nil else { throw FixtureError.captureFailed("Цель ещё доступна") }
  }

  private func loadSuccessfulImage(_ result: CaptureResult) throws -> CGImage {
    guard case .success(let url) = result else {
      if case .failure(let error) = result { throw FixtureError.captureFailed(error.localizedDescription) }
      throw FixtureError.captureFailed("Файл не создан")
    }
    let attachment = XCTAttachment(contentsOfFile: url)
    attachment.name = url.lastPathComponent
    attachment.lifetime = .keepAlways
    add(attachment)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    guard x >= 0, y >= 0, x < image.width, y < image.height else {
      throw FixtureError.captureFailed("Проверяемый пиксель вне изображения")
    }
    // Явное RGBA-декодирование не зависит от порядка каналов PNG/WindowServer.
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width,
        height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let offset = (y * image.width + x) * 4
    return Array(bytes[offset..<(offset + 4)])
  }

  private func assertRed(_ value: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(value[0], 245, file: file, line: line)
    XCTAssertLessThan(value[1], 10, file: file, line: line)
    XCTAssertLessThan(value[2], 10, file: file, line: line)
    XCTAssertEqual(value[3], 255, file: file, line: line)
  }
}

@MainActor
private final class AlphaFixtureView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.red.setFill()
    bounds.insetBy(dx: 12, dy: 12).fill()
  }
}
