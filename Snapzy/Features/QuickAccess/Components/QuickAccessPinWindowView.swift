//
//  QuickAccessPinWindowView.swift
//  Snapzy
//
//  Floating image-first surface for pinned screenshots.
//

import AppKit
import SwiftUI

struct QuickAccessPinWindowView: View {
  @ObservedObject var state: QuickAccessPinWindowState

  let onClose: () -> Void
  let onLockChanged: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDragHovering = false
  @State private var isDragActive = false

  private var cornerRadius: CGFloat { state.roundedCorners ? QuickAccessPinChromeMetrics.cornerRadius : 0 }
  private let dragHandleCornerRadius: CGFloat = QuickAccessPinChromeMetrics.dragHandleCornerRadius
  private let controlInset: CGFloat = QuickAccessPinChromeMetrics.controlInset

  var body: some View {
    ZStack {
      screenshotImage
      chromeLayer
    }
    .frame(width: state.displaySize.width, height: state.displaySize.height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Рамка эталона: 1 px серого #808080 с α 0,6 (ref-pin-window.png).
        .stroke(QuickAccessPinChromeMetrics.borderColor.opacity(state.showsBorder ? 1 : 0), lineWidth: 1)
    )
    .background(Color.clear)
  }

  private var screenshotImage: some View {
    QuickAccessPinImageViewport(state: state)
      .frame(width: state.displaySize.width, height: state.displaySize.height)
      .clipped()
      // Затухание до 64/255 под курсором у заблокированного pin, как в эталоне.
      .opacity(state.contentOpacity)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.isMouseInside)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.opacity)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: state.isLocked)
  }

  private var chromeLayer: some View {
    ZStack {
      hoverControls

      interactiveRegion(lockButton, isInteractive: state.isMouseInside || state.isLocked)
        .opacity(state.isMouseInside || state.isLocked ? 1 : 0)
        .allowsHitTesting(state.isMouseInside || state.isLocked)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(controlInset)
    }
  }

  private var hoverControls: some View {
    ZStack {
      interactiveRegion(
        chromeButton(systemName: "xmark", help: L10n.PreferencesQuickAccess.unpinAction, action: onClose),
        isInteractive: state.isMouseInside
      )
      .opacity(state.isMouseInside ? 1 : 0)
      .allowsHitTesting(state.isMouseInside)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(controlInset)

      // У эталона масштаб – надпись, а не кнопка: в AX пина две кнопки (закрыть и замок).
      // Масштаб меняется из контекстного меню (Zoom) и жестами.
      zoomIndicator
        .opacity(showsUnlockedChrome ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, controlInset)

      // NSDraggingSource остаётся в дереве при уходе курсора: начатый drag
      // должен завершиться даже после скрытия хрома (QA-151).
      interactiveRegion(dragHandle, isInteractive: showsUnlockedChrome)
        .opacity(showsUnlockedChrome ? 1 : 0)
        .allowsHitTesting(showsUnlockedChrome)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, controlInset)
    }
  }

  private var showsUnlockedChrome: Bool {
    state.isMouseInside && !state.isLocked
  }

  /// Wraps interactive chrome so background-window dragging never starts on
  /// a control, keeping both drags and clicks exclusive to the control.
  private func interactiveRegion<V: View>(_ content: V, isInteractive: Bool) -> some View {
    content.background {
      // Окно проверяет геометрию marker views напрямую. Невидимый marker
      // перекрывал бы перетаскивание изображения даже при allowsHitTesting(false).
      if isInteractive { PinWindowDragExclusionRepresentable() }
    }
  }

  private var lockButton: some View {
    // FOLockButton эталона: floatingOverlayLocked 8×12 pt и floatingOverlayUnlocked 12×12 pt.
    chromeButton(
      glyph: OwnShotSymbols.image(state.isLocked ? "floatingOverlayLocked" : "floatingOverlayUnlocked")
        .renderingMode(.template)
        .resizable()
        .frame(width: state.isLocked ? 8 : 12, height: 12),
      help: state.isLocked ? L10n.QuickAccess.unlockPinnedWindow : L10n.QuickAccess.lockPinnedWindow
    ) {
      state.isLocked.toggle()
      onLockChanged()
    }
  }

  private var zoomIndicator: some View {
    Text("\(state.zoomPercent)%")
      .font(.system(size: 12, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(LiquidGlassTokens.inkOverlay)
      .padding(.horizontal, 10)
      .frame(height: QuickAccessPinChromeMetrics.buttonSize)
      .liquidGlassChrome(
        shape: Capsule(style: .continuous),
        isVisible: true,
        isActive: false,
        emphasis: .overlay
      )
      .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
      .fixedSize(horizontal: true, vertical: false)
      .allowsHitTesting(false)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isStaticText)
  }

  private var dragHandle: some View {
    QuickAccessPinDragHandleView(
      fileURL: state.url,
      image: state.image,
      thumbnail: state.thumbnail,
      onDragStateChanged: { isDragActive = $0 },
      onDropCompleted: { success, optionHeld in
        let closeAfterDragging = UserDefaults.standard.object(forKey: "ownshot.quickAccess.closeAfterDragging") as? Bool ?? true
        if QuickAccessCompletionPolicy.shouldCloseAfterDrag(
          success: success, closeAfterDragging: closeAfterDragging, optionHeld: optionHeld
        ) {
          onClose()
        }
      }
    )
    .frame(width: QuickAccessPinChromeMetrics.dragHandleSize.width, height: QuickAccessPinChromeMetrics.dragHandleSize.height)
    .overlay(
      // Оригинальный глиф ручки floatingOverlayDrag эталона, 39×11 pt.
      OwnShotSymbols.image("floatingOverlayDrag")
        .renderingMode(.template)
        .resizable()
        .frame(width: QuickAccessPinChromeMetrics.dragGlyphSize.width, height: QuickAccessPinChromeMetrics.dragGlyphSize.height)
      .foregroundStyle(dragForegroundColor)
      .allowsHitTesting(false)
    )
    .liquidGlassChrome(
      shape: RoundedRectangle(cornerRadius: dragHandleCornerRadius, style: .continuous),
      isVisible: true,
      isActive: isDragHovering || isDragActive,
      emphasis: .overlay
    )
    // Rule 2: scale, not opacity — a transform never detaches the glass backdrop.
    .scaleEffect(isDragHovering || isDragActive ? 1.015 : 1)
    .shadow(color: Color.black.opacity(isDragHovering || isDragActive ? 0.18 : 0.12), radius: 7, x: 0, y: 2)
    .onHover { isDragHovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDragHovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDragActive)
    .help(L10n.AnnotateUI.dragToAppHelp)
  }

  private func chromeButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
    chromeButton(
      glyph: Image(systemName: systemName).font(.system(size: 11, weight: .bold)),
      help: help,
      action: action
    )
  }

  private func chromeButton<Glyph: View>(glyph: Glyph, help: String, action: @escaping () -> Void) -> some View {
    QuickAccessPinChromeButton(glyph: glyph, action: action)
      .help(help)
  }

  private var dragForegroundColor: Color {
    let ink = LiquidGlassTokens.inkOverlay
    return isDragHovering || isDragActive ? ink : ink.opacity(0.62)
  }
}

/// Угловая кнопка пина: светлый полупрозрачный круг 22 pt с тёмным глифом, как у карточки QA (R20).
private struct QuickAccessPinChromeButton<Glyph: View>: View {
  let glyph: Glyph
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      glyph
        .foregroundStyle(Color.black.opacity(QuickAccessPinChromeMetrics.glyphOpacity))
        .frame(
          width: QuickAccessPinChromeMetrics.visibleButtonSize,
          height: QuickAccessPinChromeMetrics.visibleButtonSize
        )
        .background(Circle().fill(QuickAccessLayout.buttonFill(isHovering: isHovering)))
        .frame(width: QuickAccessPinChromeMetrics.buttonSize, height: QuickAccessPinChromeMetrics.buttonSize)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

/// Геометрия хрома pin по spec-039 pin-default: кнопки 24×24 pt в 9 pt от углов.
nonisolated enum QuickAccessPinChromeMetrics {
  /// Ячейка кнопки 24 pt, как AX эталона
  static let buttonSize: CGFloat = 24
  /// Видимый круг 22 pt в 10 pt от углов (R20: 44 px с x=20 в spec-062-live/ref-pin-hover.png)
  static let visibleButtonSize: CGFloat = 22
  /// Глиф #7D7470 на подложке #E4D4CD – чёрный ≈45 % (ref-pin-hover.png)
  static let glyphOpacity: Double = 0.45
  static let controlInset: CGFloat = 9
  static let dragGlyphSize = CGSize(width: 39, height: 11)
  static let dragHandleSize = CGSize(width: 55, height: 24)
  static let dragHandleCornerRadius: CGFloat = 7
  /// Скругление пина эталона: профиль угла ref-pin-window.png совпадает
  /// с continuous-скруглением 18 pt (у окна по умолчанию 24 pt).
  static let cornerRadius: CGFloat = 18
  static let borderColor = Color(.sRGB, white: 128.0 / 255.0, opacity: 0.6)
}


/// NSView marker that opts a region of the pin window out of background
/// window dragging. `QuickAccessPinWindow` hit-tests for this class before
/// starting a native-or-manual background drag, so chrome controls keep
/// their clicks and future interactive controls only need to be wrapped in
/// `PinWindowDragExclusionRepresentable`.
final class PinWindowDragExclusionView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }
}

struct PinWindowDragExclusionRepresentable: NSViewRepresentable {
  func makeNSView(context: Context) -> PinWindowDragExclusionView {
    PinWindowDragExclusionView(frame: .zero)
  }

  func updateNSView(_ nsView: PinWindowDragExclusionView, context: Context) {}
}
