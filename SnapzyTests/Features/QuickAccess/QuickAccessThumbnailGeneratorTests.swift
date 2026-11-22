import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessThumbnailGeneratorTests: XCTestCase {
  private func longImage() throws -> NSImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: 1100, height: 3700,
      bitsPerComponent: 8, bytesPerRow: 4400, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for (index, color) in [NSColor.red, .green, .blue].enumerated() {
      context.setFillColor(color.cgColor)
      context.fill(CGRect(x: 0, y: index * 1234, width: 1100, height: 1234))
    }
    return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 550, height: 1850))
  }

  func testМиниатюраДлинногоСнимкаСохраняетRetinaДеталиКарточки() async throws {
    let image = try longImage()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
    try data.write(to: url)
    let generated = await ThumbnailGenerator.generate(from: url)
    let thumbnail = try XCTUnwrap(generated.cardThumbnail)
    try assertSharpCard(thumbnail)
    let fallback = try XCTUnwrap(generated.thumbnail)
    XCTAssertEqual(fallback.size.width / fallback.size.height, 1100.0 / 3700, accuracy: 0.001,
      "Резервное открытие сохраняет весь снимок, включая верх и низ")
    let fallbackBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(
      fallback.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    let ends = try [0, fallbackBitmap.pixelsHigh - 1].map { row in
      try XCTUnwrap(fallbackBitmap.colorAt(x: fallbackBitmap.pixelsWide / 2, y: row)?.usingColorSpace(.deviceRGB))
    }
    XCTAssertGreaterThan(ends.map(\.redComponent).max() ?? 0, 0.8)
    XCTAssertGreaterThan(ends.map(\.blueComponent).max() ?? 0, 0.8)
  }

  func testAppKitDragПолучаетЧёткийФрагментКарточкиВместоПолногоСнимка() throws {
    let image = try longImage()
    let fullThumbnail = QuickAccessManager.cgScaleThumbnail(image, maxSize: 200)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("drag-thumbnail-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])).write(to: url)
    let item = QuickAccessItem(
      url: url,
      thumbnail: fullThumbnail,
      cardThumbnail: QuickAccessThumbnailRenderer.render(image, width: QuickAccessLayout.cardWidth))
    let hosting = NSHostingView(rootView: QuickAccessCardView(item: item, manager: .shared))
    hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    hosting.layoutSubtreeIfNeeded()

    func dragMonitors(in view: NSView) -> [QuickAccessDragMonitorView] {
      ((view as? QuickAccessDragMonitorView).map { [$0] } ?? []) + view.subviews.flatMap(dragMonitors)
    }
    let monitors = dragMonitors(in: hosting)
    XCTAssertEqual(monitors.count, 1, "Проверяем настоящий AppKit bridge карточки")
    let monitor = try XCTUnwrap(monitors.first)
    try assertSharpCard(monitor.thumbnail)
    XCTAssertEqual(item.thumbnail.size.width / item.thumbnail.size.height,
      1100.0 / 3700, accuracy: 0.001,
      "Полный снимок остаётся резервом открытия и pin, а drag получает фрагмент карточки")
  }

  func testМиниатюраПослеРедактированияНеТеряетЧёткость() async throws {
    let image = try longImage()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-update-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try XCTUnwrap(image.tiffRepresentation).write(to: url)
    let manager = QuickAccessManager.shared
    let result = await manager.addScreenshot(url: url)
    let added = try XCTUnwrap(result)
    defer { manager.removeItem(id: added.id) }
    manager.updateItemThumbnail(id: added.id, image: image)
    let updated = try XCTUnwrap(manager.items.first { $0.id == added.id })
    try assertSharpCard(try XCTUnwrap(updated.cardThumbnail))
    XCTAssertEqual(updated.thumbnail.size.width / updated.thumbnail.size.height,
      1100.0 / 3700, accuracy: 0.001)
    let generation = manager.nextThumbnailGeneration(for: added.id)
    manager.updateItemThumbnail(id: added.id,
      thumbnail: QuickAccessManager.cgScaleThumbnail(image, maxSize: 200),
      fullResImage: image, generation: generation)
    let saved = try XCTUnwrap(manager.items.first { $0.id == added.id })
    try assertSharpCard(try XCTUnwrap(saved.cardThumbnail))
  }

  func testURLQuickAccessПоказываетВидеоСДлительностьюИСнимок() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAccessURL-\(UUID())",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Recording/quick-access-url.mp4")
    let video = directory.appendingPathComponent("Fixture Video.MP4")
    let screenshot = directory.appendingPathComponent("Fixture Image.png")
    let videoData = try Data(contentsOf: fixture)
    try videoData.write(to: video)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 48, height: 32, red: 255, green: 0, blue: 0))
    let imageData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try imageData.write(to: screenshot)

    let manager = QuickAccessManager.shared
    let previousEnabled = manager.isEnabled
    let previousAutoDismiss = manager.autoDismissEnabled
    let defaults = UserDefaults.standard
    let previousURLSetting = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    manager.isEnabled = true
    manager.autoDismissEnabled = false
    defer {
      for item in manager.items where item.url == video || item.url == screenshot {
        manager.removeItem(id: item.id)
      }
      manager.autoDismissEnabled = previousAutoDismiss
      manager.isEnabled = previousEnabled
      defaults.set(previousURLSetting, forKey: PreferencesKeys.urlSchemeEnabled)
    }
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())
    var components = URLComponents()
    components.scheme = "ownshot"
    components.host = "add-quick-access-overlay"
    for url in [screenshot, video] {
      components.queryItems = [URLQueryItem(name: "filepath", value: url.path)]
      handler.handle(try XCTUnwrap(components.url))
      let deadline = ContinuousClock.now + .seconds(5)
      while ContinuousClock.now < deadline, !manager.items.contains(where: { $0.url == url }) {
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    let videoCard = try XCTUnwrap(manager.items.first { $0.url == video })
    XCTAssertEqual(videoCard.itemType, .video)
    XCTAssertEqual(videoCard.duration ?? -1, 2, accuracy: 0.001)
    XCTAssertEqual(videoCard.thumbnail.size.width / videoCard.thumbnail.size.height, 4.0 / 3, accuracy: 0.001)
    let imageCard = try XCTUnwrap(manager.items.first { $0.url == screenshot })
    XCTAssertEqual(imageCard.itemType, .screenshot)
    XCTAssertNil(imageCard.duration)
    XCTAssertEqual(try Data(contentsOf: video), videoData)
    XCTAssertEqual(try Data(contentsOf: screenshot), imageData)

    // Дожидаемся завершения пружинной анимации входа второй карточки.
    try await Task.sleep(for: .milliseconds(750))
    let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? QuickAccessPanel }.first {
      $0.isVisible && ($0.contentView as? NSHostingView<QuickAccessStackView>)?.rootView.manager === manager
    })
    let content = try XCTUnwrap(panel.contentView)
    let theme = ThemeManager.shared
    let previousAppearance = theme.preferredAppearance
    defer { theme.preferredAppearance = previousAppearance }
    let originalAppearance = panel.appearance
    defer { panel.appearance = originalAppearance }
    for mode in [AppearanceMode.light, .dark] {
      theme.preferredAppearance = mode
      panel.appearance = theme.nsAppearance
      try await Task.sleep(for: .milliseconds(250))
      content.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "quick-access-url-video-\(mode.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testURLQuickAccessПропускаетКаталогИНеМедиаФайл() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    try XCTSkipUnless(OwnShotStoragePaths.testRoot != nil, "Требуется хранилище OwnShot Test Host")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "QuickAccessInvalidURL-\(UUID())", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let folder = directory.appendingPathComponent("Fixture Folder.png", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let input = Data("OwnShot file fixture".utf8)
    try input.write(to: folder.appendingPathComponent("retained.txt"))
    let text = directory.appendingPathComponent("Fixture Notes.txt")
    let brokenPNG = directory.appendingPathComponent("Corrupted Image.png")
    let brokenMP4 = directory.appendingPathComponent("Corrupted Video.mp4")
    for file in [text, brokenPNG, brokenMP4] { try input.write(to: file) }
    let invalidURLs = [folder, text, brokenPNG, brokenMP4]

    let manager = QuickAccessManager.shared
    let previousEnabled = manager.isEnabled
    let previousAutoDismiss = manager.autoDismissEnabled
    let defaults = UserDefaults.standard
    let previousURLSetting = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    manager.isEnabled = true
    manager.autoDismissEnabled = false
    defer {
      for item in manager.items where item.url.path.hasPrefix(directory.path + "/") {
        manager.removeItem(id: item.id)
      }
      manager.autoDismissEnabled = previousAutoDismiss
      manager.isEnabled = previousEnabled
      defaults.set(previousURLSetting, forKey: PreferencesKeys.urlSchemeEnabled)
      try? FileManager.default.removeItem(at: directory)
    }
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 20, height: 16))
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    for index in 0..<manager.maxVisibleItems {
      let capture = directory.appendingPathComponent("capture-\(index).png")
      try png.write(to: capture)
      let card = await manager.addScreenshot(url: capture)
      XCTAssertNotNil(card)
    }
    let existingItems = manager.items.map(\.id)
    XCTAssertEqual(existingItems.count, manager.maxVisibleItems)
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())
    var components = URLComponents()
    components.scheme = "ownshot"
    components.host = "add-quick-access-overlay"
    for invalid in invalidURLs {
      components.queryItems = [URLQueryItem(name: "filepath", value: invalid.path)]
      handler.handle(try XCTUnwrap(components.url))
    }

    let deadline = ContinuousClock.now + .seconds(1)
    let invalidPaths = Set(invalidURLs.map(\.path))
    while ContinuousClock.now < deadline,
          !invalidPaths.isSubset(of: Set(manager.items.map { $0.url.path })) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(manager.items.map(\.id), existingItems)
    for url in invalidURLs {
      XCTAssertFalse(manager.items.contains { $0.url.path == url.path }, url.lastPathComponent)
    }
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("retained.txt")), input)
    for file in [text, brokenPNG, brokenMP4] {
      XCTAssertEqual(try Data(contentsOf: file), input)
    }
  }

  private func assertSharpCard(_ image: NSImage) throws {
    let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    // 210×150 pt, максимальный размер карточки 150%, Retina 2x.
    XCTAssertEqual(bitmap.width, 630)
    XCTAssertEqual(bitmap.height, 450)
    XCTAssertEqual(image.size.width / image.size.height, 1.4, accuracy: 0.01)
    let rep = NSBitmapImageRep(cgImage: bitmap)
    for (x, y) in [(0, 0), (bitmap.width / 2, bitmap.height / 2), (bitmap.width - 1, bitmap.height - 1)] {
      let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      XCTAssertGreaterThan(color.greenComponent, 0.95, "Карточка сохраняет прежнее центральное кадрирование")
      XCTAssertLessThan(color.redComponent, 0.05)
      XCTAssertLessThan(color.blueComponent, 0.05)
    }
  }
}
