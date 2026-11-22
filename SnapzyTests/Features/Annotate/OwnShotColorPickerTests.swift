import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotColorPickerTests: XCTestCase {
  private func makeDefaults() -> UserDefaults {
    let name = "ownshot.color-picker.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
    return defaults
  }

  private func makeModel(defaults: UserDefaults? = nil) -> AnnotateColorPickerModel {
    AnnotateColorPickerModel(store: AnnotateSavedColorStore(defaults: defaults ?? makeDefaults()))
  }

  private let green = Color(.sRGB, red: 0.25, green: 0.84, blue: 0.32, opacity: 1)

  func testПанельРаскрываетсяДо316ИОставляетКолонкуСохранённыхЦветов() {
    let model = makeModel()
    XCTAssertEqual(model.panelSize, NSSize(width: 52, height: 400))
    model.setExpanded(true)
    XCTAssertEqual(model.panelSize, NSSize(width: 316, height: 400))
    XCTAssertEqual(model.addCurrentColor(), .added(0))
    model.setExpanded(false)
    XCTAssertEqual(model.panelSize, NSSize(width: 86, height: 400))
    model.removeColor(at: 0)
    XCTAssertEqual(model.panelSize, NSSize(width: 52, height: 400))
  }

  func testОткреплённаяПалитраПолучаетСтрокуЗакрытияВысотой15ИСбрасываетсяПриНовомОткрытии() {
    let model = makeModel()
    model.setExpanded(true)
    model.detach()
    XCTAssertTrue(model.isDetached)
    XCTAssertEqual(model.panelSize, NSSize(width: 316, height: 415))
    model.resetPresentation()
    XCTAssertFalse(model.isDetached)
    XCTAssertFalse(model.isExpanded)
    XCTAssertEqual(model.panelSize, NSSize(width: 52, height: 400))
  }

  func testРедакторПоказываетЦелыеКомпонентыИHSVКакЭталон() {
    let model = makeModel()
    model.synchronize(green)
    XCTAssertEqual(model.hexText, "3FD651")
    XCTAssertEqual(model.rgbComponents, [63, 214, 81])
    XCTAssertEqual(model.alphaPercentage, 100)
    XCTAssertEqual(model.hsba.hue, 0.353200883, accuracy: 0.00001)
    XCTAssertEqual(model.hsba.saturation, 0.705607477, accuracy: 0.00001)
    XCTAssertEqual(model.hsba.brightness, 0.839215686, accuracy: 0.00001)
  }

  func testHexПрименяетсяОдинРазИНеверныйВводОтклоняется() {
    let model = makeModel()
    var updates = 0
    model.onColorChange = { _ in updates += 1 }
    XCTAssertTrue(model.applyHex("112233"))
    XCTAssertEqual(model.rgbComponents, [17, 34, 51])
    XCTAssertTrue(model.applyHex("#112233"))
    XCTAssertEqual(updates, 1, "повтор того же значения не меняет цвет и не пишет undo")
    for invalid in ["", "xyz", "12", "1234", "12345G", "#"] {
      XCTAssertFalse(model.applyHex(invalid), invalid)
    }
    XCTAssertEqual(model.hexText, "112233")
    XCTAssertEqual(updates, 1)
  }

  func testHexТриЗнакаОтклоняетсяВосемьНеМеняютAlpha() {
    // ANN-206: у эталона «123» возвращает прежний цвет, «33669980» даёт 336699 и Alpha 100.
    let model = makeModel()
    XCTAssertTrue(model.applyHex("112233"))
    XCTAssertFalse(model.applyHex("#abc"))
    XCTAssertFalse(model.applyHex("123"))
    XCTAssertEqual(model.rgbComponents, [17, 34, 51])
    XCTAssertTrue(model.applyHex("33669980"))
    XCTAssertEqual(model.rgbComponents, [51, 102, 153])
    XCTAssertEqual(model.alphaPercentage, 100)
    XCTAssertTrue(model.applyComponent(.alpha, text: "40"))
    XCTAssertTrue(model.applyHex("#FF000000"))
    XCTAssertEqual(model.rgbComponents, [255, 0, 0])
    XCTAssertEqual(model.alphaPercentage, 40, "последние два знака не трогают прозрачность")
    for invalid in ["", "фыв", "12345", "абвгде", "1234567"] {
      XCTAssertFalse(model.applyHex(invalid), invalid)
      XCTAssertNil(AnnotateColorPickerModel.parseHex(invalid), invalid)
    }
    XCTAssertEqual(model.rgbComponents, [255, 0, 0])
    XCTAssertEqual(AnnotateColorPickerModel.sanitizedHexInput("#3fd6-51zz99"), "3FD65199")
  }

  func testRGBИПрозрачностьОграниченыДиапазоном() {
    let model = makeModel()
    XCTAssertTrue(model.applyHex("112233"))
    XCTAssertTrue(model.applyComponent(.red, text: "300"))
    XCTAssertTrue(model.applyComponent(.green, text: "-5"))
    XCTAssertTrue(model.applyComponent(.alpha, text: " 133 "))
    XCTAssertEqual(model.rgbComponents, [255, 0, 51])
    XCTAssertEqual(model.alphaPercentage, 100)
    XCTAssertTrue(model.applyComponent(.alpha, text: "33"))
    XCTAssertEqual(model.alphaPercentage, 33)
    XCTAssertFalse(model.applyComponent(.blue, text: ""))
    XCTAssertFalse(model.applyComponent(.blue, text: "1a"))
    XCTAssertEqual(model.rgbComponents, [255, 0, 51])
    XCTAssertEqual(AnnotateColorPaletteView.sanitizedNumberInput("2-5x5"), "255")
    XCTAssertEqual(AnnotateColorPaletteView.sanitizedNumberInput("-12"), "-12")
  }

  func testЖестСпектраДаётОднуПаруНачалоКонецИОттенокНаЧёрномСохраняется() {
    let model = makeModel()
    model.synchronize(green)
    var editing: [Bool] = []
    var updates = 0
    model.onEditingChanged = { editing.append($0) }
    model.onColorChange = { _ in updates += 1 }
    model.beginGesture()
    model.setSaturation(1, brightness: 1)
    model.beginGesture()
    model.setSaturation(0.5, brightness: 0)
    model.synchronize(.red)
    model.endGesture()
    model.endGesture()
    XCTAssertEqual(editing, [true, false])
    XCTAssertEqual(updates, 2)
    XCTAssertEqual(model.rgbComponents, [0, 0, 0], "внешняя синхронизация во время жеста игнорируется")
    XCTAssertEqual(model.hsba.hue, 0.353200883, accuracy: 0.00001)
    model.synchronize(.black)
    XCTAssertEqual(model.hsba.hue, 0.353200883, accuracy: 0.00001)
    XCTAssertEqual(model.hsba.saturation, 0.5, accuracy: 0.00001)
  }

  func testHueИAlphaМеняютЦветБезПотериНасыщенности() {
    let model = makeModel()
    model.synchronize(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
    model.setHue(1.0 / 3)
    XCTAssertEqual(model.rgbComponents, [0, 255, 0])
    model.setAlpha(0.5)
    XCTAssertEqual(model.alphaPercentage, 50)
    XCTAssertEqual(model.currentSavedColor, AnnotateSavedColor(red: 0, green: 255, blue: 0, alpha: 50))
  }

  func testДубликатыЗанимаютОтдельныеЯчейкиИОсвободившеесяМестоИспользуетсяСнова() {
    let model = makeModel()
    _ = model.applyHex("112233")
    XCTAssertEqual(model.addCurrentColor(), .added(0))
    XCTAssertEqual(model.addCurrentColor(), .added(1))
    XCTAssertEqual(model.slots.compactMap { $0 }.count, 2)
    model.removeColor(at: 0)
    XCTAssertNil(model.slots[0])
    XCTAssertNotNil(model.slots[1])
    _ = model.applyHex("AABBCC")
    XCTAssertEqual(model.addCurrentColor(), .added(0))
    XCTAssertEqual(model.slots[0], AnnotateSavedColor(red: 170, green: 187, blue: 204, alpha: 100))
    XCTAssertEqual(model.slots[1], AnnotateSavedColor(red: 17, green: 34, blue: 51, alpha: 100))
  }

  func testСохранённыйЦветКвантуетсяДоЦелыхRGBИВыбираетсяИзЯчейки() {
    let model = makeModel()
    model.synchronize(green)
    XCTAssertEqual(model.addCurrentColor(), .added(0))
    XCTAssertEqual(model.slots[0], AnnotateSavedColor(red: 63, green: 214, blue: 81, alpha: 100))
    var selected: Color?
    model.onColorChange = { selected = $0 }
    _ = model.applyHex("000000")
    model.selectSavedColor(at: 0)
    XCTAssertEqual(model.selectedSavedSlot, 0)
    let rgba = try? XCTUnwrap(selected.flatMap { RGBAColor(color: $0) })
    XCTAssertEqual(rgba?.green ?? 0, 214.0 / 255, accuracy: 0.000001)
    model.selectSavedColor(at: 5)
    XCTAssertEqual(model.selectedSavedSlot, 0, "пустая ячейка не выбирается")
  }

  func testОдиннадцатыйЦветНеЗаменяетСуществующиеИСохранениеПереживаетНовыйЭкземпляр() {
    let defaults = makeDefaults()
    let model = makeModel(defaults: defaults)
    for index in 0..<10 { XCTAssertEqual(model.addCurrentColor(), .added(index)) }
    let before = model.slots
    XCTAssertEqual(model.addCurrentColor(), .full)
    XCTAssertEqual(model.slots, before)
    XCTAssertNotNil(defaults.data(forKey: "annotateCustomColors"))
    XCTAssertEqual(AnnotateSavedColorStore(defaults: defaults).slots, before)
  }

  func testUpdateWithCurrentColorИПерестановкаЯчеек() {
    let defaults = makeDefaults()
    let model = makeModel(defaults: defaults)
    _ = model.applyHex("111111"); _ = model.addCurrentColor()
    _ = model.applyHex("222222"); _ = model.addCurrentColor()
    _ = model.applyHex("333333"); _ = model.addCurrentColor()
    _ = model.applyHex("ABCDEF")
    model.updateSlotWithCurrentColor(1)
    XCTAssertEqual(model.slots[1], AnnotateSavedColor(red: 171, green: 205, blue: 239, alpha: 100))
    model.updateSlotWithCurrentColor(4)
    XCTAssertEqual(model.slots[4], AnnotateSavedColor(red: 171, green: 205, blue: 239, alpha: 100))
    model.moveSlot(from: 0, to: 2)
    XCTAssertEqual(model.slots[0]?.red, 171)
    XCTAssertEqual(model.slots[1]?.red, 51)
    XCTAssertEqual(model.slots[2]?.red, 17)
    XCTAssertNil(model.slots[3])
    XCTAssertEqual(AnnotateSavedColorStore(defaults: defaults).slots, model.slots, "порядок сохраняется")
  }

  func testОбщийСторВидитЦветаИзДругогоОкнаИОчисткаУдаляетКлюч() {
    let defaults = makeDefaults()
    let store = AnnotateSavedColorStore(defaults: defaults)
    let first = AnnotateColorPickerModel(store: store)
    let second = AnnotateColorPickerModel(store: store)
    _ = first.applyHex("102030")
    XCTAssertEqual(first.addCurrentColor(), .added(0))
    XCTAssertEqual(second.slots[0], AnnotateSavedColor(red: 16, green: 32, blue: 48, alpha: 100))
    XCTAssertEqual(second.panelSize, NSSize(width: 86, height: 400))
    second.removeColor(at: 0)
    XCTAssertNil(defaults.object(forKey: AnnotateSavedColorStore.defaultsKey))
  }

  func testПовреждённыеИНеполныеДанныеНеЛомаютЗагрузку() throws {
    let defaults = makeDefaults()
    defaults.set(Data("not json".utf8), forKey: AnnotateSavedColorStore.defaultsKey)
    XCTAssertEqual(AnnotateSavedColorStore(defaults: defaults).slots.count, 10)
    let partial = #"[{"red":300,"green":10}, null]"#
    defaults.set(Data(partial.utf8), forKey: AnnotateSavedColorStore.defaultsKey)
    let store = AnnotateSavedColorStore(defaults: defaults)
    XCTAssertEqual(store.slots.count, 10)
    XCTAssertEqual(store.slots[0], AnnotateSavedColor(red: 255, green: 10, blue: 0, alpha: 100))
    XCTAssertNil(store.slots[1])
  }

  func testПалитраВстаётПодКнопкойИНеУходитЗаКраяЭкрана() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let anchor = NSRect(x: 1000, y: 700, width: 40, height: 26)
    let normal = AnnotateColorPalettePlacement.frame(anchor: anchor,
      size: NSSize(width: 52, height: 400), visibleFrame: visible)
    XCTAssertEqual(normal, NSRect(x: 994, y: 288, width: 52, height: 400))

    let right = AnnotateColorPalettePlacement.frame(anchor: NSRect(x: 1400, y: 700, width: 40, height: 26),
      size: NSSize(width: 316, height: 400), visibleFrame: visible)
    XCTAssertEqual(right.maxX, visible.maxX)

    let left = AnnotateColorPalettePlacement.frame(anchor: NSRect(x: 0, y: 700, width: 20, height: 26),
      size: NSSize(width: 52, height: 400), visibleFrame: visible)
    XCTAssertEqual(left.minX, visible.minX)

    let bottom = AnnotateColorPalettePlacement.frame(anchor: NSRect(x: 500, y: 200, width: 40, height: 26),
      size: NSSize(width: 52, height: 400), visibleFrame: visible)
    XCTAssertEqual(bottom.minY, 238, "снизу места нет: панель над кнопкой")

    let tight = AnnotateColorPalettePlacement.frame(anchor: NSRect(x: 500, y: 300, width: 40, height: 26),
      size: NSSize(width: 52, height: 700), visibleFrame: visible)
    XCTAssertGreaterThanOrEqual(tight.minY, visible.minY)
    XCTAssertLessThanOrEqual(tight.maxY, visible.maxY)

    let resized = AnnotateColorPalettePlacement.resized(NSRect(x: 100, y: 100, width: 52, height: 400),
      to: NSSize(width: 316, height: 415), visibleFrame: visible)
    XCTAssertEqual(resized, NSRect(x: 100, y: 85, width: 316, height: 415), "левый верхний угол на месте")
  }

  func testКонтроллерПередаётЖестИЦветВUndoAnnotateState() {
    let controller = AnnotateColorPaletteController(store: AnnotateSavedColorStore(defaults: makeDefaults()))
    var editing: [Bool] = []
    var colors: [Color] = []
    controller.onEditingChanged = { editing.append($0) }
    controller.onSelect = { colors.append($0) }
    controller.color = green
    XCTAssertTrue(colors.isEmpty, "внешний цвет не возвращается обратно")
    controller.model.beginGesture()
    controller.model.setHue(0.1)
    controller.model.setHue(0.2)
    controller.model.endGesture()
    XCTAssertEqual(editing, [true, false])
    XCTAssertEqual(colors.count, 2)
    controller.invalidate()
    controller.model.setHue(0.3)
    XCTAssertEqual(colors.count, 2)
  }
}
