import SwiftUI

enum CropToolbarSymbols {
  static let snapToEdges =
    NSImage(systemSymbolName: "magnet", accessibilityDescription: nil) != nil ? "magnet" : "square.dashed"
}

struct CropToolbarView: View {
  /// Rotate Image эталона поворачивает на 90° против часовой (spec-039, editor-rotated-export-comparison.json).
  static let rotatesClockwise = false

  @ObservedObject var state: AnnotateState
  var compact = false
  @State private var showsImageSize = false
  @State private var showsBackgroundColor = false
  @State private var ratioWidthText = ""
  @State private var ratioHeightText = ""
  @State private var ratioFieldsEdited = false
  @FocusState private var focusedRatioField: RatioField?

  private enum RatioField { case width, height }

  private let presets: [CropAspectRatio] = [.square, .ratio5x4, .ratio7x5, .ratio4x3, .ratio3x2, .ratio16x9]

  var body: some View {
    HStack(spacing: compact ? 6 : 12) {
      Menu {
        // Custom Ratio у эталона не открывает отдельного окна: ввод идёт в поля отношения.
        Button("Custom Ratio") {
          state.applyCropAspectRatio(.free)
          ratioWidthText = ""
          ratioHeightText = ""
          ratioFieldsEdited = false
          focusedRatioField = .width
        }
        Divider()
        Button("Freeform") { state.applyCropAspectRatio(.free) }
        Button("Original Ratio") { state.applyOriginalCropRatio() }
        Divider()
        ForEach(presets) { ratio in
          Button(presetTitle(ratio)) {
            state.applyCropAspectRatio(ratio)
          }
        }
      } label: { Text(state.cropRatioTitle).frame(minWidth: 85, alignment: .leading) }
      .menuStyle(.borderlessButton)
      .ownShotNonFocusable()
      .frame(width: compact ? 96 : 112)
      ratioField("Ratio width", text: $ratioWidthText, field: .width)
      Button { state.swapCropDimensions() } label: {
        OwnShotSymbols.image("annotateSwapButton").renderingMode(.template).frame(width: 14, height: 14)
      }
        .buttonStyle(.plain).help("Swap width and height")
        .ownShotNonFocusable()
      ratioField("Ratio height", text: $ratioHeightText, field: .height)
      backgroundColorButton
      Divider().frame(height: 24)
      Button {
        state.confirmCropInteraction()
        state.rotateImage(clockwise: Self.rotatesClockwise)
        state.beginCropInteraction()
      } label: { Image(systemName: Self.rotatesClockwise ? "rotate.right" : "rotate.left") }
        .help("Rotate Image")
        .ownShotNonFocusable()
      Menu {
        Button("Flip Horizontally") { flip(horizontal: true) }
        Button("Flip Vertically") { flip(horizontal: false) }
      } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
      .menuStyle(.borderlessButton).frame(width: 32).help("Flip Image")
      .ownShotNonFocusable()
      Divider().frame(height: 24)
      if !compact {
        Text("Image size:").foregroundStyle(.secondary).fixedSize()
      }
      Button {
        showsImageSize = true
      } label: {
        HStack(spacing: 5) {
          Text("\(Int(state.cropPixelSize.width)) × \(Int(state.cropPixelSize.height)) px")
          Image(systemName: "chevron.down").font(.system(size: 9))
        }
      }
      .ownShotNonFocusable()
      .popover(isPresented: $showsImageSize, arrowEdge: .bottom) {
        AnnotateImageSizePopover(state: state) { showsImageSize = false }
      }
    }
    .font(.system(size: 12))
    .buttonStyle(.bordered)
    .tint(.primary)
    .fixedSize()
    .onAppear(perform: syncRatioFields)
    .onChange(of: state.cropRatioTitle) { _ in syncRatioFields() }
    .onChange(of: state.isCropPortraitOrientation) { _ in syncRatioFields() }
    .onChange(of: focusedRatioField) { newValue in
      commitRatioFields()
      if newValue == nil && !ratioFieldsEdited { syncRatioFields() }
    }
  }

  /// Background color эталона (ANCropController.colorButton): кружок цвета заливки,
  /// шахматка – прозрачный фон рамки за пределами изображения.
  private var backgroundColorButton: some View {
    Button { showsBackgroundColor.toggle() } label: {
      Group {
        if let color = state.cropFillColor {
          Circle().fill(Color(nsColor: color))
        } else {
          AnnotateCheckerboardPattern().clipShape(Circle())
        }
      }
      .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
      .frame(width: 16, height: 16)
      .frame(width: 26)
    }
    .help(Self.backgroundColorTitle)
    .accessibilityLabel(Self.backgroundColorTitle)
    .ownShotNonFocusable()
    .popover(isPresented: $showsBackgroundColor, arrowEdge: .bottom) {
      AnnotateBackgroundColorPalette(selectedColor: Binding(
        get: { state.cropFillColor.map { Color(nsColor: $0) } ?? AnnotateBackgroundPalette.transparent },
        set: { state.cropFillColor = CropFillColor.normalized($0.map { NSColor($0) }) }
      ))
      .padding(12)
    }
  }

  static var backgroundColorTitle: String {
    L10n.string(
      "annotate.crop.background-color",
      defaultValue: "Background color",
      comment: "Tooltip of the crop toolbar button that picks the fill outside the image"
    )
  }

  /// Поля показывают части текущего отношения; во Freeform они пустые.
  private func syncRatioFields() {
    guard focusedRatioField == nil else { return }
    let components = state.cropRatioFieldValues
    ratioWidthText = components.map { String($0.width) } ?? ""
    ratioHeightText = components.map { String($0.height) } ?? ""
    ratioFieldsEdited = false
  }

  /// Отношение применяется, только когда заполнены обе части (spec-039: одна 7 не меняет рамку).
  private func commitRatioFields() {
    guard ratioFieldsEdited,
          let width = AnnotateIntegerInput.positiveInteger(from: ratioWidthText),
          let height = AnnotateIntegerInput.positiveInteger(from: ratioHeightText) else { return }
    ratioFieldsEdited = false
    if let current = state.cropRatioFieldValues, current.width == width, current.height == height { return }
    state.applyCropRatioFields(width: width, height: height)
  }

  private func ratioField(_ title: String, text: Binding<String>, field: RatioField) -> some View {
    TextField("", text: Binding(
      get: { text.wrappedValue },
      // IntTextField эталона: в поле остаются только цифры.
      set: { value in
        let digits = String(value.filter { ("0"..."9").contains($0) }.prefix(5))
        guard digits != text.wrappedValue else { return }
        text.wrappedValue = digits
        ratioFieldsEdited = true
      }
    ))
    .focused($focusedRatioField, equals: field)
    .onSubmit(commitRatioFields)
    .labelsHidden()
    .textFieldStyle(.plain)
    // Тулбар красит кнопки .tint(.primary); полю возвращаем системный цвет выделения (R33).
    .tint(nil)
    .multilineTextAlignment(.center)
    .frame(width: 44, height: 22)
    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    .accessibilityLabel(title)
  }

  private func flip(horizontal: Bool) {
    state.confirmCropInteraction()
    state.flipImage(horizontal: horizontal)
    state.beginCropInteraction()
  }

  private func presetTitle(_ ratio: CropAspectRatio) -> String {
    switch ratio {
    case .square: "1 : 1 (Square)"
    case .ratio5x4: "5 : 4 (10 : 8)"
    case .ratio3x2: "3 : 2 (6 : 4)"
    default: ratio.rawValue.replacingOccurrences(of: ":", with: " : ")
    }
  }
}

/// Заливка рамки Crop: прозрачный цвет хранится как nil.
enum CropFillColor {
  static func normalized(_ color: NSColor?) -> NSColor? {
    guard let color, let srgb = color.usingColorSpace(.sRGB), srgb.alphaComponent > 0.001 else { return nil }
    return srgb
  }
}

/// Пересчёт и ввод полей Image Size эталона (spec-063-live/ref-imagesize-*).
nonisolated enum AnnotateImageSizeInput {
  static let maximumPixels = 32769

  /// В полях Width/Height эталона буквы и знаки не вводятся (ANN-359).
  static func digitsOnly(_ text: String) -> String {
    String(text.filter { $0.isASCII && $0.isNumber })
  }

  /// Проценты → пиксели с отбрасыванием дроби: 901 × 33 % = 297, 561 × 50 % = 280 (ANN-262).
  /// Ноль поднимается до 1 px, как и раньше (spec-039 editor-image-size-zero).
  static func pixels(percent: Int, reference: Int) -> Int {
    let value = (Double(max(percent, 0)) * Double(max(reference, 1)) / 100).rounded(.down)
    return Int(min(Double(maximumPixels), max(1, value)))
  }

  /// Пиксели → проценты тоже вниз: 297 из 901 – 32 %, 450 из 901 – 49 %.
  static func percent(pixels: Int, reference: Int) -> Int {
    Int((Double(pixels) * 100 / Double(max(reference, 1)) + 1e-9).rounded(.down))
  }

  static func text(pixels: Int, reference: Int, unit: AnnotateResizeUnit) -> String {
    String(unit == .percent ? percent(pixels: pixels, reference: reference) : pixels)
  }

  /// Новое значение поля. В процентах с замком второе поле получает тот же процент
  /// от своей исходной стороны: 33 % у 901 × 561 дают 297 × 185, а не 297 × 184.
  static func edit(
    value: Int, isWidth: Bool, unit: AnnotateResizeUnit, locked: Bool, ratio: Double,
    reference: (width: Int, height: Int), current: (width: Int, height: Int)
  ) -> (width: Int, height: Int) {
    switch unit {
    case .percent:
      let width = isWidth || locked ? pixels(percent: value, reference: reference.width) : current.width
      let height = !isWidth || locked ? pixels(percent: value, reference: reference.height) : current.height
      return (width, height)
    case .pixels:
      let typed = unit.pixels(value: Double(value), reference: isWidth ? reference.width : reference.height)
      return isWidth
        ? AnnotateResizeDimensions.editWidth(typed, ratio: ratio, locked: locked, height: current.height)
        : AnnotateResizeDimensions.editHeight(typed, ratio: ratio, locked: locked, width: current.width)
    }
  }
}

private struct AnnotateImageSizePopover: View {
  @ObservedObject var state: AnnotateState
  let onDismiss: () -> Void
  @State private var resizeWidth: Int
  @State private var resizeHeight: Int
  @State private var widthText: String
  @State private var heightText: String
  @State private var locksAspectRatio: Bool
  @State private var flattenAnnotations: Bool
  @State private var unit: AnnotateResizeUnit
  @FocusState private var focusedField: Field?
  @Environment(\.colorScheme) private var colorScheme
  private let initialWidth: Int
  private let initialHeight: Int
  private let sourceRatio: Double

  private enum Field { case width, height }

  init(state: AnnotateState, onDismiss: @escaping () -> Void) {
    self.state = state
    self.onDismiss = onDismiss
    let dimensions = AnnotateResizeDimensions.initial(pixelSize: state.cropPixelSize)
    _resizeWidth = State(initialValue: dimensions.width)
    _resizeHeight = State(initialValue: dimensions.height)
    // Units, lock и Flatten открываются такими, какими их оставили в прошлый раз.
    let memory = state.imageSizeMemory
    _locksAspectRatio = State(initialValue: memory.locksAspectRatio)
    _flattenAnnotations = State(initialValue: memory.flattenAnnotations)
    _unit = State(initialValue: memory.unit)
    _widthText = State(initialValue: AnnotateImageSizeInput.text(pixels: dimensions.width,
      reference: dimensions.width, unit: memory.unit))
    _heightText = State(initialValue: AnnotateImageSizeInput.text(pixels: dimensions.height,
      reference: dimensions.height, unit: memory.unit))
    initialWidth = dimensions.width
    initialHeight = dimensions.height
    sourceRatio = dimensions.ratio
  }

  private var canResize: Bool {
    resizeWidth >= 1 && resizeHeight >= 1 && resizeWidth <= 32768 && resizeHeight <= 32768
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        sizeRow
        flattenRow
      }
      .padding(.horizontal, 20)
      .frame(maxHeight: .infinity)
      Divider()
      buttonRow
    }
    .font(.system(size: 12))
    // Без .tint(.primary): он красил выделение в полях в серый, а у эталона выделение –
    // системный selectedTextBackgroundColor (spec-066 R33, ref-imagesize-letters.png).
    .frame(width: 350, height: 185)
    .onChange(of: unit) { newUnit in
      state.imageSizeMemory.unit = newUnit
      syncTexts()
    }
    .onChange(of: locksAspectRatio) { state.imageSizeMemory.locksAspectRatio = $0 }
    .onChange(of: flattenAnnotations) { state.imageSizeMemory.flattenAnnotations = $0 }
    .onChange(of: widthText) { fieldTextChanged($0, field: .width) }
    .onChange(of: heightText) { fieldTextChanged($0, field: .height) }
    // В пикселях уход из поля показывает итоговое значение: 0 + Tab даёт 1 (spec-039).
    .onChange(of: focusedField) { _ in if unit == .pixels { syncTexts() } }
  }

  private var sizeRow: some View {
    HStack(spacing: 0) {
      VStack(spacing: 10) {
        dimensionField("Width:", field: .width, text: $widthText)
        dimensionField("Height:", field: .height, text: $heightText)
      }
      Spacer().frame(width: 2)
      Button { locksAspectRatio.toggle() } label: {
        // Скобка с замком resizeLock эталона 23×33 pt в кнопке 33×54 pt (spec-039 editor-image-size).
        OwnShotSymbols.image(locksAspectRatio ? "resizeLock" : "resizeLockOpen")
          .frame(width: 33, height: 54)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Lock aspect ratio")
      .accessibilityValue(locksAspectRatio ? "Locked" : "Unlocked")
      Spacer().frame(width: 10)
      AnnotateImageSizeUnitsPicker(selection: $unit).frame(width: 118, height: 27)
    }
  }

  private var flattenRow: some View {
    HStack(spacing: 6) {
      // Чекбокс и кнопки – AppKit: у эталона их имена видны в AX как заголовки (ANN-381).
      AnnotatePopoverCheckbox(title: L10n.AnnotateImageSize.flattenAnnotations, isOn: $flattenAnnotations)
        .fixedSize()
      // Успешное запекание очищает историю редактируемых аннотаций.
      Text("(Can’t be undone)").foregroundStyle(.tertiary).font(.system(size: 11))
    }.padding(.leading, 50)
  }

  private var buttonRow: some View {
    HStack(spacing: 12) {
      Spacer()
      AnnotatePopoverPushButton(title: L10n.Common.cancel, keyEquivalent: "\u{1b}", action: onDismiss)
        .fixedSize()
      // Resize – кнопка по умолчанию: Return применяет размер и закрывает поповер (ANN-264).
      AnnotatePopoverPushButton(title: L10n.QuickAccessMenu.resizeConfirm, keyEquivalent: "\r",
        isEnabled: canResize, action: resize)
        .fixedSize()
    }
    .padding(14)
  }

  private func resize() {
    guard canResize else { return }
    // Flatten запекает аннотации без возможности отмены, поэтому сначала спрашиваем.
    guard !flattenAnnotations || confirmFlatten() else { return }
    state.resizeImage(pixelWidth: resizeWidth, pixelHeight: resizeHeight, flattenAnnotations: flattenAnnotations)
    onDismiss()
  }

  /// Предупреждение эталона перед Flatten (строки binary-strings.txt:10595-10596).
  private func confirmFlatten() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.AnnotateUI.flattenWarning
    alert.informativeText = L10n.AnnotateUI.cannotBeUndone
    alert.addButton(withTitle: L10n.QuickAccessMenu.resizeConfirm)
    alert.addButton(withTitle: L10n.Common.cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Набранное значение применяется сразу, поэтому Return сразу отдаёт его кнопке Resize.
  /// Второе поле переписывается только из поля в фокусе, иначе правки шли бы по кругу.
  private func fieldTextChanged(_ text: String, field: Field) {
    let digits = AnnotateImageSizeInput.digitsOnly(text)
    guard digits == text else {
      if field == .width { widthText = digits } else { heightText = digits }
      return
    }
    let isWidth = field == .width
    // Текст, совпадающий с текущим размером (после синхронизации или смены единиц), размер не меняет.
    let shown = isWidth
      ? AnnotateImageSizeInput.text(pixels: resizeWidth, reference: initialWidth, unit: unit)
      : AnnotateImageSizeInput.text(pixels: resizeHeight, reference: initialHeight, unit: unit)
    guard focusedField == field, digits != shown, let value = Int(digits) else { return }
    let dimensions = AnnotateImageSizeInput.edit(value: value, isWidth: isWidth, unit: unit,
      locked: locksAspectRatio, ratio: sourceRatio,
      reference: (initialWidth, initialHeight), current: (resizeWidth, resizeHeight))
    resizeWidth = dimensions.width
    resizeHeight = dimensions.height
    guard locksAspectRatio else { return }
    // В процентах с замком второе поле показывает тот же процент, как у эталона (33/33).
    let other = unit == .percent ? digits : (isWidth ? String(resizeHeight) : String(resizeWidth))
    if isWidth { heightText = other } else { widthText = other }
  }

  private func syncTexts() {
    widthText = AnnotateImageSizeInput.text(pixels: resizeWidth, reference: initialWidth, unit: unit)
    heightText = AnnotateImageSizeInput.text(pixels: resizeHeight, reference: initialHeight, unit: unit)
  }

  private func dimensionField(_ title: String, field: Field, text: Binding<String>) -> some View {
    HStack(spacing: 8) {
      Text(title).frame(width: 43, alignment: .trailing)
      // Поле эталона без кольца фокуса и безеля: плоская утопленная заливка, в фокусе
      // та же (spec-066 R30/R32, ref-imagesize-popover.png).
      TextField(title, text: text)
        .focused($focusedField, equals: field)
        .multilineTextAlignment(.center)
        .textFieldStyle(.plain)
        // Поповер наследует .tint(.primary) тулбара обрезки, полю нужен системный цвет выделения.
        .tint(nil)
        .frame(width: AnnotateImageSizeFieldMetrics.size.width, height: AnnotateImageSizeFieldMetrics.size.height)
        .background(
          Color.black.opacity(AnnotateImageSizeFieldMetrics.fillBlackOpacity(for: colorScheme)),
          in: RoundedRectangle(cornerRadius: AnnotateImageSizeFieldMetrics.cornerRadius, style: .continuous)
        )
    }
  }
}

/// Поля Width/Height поповера Image Size. Кадр spec-063-live/ref-imagesize-popover.png (2×):
/// поле #C8C8C8 на подложке поповера #DEDEDE…#E0E0E0 (≈чёрный 10 %), 100×21 pt, без рамки.
/// В тёмной теме поля HUD утоплены на чёрный ≈20 % (R30, решение C4).
enum AnnotateImageSizeFieldMetrics {
  static let size = CGSize(width: 100, height: 21)
  static let cornerRadius: CGFloat = 6
  static let lightFillBlackOpacity: Double = 0.1
  static let darkFillBlackOpacity: Double = 0.2

  static func fillBlackOpacity(for scheme: ColorScheme) -> Double {
    scheme == .dark ? darkFillBlackOpacity : lightFillBlackOpacity
  }
}

/// Кнопка поповера на NSButton: заголовок виден в AX как у эталона, keyEquivalent
/// «\r» делает её кнопкой по умолчанию, «\u{1b}» – кнопкой Escape.
private struct AnnotatePopoverPushButton: NSViewRepresentable {
  let title: String
  var keyEquivalent = ""
  var isEnabled = true
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.performAction))
    button.bezelStyle = .rounded
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    if button.title != title { button.title = title }
    if button.keyEquivalent != keyEquivalent { button.keyEquivalent = keyEquivalent }
    button.isEnabled = isEnabled
  }

  final class Coordinator: NSObject {
    var action: () -> Void = {}
    @objc func performAction() { action() }
  }
}

/// Чекбокс поповера на NSButton: заголовок «Flatten Annotations» виден в AX.
private struct AnnotatePopoverCheckbox: NSViewRepresentable {
  let title: String
  @Binding var isOn: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(checkboxWithTitle: title, target: context.coordinator,
      action: #selector(Coordinator.toggle(_:)))
    button.font = .systemFont(ofSize: 12)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.onChange = { isOn = $0 }
    if button.title != title { button.title = title }
    button.state = isOn ? .on : .off
  }

  final class Coordinator: NSObject {
    var onChange: (Bool) -> Void = { _ in }
    @objc func toggle(_ sender: NSButton) { onChange(sender.state == .on) }
  }
}

struct CropToolbarIconButton: View {
  /// Matches `ControlMetrics.toolbarButton`: the crop toolbar takes over the same bottom-bar slot
  /// as `BottomBarButton`, so the two have to share a height *and* a corner radius.
  static let height = ControlMetrics.toolbarButton

  let icon: String
  var isActive: Bool = false
  let tooltip: String
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(foregroundColor)
        .frame(width: Self.height, height: Self.height)
        .liquidGlassControl(
          isActive: isActive,
          in: Radius.controlRect(forHeight: Self.height)
        )
    }
    .buttonStyle(.plain)
    .help(tooltip)
  }

  private var foregroundColor: Color {
    guard isEnabled else { return Color.primary.opacity(0.4) }
    return isActive ? LiquidGlassTokens.inkOnAccent : Color.primary
  }
}

/// Нативный список единиц эталона размером 118×27 pt.
/// SwiftUI Picker сжимал видимую кнопку до 94,5 pt при ширине обёртки 115.
private struct AnnotateImageSizeUnitsPicker: NSViewRepresentable {
  @Binding var selection: AnnotateResizeUnit

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.addItems(withTitles: AnnotateResizeUnit.allCases.map(\.rawValue))
    button.font = .systemFont(ofSize: 13)
    button.focusRingType = .none
    button.setAccessibilityLabel("Units")
    button.target = context.coordinator
    button.action = #selector(Coordinator.selectUnit(_:))
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    button.selectItem(withTitle: selection.rawValue)
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  final class Coordinator: NSObject {
    var selection: Binding<AnnotateResizeUnit>
    init(selection: Binding<AnnotateResizeUnit>) { self.selection = selection }
    @objc func selectUnit(_ button: NSPopUpButton) {
      guard let title = button.selectedItem?.title,
        let unit = AnnotateResizeUnit(rawValue: title) else { return }
      selection.wrappedValue = unit
    }
  }
}
