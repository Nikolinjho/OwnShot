//
//  AnnotateUndoRedoTests.swift
//  SnapzyTests
//
//  Characterization tests for AnnotateState undo/redo checkpoint semantics:
//  saveState pushes a snapshot, undo restores the prior snapshot, redo reapplies
//  it, and a new mutating checkpoint after undo invalidates the redo stack.
//  Text-specific undo/redo is already covered in AnnotateCoreTests; these lock
//  down the generic stack contract via canUndo/canRedo + annotation snapshots.
//

import AppKit
import CoreGraphics
import SwiftUI
import AppKit
import XCTest
@testable import Snapzy

final class AnnotateUndoRedoTests: XCTestCase {
  @MainActor private static var retainedAnnotateStates: [AnnotateState] = []

  @MainActor
  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  @MainActor
  private func makeRectangle() -> AnnotationItem {
    AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
      properties: AnnotationProperties()
    )
  }

  @MainActor
  func testSaveStateEnablesUndoAndMarksUnsavedChanges() {
    let state = makeAnnotateState()
    XCTAssertFalse(state.canUndo)
    XCTAssertFalse(state.canRedo)

    state.saveState()

    XCTAssertTrue(state.canUndo)
    XCTAssertFalse(state.canRedo)
    XCTAssertTrue(state.hasUnsavedChanges)
  }

  @MainActor
  func testUndoRestoresPriorAnnotationSnapshotAndEnablesRedo() {
    let state = makeAnnotateState()

    state.saveState()
    state.annotations = [makeRectangle()]

    XCTAssertEqual(state.annotations.count, 1)

    state.undo()

    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertFalse(state.canUndo)
    XCTAssertTrue(state.canRedo)
  }

  @MainActor
  func testRedoReappliesUndoneAnnotationSnapshot() {
    let state = makeAnnotateState()

    state.saveState()
    let rectangle = makeRectangle()
    state.annotations = [rectangle]

    state.undo()
    XCTAssertTrue(state.annotations.isEmpty)

    state.redo()

    XCTAssertEqual(state.annotations.count, 1)
    XCTAssertEqual(state.annotations.first?.id, rectangle.id)
    XCTAssertTrue(state.canUndo)
    XCTAssertFalse(state.canRedo)
  }

  @MainActor
  func testUndoИRedoПослеИзмененияОбластиОставляютАннотацииНаМесте() throws {
    let state = makeAnnotateState()
    let firstImage = try XCTUnwrap(TestImageFactory.solidColor(width: 200, height: 160))
    state.loadImage(NSImage(cgImage: firstImage, size: NSSize(width: 200, height: 160)))
    let rectangle = makeRectangle()
    let line = AnnotationItem(
      type: .line(start: CGPoint(x: 80, y: 70), end: CGPoint(x: 110, y: 90)),
      bounds: CGRect(x: 80, y: 70, width: 30, height: 20),
      properties: AnnotationProperties()
    )
    state.saveState()
    state.annotations.append(rectangle)
    state.saveState()
    state.annotations.append(line)

    let sizeAfterFirstResize = NSSize(width: 220, height: 140)
    state.replaceSourceImagePreservingAnnotations(NSImage(size: sizeAfterFirstResize),
      annotationOffset: CGPoint(x: 14, y: -6))
    XCTAssertEqual(state.annotations.map(\.bounds),
      [rectangle.bounds, line.bounds].map { $0.offsetBy(dx: 14, dy: -6) })
    state.undo()
    XCTAssertEqual(state.annotations.map(\.id), [rectangle.id])
    XCTAssertEqual(state.annotations.first?.bounds, rectangle.bounds.offsetBy(dx: 14, dy: -6))
    XCTAssertEqual(state.sourceImage?.size, sizeAfterFirstResize)

    let sizeAfterSecondResize = NSSize(width: 215, height: 170)
    state.replaceSourceImagePreservingAnnotations(NSImage(size: sizeAfterSecondResize),
      annotationOffset: CGPoint(x: -4, y: 16))
    state.redo()
    XCTAssertEqual(state.annotations.map(\.id), [rectangle.id, line.id])
    XCTAssertEqual(state.annotations.map(\.bounds),
      [rectangle.bounds, line.bounds].map { $0.offsetBy(dx: 10, dy: 10) })
    XCTAssertEqual(state.sourceImage?.size, sizeAfterSecondResize)
    guard case .line(let start, let end) = state.annotations.last?.type else {
      return XCTFail("Redo должен восстановить линию")
    }
    XCTAssertEqual(start, CGPoint(x: 90, y: 80))
    XCTAssertEqual(end, CGPoint(x: 120, y: 100))
  }

  @MainActor
  func testUndoWithoutCheckpointIsNoOp() {
    let state = makeAnnotateState()
    state.annotations = [makeRectangle()]

    state.undo()

    XCTAssertEqual(state.annotations.count, 1)
    XCTAssertFalse(state.canUndo)
    XCTAssertFalse(state.canRedo)
  }

  @MainActor
  func testNewCheckpointAfterUndoInvalidatesRedoStack() {
    let state = makeAnnotateState()

    state.saveState()
    state.annotations = [makeRectangle()]

    state.undo()
    XCTAssertTrue(state.canRedo)

    // A fresh checkpoint (new mutating action) must clear the redo stack.
    state.saveState()

    XCTAssertFalse(state.canRedo)
    XCTAssertTrue(state.canUndo)
  }

  @MainActor
  func testSequentialCheckpointsUndoInReverseOrder() throws {
    let state = makeAnnotateState()
    let first = makeRectangle()
    let second = AnnotationItem(
      type: .oval,
      bounds: CGRect(x: 60, y: 60, width: 30, height: 30),
      properties: AnnotationProperties()
    )

    state.saveState()
    state.annotations = [first]
    state.saveState()
    state.annotations = [first, second]

    state.undo()
    XCTAssertEqual(state.annotations.map(\.id), [first.id])

    state.undo()
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testDuplicateSelectionIsAtomicAndUndoRedoRestoresSelection() {
    let state = makeAnnotateState()
    let first = makeRectangle()
    let second = AnnotationItem(
      type: .oval,
      bounds: CGRect(x: 80, y: 80, width: 30, height: 30),
      properties: AnnotationProperties()
    )
    state.annotations = [first, second]
    state.setSelectedAnnotationIds([first.id, second.id])

    XCTAssertTrue(state.duplicateSelectedAnnotations())
    let duplicatedIds = Set(state.annotations.suffix(2).map(\.id))
    XCTAssertEqual(state.annotations.count, 4)
    XCTAssertEqual(state.selectedAnnotationIds, duplicatedIds)

    state.undo()
    XCTAssertEqual(state.annotations.map(\.id), [first.id, second.id])
    XCTAssertEqual(state.selectedAnnotationIds, [first.id, second.id])
    XCTAssertFalse(state.canUndo)
    XCTAssertTrue(state.canRedo)

    state.redo()
    XCTAssertEqual(state.annotations.count, 4)
    XCTAssertEqual(state.selectedAnnotationIds, duplicatedIds)
    XCTAssertTrue(state.canUndo)
    XCTAssertFalse(state.canRedo)
  }

  // MARK: - Слайдеры: один жест – одна запись undo

  @MainActor private static var retainedCanvasPresetStores: [AnnotateCanvasPresetStore] = []
  @MainActor private static var retainedUserDefaults: [UserDefaults] = []

  /// Состояние с пустым фоном и изолированными настройками, без пресета по умолчанию.
  @MainActor
  private func makeNoneBackgroundState() -> AnnotateState {
    let defaults = UserDefaultsFactory.make()
    let store = AnnotateCanvasPresetStore(defaults: defaults)
    let state = AnnotateState(
      image: NSImage(size: NSSize(width: 40, height: 40)),
      url: URL(fileURLWithPath: "/tmp/snapzy-undo-slider-tests.png"),
      defaults: defaults,
      canvasPresetStore: store
    )
    Self.retainedUserDefaults.append(defaults)
    Self.retainedCanvasPresetStores.append(store)
    Self.retainedAnnotateStates.append(state)
    state.resetCanvasEffectsToNone()
    return state
  }

  @MainActor
  func testBackgroundSlidersRecordOneUndoPerCommittedValue() {
    let state = makeNoneBackgroundState()
    XCTAssertFalse(state.canUndo)

    // Слайдер сайдбара отдаёт значение один раз в конце жеста
    state.setBackgroundPadding(40)
    state.setBackgroundInset(12)
    state.setBackgroundShadowIntensity(0.45)
    state.setBackgroundCornerRadius(18)

    XCTAssertEqual(state.padding, 40)
    XCTAssertEqual(state.backgroundStyle, .solidColor(.white))

    state.undo()
    XCTAssertEqual(state.cornerRadius, 0)
    XCTAssertEqual(state.shadowIntensity, 0.45)
    state.undo()
    XCTAssertEqual(state.shadowIntensity, 0)
    XCTAssertEqual(state.inset, 12)
    state.undo()
    XCTAssertEqual(state.inset, 0)
    XCTAssertEqual(state.padding, 40)
    state.undo()
    // Padding и автоматический белый фон откатываются одной записью
    XCTAssertEqual(state.padding, 0)
    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testBackgroundSliderRepeatedSameValueRecordsNoExtraUndo() {
    let state = makeNoneBackgroundState()

    // Ввод числа в поле: Submit и потеря фокуса дают одно и то же значение
    state.setBackgroundPadding(24)
    state.setBackgroundPadding(24)

    state.undo()
    XCTAssertEqual(state.padding, 0)
    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testCanvasEffectsGestureRecordsSingleUndoCheckpoint() {
    let state = makeNoneBackgroundState()

    // Перетаскивание в панели своего цвета Plain color
    state.setCanvasEffectsGestureEditing(true)
    state.selectSolidColorBackground(.red)
    state.selectSolidColorBackground(.green)
    state.selectSolidColorBackground(.blue)
    state.setCanvasEffectsGestureEditing(false)

    XCTAssertEqual(state.backgroundStyle, .solidColor(.blue))

    state.undo()
    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.canUndo)

    // После жеста каждое действие снова пишет свою точку
    state.selectSolidColorBackground(.red)
    state.selectSolidColorBackground(.green)
    state.undo()
    XCTAssertEqual(state.backgroundStyle, .solidColor(.red))
  }

  @MainActor
  func testQuickSpotlightOpacitySliderGestureRecordsSingleUndo() throws {
    let state = makeAnnotateState()
    let spotlight = AnnotationItem(
      type: .spotlight,
      bounds: CGRect(x: 10, y: 10, width: 80, height: 60),
      properties: AnnotationProperties(spotlightOpacity: 0.5)
    )
    state.annotations = [spotlight]
    state.setSelectedAnnotationIds([spotlight.id])

    state.setQuickPropertiesControlEditing(true)
    state.quickSpotlightOpacityBinding.wrappedValue = 0.6
    state.quickSpotlightOpacityBinding.wrappedValue = 0.7
    state.quickSpotlightOpacityBinding.wrappedValue = 0.8
    state.setQuickPropertiesControlEditing(false)

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.spotlightOpacity, 0.8, accuracy: 0.0001)

    state.undo()

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.spotlightOpacity, 0.5, accuracy: 0.0001)
    XCTAssertFalse(state.canUndo)
  }
}
