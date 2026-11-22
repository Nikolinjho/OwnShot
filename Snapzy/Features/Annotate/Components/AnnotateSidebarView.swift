//
//  AnnotateSidebarView.swift
//  Snapzy
//
//  Left sidebar for background and styling settings
//

import AppKit
import SwiftUI

/// Control heights the Annotate sidebar is laid out at, so its corner radii stay derived rather
/// than guessed. The sidebar's buttons, selects and preset rows all land on one 26–30pt step.
enum AnnotateSidebarMetrics {
  static let control: CGFloat = 28
  static let inlineFieldHeight: CGFloat = 18
  static var controlRadius: CGFloat { Radius.control(forHeight: control) }
  /// Ширина сайдбара эталона (AX scroll area 250 pt).
  static let width: CGFloat = AnnotateBackgroundPanelLayout.sidebarWidth
}

private struct AnnotateSidebarSnapshot: Equatable {
  let editorMode: AnnotateState.EditorMode
  let backgroundStyle: BackgroundStyle
  let isBlurredBackgroundEnabled: Bool
  let blurredBackgroundEffect: BlurredBackgroundEffect
  let padding: CGFloat
  let previewPadding: CGFloat?
  let inset: CGFloat
  let previewInset: CGFloat?
  let autoBalance: Bool
  let shadowIntensity: CGFloat
  let previewShadowIntensity: CGFloat?
  let cornerRadius: CGFloat
  let previewCornerRadius: CGFloat?
  let imageAlignment: ImageAlignment
  let aspectRatio: AspectRatioOption
  let aspectRatioOrientation: AspectRatioOrientation
  let canvasPresets: [AnnotateCanvasPreset]
  let selectedCanvasPresetId: UUID?
  let isSelectedCanvasPresetDirty: Bool
  let defaultCanvasPresetId: UUID?
  let isCombineMode: Bool
  let combineMode: CombineImagesMode
  let combineDirection: CombineImagesDirection
  let combineResolvedDirection: CombineImagesDirection
  let combineGap: CGFloat

  init(state: AnnotateState) {
    editorMode = state.editorMode
    backgroundStyle = state.backgroundStyle
    isBlurredBackgroundEnabled = state.isBlurredBackgroundEnabled
    blurredBackgroundEffect = state.blurredBackgroundEffect
    padding = state.padding
    previewPadding = state.previewPadding
    inset = state.inset
    previewInset = state.previewInset
    autoBalance = state.autoBalance
    shadowIntensity = state.shadowIntensity
    previewShadowIntensity = state.previewShadowIntensity
    cornerRadius = state.cornerRadius
    previewCornerRadius = state.previewCornerRadius
    imageAlignment = state.imageAlignment
    aspectRatio = state.aspectRatio
    aspectRatioOrientation = state.aspectRatioOrientation
    canvasPresets = state.canvasPresets
    selectedCanvasPresetId = state.selectedCanvasPresetId
    isSelectedCanvasPresetDirty = state.isSelectedCanvasPresetDirty
    defaultCanvasPresetId = state.defaultCanvasPresetId
    isCombineMode = state.isCombineMode
    combineMode = state.combineMode
    combineDirection = state.combineDirection
    combineResolvedDirection = state.combineResolvedDirection
    combineGap = state.combineGap
  }
}

/// Left sidebar with background customization options
struct AnnotateSidebarView: View, Equatable {
  let state: AnnotateState
  private let snapshot: AnnotateSidebarSnapshot
  @State private var isPresetDropdownPresented = false
  /// Show less/Show more секции Gradients: 20 плиток в раскрытом виде, 10 в свёрнутом.
  @State private var isGradientListExpanded = true

  init(state: AnnotateState) {
    self.state = state
    snapshot = AnnotateSidebarSnapshot(state: state)
  }

  static func == (lhs: AnnotateSidebarView, rhs: AnnotateSidebarView) -> Bool {
    lhs.snapshot == rhs.snapshot
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Эталон: Presets..., None, Gradients, Wallpapers, Blurred, Plain color.
        presetControlsSection

        // Compact gradient section
        gradientSection

        // Wallpaper section
        wallpaperSection

        // Blurred background section
        blurredSection

        // Compact color section
        colorSection

        Divider().background(Color(nsColor: .separatorColor))

        // Sliders section
        slidersSection

        // Alignment и Ratio в одну строку, как в эталоне
        if !state.isCombineMode {
          HStack(alignment: .top, spacing: Spacing.md) {
            alignmentSection
            Spacer(minLength: 0)
            ratioSection
          }
        }

        // Mockup section (shown when mockup mode is active)
        if state.editorMode == .mockup {
          Divider().background(Color(nsColor: .separatorColor))
          MockupControlsSection(state: state)
        }

        if state.isCombineMode {
          AnnotateCombineControlsView(state: state)
        }

        Spacer(minLength: Spacing.lg)
      }
      // Эталон: список шириной 227 pt с отступом 11 pt слева.
      .padding(.vertical, Spacing.md)
      .padding(.leading, AnnotateBackgroundPanelLayout.leadingPadding)
      .padding(.trailing, AnnotateBackgroundPanelLayout.trailingPadding)
    }
    .frame(maxHeight: .infinity)
//    .background(Color(nsColor: .scrubberTexturedBackground))
  }

  // MARK: - Preset Controls

  private var presetControlsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Эталон: широкий Presets... с chevron, справа отдельный plus 20 × 20 pt.
      HStack(spacing: Spacing.xs) {
        presetDropdownButton

        if state.canUpdateSelectedCanvasPreset {
          presetIconButton(resourceName: "annotatePresetSave", help: AnnotateBackgroundPanelStrings.savePresetChanges) {
            handleUpdatePreset()
          }
        }

        if let preset = state.selectedCanvasPreset {
          presetIconButton(resourceName: "annotatePresetTrash", help: L10n.AnnotateUI.deletePresetHelp) {
            handleDeletePreset(preset)
          }
        }

        presetIconButton(resourceName: "annotatePresetNew", help: L10n.AnnotateUI.addNewPreset) {
          handleCreatePreset()
        }
        .disabled(state.isCanvasPresetLimitReached)
      }

      noneButton
    }
  }

  /// Глифы пресетов эталона в собственном размере: annotatePresetSave 12×7,
  /// annotatePresetTrash 11×13, annotatePresetNew 11×11 pt.
  private func presetIconButton(resourceName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      OwnShotIcons.image(resourceName)
        .renderingMode(.template)
        .foregroundColor(SidebarColors.labelSecondary)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  /// Строка None на всю ширину под Presets..., как первая секция списка эталона.
  private var noneButton: some View {
    Button {
      state.selectNoneCanvasEffects()
    } label: {
      Text(L10n.Common.none)
        .font(Typography.labelSmall)
        .foregroundColor(SidebarColors.labelPrimary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 7)
        .frame(height: AnnotateSidebarMetrics.control)
        .background(
          Capsule(style: .continuous)
            .fill(state.isNoneCanvasEffectsActive ? Color.accentColor.opacity(0.25) : SidebarColors.itemDefault)
        )
        .overlay(
          Capsule(style: .continuous)
            .stroke(
              state.isNoneCanvasEffectsActive ? Color.accentColor : Color.clear,
              lineWidth: Size.strokeSelected
            )
        )
    }
    .buttonStyle(.plain)
    .help(L10n.AnnotateUI.resetCanvasEffectsHelp)
  }

  private var presetDropdownButton: some View {
    Button {
      isPresetDropdownPresented = true
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(state.selectedCanvasPreset?.name ?? AnnotateBackgroundPanelStrings.presetsPlaceholder)
          .font(Typography.labelSmall)
          .foregroundColor(SidebarColors.labelPrimary)
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: Spacing.xs)

        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(SidebarColors.labelSecondary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 7)
      .frame(height: AnnotateSidebarMetrics.control)
      .background(
        Capsule(style: .continuous)
          .fill(SidebarColors.itemDefault)
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(
            state.selectedCanvasPresetId != nil ? Color.accentColor.opacity(0.7) : Color.clear,
            lineWidth: Size.strokeDefault
          )
      )
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .help(L10n.AnnotateUI.applySavedStylePreset)
    .background(
      AnnotateBackgroundPresetMenuAnchor(
        isPresented: $isPresetDropdownPresented,
        configuration: presetMenuConfiguration
      )
    )
  }

  /// Пункты меню Presets...: пресеты, подменю Default Preset и Add New Preset...
  private var presetMenuConfiguration: AnnotateBackgroundPresetMenuController.Configuration {
    let state = self.state
    return AnnotateBackgroundPresetMenuController.Configuration(
      presets: state.canvasPresets.map { (id: $0.id, name: $0.name) },
      selectedId: state.selectedCanvasPresetId,
      defaultId: state.defaultCanvasPresetId,
      canAddPreset: !state.isCanvasPresetLimitReached,
      onSelect: { id in
        guard let preset = state.canvasPresets.first(where: { $0.id == id }) else { return }
        state.selectCanvasPresetFromSidebar(preset)
      },
      onSetDefault: { id in
        if let id {
          state.setDefaultCanvasPreset(id: id)
        } else {
          state.clearDefaultCanvasPreset()
        }
      },
      onAdd: { [self] in
        handleCreatePreset()
      }
    )
  }

  private func handleCreatePreset() {
    if state.isCanvasPresetLimitReached {
      showPresetLimitAlert()
      return
    }

    guard let name = promptForPresetName(
      title: L10n.AnnotateUI.savePresetTitle,
      message: AnnotateBackgroundPanelStrings.enterPresetName,
      defaultValue: state.nextSuggestedCanvasPresetName
    ) else {
      return
    }

    switch state.saveCurrentCanvasAsPreset(name: name) {
    case .success:
      return
    case .limitReached:
      showPresetLimitAlert()
    case .invalidName:
      return
    case .unavailablePayload:
      showPresetUnavailableAlert()
    case .missingSelection:
      return
    }
  }

  private func handleUpdatePreset() {
    // Кнопка Save changes to the preset эталона сохраняет без отдельного подтверждения.
    switch state.updateSelectedCanvasPreset() {
    case .success:
      return
    case .unavailablePayload:
      showPresetUnavailableAlert()
    case .missingSelection, .invalidName, .limitReached:
      return
    }
  }

  private func handleDeletePreset(_ preset: AnnotateCanvasPreset) {
    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.deletePresetTitle
    alert.informativeText = L10n.AnnotateUI.deletePresetMessage(preset.name)
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.deleteAction)
    alert.addButton(withTitle: L10n.Common.cancel)

    if alert.runModal() == .alertFirstButtonReturn {
      _ = state.deleteCanvasPreset(id: preset.id)
    }
  }

  private func promptForPresetName(
    title: String,
    message: String,
    defaultValue: String
  ) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: L10n.Common.save)
    alert.addButton(withTitle: L10n.Common.cancel)

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    textField.stringValue = defaultValue
    textField.placeholderString = L10n.AnnotateUI.presetNamePlaceholder
    alert.accessoryView = textField

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else {
      return nil
    }

    return AnnotateBackgroundPresetMenu.normalizedName(textField.stringValue)
  }

  private func showPresetLimitAlert() {
    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.presetLimitReachedTitle
    alert.informativeText = L10n.AnnotateUI.presetLimitReachedMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  private func showPresetUnavailableAlert() {
    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.unableToSavePresetTitle
    alert.informativeText = L10n.AnnotateUI.unableToSavePresetMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  // MARK: - Sections

  private var gradientSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        SidebarSectionHeader(title: L10n.Common.gradients)
        Spacer(minLength: 0)
        Button {
          isGradientListExpanded.toggle()
        } label: {
          Text(isGradientListExpanded ? AnnotateBackgroundPanelStrings.showLess : AnnotateBackgroundPanelStrings.showMore)
            .font(Typography.labelSmall)
            .foregroundColor(SidebarColors.labelSecondary)
        }
        .buttonStyle(.plain)
      }

      // Эталон: 20 плиток сеткой 5 × 4, Show less оставляет первые 2 ряда.
      // Плитки 43 × 43 pt без растягивания на ширину сайдбара.
      LazyVGrid(columns: AnnotateBackgroundTileGrid.columns, alignment: .leading, spacing: AnnotateBackgroundPanelLayout.tileSpacing) {
        ForEach(Self.visibleGradients(isExpanded: isGradientListExpanded)) { preset in
          GradientPresetButton(
            preset: preset,
            isSelected: state.backgroundStyle == .gradient(preset)
          ) {
            state.selectGradientBackground(preset)
          }
        }
      }
    }
  }

  static let collapsedGradientCount = 10

  /// Плитки градиентов для состояния Show less/Show more.
  static func visibleGradients(isExpanded: Bool) -> [GradientPreset] {
    isExpanded ? GradientPreset.allCases : Array(GradientPreset.allCases.prefix(collapsedGradientCount))
  }

  private var wallpaperSection: some View {
    SidebarWallpaperSection(state: state)
  }

  private var blurredSection: some View {
    SidebarBlurredSection(state: state)
  }

  private var colorSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      SidebarSectionHeader(title: AnnotateBackgroundPanelStrings.plainColor)
      AnnotateBackgroundColorPalette(
        selectedColor: colorBinding,
        onCustomColorEditingChanged: state.setCanvasEffectsGestureEditing
      )
    }
  }

  private var colorBinding: Binding<Color?> {
    Binding(
      get: {
        if case let .solidColor(color) = state.backgroundStyle {
          return color
        }
        return nil
      },
      set: { newColor in
        if let color = newColor {
          state.selectSolidColorBackground(color)
        }
      }
    )
  }

  // Эталон: Padding на всю ширину, Inset с Auto-balance, затем Shadow и Corners в одну строку.
  private var slidersSection: some View {
    VStack(alignment: .leading, spacing: AnnotateBackgroundPanelLayout.sliderRowSpacing) {
      CompactSliderRow(
        label: L10n.Common.padding,
        value: Binding(
          get: { state.padding },
          set: { state.setBackgroundPadding($0) }
        ),
        range: 0 ... 300,
        onDragging: { isDragging, value in
          state.previewPadding = isDragging ? value : nil
        },
        revealsValueOnHover: true,
        style: .background
      )

      HStack(alignment: .bottom, spacing: AnnotateBackgroundPanelLayout.sliderColumnSpacing) {
        CompactSliderRow(
          label: L10n.Common.inset,
          value: Binding(
            get: { state.inset },
            set: { state.setBackgroundInset($0) }
          ),
          range: AnnotateBackgroundInset.range,
          onDragging: { isDragging, value in
            state.previewInset = isDragging ? value : nil
          },
          revealsValueOnHover: true,
          style: .background
        )
        .frame(maxWidth: .infinity)

        Toggle(
          L10n.AnnotateUI.autoBalance,
          isOn: Binding(
            get: { state.autoBalance },
            set: { state.setBackgroundAutoBalance($0) }
          )
        )
        .toggleStyle(.checkbox)
        // У эталона Auto-balance – обычный флажок 13 pt (AX 102×18).
        .font(.system(size: AnnotateBackgroundPanelLayout.sliderLabelFontSize))
        .foregroundColor(SidebarColors.labelPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(alignment: .bottom, spacing: AnnotateBackgroundPanelLayout.sliderColumnSpacing) {
        // Эталон показывает Shadow в шкале 0…100, модель хранит долю 0…1
        CompactSliderRow(
          label: L10n.Common.shadow,
          value: Binding(
            get: { state.shadowIntensity * 100 },
            set: { state.setBackgroundShadowIntensity($0 / 100) }
          ),
          range: 0 ... 100,
          onDragging: { isDragging, value in
            state.previewShadowIntensity = isDragging ? value / 100 : nil
          },
          revealsValueOnHover: true,
          style: .background
        )
        .frame(maxWidth: .infinity)

        CompactSliderRow(
          label: L10n.Common.corners,
          value: Binding(
            get: { state.cornerRadius },
            set: { state.setBackgroundCornerRadius($0) }
          ),
          range: 0 ... 60,
          onDragging: { isDragging, value in
            state.previewCornerRadius = isDragging ? value : nil
          },
          revealsValueOnHover: true,
          style: .background
        )
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.leading, AnnotateBackgroundPanelLayout.slidersLeadingInset)
    .padding(.trailing, AnnotateBackgroundPanelLayout.slidersTrailingInset)
  }

  private var alignmentSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      SidebarSectionHeader(title: L10n.AnnotateUI.alignment)
      // Выбор, автоматический Padding 24 и белый фон – одна точка undo.
      AlignmentGrid(selected: Binding(
        get: { state.imageAlignment },
        set: { state.selectImageAlignment($0) }
      ))
    }
  }

  /// Popup Ratio эталона: Auto, 1 : 1, 5 : 4, 4 : 3, 3 : 2, 16 : 9, разделитель, 4 : 5, 3 : 4, 9 : 16.
  private var ratioSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      SidebarSectionHeader(title: AnnotateBackgroundPanelStrings.ratio)

      Picker("", selection: Binding<AnnotateBackgroundRatioChoice?>(
        get: {
          AnnotateBackgroundRatioChoice(option: state.aspectRatio, orientation: state.aspectRatioOrientation)
        },
        set: { choice in
          if let choice {
            state.selectBackgroundRatio(choice)
          }
        }
      )) {
        ForEach(AnnotateBackgroundRatioChoice.landscapeChoices) { choice in
          Text(choice.title).tag(Optional(choice))
        }
        Divider()
        ForEach(AnnotateBackgroundRatioChoice.portraitChoices) { choice in
          Text(choice.title).tag(Optional(choice))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.small)
      .frame(width: 82)
    }
    .frame(width: 102, alignment: .leading)
  }
}

// MARK: - Compact Components

struct AspectRatioOptionButton: View {
  let option: AspectRatioOption
  let isSelected: Bool
  let orientation: AspectRatioOrientation
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Text(displayName)
        .font(Typography.labelSmall)
        .fontWeight(isSelected ? .semibold : .medium)
        .foregroundColor(isSelected ? .accentColor : SidebarColors.labelPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
          Capsule(style: .continuous)
            .fill(backgroundColor)
        )
        .overlay(
          Capsule(style: .continuous)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: Size.strokeSelected)
        )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var backgroundColor: Color {
    if isSelected {
      return SidebarColors.itemSelected
    } else if isHovering {
      return SidebarColors.itemHover
    }
    return SidebarColors.itemDefault
  }

  private var displayName: String {
    option.effectiveDisplayName(orientation: orientation)
  }
}

struct CompactColorSwatchGrid: View {
  @Binding var selectedColor: Color?
  @ObservedObject private var paletteStore = AnnotateColorPaletteStore.shared
  @State private var draftCustomColor = Color.red

  private let colors: [Color] = [
    .red, .orange, .yellow, .green, .blue, .purple, .pink, .gray, .white, .black,
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: GridConfig.gap), count: GridConfig.colorColumns), spacing: GridConfig.gap) {
        ForEach(colors, id: \.self) { color in
          Button {
            selectedColor = color
          } label: {
            Circle()
              .fill(color)
              .colorSwatchStyle(isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color))
          }
          .buttonStyle(.plain)
          .ownShotAnnotateColorName(color)
        }

        ForEach(paletteStore.customColors, id: \.self) { color in
          AnnotateColorSwatchButton(
            color: color,
            isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color),
            size: nil,
            onDelete: {
              paletteStore.removeColor(color)
            }
          ) {
            selectedColor = color
          }
        }

        AnnotateCustomColorPickerControl(
          selectedColor: customColorBinding,
          draftColor: $draftCustomColor,
          swatchSize: nil
        )
      }
    }
  }

  private var customColorBinding: Binding<Color> {
    Binding(
      get: { selectedColor ?? draftCustomColor },
      set: { color in
        draftCustomColor = color
        selectedColor = color
      }
    )
  }
}

/// Метрики строки слайдера: компактные (свойства аннотаций, Combine) или панели Background.
enum CompactSliderRowStyle {
  case compact
  case background

  var labelFont: Font {
    switch self {
    case .compact: return Typography.labelSmall
    case .background: return .system(size: AnnotateBackgroundPanelLayout.sliderLabelFontSize)
    }
  }

  var labelSpacing: CGFloat {
    switch self {
    case .compact: return 2
    case .background: return AnnotateBackgroundPanelLayout.sliderLabelSpacing
    }
  }

  var valueFieldWidth: CGFloat {
    switch self {
    case .compact: return 36
    case .background: return AnnotateBackgroundPanelLayout.sliderValueFieldWidth
    }
  }

  /// У Background поле без внутренних отступов, чтобы строка подписи была 16 pt.
  var valueFieldHorizontalPadding: CGFloat {
    self == .compact ? Spacing.xs : 0
  }

  var valueFieldVerticalPadding: CGFloat {
    self == .compact ? 2 : 0
  }

  /// Высота строки подписи: у Background ровно 16 pt, компактная – по содержимому.
  var labelRowHeight: CGFloat? {
    self == .background ? AnnotateBackgroundPanelLayout.sliderLabelHeight : nil
  }
}

struct CompactSliderRow: View {
  let label: String
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  var onDragging: ((Bool, CGFloat) -> Void)? = nil
  /// Background эталона (ANBackgroundToolSlider): число видно только по наведению,
  /// при вводе с клавиатуры и во время перетаскивания ползунка.
  var revealsValueOnHover = false
  /// `.background` – метрики панели Background эталона: подписи 13 pt, шаг строк 47 pt.
  var style: CompactSliderRowStyle = .compact

  @State private var localValue: CGFloat = 0
  @State private var isDragging: Bool = false
  @State private var isHovering = false
  @State private var textValue: String = ""
  @FocusState private var isTextFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: style.labelSpacing) {
      HStack {
        Text(label)
          .font(style.labelFont)
          .foregroundColor(SidebarColors.labelSecondary)
        Spacer()
        TextField("", text: $textValue)
          .font(style.labelFont)
          .foregroundColor(SidebarColors.labelSecondary.opacity(0.9))
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.plain)
          .frame(width: style.valueFieldWidth)
          .padding(.horizontal, style.valueFieldHorizontalPadding)
          .padding(.vertical, style.valueFieldVerticalPadding)
          .background(
            Radius.rect(Radius.control(forHeight: AnnotateSidebarMetrics.inlineFieldHeight))
              .fill(SidebarColors.itemDefault)
          )
          .focused($isTextFieldFocused)
          .modifier(CompactSliderArrowKeys(isEnabled: isTextFieldFocused) { delta in
            stepValue(by: delta)
          })
          .opacity(Self.showsValueField(
            revealsOnHover: revealsValueOnHover,
            isHovering: isHovering,
            isFocused: isTextFieldFocused,
            isDragging: isDragging
          ) ? 1 : 0)
          .animation(.easeInOut(duration: 0.15), value: isHovering)
          .onAppear {
            textValue = String(format: "%.0f", value)
          }
          .onChange(of: localValue) { newValue in
            if !isTextFieldFocused {
              textValue = String(format: "%.0f", newValue)
            }
          }
          .onChange(of: isTextFieldFocused) { focused in
            if !focused {
              applyTextValue()
            }
          }
          .onSubmit {
            applyTextValue()
            isTextFieldFocused = false
          }
      }
      .frame(height: style.labelRowHeight)
      // Эталон: значения целые, дробная позиция ползунка округляется.
      Slider(
        value: Binding(
          get: { localValue },
          set: { localValue = AnnotateBackgroundSliderValue.integral($0, in: range) }
        ),
        in: range,
        onEditingChanged: { editing in
          isDragging = editing
          if !editing {
            // Sync to binding only when drag ends
            value = localValue
            onDragging?(false, localValue)
          } else {
            // Drag started
            onDragging?(true, localValue)
          }
        }
      )
      .controlSize(.small)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .onAppear { localValue = value }
    .onChange(of: localValue) { newValue in
      // Update preview in real-time during drag
      if isDragging {
        onDragging?(true, newValue)
      }
    }
    .onChange(of: value) { newValue in
      // External changes sync to local (e.g., preset selection)
      if !isDragging { localValue = newValue }
    }
  }

  /// Видимость числового поля: всегда, если показ по наведению выключен.
  static func showsValueField(revealsOnHover: Bool, isHovering: Bool, isFocused: Bool, isDragging: Bool) -> Bool {
    !revealsOnHover || isHovering || isFocused || isDragging
  }

  /// Стрелки вверх и вниз в поле меняют значение на единицу, как IntTextField эталона.
  private func stepValue(by delta: CGFloat) {
    let stepped = AnnotateBackgroundSliderValue.stepped(localValue, by: delta, in: range)
    guard stepped != localValue else { return }
    localValue = stepped
    value = stepped
    textValue = String(format: "%.0f", stepped)
  }

  private func applyTextValue() {
    // Submit и потеря фокуса приходят оба: неизменённое поле не пишет значение
    // и не даёт лишней точки undo.
    guard textValue != String(format: "%.0f", localValue) else { return }
    if let newValue = Double(textValue) {
      let clampedValue = AnnotateBackgroundSliderValue.integral(CGFloat(newValue), in: range)
      localValue = clampedValue
      value = clampedValue
      textValue = String(format: "%.0f", clampedValue)
    } else {
      textValue = String(format: "%.0f", localValue)
    }
  }
}

/// Стрелки в числовом поле слайдера. onKeyPress есть только с macOS 14,
/// на macOS 13 поле принимает ввод и Tab без шага стрелками.
private struct CompactSliderArrowKeys: ViewModifier {
  let isEnabled: Bool
  let step: (CGFloat) -> Void

  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content
        .onKeyPress(.upArrow) {
          guard isEnabled else { return .ignored }
          step(1)
          return .handled
        }
        .onKeyPress(.downArrow) {
          guard isEnabled else { return .ignored }
          step(-1)
          return .handled
        }
    } else {
      content
    }
  }
}
