import AppKit
import Combine
import SwiftUI

/// Компонент цвета в полях R, G, B и Alpha собственной панели Custom Color.
enum AnnotateColorComponent: CaseIterable {
  case red, green, blue, alpha

  /// Верхняя граница поля: RGB в 0…255, Alpha в процентах 0…100.
  var maximum: Int { self == .alpha ? 100 : 255 }
}

/// Сохранённый цвет ячейки «My Colors». Как ANColorStorage эталона хранит целые
/// компоненты: RGB 0…255 и Alpha в процентах 0…100.
nonisolated struct AnnotateSavedColor: Codable, Equatable {
  var red: Int
  var green: Int
  var blue: Int
  var alpha: Int

  init(red: Int, green: Int, blue: Int, alpha: Int) {
    self.red = min(max(red, 0), 255)
    self.green = min(max(green, 0), 255)
    self.blue = min(max(blue, 0), 255)
    self.alpha = min(max(alpha, 0), 100)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      red: try container.decodeIfPresent(Int.self, forKey: .red) ?? 0,
      green: try container.decodeIfPresent(Int.self, forKey: .green) ?? 0,
      blue: try container.decodeIfPresent(Int.self, forKey: .blue) ?? 0,
      alpha: try container.decodeIfPresent(Int.self, forKey: .alpha) ?? 100
    )
  }

  var rgba: RGBAColor {
    RGBAColor(red: Double(red) / 255, green: Double(green) / 255,
      blue: Double(blue) / 255, alpha: Double(alpha) / 100)
  }

  var color: Color { rgba.color }
}

/// Ячейки «My Colors», общие для всех окон редактора и всех инструментов.
/// Хранятся по индексам: удаление оставляет дырку, следующее добавление её занимает.
@MainActor
final class AnnotateSavedColorStore: ObservableObject {
  static let shared = AnnotateSavedColorStore()
  /// Ключ defaults совпадает с ключом эталона.
  static let defaultsKey = "annotateCustomColors"
  static let capacity = 10

  @Published private(set) var slots: [AnnotateSavedColor?]
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    slots = Self.load(from: defaults)
  }

  var isEmpty: Bool { slots.allSatisfy { $0 == nil } }

  /// Индекс занятой ячейки или nil, если все десять заняты.
  func add(_ color: AnnotateSavedColor) -> Int? {
    guard let slot = slots.firstIndex(where: { $0 == nil }) else { return nil }
    commit { $0[slot] = color }
    return slot
  }

  func set(_ color: AnnotateSavedColor, at slot: Int) {
    guard slots.indices.contains(slot) else { return }
    commit { $0[slot] = color }
  }

  func remove(at slot: Int) {
    guard slots.indices.contains(slot), slots[slot] != nil else { return }
    commit { $0[slot] = nil }
  }

  /// Перестановка ячеек перетаскиванием: элемент переезжает на новое место,
  /// остальные сдвигаются, пустые ячейки остаются пустыми.
  func move(from source: Int, to destination: Int) {
    guard source != destination, slots.indices.contains(source),
      slots.indices.contains(destination) else { return }
    commit {
      let value = $0.remove(at: source)
      $0.insert(value, at: destination)
    }
  }

  private func commit(_ change: (inout [AnnotateSavedColor?]) -> Void) {
    var next = slots
    change(&next)
    guard next != slots else { return }
    slots = next
    if isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey)
    } else if let data = try? JSONEncoder().encode(next) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }

  private static func load(from defaults: UserDefaults) -> [AnnotateSavedColor?] {
    let empty = [AnnotateSavedColor?](repeating: nil, count: capacity)
    guard let data = defaults.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([AnnotateSavedColor?].self, from: data) else { return empty }
    return Array((decoded + empty).prefix(capacity))
  }
}

/// HSB-представление текущего цвета панели. Хранится отдельно от RGB, чтобы
/// оттенок не терялся на сером и чёрном.
struct AnnotateColorPickerHSBA: Equatable {
  var hue: Double
  var saturation: Double
  var brightness: Double
  var alpha: Double

  init(hue: Double, saturation: Double, brightness: Double, alpha: Double) {
    self.hue = min(max(hue, 0), 1)
    self.saturation = min(max(saturation, 0), 1)
    self.brightness = min(max(brightness, 0), 1)
    self.alpha = min(max(alpha, 0), 1)
  }

  init(rgba: RGBAColor) {
    let maximum = max(rgba.red, rgba.green, rgba.blue)
    let minimum = min(rgba.red, rgba.green, rgba.blue)
    let delta = maximum - minimum
    var hue = 0.0
    if delta > 0 {
      if maximum == rgba.red {
        hue = (rgba.green - rgba.blue) / delta
      } else if maximum == rgba.green {
        hue = (rgba.blue - rgba.red) / delta + 2
      } else {
        hue = (rgba.red - rgba.green) / delta + 4
      }
      hue /= 6
      if hue < 0 { hue += 1 }
    }
    self.init(hue: hue, saturation: maximum > 0 ? delta / maximum : 0,
      brightness: maximum, alpha: rgba.alpha)
  }

  var rgba: RGBAColor {
    let h = (hue >= 1 ? 0 : hue) * 6
    let c = brightness * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = brightness - c
    let channels: (Double, Double, Double)
    switch Int(h) % 6 {
    case 0: channels = (c, x, 0)
    case 1: channels = (x, c, 0)
    case 2: channels = (0, c, x)
    case 3: channels = (0, x, c)
    case 4: channels = (x, 0, c)
    default: channels = (c, 0, x)
    }
    return RGBAColor(red: channels.0 + m, green: channels.1 + m, blue: channels.2 + m, alpha: alpha)
  }

  /// Чистый оттенок для фона спектра и бегунка Hue.
  var pureHue: Color {
    AnnotateColorPickerHSBA(hue: hue, saturation: 1, brightness: 1, alpha: 1).rgba.color
  }
}

/// Состояние собственной панели цвета: палитра 52×400, колонка «My Colors»
/// 86×400, раскрытый редактор 316×400 и откреплённая панель с полосой 15 pt.
@MainActor
final class AnnotateColorPickerModel: ObservableObject {
  enum AddResult: Equatable {
    case added(Int)
    case full
  }

  static let collapsedSize = NSSize(width: 52, height: 400)
  static let savedColumnSize = NSSize(width: 86, height: 400)
  static let expandedSize = NSSize(width: 316, height: 400)
  static let detachedStripHeight: CGFloat = 15

  @Published private(set) var rgba = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
  @Published private(set) var hsba = AnnotateColorPickerHSBA(hue: 0, saturation: 0, brightness: 0, alpha: 1)
  @Published private(set) var isExpanded = false
  @Published private(set) var isDetached = false
  @Published private(set) var selectedSavedSlot: Int?
  @Published private(set) var isEditingGesture = false

  let store: AnnotateSavedColorStore
  /// Новый цвет для аннотаций. Один вызов вне жеста – одна точка undo.
  var onColorChange: (Color) -> Void = { _ in }
  /// Начало и конец непрерывного жеста (спектр, Hue, Alpha): undo один на жест.
  var onEditingChanged: (Bool) -> Void = { _ in }
  var onLayoutChange: () -> Void = {}
  private var storeObservation: AnyCancellable?

  init(store: AnnotateSavedColorStore? = nil) {
    let store = store ?? .shared
    self.store = store
    storeObservation = store.$slots.dropFirst().sink { [weak self] _ in
      // Публикация срабатывает до записи нового значения, раскладку меняем следующим тиком.
      DispatchQueue.main.async { self?.onLayoutChange() }
      self?.objectWillChange.send()
    }
  }

  var slots: [AnnotateSavedColor?] { store.slots }
  var color: Color { rgba.color }
  var hasSavedColumn: Bool { isExpanded || !store.isEmpty }

  var panelSize: NSSize {
    let base = isExpanded ? Self.expandedSize : (hasSavedColumn ? Self.savedColumnSize : Self.collapsedSize)
    return NSSize(width: base.width, height: base.height + (isDetached ? Self.detachedStripHeight : 0))
  }

  /// Целые RGB, как в полях эталона: 0.25/0.84/0.32 показываются как 63/214/81.
  var rgbComponents: [Int] {
    [rgba.red, rgba.green, rgba.blue].map { Self.integer($0, scale: 255) }
  }
  var alphaPercentage: Int { Self.integer(rgba.alpha, scale: 100) }
  var hexText: String { rgbComponents.map { String(format: "%02X", $0) }.joined() }

  func value(of component: AnnotateColorComponent) -> Int {
    switch component {
    case .red: rgbComponents[0]
    case .green: rgbComponents[1]
    case .blue: rgbComponents[2]
    case .alpha: alphaPercentage
    }
  }

  /// Текущий цвет в виде сохраняемой ячейки, квантованный до целых RGB.
  var currentSavedColor: AnnotateSavedColor {
    let rgb = rgbComponents
    return AnnotateSavedColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alphaPercentage)
  }

  // MARK: Раскладка

  /// Новое открытие палитры начинается со свёрнутого прикреплённого состояния.
  func resetPresentation() {
    isExpanded = false
    isDetached = false
    selectedSavedSlot = nil
  }

  func setExpanded(_ expanded: Bool) {
    guard isExpanded != expanded else { return }
    isExpanded = expanded
    onLayoutChange()
  }

  func toggleExpanded() { setExpanded(!isExpanded) }

  func detach() {
    guard !isDetached else { return }
    isDetached = true
    onLayoutChange()
  }

  // MARK: Цвет

  /// Внешняя смена цвета (другой инструмент, выбор аннотации) без обратного вызова.
  func synchronize(_ color: Color) {
    guard !isEditingGesture, let next = RGBAColor(color: color), !Self.matches(next, rgba) else { return }
    replaceColor(next, notify: false)
  }

  func selectColor(_ color: Color) {
    guard let next = RGBAColor(color: color) else { return }
    replaceColor(next, notify: true)
  }

  func selectSavedColor(at slot: Int) {
    guard store.slots.indices.contains(slot), let value = store.slots[slot] else { return }
    replaceColor(value.rgba, notify: true)
    selectedSavedSlot = slot
  }

  func beginGesture() {
    guard !isEditingGesture else { return }
    isEditingGesture = true
    onEditingChanged(true)
  }

  func endGesture() {
    guard isEditingGesture else { return }
    isEditingGesture = false
    onEditingChanged(false)
  }

  func setSaturation(_ saturation: Double, brightness: Double) {
    updateHSBA(AnnotateColorPickerHSBA(hue: hsba.hue, saturation: saturation,
      brightness: brightness, alpha: hsba.alpha))
  }

  func setHue(_ hue: Double) {
    updateHSBA(AnnotateColorPickerHSBA(hue: hue, saturation: hsba.saturation,
      brightness: hsba.brightness, alpha: hsba.alpha))
  }

  func setAlpha(_ alpha: Double) {
    updateHSBA(AnnotateColorPickerHSBA(hue: hsba.hue, saturation: hsba.saturation,
      brightness: hsba.brightness, alpha: alpha))
  }

  func updateHSBA(_ value: AnnotateColorPickerHSBA) {
    guard value != hsba else { return }
    selectedSavedSlot = nil
    hsba = value
    rgba = value.rgba
    onColorChange(color)
  }

  /// Hex: с # и без, 3, 6 или 8 символов (8 – с прозрачностью). Неверный ввод не применяется.
  @discardableResult
  func applyHex(_ text: String) -> Bool {
    guard let parsed = Self.parseHex(text) else { return false }
    let next = RGBAColor(red: Double(parsed.red) / 255, green: Double(parsed.green) / 255,
      blue: Double(parsed.blue) / 255, alpha: parsed.alpha.map { Double($0) / 255 } ?? rgba.alpha)
    guard !Self.matches(next, rgba) else { return true }
    replaceColor(next, notify: true)
    return true
  }

  /// Поля R, G, B и Alpha: целое число, выход за диапазон прижимается к границе.
  @discardableResult
  func applyComponent(_ component: AnnotateColorComponent, text: String) -> Bool {
    guard let value = Self.parseComponent(text, maximum: component.maximum) else { return false }
    var rgb = rgbComponents
    var alpha = alphaPercentage
    switch component {
    case .red: rgb[0] = value
    case .green: rgb[1] = value
    case .blue: rgb[2] = value
    case .alpha: alpha = value
    }
    let next = AnnotateSavedColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha).rgba
    guard !Self.matches(next, rgba) else { return true }
    replaceColor(next, notify: true)
    return true
  }

  // MARK: My Colors

  @discardableResult
  func addCurrentColor() -> AddResult {
    guard let slot = store.add(currentSavedColor) else { return .full }
    return .added(slot)
  }

  func updateSlotWithCurrentColor(_ slot: Int) {
    store.set(currentSavedColor, at: slot)
  }

  func removeColor(at slot: Int) {
    if selectedSavedSlot == slot { selectedSavedSlot = nil }
    store.remove(at: slot)
  }

  func moveSlot(from source: Int, to destination: Int) {
    store.move(from: source, to: destination)
    if selectedSavedSlot == source { selectedSavedSlot = destination }
  }

  // MARK: Разбор ввода

  /// Hex эталона: принимаются только 6 и 8 знаков. Три знака не раскрываются в пары
  /// и отклоняются, у восьми последние два игнорируются – Alpha остаётся прежней (ANN-206).
  nonisolated static func parseHex(_ text: String) -> (red: Int, green: Int, blue: Int, alpha: Int?)? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard [6, 8].contains(value.count), value.allSatisfy(\.isHexDigit),
      let number = UInt32(value.prefix(6), radix: 16) else { return nil }
    return (Int((number >> 16) & 255), Int((number >> 8) & 255), Int(number & 255), nil)
  }

  nonisolated static func parseComponent(_ text: String, maximum: Int) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return min(max(value, 0), maximum)
  }

  /// Ввод поля Hex: только шестнадцатеричные символы, не длиннее 8 (аналог HexOnlyValueFormatter).
  nonisolated static func sanitizedHexInput(_ text: String) -> String {
    String(text.uppercased().filter(\.isHexDigit).prefix(8))
  }

  // MARK: Внутреннее

  private func replaceColor(_ next: RGBAColor, notify: Bool) {
    selectedSavedSlot = nil
    rgba = next
    let rgb = rgbComponents
    var normalized = AnnotateColorPickerHSBA(rgba: RGBAColor(red: Double(rgb[0]) / 255,
      green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255, alpha: next.alpha))
    // На сером и чёрном оттенок и насыщенность не определены, сохраняем прежние.
    if normalized.saturation == 0 { normalized.hue = hsba.hue }
    if normalized.brightness == 0 {
      normalized.hue = hsba.hue
      normalized.saturation = hsba.saturation
    }
    hsba = normalized
    if notify { onColorChange(color) }
  }

  private static func integer(_ value: Double, scale: Int) -> Int {
    min(max(Int((value * Double(scale) + 0.0000001).rounded(.down)), 0), scale)
  }

  private static func matches(_ a: RGBAColor, _ b: RGBAColor) -> Bool {
    abs(a.red - b.red) < 0.000001 && abs(a.green - b.green) < 0.000001
      && abs(a.blue - b.blue) < 0.000001 && abs(a.alpha - b.alpha) < 0.000001
  }
}

/// Размещение панели у якоря с учётом краёв экрана.
enum AnnotateColorPalettePlacement {
  static let gap: CGFloat = 12
  static let anchorInset: CGFloat = 26

  /// Левый верхний угол стоит под центром кнопки цвета. Если снизу не хватает
  /// места, панель встаёт над кнопкой, а по горизонтали прижимается к видимой области.
  static func frame(anchor: NSRect, size: NSSize, visibleFrame: NSRect?) -> NSRect {
    var frame = NSRect(x: anchor.midX - anchorInset, y: anchor.minY - gap - size.height,
      width: size.width, height: size.height)
    guard let visible = visibleFrame else { return frame }
    if frame.minY < visible.minY {
      let above = anchor.maxY + gap
      frame.origin.y = above + size.height <= visible.maxY ? above : visible.minY
    }
    frame.origin.y = min(frame.origin.y, visible.maxY - size.height)
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - size.width)
    return frame
  }

  /// Новая рамка при смене размера: левый верхний угол остаётся на месте,
  /// но панель не уезжает за видимую область.
  static func resized(_ frame: NSRect, to size: NSSize, visibleFrame: NSRect?) -> NSRect {
    var next = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    guard let visible = visibleFrame else { return next }
    next.origin.x = min(max(next.origin.x, visible.minX), visible.maxX - size.width)
    next.origin.y = min(max(next.origin.y, visible.minY), visible.maxY - size.height)
    return next
  }
}
