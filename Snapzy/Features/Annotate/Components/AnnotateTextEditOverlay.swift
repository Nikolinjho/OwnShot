//
//  TextEditOverlay.swift
//  Snapzy
//
//  SwiftUI overlay for inline text annotation editing
//

import AppKit
import SwiftUI

/// Overlay for editing text annotations inline on the canvas
struct TextEditOverlay: View {
  @ObservedObject var state: AnnotateState
  let scale: CGFloat
  let canvasBounds: CGRect
  var interactionBridge: CanvasInteractionBridge?

  @State private var editingText: String = ""

  // MARK: - Constants

  private let minTextFieldWidth: CGFloat = AnnotateTextLayout.minWidth

  var body: some View {
    GeometryReader { _ in
      if let editingId = state.editingTextAnnotationId,
         let annotation = state.annotations.first(where: { $0.id == editingId }),
         case .text(let currentText) = annotation.type {

        let displayBounds = calculateDisplayBounds(annotation.bounds)
        let displayFont = AnnotateTextLayout.displayFont(
          size: annotation.properties.fontSize,
          fontName: annotation.properties.fontName,
          textStyle: annotation.properties.textStyle,
          // TODO: вид обводки Outlined и подложек Box во время ввода у эталона
          // не снят, поэтому в редакторе меняется только шрифт стиля.
          scale: scale
        )
        let fieldWidth = max(displayBounds.width, minTextFieldWidth)
        let fieldHeight = max(displayBounds.height, 1)
        let textContainerInset = AnnotateTextLayout.textEditorInset(
          scale: scale,
          presentation: annotation.properties.textPresentation,
          fontSize: annotation.properties.fontSize
        )
        let tailTarget = annotation.properties.calloutTailTarget.map {
          TextBubbleGeometry.resolvedTailTarget(
            in: annotation.bounds,
            requestedTarget: $0,
            fontSize: annotation.properties.fontSize
          )
        }.map(calculateDisplayPoint)
        let relativeTailTarget = tailTarget.map {
          CGPoint(x: $0.x - displayBounds.minX, y: $0.y - displayBounds.minY)
        }

        ZStack(alignment: .topLeading) {
          if annotation.properties.textPresentation != .plain {
            TextBubbleShape(
              tailTarget: annotation.properties.textPresentation == .callout ? relativeTailTarget : nil,
              fontSize: displayFont.pointSize,
              cornerRadius: annotation.properties.cornerRadius * scale
            )
              .fill(annotation.properties.fillColor)
          }

          InlineAnnotationTextEditor(
            editingId: editingId,
            text: $editingText,
            font: displayFont,
            textContainerInset: textContainerInset,
            textColor: NSColor(annotation.properties.strokeColor),
            onCommit: { commitEdit(id: editingId) },
            onCancel: cancelEdit,
            onUndo: { state.undo() },
            onRedo: { state.redo() },
            interactionBridge: interactionBridge
          )
        }
          .frame(
            width: fieldWidth,
            height: fieldHeight,
            alignment: .topLeading
          )
          .position(
            x: displayBounds.minX + fieldWidth / 2,
            y: displayBounds.minY + fieldHeight / 2
          )
          .onAppear {
            editingText = currentText
          }

        // Кнопка эмодзи эталона над рамкой (ANN-043): открывает системную
        // палитру символов, выбранный символ вставляется в текст.
        TextEmojiPaletteButton(interactionBridge: interactionBridge)
          .frame(
            width: AnnotateTextFrameGeometry.emojiButtonDiameter,
            height: AnnotateTextFrameGeometry.emojiButtonDiameter
          )
          .position(emojiButtonCenter(for: displayBounds, fieldHeight: fieldHeight))
          .accessibilityLabel(L10n.AnnotateUI.textEmojiAndSymbols)
          .onChange(of: editingText) { newValue in
            // Live-update annotation text and bounds
            if let editingId = state.editingTextAnnotationId {
              state.updateAnnotationText(id: editingId, text: newValue)
            }
          }
      }
    }
  }

  /// Центр кнопки эмодзи: над рамкой, а если сверху нет места (рамка у
  /// верхнего края холста, оверлей там обрезается) – под рамкой.
  private func emojiButtonCenter(for displayBounds: CGRect, fieldHeight: CGFloat) -> CGPoint {
    let offset = AnnotateTextFrameGeometry.emojiButtonCenterAboveFrame
    let radius = AnnotateTextFrameGeometry.emojiButtonDiameter / 2
    let aboveY = displayBounds.minY - offset
    let y = aboveY - radius >= 0 ? aboveY : displayBounds.minY + fieldHeight + offset
    return CGPoint(x: displayBounds.midX, y: y)
  }

  /// Convert image bounds to display coordinates
  /// The parent view supplies a frame that matches the active canvas bounds.
  /// Crop offset is handled by this conversion, so we only:
  /// 1. Scale the bounds
  /// 2. Flip Y axis (AppKit bottom-left origin → SwiftUI top-left origin)
  private func calculateDisplayBounds(_ imageBounds: CGRect) -> CGRect {
    // Scale the bounds
    let scaledX = (imageBounds.origin.x - canvasBounds.minX) * scale
    let scaledWidth = imageBounds.width * scale
    let scaledHeight = imageBounds.height * scale

    // Flip Y axis: AppKit uses bottom-left origin, SwiftUI uses top-left
    // In AppKit: y=0 is bottom, y increases upward
    // In SwiftUI: y=0 is top, y increases downward
    let flippedY = (canvasBounds.maxY - imageBounds.origin.y - imageBounds.height) * scale

    return CGRect(
      x: scaledX,
      y: flippedY,
      width: scaledWidth,
      height: scaledHeight
    )
  }

  private func calculateDisplayPoint(_ imagePoint: CGPoint) -> CGPoint {
    CGPoint(
      x: (imagePoint.x - canvasBounds.minX) * scale,
      y: (canvasBounds.maxY - imagePoint.y) * scale
    )
  }

  private func commitEdit(id: UUID) {
    if state.editingTextAnnotationId == id {
      state.updateAnnotationText(id: id, text: editingText)
      state.commitTextEditing()
    }
  }

  private func cancelEdit() {
    // If it was a new annotation with empty text, delete it
    if let editingId = state.editingTextAnnotationId,
       let annotation = state.annotations.first(where: { $0.id == editingId }),
       case .text(let text) = annotation.type,
       text.isEmpty {
      state.annotations.removeAll { $0.id == editingId }
      state.selectedAnnotationId = nil
    }
    state.finishTextEditing()
  }
}

private struct TextBubbleShape: Shape {
  let tailTarget: CGPoint?
  let fontSize: CGFloat
  let cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let resolvedCornerRadius = cornerRadius > 0
      ? min(cornerRadius, min(rect.width, rect.height) * 0.46)
      : TextBubbleGeometry.cornerRadius(in: rect, fontSize: fontSize)
    return Path(
      TextBubbleGeometry.bubblePath(
        in: rect,
        cornerRadius: resolvedCornerRadius,
        tailTarget: tailTarget,
        fontSize: fontSize
      )
    )
  }
}

/// Круглая синяя кнопка с белым смайликом над рамкой текста в правке.
/// Отдельный AppKit-вид: прокси холста передаёт нажатия только зарегистрированным
/// в мосте видам, а фокус ввода должен остаться у редактора текста.
private struct TextEmojiPaletteButton: NSViewRepresentable {
  var interactionBridge: CanvasInteractionBridge?

  func makeNSView(context _: Context) -> EmojiPaletteButtonView {
    let view = EmojiPaletteButtonView()
    view.interactionBridge = interactionBridge
    interactionBridge?.textEditorAccessory = view
    return view
  }

  func updateNSView(_ view: EmojiPaletteButtonView, context _: Context) {
    view.interactionBridge = interactionBridge
    interactionBridge?.textEditorAccessory = view
  }

  static func dismantleNSView(_ view: EmojiPaletteButtonView, coordinator _: ()) {
    if view.interactionBridge?.textEditorAccessory === view {
      view.interactionBridge?.textEditorAccessory = nil
    }
    view.interactionBridge = nil
  }

  final class EmojiPaletteButtonView: NSView {
    weak var interactionBridge: CanvasInteractionBridge?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with _: NSEvent) {
      // Палитра вставляет символ в первого ответчика окна – редактор текста.
      if let editor = interactionBridge?.textEditor, let window = editor.window,
         window.firstResponder !== editor {
        window.makeFirstResponder(editor)
      }
      NSApp.orderFrontCharacterPalette(nil)
    }

    override func draw(_: NSRect) {
      let border: CGFloat = 2
      let circle = bounds.insetBy(dx: border / 2, dy: border / 2)
      let background = NSBezierPath(ovalIn: circle)
      NSColor.systemBlue.setFill()
      background.fill()
      NSColor.white.setStroke()
      background.lineWidth = border
      background.stroke()

      // Смайлик: два глаза и улыбка белым, как на кнопке эталона.
      let side = min(bounds.width, bounds.height)
      let center = CGPoint(x: bounds.midX, y: bounds.midY)
      let eyeRadius = side * 0.06
      let eyeOffsetX = side * 0.13
      let eyeY = center.y - side * 0.08
      NSColor.white.setFill()
      for dx in [-eyeOffsetX, eyeOffsetX] {
        NSBezierPath(ovalIn: CGRect(
          x: center.x + dx - eyeRadius,
          y: eyeY - eyeRadius,
          width: eyeRadius * 2,
          height: eyeRadius * 2
        )).fill()
      }
      let smile = NSBezierPath()
      // isFlipped: в координатах вида Y растёт вниз, дуга улыбки снизу центра.
      smile.appendArc(
        withCenter: CGPoint(x: center.x, y: center.y + side * 0.02),
        radius: side * 0.2,
        startAngle: 30,
        endAngle: 150
      )
      smile.lineWidth = max(side * 0.07, 1.5)
      smile.lineCapStyle = .round
      NSColor.white.setStroke()
      smile.stroke()
    }
  }
}

private struct InlineAnnotationTextEditor: NSViewRepresentable {
  let editingId: UUID
  @Binding var text: String
  let font: NSFont
  let textContainerInset: NSSize
  let textColor: NSColor
  let onCommit: () -> Void
  let onCancel: () -> Void
  let onUndo: () -> Void
  let onRedo: () -> Void
  var interactionBridge: CanvasInteractionBridge?

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> UndoIsolatedTextView {
    let textView = UndoIsolatedTextView()
    textView.delegate = context.coordinator
    textView.string = text
    textView.onCommit = onCommit
    textView.onCancel = onCancel
    textView.onUndo = onUndo
    textView.onRedo = onRedo

    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = textContainerInset
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.lineBreakMode = .byWordWrapping
    textView.font = font
    textView.textColor = textColor
    // Каретка эталона – акцент темы 2 pt высотой в строку (spec-066 R04/F8,
    // spec-063-live/b3r-text-ref-1.png, b3r-text-ref-4.png), а не цвет текста.
    textView.insertionPointColor = UndoIsolatedTextView.caretColor
    context.coordinator.focusedEditingId = editingId
    textView.interactionBridge = interactionBridge
    interactionBridge?.textEditor = textView
    textView.requestInitialFocus()

    return textView
  }

  func updateNSView(_ textView: UndoIsolatedTextView, context: Context) {
    context.coordinator.text = $text
    textView.onCommit = onCommit
    textView.onCancel = onCancel
    textView.onUndo = onUndo
    textView.onRedo = onRedo
    textView.interactionBridge = interactionBridge
    interactionBridge?.textEditor = textView

    if textView.string != text {
      context.coordinator.isApplyingExternalText = true
      textView.string = text
      context.coordinator.isApplyingExternalText = false
    }
    if textView.font != font {
      textView.font = font
    }
    if textView.textContainerInset != textContainerInset {
      textView.textContainerInset = textContainerInset
    }
    if textView.textColor != textColor {
      textView.textColor = textColor
    }
    if textView.insertionPointColor != UndoIsolatedTextView.caretColor {
      textView.insertionPointColor = UndoIsolatedTextView.caretColor
    }
    if context.coordinator.focusedEditingId != editingId {
      context.coordinator.focusedEditingId = editingId
      textView.requestInitialFocus()
    }

    // The annotation can grow or move while an IME composition is active.
    // Tell AppKit to ask for the caret rectangle again after this layout pass,
    // so its candidate window follows the current character rather than an
    // earlier position in the text.
    textView.refreshInputMethodPlacement()
  }

  static func dismantleNSView(_ textView: UndoIsolatedTextView, coordinator: Coordinator) {
    if textView.interactionBridge?.textEditor === textView {
      textView.interactionBridge?.textEditor = nil
    }
    textView.interactionBridge = nil
    textView.onCommit = nil
    textView.onCancel = nil
    textView.onUndo = nil
    textView.onRedo = nil
    textView.delegate = nil
    textView.undoManager?.removeAllActions()
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var isApplyingExternalText = false
    var focusedEditingId: UUID?

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingExternalText,
            let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      (notification.object as? UndoIsolatedTextView)?.refreshInputMethodPlacement()
    }

    func textDidEndEditing(_ notification: Notification) {
      guard let textView = notification.object as? UndoIsolatedTextView else { return }
      textView.onCommit?()
    }
  }

  final class UndoIsolatedTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    weak var interactionBridge: CanvasInteractionBridge?
    private var wantsInitialFocus = false
    private var hasPendingInputMethodPlacementRefresh = false

    /// Пока правка не получила ни одного своего нажатия мыши: первое нажатие
    /// двойного клика пришлось на холст и само открыло правку.
    private var hasReceivedMouseDown = false

    /// Акцент темы: raw #EC5F5D (sRGB #FF5257) в тёмной теме на кадрах b3r-text-ref-1/4.
    /// Прежняя тёмная каретка NSColor.textColor держалась на ошибочной записи реестра.
    /// Ширину 2 pt даёт системный индикатор вставки, её не переопределяем.
    static let caretColor: NSColor = OwnShotEditorChrome.accentNSColor

    override var undoManager: UndoManager? { nil }
    override var acceptsFirstResponder: Bool { true }

    /// Второе нажатие двойного клика, начавшего правку (Text или Move по тексту),
    /// у эталона оставляет каретку в конце, а не выделяет слово (ANN-104).
    override func mouseDown(with event: NSEvent) {
      defer { hasReceivedMouseDown = true }
      if AnnotateTextFrameGeometry.keepsCaretAtEnd(
        clickCount: event.clickCount,
        hasReceivedMouseDown: hasReceivedMouseDown
      ) {
        let endLocation = (string as NSString).length
        setSelectedRange(NSRange(location: endLocation, length: 0))
        return
      }
      super.mouseDown(with: event)
    }

    override func didChangeText() {
      super.didChangeText()
      refreshInputMethodPlacement()
    }

    /// Inline annotation text changes its frame as the user types. Input
    /// methods cache character coordinates, so refresh them on the next run
    /// loop after AppKit has applied the new frame and layout.
    func refreshInputMethodPlacement() {
      guard !hasPendingInputMethodPlacementRefresh else { return }
      hasPendingInputMethodPlacementRefresh = true

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.hasPendingInputMethodPlacementRefresh = false
        if let textContainer = self.textContainer {
          self.layoutManager?.ensureLayout(for: textContainer)
        }
        self.inputContext?.invalidateCharacterCoordinates()
      }
    }

    func requestInitialFocus() {
      wantsInitialFocus = true
      hasReceivedMouseDown = false
      focusWhenReady(attempt: 0)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if wantsInitialFocus {
        focusWhenReady(attempt: 0)
      }
    }

    private func focusWhenReady(attempt: Int) {
      let delay = attempt == 0 ? 0 : 0.01
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.wantsInitialFocus else { return }

        if let window = self.window {
          if !window.isKeyWindow {
            window.makeKey()
          }
          window.makeFirstResponder(self)
          if window.firstResponder === self {
            let endLocation = (self.string as NSString).length
            self.setSelectedRange(NSRange(location: endLocation, length: 0))
            self.wantsInitialFocus = false
            return
          }
        }

        if attempt < 8 {
          self.focusWhenReady(attempt: attempt + 1)
        }
      }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard event.type == .keyDown else {
        return super.performKeyEquivalent(with: event)
      }

      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if event.keyCode == 6 && flags == .command {
        onUndo?()
        return true
      }
      if event.keyCode == 6 && flags == [.command, .shift] {
        onRedo?()
        return true
      }

      return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if (event.keyCode == 36 || event.keyCode == 76), flags == .command {
        onCommit?()
        return
      }
      if event.keyCode == 53 {
        onCancel?()
        return
      }
      super.keyDown(with: event)
    }
  }
}
