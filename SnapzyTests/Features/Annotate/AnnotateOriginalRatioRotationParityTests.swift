import AppKit
import Testing
@testable import Snapzy

@MainActor
struct AnnotateOriginalRatioRotationParityTests {
  private static var retainedStates: [AnnotateState] = []

  @Test("Original Ratio после поворота сохраняет пропорции загруженного исходника при 1× и 2×",
    arguments: [false, true], [1, 2])
  func originalRatioAfterRotation(portrait: Bool, density: Int) throws {
    let pixelWidth = portrait ? 450 : 800
    let pixelHeight = portrait ? 800 : 450
    let state = makeState()
    let image = try makeImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight, density: density)
    state.loadImage(image)
    let originalRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)

    state.rotateImage(clockwise: true)
    #expect(state.sourceImage?.size == CGSize(width: CGFloat(pixelHeight) / CGFloat(density),
      height: CGFloat(pixelWidth) / CGFloat(density)))
    #expect(state.sourceImage?.backingPixelSize == CGSize(width: pixelHeight, height: pixelWidth))
    state.beginCropInteraction()
    state.applyOriginalCropRatio()

    // ANN-233: b4-rotate-ratio.txt и b4-rotate-original-ratio-ref.png:
    // на повёрнутом портретном изображении Original Ratio остаётся альбомным.
    // Проверяем настоящее состояние и полученную рамку, без заданных размеров рамки.
    #expect(state.isCropActive)
    let ratio = try #require(state.effectiveCropRatio)
    let crop = try #require(state.cropRect)
    #expect(abs(ratio - originalRatio) < 0.0001)
    #expect(abs(crop.width / crop.height - originalRatio) < 0.0001)
    #expect(state.cropRatioFieldValues?.width == (portrait ? 9 : 16))
    #expect(state.cropRatioFieldValues?.height == (portrait ? 16 : 9))

    state.swapCropDimensions()
    #expect(state.cropRatioTitle == "Original Ratio")
    #expect(state.cropRatioFieldValues?.width == (portrait ? 16 : 9))
    #expect(state.cropRatioFieldValues?.height == (portrait ? 9 : 16))
    state.applyCropAspectRatio(.free)
    #expect(state.cropRatioFieldValues == nil)
    state.cancelCrop()
  }

  @Test("Загрузка другого исходника сбрасывает Original Ratio предыдущего документа")
  func replacingBaseImageResetsOriginalRatio() throws {
    let state = makeState()
    state.loadImage(try makeImage(pixelWidth: 800, pixelHeight: 450, density: 2))
    state.rotateImage(clockwise: true)
    state.beginCropInteraction()
    state.applyOriginalCropRatio()
    state.cancelCrop()

    // Реальный loadImage, а не прямая подмена sourceImage: новый документ должен
    // забыть исходные пропорции предыдущего, независимо от сделанных поворотов.
    state.loadImage(try makeImage(pixelWidth: 300, pixelHeight: 600, density: 1))
    state.beginCropInteraction()
    state.applyOriginalCropRatio()
    let beforeRotation = try #require(state.effectiveCropRatio)
    #expect(abs(beforeRotation - 0.5) < 0.0001)
    state.cancelCrop()

    state.rotateImage(clockwise: true)
    state.beginCropInteraction()
    state.applyOriginalCropRatio()
    let afterRotation = try #require(state.effectiveCropRatio)
    let crop = try #require(state.cropRect)
    #expect(abs(afterRotation - 0.5) < 0.0001)
    #expect(abs(crop.width / crop.height - 0.5) < 0.0001)
    state.cancelCrop()
  }

  @Test("Undo и Redo поворота сохраняют исходные пропорции при плотности 2×")
  func originalRatioSurvivesRotationUndoRedo() throws {
    let state = makeState()
    state.loadImage(try makeImage(pixelWidth: 800, pixelHeight: 450, density: 2))
    state.rotateImage(clockwise: true)
    for step in 0..<3 {
      let expected = step == 1 ? CGSize(width: 400, height: 225) : CGSize(width: 225, height: 400)
      #expect(state.sourceImage?.size == expected)
      state.beginCropInteraction()
      state.applyOriginalCropRatio()
      let ratio = try #require(state.effectiveCropRatio)
      let crop = try #require(state.cropRect)
      #expect(abs(ratio - 800.0 / 450) < 0.0001)
      #expect(abs(crop.width / crop.height - 800.0 / 450) < 0.0001)
      state.cancelCrop()
      if step == 0 { state.undo() }
      if step == 1 { state.redo() }
    }
  }

  private func makeState() -> AnnotateState {
    let state = AnnotateState(defaults: UserDefaultsFactory.make(),
      appliesDefaultCanvasPresetOnNewImages: false)
    // Общий AnnotateState удерживается до конца процесса, как в остальных тестах редактора.
    Self.retainedStates.append(state)
    return state
  }

  private func makeImage(pixelWidth: Int, pixelHeight: Int, density: Int) throws -> NSImage {
    let pixels = try #require(TestImageFactory.solidColor(width: pixelWidth, height: pixelHeight))
    return NSImage(cgImage: pixels, size: CGSize(width: CGFloat(pixelWidth) / CGFloat(density),
      height: CGFloat(pixelHeight) / CGFloat(density)))
  }
}
