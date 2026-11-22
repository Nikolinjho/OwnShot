//
//  ToolbarIconButton.swift
//  Snapzy
//
//  Reusable icon button for the recording toolbar with hover state
//  Styled to match Apple's native macOS recording toolbar
//

import SwiftUI

struct ToolbarIconButton: View {
  let systemName: String
  let action: () -> Void
  let accessibilityLabel: String
  var iconSize: CGFloat = ToolbarConstants.iconSize
  /// Символ из набора инструментов OwnShot.
  var resourceName: String? = nil

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      ToolbarIconButtonLabel(
        systemName: systemName, iconSize: iconSize, isHovered: isHovered, resourceName: resourceName
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityLabel(accessibilityLabel)
  }
}

#Preview {
  HStack(spacing: 4) {
    ToolbarIconButton(
      systemName: "xmark",
      action: {},
      accessibilityLabel: L10n.Common.close
    )
    ToolbarIconButton(
      systemName: "gearshape",
      action: {},
      accessibilityLabel: L10n.Common.preferences
    )
  }
  .padding(10)
  .background(.ultraThinMaterial)
  .clipShape(Radius.rect(Radius.card))
}
