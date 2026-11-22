import AVFoundation
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotRecordingPreferencesTests: XCTestCase {
  func testGIFПоУмолчаниюИспользует800Пикселей() {
    XCTAssertEqual(GIFConverter.Options.default.maxWidth, 800)
  }

  func testMonoНастройкиСохраняютОдинКанал() {
    for settings in [
      RecordingAudioEncodingSettings.makeSystemAudioSettings(mono: true),
      RecordingAudioEncodingSettings.makeMicrophoneAudioSettings(mono: true),
      RecordingAudioEncodingSettings.makeMixedAudioSettings(mono: true)
    ] {
      XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
      let layoutData = settings[AVChannelLayoutKey] as? Data
      XCTAssertNotNil(layoutData)
      if let layoutData {
        let tag = layoutData.withUnsafeBytes { $0.loadUnaligned(as: AudioChannelLayout.self).mChannelLayoutTag }
        XCTAssertEqual(tag, kAudioChannelLayoutTag_Mono)
      }
    }
  }

  func testРаздельныеДорожкиНеТребуютСведения() {
    XCTAssertFalse(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 2, separateTracks: true))
    XCTAssertTrue(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 2, separateTracks: false))
    XCTAssertFalse(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 1, separateTracks: false))
  }

  func testRetina1xНеМасштабируетВышеИсходника() {
    XCTAssertEqual(OwnShotRecordingPreferences.outputScale(backingScale: 2, scaleRetina: true), 1)
    XCTAssertEqual(OwnShotRecordingPreferences.outputScale(backingScale: 1, scaleRetina: true), 1)
    XCTAssertEqual(OwnShotRecordingPreferences.outputScale(backingScale: 2, scaleRetina: false), 2)
  }

  func testНастройкиОграничиваютПовреждённыеЗначенияGIF() {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(-10, forKey: OwnShotRecordingPreferenceKeys.gifFPS)
    defaults.set(-1, forKey: OwnShotRecordingPreferenceKeys.gifWidth)
    defaults.set(9.0, forKey: OwnShotRecordingPreferenceKeys.gifQuality)
    let options = OwnShotRecordingPreferences.gifOptions(defaults: defaults)
    XCTAssertEqual(options.fps, 15)
    XCTAssertEqual(options.maxWidth, 800)
    XCTAssertEqual(options.quality, 1)
  }
}

extension OwnShotRecordingPreferencesTests {
  func testОптимизацияGIFОбъединяетОдинаковыеКадрыБезПотериДлительности() {
    var sequencer = GIFFrameSequencer<Int>(frameDelay: 0.1, framesEqual: { $0 == $1 })
    XCTAssertTrue(sequencer.resolve(index: 0, frame: 7).isEmpty)
    XCTAssertTrue(sequencer.resolve(index: 1, frame: 7).isEmpty)
    let result = sequencer.resolve(index: 2, frame: 9) + sequencer.finish(frameCount: 3)
    XCTAssertEqual(result.map(\.frame), [7, 9])
    XCTAssertEqual(result[0].delay, 0.2, accuracy: 0.0001)
    XCTAssertEqual(result[1].delay, 0.1, accuracy: 0.0001)
  }

  func testКачествоGIFМеняетЦветБезИзмененияРазмера() throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let image = try XCTUnwrap(context.makeImage())
    let low = try XCTUnwrap(GIFFrameProcessing.quantized(image, quality: 0))
    let high = try XCTUnwrap(GIFFrameProcessing.quantized(image, quality: 1))
    XCTAssertEqual(low.width, 1)
    XCTAssertEqual(low.height, 1)
    XCTAssertNotEqual(low.dataProvider?.data as Data?, high.dataProvider?.data as Data?)
  }
}

extension OwnShotRecordingPreferencesTests {
  func testОтменённыйОтсчётНеРазрешаетНачатьЗапись() async {
    let shouldStart = await OwnShotRecordingCountdown.wait(seconds: 3, isCurrent: { false })
    XCTAssertFalse(shouldStart)
  }

  func testНулевойОтсчётНачинаетЗаписьБезОжидания() async {
    let shouldStart = await OwnShotRecordingCountdown.wait(seconds: 0, isCurrent: { true })
    XCTAssertTrue(shouldStart)
  }
}

extension OwnShotRecordingPreferencesTests {
  func testEscОтменяетПервыйИПовторныйОтсчётПослеЗапуска() async throws {
    _ = NSApplication.shared
    for _ in 0..<2 {
      let waiting = Task { await OwnShotRecordingCountdown.wait(seconds: 1, isCurrent: { true }) }
      try await Task.sleep(nanoseconds: 100_000_000)
      let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: 0, context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
      NSApplication.shared.sendEvent(escape)
      let allowed = await waiting.value
      XCTAssertFalse(allowed, "Esc должен отменять каждый новый отсчёт, включая повторный запуск")
    }
  }

  func testOriginalСохраняет5KБезМасштабированияRetina() {
    let scale = OwnShotRecordingPreferences.outputScale(backingScale: 2, scaleRetina: false)
    let size = RecordingVideoCompatibilityLimiter.clampedOutputSize(
      width: Int(2560 * scale), height: Int(1440 * scale), resolution: .native, fps: 30
    )
    XCTAssertEqual(size.width, 5120)
    XCTAssertEqual(size.height, 2880)
  }
}

extension OwnShotRecordingPreferencesTests {
  func testЗадержкиGIFОкругляютсяПоНакопленномуВремениДоОбъединенияКадров() {
    for fps in [15, 30, 60] {
      var sequencer = GIFFrameSequencer<Int>(frameDelay: 1 / Double(fps))
      var output: [GIFFrameSequencer<Int>.Output] = []
      for index in 0..<fps { output += sequencer.resolve(index: index, frame: index) }
      output += sequencer.finish(frameCount: fps)
      var boundary = 0.0
      for (index, frame) in output.enumerated() {
        XCTAssertEqual(frame.delay * 100, (frame.delay * 100).rounded(), accuracy: 0.00001)
        boundary += frame.delay
        XCTAssertEqual(boundary, (Double(index + 1) / Double(fps) * 100).rounded() / 100, accuracy: 0.00001)
      }
      XCTAssertEqual(boundary, 1, accuracy: 0.00001)
    }
  }
}

extension OwnShotRecordingPreferencesTests {
  func testНастройкиGIFПередаютКаждуюЧастотуРазмерКачествоИОптимизацию() {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    for fps in OwnShotRecordingPreferences.gifFrameRates {
      for width in OwnShotRecordingPreferences.gifWidths where width != OwnShotRecordingPreferences.gifOriginalWidth {
        defaults.set(fps, forKey: OwnShotRecordingPreferenceKeys.gifFPS)
        defaults.set(width, forKey: OwnShotRecordingPreferenceKeys.gifWidth)
        defaults.set(false, forKey: OwnShotRecordingPreferenceKeys.gifOptimize)
        defaults.set(0.25, forKey: OwnShotRecordingPreferenceKeys.gifQuality)
        let options = OwnShotRecordingPreferences.gifOptions(defaults: defaults)
        XCTAssertEqual(options.fps, fps)
        XCTAssertEqual(options.maxWidth, CGFloat(width))
        XCTAssertEqual(options.quality, 0.25)
        XCTAssertFalse(options.optimize)
      }
    }
  }

  func testОтменаЗадачиИЗаменаПоколенияПрерываютОтсчётАСледующийУспешен() async throws {
    let cancelled = Task { await OwnShotRecordingCountdown.wait(seconds: 1, isCurrent: { true }) }
    try await Task.sleep(nanoseconds: 100_000_000)
    cancelled.cancel()
    let cancelledResult = await cancelled.value
    XCTAssertFalse(cancelledResult)
    var current = true
    let replaced = Task { await OwnShotRecordingCountdown.wait(seconds: 1, isCurrent: { current }) }
    try await Task.sleep(nanoseconds: 100_000_000)
    current = false
    let replacedResult = await replaced.value
    XCTAssertFalse(replacedResult)
    let restarted = await OwnShotRecordingCountdown.wait(seconds: 1, isCurrent: { true })
    XCTAssertTrue(restarted)
  }

  func testОсновныеПереключателиЗаписиЧитаютСохранённыеЗначения() {
    let defaults = UserDefaultsFactory.make()
    for enabled in [false, true] {
      for key in [PreferencesKeys.recordingHoverBarVisible, PreferencesKeys.recordingShowTimeOnMenuBar,
                  PreferencesKeys.recordingDimNonSelectedArea] { defaults.set(enabled, forKey: key) }
      XCTAssertEqual(RecordingToolbarPreferences.hoverBarVisible(defaults: defaults), enabled)
      XCTAssertEqual(RecordingToolbarPreferences.showTimeOnMenuBar(defaults: defaults), enabled)
      XCTAssertEqual(RecordingToolbarPreferences.dimNonSelectedArea(defaults: defaults), enabled)
    }
  }
}
