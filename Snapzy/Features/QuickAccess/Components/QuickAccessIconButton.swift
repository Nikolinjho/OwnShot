//
//  QuickAccessIconButton.swift
//  Snapzy
//
//  Reusable icon button with hover effect and cursor state for quick access cards
//

import AppKit
import SwiftUI

/// Icon button with hover effect and pointer cursor for card action buttons
struct QuickAccessIconButton: View {
  let icon: String
  /// Оригинальный глиф эталона. Без него рисуется SF Symbol icon.
  var asset: QuickAccessCardChrome.CornerAsset? = nil
  let action: () -> Void
  var helpText: String? = nil

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false
  @State private var isPressed = false

  var body: some View {
    Button(action: {
      guard isEnabled else { return }
      // Immediate visual feedback before action
      withAnimation(.easeOut(duration: 0.05)) {
        isPressed = true
      }
      // Execute action immediately
      action()
      // Reset press state
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        isPressed = false
      }
    }) {
      glyph
        .foregroundColor(QuickAccessLayout.color(QuickAccessLayout.cornerGlyphHex).opacity(isEnabled ? 1 : 0.45))
        .frame(width: QuickAccessLayout.cornerButtonSize, height: QuickAccessLayout.cornerButtonSize)
        .background(
          Circle()
            .fill(buttonBackgroundColor)
        )
        .scaleEffect(isPressed ? 0.85 : 1.0)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      guard isEnabled else {
        isHovering = false
        NSCursor.arrow.set()
        return
      }
      withAnimation(.easeInOut(duration: 0.1)) {
        isHovering = hovering
      }
      if hovering {
        NSCursor.pointingHand.set()
      } else {
        NSCursor.arrow.set()
      }
    }
    .if(helpText != nil) { view in
      view.help(helpText!)
    }
  }

  @ViewBuilder
  private var glyph: some View {
    if let asset {
      OwnShotIcons.image(asset.resourceName)
        .renderingMode(.template)
        .resizable()
        .frame(width: asset.size.width, height: asset.size.height)
    } else {
      Image(systemName: icon)
        .font(.system(size: QuickAccessLayout.cornerButtonGlyphSize, weight: .bold))
    }
  }

  private var buttonBackgroundColor: Color {
    if !isEnabled {
      return Color(white: 0.65).opacity(0.6)
    } else if isPressed {
      return Color(white: 0.65)
    }
    // R20: полупрозрачная светлая подложка, фон карточки просвечивает
    return QuickAccessLayout.buttonFill(isHovering: isHovering)
  }
}
