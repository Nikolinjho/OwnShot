//
//  AnnotateBackgroundPanelLayoutTests.swift
//  SnapzyTests
//
//  Доводка панели Background: размеры плиток, Shadow по умолчанию, undo обоев, Blurred и Alignment,
//  целые значения слайдеров, меню Presets и рост окна при открытии панели.
//

import AppKit
import Foundation
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateBackgroundPanelLayoutTests: XCTestCase {
  // AnnotateState держим живым до конца процесса: деинициализация в XCTest может падать.
  private static var retainedAnnotateStates: [AnnotateState] = []
  private static var retainedCanvasPresetStores: [AnnotateCanvasPresetStore] = []
  private static var retainedUserDefaults: [UserDefaults] = []

  private func makeState(resetToNone: Bool = true) -> AnnotateState {
    let defaults = UserDefaultsFactory.make()
    let store = AnnotateCanvasPresetStore(defaults: defaults)
    let state = AnnotateState(
      image: NSImage(size: NSSize(width: 40, height: 40)),
      url: URL(fileURLWithPath: "/tmp/snapzy-background-panel-tests.png"),
      defaults: defaults,
      canvasPresetStore: store
    )
    Self.retainedUserDefaults.append(defaults)
    Self.retainedCanvasPresetStores.append(store)
    Self.retainedAnnotateStates.append(state)
    if resetToNone {
      state.resetCanvasEffectsToNone()
    }
    return state
  }

  private let wallpaperURL = URL(fileURLWithPath: "/tmp/snapzy-background-panel-wallpaper.png")

  // MARK: - Размеры

  func testTileGridMatchesReferenceGeometry() {
    // Эталон: 5 плиток по 43 pt с шагом 46 pt занимают 227 pt.
    XCTAssertEqual(AnnotateBackgroundPanelLayout.tileSize, 43)
    XCTAssertEqual(AnnotateBackgroundPanelLayout.tileSpacing, 3, accuracy: 0.0001)
    let rowWidth = AnnotateBackgroundPanelLayout.tileSize * 5 + AnnotateBackgroundPanelLayout.tileSpacing * 4
    XCTAssertEqual(rowWidth, AnnotateBackgroundPanelLayout.contentWidth, accuracy: 0.0001)
  }

  func testPlainColorGridMatchesReferenceGeometry() {
    // Эталон: 9 кружков по 24 pt в ряду 227 pt, ряды вплотную.
    XCTAssertEqual(AnnotateBackgroundPanelLayout.colorSwatchSize, 24)
    XCTAssertEqual(AnnotateBackgroundPanelLayout.colorColumns, 9)
    XCTAssertEqual(AnnotateBackgroundPanelLayout.colorSpacing, 1.375, accuracy: 0.0001)
    XCTAssertEqual(AnnotateBackgroundPanelLayout.colorRowSpacing, 0)
  }

  func testSidebarFitsReferenceContentWidth() {
    let layout = AnnotateBackgroundPanelLayout.self
    XCTAssertEqual(AnnotateSidebarMetrics.width, 250)
    XCTAssertEqual(layout.sidebarWidth - layout.leadingPadding - layout.trailingPadding, layout.contentWidth)
  }

  // MARK: - Shadow по умолчанию

  func testFreshEditorShadowIsZero() {
    let state = makeState(resetToNone: false)
    XCTAssertEqual(state.shadowIntensity, 0)
    XCTAssertEqual(AnnotationCanvasEffects().shadowIntensity, 0)
  }

  func testUndoAfterGradientInFreshEditorRestoresZeroShadow() {
    let state = makeState(resetToNone: false)
    state.selectGradientBackground(.pinkOrange)

    state.undo()

    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertEqual(state.shadowIntensity, 0)
  }

  // MARK: - Undo

  func testWallpaperSelectionIsUndoable() {
    let state = makeState()

    state.selectWallpaperBackground(wallpaperURL)

    XCTAssertEqual(state.backgroundStyle, .wallpaper(wallpaperURL))
    XCTAssertEqual(state.padding, 24)
    XCTAssertTrue(state.canUndo)

    state.undo()

    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertEqual(state.padding, 0)
  }

  func testReselectingSameWallpaperDoesNotAddUndoStep() {
    let state = makeState()
    state.selectWallpaperBackground(wallpaperURL)

    state.selectWallpaperBackground(wallpaperURL)

    // Повторный клик не создаёт точку: один undo возвращает None.
    state.undo()
    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.canUndo)
  }

  func testBlurredSelectionAndToggleOffAreUndoable() {
    let state = makeState()
    state.selectWallpaperBackground(wallpaperURL)

    state.selectBlurredBackgroundEffect(.frosted)
    XCTAssertTrue(state.isBlurredBackgroundEnabled)
    XCTAssertEqual(state.blurredBackgroundEffect, .frosted)

    state.selectBlurredBackgroundEffect(.frosted)
    XCTAssertFalse(state.isBlurredBackgroundEnabled)

    state.undo()
    XCTAssertTrue(state.isBlurredBackgroundEnabled)
    XCTAssertEqual(state.blurredBackgroundEffect, .frosted)

    state.undo()
    XCTAssertFalse(state.isBlurredBackgroundEnabled)
    XCTAssertEqual(state.backgroundStyle, .wallpaper(wallpaperURL))
  }

  func testBlurredIsIgnoredWithoutImageOrColorBackground() {
    let state = makeState()

    state.selectBlurredBackgroundEffect(.soft)

    XCTAssertFalse(state.isBlurredBackgroundEnabled)
    XCTAssertFalse(state.canUndo)
  }

  func testAlignmentIsUndoableInOneStepWithAutoPadding() {
    let state = makeState()

    state.selectImageAlignment(.topLeft)

    XCTAssertEqual(state.imageAlignment, .topLeft)
    XCTAssertEqual(state.padding, 24)
    XCTAssertNotEqual(state.backgroundStyle, .none)

    state.undo()

    XCTAssertEqual(state.imageAlignment, .center)
    XCTAssertEqual(state.padding, 0)
    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.canUndo)
  }

  func testReselectingSameAlignmentDoesNotAddUndoStep() {
    let state = makeState()
    state.selectImageAlignment(.center)
    XCTAssertFalse(state.canUndo)
  }

  // MARK: - Слайдеры

  func testSliderValuesAreIntegralAndClamped() {
    let range: ClosedRange<CGFloat> = 0 ... 300
    XCTAssertEqual(AnnotateBackgroundSliderValue.integral(12.4, in: range), 12)
    XCTAssertEqual(AnnotateBackgroundSliderValue.integral(12.5, in: range), 13)
    XCTAssertEqual(AnnotateBackgroundSliderValue.integral(-3, in: range), 0)
    XCTAssertEqual(AnnotateBackgroundSliderValue.integral(301.7, in: range), 300)
    XCTAssertEqual(AnnotateBackgroundSliderValue.integral(.nan, in: range), 0)
  }

  // MARK: - Меню Presets

  func testDefaultPresetSubmenuStartsWithCheckedNone() {
    let first = UUID()
    let entries = AnnotateBackgroundPresetMenu.defaultPresetEntries(
      presets: [(id: first, name: "Preset 1")],
      defaultId: nil,
      noneTitle: "None"
    )
    XCTAssertEqual(entries.map(\.title), ["None", "Preset 1"])
    XCTAssertEqual(entries.map(\.isChecked), [true, false])
    XCTAssertNil(entries[0].presetId)
  }

  func testDefaultPresetSubmenuChecksDefaultPreset() {
    let first = UUID()
    let second = UUID()
    let entries = AnnotateBackgroundPresetMenu.defaultPresetEntries(
      presets: [(id: first, name: "A"), (id: second, name: "B")],
      defaultId: second,
      noneTitle: "None"
    )
    XCTAssertEqual(entries.map(\.isChecked), [false, false, true])
  }

  func testDefaultPresetSubmenuFallsBackToNoneForUnknownDefault() {
    let entries = AnnotateBackgroundPresetMenu.defaultPresetEntries(
      presets: [(id: UUID(), name: "A")],
      defaultId: UUID(),
      noneTitle: "None"
    )
    XCTAssertEqual(entries.map(\.isChecked), [true, false])
  }

  func testPresetEntriesCheckSelectedPreset() {
    let first = UUID()
    let second = UUID()
    let entries = AnnotateBackgroundPresetMenu.presetEntries(
      presets: [(id: first, name: "A"), (id: second, name: "B")],
      selectedId: first
    )
    XCTAssertEqual(entries.map(\.isChecked), [true, false])
  }

  func testPresetMenuHasDefaultPresetSubmenuAndAddItem() {
    let controller = AnnotateBackgroundPresetMenuController()
    let menu = controller.makeMenu()

    XCTAssertEqual(menu.items.map(\.title), [
      AnnotateBackgroundPanelStrings.defaultPreset,
      "",
      AnnotateBackgroundPanelStrings.addNewPresetMenuItem,
    ])
    XCTAssertTrue(menu.items[1].isSeparatorItem)
    let submenu = try? XCTUnwrap(menu.items[0].submenu)
    XCTAssertEqual(submenu?.items.first?.title, AnnotateBackgroundPanelStrings.autoApplyPresetHeader)
    XCTAssertEqual(submenu?.items.last?.title, L10n.Common.none)
    XCTAssertEqual(submenu?.items.last?.state, .on)
  }

  func testPresetNameIsTrimmedAndEmptyRejected() {
    XCTAssertEqual(AnnotateBackgroundPresetMenu.normalizedName("  Card  "), "Card")
    XCTAssertNil(AnnotateBackgroundPresetMenu.normalizedName("   \n"))
  }

  func testSelectingPresetFromSidebarIsUndoable() {
    let state = makeState()
    state.selectGradientBackground(.pinkOrange)
    XCTAssertEqual(state.saveCurrentCanvasAsPreset(name: "Card"), .success)
    let preset = try? XCTUnwrap(state.selectedCanvasPreset)
    state.selectNoneCanvasEffects()

    state.selectCanvasPresetFromSidebar(preset!)
    XCTAssertEqual(state.backgroundStyle, .gradient(.pinkOrange))

    state.undo()
    XCTAssertEqual(state.backgroundStyle, .none)
  }

  // MARK: - Рост окна

  func testOpeningBackgroundGrowsWindowFromReferenceSize() throws {
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    let current = CGRect(x: 369, y: 200, width: 990, height: 753)

    let frame = try XCTUnwrap(AnnotateBackgroundWindowSizing.grownFrame(current: current, visibleFrame: visible))

    XCTAssertEqual(frame.size, CGSize(width: 990, height: 875))
    // Верхний край остаётся на месте.
    XCTAssertEqual(frame.maxY, current.maxY)
  }

  func testWindowAlreadyTallEnoughIsNotResized() {
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    XCTAssertNil(AnnotateBackgroundWindowSizing.grownFrame(
      current: CGRect(x: 0, y: 100, width: 990, height: 875),
      visibleFrame: visible
    ))
    XCTAssertNil(AnnotateBackgroundWindowSizing.grownFrame(
      current: CGRect(x: 0, y: 100, width: 990, height: 950),
      visibleFrame: visible
    ))
  }

  func testWindowGrowthStaysInsideVisibleFrame() throws {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 800)
    let current = CGRect(x: 100, y: 40, width: 990, height: 600)

    let frame = try XCTUnwrap(AnnotateBackgroundWindowSizing.grownFrame(current: current, visibleFrame: visible))

    XCTAssertEqual(frame.height, 800)
    XCTAssertEqual(frame.minY, visible.minY)
    XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
  }
}
