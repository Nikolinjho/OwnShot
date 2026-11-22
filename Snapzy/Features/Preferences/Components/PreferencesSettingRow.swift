//
//  SettingRow.swift
//  Snapzy
//
//  Reusable compact settings row: title with an info hint, and trailing content.
//

import SwiftUI

/// Where a row's description is shown.
enum SettingRowDescriptionStyle {
  /// Static explanation, revealed by hovering the ⓘ beside the title. Keeps rows single-line.
  case hint
  /// Live state the user should see at a glance (a path, a size, a sync status).
  case subtitle
}

struct SettingRow<Content: View>: View {
  let title: String
  let description: String?
  var descriptionStyle: SettingRowDescriptionStyle = .hint
  var tooltip: String? = nil
  /// `.top` for tall trailing content (thumbnail pickers): macOS pins the label to the top edge.
  /// Без явного значения строка с подписью ставит контрол на уровень первой строки, как эталон.
  var alignment: VerticalAlignment? = nil
  @ViewBuilder let content: () -> Content

  @Environment(\.preferencesHighlightedSetting) private var highlightedSetting

  var body: some View {
    row
      // The title doubles as the anchor Preferences search scrolls to.
      .id(title)
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.accentColor.opacity(highlightedSetting == title ? 0.16 : 0))
          .padding(.horizontal, -6)
          .padding(.vertical, -4)
          .animation(.easeInOut(duration: 0.35), value: highlightedSetting == title)
      }
  }

  private var row: some View {
    HStack(alignment: resolvedAlignment, spacing: 12) {
      labelStack
      Spacer()
      content()
    }
  }

  private var labelStack: some View {
    VStack(alignment: .leading, spacing: descriptionStyle == .subtitle ? 4 : 2) {
      if let hintText {
        Text(title)
          .hint(hintText, variant: .icon(.info))
      } else {
        Text(title)
      }
      if descriptionStyle == .subtitle, let description {
        Text(description)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
    }
    // Двухстрочная строка эталона на 0,5 pt выше суммы подписей (54,5 pt против 54).
    .padding(.vertical, hasSubtitle ? SettingsRowMetrics.subtitleExtraPadding : 0)
  }

  private var hasSubtitle: Bool {
    descriptionStyle == .subtitle && !(description ?? "").isEmpty
  }

  private var resolvedAlignment: VerticalAlignment {
    SettingRowLayout.alignment(
      explicit: alignment,
      descriptionStyle: descriptionStyle,
      hasDescription: !(description ?? "").isEmpty
    )
  }

  private var hintText: String? {
    let hinted = descriptionStyle == .hint ? description : nil
    let parts = [hinted, tooltip].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }
}

enum SettingRowLayout {
  /// Подпись под заголовком делает строку двухстрочной: контрол остаётся у первой строки.
  static func alignment(
    explicit: VerticalAlignment?,
    descriptionStyle: SettingRowDescriptionStyle,
    hasDescription: Bool
  ) -> VerticalAlignment {
    if let explicit { return explicit }
    return descriptionStyle == .subtitle && hasDescription ? .top : .center
  }
}

/// На macOS 27 скрытая подпись Toggle не предоставляет AXPress без явного действия.
struct PreferencesToggle: View {
  let title: String
  @Binding var isOn: Bool

  init(_ title: String, isOn: Binding<Bool>) {
    self.title = title
    _isOn = isOn
  }

  var body: some View {
    Toggle(title, isOn: $isOn)
      .labelsHidden()
      .accessibilityAction { isOn.toggle() }
      // Строка с переключателем у эталона 36,5 pt, как у Toggle с подписью в Form.
      .padding(.vertical, SettingsRowMetrics.toggleExtraPadding)
  }
}

// MARK: - Высота строк

/// Высоты строк grouped Form по эталону (PNG Settings live 062). Строка Form добавляет
/// к высоте содержимого 20 pt и 1 pt разделителя: переключатель – 36,5 pt, попап – 37,5 pt,
/// строка с записью сочетания – 42 pt.
enum SettingsRowMetrics {
  /// Переключатель 16 pt дополняется до 16,5 pt.
  static let toggleExtraPadding: CGFloat = 0.25
  /// Заголовок с подписью дополняется на 0,5 pt.
  static let subtitleExtraPadding: CGFloat = 0.25
  /// Попап 24 pt занимает в строке 17,5 pt, как Picker с подписью в Form.
  static let popupHeight: CGFloat = 17.5
  /// Поле записи сочетания 30 pt занимает в строке 22 pt.
  static let shortcutRecorderHeight: CGFloat = 22
}

/// Сообщает строке высоту не больше `maxHeight` и рисует содержимое по центру:
/// контрол выходит в вертикальные отступы строки и не раздувает её.
struct SettingsRowHeightCap: Layout {
  let maxHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    var size = CGSize.zero
    for subview in subviews {
      let fitting = subview.sizeThatFits(proposal)
      size.width = max(size.width, fitting.width)
      size.height = max(size.height, fitting.height)
    }
    size.height = min(size.height, maxHeight)
    return size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      let fitting = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      subview.place(
        at: CGPoint(x: bounds.midX, y: bounds.midY),
        anchor: .center,
        proposal: ProposedViewSize(fitting)
      )
    }
  }
}

extension View {
  /// Ограничивает вклад контрола в высоту строки настроек.
  func settingsRowHeight(_ maxHeight: CGFloat) -> some View {
    SettingsRowHeightCap(maxHeight: maxHeight) { self }
  }

  /// Попап в строке настроек: высота строки как у эталона (37,5 pt).
  func settingsPopupRow() -> some View {
    settingsRowHeight(SettingsRowMetrics.popupHeight)
  }
}

// MARK: - Search Highlight

private struct PreferencesHighlightedSettingKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  /// Title of the setting row flashing after a Preferences search jump.
  var preferencesHighlightedSetting: String? {
    get { self[PreferencesHighlightedSettingKey.self] }
    set { self[PreferencesHighlightedSettingKey.self] = newValue }
  }
}
