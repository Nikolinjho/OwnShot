//
//  OwnShotAppParity059Tests.swift
//  SnapzyTests
//
//  Паритет Settings, меню, захвата и приложения (spec-059).
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotAppParity059Tests: XCTestCase {
  // MARK: - Settings

  func testАкцентТумблеровЗависитОтТемы() {
    XCTAssertEqual(PreferencesAccent.hex(isDark: false), 0xD9373C)
    XCTAssertEqual(PreferencesAccent.hex(isDark: true), 0xFF5257)
    XCTAssertEqual(PreferencesAccent.hex(for: NSAppearance(named: .aqua)!), 0xD9373C)
    XCTAssertEqual(PreferencesAccent.hex(for: NSAppearance(named: .darkAqua)!), 0xFF5257)
  }

  func testСтрокаСПодписьюСтавитКонтролНаПервуюСтроку() {
    XCTAssertEqual(SettingRowLayout.alignment(explicit: nil, descriptionStyle: .subtitle, hasDescription: true), .top)
    XCTAssertEqual(SettingRowLayout.alignment(explicit: nil, descriptionStyle: .subtitle, hasDescription: false), .center)
    XCTAssertEqual(SettingRowLayout.alignment(explicit: nil, descriptionStyle: .hint, hasDescription: true), .center)
    XCTAssertEqual(SettingRowLayout.alignment(explicit: .center, descriptionStyle: .subtitle, hasDescription: true), .center)
  }

  func testЗаголовокОкнаПриглушёнДо4D() {
    let channel = Int((255 * (1 - PreferencesWindowTitle.textOpacity)).rounded())
    XCTAssertEqual(channel, 0x4D)
  }

  func testЗаголовокОкнаВТёмнойТемеЯркийКакУЭталона() {
    // Светлая тема: чёрный с непрозрачностью 0.7 – #4D4D4D на белом.
    let light = PreferencesWindowTitle.textTone(for: .light)
    XCTAssertEqual(light.white, 0)
    XCTAssertEqual(Int((255 * (1 - light.opacity)).rounded()), 0x4D)
    // Тёмная тема: сплошной #E9E9E9, снятый с эталона.
    let dark = PreferencesWindowTitle.textTone(for: .dark)
    XCTAssertEqual(Int((255 * dark.white).rounded()), 0xE9)
    XCTAssertEqual(dark.opacity, 1)
  }

  func testСайдбарНепрозрачныйЦветТемыКакУЭталона() throws {
    XCTAssertEqual(PreferencesSidebarBackground.hex(isDark: false), 0xECECEB)
    XCTAssertEqual(PreferencesSidebarBackground.hex(isDark: true), 0x2C2928)
    // Цвет сплошной: фон за окном не просвечивает ни в одной теме.
    for (name, hex) in [(NSAppearance.Name.aqua, 0xECECEB), (.darkAqua, 0x2C2928)] {
      let appearance = NSAppearance(named: name)!
      XCTAssertEqual(PreferencesSidebarBackground.hex(for: appearance), UInt32(hex))
      var resolved: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        resolved = PreferencesSidebarBackground.nsColor.usingColorSpace(.sRGB)
      }
      let color = try XCTUnwrap(resolved)
      XCTAssertEqual(color.alphaComponent, 1)
      XCTAssertEqual(Int((color.redComponent * 255).rounded()), (hex >> 16) & 255)
      XCTAssertEqual(Int((color.greenComponent * 255).rounded()), (hex >> 8) & 255)
      XCTAssertEqual(Int((color.blueComponent * 255).rounded()), hex & 255)
    }
  }

  func testОкноAcknowledgmentsКакУЭталона() {
    XCTAssertEqual(OwnShotAcknowledgmentsWindowController.frameSize, NSSize(width: 750, height: 420))
    XCTAssertEqual(OwnShotAcknowledgmentsWindowController.contentSize, NSSize(width: 750, height: 388))
  }

  func testТекстыSettingsЭталона() {
    XCTAssertTrue(L10n.SettingsParity.urlSchemeDescription.contains("[URL scheme API]("))
    XCTAssertEqual(L10n.SettingsParity.pixelSnapTitle, "Need more precision?")
    XCTAssertEqual(L10n.SettingsParity.pixelSnapBody, "Automagically select objects to capture with PixelSnap.")
    XCTAssertEqual(L10n.SettingsParity.learnMore, "Learn more")
  }

  func testОверлейВыбораОбластиПоУмолчаниюБезЛинийИЗатемнения() throws {
    let suite = "OwnShotAppParity059Tests.overlay"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(OwnShotCrosshairMode.current(defaults: defaults), .disabled)
    XCTAssertFalse(OwnShotSelectionOverlayDefaults.showsSelectionAreaOverlay(defaults: defaults))
    // При выключенном прицеле старое значение Snapzy не включает затемнение (CAP-109).
    defaults.set(true, forKey: PreferencesKeys.screenshotShowSelectionAreaOverlay)
    XCTAssertFalse(OwnShotSelectionOverlayDefaults.showsSelectionAreaOverlay(defaults: defaults))
    // В режимах с прицелом настройка работает как раньше.
    defaults.set(OwnShotCrosshairMode.always.rawValue, forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    XCTAssertTrue(OwnShotSelectionOverlayDefaults.showsSelectionAreaOverlay(defaults: defaults))
    defaults.set(OwnShotCrosshairMode.command.rawValue, forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    XCTAssertTrue(OwnShotSelectionOverlayDefaults.showsSelectionAreaOverlay(defaults: defaults))
  }

  // MARK: - Меню

  func testЗависимаяКлавишаНеПовторяетСочетаниеРодителя() {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "4")
    item.keyEquivalentModifierMask = [.command, .shift]
    AppStatusBarController.configureOverlayMenuItem(
      item,
      base: "Capture Window",
      shortcut: CaptureOverlayShortcut(keyCode: 49, modifiers: 0),
      parentKind: .area,
      using: KeyboardShortcutManager.shared
    )
    XCTAssertEqual(item.title, "Capture Window")
    XCTAssertEqual(item.keyEquivalent, "")
    XCTAssertEqual(item.keyEquivalentModifierMask, [])
  }

  func testУHideDesktopIconsЕстьSFSymbol() {
    XCTAssertNotNil(NSImage(systemSymbolName: AppStatusBarController.hideDesktopIconsSymbol, accessibilityDescription: nil))
  }

  // MARK: - Приложение

  func testВыходПодтверждаетсяПриЗаписиИНесохранённыхОкнах() {
    XCTAssertEqual(OwnShotQuitGuard.decision(isRecordingActive: false, hasEditedDocuments: false), .terminateNow)
    XCTAssertEqual(OwnShotQuitGuard.decision(isRecordingActive: false, hasEditedDocuments: true), .confirmUnsavedDocuments)
    XCTAssertEqual(OwnShotQuitGuard.decision(isRecordingActive: true, hasEditedDocuments: true), .confirmRecording)
  }

  func testНесохранённоеОкноНаходитсяПоIsDocumentEdited() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    XCTAssertFalse(OwnShotQuitGuard.hasEditedDocuments(in: [window]))
    window.isDocumentEdited = true
    // Невидимое окно не мешает выходу.
    XCTAssertFalse(OwnShotQuitGuard.hasEditedDocuments(in: [window]))
  }

  func testOpenAnnotateБезFilepathОткрываетВыборФайла() throws {
    XCTAssertEqual(SnapzyDeepLinkAction(url: try XCTUnwrap(URL(string: "ownshot://open-annotate"))), .openAnnotate)
    XCTAssertEqual(SnapzyDeepLinkAction(url: try XCTUnwrap(URL(string: "ownshot://open-annotate?action=edit"))), .openAnnotate)
  }

  func testБезDisplayБерётсяЭкранПодКурсором() throws {
    let request = try XCTUnwrap(OwnShotAutomationRequest(command: "capture-area", components: URLComponents(string: "ownshot://capture-area?x=10&y=20&width=100&height=50")))
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    XCTAssertEqual(request.resolvedRect(screenFrames: screens, mouseLocation: CGPoint(x: 2000, y: 500)), CGRect(x: 1450, y: 20, width: 100, height: 50))
    XCTAssertEqual(request.resolvedRect(screenFrames: screens, mouseLocation: CGPoint(x: 100, y: 100)), CGRect(x: 10, y: 20, width: 100, height: 50))
    let primary = try XCTUnwrap(OwnShotAutomationRequest(command: "capture-area", components: URLComponents(string: "ownshot://capture-area?display=1")))
    XCTAssertEqual(primary.resolvedRect(screenFrames: screens, mouseLocation: CGPoint(x: 2000, y: 500)), screens[0])
  }

  // MARK: - Захват

  func testКлавишиРежимовAllInOne() {
    func action(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], editing: Bool = false) -> OwnShotAllInOneController.KeyAction? {
      OwnShotAllInOneController.keyAction(keyCode: keyCode, characters: characters, modifiers: modifiers, isEditingField: editing)
    }
    XCTAssertEqual(action("a"), .activate(.area))
    XCTAssertEqual(action("f"), .activate(.fullscreen))
    XCTAssertEqual(action(" ", keyCode: 49), .activate(.window))
    XCTAssertEqual(action("w"), .activate(.window))
    XCTAssertEqual(action("s"), .activate(.scrolling))
    XCTAssertEqual(action("o"), .activate(.ocr))
    XCTAssertEqual(action("r"), .activate(.recording))
    XCTAssertEqual(action("c", modifiers: .command), .copy)
    XCTAssertEqual(action("", keyCode: 53, editing: true), .dismiss)
    XCTAssertNil(action("a", modifiers: .command))
    XCTAssertNil(action("a", editing: true))
    XCTAssertNil(action("c", modifiers: .command, editing: true))
    XCTAssertNil(action("x"))
  }

  func testПодсказкиКнопокAllInOneСБуквами() {
    XCTAssertEqual(OwnShotAllInOneController.helpText(for: .area), "Capture Area (A)")
    XCTAssertEqual(OwnShotAllInOneController.helpText(for: .fullscreen), "Capture Fullscreen (F)")
    XCTAssertEqual(OwnShotAllInOneController.helpText(for: .window), "Capture Window (Space/W)")
    XCTAssertEqual(OwnShotAllInOneController.helpText(for: .scrolling), "Scrolling Capture (S)")
    XCTAssertEqual(OwnShotAllInOneController.helpText(for: .ocr), "Capture Text (O)")
    XCTAssertEqual(OwnShotAllInOneController.helpText(for: .recording), "Record Screen (R)")
  }

  func testПресетСоотношенияСбрасываетсяДругимВыделением() {
    XCTAssertFalse(OwnShotCaptureAspectRatio.shouldReset(.freeform, for: CGRect(x: 0, y: 0, width: 10, height: 30)))
    XCTAssertFalse(OwnShotCaptureAspectRatio.shouldReset(.square, for: CGRect(x: 0, y: 0, width: 40, height: 40)))
    XCTAssertTrue(OwnShotCaptureAspectRatio.shouldReset(.square, for: CGRect(x: 0, y: 0, width: 40, height: 30)))
  }

  func testОбластьПривязанаКДисплею() {
    let main = ScreenshotLastAreaStore.ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    let external = ScreenshotLastAreaStore.ScreenInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    let rect = CGRect(x: 1540, y: 100, width: 300, height: 200)
    XCTAssertEqual(ScreenshotLastAreaStore.screen(for: rect, in: [main, external]), external)

    let stored = ScreenshotLastAreaStore.Stored(rect: rect, screenID: 2, localOrigin: CGPoint(x: 100, y: 100))
    // Внешний дисплей переставили слева от основного.
    let moved = ScreenshotLastAreaStore.ScreenInfo(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(ScreenshotLastAreaStore.resolve(stored, screens: [main, moved]), CGRect(x: -1820, y: 100, width: 300, height: 200))
    // Дисплей отключён, глобальная область на нём не видна.
    XCTAssertNil(ScreenshotLastAreaStore.resolve(stored, screens: [main]))
  }

  func testСтараяЗаписьОбластиБезScreenIDЧитается() {
    let stored = ScreenshotLastAreaStore.decode(["x": CGFloat(10), "y": CGFloat(20), "width": CGFloat(30), "height": CGFloat(40)])
    XCTAssertEqual(stored, ScreenshotLastAreaStore.Stored(rect: CGRect(x: 10, y: 20, width: 30, height: 40), screenID: nil, localOrigin: nil))
    let main = ScreenshotLastAreaStore.ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    XCTAssertEqual(stored.flatMap { ScreenshotLastAreaStore.resolve($0, screens: [main]) }, CGRect(x: 10, y: 20, width: 30, height: 40))
  }

  func testAlertОтказаScreenRecording() {
    let content = ScreenRecordingPermissionAlert.content
    XCTAssertEqual(content.title, "OwnShot requires Screen Recording permission")
    XCTAssertTrue(content.message.hasPrefix("In order to continue working properly, OwnShot needs Screen Recording permission.\n\nPlease open the Privacy & Security panel"))
    XCTAssertEqual(content.buttons.count, 2)
  }

  func testDiscardВДиалогеИмени() {
    XCTAssertEqual(OwnShotCaptureNamePrompt.enteredName(for: .alertFirstButtonReturn, fieldValue: "typed", suggested: "default"), "typed")
    XCTAssertEqual(OwnShotCaptureNamePrompt.enteredName(for: .alertSecondButtonReturn, fieldValue: "typed", suggested: "default"), "default")
    XCTAssertNil(OwnShotCaptureNamePrompt.enteredName(for: .alertThirdButtonReturn, fieldValue: "typed", suggested: "default"))
    XCTAssertEqual(L10n.CaptureNamePrompt.discard, "Discard")
  }

  func testСсылкаИзQRСпрашиваетПодтверждение() {
    let detections = [
      QRCodeDetection(payload: "hello", boundingBox: .zero, classification: .plainText),
      QRCodeDetection(payload: "https://example.com/a", boundingBox: .zero, classification: .webURL(scheme: "https", host: "example.com")),
    ]
    XCTAssertEqual(OCRLinkPromptManager.qrLinks(from: detections).map(\.absoluteString), ["https://example.com/a"])
    XCTAssertEqual(OCRLinkPromptManager.qrLinkChoice(for: .alertFirstButtonReturn), .open)
    XCTAssertEqual(OCRLinkPromptManager.qrLinkChoice(for: .alertSecondButtonReturn), .cancel)
    XCTAssertEqual(OCRLinkPromptManager.qrLinkChoice(for: .alertThirdButtonReturn), .neverOpen)
    XCTAssertEqual(L10n.QRLinkPrompt.title, "Do you want to open this link?")
    XCTAssertEqual(L10n.QRLinkPrompt.openInBrowser, "Open Link in Browser")
    XCTAssertEqual(L10n.QRLinkPrompt.neverOpen, "Never open links")
  }

  func testReturnЗапускаетИОстанавливаетПрокрутку() {
    XCTAssertEqual(ScrollingCaptureCoordinator.returnKeyAction(phase: .ready, canStart: true, canFinish: false), .start)
    XCTAssertEqual(ScrollingCaptureCoordinator.returnKeyAction(phase: .ready, canStart: false, canFinish: false), .none)
    XCTAssertEqual(ScrollingCaptureCoordinator.returnKeyAction(phase: .capturing, canStart: false, canFinish: true), .finish)
    XCTAssertEqual(ScrollingCaptureCoordinator.returnKeyAction(phase: .saving, canStart: true, canFinish: true), .none)
  }

  func testСтраницыПомощиПрокрутки() {
    XCTAssertEqual(ScrollingCaptureHelpPage.area.title, "How to select an area?")
    XCTAssertEqual(ScrollingCaptureHelpPage.area.next, .scroll)
    XCTAssertNil(ScrollingCaptureHelpPage.limitations.next)
    XCTAssertTrue(ScrollingCaptureHelpPage.limitations.body.contains("When you start scrolling up."))
    XCTAssertEqual(L10n.ScrollingCaptureHelp.selectDrag, "Drag to capture the scrolling part of the screen.")
  }
}
