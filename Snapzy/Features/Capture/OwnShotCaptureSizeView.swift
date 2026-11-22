import AppKit
import Combine
import SwiftUI

struct OwnShotCaptureSizeView: View {
  let rect: CGRect
  let onResize: (CGFloat?, CGFloat?, Bool) -> Void
  let onAspectRatio: (CGFloat?) -> Void
  /// С onExpand справа от высоты стоит малая кнопка expand, как AXButton4 эталона All-In-One,
  /// а меню соотношений выносится в отдельный сегмент (OwnShotCaptureAspectRatioSegment).
  var onExpand: (() -> Void)? = nil
  /// Ограничение пропорций от внешнего сегмента, когда меню соотношений не внутри.
  var isRatioLocked = false
  /// Свой глиф кнопки соотношений (панель записи ставит RecordingRatioGlyph).
  var ratioGlyph: AnyView? = nil
  @State private var width = ""
  @State private var height = ""
  @State private var selectedRatio: OwnShotCaptureAspectRatio = .freeform
  @FocusState private var focusedField: OwnShotCaptureSizeField?
  @State private var previousFocusedField: OwnShotCaptureSizeField?
  @StateObject private var fieldFocus = OwnShotCaptureSizeFieldFocus()

  /// Панель записи (без кнопки expand) применяет значение по Tab, Return и уходу фокуса,
  /// как эталон; All-In-One – по мере ввода.
  private var appliesOnCommit: Bool { onExpand == nil }

  var body: some View {
    ZStack(alignment: .topLeading) {
      dimensionField("Width", width: true)
        .position(x: 22, y: 11)
      Text("×").foregroundStyle(Color(nsColor: OwnShotHUDStyle.primaryForeground)).fixedSize()
        .position(x: 51, y: 11)
      dimensionField("Height", width: false)
        .position(x: 82, y: 11)
      if let onExpand {
        Button(action: onExpand) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 20, height: 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.AllInOne.expandToScreen)
        .accessibilityLabel(L10n.AllInOne.expandToScreen)
        .position(x: 122, y: 11)
      } else {
        Menu {
          OwnShotCaptureAspectRatioMenuItems(selectedRatio: $selectedRatio, onAspectRatio: onAspectRatio)
        } label: {
          if let ratioGlyph {
            ratioGlyph
          } else {
            OwnShotCaptureAspectRatioGlyph(rect: rect)
          }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18, height: 22)
        .help("Aspect ratio")
        .accessibilityLabel("Aspect ratio")
        .position(x: 122, y: 11)
      }
    }
    .frame(width: 132, height: 22)
    .font(.system(size: 13, weight: .medium))
    .background(OwnShotCaptureSizeWindowReader(focus: fieldFocus))
    .onAppear { sync(rect) }
    .onChange(of: focusedField) { newField in
      if appliesOnCommit, let previous = previousFocusedField, previous != newField {
        commit(width: previous == .width)
      }
      previousFocusedField = newField
      if newField != nil { fieldFocus.fieldDidGainFocus() }
    }
    .onChange(of: rect) { newRect in
      DiagnosticLogger.shared.log(.debug, .ui, "Capture size fields synchronized", context: [
        "incoming": "\(newRect.width)x\(newRect.height)",
        "captured": "\(rect.width)x\(rect.height)",
      ])
      sync(newRect)
      guard onExpand == nil else { return }
      if OwnShotCaptureAspectRatio.shouldReset(selectedRatio, for: newRect, allowsRoundedDimensions: true) {
        // Новое свободное выделение сбрасывает и меню, и ограничение ручек.
        selectedRatio = .freeform
        onAspectRatio(nil)
      }
    }
  }

  private func dimensionField(_ title: String, width editingWidth: Bool) -> some View {
    TextField(title, text: dimensionBinding(width: editingWidth))
      .focused($focusedField, equals: editingWidth ? .width : .height)
      .onSubmit { if appliesOnCommit { commit(width: editingWidth) } }
      .textFieldStyle(.plain)
      .multilineTextAlignment(.center)
      // Значение поля – второй уровень переднего плана HUD, #DEDEDE (R31).
      .foregroundStyle(Color(nsColor: OwnShotHUDStyle.valueForeground))
      .frame(width: 44, height: 22)
      // Утопленное поле без рамки: чёрный 20 % поверх панели (R30).
      .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: OwnShotHUDStyle.recessedCornerRadius))
      .accessibilityLabel(editingWidth ? "Selection width" : "Selection height")
  }

  private func dimensionBinding(width editingWidth: Bool) -> Binding<String> {
    Binding(get: { editingWidth ? width : height }, set: { value in
      if appliesOnCommit {
        // Точку и буквы эталон не пропускает: «250.5» набирается как «2505».
        let digits = OwnShotCaptureSizeFieldRules.sanitized(value)
        if editingWidth { width = digits } else { height = digits }
        return
      }
      if editingWidth { width = value } else { height = value }
      guard let number = Double(value), number.isFinite, number > 0 else { return }
      let locked = onExpand == nil ? selectedRatio != .freeform : isRatioLocked
      onResize(editingWidth ? CGFloat(number) : nil, editingWidth ? nil : CGFloat(number), locked)
    })
  }

  /// Применяет введённое значение панели записи по правилам эталона (OwnShotCaptureSizeFieldRules).
  private func commit(width editingWidth: Bool) {
    let text = editingWidth ? width : height
    switch OwnShotCaptureSizeFieldRules.commit(text) {
    case .keep(let display):
      if editingWidth { width = display } else { height = display }
    case .apply(let value):
      if editingWidth { width = String(value) } else { height = String(value) }
      let size = OwnShotCaptureSizeFieldRules.resolvedSize(
        editingWidth: editingWidth,
        value: CGFloat(value),
        ratio: selectedRatio.ratio
      )
      onResize(size.width, size.height, size.locked)
    }
  }

  private func sync(_ rect: CGRect) {
    width = String(Int(rect.width.rounded()))
    height = String(Int(rect.height.rounded()))
  }
}

enum OwnShotCaptureSizeField: Hashable {
  case width
  case height
}

/// Правила полей размера панели записи, снятые с эталона (ref-rec-width.txt, ref-rec-height.txt).
enum OwnShotCaptureSizeFieldRules {
  /// Меньше 50 pt по стороне эталон не даёт: «1» становится 50.
  static let minimumSide = 50

  enum Commit: Equatable {
    /// Значение не применяется, в поле остаётся этот текст (пусто показывается как «0»).
    case keep(String)
    /// Сторона, которую нужно применить к области.
    case apply(Int)
  }

  /// В поле попадают только цифры.
  static func sanitized(_ text: String) -> String {
    String(text.filter { $0.isASCII && $0.isNumber })
  }

  static func commit(_ text: String) -> Commit {
    let digits = sanitized(text)
    guard let number = Int(digits), number > 0 else {
      return .keep(digits.isEmpty ? "0" : digits)
    }
    return .apply(max(minimumSide, number))
  }

  /// Размер для применения. Без пропорции меняется только введённая сторона; с пропорцией
  /// вторая сторона пересчитывается с отбрасыванием дроби (16:9, высота 300 → 533×300).
  /// Если вторая сторона меньше минимума, увеличиваем обе стороны в выбранной пропорции.
  static func resolvedSize(
    editingWidth: Bool, value: CGFloat, ratio: CGFloat?
  ) -> (width: CGFloat?, height: CGFloat?, locked: Bool) {
    guard let ratio, ratio.isFinite, ratio > 0 else {
      return editingWidth ? (value, nil, false) : (nil, value, false)
    }
    let minimumDimension = CGFloat(minimumSide)
    if editingWidth {
      let height = (value / ratio).rounded(.down)
      return height < minimumDimension
        ? (minimumDimension * ratio, minimumDimension, true)
        : (value, height, true)
    }
    let width = (value * ratio).rounded(.down)
    return width < minimumDimension
      ? (minimumDimension, minimumDimension / ratio, true)
      : (width, value, true)
  }
}

/// Фокус полей размера: по клику эталон выделяет всё значение насыщенным акцентным цветом.
@MainActor
final class OwnShotCaptureSizeFieldFocus: ObservableObject {
  /// Цвет выделения – системный selectedTextBackgroundColor тёмной темы (R33): панели HUD
  /// всегда тёмные, поэтому цвет берётся для darkAqua, даже если приложение в светлой теме.
  /// При системном цвете Red это raw #84595A (spec-063-live/ref-aio-width-focus.png,
  /// ref-aio-after-tab.png); прежней константы #976D6D в кадрах эталона нет.
  static var selectionColor: NSColor { resolvedSelectionColor(appearance: NSAppearance(named: .darkAqua)) }

  /// Статический цвет выделения для данного вида: следует системному цвету выделения.
  static func resolvedSelectionColor(appearance: NSAppearance?) -> NSColor {
    var color = NSColor.selectedTextBackgroundColor
    let resolve = {
      color = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.selectedTextBackgroundColor
    }
    if let appearance {
      appearance.performAsCurrentDrawingAppearance(resolve)
    } else {
      resolve()
    }
    return color
  }

  weak var window: NSWindow?
  private var mouseUpMonitor: Any?

  func fieldDidGainFocus() {
    selectAll()
    // Клик ставит каретку после получения фокуса, поэтому при нажатой кнопке
    // выделяем ещё раз, когда её отпустят.
    guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
    removeMonitor()
    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      DispatchQueue.main.async {
        self?.selectAll()
        self?.removeMonitor()
      }
      return event
    }
  }

  func selectAll() {
    DispatchQueue.main.async { [weak self] in
      guard let editor = self?.window?.firstResponder as? NSTextView else { return }
      editor.selectedTextAttributes = [
        .backgroundColor: Self.selectionColor,
        .foregroundColor: NSColor.white,
      ]
      editor.selectAll(nil)
    }
  }

  private func removeMonitor() {
    if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
    mouseUpMonitor = nil
  }
}

/// Даёт OwnShotCaptureSizeFieldFocus окно, в котором стоят поля.
private struct OwnShotCaptureSizeWindowReader: NSViewRepresentable {
  let focus: OwnShotCaptureSizeFieldFocus

  func makeNSView(context: Context) -> NSView {
    let view = PassthroughView()
    DispatchQueue.main.async { [weak view] in focus.window = view?.window }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let window = nsView.window { focus.window = window }
  }

  private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// Сегмент 62 pt с иконкой соотношения и chevron, как AXButton3 эталона All-In-One.
struct OwnShotCaptureAspectRatioSegment: View {
  let rect: CGRect
  let onAspectRatio: (CGFloat?) -> Void
  @State private var selectedRatio: OwnShotCaptureAspectRatio = .freeform

  static let size = CGSize(width: 62, height: 54)

  var body: some View {
    Menu {
      OwnShotCaptureAspectRatioMenuItems(selectedRatio: $selectedRatio, onAspectRatio: onAspectRatio)
    } label: {
      HStack(spacing: 6) {
        // У эталона здесь иконка соотношения, expand вынесен в малую кнопку у полей.
        // Значок соотношения – вторичное действие #949393, chevron – подпись #AAA9A9 (R31,
        // spec-039-live/all-in-one-overlay-initial.png).
        Image(systemName: "aspectratio").font(.system(size: 15, weight: .medium))
          .foregroundStyle(Color(nsColor: OwnShotHUDStyle.inactiveForeground))
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color(nsColor: OwnShotHUDStyle.secondaryForeground))
      }
      .frame(width: Self.size.width, height: Self.size.height)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: Self.size.width, height: Self.size.height)
    .help("Aspect ratio")
    .accessibilityLabel("Aspect ratio")
    .onChange(of: rect) { newRect in
      if OwnShotCaptureAspectRatio.shouldReset(selectedRatio, for: newRect) {
        // Новое свободное выделение сбрасывает и меню, и ограничение ручек.
        selectedRatio = .freeform
        onAspectRatio(nil)
      }
    }
  }
}

private struct OwnShotCaptureAspectRatioMenuItems: View {
  @Binding var selectedRatio: OwnShotCaptureAspectRatio
  let onAspectRatio: (CGFloat?) -> Void

  var body: some View {
    ForEach(OwnShotCaptureAspectRatio.allCases) { preset in
      Button {
        selectedRatio = preset
        onAspectRatio(preset.ratio)
      } label: {
        if selectedRatio == preset {
          Label(preset.rawValue, systemImage: "checkmark")
        } else {
          Text(preset.rawValue)
        }
      }
    }
  }
}

/// Рамка с пропорциями текущего выделения.
private struct OwnShotCaptureAspectRatioGlyph: View {
  let rect: CGRect

  var body: some View {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
      .font(.system(size: 11, weight: .medium))
      .frame(width: 18, height: 16)
      .overlay {
        let ratio = rect.height > 0 ? max(0.35, min(2.8, rect.width / rect.height)) : 1
        RoundedRectangle(cornerRadius: 3)
          .stroke(.white.opacity(0.25))
          .frame(width: ratio >= 1 ? 18 : 18 * ratio,
                 height: ratio >= 1 ? 16 / ratio : 16)
      }
  }
}

enum OwnShotCaptureAspectRatio: String, CaseIterable, Identifiable {
  case freeform = "Freeform"
  case square = "1 : 1 (Square)"
  case fiveFour = "5 : 4 (10 : 8)"
  case fourThree = "4 : 3"
  case sevenFive = "7 : 5"
  case threeTwo = "3 : 2 (6 : 4)"
  case sixteenTen = "16 : 10"
  case sixteenNine = "16 : 9"
  case cinema = "1.85 : 1"
  case widescreen = "2.35 : 1"
  case fourFive = "4 : 5"
  case threeFour = "3 : 4"
  case twoThree = "2 : 3"
  case nineSixteen = "9 : 16"

  var id: Self { self }

  /// Выделение с другими пропорциями снимает выбранный пресет.
  static func shouldReset(
    _ selected: OwnShotCaptureAspectRatio, for rect: CGRect, allowsRoundedDimensions: Bool = false
  ) -> Bool {
    guard let ratio = selected.ratio, rect.height > 0 else { return false }
    let difference = abs(rect.width / rect.height - ratio)
    // В панели записи вторая сторона округляется вниз перед подгонкой под экран.
    let roundedTolerance = allowsRoundedDimensions ? max(1, ratio) / rect.height : 0
    return difference > max(0.0001, roundedTolerance)
  }

  var ratio: CGFloat? {
    switch self {
    case .freeform: nil
    case .square: 1
    case .fiveFour: 5.0 / 4
    case .fourThree: 4.0 / 3
    case .sevenFive: 7.0 / 5
    case .threeTwo: 3.0 / 2
    case .sixteenTen: 16.0 / 10
    case .sixteenNine: 16.0 / 9
    case .cinema: 1.85
    case .widescreen: 2.35
    case .fourFive: 4.0 / 5
    case .threeFour: 3.0 / 4
    case .twoThree: 2.0 / 3
    case .nineSixteen: 9.0 / 16
    }
  }
}
