//
//  AnnotateTextStyleTests.swift
//  SnapzyTests
//
//  Семь стилей текста эталона (Standard, Rounded, Outlined, Mono, Box, Mono Box,
//  Rounded Box): порядок и индексы, применение к выбранному тексту, память
//  инструмента, сериализация и отрисовка.
//

import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateTextStyleTests: XCTestCase {
  // AnnotateState держим живым до конца процесса: деинициализация в scope теста
  // может уронить XCTest (см. AnnotateTextEditingTests).
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeAnnotateState(defaults: UserDefaults = UserDefaultsFactory.make()) -> AnnotateState {
    let state = AnnotateState(defaults: defaults)
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeSelectedText(in state: AnnotateState, properties: AnnotationProperties = AnnotationProperties(fontSize: 30)) -> AnnotationItem {
    let annotation = AnnotationItem(
      type: .text("OwnShot 043"),
      bounds: CGRect(x: 40, y: 80, width: 240, height: 40),
      properties: properties
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id
    state.selectedTool = .text
    return annotation
  }

  // MARK: - Модель

  func testStylesFollowReferenceMenuOrderAndIndices() {
    XCTAssertEqual(
      AnnotationTextStyle.allCases.map(\.title),
      ["Standard", "Rounded", "Outlined", "Mono", "Box", "Mono Box", "Rounded Box"]
    )
    XCTAssertEqual(AnnotationTextStyle.allCases.map(\.rawValue), Array(0 ... 6))
    // В сохранённом Project эталона textStyle 6 соответствует Rounded Box.
    XCTAssertEqual(AnnotationTextStyle(rawValue: 6), .roundedBox)
    XCTAssertEqual(AnnotationProperties().textStyle, .standard)
  }

  func testStyleTraits() {
    XCTAssertEqual(AnnotationTextStyle.rounded.fontDesign, .rounded)
    XCTAssertEqual(AnnotationTextStyle.mono.fontDesign, .monospaced)
    XCTAssertEqual(AnnotationTextStyle.monoBox.fontDesign, .monospaced)
    XCTAssertEqual(AnnotationTextStyle.roundedBox.fontDesign, .standard)
    XCTAssertTrue(AnnotationTextStyle.outlined.isOutlined)
    XCTAssertNil(AnnotationTextStyle.mono.backdrop)
    XCTAssertEqual(AnnotationTextStyle.box.backdrop, .box)
    XCTAssertEqual(AnnotationTextStyle.monoBox.backdrop, .monoBox)
    XCTAssertEqual(AnnotationTextStyle.roundedBox.backdrop, .roundedBox)
    XCTAssertEqual(AnnotationTextStyle.monoBox.withoutBackdrop, .mono)
    XCTAssertEqual(AnnotationTextStyle.roundedBox.withoutBackdrop, .standard)
  }

  func testMonoStyleUsesFixedPitchFont() {
    let standard = AnnotateTextLayout.font(size: 30, fontName: "SF Pro")
    let mono = AnnotateTextLayout.font(size: 30, fontName: "SF Pro", textStyle: .mono)
    XCTAssertFalse(standard.isFixedPitch)
    XCTAssertTrue(mono.isFixedPitch)
    XCTAssertEqual(mono.pointSize, 30)
  }

  // MARK: - Состояние

  func testSetTextStyleAppliesToSelectedTextWithSingleUndoStep() throws {
    let state = makeAnnotateState()
    _ = makeSelectedText(in: state)

    state.setTextStyle(.roundedBox)

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.textStyle, .roundedBox)
    XCTAssertEqual(state.quickTextStyle, .roundedBox)
    XCTAssertTrue(state.hasUnsavedChanges)

    state.undo()
    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.textStyle, .standard)
  }

  func testMonoStyleRecomputesWrappedTextHeight() throws {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .text("OwnShot 043 wraps"),
      bounds: CGRect(x: 40, y: 80, width: 200, height: 40),
      properties: AnnotationProperties(fontSize: 30)
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id
    state.selectedTool = .text

    state.setTextStyle(.mono)

    let updated = try XCTUnwrap(state.annotations.first)
    // Моноширинный текст шире и в той же ширине переносится на больше строк.
    XCTAssertGreaterThan(updated.bounds.height, 40)
    XCTAssertEqual(updated.bounds.maxY, annotation.bounds.maxY, accuracy: 0.5)
  }

  func testBackdropStyleAndLabelPresentationDoNotStack() throws {
    let state = makeAnnotateState()
    _ = makeSelectedText(in: state, properties: AnnotationProperties(fontSize: 30, textPresentation: .label))

    state.setTextStyle(.monoBox)
    var updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.properties.textStyle, .monoBox)
    XCTAssertEqual(updated.properties.textPresentation, .plain)

    state.setTextPresentation(.label)
    updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.properties.textPresentation, .label)
    XCTAssertEqual(updated.properties.textStyle, .mono)
  }

  func testToolTextStylePersistsAcrossStateReload() {
    let defaults = UserDefaultsFactory.make()
    let firstState = makeAnnotateState(defaults: defaults)
    firstState.selectedTool = .text

    firstState.setTextStyle(.outlined)
    XCTAssertEqual(firstState.quickTextStyle, .outlined)

    let reloadedState = makeAnnotateState(defaults: defaults)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .text).textStyle, .outlined)
  }

  // MARK: - Сериализация

  func testPersistedPropertiesRoundTripTextStyleAndDecodeLegacyAsStandard() throws {
    let persisted = PersistedAnnotationProperties(properties: AnnotationProperties(fontSize: 30, textStyle: .roundedBox))
    let encoded = try JSONEncoder().encode(persisted)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(json["textStyle"] as? Int, 6)

    let decoded = try JSONDecoder().decode(PersistedAnnotationProperties.self, from: encoded)
    XCTAssertEqual(decoded.annotationProperties.textStyle, .roundedBox)

    var legacy = json
    legacy.removeValue(forKey: "textStyle")
    let legacyDecoded = try JSONDecoder().decode(
      PersistedAnnotationProperties.self,
      from: JSONSerialization.data(withJSONObject: legacy)
    )
    XCTAssertEqual(legacyDecoded.annotationProperties.textStyle, .standard)
  }

  // MARK: - Отрисовка

  private struct Pixel {
    let r: UInt8
    let g: UInt8
    let b: UInt8
  }

  /// Рисует один текст на чёрном холсте 320×120 и возвращает доступ к пикселям
  /// в координатах холста (y вверх).
  private func render(style: AnnotationTextStyle, bounds: CGRect) throws -> (Int, Int) -> Pixel {
    let width = 320
    let height = 120
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.setFillColor(NSColor.black.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))

      let annotation = AnnotationItem(
        type: .text("Hi"),
        bounds: bounds,
        properties: AnnotationProperties(strokeColor: .green, fontSize: 30, textStyle: style)
      )
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      AnnotationRenderer(context: context, drawsObjectShadow: false).draw(annotation)
      NSGraphicsContext.restoreGraphicsState()
    }
    return { x, y in
      let index = ((height - 1 - y) * width + x) * 4
      return Pixel(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2])
    }
  }

  private func isLight(_ pixel: Pixel) -> Bool {
    pixel.r > 220 && pixel.g > 220 && pixel.b > 220
  }

  func testBoxStylesDrawLightBackdropBesideGlyphs() throws {
    let bounds = CGRect(x: 60, y: 40, width: 200, height: 40)
    let font = AnnotateTextLayout.font(size: 30, fontName: "SF Pro")
    let textRect = AnnotateTextLayout.textRect(for: "Hi", font: font, in: bounds)
    // Точка в поле подложки: левее первого glyph на 4 pt, на середине строки.
    let probeX = Int(textRect.minX) - 4
    let probeY = Int(textRect.midY)

    let standard = try render(style: .standard, bounds: bounds)
    XCTAssertFalse(isLight(standard(probeX, probeY)))

    for style in [AnnotationTextStyle.box, .monoBox, .roundedBox] {
      let pixels = try render(style: style, bounds: bounds)
      XCTAssertTrue(isLight(pixels(probeX, probeY)), "\(style.title): нет подложки")
    }

    // Mono Box – чисто белая подложка, Box – белая с оттенком цвета текста.
    let monoBox = try render(style: .monoBox, bounds: bounds)(probeX, probeY)
    XCTAssertEqual(monoBox.r, 255)
    XCTAssertEqual(monoBox.b, 255)
    let box = try render(style: .box, bounds: bounds)(probeX, probeY)
    XCTAssertLessThan(box.r, 255)
  }

  func testOutlinedStyleDrawsWhiteOutline() throws {
    let bounds = CGRect(x: 60, y: 40, width: 200, height: 40)
    let count: (AnnotationTextStyle) throws -> Int = { style in
      let pixels = try self.render(style: style, bounds: bounds)
      var light = 0
      for x in 60 ..< 260 {
        for y in 40 ..< 80 where self.isLight(pixels(x, y)) {
          light += 1
        }
      }
      return light
    }

    XCTAssertEqual(try count(.standard), 0)
    XCTAssertGreaterThan(try count(.outlined), 50)
  }
}
