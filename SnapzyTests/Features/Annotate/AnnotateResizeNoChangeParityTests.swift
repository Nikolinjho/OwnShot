import AppKit
import SwiftUI
import Testing
@testable import Snapzy

@MainActor
@Suite(.serialized)
struct AnnotateResizeNoChangeParityTests {
  private func makeState(scale: CGFloat = 1) throws -> AnnotateState {
    let cg = try #require(TestImageFactory.solidColor(width: 800, height: 500))
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    state.loadImage(NSImage(cgImage: cg, size: NSSize(width: 800 / scale, height: 500 / scale)))
    return state
  }

  @Test("Resize без изменений сохраняет Crop, исходник и состояние документа",
    arguments: [CGFloat(1), CGFloat(2)], [false, true])
  func unchangedResizePreservesDocument(scale: CGFloat, alreadyEdited: Bool) throws {
    let state = try makeState(scale: scale)
    if alreadyEdited {
      state.saveState()
      state.annotations.append(AnnotationItem(type: .rectangle,
        bounds: CGRect(x: 10, y: 10, width: 40, height: 30), properties: AnnotationProperties()))
    }
    state.beginCropInteraction()
    let image = try #require(state.sourceImage)
    let ids = state.annotations.map(\.id)
    let rect = state.cropRect
    let dirty = state.hasUnsavedChanges
    let canUndo = state.canUndo
    let canRedo = state.canRedo
    state.resizeImage(pixelWidth: 800, pixelHeight: 500, flattenAnnotations: false)
    #expect(state.isCropActive)
    #expect(state.selectedTool == .crop)
    #expect(state.sourceImage === image)
    #expect(state.cropRect == rect)
    #expect(state.annotations.map(\.id) == ids)
    #expect(state.hasUnsavedChanges == dirty)
    #expect(state.canUndo == canUndo)
    #expect(state.canRedo == canRedo)
    if alreadyEdited {
      state.undo()
      #expect(state.annotations.isEmpty, "Resize не добавляет лишнюю точку undo")
    }
  }

  @Test("Одинаковый размер с Flatten действительно запекает разметку")
  func unchangedDimensionsStillFlatten() throws {
    let state = try makeState()
    state.annotations = [AnnotationItem(type: .filledRectangle,
      bounds: CGRect(x: 10, y: 10, width: 40, height: 30), properties: AnnotationProperties())]
    state.beginCropInteraction()
    state.resizeImage(pixelWidth: 800, pixelHeight: 500, flattenAnnotations: true)
    #expect(state.annotations.isEmpty)
    #expect(state.canUndo == false)
    #expect(state.isCropActive == false)
    #expect(state.sourceImage?.backingPixelSize == CGSize(width: 800, height: 500))
  }

  @Test("Совпавший размер выбранной части применяет настоящую обрезку")
  func unchangedCropDimensionsStillApplyCrop() throws {
    let state = try makeState()
    state.beginCropInteraction()
    state.cropRect = CGRect(x: 100, y: 50, width: 400, height: 250)
    state.resizeImage(pixelWidth: 400, pixelHeight: 250, flattenAnnotations: false)
    #expect(state.sourceImage?.backingPixelSize == CGSize(width: 400, height: 250))
    #expect(state.isCropActive == false)
    state.undo()
    #expect(state.sourceImage?.backingPixelSize == CGSize(width: 800, height: 500))
  }
}
