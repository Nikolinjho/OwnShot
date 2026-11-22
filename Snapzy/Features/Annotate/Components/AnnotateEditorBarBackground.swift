//
//  AnnotateEditorBarBackground.swift
//  Snapzy
//
//  Полупрозрачный фон тулбара и нижней панели редактора.
//

import AppKit
import SwiftUI

/// Цвета полупрозрачной хромы редактора, снятые с эталона на чёрном и белом
/// фоне (evidence/spec-050-visual/*/editor-idle-on-000000.png и -on-FFFFFF.png).
/// Значения – байты PNG без конвертации профиля, как их читают тесты.
enum AnnotateEditorBarMetrics {
  /// Светлая тема: панель #CCCCCC на чёрном и #FFFFFF на белом – белый с alpha 0,8 (ANN-808).
  static let lightBarAlpha: CGFloat = 0.8
  /// Тёмная тема: #21201F на чёрном и #504F4E на белом – #282726 с alpha ≈0,814 (ANN-360).
  static let darkBarColor: UInt32 = 0x282726
  static let darkBarAlpha: CGFloat = 0.814
  /// Неактивное окно эталона непрозрачно на любом фоне: #292726 в тёмной теме, #FFFFFF в светлой
  /// (evidence/spec-051-pairs/reference-*/editor-inactive-on-000000.png и -on-FFFFFF.png).
  static let inactiveDarkBarColor: UInt32 = 0x292726
  static let inactiveLightBarColor: UInt32 = 0xFFFFFF
  /// Капсула группы инструментов: в светлой теме чёрный 6 % (#C0C0C0/#F0F0F0),
  /// в тёмной белый 10 % (#373635/#616160, в неактивном окне #3E3D3C).
  static let lightToolGroupBlackOpacity: Double = 0.06
  static let darkToolGroupWhiteOpacity: Double = 0.1
  /// Капсула кнопок захвата и полей панелей в тёмной теме: белый 20 %
  /// (#4D4D4C/#737271, в неактивном окне #545251).
  static let darkControlWhiteOpacity: Double = 0.2
  /// Drag Me: в светлой теме непрозрачная #FDFDFD, в тёмной белый 10 %.
  static let lightDragMeColor: UInt32 = 0xFDFDFD
  static let darkDragMeWhiteOpacity: Double = 0.1
  /// Размер Drag Me по AX эталона (spec-055-live/editor-saveas.txt:4).
  static let dragMeSize = CGSize(width: 117, height: 33)
  /// Красное свечение под Save as… в светлой теме: #F4E6E4 в 2 pt под кнопкой и #F7ECEB в 8 pt.
  static let saveGlowOpacity: Double = 0.35
  static let saveGlowRadius: CGFloat = 6
  static let saveGlowOffsetY: CGFloat = 2

  /// Минимальная подложка прозрачного окна: 2/255 в 8 битах. WindowServer пропускает
  /// клики сквозь пиксели с нулевой альфой непрозрачного окна, поэтому в окне редактора
  /// таких пикселей быть не должно. Цвет подложки совпадает с тинтом темы, и под тинтом
  /// она не меняет замеров эталона: 204/255 в светлой, 33/80 в тёмной.
  static let windowFloorAlpha: CGFloat = 2.0 / 255

  /// Подложка окна под тон текущего оформления: белая в светлой теме, #282726 в тёмной.
  static let windowFloorColor = NSColor(name: "OwnShotEditorWindowFloor") { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let rgb = isDark ? darkBarColor : 0xFFFFFF
    return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255, alpha: windowFloorAlpha)
  }

  /// Цвет панели поверх фона `backdrop` (0…1 на канал) – для проверки чисел эталона.
  static func composite(barColor: CGFloat, alpha: CGFloat, over backdrop: CGFloat) -> CGFloat {
    barColor * alpha + backdrop * (1 - alpha)
  }
}

/// Подложка для офскрин-рендера: без окна за панелью ничего нет. Тесты задают
/// фиксированный фон и сверяют тон панели поверх него с замерами эталона.
private struct AnnotateEditorBarBackdropKey: EnvironmentKey {
  static let defaultValue: Color? = nil
}

extension EnvironmentValues {
  var annotateEditorBarBackdrop: Color? {
    get { self[AnnotateEditorBarBackdropKey.self] }
    set { self[AnnotateEditorBarBackdropKey.self] = newValue }
  }
}

/// Фон панели: прозрачная подложка окна либо фиксированный фон из окружения.
/// С `movesWindow` панель перетаскивает окно, как нижняя панель эталона (changelog 4.5.1).
///
/// Материала здесь нет: у эталона итог = тинт с alpha поверх того, что за окном
/// (тёмная тема: 33 на чёрном, 80 на белом). NSVisualEffectView `.underWindowBackground`
/// сам почти непрозрачен (≈83 %, 40 на чёрном и 83 на белом), и тинт поверх него
/// давал 40/48 вместо 33/80. Поэтому под тинтом лежит прозрачное окно
/// (`AnnotateWindow` не opaque, фон `.clear`), а не материал.
struct AnnotateEditorBarBackground: View {
  var movesWindow = false
  @Environment(\.annotateEditorBarBackdrop) private var backdrop

  var body: some View {
    if let backdrop {
      backdrop.allowsHitTesting(false)
    } else {
      AnnotateEditorBarWindowDragArea(movesWindow: movesWindow)
    }
  }
}

/// Прозрачная область под панелью: ничего не рисует, только перетаскивает окно.
struct AnnotateEditorBarWindowDragArea: NSViewRepresentable {
  var movesWindow = false

  func makeNSView(context: Context) -> AnnotateEditorBarDragView {
    let view = AnnotateEditorBarDragView()
    view.movesWindow = movesWindow
    return view
  }

  func updateNSView(_ view: AnnotateEditorBarDragView, context: Context) {
    view.movesWindow = movesWindow
  }
}

final class AnnotateEditorBarDragView: NSView {
  var movesWindow = false

  override var isOpaque: Bool { false }
  override var mouseDownCanMoveWindow: Bool { movesWindow }

  override func mouseDown(with event: NSEvent) {
    guard movesWindow, let window else {
      super.mouseDown(with: event)
      return
    }
    window.performDrag(with: event)
  }
}

/// Тинт поверх прозрачного окна: даёт тон эталона на любом фоне за окном.
struct AnnotateEditorBarTint: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    tint.allowsHitTesting(false)
  }

  private var tint: Color {
    // Неактивное окно эталона непрозрачно: фон за окном не просвечивает.
    if controlActiveState == .inactive {
      return OwnShotEditorChrome.color(colorScheme == .dark
        ? AnnotateEditorBarMetrics.inactiveDarkBarColor : AnnotateEditorBarMetrics.inactiveLightBarColor)
    }
    if colorScheme == .dark {
      return OwnShotEditorChrome.color(AnnotateEditorBarMetrics.darkBarColor)
        .opacity(AnnotateEditorBarMetrics.darkBarAlpha)
    }
    return Color.white.opacity(AnnotateEditorBarMetrics.lightBarAlpha)
  }
}
