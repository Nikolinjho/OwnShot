import AppKit
import XCTest
@testable import Snapzy

/// Паритет Settings, меню и захвата с CleanShot X 5.0.1: формат имени файла,
/// Advanced, Self-Timer, меню в строке меню, About.
@MainActor
final class OwnShotAppSettingsParityTests: XCTestCase {
  // 2026-01-15 14:30:45.123 UTC
  private let fixedDate = Date(timeIntervalSince1970: 1_768_487_445.123)
  private let utc = CaptureFileNameOptions(usesUTC: true, removesIllegalCharacters: true)

  // MARK: - Сегменты шаблона

  func testШаблонРазбиваетсяНаТекстИТокены() {
    XCTAssertEqual(
      CaptureOutputNaming.segments(of: "Shot %y-%m at %H"),
      [.text("Shot "), .token(.year), .text("-"), .token(.monthNumeric), .text(" at "), .token(.hour)]
    )
  }

  func testНеизвестныйПроцентОстаётсяТекстом() {
    XCTAssertEqual(CaptureOutputNaming.segments(of: "100%z"), [.text("100%z")])
    XCTAssertEqual(CaptureOutputNaming.segments(of: "a%"), [.text("a%")])
    XCTAssertEqual(CaptureOutputNaming.segments(of: "%%y"), [.text("%"), .token(.year)])
  }

  func testПалитраСодержитВсеТринадцатьЭлементов() {
    let palette = CaptureFileNameToken.paletteLeftColumn + CaptureFileNameToken.paletteRightColumn
    XCTAssertEqual(Set(palette), Set(CaptureFileNameToken.allCases))
    XCTAssertEqual(palette.count, 13)
    XCTAssertEqual(CaptureFileNameToken.autoIncrement.code, "%i")
    XCTAssertEqual(CaptureFileNameToken.monthName.title, "Month (name):")
  }

  // MARK: - Значения токенов

  func testФорматЭталонаС12ЧасовымВременем() {
    let name = CaptureOutputNaming.resolveTemplateBaseName(
      "OwnShot %y-%m-%d at %H.%M.%S %p",
      kind: .screenshot,
      date: fixedDate,
      options: utc,
      autoIncrement: 1,
      defaults: UserDefaultsFactory.make()
    )
    XCTAssertEqual(name, "OwnShot 2026-01-15 at 2.30.45 PM")
  }

  func testБезAMPMЧасы24Часовые() {
    let name = CaptureOutputNaming.resolveTemplateBaseName(
      "%H-%M", kind: .screenshot, date: fixedDate, options: utc, autoIncrement: 1, defaults: UserDefaultsFactory.make()
    )
    XCTAssertEqual(name, "14-30")
  }

  func testЧасовойПоясUTCМеняетВремя() {
    let local = CaptureFileNameOptions(usesUTC: false, removesIllegalCharacters: true)
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH"
    let name = CaptureOutputNaming.resolveTemplateBaseName(
      "%H", kind: .screenshot, date: fixedDate, options: local, autoIncrement: 1, defaults: UserDefaultsFactory.make()
    )
    XCTAssertEqual(name, formatter.string(from: fixedDate))
  }

  func testНазваниеОкнаИПриложенияНеСоздаютПодпапки() {
    let context = CaptureContext(appName: "A/B", windowTitle: "x:y")
    let name = CaptureOutputNaming.resolveTemplateBaseName(
      "%a %t", kind: .screenshot, date: fixedDate, context: context, options: utc, autoIncrement: 1,
      defaults: UserDefaultsFactory.make()
    )
    XCTAssertEqual(name, "A-B x-y")
  }

  func testСлучайныеСимволыИСтарыеФигурныеТокеныРаботаютВместе() {
    let name = CaptureOutputNaming.resolveTemplateBaseName(
      "{type}_%r", kind: .recording, date: fixedDate, options: utc, autoIncrement: 1,
      randomCharacters: { "abc123" }, defaults: UserDefaultsFactory.make()
    )
    XCTAssertEqual(name, "recording_abc123")
    XCTAssertEqual(CaptureFileNameToken.randomCharactersLength, 6)
  }

  // MARK: - Remove illegal characters

  func testRemoveIllegalCharactersУправляетЗаменой() {
    let defaults = UserDefaultsFactory.make()
    let strict = CaptureOutputNaming.resolveTemplateBaseName(
      "a?b*c", kind: .screenshot, date: fixedDate, options: utc, autoIncrement: 1, defaults: defaults
    )
    XCTAssertEqual(strict, "a_b_c")
    let relaxed = CaptureOutputNaming.resolveTemplateBaseName(
      "a?b*c:d", kind: .screenshot, date: fixedDate,
      options: CaptureFileNameOptions(usesUTC: true, removesIllegalCharacters: false),
      autoIncrement: 1, defaults: defaults
    )
    XCTAssertEqual(relaxed, "a?b*c_d", "Двоеточие заменяется всегда")
  }

  func testОпцииЧитаютсяИзНастроекСЗначениямиПоУмолчанию() {
    let defaults = UserDefaultsFactory.make()
    XCTAssertEqual(CaptureFileNameOptions.current(defaults: defaults), .defaults)
    XCTAssertTrue(CaptureFileNameOptions.defaults.removesIllegalCharacters)
    XCTAssertFalse(CaptureFileNameOptions.defaults.usesUTC)
    utc.save(to: defaults)
    XCTAssertEqual(CaptureFileNameOptions.current(defaults: defaults), utc)
  }

  // MARK: - Auto-increment

  func testAutoIncrementРасходуетсяТолькоПриСохранении() {
    let defaults = UserDefaultsFactory.make()
    defaults.set("Shot %i", forKey: PreferencesKeys.screenshotFileNameTemplate)
    XCTAssertEqual(CaptureOutputNaming.nextAutoIncrement(defaults: defaults), 1)

    // Превью не трогает счётчик.
    let preview = CaptureOutputNaming.resolveTemplateBaseName("Shot %i", kind: .screenshot, defaults: defaults)
    XCTAssertEqual(preview, "Shot 1")
    XCTAssertEqual(CaptureOutputNaming.nextAutoIncrement(defaults: defaults), 1)

    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: nil, kind: .screenshot, defaults: defaults), "Shot 1")
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: nil, kind: .screenshot, defaults: defaults), "Shot 2")
    XCTAssertEqual(CaptureOutputNaming.nextAutoIncrement(defaults: defaults), 3)

    // Своё имя и шаблон без %i счётчик не сдвигают.
    _ = CaptureOutputNaming.resolveBaseName(customName: "Custom", kind: .screenshot, defaults: defaults)
    _ = CaptureOutputNaming.resolveBaseName(customName: nil, kind: .recording, defaults: defaults)
    XCTAssertEqual(CaptureOutputNaming.nextAutoIncrement(defaults: defaults), 3)
  }

  func testСледующийНомерНеМеньшеЕдиницы() {
    let defaults = UserDefaultsFactory.make()
    CaptureOutputNaming.setNextAutoIncrement(-5, defaults: defaults)
    XCTAssertEqual(CaptureOutputNaming.nextAutoIncrement(defaults: defaults), 1)
    XCTAssertTrue(CaptureOutputNaming.usesAutoIncrement("a%ib"))
    XCTAssertFalse(CaptureOutputNaming.usesAutoIncrement("a%%b"))
  }

  // MARK: - Черновик sheet Customize…

  func testЧерновикСохраняетсяТолькоПоOKИRestoreDefaultsСбрасываетФорматы() {
    let defaults = UserDefaultsFactory.make()
    var draft = OwnShotFileNameFormatDraft.load(defaults: defaults)
    XCTAssertEqual(draft.screenshotTemplate, CaptureOutputKind.screenshot.defaultTemplate)
    XCTAssertEqual(draft.nextAutoIncrement, 1)

    draft.setTemplate("Shot %i", for: .screenshot)
    draft.setTemplate("Rec %y", for: .recording)
    draft.options = utc
    draft.nextAutoIncrement = 42
    // Cancel: в настройках ничего не меняется.
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.screenshotFileNameTemplate))

    draft.save(to: defaults)
    let reloaded = OwnShotFileNameFormatDraft.load(defaults: defaults)
    XCTAssertEqual(reloaded, draft)

    draft.restoreDefaults()
    XCTAssertEqual(draft.template(for: .screenshot), CaptureOutputKind.screenshot.defaultTemplate)
    XCTAssertEqual(draft.template(for: .recording), CaptureOutputKind.recording.defaultTemplate)
    XCTAssertEqual(draft.options, .defaults)
    XCTAssertEqual(draft.nextAutoIncrement, 42, "Restore Defaults не сбрасывает счётчик")
  }

  // MARK: - Advanced

  func testKeepHistoryКакВЭталоне() {
    XCTAssertEqual(OwnShotHistoryRetentionOption.options(including: 3), [1, 3, 7, 30])
    XCTAssertEqual(OwnShotHistoryRetentionOption.options(including: 14), [1, 3, 7, 14, 30])
    XCTAssertEqual(OwnShotHistoryRetentionOption.options(including: 0), [1, 3, 7, 30, 0])
    XCTAssertEqual(OwnShotHistoryRetentionOption.title(forDays: 7), "1 week")
    XCTAssertEqual(OwnShotHistoryRetentionOption.title(forDays: 30), "1 month")
    XCTAssertEqual(OwnShotHistoryRetentionOption.title(forDays: 1), "1 day")
    XCTAssertEqual(OwnShotHistoryRetentionOption.title(forDays: 0), "Forever")
  }

  func testЯзыкиTextRecognitionКакВЭталоне() {
    let options = OwnShotRecognitionLanguageOption.all
    XCTAssertEqual(options.count, 29)
    XCTAssertEqual(options.first?.title, "Automatically Detect Language")
    XCTAssertEqual(options.last?.title, "Vietnamese")
    XCTAssertEqual(Set(options.map(\.id)).count, 29)
    // Для каждого нового языка есть соответствие в Vision.
    let profiled: Set<String> = ["auto", "en", "zh-Hans", "zh-Hant", "fr", "de", "ja", "ko", "ru", "es", "vi"]
    for option in options where !profiled.contains(option.id) {
      XCTAssertNotNil(VisionOCRProfile.additionalVisionLanguages[option.id], option.id)
    }
  }

  func testДополнительныйЯзыкOCRИспользуетПоддерживаемыйЯзыкVision() {
    let profile = VisionOCRProfile.additionalLanguageProfile(for: "uk", supportedLanguages: ["en-US", "uk-UA"])
    XCTAssertEqual(profile?.recognitionLanguages, ["uk-UA", "en-US"])
    XCTAssertEqual(profile?.automaticallyDetectsLanguage, false)
    let prefixed = VisionOCRProfile.additionalLanguageProfile(for: "pt", supportedLanguages: ["pt-PT"])
    XCTAssertEqual(prefixed?.recognitionLanguages.first, "pt-PT")
    XCTAssertNil(VisionOCRProfile.additionalLanguageProfile(for: "pl", supportedLanguages: ["en-US"]))
    XCTAssertNil(VisionOCRProfile.additionalLanguageProfile(for: "ru", supportedLanguages: ["ru-RU"]))
  }

  func testOCRВыбираетЯвнуюРегиональнуюРазновидностьЯзыка() {
    let supported = ["en-US", "pt-BR", "pt-PT", "uk-UA"]
    for input in ["pt-PT", "PT_pt"] {
      let profile = VisionOCRProfile.additionalLanguageProfile(for: input, supportedLanguages: supported)
      XCTAssertEqual(profile?.id, "pt-interface")
      XCTAssertEqual(profile?.recognitionLanguages, ["pt-PT", "en-US"], input)
    }
    let ukrainian = VisionOCRProfile.additionalLanguageProfile(for: "uk-UA", supportedLanguages: supported)
    XCTAssertEqual(ukrainian?.recognitionLanguages, ["uk-UA", "en-US"])
    let portuguese = VisionOCRProfile.additionalLanguageProfile(for: "pt", supportedLanguages: supported)
    XCTAssertEqual(portuguese?.recognitionLanguages, ["pt-BR", "en-US"])
  }

  func testClipboardFileOnlyЕстьВНастройке() {
    XCTAssertEqual(ClipboardImageContentOption.allCases, [.imageAndFile, .imageOnly, .fileOnly])
    XCTAssertEqual(ClipboardImageContentOption.fileOnly.displayName, "File only")
  }

  // MARK: - Screenshots

  func testCrosshairCommandСоЗначком() {
    XCTAssertEqual(OwnShotCrosshairMode.command.title, "When ⌘ Command is pressed")
  }

  // MARK: - Меню в строке меню

  func testMoreСкрытВПокое() {
    XCTAssertFalse(AppStatusBarController.showsMoreSubmenu(extras: [.openAnnotate], optionPressed: false, hasCustomizedMenu: false))
    XCTAssertTrue(AppStatusBarController.showsMoreSubmenu(extras: [.openAnnotate], optionPressed: true, hasCustomizedMenu: false))
    XCTAssertTrue(AppStatusBarController.showsMoreSubmenu(extras: [.openAnnotate], optionPressed: false, hasCustomizedMenu: true))
    XCTAssertFalse(AppStatusBarController.showsMoreSubmenu(extras: [], optionPressed: true, hasCustomizedMenu: true))
  }

  // MARK: - About

  func testAcknowledgmentsСодержитЛицензиюИПакеты() {
    let text = OwnShotAcknowledgments.text
    XCTAssertTrue(text.hasPrefix("Portions of this software utilize the following copyrighted material"))
    XCTAssertTrue(text.contains("Copyright (c) 2026, Trong Duong Duc"))
    for package in OwnShotAcknowledgments.packages {
      XCTAssertTrue(text.contains(package.name), package.name)
    }
    let attributed = OwnShotAcknowledgments.attributedText()
    var links = 0
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      if value != nil { links += 1 }
    }
    XCTAssertGreaterThanOrEqual(links, OwnShotAcknowledgments.packages.count)
  }

  // Решение владельца 14.11.2026: пять строк эталона, ссылок Snapzy нет.
  func testСсылкиAboutНеВедутВСеть() {
    XCTAssertEqual(OwnShotAboutLink.all.map(\.title), ["Website", "Changelog", "Contact Us", "Twitter / X", "YouTube"])
    XCTAssertTrue(OwnShotAboutLink.all.allSatisfy { $0.url?.isFileURL ?? true })
  }
}
