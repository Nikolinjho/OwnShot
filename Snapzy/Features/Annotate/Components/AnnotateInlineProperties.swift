import SwiftUI

struct AnnotateInlineProperties: View {
  @ObservedObject var state: AnnotateState
  @State private var showsColor = false
  @State private var showsThickness = false
  @State private var showsArrow = false
  @State private var showsRedaction = false
  @State private var showsOther = false
  @State private var showsCounter = false
  /// Secure и Blur (smooth) у эталона показывают силу 3…30; smooth хранит её
  /// в strokeWidth той же шкалой, что и Secure (ANN-109).
  private var usesStrengthSlider: Bool {
    state.activeBlurType == .secure || state.activeBlurType == .gaussian
  }

  private var usesReferenceRedactionSize: Bool {
    usesStrengthSlider || state.activeBlurType == .pixelated
  }

  var redactionSizeBinding: Binding<CGFloat> {
    if state.activeBlurType == .pixelated {
      // ANN-722…725: интерфейс 3…30, прежний документ и рендер Pixelate 1…25.
      // Меняем только представление значения, сохраняя размер блоков существующих масок.
      let stored = AnnotationProperties.controlValueRange
      let displayed = BlurEffectRenderer.smoothBlurStrengthRange
      let ratio = (displayed.upperBound - displayed.lowerBound) / (stored.upperBound - stored.lowerBound)
      return Binding(
        get: { displayed.lowerBound + (AnnotationProperties.clampedControlValue(
          state.quickStrokeWidthBinding.wrappedValue) - stored.lowerBound) * ratio },
        set: { value in
          let clamped = min(max(value, displayed.lowerBound), displayed.upperBound)
          state.quickStrokeWidthBinding.wrappedValue = stored.lowerBound + (clamped - displayed.lowerBound) / ratio
        }
      )
    }
    guard usesStrengthSlider else { return state.quickStrokeWidthBinding }
    return Binding(
      get: { AnnotationProperties.secureBlurStrength(for: state.quickStrokeWidthBinding.wrappedValue) },
      set: { state.quickStrokeWidthBinding.wrappedValue = AnnotationProperties.secureBlurControlValue(for: $0) }
    )
  }

  var redactionSizeRange: ClosedRange<CGFloat> {
    usesReferenceRedactionSize ? BlurEffectRenderer.smoothBlurStrengthRange : AnnotationProperties.controlValueRange
  }

  static let palette: [(String, Color)] = [
    ("Black", Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)),
    ("Red", Color(.sRGB, red: 0.976, green: 0.204, blue: 0.259, opacity: 1)),
    ("Orange", Color(.sRGB, red: 1, green: 0.549, blue: 0, opacity: 1)),
    ("Yellow", Color(.sRGB, red: 1, green: 0.882, blue: 0, opacity: 1)),
    ("Green", Color(.sRGB, red: 0.25, green: 0.84, blue: 0.32, opacity: 1)),
    ("Cyan", Color(.sRGB, red: 0.18, green: 0.81, blue: 0.76, opacity: 1)),
    ("Blue", Color(.sRGB, red: 0, green: 0.48, blue: 1, opacity: 1)),
    ("Purple", Color(.sRGB, red: 0.54, green: 0.32, blue: 1, opacity: 1)),
    ("Pink", Color(.sRGB, red: 0.999, green: 0.18, blue: 0.42, opacity: 1)),
    ("White", Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)),
  ]

  static let selectionRingLight: [String: Color] = [
    "Red": OwnShotEditorChrome.color(0xDFB7B8),
    "Black": OwnShotEditorChrome.color(0xACACAC),
    "Orange": OwnShotEditorChrome.color(0xDFC7B3),
    "Yellow": OwnShotEditorChrome.color(0xDED8B7),
    "Green": OwnShotEditorChrome.color(0xBCD6BD),
    "Cyan": OwnShotEditorChrome.color(0xBAD5D2),
    "Blue": OwnShotEditorChrome.color(0xB2C4E0),
    "Purple": OwnShotEditorChrome.color(0xC7BCE0),
    "Pink": OwnShotEditorChrome.color(0xE1B6C0),
    "White": OwnShotEditorChrome.color(0xDEDEDE),
  ]

  var body: some View {
    HStack(spacing: 4) {
      if state.quickPropertiesSupportsStrokeColor {
        Button { showsColor.toggle() } label: {
          HStack(spacing: 5) {
            Circle().fill(state.quickStrokeColorBinding.wrappedValue)
              .overlay(Circle().stroke(.white, lineWidth: 1))
              .frame(width: 14, height: 14)
            chevron
          }
          .padding(.horizontal, 6).frame(width: 42, height: 28)
          .modifier(OwnShotEditorCapsule())
        }
        .buttonStyle(.plain).help("Color").accessibilityLabel("Color")
        // Своя панель Custom Color вместо NSColorPanel: жест спектра/Hue/Alpha – одна точка undo.
        .background(AnnotateColorPaletteAnchor(isPresented: $showsColor,
          color: state.quickStrokeColorBinding.wrappedValue,
          onEditingChanged: state.setQuickPropertiesControlEditing,
          onSelect: { color in
            state.quickStrokeColorBinding.wrappedValue = color
          }))
      }
      if state.quickPropertiesSupportsBlurType {
        HStack(spacing: usesReferenceRedactionSize ? 9 : 6) {
          capsule("Redaction style", icon: state.activeBlurType.icon) { showsRedaction.toggle() }
            .background(AnnotateRedactionMenuAnchor(isPresented: $showsRedaction,
              selectedType: state.activeBlurType) { type in
                state.quickBlurTypeBinding.wrappedValue = type
              })
          if state.activeBlurType != .blackOut {
            Slider(value: redactionSizeBinding,
              in: redactionSizeRange,
              onEditingChanged: state.setQuickPropertiesControlEditing)
              // ANN-722…749: нативный AX эталона фиксирует 102×16 pt.
              .labelsHidden()
              .frame(width: usesReferenceRedactionSize ? 102 : 80, height: usesReferenceRedactionSize ? 16 : 14)
              .controlSize(usesReferenceRedactionSize ? .regular : .small)
              .help("Size").accessibilityLabel("Redaction size")
              .accessibilityValue(state.activeBlurType == .gaussian || state.activeBlurType == .pixelated
                ? "\(Int(redactionSizeBinding.wrappedValue.rounded()))" : state.quickStrokeWidthDisplayText)
          }
        }
      } else if state.quickPropertiesTool == .counter {
        // Counter эталона: Color, Thickness, Counter settings (spec-039 editor-tool-counter.json).
        // У ANCounter одно поле thickness, поэтому Thickness и Size меняют одно значение.
        thicknessCapsule
        capsule(Self.counterSettingsTitle, icon: "list.number") { showsCounter.toggle() }
          .background(AnnotateCounterMenuAnchor(isPresented: $showsCounter,
            configuration: counterMenuConfiguration))
      } else if state.quickPropertiesSupportsStrokeWidth {
        thicknessCapsule
      }
      // Font size и Text style у Text, форма и слайдер у Spotlight, Lock canvas у Draw/Highlighter.
      if AnnotateInlineToolControls.hasControls(for: state) {
        AnnotateInlineToolControls(state: state)
      }
      if state.quickPropertiesSupportsArrowStyle {
        Button { showsArrow.toggle() } label: {
          HStack(spacing: 5) {
            AnnotateArrowPresetGlyph(preset: state.activeArrowPreset).frame(width: 14, height: 16)
            chevron
          }.padding(.horizontal, 6).frame(width: 42, height: 28)
            .modifier(OwnShotEditorCapsule())
        }
        .buttonStyle(.plain).help("Arrow style").accessibilityLabel("Arrow style")
        .background(AnnotateArrowMenuAnchor(isPresented: $showsArrow, selectedPreset: state.activeArrowPreset) { preset in
          state.setArrowPreset(preset)
        })
        .contextMenu {
          Menu("Geometry") {
            ForEach(ArrowStyle.allCases) { style in
              Button(style.displayName) { state.setActiveArrowStyle(style) }
            }
          }
          Menu("Display") {
            ForEach(ArrowType.allCases) { type in
              Button(type.displayName) { state.setActiveArrowType(type) }
            }
          }
          Menu("Start Head") {
            ForEach(ArrowEndpointStyle.allCases) { head in
              Button(head.displayName) { state.setActiveArrowStartHead(head) }
            }
          }
          Menu("End Head") {
            ForEach(ArrowEndpointStyle.allCases) { head in
              Button(head.displayName) { state.setActiveArrowEndHead(head) }
            }
          }
        }
      } else if !state.quickPropertiesSupportsBlurType {
        otherProperties
      }
    }.fixedSize()
  }

  /// Подсказка кнопки меню Counter у эталона – Counter settings.
  static let counterSettingsTitle = "Counter settings"

  private var thicknessCapsule: some View {
    capsule("Thickness", icon: "line.diagonal") { showsThickness.toggle() }
      .background(AnnotateThicknessMenuAnchor(isPresented: $showsThickness,
        selectedWidth: state.quickStrokeWidthBinding.wrappedValue) { width in
          state.quickStrokeWidthBinding.wrappedValue = width
        })
  }

  private var counterMenuConfiguration: AnnotateCounterMenuController.Configuration {
    AnnotateCounterMenuController.Configuration(
      format: state.activeCounterFormat,
      startingNumber: state.counterStartingNumber,
      size: state.activeCounterSize,
      onFormat: { [state] in state.setActiveCounterFormat($0) },
      onStartingNumber: { [state] in state.setCounterStartingNumber($0) },
      onSize: { [state] in state.setCounterSize($0) }
    )
  }

  private var chevron: some View {
    OwnShotIcons.image("annotateChevron").renderingMode(.template).foregroundStyle(.secondary)
  }

  private var redactionResourceName: String {
    switch state.activeBlurType {
    case .pixelated: "annotatePixelateStylePixelate-small"
    case .secure: "annotatePixelateStyleSecureBlur-small"
    case .blackOut: "annotatePixelateStyleBlackOut-small"
    default: "annotatePixelateStyleBlur-small"
    }
  }

  private func capsule(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if title == "Thickness" {
          OwnShotIcons.image("annotateLineTool").renderingMode(.template)
            .frame(width: 14, height: 16)
        } else if title == "Redaction style" {
          OwnShotIcons.image(redactionResourceName).renderingMode(.template)
        } else if title == Self.counterSettingsTitle {
          // annotateCounterSettings эталона: «123..», 22×14 pt.
          OwnShotIcons.image("annotateCounterSettings").renderingMode(.template).frame(width: 22, height: 14)
        } else {
          Image(systemName: icon).font(.system(size: 14))
        }
        chevron
      }.padding(.horizontal, title == Self.counterSettingsTitle ? 3 : 6).frame(width: 42, height: 28)
        .modifier(OwnShotEditorCapsule())
    }.buttonStyle(.plain).help(title).accessibilityLabel(title)
  }

  private var otherProperties: some View {
    Menu {
      if state.quickPropertiesSupportsLineStyle {
        ForEach(LineDashStyle.allCases) { style in
          Button(style.displayName) { state.quickLineStyleBinding.wrappedValue = style }
        }
      }
      Button("More Properties…") { showsOther = true }
    } label: { Image(systemName: "ellipsis") }
    .menuStyle(.borderlessButton).frame(width: 20).help("Tool Properties")
    .popover(isPresented: $showsOther) {
      AnnotateQuickPropertiesBar(state: state).frame(width: 740, height: 48).padding(12)
        .modifier(AnnotatePopoverEscape(isPresented: $showsOther))
    }
  }
}

private struct AnnotatePopoverEscape: ViewModifier {
  @Binding var isPresented: Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content.onAppear {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.keyCode == 53 else { return event }
        isPresented = false
        return nil
      }
    }.onDisappear {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

private struct AnnotateArrowPresetGlyph: View {
  let preset: AnnotateArrowPreset
  var isMenuPreview = false

  var body: some View {
    OwnShotIcons.image(resourceName).renderingMode(.template)
  }

  private var resourceName: String {
    let prefix = isMenuPreview ? "annotateArrowStyle" : "annotateArrowStyleButton"
    let suffix = switch preset {
    case .standard: "Standard"
    case .fancy: "Fancy"
    case .curved: "Curved"
    case .double: "Double"
    }
    return prefix + suffix
  }
}

@MainActor
final class AnnotateRedactionMenuController: NSObject {
  var onSelect: (BlurType) -> Void
  var selectedType: BlurType = .pixelated
  var isTracking = false

  init(onSelect: @escaping (BlurType) -> Void) { self.onSelect = onSelect }

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.font = .systemFont(ofSize: 14)
    menu.minimumWidth = 147
    let resources = ["Pixelate", "SecureBlur", "Blur", "BlackOut"]
    for (index, type) in BlurType.redactionTypes.enumerated() {
      let item = NSMenuItem(title: type.displayName, action: #selector(selectType(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
      let image = OwnShotIcons.nsImage("annotatePixelateStyle" + resources[index])
      item.image = AnnotateMenuImage.make(image, emphasized: type == selectedType)
      menu.addItem(item)
    }
    return menu
  }

  @objc private func selectType(_ sender: NSMenuItem) {
    guard BlurType.redactionTypes.indices.contains(sender.tag) else { return }
    onSelect(BlurType.redactionTypes[sender.tag])
  }
}

private struct AnnotateRedactionMenuAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  let selectedType: BlurType
  let onSelect: (BlurType) -> Void

  func makeCoordinator() -> AnnotateRedactionMenuController {
    AnnotateRedactionMenuController(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> NSView { MenuAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelect = onSelect
    coordinator.selectedType = selectedType
    guard isPresented, !coordinator.isTracking else { return }
    coordinator.isTracking = true
    DispatchQueue.main.async {
      defer {
        coordinator.isTracking = false
        isPresented = false
      }
      guard isPresented, view.window != nil else { return }
      coordinator.makeMenu().popUp(positioning: nil,
        at: NSPoint(x: -10, y: view.bounds.maxY - 3), in: view)
    }
  }

  private final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

@MainActor
private enum AnnotateMenuImage {
  static func make(_ original: NSImage?, emphasized: Bool) -> NSImage? {
    guard let original else { return nil }
    let image = NSImage(size: original.size, flipped: false) { rect in
      NSGraphicsContext.saveGraphicsState()
      original.draw(in: rect, from: .zero, operation: .sourceOver, fraction: emphasized ? 1 : 0.3)
      NSGraphicsContext.current?.compositingOperation = .sourceIn
      NSColor.labelColor.setFill()
      NSBezierPath(rect: rect).fill()
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    image.isTemplate = false
    return image
  }

}

@MainActor
final class AnnotateThicknessMenuController: NSObject {
  var onSelect: (CGFloat) -> Void
  var selectedWidth: CGFloat = 7
  var isTracking = false

  init(onSelect: @escaping (CGFloat) -> Void) { self.onSelect = onSelect }

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.minimumWidth = 61
    for (index, width) in [1, 3, 7, 10, 15, 25].enumerated() {
      let item = NSMenuItem(title: "", action: #selector(selectWidth(_:)), keyEquivalent: "")
      item.target = self
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
      item.tag = width
      item.toolTip = "\(width) px"
      item.setAccessibilityLabel("\(width) px")
      item.image = thicknessImage(index: index, emphasized: CGFloat(width) == selectedWidth)
      menu.addItem(item)
    }
    return menu
  }

  private func thicknessImage(index: Int, emphasized: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 23, height: 30), flipped: false) { _ in
      NSColor.labelColor.withAlphaComponent(emphasized ? 1 : 0.3).setStroke()
      let line = NSBezierPath()
      line.lineWidth = CGFloat(index + 2)
      line.lineCapStyle = .round
      line.move(to: NSPoint(x: 9.5, y: 8.5))
      line.line(to: NSPoint(x: 19.5, y: 18.5))
      line.stroke()
      return true
    }
    image.isTemplate = false
    return image
  }

  @objc private func selectWidth(_ sender: NSMenuItem) { onSelect(CGFloat(sender.tag)) }
}

private struct AnnotateThicknessMenuAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  let selectedWidth: CGFloat
  let onSelect: (CGFloat) -> Void

  func makeCoordinator() -> AnnotateThicknessMenuController {
    AnnotateThicknessMenuController(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> NSView { MenuAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelect = onSelect
    coordinator.selectedWidth = selectedWidth
    guard isPresented, !coordinator.isTracking else { return }
    coordinator.isTracking = true
    DispatchQueue.main.async {
      defer {
        coordinator.isTracking = false
        isPresented = false
      }
      guard isPresented, view.window != nil else { return }
      coordinator.makeMenu().popUp(positioning: nil,
        at: NSPoint(x: -10, y: view.bounds.maxY - 3), in: view)
    }
  }

  private final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

@MainActor
final class AnnotateArrowMenuController: NSObject {
  var onSelect: (AnnotateArrowPreset) -> Void
  var isTracking = false
  var selectedPreset: AnnotateArrowPreset = .standard

  init(onSelect: @escaping (AnnotateArrowPreset) -> Void) {
    self.onSelect = onSelect
  }

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.font = .systemFont(ofSize: 14)
    menu.minimumWidth = 152
    for (index, preset) in AnnotateArrowPreset.allCases.enumerated() {
      let item = NSMenuItem(title: preset.rawValue, action: #selector(selectPreset(_:)), keyEquivalent: "")
      item.target = self
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
      item.tag = index
      let image = OwnShotIcons.nsImage("annotateArrowStyle" + preset.rawValue)?.copy() as? NSImage
      image?.isTemplate = false
      item.image = AnnotateMenuImage.make(image, emphasized: preset == selectedPreset)
      menu.addItem(item)
    }
    return menu
  }

  @objc private func selectPreset(_ sender: NSMenuItem) {
    guard AnnotateArrowPreset.allCases.indices.contains(sender.tag) else { return }
    onSelect(AnnotateArrowPreset.allCases[sender.tag])
  }
}

private struct AnnotateArrowMenuAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  let selectedPreset: AnnotateArrowPreset
  let onSelect: (AnnotateArrowPreset) -> Void

  func makeCoordinator() -> AnnotateArrowMenuController {
    AnnotateArrowMenuController(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> NSView { MenuAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelect = onSelect
    coordinator.selectedPreset = selectedPreset
    guard isPresented, !coordinator.isTracking else { return }
    coordinator.isTracking = true
    DispatchQueue.main.async {
      defer {
        coordinator.isTracking = false
        isPresented = false
      }
      guard isPresented, view.window != nil else { return }
      let menu = coordinator.makeMenu()
      menu.popUp(positioning: nil, at: NSPoint(x: -10, y: view.bounds.maxY - 3), in: view)
    }
  }

  private final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// Меню Counter: четыре формата, разделитель, Starting number, разделитель, подменю Size.
@MainActor
final class AnnotateCounterMenuController: NSObject, NSTextFieldDelegate {
  struct Configuration {
    var format: CounterNumberFormat = .decimal
    var startingNumber: Int = AnnotateCounterSettings.defaultStartingNumber
    var size: Int?
    var onFormat: (CounterNumberFormat) -> Void = { _ in }
    var onStartingNumber: (Int) -> Void = { _ in }
    var onSize: (Int) -> Void = { _ in }
  }

  var configuration = Configuration()
  var isTracking = false
  private weak var startingNumberField: NSTextField?
  private weak var startingNumberStepper: NSStepper?

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.font = .systemFont(ofSize: 14)
    menu.minimumWidth = 226
    for (index, format) in CounterNumberFormat.allCases.enumerated() {
      let item = NSMenuItem(title: format.menuTitle, action: #selector(selectFormat(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      item.state = format == configuration.format ? .on : .off
      item.attributedTitle = Self.formatTitle(format.menuTitle)
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let startingItem = NSMenuItem()
    startingItem.view = makeStartingNumberView()
    menu.addItem(startingItem)
    menu.addItem(.separator())
    let sizeItem = NSMenuItem(title: "Size:", action: nil, keyEquivalent: "")
    let sizeMenu = NSMenu(title: "Size:")
    sizeMenu.autoenablesItems = false
    for points in AnnotateCounterSettings.sizePoints {
      let item = NSMenuItem(title: "\(points) pt", action: #selector(selectSize(_:)), keyEquivalent: "")
      item.target = self
      item.tag = points
      item.state = points == configuration.size ? .on : .off
      sizeMenu.addItem(item)
    }
    sizeItem.submenu = sizeMenu
    menu.addItem(sizeItem)
    return menu
  }

  /// Высота строки формата у эталона – 36 pt при обычном кегле 14 pt, превью
  /// кружка в строке нет (spec-051-pairs, editor-popup-counter-settings). Строка
  /// текста 30 pt даёт штатному пункту NSMenu ровно 36 pt и сохраняет галочку,
  /// подсветку и клавиатуру.
  static let formatLineHeight: CGFloat = 30

  static func formatTitle(_ title: String) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: 14)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = formatLineHeight
    paragraph.maximumLineHeight = formatLineHeight
    // Лишняя высота строки уходит вверх над текстом, сдвиг базовой линии
    // возвращает текст в середину строки.
    let naturalHeight = font.ascender - font.descender + font.leading
    return NSAttributedString(string: title, attributes: [
      .font: font,
      .paragraphStyle: paragraph,
      .baselineOffset: (formatLineHeight - naturalHeight) / 2,
    ])
  }

  /// Пока у формата стоит галочка, NSMenu добавляет к ширине view колонку
  /// состояния 15 pt, поэтому view на 211 pt даёт меню 226 pt эталона. По ширине
  /// меню view растягивается, подписи и степпер остаются на местах эталона.
  static let startingNumberViewWidth: CGFloat = 211

  /// Строка «Starting number:» с полем и степпером, диапазон 0…9999.
  private func makeStartingNumberView() -> NSView {
    let range = AnnotateCounterSettings.startingNumberRange
    let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.startingNumberViewWidth, height: 30))
    container.autoresizingMask = [.width]
    let label = NSTextField(labelWithString: "Starting number:")
    label.font = .systemFont(ofSize: 14)
    label.frame = NSRect(x: 24, y: 6, width: 122, height: 18)

    // Без NumberFormatter: ввод фильтрует controlTextDidChange, как поле эталона (ANN-502).
    let field = NSTextField(frame: NSRect(x: 149, y: 3, width: 46, height: 24))
    field.stringValue = String(configuration.startingNumber)
    field.alignment = .right
    field.delegate = self
    field.target = self
    field.action = #selector(startingNumberFieldChanged(_:))
    field.setAccessibilityLabel("Starting number")

    let stepper = NSStepper(frame: NSRect(x: 195, y: 2, width: 22, height: 26))
    stepper.minValue = Double(range.lowerBound)
    stepper.maxValue = Double(range.upperBound)
    stepper.increment = 1
    stepper.valueWraps = false
    stepper.integerValue = configuration.startingNumber
    stepper.target = self
    stepper.action = #selector(startingNumberStepperChanged(_:))

    startingNumberField = field
    startingNumberStepper = stepper
    container.addSubview(label)
    container.addSubview(field)
    container.addSubview(stepper)
    return container
  }

  private func commitStartingNumber(_ value: Int) {
    let clamped = AnnotateCounterSettings.clampedStartingNumber(value)
    startingNumberField?.integerValue = clamped
    startingNumberStepper?.integerValue = clamped
    configuration.startingNumber = clamped
    configuration.onStartingNumber(clamped)
  }

  @objc private func selectFormat(_ sender: NSMenuItem) {
    guard CounterNumberFormat.allCases.indices.contains(sender.tag) else { return }
    configuration.onFormat(CounterNumberFormat.allCases[sender.tag])
  }

  @objc private func selectSize(_ sender: NSMenuItem) {
    configuration.onSize(sender.tag)
  }

  @objc private func startingNumberStepperChanged(_ sender: NSStepper) {
    commitStartingNumber(sender.integerValue)
  }

  @objc private func startingNumberFieldChanged(_ sender: NSTextField) {
    // Пустое поле возвращает прежнее число, а не обнуляет его.
    commitStartingNumber(AnnotateCounterSettings.startingNumber(fromInput: sender.stringValue)
      ?? configuration.startingNumber)
  }

  // Набранное число применяется сразу, чтобы оно не терялось при закрытии меню.
  // Нецифровые символы в поле не попадают, лишние разряды прижимаются к 9999 (ANN-502).
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField, field === startingNumberField else { return }
    let sanitized = AnnotateCounterSettings.sanitizedStartingNumberInput(field.stringValue)
    if sanitized != field.stringValue {
      if let editor = field.currentEditor() as? NSTextView {
        editor.string = sanitized
      } else {
        field.stringValue = sanitized
      }
    }
    guard let clamped = AnnotateCounterSettings.startingNumber(fromInput: sanitized) else { return }
    startingNumberStepper?.integerValue = clamped
    configuration.startingNumber = clamped
    configuration.onStartingNumber(clamped)
  }
}

private struct AnnotateCounterMenuAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  let configuration: AnnotateCounterMenuController.Configuration

  func makeCoordinator() -> AnnotateCounterMenuController { AnnotateCounterMenuController() }

  func makeNSView(context: Context) -> NSView { MenuAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.configuration = configuration
    guard isPresented, !coordinator.isTracking else { return }
    coordinator.isTracking = true
    DispatchQueue.main.async {
      defer {
        coordinator.isTracking = false
        isPresented = false
      }
      guard isPresented, view.window != nil else { return }
      coordinator.makeMenu().popUp(positioning: nil,
        at: NSPoint(x: -10, y: view.bounds.maxY - 3), in: view)
    }
  }

  private final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
