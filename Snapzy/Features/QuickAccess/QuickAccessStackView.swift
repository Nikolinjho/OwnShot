//
//  QuickAccessStackView.swift
//  Snapzy
//
//  Vertical stacked container view for quick access cards
//

import SwiftUI

/// Displays a vertical stack of quick access cards, bottom-aligned in fixed-size panel
struct QuickAccessStackView: View {
  @ObservedObject var manager: QuickAccessManager
  /// Уходящая панель сохраняет карточки до завершения собственной анимации.
  var frozenItems: [QuickAccessItem]? = nil
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  var body: some View {
    let visibleItems = (frozenItems ?? manager.items).filter { !(manager.hideCardWhenWindowOpen && $0.isWindowOpen) }
    
    VStack(spacing: QuickAccessLayout.cardSpacing) {
      Spacer(minLength: 0)
      ForEach(visibleItems) { item in
        QuickAccessCardView(
          item: item,
          manager: manager,
          onHover: nil
        )
        .id(item.id)
        .transition(cardTransition(for: item))
      }
    }
    .frame(
      width: QuickAccessLayout.scaledCardWidth(manager.overlayScale),
      height: CGFloat(manager.maxVisibleItems) * QuickAccessLayout.scaledCardHeight(manager.overlayScale)
        + CGFloat(manager.maxVisibleItems - 1) * QuickAccessLayout.cardSpacing,
      alignment: .bottom
    )
    .padding(QuickAccessLayout.containerPadding)
    .allowsHitTesting(frozenItems == nil)
    .animation(QuickAccessAnimations.cardRemove, value: visibleItems.count)
  }

  private func cardTransition(for item: QuickAccessItem) -> AnyTransition {
    if reduceMotion {
      return .opacity
    }
    
    switch manager.animationStyle {
    case .scale:
      return .asymmetric(
        insertion: .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity),
        removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)
      )
    case .slide:
      let edge: Edge = manager.position.isLeftSide ? .leading : .trailing
      return .asymmetric(
        insertion: .move(edge: edge).combined(with: .opacity),
        removal: .move(edge: edge).combined(with: .opacity)
      )
    }
  }
}
