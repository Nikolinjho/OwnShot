//
//  QuickAccessTextButton.swift
//  Snapzy
//
//  Text-based action button for quick access screenshot cards
//

import SwiftUI

/// Text-based action button with hover effect for card overlays
struct QuickAccessTextButton: View {
  let label: String
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Text(label)
        // R21: видимая капсула 22 pt внутри ячейки 29 pt (AX эталона 54×29), текст #1F1F20 12 pt semibold
        .font(.system(size: QuickAccessLayout.textButtonFontSize, weight: .semibold))
        .foregroundColor(QuickAccessLayout.color(QuickAccessLayout.textButtonTextHex).opacity(isEnabled ? 1 : 0.45))
        .padding(.horizontal, QuickAccessLayout.textButtonHorizontalPadding)
        .frame(height: QuickAccessLayout.textButtonHeight)
        .background(
          Capsule(style: .continuous)
            .fill(buttonBackgroundColor)
        )
        .frame(height: QuickAccessLayout.textButtonHitHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      guard isEnabled else {
        isHovering = false
        return
      }
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
  }

  private var buttonBackgroundColor: Color {
    guard isEnabled else {
      return Color(white: 0.65).opacity(0.6)
    }
    // Материал тот же, что у угловых кругов (R21)
    return QuickAccessLayout.buttonFill(isHovering: isHovering)
  }
}
