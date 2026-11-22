//
//  QuickAccessHiddenStackStrip.swift
//  Snapzy
//
//  Полоска со стрелкой у нижнего края, через которую возвращается временно скрытый стек
//  (Popup.slideDownView и ассет popupArrow 36×10 pt у эталона). Глиф нарисован в коде.
//

import AppKit
import SwiftUI

enum QuickAccessHiddenStackStripLayout {
  static let arrowSize = CGSize(width: 36, height: 10)
  static let stripSize = CGSize(width: 64, height: 20)

  /// Полоска стоит у нижнего края видимой области под центром стека
  static func frame(visibleFrame: CGRect, isLeftSide: Bool, scale: CGFloat) -> CGRect {
    let cardWidth = QuickAccessLayout.scaledCardWidth(scale)
    let inset = QuickAccessLayout.containerPadding + cardWidth / 2
    let centerX = isLeftSide ? visibleFrame.minX + inset : visibleFrame.maxX - inset
    return CGRect(
      x: (centerX - stripSize.width / 2).rounded(),
      y: visibleFrame.minY,
      width: stripSize.width,
      height: stripSize.height
    )
  }
}

/// Стрелка вверх 36×10 pt
private struct QuickAccessHiddenStackArrow: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    return path
  }
}

private struct QuickAccessHiddenStackStripView: View {
  let onRestore: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: onRestore) {
      QuickAccessHiddenStackArrow()
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .frame(
          width: QuickAccessHiddenStackStripLayout.arrowSize.width,
          height: QuickAccessHiddenStackStripLayout.arrowSize.height
        )
        .frame(
          width: QuickAccessHiddenStackStripLayout.stripSize.width,
          height: QuickAccessHiddenStackStripLayout.stripSize.height
        )
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(isHovering ? 0.75 : 0.55))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(L10n.QuickAccess.showHiddenOverlays)
    .accessibilityLabel(L10n.QuickAccess.showHiddenOverlays)
  }
}

@MainActor
final class QuickAccessHiddenStackStrip {
  static let shared = QuickAccessHiddenStackStrip()

  private var panel: NSPanel?

  var isVisible: Bool { panel?.isVisible == true }

  func show(on screen: NSScreen, isLeftSide: Bool, scale: CGFloat, onRestore: @escaping () -> Void) {
    let frame = QuickAccessHiddenStackStripLayout.frame(
      visibleFrame: screen.visibleFrame,
      isLeftSide: isLeftSide,
      scale: scale
    )
    let panel = panel ?? makePanel()
    panel.contentView = NSHostingView(rootView: QuickAccessHiddenStackStripView(onRestore: onRestore))
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    self.panel = panel
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = NSWindow.Level(rawValue: QuickAccessLayout.panelWindowLevel)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
  }
}
