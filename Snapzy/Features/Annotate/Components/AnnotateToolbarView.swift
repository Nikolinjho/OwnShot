//
//  AnnotateToolbarView.swift
//  Snapzy
//
//  Top toolbar with annotation tools and actions
//

import SwiftUI

private enum AnnotateToolbarActionRegistration: Equatable {
  case annotateDefault
  case crop
  case cutOut
}

/// Top toolbar containing all annotation tools
struct AnnotateToolbarView: View {
  @ObservedObject var state: AnnotateState
  @AppStorage(PreferencesKeys.backgroundCutoutAutoCropEnabled) private var backgroundCutoutAutoCropEnabled = true
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.colorScheme) private var colorScheme
  /// С Option кнопка Save as… сохраняет без диалога (changelog 4.1, flagsChanged: у Annotate).
  @ObservedObject private var optionKeyMonitor = AnnotateOptionKeyMonitor.shared

  private var isOptionHeld: Bool { optionKeyMonitor.isOptionHeld && controlActiveState != .inactive }

  private var isInactive: Bool { controlActiveState == .inactive }

  /// Инструмент под указателем: его ячейка подсвечивается и прячет соседние разделители (R18, N07).
  @State private var hoveredTool: AnnotationToolType?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      toolbarContent(spacing: 12)
      toolbarContent(spacing: 4)
    }
    .tint(Color(red: 1, green: 0.31, blue: 0.34))
    .padding(.leading, 96)
    .padding(.trailing, 13)
    .padding(.top, 1.5)
    .frame(height: 50.5)
    .background {
      // Полупрозрачный тинт поверх прозрачного окна, как у эталона (ANN-360, 808).
      // Лежит под всей полосой, от левого края окна с зоной светофора до правого:
      // фон не ограничивается безопасной областью заголовка.
      ZStack {
        AnnotateEditorBarBackground()
        AnnotateEditorBarTint()
      }
      .ignoresSafeArea()
    }
    .animation(.easeInOut(duration: 0.16), value: activeActionRegistration)

    .alert(
      L10n.AnnotateUI.backgroundCutoutTitle,
      isPresented: Binding(
        get: { state.cutoutErrorMessage != nil },
        set: { if !$0 { state.cutoutErrorMessage = nil } }
      )
    ) {
      Button(L10n.Common.ok, role: .cancel) {}
    } message: {
      Text(state.cutoutErrorMessage ?? L10n.AnnotateUI.unableToRemoveBackground)
    }
  }

  /// На узком окне уменьшаются промежутки между группами. Кнопки и крайние отступы сохраняются.
  private func toolbarContent(spacing: CGFloat) -> some View {
    HStack(spacing: spacing) {
      // Left group: Capture tools
      if activeActionRegistration == .crop {
        ToolbarButton(icon: "crop", isSelected: true, activeGlassTint: nil) {
          state.revertCropToOriginalBounds()
        }
        .ownShotNonFocusable()
      } else {
        captureToolsGroup
      }

      if activeActionRegistration == .crop {
        ViewThatFits(in: .horizontal) {
          CropToolbarView(state: state)
          CropToolbarView(state: state, compact: true)
        }
      } else {
        annotationToolsGroup
        AnnotateInlineProperties(state: state)
      }

      Spacer(minLength: 0)

      registeredActionButtons
    }
  }

  // MARK: - Tool Groups

  private var captureToolsGroup: some View {
    HStack(spacing: 6) {
      captureButton(.crop, isSelected: state.selectedTool == .crop) {
        state.beginCropInteraction()
      }
      .help("Crop & Resize (K)")

      captureButton(.addImage, isSelected: false) {
        guard let window = NSApp.keyWindow else { return }
        NotificationCenter.default.post(name: .annotateAddImage, object: window)
      }.help(L10n.AnnotateUI.addScreenshot)

      captureButton(.background, isSelected: state.showSidebar) {
        state.toggleSidebarVisibility()
      }
      .help(L10n.AnnotateUI.addBackground("B"))

    }
    .contextMenu {
        Button("Cut Out") { state.beginCutOutInteraction() }.disabled(!state.canApplyCutOut)
        Button("Rotate Left") { state.rotateImage(clockwise: false) }.disabled(!state.canRotateImage)
        Button("Rotate Right") { state.rotateImage(clockwise: true) }.disabled(!state.canRotateImage)
        Divider()
        Button("Undo") { state.undo() }.disabled(!state.canUndo)
        Button("Redo") { state.redo() }.disabled(!state.canRedo)
        Divider()
        Button("Measure") { state.activateTool(.measure) }
          .disabled(state.editorMode == .mockup)
        Button("Watermark") { state.activateTool(.watermark) }
          .disabled(state.editorMode == .mockup)
        Button("Remove Background") { state.toggleBackgroundCutout() }
          .disabled(!state.canUseBackgroundCutout || !state.hasImage || state.isCutoutProcessing)
    }
  }

  /// Cut out sits with rotate so Crop/Sidebar keep their established positions.
  private var imageTransformButtonsGroup: some View {
    HStack(spacing: 4) {
      ToolbarButton(
        icon: "scissors",
        isSelected: state.selectedTool == .cutOut,
        activeGlassTint: nil
      ) {
        state.beginCutOutInteraction()
      }
      .help(L10n.AnnotateUI.cutOut)
      .disabled(!state.canApplyCutOut)
      .opacity(state.canApplyCutOut ? 1 : 0.4)

      ToolbarButton(icon: "rotate.left", isSelected: false) {
        state.rotateImage(clockwise: false)
      }
      .help(L10n.AnnotateUI.rotateLeft)
      .disabled(!state.canRotateImage)

      ToolbarButton(icon: "rotate.right", isSelected: false) {
        state.rotateImage(clockwise: true)
      }
      .help(L10n.AnnotateUI.rotateRight)
      .disabled(!state.canRotateImage)
    }
  }

  private var annotationToolsGroup: some View {
    HStack(spacing: 0) {
      ForEach(Array(groupTools.enumerated()), id: \.element) { index, tool in
        annotationToolButton(for: tool, index: index)
      }
    }
    // Капсула полупрозрачная поверх материала панели (ANN-809).
    .background(colorScheme == .dark
      ? Color.white.opacity(AnnotateEditorBarMetrics.darkToolGroupWhiteOpacity)
      : Color.black.opacity(AnnotateEditorBarMetrics.lightToolGroupBlackOpacity), in: Capsule())
    .clipShape(Capsule())
  }

  private func captureButton(_ glyph: AnnotateCaptureGlyph.Kind, isSelected: Bool,
    action: @escaping () -> Void) -> some View {
    Button(action: action) {
      AnnotateCaptureGlyph(kind: glyph)
        .frame(width: 20, height: 20)
        // Глиф кнопок захвата в неактивном окне не тускнеет: #191919 / #E5E5E5 в обоих
        // состояниях (R15, spec-051-pairs/reference-*/editor-inactive-on-000000.png).
        .foregroundStyle(Color.primary)
        .frame(width: 36, height: 26)
        .modifier(OwnShotEditorCapsule(isActive: isSelected))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .ownShotNonFocusable()
    .accessibilityLabel(glyph.accessibilityLabel)
  }

  private var drawingTools: [AnnotationToolType] {
    AnnotationToolType.drawableTools.filter { $0 != .measure && $0 != .watermark }
  }

  /// Ячейки группы инструментов слева направо: курсор и инструменты рисования.
  private var groupTools: [AnnotationToolType] {
    [.selection] + drawingTools
  }

  private var backgroundCutoutButton: some View {
    ToolbarButton(
      icon: state.isCutoutProcessing ? "hourglass" : "wand.and.stars",
      isSelected: state.isCutoutApplied,
      activeGlassTint: nil
    ) {
      state.toggleBackgroundCutout()
    }
    .disabled(!state.canUseBackgroundCutout || !state.hasImage || state.isCutoutProcessing)
    .opacity((!state.canUseBackgroundCutout || !state.hasImage) ? 0.4 : 1)
    .help(
      state.canUseBackgroundCutout
        ? (state.isCutoutApplied
          ? L10n.AnnotateUI.backgroundRemovedClickToRestore
          : (backgroundCutoutAutoCropEnabled
            ? L10n.AnnotateUI.removeBackgroundAutoCropsWhenSafe
            : L10n.AnnotateUI.removeBackgroundAutoCropDisabledInSettings))
        : L10n.AnnotateUI.requiresMacOS14OrLater
    )
  }

  @ViewBuilder
  private func annotationToolButton(for tool: AnnotationToolType, index: Int) -> some View {
    let isSelected = state.selectedTool == tool
    let tools = groupTools
    Button {
      state.activateTool(tool)
    } label: {
      AnnotateToolGlyph(tool: tool).frame(width: 18, height: 18)
        .frame(width: tool == .selection ? 35 : 36, height: 24)
        .background {
          if isSelected {
            Capsule().fill(selectedToolFill)
          } else if hoveredTool == tool {
            // Наведённая ячейка – нейтральная капсула той же геометрии, глиф не меняется (N07).
            Capsule().fill(OwnShotEditorChrome.toolHoverColor(for: colorScheme))
          }
        }
        .overlay(alignment: .leading) {
          // Разделитель 1×14 pt прячется с обеих сторон выбранной и наведённой ячейки (R18).
          if OwnShotEditorChrome.showsToolSeparator(
            beforeIndex: index,
            selectedIndex: tools.firstIndex(of: state.selectedTool),
            hoveredIndex: hoveredTool.flatMap { tools.firstIndex(of: $0) }
          ) {
            Rectangle().fill(OwnShotEditorChrome.toolSeparatorColor(for: colorScheme))
              .frame(width: OwnShotEditorChrome.toolSeparatorSize.width,
                height: OwnShotEditorChrome.toolSeparatorSize.height)
          }
        }
        .foregroundStyle(toolGlyphColor(isSelected: isSelected))
        // Кнопка нажимается во всей ячейке 36×24, а не только по штрихам значка:
        // иначе клик внутрь контура Rectangle, Ellipse, Text, Arrow не попадает в кнопку.
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .ownShotNonFocusable()
    .onHover { inside in
      if inside {
        hoveredTool = tool
      } else if hoveredTool == tool {
        hoveredTool = nil
      }
    }
    .help(tool.displayName)
    .accessibilityLabel(tool.displayName)
    .disabled(state.editorMode == .mockup && tool != .selection)
    .opacity(state.editorMode == .mockup && tool != .selection ? 0.4 : 1)
  }

  /// Капсула выбранного инструмента: красная в обеих темах (R05), в неактивном окне серая (R14).
  private var selectedToolFill: Color {
    guard isInactive else { return Color(red: 1, green: 0.31, blue: 0.34) }
    return OwnShotEditorChrome.color(colorScheme == .dark
      ? OwnShotEditorChrome.inactiveDarkSelectedToolRGB : OwnShotEditorChrome.inactiveLightSelectedToolRGB)
  }

  /// Глиф ячейки: белый на акценте; в неактивном окне глифы группы светлеют (кадры R14).
  private func toolGlyphColor(isSelected: Bool) -> Color {
    guard isInactive else { return isSelected ? Color.white : Color.primary }
    let isDark = colorScheme == .dark
    if isSelected {
      return OwnShotEditorChrome.color(isDark
        ? OwnShotEditorChrome.inactiveDarkSelectedGlyphRGB : OwnShotEditorChrome.inactiveLightSelectedGlyphRGB)
    }
    return OwnShotEditorChrome.color(isDark
      ? OwnShotEditorChrome.inactiveDarkToolGlyphRGB : OwnShotEditorChrome.inactiveLightToolGlyphRGB)
  }

  /// Основная кнопка панели: акцент темы (R04), в неактивном окне серая с белым текстом (R14).
  private var primaryButtonFill: Color {
    guard isInactive else { return OwnShotEditorChrome.accent(for: colorScheme) }
    return OwnShotEditorChrome.color(colorScheme == .dark
      ? OwnShotEditorChrome.inactiveDarkPrimaryButtonRGB : OwnShotEditorChrome.inactiveLightPrimaryButtonRGB)
  }

  private var undoRedoGroup: some View {
    HStack(spacing: 4) {
      ToolbarButton(icon: "arrow.uturn.backward", isSelected: false) {
        state.undo()
      }
      .help(L10n.Common.undo)
      .disabled(!state.canUndo)

      ToolbarButton(icon: "arrow.uturn.forward", isSelected: false) {
        state.redo()
      }
      .help(L10n.Common.redo)
      .disabled(!state.canRedo)
    }
  }

  private var activeActionRegistration: AnnotateToolbarActionRegistration {
    if state.selectedTool == .crop && state.isCropActive {
      return .crop
    }
    if state.selectedTool == .cutOut && state.isCutOutActive {
      return .cutOut
    }

    return .annotateDefault
  }

  @ViewBuilder
  private var registeredActionButtons: some View {
    switch activeActionRegistration {
    case .annotateDefault:
      annotateActionButtons
        .transition(.move(edge: .trailing))
    case .crop:
      cropActionButtons
        .transition(.move(edge: .trailing))
    case .cutOut:
      cutOutActionButtons
        .transition(.move(edge: .trailing))
    }
  }

  private var annotateActionButtons: some View {
    HStack(spacing: 8) {
      Button(action: isOptionHeld ? done : saveAs) {
        Text(AnnotateOptionKeyMonitor.saveButtonTitle(optionHeld: isOptionHeld))
          .font(.system(size: 13))
          .foregroundStyle(.primary)
          .frame(width: 77, height: 26)
          .background(Color.primary.opacity(isInactive ? 0.08 : 0.12), in: Capsule())
      }
      .buttonStyle(.plain)
      .ownShotNonFocusable()
      .help(isOptionHeld ? L10n.string(
        "annotate.toolbar.save-option-help",
        defaultValue: "Save to export location and exit",
        comment: "Tooltip for the Save as button while Option is held"
      ) : L10n.string(
        "annotate.toolbar.save-as-help",
        defaultValue: "Choose export location (⇧⌘S)",
        comment: "Tooltip for the Save as button in the annotate toolbar"
      ))

      // Done справа от Save as: сохранить на место и закрыть (⌘S).
      Button(action: done) {
        Text(L10n.Common.done)
          .font(.system(size: 13))
          .foregroundStyle(.white)
          .frame(width: 58, height: 26)
          .background(primaryButtonFill, in: Capsule())
          // Красное свечение под основной кнопкой в светлой активной теме (ANN-812).
          .shadow(color: OwnShotEditorChrome.accent(for: colorScheme).opacity(
            colorScheme == .light && !isInactive ? AnnotateEditorBarMetrics.saveGlowOpacity : 0),
            radius: AnnotateEditorBarMetrics.saveGlowRadius, y: AnnotateEditorBarMetrics.saveGlowOffsetY)
      }
      .buttonStyle(.plain)
      .ownShotNonFocusable()
      .help(L10n.string(
        "annotate.toolbar.done-help",
        defaultValue: "Save and exit (⌘S)",
        comment: "Tooltip for the Done button in the annotate toolbar"
      ))
    }
  }

  private var cropActionButtons: some View {
    HStack(spacing: 8) {
      Button(L10n.Common.cancel) {
        state.cancelCrop()
      }
      .buttonStyle(.liquidGlass(emphasis: .secondary, capsule: true))
      .ownShotNonFocusable()

      Button("Crop") {
        state.confirmCropInteraction()
      }
      .buttonStyle(.liquidGlass(emphasis: .primary, capsule: true))
      .ownShotNonFocusable()
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var cutOutActionButtons: some View {
    HStack(spacing: 8) {
      Button(L10n.Common.cancel) {
        state.cancelCutOut()
      }
      .buttonStyle(.liquidGlass(emphasis: .secondary, capsule: true))
      .ownShotNonFocusable()

      Button(state.cutOutMode == .remove ? L10n.AnnotateUI.cutOut : L10n.AnnotateUI.cutOutInsert) {
        state.commitCutOut()
      }
      .buttonStyle(.liquidGlass(emphasis: .primary, capsule: true))
      .ownShotNonFocusable()
      .disabled(state.cutOutPreviewStrip == nil)
      .opacity(state.cutOutPreviewStrip == nil ? 0.4 : 1)
    }
  }

  // MARK: - Actions

  private func saveAs() {
    if state.isCombineMode {
      guard let window = NSApp.keyWindow else { return }
      NotificationCenter.default.post(name: .annotateSave, object: window)
    } else {
      // Save As ведёт контроллер окна: меню формата, проект и политика закрытия в одном месте.
      guard let window = NSApp.keyWindow else { return }
      NotificationCenter.default.post(name: .annotateSaveAs, object: window)
    }
  }

  private func done() {
    // Post save notification — controller handles silent save + cache + QA refresh + close
    guard let window = NSApp.keyWindow else { return }
    NotificationCenter.default.post(name: .annotateSave, object: window)
  }
}
