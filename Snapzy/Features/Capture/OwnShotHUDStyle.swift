import AppKit
import SwiftUI

/// Палитра тёмных HUD захвата и записи (All-In-One, настройка записи) по кадрам эталона.
/// Значения – байты PNG, как их снимают тесты OwnShot: серые и почти серые тона при пересчёте
/// в sRGB не меняются. Кадры: spec-039-live/all-in-one-overlay-initial.png (AIO),
/// spec-063-live/ref-record-options-panel.png (запись). Правила R07, R28, R30, R31 (spec-066).
enum OwnShotHUDStyle {
  /// Вид панели: у AIO и у карточек записи свой тёплый оттенок.
  enum Surface {
    case allInOne
    case recording
  }

  // MARK: Поверхность (R28, R07)

  /// Непрозрачная заливка панели: AIO #2A2929, запись #282726.
  static func fill(_ surface: Surface) -> NSColor {
    switch surface {
    case .allInOne: rgb(0x2A2929)
    case .recording: rgb(0x282726)
    }
  }

  /// Внутренняя светлая кромка 1 pt (≈белый 5 %): #353434 / #333231.
  /// Разделители внутри панели того же цвета.
  static func innerEdge(_ surface: Surface) -> NSColor {
    switch surface {
    case .allInOne: rgb(0x353434)
    case .recording: rgb(0x333231)
    }
  }

  /// Внешняя тёмная кромка 1 pt: #191919 / #181717.
  static func outerEdge(_ surface: Surface) -> NSColor {
    switch surface {
    case .allInOne: rgb(0x191919)
    case .recording: rgb(0x181717)
    }
  }

  /// Толщина каждой из двух кромок и разделителей.
  static let edgeWidth: CGFloat = 1

  /// Зазор между соседними панелями одного HUD (R29): 20 px = 10 pt на обоих кадрах.
  static let panelSpacing: CGFloat = 10

  // MARK: Утопленные поля и ячейки (R30)

  /// Утопленная заливка – чёрный ≈20 % поверх панели, без рамки:
  /// #222121 на #2A2929 (поля AIO), #201F1E на #282726 (поля и выбранная ячейка записи).
  static func recessed(_ surface: Surface) -> NSColor {
    switch surface {
    case .allInOne: rgb(0x222121)
    case .recording: rgb(0x201F1E)
    }
  }

  /// Радиус утопленного поля.
  static let recessedCornerRadius: CGFloat = 6

  // MARK: Передний план (R31)

  /// Активный значок, знак «×» и значок expand – белый 100 %.
  static let primaryForeground = NSColor.white
  /// Значения полей и заголовки кнопок («Record GIF») – #DEDEDE.
  static let valueForeground = rgb(0xDEDEDE)
  /// Подписи режимов, шорткаты и chevron – #AAA9A9 (≈белый 60 % поверх панели).
  static let secondaryForeground = rgb(0xAAA9A9)
  /// Выключенные значки и вторичные действия (микрофон выкл., кроп) – #949393 (≈белый 50 %).
  static let inactiveForeground = rgb(0x949393)

  static func rgb(_ value: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 255) / 255,
      green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255,
      alpha: 1
    )
  }
}

/// Непрозрачная панель HUD с двойной кромкой: снаружи тёмная 1 pt, внутри светлая 1 pt (R07, R28).
/// Обе кромки лежат внутри рамки панели: зазор 10 pt меряется между внешними кромками.
struct OwnShotHUDPanelSurface: ViewModifier {
  let surface: OwnShotHUDStyle.Surface
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let edge = OwnShotHUDStyle.edgeWidth
    content
      .background(Color(nsColor: OwnShotHUDStyle.fill(surface)), in: shape)
      .overlay {
        shape.strokeBorder(Color(nsColor: OwnShotHUDStyle.outerEdge(surface)), lineWidth: edge)
      }
      .overlay {
        RoundedRectangle(cornerRadius: max(cornerRadius - edge, 0), style: .continuous)
          .strokeBorder(Color(nsColor: OwnShotHUDStyle.innerEdge(surface)), lineWidth: edge)
          .padding(edge)
      }
  }
}
