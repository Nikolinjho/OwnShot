//
//  AnnotateBackgroundSelectionTests.swift
//  SnapzyTests
//
//  Выбор фона в сайдбаре Background: состав градиентов и палитры,
//  параметры холста при выборе градиента, Ratio, Inset/Auto-balance и откат через undo.
//

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateBackgroundSelectionTests: XCTestCase {
  // AnnotateState держим живым до конца процесса: деинициализация в XCTest может падать.
  private static var retainedAnnotateStates: [AnnotateState] = []
  private static var retainedCanvasPresetStores: [AnnotateCanvasPresetStore] = []
  private static var retainedUserDefaults: [UserDefaults] = []

  private func makeNoneState() -> AnnotateState {
    let defaults = UserDefaultsFactory.make()
    let store = AnnotateCanvasPresetStore(defaults: defaults)
    let state = AnnotateState(
      image: NSImage(size: NSSize(width: 40, height: 40)),
      url: URL(fileURLWithPath: "/tmp/snapzy-background-selection-tests.png"),
      defaults: defaults,
      canvasPresetStore: store
    )
    Self.retainedUserDefaults.append(defaults)
    Self.retainedCanvasPresetStores.append(store)
    Self.retainedAnnotateStates.append(state)
    state.resetCanvasEffectsToNone()
    return state
  }

  // MARK: - Состав

  func testGradientGridHasTwentyTiles() {
    XCTAssertEqual(GradientPreset.allCases.count, 20)
    XCTAssertEqual(Set(GradientPreset.allCases.map(\.rawValue)).count, 20)
    for preset in GradientPreset.allCases {
      XCTAssertTrue(preset.gradient.isValid, "\(preset.rawValue)")
    }
  }

  func testGradientRasterKeepsSourceAspectAndMeshNodes() throws {
    // Растр плитки повторяет пропорции исходника эталона, а в углу совпадает с угловым узлом сетки.
    for preset in GradientPreset.allCases {
      let description = preset.gradient
      let image = try XCTUnwrap(GradientPresetRasterizer.image(for: preset), preset.rawValue)
      XCTAssertEqual(max(image.width, image.height), GradientPresetRasterizer.longSide, preset.rawValue)
      XCTAssertEqual(Double(image.width) / Double(image.height), description.aspect, accuracy: 0.01, preset.rawValue)
      guard case .mesh(_, let nodes) = description.shape else { continue }
      let corner = description.color(u: 0, v: 0)
      let node = GradientDescription.rgb(nodes[0])
      XCTAssertEqual(corner.x, node.x, accuracy: 0.001, preset.rawValue)
      XCTAssertEqual(corner.y, node.y, accuracy: 0.001, preset.rawValue)
      XCTAssertEqual(corner.z, node.z, accuracy: 0.001, preset.rawValue)
    }
  }

  func testGradientRawValuesOfExistingPresetsStayStable() {
    // Сохранённые пресеты холста ссылаются на rawValue, первые 8 плиток переименовывать нельзя.
    XCTAssertEqual(
      Array(GradientPreset.allCases.prefix(8)).map(\.rawValue),
      ["pinkOrange", "bluePurple", "greenBlue", "orangeRed", "purplePink", "blueGreen", "yellowOrange", "cyanBlue"]
    )
  }

  func testPlainColorPaletteIsTwoRowsOfNine() {
    let cells = AnnotateBackgroundColorPalette.fixedCells
    let makeSwatch = AnnotateBackgroundColorPalette.FixedCell.swatch

    XCTAssertEqual(AnnotateBackgroundColorPalette.columnCount, 9)
    XCTAssertEqual(Array(cells.indices), Array(0 ..< 18))
    XCTAssertEqual(
      Array(cells.prefix(9)),
      AnnotateBackgroundPalette.primaryRow.map(makeSwatch) + [.transparent]
    )
    XCTAssertEqual(
      Array(cells.suffix(9)),
      AnnotateBackgroundPalette.secondaryRow.map(makeSwatch) + [.customPicker]
    )
    XCTAssertEqual(RGBAColor(color: AnnotateBackgroundPalette.transparent)?.alpha, 0)
  }

  func testTransparentBackgroundSurvivesCodableRoundTrip() throws {
    let style = BackgroundStyle.solidColor(AnnotateBackgroundPalette.transparent)
    let codable = try XCTUnwrap(CodableBackgroundStyle(from: style))
    XCTAssertEqual(codable.solidColorRGBA?.alpha, 0)
  }

  // MARK: - Параметры холста

  func testSelectingGradientFromNoneAppliesReferenceCanvasDefaults() {
    let state = makeNoneState()

    state.selectGradientBackground(.skyLilac)

    XCTAssertEqual(state.backgroundStyle, .gradient(.skyLilac))
    XCTAssertEqual(state.padding, 63)
    XCTAssertEqual(state.shadowIntensity, 0.28, accuracy: 0.0001)
    XCTAssertEqual(state.cornerRadius, 15)
    XCTAssertEqual(state.inset, 0)
  }

  func testSwitchingGradientKeepsTunedCanvasParameters() {
    let state = makeNoneState()
    state.selectGradientBackground(.pinkOrange)
    state.padding = 100
    state.cornerRadius = 30

    state.selectGradientBackground(.roseApricot)

    XCTAssertEqual(state.backgroundStyle, .gradient(.roseApricot))
    XCTAssertEqual(state.padding, 100)
    XCTAssertEqual(state.cornerRadius, 30)
  }

  // MARK: - Undo

  func testUndoAfterGradientRestoresNoneAndZeroFields() {
    let state = makeNoneState()

    state.selectGradientBackground(.pinkOrange)
    XCTAssertTrue(state.canUndo)

    state.undo()

    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertEqual(state.padding, 0)
    XCTAssertEqual(state.shadowIntensity, 0)
    XCTAssertEqual(state.cornerRadius, 0)
    XCTAssertEqual(state.inset, 0)
    XCTAssertTrue(state.isNoneCanvasEffectsActive)
    XCTAssertTrue(state.canRedo)
  }

  func testRedoReappliesGradientWithCanvasDefaults() {
    let state = makeNoneState()
    state.selectGradientBackground(.nightViolet)
    state.undo()

    state.redo()

    XCTAssertEqual(state.backgroundStyle, .gradient(.nightViolet))
    XCTAssertEqual(state.padding, 63)
    XCTAssertEqual(state.shadowIntensity, 0.28, accuracy: 0.0001)
    XCTAssertEqual(state.cornerRadius, 15)
  }

  func testUndoAfterSolidColorRestoresPreviousGradient() {
    let state = makeNoneState()
    state.selectGradientBackground(.blueApricot)
    let color = AnnotateBackgroundPalette.secondaryRow[2]

    state.selectSolidColorBackground(color)
    state.undo()

    XCTAssertEqual(state.backgroundStyle, .gradient(.blueApricot))
  }

  func testNoneButtonIsUndoable() {
    let state = makeNoneState()
    state.selectGradientBackground(.magentaWine)

    state.selectNoneCanvasEffects()
    XCTAssertTrue(state.isNoneCanvasEffectsActive)
    state.undo()

    XCTAssertEqual(state.backgroundStyle, .gradient(.magentaWine))
    XCTAssertEqual(state.padding, 63)
  }

  func testReselectingSameGradientDoesNotAddUndoStep() {
    let state = makeNoneState()
    state.selectGradientBackground(.lavenderMist)

    state.selectGradientBackground(.lavenderMist)
    state.undo()

    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.canUndo)
  }
  // MARK: - Секции панели

  func testGradientShowLessKeepsTenTilesAndShowMoreTwenty() {
    XCTAssertEqual(AnnotateSidebarView.visibleGradients(isExpanded: false).count, 10)
    XCTAssertEqual(AnnotateSidebarView.visibleGradients(isExpanded: true).count, 20)
    XCTAssertEqual(
      AnnotateSidebarView.visibleGradients(isExpanded: false),
      Array(GradientPreset.allCases.prefix(10))
    )
  }

  func testBlurredSectionHasThreeTiles() {
    XCTAssertEqual(BlurredBackgroundEffect.sidebarEffects.count, 3)
    XCTAssertEqual(Set(BlurredBackgroundEffect.sidebarEffects).count, 3)
  }

  func testInsetRangeMatchesReference() {
    XCTAssertEqual(AnnotateBackgroundInset.range, 0 ... 100)
    XCTAssertEqual(AnnotateBackgroundInset.clampedInset(140), 100)
    XCTAssertEqual(AnnotateBackgroundInset.clampedInset(-5), 0)
  }

  // MARK: - Ratio

  func testRatioPopupItemsMatchReferenceOrder() {
    XCTAssertEqual(
      AnnotateBackgroundRatioChoice.landscapeChoices.map(\.title),
      ["Auto", "1 : 1", "5 : 4", "4 : 3", "3 : 2", "16 : 9"]
    )
    XCTAssertEqual(
      AnnotateBackgroundRatioChoice.portraitChoices.map(\.title),
      ["4 : 5", "3 : 4", "9 : 16"]
    )
    XCTAssertEqual(
      AnnotateBackgroundRatioChoice.landscapeChoices.count + AnnotateBackgroundRatioChoice.portraitChoices.count,
      AnnotateBackgroundRatioChoice.allCases.count
    )
  }

  func testRatioChoiceRoundTripsThroughOptionAndOrientation() {
    for choice in AnnotateBackgroundRatioChoice.allCases {
      XCTAssertEqual(
        AnnotateBackgroundRatioChoice(option: choice.option, orientation: choice.orientation),
        choice
      )
    }
    XCTAssertNil(AnnotateBackgroundRatioChoice(option: .free, orientation: .horizontal))
    XCTAssertNil(AnnotateBackgroundRatioChoice(option: .ratio3x2, orientation: .vertical))
  }

  func testFiveByFourRatioTargetsBothOrientations() throws {
    let size = CGSize(width: 100, height: 100)
    XCTAssertEqual(try XCTUnwrap(AspectRatioOption.ratio5x4.targetRatio(for: size)), 1.25, accuracy: 0.0001)
    XCTAssertEqual(
      try XCTUnwrap(AspectRatioOption.ratio5x4.targetRatio(for: size, orientation: .vertical)),
      0.8,
      accuracy: 0.0001
    )
  }

  func testSelectingRatioIsUndoable() {
    let state = makeNoneState()

    state.selectBackgroundRatio(.ratio9x16)
    XCTAssertEqual(state.aspectRatio, .ratio16x9)
    XCTAssertEqual(state.aspectRatioOrientation, .vertical)

    state.undo()

    XCTAssertEqual(state.aspectRatio, .auto)
    XCTAssertEqual(state.aspectRatioOrientation, .horizontal)
  }

  // MARK: - Inset и Auto-balance

  func testAutoBalanceIsOffByDefault() {
    XCTAssertFalse(AnnotationCanvasEffects().autoBalance)
    XCTAssertEqual(AnnotationCanvasEffects().inset, 0)
  }

  func testInsetWithoutAutoBalanceIsUniform() {
    let margins = AnnotateInsetEdges(top: 0, left: 12, bottom: 0, right: 0)
    let edges = AnnotateBackgroundInset.edges(inset: 20, autoBalance: false, margins: margins)
    XCTAssertEqual(edges, .uniform(20))
  }

  func testAutoBalancePadsEdgesWhereContentTouchesBorder() {
    let margins = AnnotateInsetEdges(top: 0, left: 12, bottom: 4, right: 0)
    let edges = AnnotateBackgroundInset.edges(inset: 10, autoBalance: true, margins: margins)
    // Итоговое поле с каждой стороны: собственное поле + отступ = 12 + 10.
    XCTAssertEqual(edges, AnnotateInsetEdges(top: 22, left: 10, bottom: 18, right: 22))
  }

  func testEdgeAnalysisFindsBorderColorAndOwnMargins() throws {
    // 100 × 50 белое поле слева шириной 20 px, остальное – красный контент до края.
    let image = try makeImage(width: 100, height: 50) { context in
      context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
      context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 20, y: 0, width: 80, height: 50))
    }

    let analysis = AnnotateBackgroundInset.analyze(
      image: image,
      visibleBounds: CGRect(x: 0, y: 0, width: 100, height: 50)
    )

    let edgeColor = try XCTUnwrap(analysis.edgeColor)
    XCTAssertEqual(edgeColor.red, 1, accuracy: 0.02)
    XCTAssertEqual(edgeColor.green, 0, accuracy: 0.02)
    XCTAssertEqual(analysis.margins.left, 0)
    XCTAssertEqual(analysis.margins.top, 0)

    // Белое поле слева – это собственное поле, только если цвет каймы белый.
    let whiteFrame = try makeImage(width: 100, height: 50) { context in
      context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
      context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 20, y: 0, width: 80, height: 40))
    }
    let framed = AnnotateBackgroundInset.analyze(
      image: whiteFrame,
      visibleBounds: CGRect(x: 0, y: 0, width: 100, height: 50)
    )
    XCTAssertEqual(framed.margins.left, 20, accuracy: 0.5)
    XCTAssertEqual(framed.margins.top, 10, accuracy: 0.5)
    XCTAssertEqual(framed.margins.right, 0)
    XCTAssertEqual(framed.margins.bottom, 0)
  }

  func testRenderCanvasEffectsGrowsCanvasByInset() throws {
    let image = try makeImage(width: 40, height: 30) { context in
      context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
    var effects = AnnotationCanvasEffects(
      backgroundStyle: .solidColor(.white),
      padding: 10,
      shadowIntensity: 0,
      cornerRadius: 0,
      aspectRatio: .free
    )
    effects.inset = 15

    let rendered = try XCTUnwrap(AnnotateExporter.renderCanvasEffects(sourceImage: image, effects: effects))

    XCTAssertEqual(rendered.size.width, 40 + 10 * 2 + 15 * 2)
    XCTAssertEqual(rendered.size.height, 30 + 10 * 2 + 15 * 2)
  }

  func testInsetIsInactiveWithoutBackground() {
    let state = makeNoneState()
    state.inset = 40

    XCTAssertEqual(state.backgroundInsetLayout(for: state.sourceImageBounds), .none)
  }

  func testAutoBalanceToggleIsUndoableAndAppliesBackground() {
    let state = makeNoneState()

    state.setBackgroundAutoBalance(true)
    XCTAssertTrue(state.autoBalance)
    XCTAssertNotEqual(state.backgroundStyle, .none)

    state.undo()

    XCTAssertFalse(state.autoBalance)
    XCTAssertEqual(state.backgroundStyle, .none)
  }

  func testUndoRestoresInsetFromCanvasSnapshot() {
    let state = makeNoneState()
    state.selectGradientBackground(.pinkOrange)
    state.inset = 30
    state.autoBalance = true

    state.selectNoneCanvasEffects()
    XCTAssertEqual(state.inset, 0)
    XCTAssertFalse(state.autoBalance)
    state.undo()

    XCTAssertEqual(state.inset, 30)
    XCTAssertTrue(state.autoBalance)
  }

  // MARK: - Пресеты и проект

  func testPresetPayloadKeepsInsetAndAutoBalance() throws {
    let payload = AnnotateCanvasPresetPayload(
      backgroundStyle: try XCTUnwrap(CodableBackgroundStyle(from: .gradient(.pinkOrange))),
      padding: 63,
      shadowIntensity: 0.28,
      cornerRadius: 15,
      inset: 24,
      autoBalance: true
    )

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(AnnotateCanvasPresetPayload.self, from: data)

    XCTAssertEqual(decoded.inset, 24)
    XCTAssertTrue(decoded.autoBalance)
    XCTAssertTrue(decoded.approximatelyEquals(payload))
    var changed = payload
    changed.autoBalance = false
    XCTAssertFalse(changed.approximatelyEquals(payload))
  }

  func testLegacyPresetPayloadWithoutInsetDecodesDefaults() throws {
    let json = """
    {"backgroundStyle":{"kind":"none"},"padding":0,"shadowIntensity":0,"cornerRadius":0}
    """
    let decoded = try JSONDecoder().decode(AnnotateCanvasPresetPayload.self, from: Data(json.utf8))

    XCTAssertEqual(decoded.inset, 0)
    XCTAssertFalse(decoded.autoBalance)
  }

  func testApplyingPresetRestoresInsetAndAutoBalance() throws {
    let state = makeNoneState()
    let preset = AnnotateCanvasPreset(
      name: "Inset",
      payload: AnnotateCanvasPresetPayload(
        backgroundStyle: try XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
        padding: 40,
        shadowIntensity: 0.2,
        cornerRadius: 10,
        inset: 18,
        autoBalance: true
      )
    )

    state.applyCanvasPreset(preset)

    XCTAssertEqual(state.inset, 18)
    XCTAssertTrue(state.autoBalance)
  }

  func testPersistedCanvasEffectsWithoutInsetKeysDecode() throws {
    var effects = AnnotationCanvasEffects()
    effects.backgroundStyle = .gradient(.greenBlue)
    effects.padding = 50
    effects.inset = 12
    effects.autoBalance = true
    let data = try JSONEncoder().encode(PersistedCanvasEffects(effects: effects))

    let roundTrip = try JSONDecoder().decode(PersistedCanvasEffects.self, from: data)
    XCTAssertEqual(roundTrip.inset, 12)
    XCTAssertTrue(roundTrip.autoBalance)

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "inset")
    object.removeValue(forKey: "autoBalanceEnabled")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let legacy = try JSONDecoder().decode(PersistedCanvasEffects.self, from: legacyData)

    XCTAssertEqual(legacy.inset, 0)
    XCTAssertFalse(legacy.autoBalance)
    XCTAssertEqual(legacy.padding, 50)
  }

  // MARK: - Хелперы

  private func makeImage(
    width: Int,
    height: Int,
    draw: (CGContext) -> Void
  ) throws -> NSImage {
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    draw(context)
    let cgImage = try XCTUnwrap(context.makeImage())
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }
}
