//
//  OwnShotAppSettingsCaptureQA063Tests.swift
//  SnapzyTests
//
//  Паритет spec-063 (app-settings-capture-qa): окно Settings, повторный запуск,
//  обложка рабочего стола, Fn в рекордере, Choose and Pin, Option+Save карточки,
//  поля размера панели записи, лента History.
//

import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotAppSettingsCaptureQA063Tests: XCTestCase {
  // MARK: - SET-169 / APP-124: окно Settings

  func testОкноSettingsФиксированнойШириныИВысотойОт660() {
    XCTAssertEqual(PreferencesWindowController.minimumContentSize, CGSize(width: 810, height: 660))
    XCTAssertEqual(PreferencesWindowController.maximumContentSize.width, 810)
    XCTAssertGreaterThan(PreferencesWindowController.maximumContentSize.height, 10_000)
    XCTAssertEqual(PreferencesWindowController.defaultContentSize, CGSize(width: 810, height: 660))
  }

  func testЗакрытоеОкноБезЯвнойВкладкиОткрываетсяНаGeneral() {
    XCTAssertEqual(PreferencesWindowController.tabToOpen(requested: nil, isWindowVisible: false), .general)
  }

  func testЯвнаяВкладкаОткрываетсяВсегда() {
    XCTAssertEqual(PreferencesWindowController.tabToOpen(requested: .advanced, isWindowVisible: false), .advanced)
    XCTAssertEqual(PreferencesWindowController.tabToOpen(requested: .shortcuts, isWindowVisible: true), .shortcuts)
  }

  func testОткрытоеОкноБезЯвнойВкладкиОстаётсяНаТекущей() {
    XCTAssertNil(PreferencesWindowController.tabToOpen(requested: nil, isWindowVisible: true))
  }

  // MARK: - APP-025: пузырь при повторном запуске

  func testПузырьСтоитПоЦентруПодЗначком() {
    let anchor = CGRect(x: 1000, y: 1084, width: 30, height: 33)
    let frame = AppStatusBarController.readyBubbleFrame(
      anchor: anchor,
      size: CGSize(width: 209, height: 46),
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
    )
    XCTAssertEqual(frame.midX, anchor.midX, accuracy: 0.5)
    XCTAssertEqual(frame.maxY, anchor.minY - 2, accuracy: 0.5)
    XCTAssertEqual(frame.size, CGSize(width: 209, height: 46))
  }

  func testПузырьУКраяЭкранаНеВыходитЗаЭкран() {
    let frame = AppStatusBarController.readyBubbleFrame(
      anchor: CGRect(x: 1700, y: 1084, width: 24, height: 33),
      size: CGSize(width: 209, height: 46),
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
    )
    XCTAssertLessThanOrEqual(frame.maxX, 1728)
  }

  func testТекстПузыряПроOwnShot() {
    XCTAssertEqual(L10n.Menu.readyToUse, "OwnShot is ready to use!")
  }

  // MARK: - SET-220: двойной клик по обложке рабочего стола

  func testДвойнойКликПоОбложкеВызываетПоказИконок() throws {
    let view = OwnShotDesktopCoverView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    var calls = 0
    view.onDoubleClick = { calls += 1 }
    view.mouseDown(with: try mouseDown(clickCount: 1))
    XCTAssertEqual(calls, 0)
    view.mouseDown(with: try mouseDown(clickCount: 2))
    XCTAssertEqual(calls, 1)
  }

  func testДвойнойКликБезОбложкиНичегоНеМеняет() {
    let controller = OwnShotDesktopIconsController.shared
    XCTAssertFalse(controller.isHidden)
    controller.handleCoverDoubleClick()
    XCTAssertFalse(controller.isHidden)
  }

  // MARK: - SET-168: Fn в рекордере сочетаний

  func testFnОтбрасываетсяИЗаписываетсяОстаток() {
    let decision = ShortcutRecordingRules.decisionDroppingFn(
      keyCode: UInt16(kVK_ANSI_K),
      modifiers: [.function, .control, .option],
      allowsSingleKey: false
    )
    XCTAssertEqual(
      decision,
      .record(ShortcutConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)))
    )
  }

  func testБезFnРешениеНеМеняется() {
    let decision = ShortcutRecordingRules.decisionDroppingFn(
      keyCode: UInt16(kVK_ANSI_J),
      modifiers: [.control, .shift],
      allowsSingleKey: false
    )
    XCTAssertEqual(
      decision,
      .record(ShortcutConfig(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | shiftKey)))
    )
  }

  func testОдиночнаяКлавишаСFnОстаётсяКакБыла() {
    let decision = ShortcutRecordingRules.decisionDroppingFn(
      keyCode: UInt16(kVK_F5),
      modifiers: [.function],
      allowsSingleKey: false
    )
    XCTAssertEqual(
      decision,
      .record(ShortcutConfig(keyCode: UInt32(kVK_F5), modifiers: ShortcutConfig.functionCarbonModifier))
    )
  }

  func testEscapeИDeleteСFnРаботаютКакРаньше() {
    XCTAssertEqual(
      ShortcutRecordingRules.decisionDroppingFn(keyCode: UInt16(kVK_Escape), modifiers: [.function], allowsSingleKey: false),
      .cancel
    )
    XCTAssertEqual(
      ShortcutRecordingRules.decisionDroppingFn(keyCode: UInt16(kVK_ForwardDelete), modifiers: [.function], allowsSingleKey: false),
      .clear
    )
  }

  // MARK: - QA-034: Choose and Pin an Image

  func testChooseAndPinПускаетТолькоPNGИJPEG() {
    XCTAssertEqual(OwnShotShortcutCommands.pinnableImageTypes, [.png, .jpeg])
  }

  // MARK: - QA-068: Option+Save карточки

  func testПанельSaveПодставляетИмяБезРасширения() {
    let suggestion = QuickAccessManager.savePanelSuggestion(for: URL(fileURLWithPath: "/tmp/qa1.png"))
    XCTAssertEqual(suggestion.name, "qa1")
    XCTAssertEqual(suggestion.contentType, .png)
  }

  func testФайлБезРасширенияСохраняетИмя() {
    let suggestion = QuickAccessManager.savePanelSuggestion(for: URL(fileURLWithPath: "/tmp/qa1"))
    XCTAssertEqual(suggestion.name, "qa1")
    XCTAssertNil(suggestion.contentType)
  }

  // MARK: - REC-034 / REC-035: поля размера панели записи

  func testВПолеПопадаютТолькоЦифры() {
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.sanitized("250.5"), "2505")
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.sanitized("abc"), "")
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.sanitized("1a2"), "12")
  }

  func testШирина1СтановитсяМинимумом50() {
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.commit("1"), .apply(50))
  }

  func testНольИПустоОстаютсяВПолеБезПрименения() {
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.commit("0"), .keep("0"))
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.commit(""), .keep("0"))
  }

  func testМаксимальныйРазмерНеТеряетТочностьДоФорматированияПоля() {
    let text = String(Int.max)
    guard case let .apply(value) = OwnShotCaptureSizeFieldRules.commit(text) else {
      XCTFail("Максимальное целое значение должно применяться")
      return
    }
    XCTAssertEqual(Int(exactly: value), Int.max)
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.commit(text + "0"), .keep(text + "0"))
  }

  func testШирокийПресетУмещаетОбеСтороныБезПодменыИсходнымиПропорциями() throws {
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: true, value: 2505, ratio: 16.0 / 9)
    let width = try XCTUnwrap(size.width)
    let height = try XCTUnwrap(size.height)
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let selection = CGRect(x: 664, y: 450, width: 400, height: 200)

    let rect = OwnShotCaptureGeometry.resized(
      selection, width: width, height: height, locked: size.locked, within: screen, keepingCenter: true
    )

    XCTAssertTrue(screen.contains(rect))
    XCTAssertEqual(rect.width, screen.width, accuracy: 0.0001)
    XCTAssertEqual(rect.height, height * screen.width / width, accuracy: 0.0001)
    XCTAssertEqual(rect.midY, selection.midY, accuracy: 0.0001)
    XCTAssertFalse(OwnShotCaptureAspectRatio.shouldReset(.sixteenNine, for: rect, allowsRoundedDimensions: true))
  }

  func testВысокийПресетУмещаетОбеСтороныБезПодменыИсходнымиПропорциями() throws {
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: false, value: 1500, ratio: 16.0 / 9)
    let width = try XCTUnwrap(size.width)
    let height = try XCTUnwrap(size.height)
    let screen = CGRect(x: -1800, y: 0, width: 1800, height: 700)
    let selection = CGRect(x: -1100, y: 250, width: 400, height: 200)

    let rect = OwnShotCaptureGeometry.resized(
      selection, width: width, height: height, locked: size.locked, within: screen, keepingCenter: true
    )

    XCTAssertTrue(screen.contains(rect))
    XCTAssertEqual(rect.width, width * screen.height / height, accuracy: 0.0001)
    XCTAssertEqual(rect.height, screen.height, accuracy: 0.0001)
    XCTAssertEqual(rect.midX, selection.midX, accuracy: 0.0001)
    XCTAssertFalse(OwnShotCaptureAspectRatio.shouldReset(.sixteenNine, for: rect, allowsRoundedDimensions: true))
  }

  func testОкруглениеПоляНеСбрасываетПресетНоСвободноеВыделениеСбрасывает() {
    let rounded = CGRect(x: 0, y: 0, width: 801, height: 450)
    let freeform = CGRect(x: 0, y: 0, width: 802, height: 450)

    XCTAssertFalse(OwnShotCaptureAspectRatio.shouldReset(.sixteenNine, for: rounded, allowsRoundedDimensions: true))
    XCTAssertTrue(OwnShotCaptureAspectRatio.shouldReset(.sixteenNine, for: freeform, allowsRoundedDimensions: true))
    XCTAssertTrue(OwnShotCaptureAspectRatio.shouldReset(.sixteenNine, for: rounded))
  }

  func testБольшоеЗначениеПрименяетсяКакЕсть() {
    // Ограничение экраном делает область (OwnShotCaptureGeometry.resized), не поле.
    XCTAssertEqual(OwnShotCaptureSizeFieldRules.commit("2505"), .apply(2505))
    let rect = OwnShotCaptureGeometry.resized(
      CGRect(x: 100, y: 100, width: 400, height: 300),
      width: 2505,
      height: nil,
      locked: false,
      within: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      keepingCenter: true
    )
    XCTAssertEqual(rect.width, 1728)
  }

  func testВСвободномРежимеМеняетсяТолькоВведённаяСторона() {
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: false, value: 200, ratio: nil)
    XCTAssertNil(size.width)
    XCTAssertEqual(size.height, 200)
    XCTAssertFalse(size.locked)
  }

  func testВысота300При16на9Даёт533() {
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: false, value: 300, ratio: 16.0 / 9)
    XCTAssertEqual(size.width, 533)
    XCTAssertEqual(size.height, 300)
  }

  func testШирина800При16на9Даёт450() {
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: true, value: 800, ratio: 16.0 / 9)
    XCTAssertEqual(size.width, 800)
    XCTAssertEqual(size.height, 450)
  }

  func testМинимальнаяШиринаШирокогоПресетаСохраняетПропорции() throws {
    let ratio = 16.0 / 9.0
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: true, value: 50, ratio: ratio)

    XCTAssertTrue(size.locked)
    XCTAssertEqual(try XCTUnwrap(size.width), 50 * ratio, accuracy: 0.0001)
    XCTAssertEqual(size.height, 50)
  }

  func testМинимальнаяВысотаПортретногоПресетаСохраняетПропорции() throws {
    let ratio = 9.0 / 16.0
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: false, value: 50, ratio: ratio)

    XCTAssertTrue(size.locked)
    XCTAssertEqual(size.width, 50)
    XCTAssertEqual(try XCTUnwrap(size.height), 50 / ratio, accuracy: 0.0001)
  }

  func testОбычноеЗначениеОкругляетДругуюСторонуДоМинимума() {
    let size = OwnShotCaptureSizeFieldRules.resolvedSize(editingWidth: true, value: 90, ratio: 16.0 / 9)

    XCTAssertEqual(size.width, 90)
    XCTAssertEqual(size.height, 50)
  }

  func testВыбор16на9СохраняетВысоту() {
    let rect = OwnShotCaptureGeometry.applyingAspectRatio(
      16.0 / 9,
      to: CGRect(x: 500, y: 500, width: 400, height: 200),
      within: CGRect(x: 0, y: 0, width: 1728, height: 1117)
    )
    XCTAssertEqual(rect.height, 200)
    XCTAssertEqual(Int(rect.width.rounded()), 356)
  }

  func testКликВПолеДелаетПанельЗаписиKey() {
    let field = NSTextField(frame: .zero)
    let container = NSView(frame: .zero)
    container.addSubview(field)
    XCTAssertTrue(RecordingToolbarWindow.isTextInput(field))
    XCTAssertFalse(RecordingToolbarWindow.isTextInput(container))
    XCTAssertFalse(RecordingToolbarWindow.isTextInput(nil))
  }

  // MARK: - QA-083: History

  func testЛентаСкрываетЗаписиБезФайла() {
    let present = record(path: "/tmp/present.png")
    let missing = record(path: "/tmp/missing.png")
    let feed = CaptureHistoryStore.feedRecords(from: [present, missing], missingIDs: [missing.id])
    XCTAssertEqual(feed.map(\.id), [present.id])
  }

  func testИсторияРаспознаётТипыТолькоДляИзображений() {
    XCTAssertEqual(HistoryExternalFileRecorder.captureType(for: URL(fileURLWithPath: "/tmp/a.png")), .screenshot)
    XCTAssertEqual(HistoryExternalFileRecorder.captureType(for: URL(fileURLWithPath: "/tmp/a.jpg")), .screenshot)
    XCTAssertNil(HistoryExternalFileRecorder.captureType(for: URL(fileURLWithPath: "/tmp/a.txt")))
    XCTAssertNil(
      HistoryExternalFileRecorder.captureType(for: URL(fileURLWithPath: "/tmp/a.\(OwnShotProjectFormat.fileExtension)"))
    )
  }

  // MARK: - Helpers

  private func mouseDown(clickCount: Int) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: CGPoint(x: 10, y: 10),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: clickCount,
      pressure: 1
    ))
  }

  private func record(path: String) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(),
      filePath: path,
      fileName: (path as NSString).lastPathComponent,
      captureType: .screenshot,
      fileSize: 0,
      capturedAt: Date(),
      width: nil,
      height: nil,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false,
      sourceAppBundleID: nil
    )
  }
}
