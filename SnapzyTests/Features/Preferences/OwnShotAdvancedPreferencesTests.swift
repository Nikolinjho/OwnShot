import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotAdvancedPreferencesTests: XCTestCase {
  func testЯзыкЗапросаOCRИмеетПриоритетНадНастройкой() async throws {
    let defaults = UserDefaultsFactory.make()
    defaults.set("ru", forKey: OwnShotAdvancedPreferenceKeys.recognitionLanguage)
    let provider = RecordingOCRProvider()
    let service = OCRService(defaults: defaults, provider: provider)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))
    _ = try await service.recognizeText(from: image, preferredLanguageIdentifier: "ja")
    XCTAssertEqual(provider.language, "ja", "Явный язык API не заменяется глобальной настройкой")
    _ = try await service.recognizeText(from: image)
    XCTAssertEqual(provider.language, "ru", "Обычный захват использует выбранный язык")
  }

  func testЯвныеПереносыOCRНеТеряютсяДоОбработкиAPI() async throws {
    let defaults = UserDefaultsFactory.make()
    defaults.set(false, forKey: OwnShotAdvancedPreferenceKeys.keepLineBreaks)
    let service = OCRService(defaults: defaults, provider: RecordingOCRProvider())
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))
    let preserved = try await service.recognizeText(from: image, preserveLineBreaks: true)
    XCTAssertEqual(preserved, "First line\nsecond line")
    let joined = try await service.recognizeText(from: image, preserveLineBreaks: false)
    XCTAssertEqual(joined, "First line second line")
    let preference = try await service.recognizeText(from: image)
    XCTAssertEqual(preference, "First line second line")
    defaults.set(true, forKey: OwnShotAdvancedPreferenceKeys.keepLineBreaks)
    let changed = try await service.recognizeText(from: image)
    XCTAssertEqual(changed, "First line\nsecond line")
  }

  func testOCRБезПереносовУбираетВсеРазделителиСтрок() async throws {
    let provider = RecordingOCRProvider()
    let input = "First\r\nsecond\rthird\u{2028}fourth\u{2029}fifth"
    provider.result = OCRResult(engine: .remote, profileID: "test", text: input, lines: [], averageConfidence: 1)
    let service = OCRService(defaults: UserDefaultsFactory.make(), provider: provider)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))

    let compact = try await service.recognizeText(from: image, preserveLineBreaks: false)
    let preserved = try await service.recognizeText(from: image, preserveLineBreaks: true)

    XCTAssertEqual(compact, "First second third fourth fifth")
    XCTAssertEqual(preserved, input)
  }

  func testЯвныеПереносыOCRРазделяютЗаголовокИФрагментыДругойСтроки() async throws {
    let provider = RecordingOCRProvider()
    let heading = OCRTextLine(text: "Title", confidence: 1, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.2))
    let first = OCRTextLine(text: "First", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.375, width: 0.1, height: 0.02))
    let second = OCRTextLine(text: "line", confidence: 1, boundingBox: CGRect(x: 0.3, y: 0.375, width: 0.1, height: 0.02))
    provider.result = OCRResult(
      engine: .vision, profileID: "test", text: "First line Title",
      lines: [first, second, heading], averageConfidence: 1
    )
    let service = OCRService(defaults: UserDefaultsFactory.make(), provider: provider)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))

    let result = try await service.recognizeText(from: image, preserveLineBreaks: true)

    XCTAssertEqual(result, "Title\nFirst line")
  }

  private final class RecordingOCRProvider: OCRProvider {
    let engine = OCREngine.vision
    var language: String?
    var result = OCRResult(engine: .vision, profileID: "test", text: "First line\nsecond line", lines: [], averageConfidence: 1)

    func recognize(_ request: OCRRequest) async throws -> OCRResult {
      language = request.preferredLanguageIdentifier
      return result
    }
  }

  func testRetinaSuffixUsesOutputScaleAndRespectsPreference() {
    let defaults = UserDefaultsFactory.make()
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: "Capture", kind: .screenshot, scaleFactor: 2, defaults: defaults), "Capture@2x")
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: "Capture", kind: .screenshot, scaleFactor: 1, defaults: defaults), "Capture")
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: "Capture@2x", kind: .screenshot, scaleFactor: 2, defaults: defaults), "Capture@2x")
    defaults.set(false, forKey: OwnShotAdvancedPreferenceKeys.addRetinaSuffix)
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: "Capture", kind: .screenshot, scaleFactor: 2, defaults: defaults), "Capture")
  }

  func testRecordingNeverAddsRetinaSuffix() {
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: "Recording", kind: .recording, scaleFactor: 2, defaults: UserDefaultsFactory.make()), "Recording")
  }

  func testAllInOneForgetSelectionUsesCenteredDefaultWithoutDeletingStoredArea() {
    let defaults = UserDefaultsFactory.make()
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let previous = CGRect(x: 20, y: 40, width: 100, height: 200)
    XCTAssertEqual(OwnShotAdvancedPreferences.initialSelection(previous: previous, screenFrame: screen, defaults: defaults), previous)
    defaults.set(false, forKey: OwnShotAdvancedPreferenceKeys.rememberAllInOneSelection)
    XCTAssertEqual(OwnShotAdvancedPreferences.initialSelection(previous: previous, screenFrame: screen, defaults: defaults), CGRect(x: 400, y: 270, width: 640, height: 360))
  }

  func testOCRExplicitLanguageOverridesAutomaticHint() {
    let defaults = UserDefaultsFactory.make()
    XCTAssertEqual(OwnShotAdvancedPreferences.recognitionLanguage(fallback: "en", defaults: defaults), "en")
    defaults.set("ru", forKey: OwnShotAdvancedPreferenceKeys.recognitionLanguage)
    XCTAssertEqual(OwnShotAdvancedPreferences.recognitionLanguage(fallback: "en", defaults: defaults), "ru")
  }

  func testOCRLineBreakPreferenceKeepsParagraphsAndCode() {
    let defaults = UserDefaultsFactory.make()
    let text = "First line\nsecond line\n\nNext paragraph"
    XCTAssertEqual(OwnShotAdvancedPreferences.recognizedText(text, contentType: .interfaceText, defaults: defaults), "First line second line\n\nNext paragraph")
    XCTAssertEqual(OwnShotAdvancedPreferences.recognizedText(text, contentType: .code, defaults: defaults), text)
    defaults.set(true, forKey: OwnShotAdvancedPreferenceKeys.keepLineBreaks)
    XCTAssertEqual(OwnShotAdvancedPreferences.recognizedText(text, contentType: .interfaceText, defaults: defaults), text)
  }
}
