//
//  OwnShotAppParity060Tests.swift
//  SnapzyTests
//
//  Паритет приложения (spec-060): онбординг, выход с несохранёнными аннотациями,
//  ошибки открытия файла, высота строк меню, Reset All Warning Dialogs.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotAppParity060Tests: XCTestCase {
  // MARK: - Онбординг: переходы

  func testОнбордингИдётОтWelcomeКВопросуПроСочетания() {
    XCTAssertEqual(next(.welcome, .primary), .defaultTool)
  }

  func testYesНаDefaultToolВедётКSystemShortcutsПриКонфликте() {
    XCTAssertEqual(next(.defaultTool, .primary, conflict: true), .systemShortcuts)
    XCTAssertEqual(next(.defaultTool, .primary, conflict: false), .hideDesktopIcons)
  }

  func testNoНаDefaultToolСпрашиваетПроЗапускПриВходе() {
    XCTAssertEqual(next(.defaultTool, .secondary, loginEnabled: false), .launchAtLogin)
    XCTAssertEqual(next(.defaultTool, .secondary, loginEnabled: true), .hideDesktopIcons)
  }

  func testSystemShortcutsНеОтпускаетПокаСочетанияВключены() {
    XCTAssertEqual(next(.systemShortcuts, .primary, conflict: true), .systemShortcuts)
    XCTAssertEqual(next(.systemShortcuts, .primary, conflict: false), .hideDesktopIcons)
    XCTAssertEqual(next(.systemShortcuts, .secondary, conflict: true), .hideDesktopIcons)
  }

  func testХвостОнбордингаЗаканчиваетсяFinish() {
    XCTAssertEqual(next(.launchAtLogin, .secondary), .hideDesktopIcons)
    XCTAssertEqual(next(.hideDesktopIcons, .primary), .preferences)
    XCTAssertEqual(next(.preferences, .primary), .finish)
    XCTAssertNil(next(.finish, .primary))
  }

  func testКнопкиЭкрановОнбординга() {
    XCTAssertEqual(OwnShotOnboardingView.buttonTitles(for: .welcome).primary, "Continue")
    XCTAssertNil(OwnShotOnboardingView.buttonTitles(for: .welcome).secondary)
    XCTAssertEqual(OwnShotOnboardingView.buttonTitles(for: .defaultTool).primary, "Yes")
    XCTAssertEqual(OwnShotOnboardingView.buttonTitles(for: .defaultTool).secondary, "No")
    XCTAssertEqual(OwnShotOnboardingView.buttonTitles(for: .systemShortcuts).secondary, "Skip")
    XCTAssertEqual(OwnShotOnboardingView.buttonTitles(for: .finish).primary, "Done")
  }

  func testТекстыОнбордингаЭталона() {
    XCTAssertEqual(L10n.OwnShotOnboarding.welcomeTitle, "Welcome to OwnShot")
    XCTAssertEqual(L10n.OwnShotOnboarding.defaultToolTitle, "Set as default screenshot tool?")
    XCTAssertEqual(L10n.OwnShotOnboarding.shortcutsNotDisabledTitle, "Shortcuts not disabled")
    XCTAssertEqual(L10n.OwnShotOnboarding.preferencesTitle, "Tweak your workflow")
    XCTAssertTrue(L10n.OwnShotOnboarding.systemShortcutsStep1.contains("(x-apple.systempreferences:com.apple.Keyboard-Settings.extension)"))
    XCTAssertEqual(
      L10n.OwnShotOnboarding.defaultToolMessage(shortcuts: "⌘⇧3"),
      "Do you want to assign ⌘⇧3\nshortcuts to OwnShot and enable launching at login?"
    )
  }

  // MARK: - Онбординг: первый запуск

  func testОнбордингПоказываетсяОдинРазИНеСтарымПользователям() throws {
    let defaults = try makeDefaults("onboarding")
    XCTAssertTrue(OwnShotOnboardingLaunch.shouldPresentOnLaunch(defaults: defaults))
    OwnShotOnboardingLaunch.markPresented(defaults: defaults)
    XCTAssertFalse(OwnShotOnboardingLaunch.shouldPresentOnLaunch(defaults: defaults))

    let legacy = try makeDefaults("onboarding.legacy")
    legacy.set(true, forKey: OwnShotOnboardingLaunch.legacyPermissionsKey)
    XCTAssertFalse(OwnShotOnboardingLaunch.shouldPresentOnLaunch(defaults: legacy))
  }

  func testОкноОнбордингаНеОткрываетсяВТестовомХосте() {
    let controller = OwnShotOnboardingWindowController()
    controller.show(launchPolicy: AppLaunchPolicy(environment: ["XCTestConfigurationFilePath": "/tmp/x"], screenCountProvider: { 1 }))
    XCTAssertFalse(controller.isVisible)
  }

  // MARK: - Онбординг: модель

  func testYesНазначаетСочетанияИВключаетЗапускПриВходе() {
    let actions = FakeOnboardingActions()
    actions.conflict = true
    let model = OwnShotOnboardingModel(actions: actions) {}
    model.answer(.primary)
    model.answer(.primary)
    XCTAssertEqual(actions.assignCount, 1)
    XCTAssertEqual(actions.launchAtLoginValues, [true])
    XCTAssertEqual(model.step, .systemShortcuts)
  }

  func testContinueПриВключённыхСочетанияхПоказываетShortcutsNotDisabled() {
    let actions = FakeOnboardingActions()
    actions.conflict = true
    let model = OwnShotOnboardingModel(actions: actions) {}
    model.answer(.primary)
    model.answer(.primary)
    model.answer(.primary)
    XCTAssertTrue(model.showsShortcutsNotDisabledAlert)
    XCTAssertEqual(model.step, .systemShortcuts)

    actions.conflict = false
    model.showsShortcutsNotDisabledAlert = false
    model.answer(.primary)
    XCTAssertFalse(model.showsShortcutsNotDisabledAlert)
    XCTAssertEqual(model.step, .hideDesktopIcons)
  }

  func testВесьПутьNoДоFinishЗакрываетОкно() {
    let actions = FakeOnboardingActions()
    var finished = false
    let model = OwnShotOnboardingModel(actions: actions) { finished = true }
    model.answer(.primary)    // welcome
    model.answer(.secondary)  // defaultTool: No
    XCTAssertEqual(model.step, .launchAtLogin)
    model.answer(.secondary)  // launchAtLogin: No
    XCTAssertEqual(actions.launchAtLoginValues, [false])
    model.hidesDesktopIcons = true
    XCTAssertEqual(actions.hideDesktopIconsValues, [true])
    model.answer(.primary)    // hideDesktopIcons
    model.answer(.primary)    // preferences
    XCTAssertEqual(model.step, .finish)
    XCTAssertFalse(finished)
    model.answer(.primary)
    XCTAssertTrue(finished)
    XCTAssertEqual(actions.assignCount, 0)
  }

  // MARK: - Выход с несохранёнными аннотациями

  func testВыходСпрашиваетПриНесохранённыхАннотациях() throws {
    let controller = AnnotateWindowController()
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    let state = try XCTUnwrap(OwnShotQuitGuard.annotateState(of: controller))
    XCTAssertFalse(OwnShotQuitGuard.hasUnsavedAnnotations(in: window))
    state.hasUnsavedChanges = true
    XCTAssertTrue(OwnShotQuitGuard.hasUnsavedAnnotations(in: window))
    XCTAssertEqual(
      OwnShotQuitGuard.decision(isRecordingActive: false, hasEditedDocuments: true),
      .confirmUnsavedDocuments
    )
  }

  // MARK: - Ошибки открытия файла

  func testОтсутствующийИБитыйФайлНеОткрываютсяПустымХолстом() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShotAppParity060-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let missing = dir.appendingPathComponent("missing.png")
    XCTAssertEqual(AnnotateManager.fileOpenIssue(at: missing), .missing)

    let broken = dir.appendingPathComponent("broken.png")
    try Data("not an image".utf8).write(to: broken)
    XCTAssertEqual(AnnotateManager.fileOpenIssue(at: broken), .undecodable)

    let valid = dir.appendingPathComponent("valid.png")
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
      NSColor.red.setFill(); rect.fill(); return true
    }
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: valid)
    XCTAssertNil(AnnotateManager.fileOpenIssue(at: valid))
  }

  func testТекстОшибкиОткрытияФайлаЭталона() {
    let url = URL(fileURLWithPath: "/tmp/shot.png")
    let missing = AnnotateManager.fileOpenErrorText(for: .missing, url: url)
    XCTAssertEqual(missing.title, "An error occurred while opening the file")
    XCTAssertTrue(missing.message.contains("Image object not found."))
    XCTAssertTrue(missing.message.contains("shot.png"))
    XCTAssertTrue(AnnotateManager.fileOpenErrorText(for: .undecodable, url: url).message.contains("Image object cannot be decoded."))
  }

  // MARK: - Высота строк меню

  func testЗаголовокСИконкойПолучаетСтроку24БезЦвета() {
    let title = StatusMenuRowMetrics.tallTitle("Capture Area")
    XCTAssertEqual(title.string, "Capture Area")
    let attributes = title.attributes(at: 0, effectiveRange: nil)
    let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
    XCTAssertEqual(paragraph?.minimumLineHeight, StatusMenuRowMetrics.titleLineHeight)
    XCTAssertEqual(paragraph?.maximumLineHeight, StatusMenuRowMetrics.titleLineHeight)
    // Без своего цвета подсветку и выключенное состояние рисует система.
    XCTAssertNil(attributes[.foregroundColor])
  }

  func testСтрокаСИконкойВМенюВысотой30() throws {
    func menuHeight(items: Int) throws -> CGFloat {
      let menu = NSMenu()
      for _ in 0..<items {
        let item = NSMenuItem(title: "Capture Area", action: nil, keyEquivalent: "")
        item.image = try XCTUnwrap(NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil))
        menu.addItem(item)
      }
      let plain = NSMenuItem(title: "About OwnShot…", action: nil, keyEquivalent: "")
      menu.addItem(plain)
      StatusMenuRowMetrics.applyIconRowHeight(to: menu)
      XCTAssertNil(plain.attributedTitle, "строка без иконки остаётся обычной, как About у эталона")
      return menu.size.height
    }
    let row = try menuHeight(items: 2) - menuHeight(items: 1)
    XCTAssertEqual(row, StatusMenuRowMetrics.iconRowHeight, accuracy: 0.5)
  }

  // MARK: - Reset All Warning Dialogs

  func testСбросПредупрежденийВозвращаетВсеДиалоги() throws {
    let defaults = try makeDefaults("warnings")
    for key in OwnShotWarningDialogs.suppressionKeys { defaults.set(true, forKey: key) }
    for key in OwnShotWarningDialogs.enabledByDefaultWarningKeys { defaults.set(false, forKey: key) }
    AnnotateClipboardImageBehavior.doNothing.persist(to: defaults)

    OwnShotWarningDialogs.resetAll(defaults: defaults)

    for key in OwnShotWarningDialogs.allKeys { XCTAssertNil(defaults.object(forKey: key), key) }
    XCTAssertEqual(AnnotateClipboardImageBehavior.stored(userDefaults: defaults), .ask)
    XCTAssertTrue(HistoryDeleteConfirmationPolicy.shouldAsk(defaults: defaults))
    XCTAssertTrue(QuickAccessCloseAllConfirmation(defaults: defaults).requiresPrompt)
  }

  func testСбросПредупрежденийПокрываетКлючиПрошлыхВолн() {
    let keys = Set(OwnShotWarningDialogs.allKeys)
    XCTAssertTrue(keys.contains(RecordingLifecycleKeys.suppressLowDiskWarning))
    XCTAssertTrue(keys.contains(RecordingLifecycleKeys.suppressNoMicrophoneWarning))
    XCTAssertTrue(keys.contains(RecordingLifecycleKeys.warnAboutMutedMicrophone))
    XCTAssertTrue(keys.contains(HistoryDeleteConfirmationPolicy.suppressKey))
    XCTAssertTrue(keys.contains(QuickAccessCloseAllConfirmation.skipConfirmationKey))
    XCTAssertEqual(OwnShotWarningDialogs.resetTitle, "All warning dialogs are now enabled.")
  }

  // MARK: - Helpers

  private func next(
    _ step: OwnShotOnboardingStep,
    _ answer: OwnShotOnboardingAnswer,
    conflict: Bool = false,
    loginEnabled: Bool = false
  ) -> OwnShotOnboardingStep? {
    OwnShotOnboardingFlow.next(
      after: step,
      answer: answer,
      hasSystemShortcutConflict: conflict,
      isLaunchAtLoginEnabled: loginEnabled
    )
  }

  private func makeDefaults(_ name: String) throws -> UserDefaults {
    let suite = "OwnShotAppParity060Tests.\(name)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
  }
}

@MainActor
private final class FakeOnboardingActions: OwnShotOnboardingActions {
  var conflict = false
  var loginEnabled = false
  var assignCount = 0
  var launchAtLoginValues: [Bool] = []
  var hideDesktopIconsValues: [Bool] = []

  var defaultShortcutsDescription: String { "⌘⇧3 ⌘⇧4 ⌘⇧5" }
  var isLaunchAtLoginEnabled: Bool { loginEnabled }
  var hidesDesktopIcons: Bool { false }

  func assignSystemDefaultShortcuts() -> Bool {
    assignCount += 1
    return true
  }

  func hasSystemShortcutConflict() -> Bool { conflict }

  func setLaunchAtLogin(_ enabled: Bool) {
    launchAtLoginValues.append(enabled)
    loginEnabled = enabled
  }

  func setHidesDesktopIcons(_ enabled: Bool) {
    hideDesktopIconsValues.append(enabled)
  }
}
