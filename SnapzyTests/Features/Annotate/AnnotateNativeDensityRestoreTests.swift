//
//  AnnotateNativeDensityRestoreTests.swift
//  SnapzyTests
//
//  Regression tests for native-density (1×) capture restores: annotation sessions
//  must reopen in the exact logical coordinate space they were authored in,
//  regardless of the current main display's scale factor (issue #414 follow-up).
//

import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateNativeDensityRestoreTests: XCTestCase {

  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_AnnotateNativeDensity_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    tempDirectory = nil
    super.tearDown()
  }

  // MARK: - File DPI density (Layer 2: file opens trust the file, not the screen)

  func testFileDensityScaleFactor_readsSnapzyWrittenDPI() throws {
    let retinaURL = try writePNG(named: "retina.png", pixelWidth: 400, pixelHeight: 300, dpi: 144)
    XCTAssertEqual(try XCTUnwrap(AnnotateState.fileDensityScaleFactor(from: retinaURL)), 2.0, accuracy: 0.001)

    let nativeURL = try writePNG(named: "native.png", pixelWidth: 400, pixelHeight: 300, dpi: 72)
    XCTAssertEqual(try XCTUnwrap(AnnotateState.fileDensityScaleFactor(from: nativeURL)), 1.0, accuracy: 0.001)
  }

  func testFileDensityScaleFactor_returnsNilWithoutDPIMetadata() throws {
    let url = try writePNG(named: "nodpi.png", pixelWidth: 400, pixelHeight: 300, dpi: nil)
    XCTAssertNil(AnnotateState.fileDensityScaleFactor(from: url))
  }

  func testLoadImageWithCorrectScale_keepsNative1xCaptureAtAuthoredLogicalSize() throws {
    // A non-Retina (1×) capture must keep pixel == logical size even when the
    // main display is Retina — the pre-fix heuristic halved it here.
    let url = try writePNG(named: "capture1x.png", pixelWidth: 400, pixelHeight: 300, dpi: 72)

    let image = try XCTUnwrap(AnnotateState.loadImageWithCorrectScale(from: url))

    XCTAssertEqual(image.size.width, 400, accuracy: 0.5)
    XCTAssertEqual(image.size.height, 300, accuracy: 0.5)
  }

  func testLoadImageWithCorrectScale_normalizesRetinaCaptureFromFileDPI() throws {
    // A 2× capture must normalize to points even when the main display is 1×.
    let url = try writePNG(named: "capture2x.png", pixelWidth: 400, pixelHeight: 300, dpi: 144)

    let image = try XCTUnwrap(AnnotateState.loadImageWithCorrectScale(from: url))

    XCTAssertEqual(image.size.width, 200, accuracy: 0.5)
    XCTAssertEqual(image.size.height, 150, accuracy: 0.5)
  }

  // MARK: - Legacy normalize heuristic branches (pure, screen-independent)

  func testNormalizedRetinaLogicalSize_scale1LeavesImageUntouched() throws {
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)
    XCTAssertNil(AnnotateState.normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: 1.0))
  }

  func testNormalizedRetinaLogicalSize_scale2HalvesPixelSizedImage() throws {
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)
    let normalized = try XCTUnwrap(
      AnnotateState.normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: 2.0)
    )
    XCTAssertEqual(normalized.width, 200, accuracy: 0.001)
    XCTAssertEqual(normalized.height, 150, accuracy: 0.001)
  }

  func testNormalizedRetinaLogicalSize_scale2LeavesAlreadyNormalizedImage() throws {
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)
    image.size = NSSize(width: 200, height: 150)
    XCTAssertNil(AnnotateState.normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: 2.0))
  }

  func testNormalizedRetinaLogicalSize_scale2LeavesNonIntegralDensityUntouched() throws {
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)
    image.size = NSSize(width: 267, height: 200)
    XCTAssertNil(AnnotateState.normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: 2.0))
  }

  // MARK: - Session restore (Layer 1: sidecar logical size wins over the heuristic)

  func testФоновыйПресетСохраняетИсходныйРазмерПриПовторномОткрытии() throws {
    let presetStore = AnnotateCanvasPresetStore(defaults: UserDefaultsFactory.make())
    let preset = AnnotateCanvasPreset(name: "Проверка", payload: .init(
      backgroundStyle: CodableBackgroundStyle(from: .solidColor(.red))!,
      padding: 12, shadowIntensity: 0, cornerRadius: 0))
    presetStore.savePresets([preset])
    presetStore.saveDefaultPresetId(preset.id)
    let applier = ScreenshotPresetAutoApplier(presetStore: presetStore)
    let sessions = AnnotationSessionStore(rootDirectory: tempDirectory.appendingPathComponent("sessions", isDirectory: true))

    for scale in [1.0, 2.0] {
      let url = try writePNG(named: "preset-\(scale)x.png", pixelWidth: 80, pixelHeight: 60, dpi: 72 * scale)
      let original = try Data(contentsOf: url)
      let data = try XCTUnwrap(applier.applyDefaultPresetIfNeeded(to: url))
      XCTAssertNotEqual(try Data(contentsOf: url), original)
      XCTAssertTrue(sessions.persist(data, for: url))

      let loaded = try XCTUnwrap(sessions.load(for: url))
      XCTAssertEqual(loaded.selectedCanvasPresetId, preset.id)
      XCTAssertEqual(loaded.originalImageData, original)
      let logicalSize = try XCTUnwrap(loaded.sourceLogicalSize)
      XCTAssertEqual(logicalSize.width, 80 / scale, accuracy: 0.5)
      XCTAssertEqual(logicalSize.height, 60 / scale, accuracy: 0.5)
      let image = try XCTUnwrap(NSImage(data: loaded.originalImageData))
      let restored = AnnotateWindowController.restoredSessionImage(image, sourceLogicalSize: logicalSize)
      XCTAssertEqual(restored.size, logicalSize)
    }
  }

  func testRestoredSessionImage_usesStoredLogicalSizeVerbatim() throws {
    // Authored at 400×300 pt; stored size must win on any display arrangement.
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)

    let restored = AnnotateWindowController.restoredSessionImage(
      image,
      sourceLogicalSize: CGSize(width: 400, height: 300)
    )

    XCTAssertEqual(restored.size.width, 400, accuracy: 0.001)
    XCTAssertEqual(restored.size.height, 300, accuracy: 0.001)
  }

  func testRestoredSessionImage_fallsBackToHeuristicWhenSizeMissing() throws {
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)

    let restored = AnnotateWindowController.restoredSessionImage(image, sourceLogicalSize: nil)

    XCTAssertTrue(restored === image)
  }

  func testRestoredSessionImage_fallsBackToHeuristicWhenSizeIsZero() throws {
    let image = try makePixelBackedImage(pixelWidth: 400, pixelHeight: 300)

    let restored = AnnotateWindowController.restoredSessionImage(image, sourceLogicalSize: .zero)

    XCTAssertTrue(restored === image)
  }

  // MARK: - Начальный масштаб при открытии файла (NEW-062-zoom)

  func testДлинныйСнимокОткрываетсяВ100ПроцентахИПрокручиваетсяПолзунком() throws {
    let url = try writePNG(named: "scrolling-result.png", pixelWidth: 1100, pixelHeight: 3700, dpi: 144)
    let controller = AnnotateWindowController(url: url)
    let window = try XCTUnwrap(controller.window)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let state = try XCTUnwrap(OwnShotQuitGuard.annotateState(of: controller))
    state.showSidebar = false
    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

    XCTAssertEqual(state.currentDisplayedZoomPercent, 100)
    XCTAssertGreaterThan(state.panOffset.height, 0, "При открытии виден верх длинного снимка")
    func scrollers(in view: NSView) -> [NSScroller] {
      (view as? NSScroller).map { [$0] } ?? view.subviews.flatMap { scrollers(in: $0) }
    }
    let controls = scrollers(in: try XCTUnwrap(window.contentView))
    let vertical = try XCTUnwrap(controls.first { $0.frame.height > $0.frame.width && !$0.isHidden })
    XCTAssertEqual(vertical.doubleValue, 0, accuracy: 0.001)
    XCTAssertGreaterThan(vertical.knobProportion, 0)
    XCTAssertLessThan(vertical.knobProportion, 1)
    vertical.doubleValue = 1
    vertical.sendAction(vertical.action, to: vertical.target)
    XCTAssertLessThan(state.panOffset.height, 0, "Ползунок открывает нижнюю часть снимка")
    vertical.doubleValue = 0
    vertical.sendAction(vertical.action, to: vertical.target)
    XCTAssertGreaterThan(state.panOffset.height, 0, "Ползунок возвращает верх снимка")
    let topOffset = state.panOffset.height
    let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
      wheelCount: 1, wheel1: -48, wheel2: 0, wheel3: 0))
    vertical.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
    XCTAssertLessThan(state.panOffset.height, topOffset, "Колесо над полосой тоже прокручивает снимок")
  }

  func testПолзункиОткрываютНижнийПравыйКрайБезПерекрытияПолосами() throws {
    let url = try writePNG(named: "both-axis-overflow.png", pixelWidth: 1600, pixelHeight: 1200, dpi: 72, marksRightEdge: true)
    let controller = AnnotateWindowController(url: url)
    let window = try XCTUnwrap(controller.window)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let state = try XCTUnwrap(OwnShotQuitGuard.annotateState(of: controller))
    state.showSidebar = false
    state.backgroundStyle = .none
    state.padding = 0
    state.inset = 0
    state.cornerRadius = 0
    state.aspectRatio = .auto
    state.imageAlignment = .center
    window.setContentSize(NSSize(width: 990, height: 500))
    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    state.zoomLevel = state.zoomLevel(forDisplayedPercent: 100)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

    func descendants(in view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants(in: $0) }
    }
    let views = descendants(in: try XCTUnwrap(window.contentView))
    let proxy = try XCTUnwrap(views.compactMap { $0 as? CanvasInteractionProxyNSView }.first)
    let canvas = try XCTUnwrap(views.compactMap { $0 as? DrawingCanvasNSView }.first)
    let controls = views.compactMap { $0 as? AnnotateCanvasScroller }.filter { !$0.isHidden }
    let vertical = try XCTUnwrap(controls.first { $0.frame.height > $0.frame.width })
    let horizontal = try XCTUnwrap(controls.first { $0.frame.width > $0.frame.height })
    XCTAssertGreaterThan(state.baseCanvasDisplaySize.width * state.zoomLevel, state.canvasContainerSize.width)
    XCTAssertGreaterThan(state.baseCanvasDisplaySize.height * state.zoomLevel, state.canvasContainerSize.height)
    let initialImage = canvas.convert(canvas.bounds, to: nil)
    let initialPan = state.panOffset
    vertical.doubleValue = 1
    vertical.sendAction(vertical.action, to: vertical.target)
    horizontal.doubleValue = 1
    horizontal.sendAction(horizontal.action, to: horizontal.target)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

    // Все прямоугольники переводим в координаты окна: Y растёт вверх.
    // Это тот же путь convert(bounds, to: nil), что у hit-test прокси холста.
    let viewport = proxy.convert(proxy.bounds, to: nil)
    let image = canvas.convert(canvas.bounds, to: nil)
    let verticalTrack = vertical.convert(vertical.bounds, to: nil)
    let horizontalTrack = horizontal.convert(horizontal.bounds, to: nil)
    XCTAssertEqual(viewport.width, state.canvasContainerSize.width, accuracy: 1)
    XCTAssertEqual(viewport.height, state.canvasContainerSize.height, accuracy: 1)
    // AppKit округляет fit-sized bounds до физического пикселя до внешнего zoom.
    let layoutPixel = 1 / window.backingScaleFactor
    XCTAssertEqual(canvas.bounds.width, state.baseCanvasDisplaySize.width, accuracy: layoutPixel)
    XCTAssertEqual(canvas.bounds.height, state.baseCanvasDisplaySize.height, accuracy: layoutPixel)
    XCTAssertEqual(image.width, canvas.bounds.width * state.zoomLevel, accuracy: 1)
    XCTAssertEqual(image.height, canvas.bounds.height * state.zoomLevel, accuracy: 1)
    // Проверяем реальное перемещение слоя, не предполагая его округлённый layout origin.
    // В координатах окна положительный SwiftUI pan по Y сдвигает слой вниз.
    let geometry = "viewport=\(viewport), initialImage=\(initialImage), initialPan=\(initialPan), finalPan=\(state.panOffset), zoom=\(state.zoomLevel)"
    XCTAssertEqual(image.maxX, initialImage.maxX + state.panOffset.width - initialPan.width,
      accuracy: 1, geometry)
    XCTAssertEqual(image.minY, initialImage.minY - state.panOffset.height + initialPan.height,
      accuracy: 1, geometry)
    XCTAssertGreaterThan(verticalTrack.height, 20)
    XCTAssertGreaterThan(horizontalTrack.width, 20)
    XCTAssertEqual(verticalTrack.maxX, viewport.maxX, accuracy: verticalTrack.width + 1)
    XCTAssertEqual(horizontalTrack.minY, viewport.minY, accuracy: horizontalTrack.height + 1)
    XCTAssertLessThanOrEqual(image.maxX, verticalTrack.minX + 1,
      "Последние столбцы снимка должны быть видны слева от вертикальной полосы")
    XCTAssertGreaterThanOrEqual(image.minY, horizontalTrack.maxY - 1,
      "Последние строки снимка должны быть видны над горизонтальной полосой")

    let originalAppearance = ThemeManager.shared.preferredAppearance
    let storedAppearance = UserDefaults.standard.object(forKey: PreferencesKeys.appearanceMode)
    defer {
      ThemeManager.shared.preferredAppearance = originalAppearance
      if let storedAppearance {
        UserDefaults.standard.set(storedAppearance, forKey: PreferencesKeys.appearanceMode)
      } else {
        UserDefaults.standard.removeObject(forKey: PreferencesKeys.appearanceMode)
      }
    }
    for (name, appearance) in [("light", AppearanceMode.light), ("dark", .dark)] {
      ThemeManager.shared.preferredAppearance = appearance
      let content = try XCTUnwrap(window.contentView)
      content.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "/private/tmp/ownshot-scrollbar-endpoint-\(name).png"))
      // Последний столбец исходника имеет ширину ровно 1 px и цвет magenta.
      // Проверяем растр отдельно от округлённого AppKit frame слоя аннотаций.
      let edgePixels = try stride(from: viewport.maxX - 6, to: viewport.maxX, by: 0.25).map {
        try bitmapRGB(bitmap, content: content, windowPoint: CGPoint(x: $0, y: viewport.midY))
      }
      XCTAssertTrue(edgePixels.contains { $0[0] - $0[1] > 100 && $0[2] - $0[1] > 100 },
        "Последний пиксельный столбец должен быть виден перед полосой: \(edgePixels)")
    }

    vertical.doubleValue = 0.5
    vertical.sendAction(vertical.action, to: vertical.target)
    horizontal.doubleValue = 0.5
    horizontal.sendAction(horizontal.action, to: horizontal.target)
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    let midpoint = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: midpoint)
    let sourcePixel = try bitmapRGB(midpoint, content: content,
      windowPoint: CGPoint(x: viewport.midX, y: viewport.midY))
    let cornerPixel = try bitmapRGB(midpoint, content: content,
      windowPoint: CGPoint(x: verticalTrack.midX, y: horizontalTrack.midY))
    XCTAssertGreaterThan(zip(sourcePixel, cornerPixel).reduce(0) { $0 + abs($1.0 - $1.1) }, 24,
      "Зарезервированный угол не должен закрашиваться снимком: source=\(sourcePixel), corner=\(cornerPixel)")
    try XCTUnwrap(midpoint.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/private/tmp/ownshot-scrollbar-midpoint-dark.png"))
  }

  func testОдиночнаяПолосаОткрываетКрайАВписанныйСнимокНеПоказываетПолос() throws {
    for (width, height) in [(1600, 100), (100, 1200), (100, 100)] {
      let url = try writePNG(named: "single-axis-\(width)-\(height).png",
        pixelWidth: width, pixelHeight: height, dpi: 72)
      let controller = AnnotateWindowController(url: url)
      let window = try XCTUnwrap(controller.window)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let state = try XCTUnwrap(OwnShotQuitGuard.annotateState(of: controller))
      state.showSidebar = false
      state.backgroundStyle = .none
      state.padding = 0
      state.inset = 0
      state.cornerRadius = 0
      state.aspectRatio = .auto
      state.imageAlignment = .center
      window.setContentSize(NSSize(width: 990, height: 500))
      window.orderFront(nil)
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
      state.zoomLevel = state.zoomLevel(forDisplayedPercent: 100)
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

      func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
      }
      let views = descendants(in: try XCTUnwrap(window.contentView))
      let controls = views.compactMap { $0 as? AnnotateCanvasScroller }.filter { !$0.isHidden }
      let horizontal = controls.first { $0.frame.width > $0.frame.height }
      let vertical = controls.first { $0.frame.height > $0.frame.width }
      XCTAssertEqual(horizontal != nil, width == 1600)
      XCTAssertEqual(vertical != nil, height == 1200)
      for control in controls {
        control.doubleValue = 1
        control.sendAction(control.action, to: control.target)
      }
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
      let proxy = try XCTUnwrap(views.compactMap { $0 as? CanvasInteractionProxyNSView }.first)
      let canvas = try XCTUnwrap(views.compactMap { $0 as? DrawingCanvasNSView }.first)
      let viewport = proxy.convert(proxy.bounds, to: nil)
      let image = canvas.convert(canvas.bounds, to: nil)
      if horizontal != nil {
        XCTAssertLessThanOrEqual(image.maxX, viewport.maxX + 1, "Правый край доступен одной горизонтальной полосой")
      }
      if vertical != nil {
        XCTAssertGreaterThanOrEqual(image.minY, viewport.minY - 1, "Нижний край доступен одной вертикальной полосой")
      }
      if controls.isEmpty {
        XCTAssertEqual(state.panOffset, .zero)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(image), "Весь маленький снимок виден без полос")
      }
      if width == 1600 {
        func visibleScrollers() throws -> [AnnotateCanvasScroller] {
          descendants(in: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? AnnotateCanvasScroller }.filter { !$0.isHidden }
        }
        // Fit убирает полосы. Затем горизонтальная полоса делает необходимой вертикальную:
        // высота снимка на 8 pt меньше полного viewport, но больше viewport за вычетом полосы.
        state.zoomLevel = 1
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(try visibleScrollers().isEmpty)
        state.zoomLevel = (state.canvasContainerSize.height - 8) / state.baseCanvasDisplaySize.height
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(try visibleScrollers().count, 2)
        let settledSize = state.canvasContainerSize
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(state.canvasContainerSize, settledSize, "Полосы не запускают цикл изменения viewport и Fit")
        XCTAssertEqual(try visibleScrollers().count, 2)
        state.zoomLevel = 1
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(try visibleScrollers().isEmpty)
        XCTAssertEqual(state.panOffset, .zero)
      }
    }
  }

  /// Путь как у ownshot://open-annotate: AnnotateManager строит AnnotateWindowController(url:)
  /// и показывает окно 990×500. Эталон открывает PNG 800×400 (72 dpi) в 100% с прокруткой,
  /// видно верх картинки; вписанные 79% – ошибка.
  func testОткрытиеФайлаЧерезКонтроллерПоказывает100ПроцентовСВерхаКартинки() throws {
    let url = try writePNG(named: "zoom-062.png", pixelWidth: 800, pixelHeight: 400, dpi: 72)
    let controller = AnnotateWindowController(url: url)
    let window = try XCTUnwrap(controller.window)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let state = try XCTUnwrap(OwnShotQuitGuard.annotateState(of: controller))
    state.showSidebar = false

    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

    XCTAssertEqual(state.sourceImage?.size, CGSize(width: 800, height: 400))
    XCTAssertLessThan(state.fitScale, 0.99, "Картинка 400 pt не помещается по высоте в окно 500 pt – fit меньше 100%")
    XCTAssertEqual(state.currentDisplayedZoomPercent, 100)
    // Прокрутка от верха: холст сдвинут вниз ровно на переполнение по высоте, по ширине по центру.
    XCTAssertGreaterThan(state.panOffset.height, 0)
    XCTAssertEqual(state.panOffset.width, 0, accuracy: 0.0001)

    // Смена размера окна, пока пользователь не трогал масштаб, сохраняет 100%.
    window.setContentSize(NSSize(width: 1_100, height: 560))
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    XCTAssertEqual(state.currentDisplayedZoomPercent, 100)

    // Выбор масштаба пользователем дальше не перетирается.
    state.zoomLevel = state.zoomLevel(forDisplayedPercent: 50)
    window.setContentSize(NSSize(width: 1_000, height: 520))
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    XCTAssertFalse(state.pendingInitialActualSize)
  }

  /// Восстановленная сессия открывается как раньше – вписанной.
  func testВосстановленнаяСессияОткрываетсяВписанной() throws {
    let url = try writePNG(named: "zoom-062-session.png", pixelWidth: 800, pixelHeight: 400, dpi: 72)
    let sessionData = AnnotationSessionData(
      originalImageData: try Data(contentsOf: url),
      annotations: [],
      canvasEffects: AnnotationCanvasEffects(),
      sourceLogicalSize: CGSize(width: 800, height: 400)
    )
    let controller = AnnotateWindowController(url: url, sessionData: sessionData)
    let window = try XCTUnwrap(controller.window)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let state = try XCTUnwrap(OwnShotQuitGuard.annotateState(of: controller))
    state.showSidebar = false

    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

    XCTAssertFalse(state.pendingInitialActualSize)
    XCTAssertEqual(state.zoomLevel, 1.0, accuracy: 0.0001)
    XCTAssertEqual(state.panOffset, .zero)
  }

  // MARK: - Helpers

  private func makePixelBackedImage(pixelWidth: Int, pixelHeight: Int) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: pixelWidth, height: pixelHeight))
    // NSBitmapImageRep keeps pixelsWide == CGImage width; NSImage(cgImage:size:)
    // would rasterize an NSCGImageSnapshotRep at the host screen's backing scale.
    let rep = NSBitmapImageRep(cgImage: cgImage)
    let image = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
    image.addRepresentation(rep)
    return image
  }

  /// Writes a PNG the way `ScreenCaptureManager.imageDestinationProperties` does:
  /// DPI = scale × 72 when provided, no density metadata otherwise.
  private func bitmapRGB(_ bitmap: NSBitmapImageRep, content: NSView, windowPoint: CGPoint) throws -> [Int] {
    let point = content.convert(windowPoint, from: nil)
    let x = Int((point.x - content.bounds.minX) * CGFloat(bitmap.pixelsWide) / content.bounds.width)
    let top = content.isFlipped ? point.y - content.bounds.minY : content.bounds.maxY - point.y
    let y = Int(top * CGFloat(bitmap.pixelsHigh) / content.bounds.height)
    XCTAssertTrue((0..<bitmap.pixelsWide).contains(x) && (0..<bitmap.pixelsHigh).contains(y))
    guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y) else {
      throw NSError(domain: "OwnShotBitmapBounds", code: 1)
    }
    XCTAssertFalse(bitmap.isPlanar)
    XCTAssertGreaterThanOrEqual(bitmap.samplesPerPixel, 3)
    let bytes = try XCTUnwrap(bitmap.bitmapData)
    let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
    return (0..<3).map { Int(bytes[offset + $0]) }
  }

  private func writePNG(named name: String, pixelWidth: Int, pixelHeight: Int, dpi: Double?,
    marksRightEdge: Bool = false) throws -> URL {
    let url = tempDirectory.appendingPathComponent(name)
    var cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: pixelWidth, height: pixelHeight))
    if marksRightEdge {
      let context = try XCTUnwrap(CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: pixelWidth - 1, y: 0, width: 1, height: pixelHeight))
      cgImage = try XCTUnwrap(context.makeImage())
    }
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    )
    var properties: [CFString: Any] = [:]
    if let dpi {
      properties[kCGImagePropertyDPIWidth] = dpi
      properties[kCGImagePropertyDPIHeight] = dpi
    }
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }
}
