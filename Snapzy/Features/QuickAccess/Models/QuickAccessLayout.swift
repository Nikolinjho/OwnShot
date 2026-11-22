//
//  QuickAccessLayout.swift
//  Snapzy
//
//  Centralized layout constants for QuickAccess panel
//

import Foundation
import SwiftUI

/// Centralized layout constants for QuickAccess panel
/// Single source of truth for dimensions used by Manager and StackView
enum QuickAccessLayout {
  /// Base width of panel content area (matches card container width)
  static let cardWidth: CGFloat = 210

  /// Base height of each card slot in the panel
  static let cardHeight: CGFloat = 150

  static let cardCornerRadius: CGFloat = 18

  /// Уровень окна карточек: эталон держит host Quick Access на 2147483628 (spec-042 WindowServer)
  static let panelWindowLevel = 2147483628
  /// Alert поверх карточек
  static let alertWindowLevel = panelWindowLevel + 1

  /// Видимый круг угловой кнопки 22 pt в 6 pt от края карточки (R20: 44 px @2x,
  /// audit-020/reference-quick-hover.png и spec-063-live/ref-qa-card-hover.png)
  static let cornerButtonSize: CGFloat = 22
  static let cornerButtonInset: CGFloat = 6
  static let cornerButtonGlyphSize: CGFloat = 11

  /// Подложка угловых кругов и текстовых капсул – полупрозрачный белый, сквозь него виден фон
  /// карточки (R20: #CECDCF на #2D2C2D и #CFD6E3 на #314B77 дают α≈0.75–0.78)
  static let buttonFillOpacity: Double = 0.78
  static let buttonFillHoverOpacity: Double = 0.9
  /// Глиф угловых кнопок QA #151515 (R20)
  static let cornerGlyphHex: UInt32 = 0x151515

  /// Текстовые капсулы Copy/Save (R21). Видимая капсула 22 pt (Copy 45 px, Save 43 px @2x
  /// в audit-020/reference-quick-hover.png), ячейка нажатия 29 pt, как AX эталона, шаг
  /// между центрами 37 pt (74 px) – видимый зазор ≈15 pt. Текст #1F1F20 12 pt semibold:
  /// ширина «Copy» по глифам 29 pt, капсулы 52 и 50 pt.
  static let textButtonHeight: CGFloat = 22
  static let textButtonHitHeight: CGFloat = 29
  static let textButtonSpacing: CGFloat = 8
  static let textButtonFontSize: CGFloat = 12
  static let textButtonHorizontalPadding: CGFloat = 12
  static let textButtonTextHex: UInt32 = 0x1F1F20

  /// Цвет sRGB из hex эталона
  static func color(_ rgb: UInt32) -> Color {
    Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
          green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
  }

  /// Подложка кнопок карточки: белый с α 0.78, ярче при наведении
  static func buttonFill(isHovering: Bool) -> Color {
    Color.white.opacity(isHovering ? buttonFillHoverOpacity : buttonFillOpacity)
  }

  /// Ховер эталона: превью размыто и слегка затемнено (spec-051 quick-access-hover)
  static let hoverBlurRadius: CGFloat = 14
  static let hoverDimOpacity: Double = 0.35

  /// Клетка шахматки под прозрачными снимками
  static let checkerboardCellSize: CGFloat = 8

  /// Scaled card width based on user overlay scale setting
  static func scaledCardWidth(_ scale: CGFloat) -> CGFloat { cardWidth * scale }

  /// Scaled card height based on user overlay scale setting
  static func scaledCardHeight(_ scale: CGFloat) -> CGFloat { cardHeight * scale }

  /// Между карточками 10 pt: высота 150 pt и шаг 160 pt у эталона.
  static let cardSpacing: CGFloat = 10

  /// Padding around the card stack (12pt for shadow clearance: radius 8 + y-offset 4)
  static let containerPadding: CGFloat = 12

  // MARK: - Depth Stacking (CleanShot X style)

  /// Scale reduction per card in stack (each card 5% smaller than previous)
  static let depthScaleStep: CGFloat = 0.05

  /// Vertical offset per card in stack (cards stack upward)
  static let depthOffsetStep: CGFloat = -8

  /// Parallax push distance when hovering a card
  static let depthParallaxPush: CGFloat = 4

  /// Opacity of the oldest (bottom) card in stack
  static let maxDepthOpacity: CGFloat = 0.7

  /// Scale increase when card is hovered
  static let hoverScaleBoost: CGFloat = 1.02
}
