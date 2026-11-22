import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class RecordingParityTests: XCTestCase {
  // MARK: - GIF

  func testGIFМенюСовпадаетСЭталоном() {
    XCTAssertEqual(OwnShotRecordingPreferences.gifFrameRates, [5, 10, 15, 20, 25, 30, 40, 50, 60])
    XCTAssertEqual(OwnShotRecordingPreferences.gifWidths, [0, 1200, 960, 800, 640, 500, 480, 320, 256, 200])
    XCTAssertEqual(OwnShotRecordingPreferences.videoFrameRates, [10, 15, 24, 25, 30, 48, 50, 60])
  }

  func testСтарыеЗначенияGIFПереходятКБлижайшемуПункту() {
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFFPS(24), 25)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFFPS(48), 50)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFFPS(nil), 15)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFFPS(5), 5)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(400), 480)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(600), 640)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(1000), 960)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(1920), 1200)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(nil), 800)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(-5), 800)
    XCTAssertEqual(OwnShotRecordingPreferences.normalizedGIFWidth(0), 0)
  }

  func testGIFOriginalНеОграничиваетШирину() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(0, forKey: OwnShotRecordingPreferenceKeys.gifWidth)
    defaults.set(40, forKey: OwnShotRecordingPreferenceKeys.gifFPS)
    let options = OwnShotRecordingPreferences.gifOptions(defaults: defaults)
    XCTAssertEqual(options.maxWidth, GIFConverter.Options.originalWidth)
    XCTAssertGreaterThan(options.maxWidth, 16_384)
    XCTAssertEqual(options.fps, 40)
  }

  // MARK: - Подсветка кликов

  func testИменованныйЦветКликовЗаменяетПроизвольный() throws {
    let defaults = UserDefaultsFactory.make()
    let custom = NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.4, alpha: 1)
    defaults.set(try NSKeyedArchiver.archivedData(withRootObject: custom, requiringSecureCoding: true),
                 forKey: PreferencesKeys.mouseHighlightColor)
    XCTAssertNil(RecordingOverlayOptions.clickColor(defaults: defaults), "старый произвольный цвет сохраняется")
    XCTAssertTrue(MouseHighlightConfiguration(defaults: defaults).highlightColor.isEqual(custom))

    defaults.set(RecordingClickColor.green.rawValue, forKey: RecordingOverlayPreferenceKeys.clickColor)
    XCTAssertEqual(RecordingOverlayOptions.clickColor(defaults: defaults), .green)
    XCTAssertTrue(MouseHighlightConfiguration(defaults: defaults).highlightColor.isEqual(NSColor.systemGreen))
  }

  func testМенюЦветаКликовВПорядкеЭталона() {
    XCTAssertEqual(RecordingClickColor.allCases.map(\.title), [
      "System Accent color", "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Gray",
    ])
    XCTAssertEqual(RecordingClickStyle.allCases.map(\.title), ["Outline", "Filled"])
  }

  func testСтильИАнимацияКликовЧитаютсяИзНастроек() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(RecordingClickStyle.filled.rawValue, forKey: RecordingOverlayPreferenceKeys.clickStyle)
    defaults.set(false, forKey: RecordingOverlayPreferenceKeys.clickAnimate)
    defaults.set(10.0, forKey: PreferencesKeys.mouseHighlightSize)
    let config = MouseHighlightConfiguration(defaults: defaults)
    XCTAssertEqual(config.style, .filled)
    XCTAssertFalse(config.animateClicks)
    XCTAssertEqual(config.highlightSize, 25, "шкала Size эталона начинается с 25")
  }

  func testСтильFilledЗаливаетКругБезКонтура() {
    let layer = CAShapeLayer()
    let color = NSColor.systemRed.cgColor
    MouseClickHighlightStyling.apply(style: .filled, color: color, ringWidth: 2, to: layer)
    XCTAssertEqual(layer.fillColor, color)
    XCTAssertNil(layer.strokeColor)
    MouseClickHighlightStyling.apply(style: .outline, color: color, ringWidth: 2, to: layer)
    XCTAssertNil(layer.fillColor)
    XCTAssertEqual(layer.strokeColor, color)
    XCTAssertEqual(layer.lineWidth, 2)
  }

  // MARK: - Клавиши

  func testШкалаРазмераКлавишПереводитсяВКегль() {
    XCTAssertEqual(RecordingOverlayOptions.keystrokeFontSize(forSize: 18), 12, accuracy: 0.001)
    XCTAssertEqual(RecordingOverlayOptions.keystrokeFontSize(forSize: 72), 36, accuracy: 0.001)
    XCTAssertEqual(RecordingOverlayOptions.keystrokeFontSize(forSize: 45), 24, accuracy: 0.001)
    XCTAssertEqual(RecordingOverlayOptions.keystrokeFontSize(forSize: 500), 36, accuracy: 0.001)
    XCTAssertEqual(RecordingOverlayOptions.keystrokeSize(forFontSize: 24), 45, accuracy: 0.001)
  }

  func testКонфигурацияКлавишБерётНовыйРазмерИНаследуетСтарыйКегль() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(20.0, forKey: PreferencesKeys.keystrokeFontSize)
    XCTAssertEqual(KeystrokeOverlayConfiguration(defaults: defaults).fontSize, 20)
    XCTAssertEqual(RecordingOverlayOptions.keystrokeSize(defaults: defaults), 36, accuracy: 0.001)

    defaults.set(72.0, forKey: RecordingOverlayPreferenceKeys.keystrokeSize)
    defaults.set(KeystrokeOverlayAppearance.light.rawValue, forKey: RecordingOverlayPreferenceKeys.keystrokeAppearance)
    defaults.set(KeystrokeOverlayKeysMode.all.rawValue, forKey: RecordingOverlayPreferenceKeys.keystrokeKeys)
    defaults.set(false, forKey: RecordingOverlayPreferenceKeys.keystrokeBlur)
    let config = KeystrokeOverlayConfiguration(defaults: defaults)
    XCTAssertEqual(config.fontSize, 36)
    XCTAssertEqual(config.appearance, .light)
    XCTAssertEqual(config.keysMode, .all)
    XCTAssertFalse(config.blurBackground)
  }

  func testКлавишиПоУмолчаниюКакУЭталона() {
    let config = KeystrokeOverlayConfiguration(defaults: UserDefaultsFactory.make())
    XCTAssertEqual(config.appearance, .dark)
    XCTAssertEqual(config.keysMode, .commandOnly)
    XCTAssertTrue(config.blurBackground)
  }

  func testФильтрКлавиш() {
    XCTAssertFalse(KeystrokeMonitorService.shouldDisplay(hasModifier: false, isSpecialKey: false, mode: .commandOnly))
    XCTAssertTrue(KeystrokeMonitorService.shouldDisplay(hasModifier: true, isSpecialKey: false, mode: .commandOnly))
    XCTAssertTrue(KeystrokeMonitorService.shouldDisplay(hasModifier: false, isSpecialKey: true, mode: .commandOnly))
    XCTAssertTrue(KeystrokeMonitorService.shouldDisplay(hasModifier: false, isSpecialKey: false, mode: .all))
  }

  func testПозицииКлавишВПорядкеЭталона() {
    XCTAssertEqual(KeystrokeOverlayPosition.allCases.map(\.hyphenatedTitle), [
      "Top-Left", "Top-Center", "Top-Right", "Bottom-Left", "Bottom-Center", "Bottom-Right",
    ])
    XCTAssertEqual(KeystrokeOverlayAppearance.allCases.map(\.title), ["Dark", "Light"])
    XCTAssertEqual(KeystrokeOverlayKeysMode.allCases.map(\.title), ["Show all keys", "Show only command keys"])
  }

  func testСветлыйБейджИмеетТёмныйТекст() {
    let dark = KeystrokeBadgePalette.colors(for: .dark, blurBackground: false)
    let light = KeystrokeBadgePalette.colors(for: .light, blurBackground: false)
    let blurred = KeystrokeBadgePalette.colors(for: .dark, blurBackground: true)
    XCTAssertGreaterThan(light.background.whiteComponent, dark.background.whiteComponent)
    XCTAssertLessThan(light.text.whiteComponent, dark.text.whiteComponent)
    XCTAssertLessThan(blurred.background.alphaComponent, dark.background.alphaComponent)
  }

  func testОкноКлавишСоздаётсяСРазмытиемИСветлымОформлением() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(KeystrokeOverlayAppearance.light.rawValue, forKey: RecordingOverlayPreferenceKeys.keystrokeAppearance)
    let window = KeystrokeOverlayWindow(
      recordingRect: CGRect(x: 0, y: 0, width: 400, height: 200),
      configuration: KeystrokeOverlayConfiguration(defaults: defaults)
    )
    defer { window.close() }
    window.showKeystroke("⌘ A")
    let blurViews = window.contentView?.subviews.flatMap(\.subviews).compactMap { $0 as? NSVisualEffectView } ?? []
    XCTAssertEqual(blurViews.count, 1)
  }

  // MARK: - Предупреждения перед стартом

  private func conditions(
    disk: RecordingDiskSpace.Level = .ok,
    camera: Bool = false,
    microphone: Bool = false,
    builtIn: Bool = false,
    lidClosed: Bool = false,
    muted: Bool = false
  ) -> RecordingStartConditions {
    RecordingStartConditions(
      diskLevel: disk, captureCamera: camera, captureMicrophone: microphone,
      microphoneIsBuiltIn: builtIn, lidClosed: lidClosed, microphoneMuted: muted,
      lowDiskSuppressed: false, noMicrophoneSuppressed: false, warnAboutMutedMicrophone: true
    )
  }

  func testПредупрежденияПередСтартом() {
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions()), [])
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions(disk: .low)), [.lowDisk])
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions(camera: true)), [.cameraWithoutMicrophone])
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions(camera: true, microphone: true)), [])
    XCTAssertEqual(
      RecordingStartWarnings.warnings(for: conditions(microphone: true, builtIn: true, lidClosed: true, muted: true)),
      [.builtInMicrophoneWithClosedLid],
      "при закрытой крышке встроенный микрофон не проверяется на mute"
    )
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions(microphone: true, lidClosed: true)), [])
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions(microphone: true, muted: true)), [.mutedMicrophone])
    XCTAssertEqual(RecordingStartWarnings.warnings(for: conditions(muted: true)), [])
  }

  func testОтключённыеПредупрежденияНеПоказываются() {
    var value = conditions(disk: .critical, camera: true, microphone: false)
    value.lowDiskSuppressed = true
    value.noMicrophoneSuppressed = true
    XCTAssertEqual(RecordingStartWarnings.warnings(for: value), [])
    var muted = conditions(microphone: true, muted: true)
    muted.warnAboutMutedMicrophone = false
    XCTAssertEqual(RecordingStartWarnings.warnings(for: muted), [])
  }

  func testУровниСвободногоМеста() {
    XCTAssertEqual(RecordingDiskSpace.level(availableBytes: nil), .ok)
    XCTAssertEqual(RecordingDiskSpace.level(availableBytes: RecordingDiskSpace.lowThreshold), .ok)
    XCTAssertEqual(RecordingDiskSpace.level(availableBytes: RecordingDiskSpace.lowThreshold - 1), .low)
    XCTAssertEqual(RecordingDiskSpace.level(availableBytes: RecordingDiskSpace.criticalThreshold - 1), .critical)
    XCTAssertNotNil(RecordingDiskSpace.availableBytes(at: FileManager.default.temporaryDirectory))
  }

  func testМониторДискаОстанавливаетсяПриКритическомУровне() async throws {
    var available: Int64 = RecordingDiskSpace.lowThreshold * 2
    let monitor = RecordingDiskSpaceMonitor(interval: 0.05) { _ in available }
    let directory = FileManager.default.temporaryDirectory
    XCTAssertEqual(monitor.check(directory: directory), .ok)
    let fired = expectation(description: "критический уровень")
    monitor.start(directory: directory) { fired.fulfill() }
    available = RecordingDiskSpace.criticalThreshold / 2
    await fulfillment(of: [fired], timeout: 2)
    monitor.stop()
  }

  func testТекстОшибкиСтартаСохраняетИсходнуюОшибку() {
    let message = RecordingLifecycleText.startErrorMessage(underlying: "Setup failed: x")
    XCTAssertTrue(message.hasPrefix("This may be caused by DRM-protected content"))
    XCTAssertTrue(message.hasSuffix("\n\nSetup failed: x"))
    XCTAssertEqual(RecordingLifecycleText.startErrorMessage(underlying: "  "), L10n.RecordingParity.startErrorMessage)
  }

  func testТекстыИсточниковИРазрешенийКакУЭталона() {
    XCTAssertEqual(L10n.RecordingParity.doNotRecordCamera, "Don't Record Camera")
    XCTAssertEqual(L10n.RecordingParity.doNotRecordMicrophone, "Do Not Record Microphone")
    XCTAssertEqual(L10n.RecordingParity.cameraNoAccessTitle, "OwnShot does not have access to the camera")
    XCTAssertTrue(L10n.RecordingParity.cameraNoAccessMessage.contains("relaunch"))
  }

  func testЗапретСнаДисплеяСнимаетсяПослеЗаписи() {
    let assertion = RecordingDisplaySleepAssertion()
    XCTAssertFalse(assertion.isActive)
    assertion.begin()
    assertion.begin()
    XCTAssertTrue(assertion.isActive)
    assertion.end()
    XCTAssertFalse(assertion.isActive)
  }

  // MARK: - Область записи

  func testOptionВыделяетОтЦентра() {
    let start = CGPoint(x: 100, y: 100)
    let end = CGPoint(x: 130, y: 80)
    XCTAssertEqual(
      RecordingRegionGeometry.selectionRect(start: start, end: end, fromCenter: false),
      CGRect(x: 100, y: 80, width: 30, height: 20)
    )
    XCTAssertEqual(
      RecordingRegionGeometry.selectionRect(start: start, end: end, fromCenter: true),
      CGRect(x: 70, y: 80, width: 60, height: 40)
    )
  }

  func testOptionМеняетРазмерСимметрично() {
    let start = CGRect(x: 100, y: 100, width: 200, height: 100)
    let resized = CGRect(x: 100, y: 100, width: 240, height: 100)
    let centered = RecordingRegionGeometry.centeredResize(resized, from: start, handle: .right, minimumSize: 50)
    XCTAssertEqual(centered, CGRect(x: 60, y: 100, width: 280, height: 100))
    let corner = RecordingRegionGeometry.centeredResize(
      CGRect(x: 100, y: 100, width: 220, height: 130), from: start, handle: .topRight, minimumSize: 50
    )
    XCTAssertEqual(corner, CGRect(x: 80, y: 70, width: 240, height: 160))
    let tooSmall = RecordingRegionGeometry.centeredResize(
      CGRect(x: 100, y: 100, width: 60, height: 100), from: start, handle: .right, minimumSize: 50
    )
    XCTAssertEqual(tooSmall.width, 50)
    XCTAssertEqual(tooSmall.midX, start.midX)
  }

  func testСтрелкиДвигаютИМеняютОбласть() {
    let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    func nudge(_ key: UInt16, _ flags: NSEvent.ModifierFlags = []) -> CGRect? {
      RecordingRegionGeometry.nudged(rect, keyCode: key, modifiers: flags, minimumSize: 50, bounds: bounds)
    }
    XCTAssertEqual(nudge(124), CGRect(x: 101, y: 100, width: 200, height: 100))
    XCTAssertEqual(nudge(123, .shift), CGRect(x: 90, y: 100, width: 200, height: 100))
    XCTAssertEqual(nudge(126), CGRect(x: 100, y: 101, width: 200, height: 100))
    XCTAssertEqual(nudge(124, .command), CGRect(x: 100, y: 100, width: 201, height: 100))
    XCTAssertEqual(nudge(125, [.command, .shift]), CGRect(x: 100, y: 90, width: 200, height: 110))
    XCTAssertEqual(nudge(126, .command)?.maxY, rect.maxY)
    XCTAssertNil(nudge(0))
    let edge = RecordingRegionGeometry.nudged(
      CGRect(x: 0, y: 0, width: 200, height: 100), keyCode: 123, modifiers: .shift, minimumSize: 50, bounds: bounds
    )
    XCTAssertEqual(edge?.minX, 0, "область не уходит за пределы экранов")
  }

  // MARK: - Камера и отсчёт

  func testКамераИмеетЧетыреФормыИЧетыреРазмера() {
    XCTAssertEqual(RecordingCameraShape.allCases, [.circle, .square, .rectangle, .vertical])
    XCTAssertEqual(RecordingCameraSize.allCases, [.small, .medium, .large, .huge])
    let vertical = RecordingCameraSize.huge.baseSize(for: .vertical)
    XCTAssertEqual(vertical.width / vertical.height, 9.0 / 16.0, accuracy: 0.001)
    XCTAssertGreaterThan(
      RecordingCameraSize.huge.baseSize(for: .circle).width,
      RecordingCameraSize.large.baseSize(for: .circle).width
    )
  }

  func testКликПоКамереОтличаетсяОтПеретаскивания() {
    XCTAssertTrue(RecordingCameraOverlayWindow.isClick(from: .zero, to: CGPoint(x: 2, y: 2)))
    XCTAssertFalse(RecordingCameraOverlayWindow.isClick(from: .zero, to: CGPoint(x: 10, y: 0)))
  }

  func testПрогрессОтсчётаРастётДоЕдиницы() {
    XCTAssertEqual(OwnShotRecordingCountdown.progress(seconds: 3, remaining: 3, tick: 0), 0, accuracy: 0.001)
    XCTAssertEqual(OwnShotRecordingCountdown.progress(seconds: 3, remaining: 3, tick: 10), 1.0 / 3, accuracy: 0.001)
    XCTAssertEqual(OwnShotRecordingCountdown.progress(seconds: 3, remaining: 1, tick: 10), 1, accuracy: 0.001)
    XCTAssertEqual(OwnShotRecordingCountdown.progress(seconds: 0, remaining: 0, tick: 0), 1, accuracy: 0.001)
  }
}
