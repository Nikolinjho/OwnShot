import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotAnnotatePreferencesTests: XCTestCase {
  private final class InactiveWindow: AnnotateWindow {
    override var isKeyWindow: Bool { false }
    override var isMainWindow: Bool { false }
  }

  func testЗакрытиеНастроекУбираетDockЕслиРедакторОтключилИконку() {
    checkDockAfterClosingPreferences(showDockIcon: false, editorLevel: .normal, expected: .accessory)
  }

  func testЗакрытиеНастроекСохраняетDockДляПлавающегоРедактора() {
    checkDockAfterClosingPreferences(showDockIcon: true, editorLevel: .floating, expected: .regular)
  }

  private func checkDockAfterClosingPreferences(
    showDockIcon: Bool, editorLevel: NSWindow.Level, expected: NSApplication.ActivationPolicy
  ) {
    let key = OwnShotAnnotatePreferenceKeys.showDockIcon
    let before = UserDefaults.standard.object(forKey: key)
    let policy = NSApp.activationPolicy()
    let preferences = PreferencesWindowController.shared
    let editor = InactiveWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600))
    editor.isReleasedWhenClosed = false
    defer {
      preferences.close()
      editor.close()
      if let before { UserDefaults.standard.set(before, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
      NSApp.setActivationPolicy(policy)
    }
    UserDefaults.standard.set(showDockIcon, forKey: key)
    editor.level = editorLevel
    editor.orderFront(nil)
    preferences.show(tab: .annotate)
    XCTAssertEqual(NSApp.activationPolicy(), .regular, "Открытые настройки показывают иконку Dock")
    preferences.close()
    XCTAssertTrue(editor.isVisible, "Закрытие настроек сохраняет редактор")
    XCTAssertEqual(NSApp.activationPolicy(), expected, "Dock учитывает настройку редактора и его плавающий уровень")
  }

  func testAlwaysOnTopПрименяетсяТолькоКНовомуРедактору() {
    let key = OwnShotAnnotatePreferenceKeys.alwaysOnTop
    let before = UserDefaults.standard.object(forKey: key)
    defer {
      if let before { UserDefaults.standard.set(before, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.set(false, forKey: key)
    let first = InactiveWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600))
    defer { first.close() }
    UserDefaults.standard.set(true, forKey: key)
    first.syncLevelWithFocusState()
    XCTAssertEqual(first.level, .normal, "Включение не поднимает уже открытое окно")
    let second = InactiveWindow(contentRect: first.frame)
    defer { second.close() }
    XCTAssertEqual(second.level.rawValue, 103, "Новый редактор открывается на уровне эталона")
    UserDefaults.standard.set(false, forKey: key)
    second.syncLevelWithFocusState()
    XCTAssertEqual(second.level.rawValue, 103, "Выключение не опускает уже поднятый редактор")
  }

  func testBackgroundVisibilityIsRememberedOnlyWhenEnabled() {
    let name = "ownshot.annotate.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: OwnShotAnnotatePreferenceKeys.rememberBackground)
    let first = AnnotateState(defaults: defaults)
    first.showSidebar = true
    XCTAssertTrue(AnnotateState(defaults: defaults).showSidebar, "Открытый фон восстанавливается")
    defaults.set(false, forKey: OwnShotAnnotatePreferenceKeys.rememberBackground)
    XCTAssertFalse(AnnotateState(defaults: defaults).showSidebar, "Без запоминания фон закрыт")
  }

  func testExpandedBoundsFollowAnnotationsAndRespectExplicitCrop() {
    let name = "ownshot.annotate.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: OwnShotAnnotatePreferenceKeys.automaticallyExpandCanvas)
    let state = AnnotateState(defaults: defaults)
    state.saveState()
    state.annotations.append(AnnotationItem(type: .rectangle, bounds: CGRect(x: -40, y: -30, width: 100, height: 100), properties: AnnotationProperties()))
    XCTAssertLessThan(state.effectiveContentBounds.minX, 0, "Объект расширяет холст влево")
    XCTAssertEqual(state.makeRenderSnapshot()?.effectiveContentBounds, nil, "Пустой редактор не экспортируется")
    state.cropRect = CGRect(x: 10, y: 10, width: 100, height: 80)
    XCTAssertEqual(state.activeAnnotationBounds, state.cropRect, "Явный Crop имеет приоритет")
    state.undo()
    XCTAssertEqual(state.effectiveContentBounds, state.sourceImageBounds, "Undo убирает расширение вместе с объектом")
  }
  func testArrowOptionOverrideAndSmoothingReachCreatedAnnotations() throws {
    let name = "ownshot.annotate.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: OwnShotAnnotatePreferenceKeys.inverseArrowDirection)
    let state = AnnotateState(defaults: defaults)
    let start = CGPoint(x: 20, y: 30), end = CGPoint(x: 120, y: 90)
    let inverse = try XCTUnwrap(AnnotationFactory.createAnnotation(tool: .arrow, from: start, to: end, path: [], state: state))
    guard case .arrow(let geometry) = inverse.type else { return XCTFail("Создана стрелка") }
    XCTAssertEqual(geometry.start, end, "Начало и конец поменялись местами")
    let normal = try XCTUnwrap(AnnotationFactory.createAnnotation(tool: .arrow, from: start, to: end, path: [], state: state, optionHeld: true))
    guard case .arrow(let normalGeometry) = normal.type else { return XCTFail("Создана стрелка") }
    XCTAssertEqual(normalGeometry.start, start, "Option отменяет обратное направление")
    let points = [start, CGPoint(x: 60, y: 80), end]
    let smoothed = try XCTUnwrap(AnnotationFactory.createAnnotation(tool: .pencil, from: start, to: end, path: points, state: state))
    guard case .path(let smoothPoints) = smoothed.type else { return XCTFail("Создан карандашный штрих") }
    XCTAssertEqual(smoothPoints, AnnotationFactory.smoothedDrawPath(points), "Сглаженные точки сохраняются в редактируемом объекте")
    defaults.set(false, forKey: OwnShotAnnotatePreferenceKeys.smoothDrawing)
    let raw = try XCTUnwrap(AnnotationFactory.createAnnotation(tool: .pencil, from: start, to: end, path: points, state: state))
    guard case .path(let rawPoints) = raw.type else { return XCTFail("Создан карандашный штрих") }
    XCTAssertEqual(rawPoints, points, "Без сглаживания сохраняются исходные точки")
  }

  func testExpandedExportAndFrozenShadowPreference() throws {
    let name = "ownshot.annotate.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: OwnShotAnnotatePreferenceKeys.automaticallyExpandCanvas)
    defaults.set(false, forKey: OwnShotAnnotatePreferenceKeys.drawObjectShadow)
    let image = NSImage(size: CGSize(width: 100, height: 80))
    let state = AnnotateState(image: image, url: URL(fileURLWithPath: "/tmp/annotate-preferences.png"), defaults: defaults, appliesDefaultCanvasPresetOnNewImages: false)
    state.annotations.append(AnnotationItem(type: .filledRectangle, bounds: CGRect(x: -40, y: -30, width: 100, height: 100), properties: AnnotationProperties()))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    XCTAssertFalse(snapshot.drawObjectShadow, "Экспорт фиксирует настройку тени")
    defaults.set(true, forKey: OwnShotAnnotatePreferenceKeys.drawObjectShadow)
    XCTAssertFalse(snapshot.drawObjectShadow, "Изменение настройки не меняет уже начатый экспорт")
    let rendered = try XCTUnwrap(AnnotateExporter.renderFlatFinalImage(snapshot: snapshot))
    XCTAssertEqual(rendered.size, snapshot.effectiveContentBounds.size, "Предпросмотр и экспорт используют одинаковые размеры расширенного холста")
  }

}
