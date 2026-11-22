import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Цвета собственной палитры: Light измерен отдельно, Dark – по нативному
/// снимку раскрытого Custom Color (ANN-392), а не по фону редактора.
private struct AnnotateColorPaletteTheme {
  let panel: Color
  let group: Color
  let field: Color
  let separator: Color
  let handle: Color
  let label: Color
  let emptySlot: Color

  static func current(_ scheme: ColorScheme) -> AnnotateColorPaletteTheme {
    scheme == .dark
      ? AnnotateColorPaletteTheme(panel: OwnShotEditorChrome.color(0x292929),
        group: OwnShotEditorChrome.color(0x1F1F1F), field: OwnShotEditorChrome.color(0x353535),
        separator: OwnShotEditorChrome.color(0x676665), handle: OwnShotEditorChrome.color(0x8A8988),
        label: OwnShotEditorChrome.color(0xA5A5A5), emptySlot: .white.opacity(0.3))
      : AnnotateColorPaletteTheme(panel: OwnShotEditorChrome.color(0xF5F5F5),
        group: OwnShotEditorChrome.color(0xE8E8E8), field: OwnShotEditorChrome.color(0xDCDCDC),
        separator: OwnShotEditorChrome.color(0xDCDCDC), handle: OwnShotEditorChrome.color(0xC4C4C4),
        label: OwnShotEditorChrome.color(0x727272), emptySlot: .black.opacity(0.25))
  }
}

/// Действия палитры, которые выполняет контроллер панели.
struct AnnotateColorPaletteActions {
  var selectPreset: (Color) -> Void = { _ in }
  var selectSaved: (Int) -> Void = { _ in }
  var addCurrentColor: () -> Void = {}
  var pickFromScreen: () -> Void = {}
  var close: () -> Void = {}
  var handleDragChanged: () -> Void = {}
  var handleDragEnded: () -> Void = {}
}

/// Палитра Custom Color: десять пресетов, колонка «My Colors» и раскрываемый
/// редактор (спектр, Hue, Alpha, Hex, R/G/B/Alpha, пипетка, Add to My Colors).
struct AnnotateColorPaletteView: View {
  @ObservedObject var model: AnnotateColorPickerModel
  let actions: AnnotateColorPaletteActions
  @Environment(\.colorScheme) private var colorScheme

  private var theme: AnnotateColorPaletteTheme { .current(colorScheme) }
  private var topInset: CGFloat { model.isDetached ? AnnotateColorPickerModel.detachedStripHeight : 0 }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.panel)
      if model.hasSavedColumn {
        extendedLayout.offset(y: topInset)
      } else {
        collapsedColumn.padding(.top, topInset)
      }
      if model.isDetached {
        AnnotateColorPaletteCloseButton(action: actions.close)
          .offset(x: 8, y: 8)
      }
    }
    .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .topLeading)
  }

  // MARK: Палитра 52×400 без сохранённых цветов

  private var collapsedColumn: some View {
    VStack(spacing: 0) {
      ForEach(AnnotateInlineProperties.palette, id: \.0) { name, entry in
        presetButton(name: name, entry: entry).frame(width: 52, height: 34)
      }
      Rectangle().fill(.black.opacity(0.1)).frame(width: 8, height: 1).padding(.vertical, 4)
      Button { model.toggleExpanded() } label: {
        wheelImage.frame(width: 52, height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).help("Custom Color").accessibilityLabel("Custom Color")
    }
    .padding(.top, 9).padding(.bottom, 10).frame(width: 52, height: 400)
  }

  // MARK: Палитра 86×400 и редактор 316×400

  private var extendedLayout: some View {
    ZStack(alignment: .topLeading) {
      if model.isExpanded {
        editorGroup.offset(x: 10, y: 10)
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.panel)
          .frame(width: 86, height: 358)
        detachHandle.offset(x: 175, y: 383)
      } else {
        Capsule().fill(theme.group).frame(width: 66, height: 32).offset(x: 10, y: 358)
      }
      ForEach(Array(AnnotateInlineProperties.palette.enumerated()), id: \.offset) { index, item in
        presetButton(name: item.0, entry: item.1).frame(width: 34, height: 34)
          .offset(x: 9, y: 9 + CGFloat(index) * 34)
      }
      ForEach(0..<AnnotateSavedColorStore.capacity, id: \.self) { slot in
        AnnotateSavedColorCell(model: model, slot: slot, theme: theme) { actions.selectSaved(slot) }
          .frame(width: 34, height: 34)
          .offset(x: 43, y: 9 + CGFloat(slot) * 34)
      }
      Button { model.toggleExpanded() } label: {
        wheelImage.frame(width: 34, height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).help("Custom Color").accessibilityLabel("Custom Color")
        .offset(x: 9, y: 358)
      AnnotateColorPaletteToggleButton(isExpanded: model.isExpanded, theme: theme) { model.toggleExpanded() }
        .offset(x: 48, y: 362)
    }
    .frame(width: model.isExpanded ? 316 : 86, height: 400, alignment: .topLeading)
  }

  private var wheelImage: some View {
    OwnShotSymbols.image("annotateColorPicker").frame(width: 24, height: 24)
  }

  private func presetButton(name: String, entry: Color) -> some View {
    Button { actions.selectPreset(entry) } label: {
      Circle().fill(entry)
        .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
        .overlay {
          if model.selectedSavedSlot == nil, AnnotateColorPaletteView.matches(model.color, entry) {
            Circle().strokeBorder(colorScheme == .dark ? entry.opacity(0.35)
              : (AnnotateInlineProperties.selectionRingLight[name] ?? entry.opacity(0.35)), lineWidth: 3)
              .frame(width: 34, height: 34)
          }
        }
        .frame(width: 24, height: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }.buttonStyle(.plain).help(name).accessibilityLabel(name)
  }

  // MARK: Редактор

  /// Серая группа 296×380 от точки 10/10: спектр 220×158 справа сверху, ниже ползунки и поля.
  private var editorGroup: some View {
    ZStack(alignment: .topLeading) {
      theme.group
      AnnotateColorSpectrum(model: model).offset(x: 76)
      AnnotateColorSlider(kind: .hue, model: model).frame(width: 144, height: 18).offset(x: 96, y: 174)
      AnnotateColorSlider(kind: .alpha, model: model).frame(width: 144, height: 18).offset(x: 96, y: 192)
      AnnotateColorPreview(color: model.color).frame(width: 28, height: 28).offset(x: 248, y: 178)
      AnnotateColorValueField(value: model.hexText, sanitize: AnnotateColorPickerModel.sanitizedHexInput,
        theme: theme, accessibilityLabel: L10n.AnnotateColorPicker.hex) { text in
          model.applyHex(text)
          return model.hexText
        }
        .frame(width: 144, height: 22).offset(x: 96, y: 219)
      fieldLabel(L10n.AnnotateColorPicker.hex).frame(width: 144).offset(x: 96, y: 243)
      Button(action: actions.pickFromScreen) {
        // Пипетка annotatePipette эталона, 14×14 pt.
        OwnShotSymbols.image("annotatePipette").renderingMode(.template).foregroundStyle(theme.label)
          .frame(width: 28, height: 28).contentShape(Rectangle())
      }.buttonStyle(.plain).help(L10n.AnnotateColorPicker.pickFromScreen)
        .accessibilityLabel(L10n.AnnotateColorPicker.pickFromScreen)
        .offset(x: 248, y: 216)
      ForEach(Array(componentFields.enumerated()), id: \.offset) { _, field in
        AnnotateColorValueField(value: String(model.value(of: field.component)),
          sanitize: AnnotateColorPaletteView.sanitizedNumberInput, theme: theme,
          accessibilityLabel: field.label) { text in
            model.applyComponent(field.component, text: text)
            return String(model.value(of: field.component))
          }
          .frame(width: 38, height: 22).offset(x: field.x, y: 265)
        fieldLabel(field.label).frame(width: 38).offset(x: field.x, y: 289)
      }
      Rectangle().fill(theme.separator).frame(width: 180, height: 1).offset(x: 96, y: 315)
      Button(action: actions.addCurrentColor) {
        HStack(spacing: 6) {
          // Тонкий плюс annotatePresetNew эталона, 11×11 pt.
          OwnShotSymbols.image("annotatePresetNew").renderingMode(.template)
          Text(L10n.AnnotateColorPicker.addToMyColors).font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(width: 180, height: 33)
        .background(Capsule().fill(OwnShotEditorChrome.color(0xE0383E)))
        .contentShape(Capsule())
      }.buttonStyle(.plain).offset(x: 96, y: 331)
    }
    .frame(width: 296, height: 380, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var componentFields: [(component: AnnotateColorComponent, label: String, x: CGFloat)] {
    [(.red, L10n.AnnotateColorPicker.red, 96), (.green, L10n.AnnotateColorPicker.green, 142),
     (.blue, L10n.AnnotateColorPicker.blue, 188), (.alpha, L10n.AnnotateColorPicker.alpha, 238)]
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundStyle(theme.label).frame(height: 14)
  }

  /// Выемка с ручкой внизу редактора: перетаскивание открепляет панель.
  private var detachHandle: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.panel).frame(width: 42, height: 17)
      // Ручка annotatePickerHandle эталона: две черты, 12×4 pt.
      OwnShotSymbols.image("annotatePickerHandle").renderingMode(.template).foregroundStyle(theme.handle)
        .frame(width: 12, height: 4).offset(x: 15, y: 6)
    }
    .frame(width: 42, height: 17, alignment: .topLeading)
    .contentShape(Rectangle())
    .help(L10n.AnnotateColorPicker.detach)
    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
      .onChanged { _ in actions.handleDragChanged() }
      .onEnded { _ in actions.handleDragEnded() })
  }

  nonisolated static func sanitizedNumberInput(_ text: String) -> String {
    var result = String(text.filter { $0.isNumber || $0 == "-" }.prefix(4))
    if let minus = result.lastIndex(of: "-"), minus != result.startIndex { result.remove(at: minus) }
    return result
  }

  static func matches(_ color: Color, _ entry: Color) -> Bool {
    guard let a = NSColor(color).usingColorSpace(.sRGB),
      let b = NSColor(entry).usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) < 0.0001
      && abs(a.greenComponent - b.greenComponent) < 0.0001
      && abs(a.blueComponent - b.blueComponent) < 0.0001
      && abs(a.alphaComponent - b.alphaComponent) < 0.0001
  }
}

// MARK: - Ячейка «My Colors»

private struct AnnotateSavedColorCell: View {
  @ObservedObject var model: AnnotateColorPickerModel
  let slot: Int
  let theme: AnnotateColorPaletteTheme
  let onSelect: () -> Void
  @State private var isHovered = false
  @State private var isDropTarget = false
  @Environment(\.colorScheme) private var colorScheme

  private static let dragMarker = "com.ownshot.annotate-color-slot:"

  private var saved: AnnotateSavedColor? {
    model.slots.indices.contains(slot) ? model.slots[slot] : nil
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Button(action: { if saved != nil { onSelect() } }) {
        swatch.frame(width: 34, height: 34).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(saved == nil ? L10n.AnnotateColorPicker.emptySlot
        : "\(L10n.AnnotateColorPicker.savedColor) \(slot + 1)")
      if saved != nil, isHovered {
        Button { model.removeColor(at: slot) } label: {
          Image(systemName: "xmark").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white)
            .frame(width: 11, height: 11)
            .background(Circle().fill(OwnShotEditorChrome.color(0x5E5E5E)))
        }.buttonStyle(.plain).help(L10n.AnnotateColorPicker.delete)
          .accessibilityLabel(L10n.AnnotateColorPicker.delete)
          .offset(x: 1, y: 1)
      }
    }
    .frame(width: 34, height: 34, alignment: .topLeading)
    .onHover { isHovered = $0 }
    // У эталона нет контекстного меню и пункта Update with Current Color: правый клик по
    // заполненной ячейке показывает одну красную кнопку Delete, по пустой – ничего (ANN-208).
    .overlay {
      if saved != nil {
        AnnotateRightClickCatcher { point, window in
          AnnotateSavedColorDeletePopup.shared.show(at: point, parent: window) { model.removeColor(at: slot) }
        }
      }
    }
    .onDrag {
      guard saved != nil else { return NSItemProvider() }
      return NSItemProvider(object: "\(Self.dragMarker)\(slot)" as NSString)
    }
    .onDrop(of: [.plainText], isTargeted: $isDropTarget) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let text = object as? String, text.hasPrefix(Self.dragMarker),
          let source = Int(text.dropFirst(Self.dragMarker.count)) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { model.moveSlot(from: source, to: slot) } }
      }
      return true
    }
  }

  @ViewBuilder private var swatch: some View {
    if let saved {
      Circle().fill(saved.color)
        .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
        .overlay {
          if model.selectedSavedSlot == slot {
            Circle().strokeBorder(saved.color.opacity(0.35), lineWidth: 3).frame(width: 34, height: 34)
          }
        }
        .frame(width: 24, height: 24)
    } else {
      Circle().strokeBorder(isDropTarget ? Color.accentColor : theme.emptySlot,
        style: StrokeStyle(lineWidth: 1, dash: [3, 2.2]))
        .frame(width: 24, height: 24)
    }
  }
}

// MARK: - Кнопки

private struct AnnotateColorPaletteToggleButton: View {
  let isExpanded: Bool
  let theme: AnnotateColorPaletteTheme
  let action: () -> Void

  var body: some View {
    let title = isExpanded ? L10n.AnnotateColorPicker.hideEditor : L10n.AnnotateColorPicker.showEditor
    Button(action: action) {
      Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.label)
        .frame(width: 24, height: 24)
        .overlay(Circle().strokeBorder(theme.handle, lineWidth: 1))
        .contentShape(Circle())
    }.buttonStyle(.plain).help(title).accessibilityLabel(title)
  }
}

private struct AnnotateColorPaletteCloseButton: View {
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Circle().fill(.black.opacity(0.08))
        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        .overlay {
          if isHovered {
            Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
          }
        }
        .frame(width: 16, height: 16)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(L10n.AnnotateColorPicker.close)
    .accessibilityLabel(L10n.AnnotateColorPicker.close)
  }
}

// MARK: - Спектр, Hue и Alpha

/// Поле насыщенности и яркости 220×158: горизонтально белый → чистый оттенок, вертикально → чёрный.
private struct AnnotateColorSpectrum: View {
  @ObservedObject var model: AnnotateColorPickerModel
  private let size = CGSize(width: 220, height: 158)

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(colors: [.white, model.hsba.pureHue], startPoint: .leading, endPoint: .trailing)
      LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
      Circle().strokeBorder(.white, lineWidth: 2)
        .shadow(color: .black.opacity(0.3), radius: 1)
        .frame(width: 13, height: 13)
        .position(x: model.hsba.saturation * size.width, y: (1 - model.hsba.brightness) * size.height)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { value in
        model.beginGesture()
        model.setSaturation(min(max(value.location.x / size.width, 0), 1),
          brightness: 1 - min(max(value.location.y / size.height, 0), 1))
      }
      .onEnded { _ in model.endGesture() })
    .accessibilityElement()
    .accessibilityLabel(L10n.AnnotateColorPicker.saturationBrightness)
  }
}

private struct AnnotateColorSlider: View {
  enum Kind { case hue, alpha }
  let kind: Kind
  @ObservedObject var model: AnnotateColorPickerModel

  private let trackHeight: CGFloat = 10
  private let thumbSize: CGFloat = 16

  private var value: Double { kind == .hue ? model.hsba.hue : model.hsba.alpha }

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        track.frame(width: width, height: trackHeight)
          .clipShape(Capsule())
          .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        Circle().fill(thumbFill)
          .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
          .shadow(color: .black.opacity(0.25), radius: 1)
          .frame(width: thumbSize, height: thumbSize)
          .offset(x: min(max(value * width - thumbSize / 2, -thumbSize / 2 + 2), width - thumbSize / 2 - 2))
      }
      .frame(width: width, height: proxy.size.height)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { drag in
          model.beginGesture()
          let fraction = min(max(drag.location.x / width, 0), 1)
          if kind == .hue { model.setHue(min(fraction, 0.9999)) } else { model.setAlpha(fraction) }
        }
        .onEnded { _ in model.endGesture() })
    }
    .accessibilityElement()
    .accessibilityLabel(kind == .hue ? L10n.AnnotateColorPicker.hue : L10n.AnnotateColorPicker.alpha)
    .accessibilityValue("\(Int((value * 100).rounded()))%")
    .accessibilityAdjustableAction { direction in
      let step = direction == .increment ? 0.01 : -0.01
      model.beginGesture()
      if kind == .hue { model.setHue(min(max(value + step, 0), 0.9999)) } else { model.setAlpha(value + step) }
      model.endGesture()
    }
  }

  @ViewBuilder private var track: some View {
    switch kind {
    case .hue:
      LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
        AnnotateColorPickerHSBA(hue: $0 >= 1 ? 0 : $0, saturation: 1, brightness: 1, alpha: 1).rgba.color
      }, startPoint: .leading, endPoint: .trailing)
    case .alpha:
      ZStack {
        AnnotateCheckerboard(cell: 5)
        LinearGradient(colors: [opaqueColor.opacity(0), opaqueColor], startPoint: .leading, endPoint: .trailing)
      }
    }
  }

  private var opaqueColor: Color {
    RGBAColor(red: model.rgba.red, green: model.rgba.green, blue: model.rgba.blue, alpha: 1).color
  }

  private var thumbFill: Color { kind == .hue ? model.hsba.pureHue : model.color }
}

private struct AnnotateCheckerboard: View {
  let cell: CGFloat

  var body: some View {
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      let columns = Int(ceil(size.width / cell))
      let rows = Int(ceil(size.height / cell))
      for row in 0..<rows {
        for column in 0..<columns where (row + column).isMultiple(of: 2) {
          context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
            with: .color(Color(white: 0.85)))
        }
      }
    }
  }
}

private struct AnnotateColorPreview: View {
  let color: Color

  var body: some View {
    ZStack {
      AnnotateCheckerboard(cell: 5).clipShape(Circle())
      Circle().fill(color)
      Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1)
    }
    .accessibilityElement()
    .accessibilityLabel(L10n.AnnotateColorPicker.currentColor)
  }
}

// MARK: - Поля ввода

/// Поле Hex или компонента: применяется по Return и при потере фокуса,
/// неверный ввод возвращает текущее значение.
private struct AnnotateColorValueField: View {
  let value: String
  let sanitize: (String) -> String
  let theme: AnnotateColorPaletteTheme
  let accessibilityLabel: String
  /// Применяет текст и возвращает новое отображаемое значение.
  let commit: (String) -> String
  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("", text: $text)
      .textFieldStyle(.plain)
      .multilineTextAlignment(.center)
      // ANN-392/394: глиф Alpha 100 в обеих темах занимает 35–36×16 px при 2×.
      .font(.system(size: 11))
      .focused($isFocused)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.field))
      .accessibilityLabel(accessibilityLabel)
      .onAppear { text = value }
      .onSubmit { apply() }
      .onChange(of: value) { newValue in
        if !isFocused { text = newValue }
      }
      .onChange(of: isFocused) { focused in
        if !focused { apply() }
      }
      .onChange(of: text) { newValue in
        let sanitized = sanitize(newValue)
        if sanitized != newValue { text = sanitized }
      }
  }

  private func apply() {
    text = commit(text)
  }
}

// MARK: - Панель и контроллер

/// Панель палитры. Принимает фокус только для полей ввода, чтобы клики по
/// цветам не отнимали ключевое окно у редактора.
final class AnnotateColorPalettePanel: NSPanel {
  var onCancel: () -> Void = {}

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) {
    onCancel()
  }
}

// MARK: - Правый клик по ячейке «My Colors»

/// Ловит только правый клик и Control-клик: остальные события проходят к кнопке
/// ячейки, наведению и перетаскиванию под ней.
private struct AnnotateRightClickCatcher: NSViewRepresentable {
  let onRightClick: (NSPoint, NSWindow) -> Void

  func makeNSView(context: Context) -> CatcherView { CatcherView() }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.onRightClick = onRightClick
  }

  final class CatcherView: NSView {
    var onRightClick: (NSPoint, NSWindow) -> Void = { _, _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent, Self.isContextClick(event) else { return nil }
      return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) { report(event) }

    override func mouseDown(with event: NSEvent) {
      guard Self.isContextClick(event) else { return super.mouseDown(with: event) }
      report(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func report(_ event: NSEvent) {
      guard let window else { return }
      onRightClick(window.convertPoint(toScreen: event.locationInWindow), window)
    }

    private static func isContextClick(_ event: NSEvent) -> Bool {
      event.type == .rightMouseDown
        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
  }
}

/// Всплывающая кнопка Delete эталона: окно 74×34 pt, левый верхний угол в точке клика,
/// красная кнопка #CE4745 с отступом 5 pt. Клик мимо или Escape убирает её без удаления.
@MainActor
final class AnnotateSavedColorDeletePopup {
  static let shared = AnnotateSavedColorDeletePopup()
  nonisolated static let size = CGSize(width: 74, height: 34)

  private var panel: NSPanel?
  private var monitors: [Any] = []

  /// Рамка окна в экранных координатах AppKit для точки клика.
  nonisolated static func frame(at point: NSPoint) -> NSRect {
    NSRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
  }

  var isShown: Bool { panel != nil }

  func show(at point: NSPoint, parent: NSWindow, onDelete: @escaping () -> Void) {
    dismiss()
    let panel = NSPanel(contentRect: Self.frame(at: point), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = true
    panel.animationBehavior = .none
    // Уровень меню: монитор палитры не закрывает её при клике по кнопке.
    parent.addChildWindow(panel, ordered: .above)
    panel.level = NSWindow.Level(rawValue: max(parent.level.rawValue, NSWindow.Level.popUpMenu.rawValue))
    panel.contentView = NSHostingView(rootView: AnnotateSavedColorDeleteButton { [weak self] in
      self?.dismiss()
      onDelete()
    })
    self.panel = panel
    panel.orderFront(nil)
    installMonitors()
  }

  func dismiss(ownedBy owner: NSWindow? = nil) {
    if let owner, panel?.parent !== owner { return }
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
    if let panel { panel.parent?.removeChildWindow(panel) }
    panel?.orderOut(nil)
    panel = nil
  }

  private func installMonitors() {
    if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
      handler: { [weak self] event in
        guard let self, let panel = self.panel else { return event }
        if event.type == .keyDown {
          guard event.keyCode == 53 else { return event }
          self.dismiss()
          return nil
        }
        if event.window !== panel { self.dismiss() }
        return event
      }) { monitors.append(local) }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
      handler: { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }) { monitors.append(global) }
  }
}

private struct AnnotateSavedColorDeleteButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(L10n.AnnotateColorPicker.delete)
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        .frame(width: 64, height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(OwnShotEditorChrome.color(0xCE4745)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.AnnotateColorPicker.delete)
    .frame(width: 74, height: 34)
    .background(VisualEffectBackdrop().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
  }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

@MainActor
final class AnnotateColorPaletteController: NSObject {
  var color: Color = .black {
    didSet { model.synchronize(color) }
  }
  var onSelect: (Color) -> Void = { _ in }
  var onEditingChanged: (Bool) -> Void = { _ in }
  var onClose: () -> Void = {}
  let model: AnnotateColorPickerModel
  private(set) var panel: AnnotateColorPalettePanel?
  private weak var anchor: NSView?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  /// Пипетка и предупреждение о лимите: клики вне панели её не закрывают.
  private var isSuspendingDismissal = false
  private var handleDragStart: (mouse: NSPoint, topLeft: NSPoint)?

  init(store: AnnotateSavedColorStore? = nil) {
    model = AnnotateColorPickerModel(store: store)
    super.init()
    model.onColorChange = { [weak self] color in self?.onSelect(color) }
    model.onEditingChanged = { [weak self] editing in self?.onEditingChanged(editing) }
    model.onLayoutChange = { [weak self] in self?.applyLayout() }
  }

  var isDetached: Bool { model.isDetached }

  func show(relativeTo anchor: NSView) {
    guard panel == nil, let parent = anchor.window else { return }
    self.anchor = anchor
    model.resetPresentation()
    model.synchronize(color)
    let size = model.panelSize
    let panel = AnnotateColorPalettePanel(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
    panel.appearance = parent.appearance
    panel.onCancel = { [weak self] in self?.cancelFromKeyboard() }
    panel.contentView = NSHostingView(rootView: AnnotateColorPaletteView(model: model, actions: makeActions()))
    self.panel = panel
    positionPanel()
    parent.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    installMonitors(parent: parent)
  }

  func close(notify: Bool = true) {
    guard let panel else { return }
    AnnotateSavedColorDeletePopup.shared.dismiss(ownedBy: panel)
    model.endGesture()
    handleDragStart = nil
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    self.panel = nil
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    localMonitor = nil
    globalMonitor = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if notify { onClose() }
  }

  /// Escape при открытом редакторе Custom Color у эталона палитру не закрывает: клавиша
  /// сразу уходит окну редактора (запрос сохранения), палитра остаётся открытой (ANN-354).
  private func cancelFromKeyboard() {
    guard model.isExpanded, let editor = anchor?.window ?? panel?.parent,
      let event = NSApp.currentEvent, event.type == .keyDown else {
      close()
      return
    }
    editor.sendEvent(event)
  }

  func invalidate() {
    close(notify: false)
    onSelect = { _ in }
    onEditingChanged = { _ in }
    onClose = {}
  }

  // MARK: Действия палитры

  private func makeActions() -> AnnotateColorPaletteActions {
    AnnotateColorPaletteActions(
      selectPreset: { [weak self] color in self?.selectPreset(color) },
      selectSaved: { [weak self] slot in self?.selectSaved(slot) },
      addCurrentColor: { [weak self] in self?.addCurrentColor() },
      pickFromScreen: { [weak self] in self?.pickFromScreen() },
      close: { [weak self] in self?.close() },
      handleDragChanged: { [weak self] in self?.handleDragChanged() },
      handleDragEnded: { [weak self] in self?.handleDragStart = nil }
    )
  }

  /// В свёрнутой прикреплённой палитре выбор закрывает её, в редакторе – нет.
  private var closesOnSelection: Bool { !model.isExpanded && !model.isDetached }

  private func selectPreset(_ color: Color) {
    model.selectColor(color)
    if closesOnSelection { close() }
  }

  private func selectSaved(_ slot: Int) {
    model.selectSavedColor(at: slot)
    if closesOnSelection { close() }
  }

  private func addCurrentColor() {
    guard model.addCurrentColor() == .full else { return }
    let alert = NSAlert()
    alert.messageText = L10n.AnnotateColorPicker.limitTitle
    alert.informativeText = L10n.AnnotateColorPicker.limitMessage
    alert.addButton(withTitle: L10n.AnnotateColorPicker.ok)
    isSuspendingDismissal = true
    alert.runModal()
    isSuspendingDismissal = false
  }

  /// Пипетка: своя лупа по контракту GlobalColorPicker эталона, клик выбирает
  /// пиксель под курсором, Escape отменяет без изменений.
  private func pickFromScreen() {
    guard !isSuspendingDismissal else { return }
    isSuspendingDismissal = true
    AnnotateScreenColorPicker.pick { [weak self] rgba in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isSuspendingDismissal = false
        if let rgba, self.panel != nil { self.model.selectColor(rgba.color) }
      }
    }
  }

  /// Нижняя ручка: первое перетаскивание открепляет панель (+15 pt сверху),
  /// дальше левый верхний угол следует за курсором.
  private func handleDragChanged() {
    guard let panel else { return }
    let mouse = NSEvent.mouseLocation
    if handleDragStart == nil {
      handleDragStart = (mouse, NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
    }
    guard let start = handleDragStart else { return }
    let dx = mouse.x - start.mouse.x
    let dy = mouse.y - start.mouse.y
    if !model.isDetached {
      guard hypot(dx, dy) >= 3 else { return }
      model.detach()
    }
    let size = model.panelSize
    panel.setFrame(NSRect(x: start.topLeft.x + dx, y: start.topLeft.y + dy - size.height,
      width: size.width, height: size.height), display: true)
  }

  // MARK: Размещение

  private func applyLayout() {
    guard let panel else { return }
    if model.isDetached {
      panel.setFrame(AnnotateColorPalettePlacement.resized(panel.frame, to: model.panelSize,
        visibleFrame: panel.screen?.visibleFrame), display: true)
    } else {
      positionPanel()
    }
  }

  private func positionPanel() {
    guard let panel, let anchor, let window = anchor.window, !model.isDetached else { return }
    let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? window.screen
    panel.setFrame(AnnotateColorPalettePlacement.frame(anchor: rect, size: model.panelSize,
      visibleFrame: screen?.visibleFrame), display: true)
  }

  private func installMonitors(parent: NSWindow) {
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self, let panel = self.panel, event.window !== panel,
        !self.isSuspendingDismissal, !self.model.isDetached else { return event }
      // Контекстное меню ячейки живёт в отдельном окне меню: клик в нём не закрывает палитру.
      if let window = event.window, !(window is AnnotateWindow), !(window is AnnotateColorPalettePanel),
        window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return event }
      let isAnchorClick: Bool
      if let anchor = self.anchor, let window = anchor.window, event.window === window {
        isAnchorClick = anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
      } else { isAnchorClick = false }
      self.close()
      return isAnchorClick ? nil : event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isSuspendingDismissal, !self.model.isDetached else { return }
        self.close()
      }
    }
    let center = NotificationCenter.default
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.positionPanel() }
      })
    }
    observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent,
      queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    // ANN-393/395/691/693: смена активного приложения сохраняет палитру.
    // Клик вне неё и закрытие окна-владельца обрабатываются отдельно выше.
  }
}

/// Якорь палитры под кнопкой цвета в верхней панели инструмента.
struct AnnotateColorPaletteAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  let color: Color
  var onEditingChanged: (Bool) -> Void = { _ in }
  let onSelect: (Color) -> Void

  func makeCoordinator() -> AnnotateColorPaletteController { AnnotateColorPaletteController() }
  func makeNSView(context: Context) -> NSView { PaletteAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let controller = context.coordinator
    controller.onSelect = onSelect
    controller.onEditingChanged = onEditingChanged
    controller.onClose = { isPresented = false }
    controller.color = color
    guard isPresented else { controller.close(notify: false); return }
    DispatchQueue.main.async {
      guard isPresented else { return }
      controller.show(relativeTo: view)
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: AnnotateColorPaletteController) {
    coordinator.invalidate()
  }

  private final class PaletteAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
