import AppKit
import SwiftUI

/// Замок холста у Draw и Highlighter (ANDrawLockButton эталона). Пока холст
/// разблокирован, штрихи за изображением расширяют холст, как при
/// «Automatically expand canvas». Хранится отдельно от этой настройки.
nonisolated enum AnnotateCanvasLock {
  static let defaultsKey = "ownshot.annotate.lockCanvas"

  static func isLocked(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: defaultsKey) as? Bool ?? true
  }

  static func setLocked(_ locked: Bool, defaults: UserDefaults = .standard) {
    defaults.set(locked, forKey: defaultsKey)
  }

  /// Подсказка кнопки называет действие, как help «Unlock canvas» эталона.
  static func helpText(isLocked: Bool) -> String {
    isLocked ? L10n.AnnotateUI.unlockCanvas : L10n.AnnotateUI.lockCanvas
  }
}

/// Подпись кнопки Font size: «30 pt», дробные кегли округляются.
nonisolated enum AnnotateFontSizeMenu {
  static func label(for size: CGFloat) -> String {
    "\(Int(size.rounded())) pt"
  }

  /// Пункт меню, который отмечается галочкой; nil – кегль вне списка.
  static func selectedPreset(for size: CGFloat) -> CGFloat? {
    AnnotationProperties.fontSizePresets.first { abs($0 - size) < 0.5 }
  }
}

/// Контролы inline-панели, которых нет в общем наборе: Font size и Text style
/// у Text, форма и слайдер у Spotlight, замок холста у Draw и Highlighter.
struct AnnotateInlineToolControls: View {
  @ObservedObject var state: AnnotateState
  @State private var showsFontSize = false
  @State private var showsTextStyle = false
  @State private var showsSpotlightShape = false
  @AppStorage(AnnotateCanvasLock.defaultsKey) private var isCanvasLocked = true

  /// Пустой контейнер добавил бы лишний отступ в общей HStack панели.
  static func hasControls(for state: AnnotateState) -> Bool {
    state.quickPropertiesSupportsTextBackground || state.quickPropertiesSupportsSpotlightShape
      || state.quickPropertiesSupportsCanvasLock
  }

  var body: some View {
    HStack(spacing: 4) {
      if state.quickPropertiesSupportsTextBackground {
        fontSizeButton
        textStyleButton
      }
      if state.quickPropertiesSupportsSpotlightShape {
        HStack(spacing: 9) {
          spotlightShapeButton
          Slider(value: state.quickSpotlightOpacityBinding, in: 0.1 ... 0.9,
            onEditingChanged: state.setQuickPropertiesControlEditing)
            .labelsHidden().frame(width: 102, height: 16).controlSize(.regular)
            .accessibilityLabel(L10n.AnnotateUI.spotlightDimming)
        }
      }
      if state.quickPropertiesSupportsCanvasLock {
        Button { isCanvasLocked.toggle() } label: {
          // annotateLocked 9×13 и annotateUnlocked 13×13 pt эталона в кнопке шириной 38 pt.
          OwnShotSymbols.image(isCanvasLocked ? "annotateLocked" : "annotateUnlocked")
            .renderingMode(.template)
            .frame(width: 38, height: 28)
            .modifier(OwnShotEditorCapsule())
        }
        .buttonStyle(.plain)
        .help(AnnotateCanvasLock.helpText(isLocked: isCanvasLocked))
        .accessibilityLabel(AnnotateCanvasLock.helpText(isLocked: isCanvasLocked))
      }
    }.fixedSize()
  }

  private var chevron: some View {
    OwnShotSymbols.image("annotateChevron").renderingMode(.template).foregroundStyle(.secondary)
  }

  private var fontSizeButton: some View {
    let size = state.quickTextFontSizeBinding.wrappedValue
    return Button { showsFontSize.toggle() } label: {
      HStack(spacing: 5) {
        Text(AnnotateFontSizeMenu.label(for: size)).font(.system(size: 13)).monospacedDigit()
        chevron
      }.padding(.horizontal, 6).frame(height: 28)
        .modifier(OwnShotEditorCapsule())
    }
    .buttonStyle(.plain).help(L10n.AnnotateUI.fontSize).accessibilityLabel(L10n.AnnotateUI.fontSize)
    .background(AnnotateValueMenuAnchor(isPresented: $showsFontSize,
      layout: AnnotateInlineMenuContent.fontSizeLayout,
      items: AnnotateInlineMenuContent.fontSizeItems(current: size)) { index in
        state.quickTextFontSizeBinding.wrappedValue = AnnotationProperties.fontSizePresets[index]
      })
  }

  private var textStyleButton: some View {
    let current = state.quickTextStyle
    return Button { showsTextStyle.toggle() } label: {
      HStack(spacing: 5) {
        OwnShotSymbols.image("annotateTextStyle").renderingMode(.template).frame(width: 14, height: 14)
        chevron
      }.padding(.horizontal, 6).frame(width: 42, height: 28)
        .modifier(OwnShotEditorCapsule())
    }
    .buttonStyle(.plain).help(L10n.AnnotateUI.inlineTextStyle).accessibilityLabel(L10n.AnnotateUI.inlineTextStyle)
    .accessibilityValue(current.title)
    .background(AnnotateValueMenuAnchor(isPresented: $showsTextStyle,
      layout: AnnotateInlineMenuContent.textStyleLayout,
      items: AnnotateInlineMenuContent.textStyleItems(current: current)) { index in
        state.setTextStyle(AnnotationTextStyle.allCases[index])
      })
  }

  private var spotlightShapeButton: some View {
    let current = state.quickSpotlightShape
    return Button { showsSpotlightShape.toggle() } label: {
      HStack(spacing: 5) {
        Image(systemName: current.symbolName).font(.system(size: 13))
        chevron
      }.padding(.horizontal, 6).frame(width: 42, height: 28)
        .modifier(OwnShotEditorCapsule())
    }
    .buttonStyle(.plain).help(L10n.AnnotateUI.spotlightShape)
    .accessibilityLabel(L10n.AnnotateUI.spotlightShape)
    .accessibilityValue(current.title)
    .background(AnnotateValueMenuAnchor(isPresented: $showsSpotlightShape,
      layout: AnnotateInlineMenuContent.spotlightShapeLayout,
      items: AnnotateInlineMenuContent.spotlightShapeItems(current: current)) { index in
        state.setSpotlightShape(SpotlightShape.allCases[index])
      })
  }
}

/// Простое NSMenu со списком значений и галочкой у текущего, как у ANPropertyButton.
/// Строки штатные (без NSMenuItem.view): подсветку при наведении, клавиатуру и
/// состояние .on обрабатывает сам NSMenu. Высоту строки задаёт картинка пункта:
/// строка на 6 pt выше картинки, но не ниже 24 pt (как у меню Thickness и Arrow style).
@MainActor
final class AnnotateValueMenuController: NSObject {
  struct Item {
    var title: String
    var symbolName: String?
    var image: NSImage?
    var accessibilityLabel: String?
    var isOn: Bool

    init(title: String, symbolName: String? = nil, image: NSImage? = nil,
      accessibilityLabel: String? = nil, isOn: Bool) {
      self.title = title
      self.symbolName = symbolName
      self.image = image
      self.accessibilityLabel = accessibilityLabel
      self.isOn = isOn
    }
  }

  /// Вид меню целиком: колонка галочек и минимальная ширина.
  struct Layout: Equatable {
    var showsStateColumn = true
    var minimumWidth: CGFloat = 0
  }

  var items: [Item] = []
  var layout = Layout()
  var onSelect: (Int) -> Void = { _ in }
  var isTracking = false

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.font = .systemFont(ofSize: 14)
    menu.showsStateColumn = layout.showsStateColumn
    menu.minimumWidth = layout.minimumWidth
    for (index, entry) in items.enumerated() {
      let item = NSMenuItem(title: entry.title, action: #selector(select(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      // Без колонки галочек текущее значение выделено яркостью картинки, как у
      // Thickness и Arrow style эталона. Состояние .on NSMenu учитывает в ширине
      // даже со скрытой колонкой (+15 pt), поэтому здесь его нет.
      item.state = entry.isOn && layout.showsStateColumn ? .on : .off
      if let image = entry.image {
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
        item.image = image
      } else if let symbolName = entry.symbolName {
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: entry.accessibilityLabel)
      }
      if let label = entry.accessibilityLabel {
        item.setAccessibilityLabel(label)
        item.toolTip = label
      }
      menu.addItem(item)
    }
    return menu
  }

  @objc private func select(_ sender: NSMenuItem) {
    guard items.indices.contains(sender.tag) else { return }
    onSelect(sender.tag)
  }
}

/// Пункты меню Font size, Text style и Spotlight shape. Размеры сверены с AX
/// эталона (evidence/spec-062-live/popups/ref-*.txt): ширина меню, высота строк.
@MainActor
enum AnnotateInlineMenuContent {
  // MARK: - Font size

  /// Font size эталона: 121 pt, без колонки галочек, слева превью «Aa».
  static let fontSizeLayout = AnnotateValueMenuController.Layout(showsStateColumn: false, minimumWidth: 121)
  /// Ширина картинки-превью «Aa»: при ней штатная ширина меню ровно 121 pt.
  static let fontSizePreviewWidth: CGFloat = 40

  /// Кегль превью «Aa» для i-го пункта списка: round(10,9 + 1,78·i), от 11 до 32 pt.
  /// Высота строки эталона растёт равномерно по позиции в списке, а не по кеглю
  /// (24, 27, 28 … 49 pt для 10 … 288 pt), формула подобрана под эти высоты.
  static func fontSizePreviewPointSize(at index: Int) -> CGFloat {
    (10.9 + 1.78 * CGFloat(index)).rounded()
  }

  /// Высота картинки превью: строка шрифта превью плюс 5 pt, строка меню ещё на 6 pt выше.
  static func fontSizePreviewHeight(at index: Int) -> CGFloat {
    let font = NSFont.systemFont(ofSize: fontSizePreviewPointSize(at: index))
    return ceil(font.ascender - font.descender + font.leading) + 5
  }

  static func fontSizeItems(current size: CGFloat) -> [AnnotateValueMenuController.Item] {
    let selected = AnnotateFontSizeMenu.selectedPreset(for: size)
    return AnnotationProperties.fontSizePresets.enumerated().map { index, preset in
      AnnotateValueMenuController.Item(title: AnnotateFontSizeMenu.label(for: preset),
        image: fontSizePreview(at: index, emphasized: preset == selected), isOn: preset == selected)
    }
  }

  private static func fontSizePreview(at index: Int, emphasized: Bool) -> NSImage {
    let size = NSSize(width: fontSizePreviewWidth, height: fontSizePreviewHeight(at: index))
    let pointSize = fontSizePreviewPointSize(at: index)
    let image = NSImage(size: size, flipped: false) { rect in
      // Цвет берётся при отрисовке, чтобы превью следовало светлой и тёмной теме.
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: pointSize),
        .foregroundColor: NSColor.labelColor.withAlphaComponent(emphasized ? 1 : 0.3),
      ]
      let text = "Aa" as NSString
      let textSize = text.size(withAttributes: attributes)
      text.draw(at: NSPoint(x: 0, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = AnnotateFontSizeMenu.label(for: AnnotationProperties.fontSizePresets[index])
    return image
  }

  // MARK: - Text style

  /// Text style эталона: 192 pt, строки по 42 pt (картинка 36 pt), без колонки галочек.
  static let textStyleLayout = AnnotateValueMenuController.Layout(showsStateColumn: false, minimumWidth: 192)
  static let textStylePreviewSize = NSSize(width: 68, height: 36)
  /// Кегль слова «Text» в превью: при нём подложка Rounded Box помещается в картинку.
  static let textStylePreviewFontSize: CGFloat = 18

  static func textStyleItems(current: AnnotationTextStyle) -> [AnnotateValueMenuController.Item] {
    AnnotationTextStyle.allCases.map { style in
      AnnotateValueMenuController.Item(title: style.title,
        image: textStylePreview(style, emphasized: style == current), isOn: style == current)
    }
  }

  /// Превью стиля рисует тот же AnnotationRenderer, что и холст: подложки Box,
  /// обводка Outlined и гарнитуры Rounded/Mono совпадают с текстом на изображении.
  static func textStylePreview(_ style: AnnotationTextStyle, emphasized: Bool) -> NSImage {
    let image = NSImage(size: textStylePreviewSize, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
      // Подложка Box светлая: в тёмной теме белый текст на ней пропал бы.
      let isDark = label.brightnessComponent > 0.5
      let textColor = style.backdrop != nil && isDark ? NSColor.black : label.withAlphaComponent(1)
      let properties = AnnotationProperties(strokeColor: Color(nsColor: textColor),
        fontSize: textStylePreviewFontSize, textStyle: style)
      let font = AnnotateTextLayout.font(size: properties.fontSize, fontName: properties.fontName, textStyle: style)
      let width = AnnotateTextLayout.preferredAutoWidth(text: "Text", font: font, minimumWidth: 0)
      let bounds = AnnotateTextLayout.bounds(text: "Text", font: font, origin: .zero, constrainedWidth: width)
      let centered = bounds.offsetBy(dx: (rect.width - bounds.width) / 2, dy: (rect.height - bounds.height) / 2)
      context.saveGState()
      context.setAlpha(emphasized ? 1 : 0.35)
      context.beginTransparencyLayer(auxiliaryInfo: nil)
      AnnotationRenderer(context: context, drawsObjectShadow: false)
        .draw(AnnotationItem(type: .text("Text"), bounds: centered, properties: properties))
      context.endTransparencyLayer()
      context.restoreGState()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = style.title
    return image
  }

  // MARK: - Spotlight shape

  /// Spotlight shape эталона: 58 pt, три строки по 36 pt, только значки формы.
  static let spotlightShapeLayout = AnnotateValueMenuController.Layout(showsStateColumn: false, minimumWidth: 58)
  static let spotlightShapeImageSize = NSSize(width: 20, height: 30)

  static func spotlightShapeItems(current: SpotlightShape) -> [AnnotateValueMenuController.Item] {
    SpotlightShape.allCases.map { shape in
      // Подписи нет на экране, но она остаётся для VoiceOver и подсказки.
      AnnotateValueMenuController.Item(title: "", image: spotlightShapeImage(shape, emphasized: shape == current),
        accessibilityLabel: shape.title, isOn: shape == current)
    }
  }

  private static func spotlightShapeImage(_ shape: SpotlightShape, emphasized: Bool) -> NSImage {
    let image = NSImage(size: spotlightShapeImageSize, flipped: false) { rect in
      // Контур 16×13 pt по центру картинки, как значки формы эталона.
      let frame = NSRect(x: rect.midX - 8, y: rect.midY - 6.5, width: 16, height: 13).insetBy(dx: 0.75, dy: 0.75)
      let path: NSBezierPath
      switch shape {
      case .rectangle: path = NSBezierPath(rect: frame)
      case .roundedRectangle: path = NSBezierPath(roundedRect: frame, xRadius: 3.5, yRadius: 3.5)
      case .ellipse: path = NSBezierPath(ovalIn: frame)
      }
      path.lineWidth = 1.5
      NSColor.labelColor.withAlphaComponent(emphasized ? 1 : 0.3).setStroke()
      path.stroke()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = shape.title
    return image
  }
}

private struct AnnotateValueMenuAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  var layout = AnnotateValueMenuController.Layout()
  let items: [AnnotateValueMenuController.Item]
  let onSelect: (Int) -> Void

  func makeCoordinator() -> AnnotateValueMenuController { AnnotateValueMenuController() }

  func makeNSView(context: Context) -> NSView { MenuAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.items = items
    coordinator.layout = layout
    coordinator.onSelect = onSelect
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
