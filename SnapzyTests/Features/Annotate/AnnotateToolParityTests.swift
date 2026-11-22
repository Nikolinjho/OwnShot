//
//  AnnotateToolParityTests.swift
//  SnapzyTests
//
//  Паритет инструментов редактора с CleanShot X: меню Font size, форма Spotlight,
//  состав панелей, память Redaction, масштаб, ⌘A, Crop в undo, поля отношения,
//  Image size, Snap с Command, Shift и Option при перетаскивании, Lock canvas.
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateToolParityTests: XCTestCase {
  // AnnotateState держим живым до конца процесса: деинициализация в scope теста
  // может уронить XCTest (см. AnnotateTextEditingTests).
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeState(defaults: UserDefaults = UserDefaultsFactory.make()) -> AnnotateState {
    let state = AnnotateState(defaults: defaults)
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeLoadedState(defaults: UserDefaults = UserDefaultsFactory.make()) throws -> AnnotateState {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: 400, height: 800))
    let state = makeState(defaults: defaults)
    state.loadImage(NSImage(cgImage: cgImage, size: NSSize(width: 400, height: 800)))
    return state
  }

  // MARK: - Text

  func testFontSizePresetsMatchReferenceMenu() {
    XCTAssertEqual(AnnotationProperties.fontSizePresets,
      [10, 13, 16, 20, 24, 30, 36, 48, 72, 96, 144, 216, 288])
    XCTAssertEqual(AnnotationProperties.clampedFontSize(4), 10)
    XCTAssertEqual(AnnotationProperties.clampedFontSize(500), 288)
    XCTAssertEqual(AnnotateFontSizeMenu.label(for: 30), "30 pt")
    XCTAssertEqual(AnnotateFontSizeMenu.selectedPreset(for: 144), 144)
    XCTAssertNil(AnnotateFontSizeMenu.selectedPreset(for: 31))
  }

  func testNewTextStartsAt30ptAndAcceptsLargePresets() {
    let state = makeState()
    state.selectedTool = .text
    XCTAssertEqual(state.quickTextFontSizeBinding.wrappedValue, 30)

    state.quickTextFontSizeBinding.wrappedValue = 216
    XCTAssertEqual(state.quickTextFontSizeBinding.wrappedValue, 216, "раньше кегль обрезался до 72")
    XCTAssertEqual(AnnotateTextLayout.font(size: 288).pointSize, 288)
  }

  func testInlineTextControlsShownForTextTool() {
    let state = makeState()
    state.selectedTool = .text
    XCTAssertTrue(AnnotateInlineToolControls.hasControls(for: state))
    XCTAssertFalse(state.quickPropertiesSupportsSpotlightShape)
  }

  // MARK: - Состав панелей

  func testPanelCompositionFollowsReference() {
    XCTAssertTrue(AnnotationToolType.filledRectangle.supportsQuickStrokeColor)
    XCTAssertFalse(AnnotationToolType.filledRectangle.supportsQuickStrokeWidth)
    XCTAssertFalse(AnnotationToolType.spotlight.supportsQuickStrokeColor)
    XCTAssertFalse(AnnotationToolType.spotlight.supportsQuickStrokeWidth)
    for tool in [AnnotationToolType.rectangle, .oval, .line, .pencil, .highlighter, .counter] {
      XCTAssertTrue(tool.supportsQuickStrokeColor, "\(tool)")
      XCTAssertTrue(tool.supportsQuickStrokeWidth, "\(tool)")
    }
  }

  // MARK: - Spotlight

  func testSpotlightShapeMatchesReferenceEnum() {
    XCTAssertEqual(SpotlightShape.allCases, [.rectangle, .roundedRectangle, .ellipse])
    XCTAssertEqual(SpotlightShape.defaultShape.rawValue, 1, "annotateLastHighlightShape = 1")
    XCTAssertEqual(AnnotationProperties().spotlightShape, .roundedRectangle)
  }

  func testSpotlightShapeIsRememberedForNextLaunch() {
    let defaults = UserDefaultsFactory.make()
    let state = makeState(defaults: defaults)
    state.selectedTool = .spotlight
    XCTAssertTrue(state.quickPropertiesSupportsSpotlightShape)
    state.setSpotlightShape(.ellipse)
    XCTAssertEqual(state.quickSpotlightShape, .ellipse)

    let relaunched = makeState(defaults: defaults)
    XCTAssertEqual(relaunched.annotationCreationProperties(for: .spotlight).spotlightShape, .ellipse)
  }

  func testSpotlightShapeChangeOnSelectionIsUndoable() {
    let state = makeState()
    let spotlight = AnnotationItem(type: .spotlight, bounds: CGRect(x: 10, y: 10, width: 100, height: 60),
      properties: AnnotationProperties())
    state.annotations = [spotlight]
    state.selectedTool = .selection
    state.setSelectedAnnotationIds([spotlight.id])

    state.setSpotlightShape(.rectangle)
    XCTAssertEqual(state.annotations.first?.properties.spotlightShape, .rectangle)
    XCTAssertTrue(state.canUndo)
    state.undo()
    XCTAssertEqual(state.annotations.first?.properties.spotlightShape, .roundedRectangle)
  }

  func testEllipseSpotlightOutlineSkipsCorners() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
    let ellipse = SpotlightCompositor.outlinePath(in: rect, cornerRadius: 14, shape: .ellipse)
    XCTAssertFalse(ellipse.contains(CGPoint(x: 2, y: 2)))
    XCTAssertTrue(ellipse.contains(CGPoint(x: 50, y: 30)))
    let square = SpotlightCompositor.outlinePath(in: rect, cornerRadius: 14, shape: .rectangle)
    XCTAssertTrue(square.contains(CGPoint(x: 0.5, y: 0.5)))
    XCTAssertEqual(SpotlightCompositor.effectiveCornerRadius(14, shape: .roundedRectangle), 14)
    XCTAssertEqual(SpotlightCompositor.effectiveCornerRadius(14, shape: .rectangle), 0)
  }

  func testPersistedSpotlightShapeRoundTripsAndLegacyFallsBack() throws {
    var properties = AnnotationProperties()
    properties.spotlightShape = .ellipse
    let persisted = PersistedAnnotationProperties(properties: properties)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(persisted)) as? [String: Any]
    )
    XCTAssertEqual(object["spotlightShape"] as? Int, 2)
    XCTAssertEqual(persisted.annotationProperties.spotlightShape, .ellipse)

    object.removeValue(forKey: "spotlightShape")
    let legacy = try JSONDecoder().decode(
      PersistedAnnotationProperties.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    XCTAssertNil(legacy.spotlightShape)
    XCTAssertEqual(legacy.annotationProperties.spotlightShape, .roundedRectangle)
  }

  // MARK: - Redaction

  func testRedactionStyleSurvivesRelaunch() {
    let defaults = UserDefaultsFactory.make()
    let state = makeState(defaults: defaults)
    XCTAssertEqual(state.activeBlurType, .pixelated)
    state.setActiveBlurType(.gaussian)

    let relaunched = makeState(defaults: defaults)
    XCTAssertEqual(relaunched.activeBlurType, .gaussian)
  }

  // MARK: - Масштаб и клавиши

  func testZoomShortcutsMatchReference() {
    XCTAssertEqual(AnnotateZoomShortcut.match(keyCode: 29, flags: .command), .actualSize)
    XCTAssertEqual(AnnotateZoomShortcut.match(keyCode: 18, flags: .command), .fitCanvas)
    XCTAssertEqual(AnnotateZoomShortcut.match(keyCode: 24, flags: .command), .zoomIn)
    XCTAssertEqual(AnnotateZoomShortcut.match(keyCode: 24, flags: [.command, .shift]), .zoomIn)
    XCTAssertEqual(AnnotateZoomShortcut.match(keyCode: 27, flags: .command), .zoomOut)
    XCTAssertEqual(AnnotateZoomShortcut.match(keyCode: 82, flags: [.command, .numericPad]), .actualSize)
    XCTAssertNil(AnnotateZoomShortcut.match(keyCode: 29, flags: [.command, .option]))
    XCTAssertNil(AnnotateZoomShortcut.match(keyCode: 18, flags: []))
    XCTAssertEqual(AnnotateZoomShortcut.fitCanvas.notificationName, .annotateZoomReset)
    XCTAssertEqual(AnnotateState.zoomMenuPercents, [50, 100, 200, 400])
  }

  func testZoomInOutStepsAndClamps() throws {
    let state = try makeLoadedState()
    // Ступени эталона в показанных процентах: при Fit 1.0 – 100 → 200, 200 → 100 → 50, предел 10%.
    state.zoomLevel = 1
    state.zoomIn()
    XCTAssertEqual(state.zoomLevel, 2, accuracy: 0.0001)
    state.zoomOut()
    state.zoomOut()
    XCTAssertEqual(state.zoomLevel, 0.5, accuracy: 0.0001)
    for _ in 0 ..< 20 { state.zoomOut() }
    XCTAssertEqual(state.zoomLevel, AnnotateState.minimumZoomLevel, accuracy: 0.0001)
  }

  func testSelectAllSelectsEveryAnnotationAndSwitchesToSelection() {
    let state = makeState()
    let items = (0 ..< 3).map { index in
      AnnotationItem(type: .rectangle, bounds: CGRect(x: index * 20, y: 0, width: 10, height: 10),
        properties: AnnotationProperties())
    }
    state.annotations = items
    state.selectedTool = .arrow
    XCTAssertTrue(state.selectAllAnnotations())
    XCTAssertEqual(state.selectedTool, .selection)
    XCTAssertEqual(state.selectedAnnotationIds, Set(items.map(\.id)))

    let empty = makeState()
    XCTAssertFalse(empty.selectAllAnnotations())
  }

  // MARK: - Crop

  func testAppliedCropIsUndoable() throws {
    let state = try makeLoadedState()
    state.beginCropInteraction()
    state.updateCropRect(CGRect(x: 0, y: 0, width: 200, height: 200))
    state.confirmCropInteraction()
    XCTAssertEqual(state.cropRect, CGRect(x: 0, y: 0, width: 200, height: 200))
    XCTAssertTrue(state.canUndo)

    state.undo()
    XCTAssertNil(state.cropRect, "⌘Z после Crop возвращает полную картинку")
  }

  func testCropWithoutChangesWritesNoUndo() throws {
    let state = try makeLoadedState()
    state.beginCropInteraction()
    state.confirmCropInteraction()
    XCTAssertFalse(state.canUndo)
  }

  func testRatioFieldsApplyRatioNotPixels() throws {
    let state = try makeLoadedState()
    state.beginCropInteraction()
    XCTAssertFalse(state.canRevertCropToOriginal)
    state.applyCropRatioFields(width: 7, height: 5)
    XCTAssertEqual(state.cropRatioTitle, "7 : 5")
    XCTAssertEqual(try XCTUnwrap(state.effectiveCropRatio), 1.4, accuracy: 0.0001)
    let rect = try XCTUnwrap(state.cropRect)
    XCTAssertEqual(rect.width / rect.height, 1.4, accuracy: 0.01)
    XCTAssertTrue(state.canRevertCropToOriginal)

    state.revertCropToOriginalBounds()
    XCTAssertEqual(state.cropRatioTitle, "Freeform")
    XCTAssertFalse(state.canRevertCropToOriginal)
  }

  func testRatioFieldValuesParseTitles() {
    XCTAssertEqual(CropRatioFieldValues.components(fromTitle: "7 : 5")?.width, 7)
    XCTAssertEqual(CropRatioFieldValues.components(fromTitle: "16:9")?.height, 9)
    XCTAssertNil(CropRatioFieldValues.components(fromTitle: "Freeform"))
    XCTAssertNil(CropRatioFieldValues.components(fromTitle: "1.5 : 1"))
    XCTAssertEqual(CropRatioFieldValues.title(width: 7, height: 5), "7 : 5")
  }

  func testIntegerInputRejectsFractionsAndZero() {
    XCTAssertEqual(AnnotateIntegerInput.positiveInteger(from: " 400 "), 400)
    XCTAssertNil(AnnotateIntegerInput.positiveInteger(from: "12.5"))
    XCTAssertNil(AnnotateIntegerInput.positiveInteger(from: "0"))
    XCTAssertNil(AnnotateIntegerInput.positiveInteger(from: "-3"))
    XCTAssertNil(AnnotateIntegerInput.positiveInteger(from: "abc"))
    let formatter = AnnotateIntegerInput.formatter()
    XCTAssertFalse(formatter.allowsFloats)
    XCTAssertEqual(formatter.maximumFractionDigits, 0)
  }

  func testImageSizeMemoryDefaultsAndLivesOnState() {
    let state = makeState()
    XCTAssertEqual(state.imageSizeMemory, AnnotateImageSizeMemory())
    state.imageSizeMemory.unit = .percent
    state.imageSizeMemory.flattenAnnotations = true
    XCTAssertEqual(state.imageSizeMemory.unit, .percent)
    XCTAssertTrue(state.imageSizeMemory.flattenAnnotations)
    XCTAssertTrue(state.imageSizeMemory.locksAspectRatio)
  }

  func testCommandInvertsSnapSetting() {
    XCTAssertTrue(CropEdgeSnapping.isActive(enabled: true, commandHeld: false))
    XCTAssertFalse(CropEdgeSnapping.isActive(enabled: true, commandHeld: true))
    XCTAssertTrue(CropEdgeSnapping.isActive(enabled: false, commandHeld: true))
    XCTAssertFalse(CropEdgeSnapping.isActive(enabled: false, commandHeld: false))
    XCTAssertEqual(CropEdgeSnapping.commandHint(enabled: false), "Hold Command ⌘ to enable snapping.")
  }

  // MARK: - Перетаскивание

  func testShiftLocksMoveToDominantAxis() {
    XCTAssertEqual(AnnotationDragConstraint.axisLockedDelta(dx: 30, dy: 8, shiftHeld: true), CGSize(width: 30, height: 0))
    XCTAssertEqual(AnnotationDragConstraint.axisLockedDelta(dx: -3, dy: -9, shiftHeld: true), CGSize(width: 0, height: -9))
    XCTAssertEqual(AnnotationDragConstraint.axisLockedDelta(dx: 5, dy: 6, shiftHeld: false), CGSize(width: 5, height: 6))
  }

  func testOptionDragDuplicateKeepsOriginalsAndSelectsCopies() {
    let state = makeState()
    let original = AnnotationItem(type: .rectangle, bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
      properties: AnnotationProperties())
    state.annotations = [original]

    XCTAssertTrue(state.duplicateAnnotations(ids: [original.id], offset: CGSize(width: 50, height: 0)))
    XCTAssertEqual(state.annotations.count, 2)
    XCTAssertEqual(state.annotations.first?.bounds, original.bounds)
    let copy = state.annotations[1]
    XCTAssertEqual(copy.bounds.origin, CGPoint(x: 60, y: 10))
    XCTAssertEqual(state.selectedAnnotationIds, [copy.id])
    state.undo()
    XCTAssertEqual(state.annotations.map(\.id), [original.id])

    XCTAssertFalse(state.duplicateAnnotations(ids: [original.id], offset: .zero))
  }

  // MARK: - Lock canvas

  func testCanvasLockControlsExpansion() {
    let defaults = UserDefaultsFactory.make()
    let state = makeState(defaults: defaults)
    XCTAssertTrue(AnnotateCanvasLock.isLocked(defaults))
    XCTAssertFalse(state.expandsCanvasBeyondImage)

    AnnotateCanvasLock.setLocked(false, defaults: defaults)
    XCTAssertTrue(state.expandsCanvasBeyondImage)
    XCTAssertEqual(AnnotateCanvasLock.helpText(isLocked: true), "Unlock canvas")

    state.selectedTool = .pencil
    XCTAssertTrue(state.quickPropertiesSupportsCanvasLock)
    state.selectedTool = .highlighter
    XCTAssertTrue(state.quickPropertiesSupportsCanvasLock)
    state.selectedTool = .rectangle
    XCTAssertFalse(state.quickPropertiesSupportsCanvasLock)
  }
}
