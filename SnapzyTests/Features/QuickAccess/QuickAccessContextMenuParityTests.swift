//
//  QuickAccessContextMenuParityTests.swift
//  SnapzyTests
//
//  Меню карточки и pin, Resize Image, преобразования файла и Restore из History.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessContextMenuParityTests: XCTestCase {
  // MARK: - Меню карточки

  func testCardMenu_повторяетПорядокИГруппыЭталона() {
    let groups = QuickAccessCardMenuLayout.groups(isVideo: false, includesCloud: true)
    XCTAssertEqual(groups, [
      [.openAnnotation, .pinToScreen, .extractText],
      [.rotateLeft, .flipHorizontal, .resize],
      [.uploadToCloud, .quickLook, .print, .saveAs],
      [.openWith, .openInMail],
      [.moveToTrash, .showInFinder],
      [.share],
      [.temporarilyHide, .close],
    ])
    // Scale Retina to 1x и Send To Raycast AI Chat... условные и по умолчанию не показываются
    XCTAssertEqual(
      groups.flatMap { $0 },
      QuickAccessCardMenuCommand.allCases.filter { $0 != .scaleRetina && $0 != .sendToRaycastAIChat }
    )
  }

  func testCardMenu_уВидеоНетОперацийНадКартинкой() {
    let commands = QuickAccessCardMenuLayout.groups(isVideo: true, includesCloud: true).flatMap { $0 }
    for command in [QuickAccessCardMenuCommand.pinToScreen, .extractText, .rotateLeft, .flipHorizontal, .resize, .print] {
      XCTAssertFalse(commands.contains(command), "\(command) не должен быть у видео")
    }
    XCTAssertEqual(commands.first, .openAnnotation)
    XCTAssertEqual(commands.last, .close)
    // Группа преобразований пустая и выпадает целиком.
    XCTAssertEqual(QuickAccessCardMenuLayout.groups(isVideo: true, includesCloud: true).count, 6)
  }

  func testCardMenu_безОблакаНетUpload() {
    let commands = QuickAccessCardMenuLayout.groups(isVideo: false, includesCloud: false).flatMap { $0 }
    XCTAssertFalse(commands.contains(.uploadToCloud))
    XCTAssertTrue(commands.contains(.quickLook))
  }

  // MARK: - Меню pin

  func testPinMenu_составПорядокИЗаголовки() {
    let entries = QuickAccessPinMenuLayout.entries(includesCloud: true)
    XCTAssertEqual(entries, [
      .command(.close),
      .separator,
      .command(.openAnnotation),
      .command(.copy),
      .command(.uploadToCloud),
      .command(.extractText),
      .command(.saveAs),
      .separator,
      .command(.lock),
      .separator,
      .header(.zoom),
      .command(.zoom(50)),
      .command(.zoom(100)),
      .command(.zoom(200)),
      .separator,
      .header(.opacity),
      .command(.opacity(20)),
      .command(.opacity(50)),
      .command(.opacity(100)),
      .separator,
      .command(.shadow),
      .command(.roundedCorners),
      .command(.border),
    ])
    let visibleRows = entries.filter { $0 != .separator }
    XCTAssertEqual(visibleRows.count, 18, "18 видимых строк эталона, включая 2 заголовка")
  }

  func testPinMenu_клавишиКакНаСнимкеЭталона() {
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .close), .command("w"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .openAnnotation), .command("e"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .copy), .command("c"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .uploadToCloud), .command("u"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .saveAs), .command("s"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .lock), .command("l"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .zoom(100)), .command("0"))
    XCTAssertNil(QuickAccessPinMenuLayout.key(for: .zoom(50)))
    XCTAssertNil(QuickAccessPinMenuLayout.key(for: .zoom(200)))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .opacity(20)), .plain("2"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .opacity(50)), .plain("5"))
    XCTAssertEqual(QuickAccessPinMenuLayout.key(for: .opacity(100)), .plain("0"))
    XCTAssertNil(QuickAccessPinMenuLayout.key(for: .extractText))
    XCTAssertNil(QuickAccessPinMenuLayout.key(for: .shadow))
  }

  func testPinMenu_клавишаНаходитКоманду() {
    func command(_ chars: String, _ flags: NSEvent.ModifierFlags) -> QuickAccessPinMenuCommand? {
      QuickAccessPinMenuLayout.command(forCharacters: chars, modifiers: flags, includesCloud: true)
    }
    XCTAssertEqual(command("0", .command), .zoom(100))
    XCTAssertEqual(command("0", []), .opacity(100))
    XCTAssertEqual(command("2", []), .opacity(20))
    XCTAssertEqual(command("W", .command), .close)
    XCTAssertEqual(command("l", [.command, .numericPad]), .lock)
    XCTAssertNil(command("2", .command))
    XCTAssertNil(command("c", []))
    XCTAssertNil(command("c", [.command, .shift]))
    XCTAssertNil(QuickAccessPinMenuLayout.command(forCharacters: "u", modifiers: .command, includesCloud: false))
  }

  // MARK: - Прозрачность pin

  func testPinOpacity_заблокированныйPinПодКурсоромДаёт64Из255() {
    XCTAssertEqual(
      QuickAccessPinWindowState.contentOpacity(opacity: 1, isLocked: true, isMouseInside: true),
      64.0 / 255.0,
      accuracy: 0.0001
    )
    XCTAssertEqual(QuickAccessPinWindowState.contentOpacity(opacity: 1, isLocked: true, isMouseInside: false), 1)
    XCTAssertEqual(QuickAccessPinWindowState.contentOpacity(opacity: 0.2, isLocked: false, isMouseInside: true), 0.2, accuracy: 0.0001)
    XCTAssertEqual(
      QuickAccessPinWindowState.contentOpacity(opacity: 0.5, isLocked: true, isMouseInside: true),
      0.5 * 64.0 / 255.0,
      accuracy: 0.0001
    )
  }

  // MARK: - Resize Image

  func testResize_связанныеПропорции800x400() {
    var dimensions = QuickAccessResizeDimensions(originalPixelSize: CGSize(width: 800, height: 400))
    XCTAssertTrue(dimensions.isUnchanged)
    dimensions.setWidth(400)
    XCTAssertEqual(dimensions.width, 400)
    XCTAssertEqual(dimensions.height, 200)
    XCTAssertEqual(dimensions.targetPixelSize, CGSize(width: 400, height: 200))
    dimensions.setHeight(100)
    XCTAssertEqual(dimensions.width, 200)
    XCTAssertFalse(dimensions.isUnchanged)
  }

  func testResize_безСвязиПолеНеМеняетДругое() {
    var dimensions = QuickAccessResizeDimensions(originalPixelSize: CGSize(width: 800, height: 400))
    dimensions.isLinked = false
    dimensions.setWidth(300)
    XCTAssertEqual(dimensions.targetPixelSize, CGSize(width: 300, height: 400))
  }

  func testResize_процентыИНекорректныйВвод() {
    var dimensions = QuickAccessResizeDimensions(originalPixelSize: CGSize(width: 801, height: 400))
    dimensions.setUnit(.percent)
    XCTAssertEqual(dimensions.width, 100)
    XCTAssertEqual(dimensions.height, 100)
    dimensions.setWidth(50)
    XCTAssertEqual(dimensions.height, 50)
    XCTAssertEqual(dimensions.targetPixelSize, CGSize(width: 401, height: 200))
    dimensions.setWidth(-5)
    dimensions.setWidth(.nan)
    XCTAssertEqual(dimensions.width, 50)
    dimensions.setUnit(.pixels)
    XCTAssertEqual(dimensions.width, 401)
    XCTAssertEqual(dimensions.height, 200)
  }

  // MARK: - Преобразования файла

  /// Картинка 2×1: левый пиксель красный, правый синий.
  private func makeTwoPixelImage() -> CGImage {
    let context = CGContext(
      data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    return context.makeImage()!
  }

  /// Цвет пикселя (x, y) от верхнего левого угла: true – красный.
  private func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
    let rep = NSBitmapImageRep(cgImage: image)
    let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return color.redComponent > 0.5 && color.blueComponent < 0.5
  }

  func testTransform_отражениеМеняетСтороны() throws {
    let output = try QuickAccessImageFileTransform.flipHorizontal.apply(to: makeTwoPixelImage())
    XCTAssertEqual(output.width, 2)
    XCTAssertFalse(isRed(output, x: 0, y: 0))
    XCTAssertTrue(isRed(output, x: 1, y: 0))
  }

  func testTransform_поворотВлевоПереноситЛевыйКрайВниз() throws {
    let output = try QuickAccessImageFileTransform.rotateLeft.apply(to: makeTwoPixelImage())
    XCTAssertEqual(output.width, 1)
    XCTAssertEqual(output.height, 2)
    // Против часовой: правый (синий) край уходит наверх, левый (красный) вниз.
    XCTAssertFalse(isRed(output, x: 0, y: 0))
    XCTAssertTrue(isRed(output, x: 0, y: 1))
  }

  func testTransform_resizeПерезаписываетФайлВТомЖеФормате() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.png")

    let context = CGContext(
      data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    XCTAssertEqual(QuickAccessImageFileTransform.pixelSize(of: url), CGSize(width: 800, height: 400))
    try QuickAccessImageFileTransform.resize(CGSize(width: 400, height: 200)).apply(toFileAt: url)
    XCTAssertEqual(QuickAccessImageFileTransform.pixelSize(of: url), CGSize(width: 400, height: 200))

    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(leftovers, ["fixture.png"], "Промежуточный файл не остаётся")
  }

  // MARK: - Open With

  func testOpenWith_приложениеПоУмолчаниюПервым() {
    let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    let krita = URL(fileURLWithPath: "/Applications/krita.app")
    let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    let ordered = QuickAccessFileActions.orderedApplications(
      [safari, krita, preview, chrome, safari],
      defaultApplication: preview,
      displayName: { $0.deletingPathExtension().lastPathComponent }
    )
    XCTAssertEqual(ordered, [preview, chrome, krita, safari])
  }

  func testOpenWith_умолчаниеВнеСпискаНеДобавляется() {
    let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    let ordered = QuickAccessFileActions.orderedApplications(
      [safari],
      defaultApplication: preview,
      displayName: { $0.lastPathComponent }
    )
    XCTAssertEqual(ordered, [safari])
  }

  // MARK: - Restore Last Capture

  private func makeRecord(_ name: String, capturedAt: Date, isDeleted: Bool = false) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(),
      filePath: "/tmp/\(name).png",
      fileName: "\(name).png",
      captureType: .screenshot,
      fileSize: 1,
      capturedAt: capturedAt,
      width: 1,
      height: 1,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: isDeleted
    )
  }

  func testRestorePolicy_сортируетЗакрытыеЗаписиОтНовыхКСтарым() {
    let now = Date()
    let old = makeRecord("old", capturedAt: now.addingTimeInterval(-300))
    let recent = makeRecord("recent", capturedAt: now.addingTimeInterval(-60))
    let open = makeRecord("open", capturedAt: now)
    let deleted = makeRecord("deleted", capturedAt: now.addingTimeInterval(60), isDeleted: true)

    let candidates = QuickAccessRestorePolicy.historyCandidates(
      in: [old, recent, open, deleted],
      excluding: [open.fileURL.standardizedFileURL]
    )
    XCTAssertEqual(candidates.map(\.id), [recent.id, old.id])
  }

  func testRestorePolicy_пустаяИсторияНеДаётКандидатов() {
    XCTAssertTrue(QuickAccessRestorePolicy.historyCandidates(in: [], excluding: []).isEmpty)
  }
}
