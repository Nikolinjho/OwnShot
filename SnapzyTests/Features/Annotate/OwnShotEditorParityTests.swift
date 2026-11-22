import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

final class OwnShotEditorParityTests: XCTestCase {
  @MainActor
  private static var retainedStates: [AnnotateState] = []

  @MainActor
  func testНативноеМенюРетушиОтображаетЗначкиИПрименяетBlackOut() throws {
    let state = makeState()
    state.activateTool(.blur)
    let controller = AnnotateRedactionMenuController { state.quickBlurTypeBinding.wrappedValue = $0 }
    let menu = controller.makeMenu()
    XCTAssertGreaterThanOrEqual(menu.size.width, 147)
    XCTAssertEqual(menu.items.map(\.title), ["Pixelate", "Blur (secure)", "Blur (smooth)", "Black Out"])
    for item in menu.items {
      XCTAssertNil(item.view)
      XCTAssertGreaterThan(try XCTUnwrap(item.image).size.width, 0)
    }
    menu.performActionForItem(at: 3)
    XCTAssertEqual(state.activeBlurType, .blackOut)
  }

  @MainActor
  func testНативноеМенюСтрелкиОтображаетЗначкиИВыбираетDouble() throws {
    let state = makeState()
    let controller = AnnotateArrowMenuController { state.setArrowPreset($0) }
    let menu = controller.makeMenu()
    XCTAssertGreaterThanOrEqual(menu.size.width, 152)
    XCTAssertEqual(menu.items.map(\.title), ["Standard", "Fancy", "Curved", "Double"])
    for item in menu.items {
      XCTAssertNil(item.view, "Мышь и клавиатуру обрабатывает штатная строка NSMenu")
      XCTAssertGreaterThan(try XCTUnwrap(item.image).size.width, 0)
    }
    menu.performActionForItem(at: 3)
    XCTAssertEqual(state.activeArrowPreset, .double)
    XCTAssertEqual(state.activeArrowStartHead, .arrow)
    XCTAssertEqual(state.activeArrowEndHead, .arrow)
  }

  @MainActor
  func testМенюТолщиныПовторяетШестьЗначенийЭталонаИПрименяетВыбор() {
    var selected: CGFloat = 7
    let controller = AnnotateThicknessMenuController { selected = $0 }
    controller.selectedWidth = 7
    let menu = controller.makeMenu()
    XCTAssertEqual(menu.size, NSSize(width: 61, height: 226))
    XCTAssertEqual(menu.items.map(\.tag), [1, 3, 7, 10, 15, 25],
      "Значения получены выбором каждой строки в живом эталоне")
    XCTAssertEqual(menu.items.map { $0.accessibilityLabel() },
      ["1 px", "3 px", "7 px", "10 px", "15 px", "25 px"])
    for index in menu.items.indices {
      menu.performActionForItem(at: index)
      XCTAssertEqual(selected, CGFloat([1, 3, 7, 10, 15, 25][index]))
    }
    XCTAssertEqual(menu.items.map { $0.image?.size }, Array(repeating: NSSize(width: 23, height: 30), count: 6))
    XCTAssertTrue(menu.items.allSatisfy { $0.view == nil })
  }

  @MainActor
  private func makeState() -> AnnotateState {
    let name = "ownshot.editor.parity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
    let state = AnnotateState(defaults: defaults)
    Self.retainedStates.append(state)
    return state
  }

  @MainActor
  func testSecureПоказываетСилуОтТрёхДоТридцатиСИсходнымДесять() {
    let state = makeState()
    state.activateTool(.blur)
    state.setActiveBlurType(.secure)
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "10")
    state.quickStrokeWidthBinding.wrappedValue = 20
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "30")
    state.quickStrokeWidthBinding.wrappedValue = 1
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "3")
    state.setActiveBlurType(.blackOut)
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "")
  }

  @MainActor
  func testDoubleПрименяетДвеГоловкиИОтменяетсяОднимДействием() throws {
    let state = makeState()
    let annotation = AnnotationItem(type: .arrow(ArrowGeometry(
      start: CGPoint(x: 5, y: 5), end: CGPoint(x: 80, y: 60), style: .straight)),
      bounds: CGRect(x: 5, y: 5, width: 75, height: 55), properties: AnnotationProperties())
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id
    state.setArrowPreset(.double)
    guard case .arrow(let double) = state.annotations[0].type else { return XCTFail("Ожидается стрелка") }
    XCTAssertEqual(double.style, .curvedRight)
    XCTAssertEqual(double.startHead, .arrow)
    XCTAssertEqual(double.endHead, .arrow)
    XCTAssertEqual(double.arrowType, .classic)
    state.undo()
    guard case .arrow(let original) = state.annotations[0].type else { return XCTFail("Ожидается стрелка") }
    XCTAssertEqual(original.style, .straight)
    XCTAssertEqual(original.startHead, .none)
    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testStandardУбираетВторуюГоловкуПослеDouble() {
    let state = makeState()
    state.setArrowPreset(.double)
    state.setArrowPreset(.standard)
    XCTAssertEqual(state.activeArrowStyle, .straight)
    XCTAssertEqual(state.activeArrowStartHead, .none)
    XCTAssertEqual(state.activeArrowEndHead, .arrow)
    XCTAssertEqual(state.activeArrowType, .classic)
  }

  @MainActor
  func testЗапеканиеОчищаетИсториюИСтарыеРедактируемыеАннотации() throws {
    let state = makeState()
    let cg = try XCTUnwrap(TestImageFactory.solidColor(width: 80, height: 60))
    state.loadImage(NSImage(cgImage: cg, size: CGSize(width: 80, height: 60)))
    state.saveState()
    state.annotations = [AnnotationItem(type: .rectangle,
      bounds: CGRect(x: 10, y: 10, width: 20, height: 15), properties: AnnotationProperties())]
    state.resizeImage(pixelWidth: 40, pixelHeight: 30, flattenAnnotations: true)
    XCTAssertFalse(state.canUndo)
    XCTAssertFalse(state.canRedo)
    state.undo()
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 40, height: 30))
  }

  func testСохранённыеСтилиСовместимыСНовымиВариантамиРедактора() {
    XCTAssertEqual(BlurType(rawValue: "gaussian"), .gaussian)
    XCTAssertEqual(BlurType(rawValue: "washi"), .washi)
    XCTAssertEqual(BlurType.redactionTypes, [.pixelated, .secure, .gaussian, .blackOut])
    XCTAssertEqual(BlurType.gaussian.displayName, "Blur (smooth)")
    XCTAssertEqual(BlurType.secure.displayName, "Blur (secure)")
  }

  func testНачальныйРазмерРедактораОграничиваетсяВидимойОбластьюЭкрана() {
    XCTAssertEqual(AnnotateWindowController.initialWindowSize(visibleSize: CGSize(width: 1728, height: 1080)),
      CGSize(width: 990, height: 500))
    let small = AnnotateWindowController.initialWindowSize(visibleSize: CGSize(width: 800, height: 450))
    XCTAssertLessThanOrEqual(small.width, 800)
    XCTAssertLessThanOrEqual(small.height, 450)
  }

  @MainActor
  func testРедакторНеСужаетсяНижеМинимальнойШириныЭталона() throws {
    let controller = AnnotateWindowController()
    let window = try XCTUnwrap(controller.window)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    XCTAssertEqual(window.minSize.width, 990,
      "Живой CleanShot при запросе ширины 800 удерживает 990 точек, см. reference-minimum-frame.json")
    XCTAssertEqual(window.minSize.height, 450,
      "Минимум относится ко всему окну, включая системную строку заголовка")
  }

  @MainActor
  func testSecureСглаживаетМелкийРисунокИСохраняетКрупныеПереходы() throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let fixtureContext = try XCTUnwrap(CGContext(data: nil, width: 160, height: 80,
      bitsPerComponent: 8, bytesPerRow: 160 * 4, space: colorSpace, bitmapInfo: bitmapInfo))
    for x in 0..<160 {
      let detail: CGFloat = x.isMultiple(of: 2) ? 0.08 : -0.08
      fixtureContext.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace,
        components: [(x < 80 ? 0.9 : 0.1) + detail, 0.2, (x < 80 ? 0.1 : 0.9) + detail, 1])))
      fixtureContext.fill(CGRect(x: x, y: 0, width: 1, height: 80))
    }
    let fixtureBytes = try XCTUnwrap(fixtureContext.data).assumingMemoryBound(to: UInt8.self)
    XCTAssertGreaterThan(Int(fixtureBytes[20 * 4]) - Int(fixtureBytes[21 * 4]), 30,
      "Исходник должен содержать мелкие контрастные полосы")
    XCTAssertGreaterThan(Int(fixtureBytes[20 * 4]) - Int(fixtureBytes[140 * 4]), 150,
      "Исходник должен содержать крупный переход между красным и синим")
    let source = NSImage(cgImage: try XCTUnwrap(fixtureContext.makeImage()), size: CGSize(width: 160, height: 80))
    let image = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: UUID(),
      bounds: CGRect(x: 0, y: 0, width: 160, height: 80), sourceImage: source,
      blurType: .secure, effectValue: 10))
    let resultContext = try XCTUnwrap(CGContext(data: nil, width: 160, height: 80,
      bitsPerComponent: 8, bytesPerRow: 160 * 4, space: colorSpace, bitmapInfo: bitmapInfo))
    resultContext.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 80))
    let bytes = try XCTUnwrap(resultContext.data).assumingMemoryBound(to: UInt8.self)
    let left = (40 * 160 + 20) * 4
    let neighbor = (40 * 160 + 21) * 4
    let right = (40 * 160 + 140) * 4
    XCTAssertLessThanOrEqual(abs(Int(bytes[left]) - Int(bytes[neighbor])), 3)
    XCTAssertLessThanOrEqual(abs(Int(bytes[left + 2]) - Int(bytes[neighbor + 2])), 3)
    XCTAssertGreaterThan(Int(bytes[left]) - Int(bytes[right]), 100)
    XCTAssertGreaterThan(Int(bytes[right + 2]) - Int(bytes[left + 2]), 100)
    XCTAssertEqual(bytes[left + 3], 255)
    XCTAssertEqual(bytes[right + 3], 255)
  }

  @MainActor
  func testBlackOutНепрозраченИНеЗависитОтИсходногоЦвета() throws {
    let source = NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 20, height: 20)),
      size: CGSize(width: 20, height: 20))
    let black = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: UUID(),
      bounds: CGRect(x: 0, y: 0, width: 20, height: 20), sourceImage: source, blurType: .blackOut))
    let result = NSBitmapImageRep(cgImage: black)
    for y in 0..<20 {
      for x in 0..<20 {
        let color = try XCTUnwrap(result.colorAt(x: x, y: y))
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
      }
    }
  }
}
