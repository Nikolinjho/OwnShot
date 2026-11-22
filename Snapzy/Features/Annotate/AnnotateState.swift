//
//  AnnotateState.swift
//  Snapzy
//
//  Central state management for annotation window
//

import AppKit
import Combine
import CoreImage
import ImageIO
import SnapzyMeasureCore
import SwiftUI

/// Central state for annotation window
@MainActor
final class AnnotateState: ObservableObject {
  private struct AnnotationSnapshot {
    var annotations: [AnnotationItem]
    var originOffset: CGPoint
    var embeddedImageAssets: [UUID: NSImage]
    var embeddedImageSourceData: [UUID: Data]
    var embeddedImageSnapshotCacheData: [UUID: Data]
    var autoSizingTextAnnotationIDs: Set<UUID>
    var freeCombineBoundsByAnnotationID: [UUID: CGRect]
    var selectedAnnotationIds: Set<UUID>
  }

  private struct AnnotationCloneResult {
    var annotations: [AnnotationItem] = []
    var embeddedImageAssets: [UUID: NSImage] = [:]
    var embeddedImageData: [UUID: Data] = [:]
    var autoSizingTextAnnotationIDs: Set<UUID> = []
  }

  /// Copy Object кладёт объекты в системный буфер под своим типом (у эталона
  /// pl.maketheweb.cleanshotx-annotate): вставка работает между окнами редактора.
  private struct AnnotationClipboardPayload: Codable {
    let items: [PersistedAnnotationItem]
    let embeddedImageData: [UUID: Data]

    init(items: [AnnotationItem], embeddedImageData: [UUID: Data]) {
      self.items = items.map(PersistedAnnotationItem.init)
      self.embeddedImageData = embeddedImageData
    }

    var annotationItems: [AnnotationItem] {
      items.compactMap(\.annotationItem)
    }
  }

  /// Snapshot of every piece of state mutated by an image transform (90°
  /// rotation, cut-out strip operations). Used as a dedicated undo entry so
  /// these transforms never disturb the annotation-only undo path.
  private struct ImageTransformSnapshot {
    var sourceImage: NSImage?
    var cutoutImage: NSImage?
    var isCutoutApplied: Bool
    var embeddedImageAssets: [UUID: NSImage]
    var embeddedImageSourceData: [UUID: Data]
    var embeddedImageSnapshotCacheData: [UUID: Data]
    var annotations: [AnnotationItem]
    var cropRect: CGRect?
    var originalCropRect: CGRect?
    var cropAspectRatio: CropAspectRatio
    var customCropRatio: CGFloat?
    var customCropRatioTitle: String?
    var isCropPortraitOrientation: Bool
    var didCutoutAutoApplyCrop: Bool
    var cutoutAutoAppliedCropRect: CGRect?
  }

  /// Снимок фона и параметров холста (Padding, Shadow, Corners и т.д.) для undo.
  /// Отдельная запись, чтобы Cmd+Z откатывал выбор фона, не трогая аннотации.
  private struct CanvasEffectsUndoSnapshot {
    var effects: AnnotationCanvasEffects
    var selectedCanvasPresetId: UUID?
    var isSelectedCanvasPresetDirty: Bool
  }

  private enum UndoEntry {
    case annotations(AnnotationSnapshot)
    case imageTransform(ImageTransformSnapshot)
    case canvasEffects(CanvasEffectsUndoSnapshot)
  }

  private struct TextEditingUndoTransaction {
    let annotationId: UUID
    let snapshotBeforeEdit: AnnotationSnapshot
    let originalText: String
    var didRecordUndo: Bool = false
  }

  /// Состояние до входа в Crop: Apply кладёт его в undo, чтобы ⌘Z вернул полную картинку.
  private var cropUndoSnapshot: ImageTransformSnapshot?
  /// Units, lock и Flatten окна Image size между открытиями в этом редакторе.
  var imageSizeMemory = AnnotateImageSizeMemory()

  private struct CropInteractionContext {
    let selectedTool: AnnotationToolType
    let selectedAnnotationIds: Set<UUID>
    let cropRect: CGRect?
    let didCutoutAutoApplyCrop: Bool
    let cutoutAutoAppliedCropRect: CGRect?
  }

  private struct SharedAnnotationParameterDefaults: Codable {
    var strokeWidth: CGFloat?
    var cornerRadius: CGFloat?
    var fontSize: CGFloat?
    var watermarkOpacity: CGFloat?
    var watermarkRotationDegrees: CGFloat?
    var spotlightCornerRadius: CGFloat?
    var arrowStyle: String?
    var arrowType: String?
    var arrowBendDirection: String?
    var arrowStartHead: String?
    var arrowEndHead: String?
    var lineStyle: String?
    /// Последний стиль Redaction (annotateLastPixelateStyle эталона); nil = Pixelate.
    var blurType: String?
  }

  private struct PersistedAnnotationProperties: Codable {
    var strokeColor: RGBAColor
    var fillColor: RGBAColor
    var strokeWidth: CGFloat
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var fontName: String
    var opacity: CGFloat
    var rotationDegrees: CGFloat
    var watermarkStyle: String
    var textPresentation: String?
    var textStyle: Int?
    var spotlightOpacity: CGFloat?
    var lineStyle: String?
    /// Формат счётчика по умолчанию; nil в старых настройках = 1, 2, 3.
    var counterFormat: String?
    /// Последняя форма Spotlight (annotateLastHighlightShape эталона); nil = скруглённый.
    var spotlightShape: Int?

    init?(_ properties: AnnotationProperties) {
      guard let strokeColor = RGBAColor(color: properties.strokeColor),
            let fillColor = RGBAColor(color: properties.fillColor) else {
        return nil
      }

      self.strokeColor = strokeColor
      self.fillColor = fillColor
      self.strokeWidth = properties.strokeWidth
      self.cornerRadius = properties.cornerRadius
      self.fontSize = properties.fontSize
      self.fontName = properties.fontName
      self.opacity = properties.opacity
      self.rotationDegrees = properties.rotationDegrees
      self.watermarkStyle = properties.watermarkStyle.rawValue
      self.textPresentation = properties.textPresentation.rawValue
      self.textStyle = properties.textStyle.rawValue
      self.spotlightOpacity = properties.spotlightOpacity
      self.lineStyle = properties.lineStyle.rawValue
      self.counterFormat = properties.counterFormat.rawValue
      self.spotlightShape = properties.spotlightShape.rawValue
    }

    var annotationProperties: AnnotationProperties {
      var properties = AnnotationProperties(
        strokeColor: strokeColor.color,
        fillColor: fillColor.color,
        strokeWidth: strokeWidth,
        lineStyle: lineStyle.flatMap(LineDashStyle.init(rawValue:)) ?? .solid,
        cornerRadius: cornerRadius,
        fontSize: fontSize,
        fontName: fontName,
        opacity: opacity,
        rotationDegrees: rotationDegrees,
        watermarkStyle: WatermarkStyle(rawValue: watermarkStyle) ?? .single,
        spotlightOpacity: spotlightOpacity ?? AnnotateState.defaultSpotlightOpacity,
        textPresentation: textPresentation.flatMap { TextPresentation(rawValue: $0) } ?? .plain,
        textStyle: textStyle.flatMap(AnnotationTextStyle.init(rawValue:)) ?? .standard,
        counterFormat: counterFormat.flatMap(CounterNumberFormat.init(rawValue:)) ?? .decimal
      )
      properties.spotlightShape = spotlightShape.flatMap(SpotlightShape.init(rawValue:)) ?? .defaultShape
      return properties
    }
  }

  private static let importedImageMaxCoverage: CGFloat = 0.7
  private static let importedImageCascadeStep: CGFloat = 24
  private static let importedImageCountWarningThreshold: Int = 8
  private static let importedImagePixelBudgetWarningThreshold: Int64 = 40_000_000
  private static let canvasPresetLimit: Int = 20
  static let annotationDuplicationOffset = CGSize(width: 10, height: -10)
  private let canvasPresetStore: AnnotateCanvasPresetStore
  private var annotatePreferencesObserver: AnyCancellable?
  private let defaults: UserDefaults
  private let appliesDefaultCanvasPresetOnNewImages: Bool
  private var suppressCanvasEffectChangeTracking = false

  // MARK: - Source Image

  @Published var sourceImage: NSImage? {
    didSet { invalidateImageAnalysisProfiles() }
  }
  @Published var sourceURL: URL?

  /// Base image as loaded/restored. Rotate, cut out and combine reorder replace
  /// `sourceImage` with a new instance, so an identity mismatch means the session
  /// must persist the transformed pixels instead of the originally loaded bytes.
  private var loadedSourceImage: NSImage?
  private var originalCropSourceSizeOverride: OriginalCropSourceSize?
  private var transformedSourceImageDataCache: (image: NSImage, data: Data)?

  var isSourceImageTransformed: Bool {
    sourceImage != nil && sourceImage !== loadedSourceImage
  }

  /// PNG bytes of the current (transformed) source image for session persistence.
  /// Cached per image instance so repeated save/copy snapshots don't re-encode.
  func transformedSourceImageData() -> Data? {
    guard let sourceImage else { return nil }
    if let cache = transformedSourceImageDataCache, cache.image === sourceImage {
      return cache.data
    }
    guard let data = AnnotateExporter.imageData(from: sourceImage, for: "png") else { return nil }
    transformedSourceImageDataCache = (sourceImage, data)
    return data
  }

  @Published private(set) var cutoutImage: NSImage? {
    didSet { invalidateImageAnalysisProfiles() }
  }
  @Published private(set) var isCutoutApplied: Bool = false {
    didSet { invalidateImageAnalysisProfiles() }
  }
  @Published private(set) var isCutoutProcessing: Bool = false
  @Published var cutoutErrorMessage: String?
  private var activeCutoutOperationID: UUID?
  @Published private(set) var isSensitiveRedactionScanning: Bool = false
  private var activeSensitiveRedactionOperationID: UUID?
  private var sensitiveRedactionToast: AppToastHandle?
  @Published private(set) var isOCRProcessing: Bool = false
  private var activeOCROperationID: UUID?
  private var ocrToast: AppToastHandle?

  /// QuickAccess item ID if opened from quick access card (nil for drag-drop workflow)
  let quickAccessItemId: UUID?

  /// Cloud URL if file was already uploaded (passed from QuickAccessItem)
  @Published var cloudURL: URL?
  /// Cloud object key for overwrite re-uploads
  @Published var cloudKey: String?
  /// True when image has changed since last cloud upload (synced from QuickAccessItem)
  @Published var isCloudStale: Bool = false

  /// Whether an image is loaded
  var hasImage: Bool { sourceImage != nil }

  /// Image currently used by preview/export. Cutout is non-destructive and overlays the original source image.
  var effectiveSourceImage: NSImage? {
    if isCutoutApplied {
      return cutoutImage ?? sourceImage
    }
    return sourceImage
  }

  var canExtractText: Bool {
    !isOCRProcessing && editorMode == .annotate && !isCombineMode && effectiveSourceImage != nil
  }

  var canUseBackgroundCutout: Bool {
    if #available(macOS 14.0, *) {
      return true
    }
    return false
  }

  var isBackgroundCutoutAutoCropEnabled: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.backgroundCutoutAutoCropEnabled) as? Bool ?? true
  }

  private var isQuickPropertiesSyncEnabled: Bool {
    AnnotateQuickPropertiesSyncPreference.isEnabled(userDefaults: defaults)
  }

  // MARK: - Tool State

  @Published var selectedTool: AnnotationToolType = .selection {
    didSet {
      // If user leaves crop by switching tool, restore sidebar if crop had auto-collapsed it.
      if oldValue == .crop, selectedTool != .crop {
        restoreSidebarAfterCropInteractionIfNeeded()
      }
      // Leaving cut-out by switching tool discards the preview and the restore context.
      if oldValue == .cutOut, selectedTool != .cutOut {
        cutOutPreviewStrip = nil
        isCutOutActive = false
        cutOutInteractionContext = nil
        restoreSidebarAfterCropInteractionIfNeeded()
      }
      // Text snapping needs the line profile ready before the first drag.
      if selectedTool == .highlighter {
        prepareTextLineProfileIfNeeded()
      }
      // Measuring reads source pixels; the raster is large, so it lives only while measuring.
      if selectedTool == .measure {
        prepareMeasureMapperIfNeeded()
      } else if oldValue == .measure {
        releaseMeasureMapper()
      }
      syncActiveToolProperties()
    }
  }
  var onToolActivated: ((AnnotationToolType) -> Void)?
  @Published var strokeWidth: CGFloat = 3
  @Published var strokeColor: Color = .red
  @Published var fillColor: Color = .clear
  @Published var rectangleCornerRadius: CGFloat = 0
  @Published var blurType: BlurType = .pixelated
  @Published var arrowStyle: ArrowStyle = .straight
  @Published var arrowType: ArrowType = .tapered
  @Published var arrowBendDirection: ArrowBendDirection = .primary
  @Published var arrowStartHead: ArrowEndpointStyle = .none
  @Published var arrowEndHead: ArrowEndpointStyle = .arrow
  @Published var watermarkText: String = "Snapzy"
  /// Затемнение Spotlight по умолчанию: фон 220 вне области у эталона становится 121 (≈45% чёрного).
  /// Сохранённые объекты хранят своё значение, новое умолчание их не меняет.
  static let defaultSpotlightOpacity: CGFloat = 0.45
  @Published var spotlightOpacity: CGFloat = AnnotateState.defaultSpotlightOpacity
  @Published private var annotationToolProperties: [AnnotationToolType: AnnotationProperties] = [:]
  private var isQuickPropertiesGestureEditing = false
  private var quickPropertiesGestureUndoSnapshot: AnnotationSnapshot?
  // Sidebar property slider drags (e.g. text font size) coalesce undo into one
  // checkpoint per gesture instead of one snapshot per tick (see issue #335).
  private var isPropertySliderGestureEditing = false
  private var propertySliderGestureUndoSnapshot: AnnotationSnapshot?
  // Жест контрола фона: одна точка undo фона на жест, см. saveCanvasEffectsState.
  private var isCanvasEffectsGestureEditing = false
  private var didRecordCanvasEffectsGestureUndo = false
  private var sharedAnnotationColor: Color?
  private var sharedAnnotationParameterDefaults = SharedAnnotationParameterDefaults()
  /// New text starts as a natural-width line. Resizing it switches that item
  /// to a fixed width so deliberate wrapping is never overwritten while typing.
  private var autoSizingTextAnnotationIDs: Set<UUID> = []
  private var annotationClipboardPayload: AnnotationClipboardPayload?
  /// changeCount буфера после Copy Object: пока он не изменился, внутренний буфер – быстрый путь.
  private var annotationClipboardChangeCount: Int?
  private var annotationPasteCount = 0
  /// Тип объектов редактора в системном буфере.
  static let annotationPasteboardType = NSPasteboard.PasteboardType("com.ownshot.annotate")
  /// Буфер Copy Object. В тестовом хосте – отдельный именованный, чтобы не трогать буфер пользователя.
  var annotationPasteboard: NSPasteboard = AnnotateState.defaultAnnotationPasteboard()

  private static func defaultAnnotationPasteboard() -> NSPasteboard {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return NSPasteboard.withUniqueName()
    }
    return .general
  }

  /// Most recent pointer location over the canvas, in image coordinates. This
  /// is intentionally not published: mouse movement should not invalidate the
  /// SwiftUI annotation surface.
  private var canvasMouseLocation: CGPoint?

  // MARK: - Editor Mode

  /// Editor mode determines whether user is annotating or applying mockup transforms
  nonisolated enum EditorMode: String, CaseIterable, Sendable {
    case annotate  // Normal annotation editing (flat image)
    case mockup    // 3D perspective transforms with controls
    case preview   // Preview combined result (hides all editing UI)
  }

  enum QuickPropertiesMode: Equatable {
    case hidden
    case toolDefaults
    case selectedItem
  }

  enum DragToAppPreparationState: Equatable {
    case unavailable
    case preparing
    case ready

    var isInteractive: Bool {
      self == .ready
    }
  }

  @Published var editorMode: EditorMode = .annotate

  // MARK: - UI State

  @Published var showSidebar: Bool = false {
    didSet {
      if annotatePreferences.rememberBackground {
        defaults.set(showSidebar, forKey: OwnShotAnnotatePreferenceKeys.backgroundWasOpen)
      }
    }
  }

  var annotatePreferences: OwnShotAnnotatePreferences { OwnShotAnnotatePreferences(defaults: defaults) }
  @Published var zoomLevel: CGFloat = 1.0 {
    didSet {
      // Любое изменение масштаба не из applyInitialActualSize – выбор пользователя:
      // дальше метрики окна 100% не навязывают.
      if !isApplyingInitialActualSize, abs(zoomLevel - oldValue) > 0.0001 {
        pendingInitialActualSize = false
      }
    }
  }
  @Published var isPinned: Bool = false
  @Published private(set) var dragToAppPreparationState: DragToAppPreparationState

  // MARK: - Combine Images

  static let combineBaseLayerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  @Published private(set) var isCombineMode = false
  @Published private(set) var combineMode: CombineImagesMode = .autoStitch
  @Published private(set) var combineDirection: CombineImagesDirection = .smart
  @Published private(set) var combineResolvedDirection: CombineImagesDirection = .horizontal
  @Published private(set) var combineGap: CGFloat = 0
  @Published private(set) var combineContentBounds: CGRect = .zero
  @Published var frozenCombineContentBounds: CGRect?
  let combineSnapTolerance: CGFloat = 14

  /// True when this editor session was opened manually (empty window / Combine picker).
  /// Its sourceURL points at a user-picked file, not a Snapzy capture, so combine saves
  /// must never silently overwrite it. Set once at window init; not an image property.
  var isManualImportSession = false

  private var freeCombineBoundsByAnnotationID: [UUID: CGRect] = [:]

  var effectiveContentBounds: CGRect {
    guard isCombineMode else {
      guard expandsCanvasBeyondImage, cropRect == nil else { return sourceImageBounds }
      return OwnShotAnnotateDrawing.expandedBounds(source: sourceImageBounds, annotations: annotations.map(\.renderBounds))
    }
    return frozenCombineContentBounds ?? combineContentBounds
  }

  var combineImageCount: Int {
    1 + annotations.reduce(into: 0) { count, annotation in
      if case .embeddedImage = annotation.type { count += 1 }
    }
  }

  func moveCombineImage(at index: Int, by offset: Int) {
    guard isCombineMode, offset != 0, let sourceImage else { return }
    let slots = annotations.compactMap { annotation -> UUID? in
      guard case .embeddedImage(let assetID) = annotation.type else { return nil }
      return assetID
    }
    var orderedImages = [sourceImage] + slots.compactMap { embeddedImageAssets[$0] }
    guard orderedImages.count == slots.count + 1,
          orderedImages.indices.contains(index) else { return }
    let destination = index + offset
    guard orderedImages.indices.contains(destination) else { return }

    pushImageTransformUndo(currentImageTransformSnapshot())
    let moved = orderedImages.remove(at: index)
    orderedImages.insert(moved, at: destination)
    self.sourceImage = orderedImages[0]
    for (slotIndex, assetID) in slots.enumerated() {
      embeddedImageAssets[assetID] = orderedImages[slotIndex + 1]
      embeddedImageSourceData.removeValue(forKey: assetID)
      embeddedImageSnapshotCacheData.removeValue(forKey: assetID)
      embeddedImageCGImageCache.removeValue(forKey: assetID)
    }
    hasUnsavedChanges = true
    refreshCombineLayout()
  }

  func activateCombineMode(preferredMode: CombineImagesMode = .autoStitch) {
    guard hasImage else { return }
    if !isCombineMode {
      isCombineMode = true
      showSidebar = true
      selectedTool = .selection
      captureCurrentFreeCombineBounds()
    }
    setCombineMode(preferredMode)
  }

  func deactivateCombineMode() {
    guard isCombineMode else { return }
    isCombineMode = false
    combineContentBounds = sourceImageBounds
    frozenCombineContentBounds = nil
  }

  func setCombineMode(_ mode: CombineImagesMode) {
    guard isCombineMode else { return }
    guard combineMode != mode else {
      refreshCombineLayout()
      return
    }

    if combineMode == .freeCanvas {
      captureCurrentFreeCombineBounds()
    }
    combineMode = mode
    switch mode {
    case .autoStitch:
      applyAutomaticCombineLayout()
    case .freeCanvas:
      restoreFreeCombineBounds()
    }
  }

  func setCombineDirection(_ direction: CombineImagesDirection) {
    combineDirection = direction
    if isCombineMode, combineMode == .autoStitch {
      applyAutomaticCombineLayout()
    }
  }

  func setCombineGap(_ gap: CGFloat) {
    combineGap = max(0, gap)
    if isCombineMode, combineMode == .autoStitch {
      applyAutomaticCombineLayout()
    } else if isCombineMode {
      updateCombineContentBounds()
    }
  }

  func refreshCombineLayout() {
    guard isCombineMode else { return }
    if combineMode == .autoStitch {
      applyAutomaticCombineLayout()
    } else {
      updateCombineContentBounds()
    }
  }

  /// Capture the active combine session's layout flags for persistence.
  /// Returns nil when not in combine mode. Source pixels persist separately via
  /// embedded image assets, so only the layout flags are captured here.
  func combineSessionSnapshot() -> CombineSessionSnapshot? {
    guard isCombineMode else { return nil }
    return CombineSessionSnapshot(
      mode: combineMode,
      direction: combineDirection,
      gap: combineGap,
      freeBoundsByAnnotationID: freeCombineBoundsByAnnotationID
    )
  }

  /// Restore a persisted combine session. Must run AFTER annotations and embedded assets
  /// are restored. Bypasses `activateCombineMode()` on purpose — that method's side effects
  /// (capturing current bounds, sidebar/tool changes) are for interactive activation, not
  /// deterministic rehydration. Does not touch `hasUnsavedChanges` or the undo stack.
  func restoreCombineSession(_ snapshot: CombineSessionSnapshot) {
    guard hasImage else { return }
    isCombineMode = true
    // Surface the sidebar so the combine controls (mode/direction/gap) are visible on
    // reopen — matches interactive activation and lets the user keep adjusting the stitch.
    showSidebar = true
    combineMode = snapshot.mode
    combineDirection = snapshot.direction
    combineGap = max(0, snapshot.gap)
    freeCombineBoundsByAnnotationID = snapshot.freeBoundsByAnnotationID
    // Deterministic: autoStitch recomputes layout from annotation order/direction/gap;
    // freeCanvas derives content bounds from the restored annotation bounds.
    refreshCombineLayout()
  }

  /// Нижняя граница zoomLevel при Fit 1.0 (10%). Настоящие пределы считаются в показанных
  /// процентах (fitScale × zoomLevel), см. effectiveZoomRange.
  static let minimumZoomLevel: CGFloat = 0.1
  /// Верхняя граница zoomLevel при Fit 1.0 (3200%).
  static let defaultMaximumZoomLevel: CGFloat = 32.0
  /// Пределы масштаба эталона в показанных процентах: ⌘− останавливается на 10%, ⌘+ на 3200%.
  nonisolated static let minimumDisplayedZoomPercent: CGFloat = 10
  nonisolated static let maximumDisplayedZoomPercent: CGFloat = 3200
  static let zoomPresetPercents = [25, 50, 75, 100, 125, 150, 200, 300, 400, 600, 800, 1200, 1600, 3200]
  /// Проценты меню масштаба эталона.
  static let zoomMenuPercents = [50, 100, 200, 400]
  /// Ступени ⌘+ и ⌘− эталона (ref-zoom-steps.txt): от 100% удвоение до 3200%,
  /// вниз деление пополам до 25%, затем 10%.
  nonisolated static let zoomStepPercents: [CGFloat] = [10, 25, 50, 100, 200, 400, 800, 1600, 3200]

  func zoomIn() {
    let target = zoomLevel(forDisplayedPercentValue: Self.nextZoomStepPercent(after: displayedZoomPercentValue))
    // Вписанный крошечный снимок может стоять выше 3200% – ⌘+ его не уменьшает.
    zoomLevel = max(zoomLevel, target)
  }

  func zoomOut() {
    let target = zoomLevel(forDisplayedPercentValue: Self.previousZoomStepPercent(before: displayedZoomPercentValue))
    // Вписанный огромный снимок может стоять ниже 10% – ⌘− его не увеличивает.
    zoomLevel = min(zoomLevel, target)
  }

  /// Следующая ступень выше показанного процента; на пределе – сам предел.
  nonisolated static func nextZoomStepPercent(after percent: CGFloat) -> CGFloat {
    zoomStepPercents.first { $0 > percent + 0.5 } ?? maximumDisplayedZoomPercent
  }

  /// Ступень ниже показанного процента; ниже 10% не уходит.
  nonisolated static func previousZoomStepPercent(before percent: CGFloat) -> CGFloat {
    zoomStepPercents.last { $0 < percent - 0.5 } ?? minimumDisplayedZoomPercent
  }

  /// Показанный процент без округления.
  var displayedZoomPercentValue: CGFloat {
    max(fitScale, 0.0001) * zoomLevel * 100
  }

  func toggleSidebarVisibility() {
    guard editorMode != .preview else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      showSidebar.toggle()
    }
  }

  /// Base fitted canvas size before zoom is applied.
  @Published private(set) var baseCanvasDisplaySize: CGSize = .zero

  /// Fit scale used to derive a dynamic max zoom for very long captures.
  @Published private(set) var fitScale: CGFloat = 1.0

  var effectiveMaximumZoomLevel: CGFloat {
    let normalizedFitScale = max(fitScale, 0.0001)
    // Fit (1.0) доступен всегда, даже если он выше 3200%.
    return max(1.0, Self.maximumDisplayedZoomPercent / 100 / normalizedFitScale)
  }

  var effectiveMinimumZoomLevel: CGFloat {
    let normalizedFitScale = max(fitScale, 0.0001)
    // Огромный снимок вписывается ниже 10% (10000×10000 у эталона – 9%), Fit остаётся доступен.
    return min(1.0, Self.minimumDisplayedZoomPercent / 100 / normalizedFitScale)
  }

  var effectiveZoomRange: ClosedRange<CGFloat> {
    effectiveMinimumZoomLevel...effectiveMaximumZoomLevel
  }

  var actualPixelZoomLevel: CGFloat {
    guard fitScale > 0 else { return 1.0 }
    return clampedZoom(1.0 / fitScale)
  }

  var currentDisplayedZoomPercent: Int {
    Int((fitScale * zoomLevel * 100).rounded())
  }

  var zoomMenuPresetPercents: [Int] {
    let maxDisplayedPercent = max(
      25,
      Int((effectiveMaximumZoomLevel * fitScale * 100).rounded(.down) / 25) * 25
    )

    var options = Self.zoomPresetPercents.filter {
      $0 <= maxDisplayedPercent
    }

    if maxDisplayedPercent > (options.last ?? 0) {
      options.append(maxDisplayedPercent)
    }

    return options
  }

  func zoomLevel(forDisplayedPercent percent: Int) -> CGFloat {
    zoomLevel(forDisplayedPercentValue: CGFloat(percent))
  }

  func zoomLevel(forDisplayedPercentValue percent: CGFloat) -> CGFloat {
    let normalizedFitScale = max(fitScale, 0.0001)
    return clampedZoom(percent / 100 / normalizedFitScale)
  }

  /// Clamp a zoom level to the valid range
  func clampedZoom(_ level: CGFloat) -> CGFloat {
    min(max(level, effectiveZoomRange.lowerBound), effectiveZoomRange.upperBound)
  }

  // MARK: - Pan State (for zoomed canvas navigation)

  /// Viewport pan offset (points). Applied alongside scaleEffect.
  @Published var panOffset: CGSize = .zero

  /// Keeps the canvas in a direct manipulation mode while the hand button is active.
  @Published var isCanvasPanningMode = false

  /// Whether Space key is currently held (hand tool active)
  @Published var isSpacePanning: Bool = false

  /// Canvas container size for pan bounds calculation (updated by GeometryReader)
  var canvasContainerSize: CGSize = .zero

  var canPanInteractively: Bool {
    let overflow = panOverflow(at: zoomLevel)
    return overflow.width > 0.5 || overflow.height > 0.5
  }

  /// Новое изображение открывается как у эталона: 100% (1 pt картинки = 1 pt экрана),
  /// без вписывания; если не помещается – прокрутка от верхнего края.
  /// Флаг держится, пока пользователь не сменил масштаб или не сдвинул холст:
  /// первые метрики окна бывают промежуточными (до раскладки тулбара и панели фона),
  /// и вписывание по ним дало бы не 100%, а 79%.
  private(set) var pendingInitialActualSize = false
  private var isApplyingInitialActualSize = false

  func updateViewportMetrics(containerSize: CGSize, baseCanvasSize: CGSize, fitScale: CGFloat) {
    let normalizedFitScale = max(fitScale, 0.0001)
    let metricsChanged = canvasContainerSize != containerSize
      || baseCanvasDisplaySize != baseCanvasSize
      || abs(self.fitScale - normalizedFitScale) > 0.0001

    canvasContainerSize = containerSize
    if baseCanvasDisplaySize != baseCanvasSize {
      baseCanvasDisplaySize = baseCanvasSize
    }
    if abs(self.fitScale - normalizedFitScale) > 0.0001 {
      self.fitScale = normalizedFitScale
    }

    guard metricsChanged else { return }

    // Обрезка и Combine меняют рабочую область холста – там 100% новой картинки уже не к месту.
    if pendingInitialActualSize, isCropActive || isCombineMode {
      pendingInitialActualSize = false
    }
    if pendingInitialActualSize, containerSize.width > 0, containerSize.height > 0,
       baseCanvasSize.width > 0, baseCanvasSize.height > 0 {
      applyInitialActualSize()
      return
    }

    let clampedLevel = clampedZoom(zoomLevel)
    if abs(clampedLevel - zoomLevel) > 0.0001 {
      zoomLevel = clampedLevel
    } else {
      resetPanIfNeeded()
    }
  }

  /// 100% от текущего Fit; при переполнении по высоте видно верх картинки.
  /// Если картинка шире окна – видно левый край (прокрутка от верхнего левого угла).
  func applyInitialActualSize() {
    isApplyingInitialActualSize = true
    defer { isApplyingInitialActualSize = false }
    zoomLevel = actualPixelZoomLevel
    panOffset = .zero
    let overflow = panOverflow(at: zoomLevel)
    if overflow.width > 0 {
      panOffset.width = overflow.width
    }
    if overflow.height > 0 {
      panOffset.height = overflow.height
    }
    clampPanOffset()
  }

  func pan(by delta: CGSize) {
    // Пользователь сам прокрутил холст – начальные 100% больше не держим.
    pendingInitialActualSize = false
    guard canPanInteractively else {
      panOffset = .zero
      return
    }

    panOffset.width += delta.width
    panOffset.height += delta.height
    clampPanOffset()
  }

  /// Reset pan when content no longer overflows.
  func resetPanIfNeeded() {
    if !canPanInteractively {
      panOffset = .zero
      isCanvasPanningMode = false
    } else {
      clampPanOffset()
    }
  }

  /// Clamp pan offset to keep content partially visible.
  /// At least ~40% of the canvas remains in the viewport at all times.
  func clampPanOffset() {
    let overflow = panOverflow(at: zoomLevel)
    guard overflow.width > 0 || overflow.height > 0 else {
      panOffset = .zero
      return
    }

    let marginX = overflow.width > 0 ? canvasContainerSize.width * 0.1 : 0
    let marginY = overflow.height > 0 ? canvasContainerSize.height * 0.1 : 0
    let maxPanX = overflow.width + marginX
    let maxPanY = overflow.height + marginY

    panOffset.width = min(max(panOffset.width, -maxPanX), maxPanX)
    panOffset.height = min(max(panOffset.height, -maxPanY), maxPanY)
  }

  private func panOverflow(at zoomLevel: CGFloat) -> CGSize {
    guard canvasContainerSize.width > 0,
          canvasContainerSize.height > 0,
          baseCanvasDisplaySize.width > 0,
          baseCanvasDisplaySize.height > 0 else {
      return .zero
    }

    let renderedWidth = baseCanvasDisplaySize.width * zoomLevel
    let renderedHeight = baseCanvasDisplaySize.height * zoomLevel

    return CGSize(
      width: max((renderedWidth - canvasContainerSize.width) / 2, 0),
      height: max((renderedHeight - canvasContainerSize.height) / 2, 0)
    )
  }

  // MARK: - Background Settings

  @Published var backgroundStyle: BackgroundStyle = .none {
    didSet {
      // Pre-cache image-backed backgrounds when style changes.
      switch backgroundStyle {
      case .wallpaper(let url), .blurred(let url):
        loadBackgroundImage(from: url)
      default:
        cachedBackgroundImage = nil
        cachedBlurredImage = nil
        cachedBackgroundURL = nil
        loadingBackgroundURL = nil
      }

      if backgroundStyle.supportsBlurredBackgroundEffect == false && isBlurredBackgroundEnabled {
        isBlurredBackgroundEnabled = false
      } else {
        refreshCachedBlurredBackgroundImage()
      }
      handleCanvasEffectDidChange()
    }
  }

  @Published var isBlurredBackgroundEnabled: Bool = false {
    didSet {
      refreshCachedBlurredBackgroundImage()
      handleCanvasEffectDidChange()
    }
  }

  @Published var blurredBackgroundEffect: BlurredBackgroundEffect = .soft {
    didSet {
      refreshCachedBlurredBackgroundImage()
      handleCanvasEffectDidChange()
    }
  }

  /// Cached background image for performance (avoids disk reads during slider drag)
  /// IMPORTANT: @Published to trigger SwiftUI re-render when async load completes
  @Published private(set) var cachedBackgroundImage: NSImage?

  /// Cached pre-computed blurred image (avoids real-time blur on every frame)
  @Published private(set) var cachedBlurredImage: NSImage?

  /// URL represented by the current cached background image.
  private var cachedBackgroundURL: URL?

  /// Track the URL being loaded to prevent race conditions
  private var loadingBackgroundURL: URL?

  var isBlurredBackgroundEffectActive: Bool {
    guard backgroundStyle.supportsBlurredBackgroundEffect else { return false }
    if case .blurred = backgroundStyle {
      return true
    }
    return isBlurredBackgroundEnabled
  }

  private var activeBlurredBackgroundURL: URL? {
    guard isBlurredBackgroundEffectActive else { return nil }
    return backgroundStyle.blurredEffectImageURL
  }

  private func loadBackgroundImage(from url: URL) {
    // Skip preset URLs (handled via gradient)
    guard url.scheme != "preset" else {
      cachedBackgroundImage = nil
      cachedBlurredImage = nil
      cachedBackgroundURL = nil
      loadingBackgroundURL = nil
      return
    }

    // Track which URL we're loading to prevent race conditions
    loadingBackgroundURL = url
    cachedBackgroundImage = nil
    cachedBlurredImage = nil
    cachedBackgroundURL = nil

    // Use preview cache (2048px) instead of full resolution for performance
    SystemWallpaperManager.shared.loadPreviewImage(for: url) { [weak self] image in
      Task { @MainActor in
        // Race condition guard: only apply if this is still the intended URL
        guard self?.loadingBackgroundURL == url else { return }

        self?.cachedBackgroundImage = image
        self?.cachedBackgroundURL = url
        self?.loadingBackgroundURL = nil

        // Pre-compute blurred variant if the selected background uses this effect.
        if self?.activeBlurredBackgroundURL == url {
          self?.cachedBlurredImage = self?.makeBlurredBackgroundImage(from: image)
        } else {
          self?.cachedBlurredImage = nil
        }
      }
    }
  }

  private func refreshCachedBlurredBackgroundImage() {
    guard let url = activeBlurredBackgroundURL else {
      cachedBlurredImage = nil
      return
    }
    guard let cachedBackgroundImage = cachedBackgroundImage(for: url) else {
      cachedBlurredImage = nil
      return
    }
    cachedBlurredImage = makeBlurredBackgroundImage(from: cachedBackgroundImage)
  }

  func backgroundImage(for url: URL) -> NSImage? {
    if cachedBackgroundURL == url, let cachedBackgroundImage {
      return cachedBackgroundImage
    }
    return SandboxFileAccessManager.shared.withScopedAccess(to: url, {
      NSImage(contentsOf: url)
    })
  }

  func cachedBackgroundImage(for url: URL) -> NSImage? {
    guard cachedBackgroundURL == url else { return nil }
    return cachedBackgroundImage
  }

  func cachedBlurredBackgroundImage(for url: URL) -> NSImage? {
    guard activeBlurredBackgroundURL == url else { return nil }
    return cachedBlurredImage
  }

  func blurredBackgroundImage(for url: URL) -> NSImage? {
    if activeBlurredBackgroundURL == url,
       let cachedBlurredImage {
      return cachedBlurredImage
    }
    return makeBlurredBackgroundImage(from: backgroundImage(for: url))
  }

  /// Apply CI filters to an NSImage once, then cache the result for preview/export reuse.
  func makeBlurredBackgroundImage(from image: NSImage?) -> NSImage? {
    guard let image = image,
          let tiffData = image.tiffRepresentation,
          let ciImage = CIImage(data: tiffData) else { return nil }

    let blurFilter = CIFilter(name: "CIGaussianBlur")
    blurFilter?.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
    blurFilter?.setValue(blurredBackgroundEffect.blurRadius, forKey: kCIInputRadiusKey)

    guard let blurredOutput = blurFilter?.outputImage else { return nil }

    let colorFilter = CIFilter(name: "CIColorControls")
    colorFilter?.setValue(blurredOutput, forKey: kCIInputImageKey)
    colorFilter?.setValue(blurredBackgroundEffect.saturation, forKey: kCIInputSaturationKey)
    colorFilter?.setValue(blurredBackgroundEffect.brightness, forKey: kCIInputBrightnessKey)

    guard let output = colorFilter?.outputImage else { return nil }

    // Crop to original bounds (blur extends edges)
    let croppedOutput = output.cropped(to: ciImage.extent)

    let rep = NSCIImageRep(ciImage: croppedOutput)
    let blurred = NSImage(size: rep.size)
    blurred.addRepresentation(rep)
    return blurred
  }

  @Published var padding: CGFloat = 0 {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  /// Inset панели Background: внутренний отступ изображения внутри фона (0…100).
  @Published var inset: CGFloat = 0 {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  /// Auto-balance: выравнивание полей там, где контент упирается в край. По умолчанию выключен.
  @Published var autoBalance: Bool = false {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  // Эталон: в свежем редакторе Shadow = 0 (сверка 055).
  @Published var shadowIntensity: CGFloat = 0 {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  @Published var cornerRadius: CGFloat = AnnotateCanvasDefaults.cornerRadius {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  @Published var imageAlignment: ImageAlignment = .center {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  @Published var aspectRatio: AspectRatioOption = .auto {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  @Published var aspectRatioOrientation: AspectRatioOrientation = .horizontal {
    didSet {
      handleCanvasEffectDidChange()
    }
  }
  @Published private(set) var canvasPresets: [AnnotateCanvasPreset] = []
  @Published var selectedCanvasPresetId: UUID?
  @Published private(set) var isSelectedCanvasPresetDirty: Bool = false
  @Published private(set) var defaultCanvasPresetId: UUID?
  @Published private(set) var isDefaultCanvasPresetAutoApplied = false

  enum CanvasPresetMutationResult {
    case success
    case invalidName
    case limitReached
    case unavailablePayload
    case missingSelection
  }

  var selectedCanvasPreset: AnnotateCanvasPreset? {
    guard let selectedCanvasPresetId else { return nil }
    return canvasPresets.first(where: { $0.id == selectedCanvasPresetId })
  }

  var defaultCanvasPreset: AnnotateCanvasPreset? {
    guard let defaultCanvasPresetId else { return nil }
    return canvasPresets.first(where: { $0.id == defaultCanvasPresetId })
  }

  var canUpdateSelectedCanvasPreset: Bool {
    selectedCanvasPresetId != nil && isSelectedCanvasPresetDirty
  }

  var canDeleteSelectedCanvasPreset: Bool {
    selectedCanvasPresetId != nil
  }

  var isCanvasPresetLimitReached: Bool {
    canvasPresets.count >= Self.canvasPresetLimit
  }

  var requiresRenderedOutputForSharing: Bool {
    hasUnsavedChanges || isDefaultCanvasPresetAutoApplied
  }

  var nextSuggestedCanvasPresetName: String {
    "Preset \(canvasPresets.count + 1)"
  }

  var isNoneCanvasEffectsActive: Bool {
    backgroundStyle == .none
      && abs(padding) <= 0.0001
      && abs(inset) <= 0.0001
      && abs(shadowIntensity) <= 0.0001
      && abs(cornerRadius) <= 0.0001
      && aspectRatio == .auto
  }

  var canvasEffectsSnapshot: AnnotationCanvasEffects {
    AnnotationCanvasEffects(
      backgroundStyle: backgroundStyle,
      isBlurredBackgroundEnabled: isBlurredBackgroundEnabled,
      blurredBackgroundEffect: blurredBackgroundEffect,
      padding: padding,
      inset: inset,
      autoBalance: autoBalance,
      shadowIntensity: shadowIntensity,
      cornerRadius: cornerRadius,
      imageAlignment: imageAlignment,
      aspectRatio: aspectRatio,
      aspectRatioOrientation: aspectRatioOrientation
    )
  }

  func applyCanvasEffects(
    _ effects: AnnotationCanvasEffects,
    preferredSelectedCanvasPresetId: UUID? = nil,
    preferredPresetDirtyState: Bool? = nil
  ) {
    withCanvasEffectChangeTrackingSuspended {
      backgroundStyle = effects.backgroundStyle
      isBlurredBackgroundEnabled = effects.isBlurredBackgroundEnabled && effects.backgroundStyle.supportsBlurredBackgroundEffect
      blurredBackgroundEffect = effects.blurredBackgroundEffect
      padding = effects.padding
      inset = effects.inset
      autoBalance = effects.autoBalance
      shadowIntensity = effects.shadowIntensity
      cornerRadius = effects.cornerRadius
      imageAlignment = effects.imageAlignment
      aspectRatio = effects.aspectRatio
      aspectRatioOrientation = effects.aspectRatioOrientation
    }

    restoreCanvasPresetSelection(
      preferredSelectedCanvasPresetId: preferredSelectedCanvasPresetId,
      preferredPresetDirtyState: preferredPresetDirtyState
    )
    isDefaultCanvasPresetAutoApplied = false

    previewPadding = nil
    previewInset = nil
    previewShadowIntensity = nil
    previewCornerRadius = nil
  }

  func loadCanvasPresets() {
    canvasPresets = canvasPresetStore.loadPresets()
    defaultCanvasPresetId = canvasPresetStore.loadDefaultPresetId(validating: canvasPresets)
    if let selectedCanvasPresetId,
       canvasPresets.contains(where: { $0.id == selectedCanvasPresetId }) == false {
      self.selectedCanvasPresetId = nil
    }
    recomputeCanvasPresetDirtyState()
  }

  func isDefaultCanvasPreset(_ preset: AnnotateCanvasPreset) -> Bool {
    defaultCanvasPresetId == preset.id
  }

  func toggleDefaultCanvasPreset(id: UUID) {
    if defaultCanvasPresetId == id {
      clearDefaultCanvasPreset()
    } else {
      setDefaultCanvasPreset(id: id)
    }
  }

  func setDefaultCanvasPreset(id: UUID) {
    guard canvasPresets.contains(where: { $0.id == id }) else { return }
    defaultCanvasPresetId = id
    canvasPresetStore.saveDefaultPresetId(id)
  }

  func clearDefaultCanvasPreset() {
    defaultCanvasPresetId = nil
    canvasPresetStore.clearDefaultPresetId()
  }

  /// Выбор градиента из сайдбара: одна точка undo на фон и параметры холста.
  /// Из пустого фона (None) эталон одновременно ставит Padding 63, Shadow 28, Corners 15 (ANN-763),
  /// уже настроенные параметры при смене одного градиента на другой не сбрасываются.
  func selectGradientBackground(_ preset: GradientPreset) {
    guard backgroundStyle != .gradient(preset) else { return }
    saveCanvasEffectsState()
    let appliesCanvasDefaults = backgroundStyle == .none || padding <= 0
    backgroundStyle = .gradient(preset)
    if appliesCanvasDefaults {
      padding = AnnotateGradientCanvasDefaults.padding
      shadowIntensity = AnnotateGradientCanvasDefaults.shadowIntensity
      cornerRadius = AnnotateGradientCanvasDefaults.cornerRadius
    }
  }

  /// Выбор обоев (встроенных или своих) из секции Wallpapers с точкой undo.
  /// Из нулевого Padding ставит 24, чтобы фон был виден.
  func selectWallpaperBackground(_ url: URL) {
    guard backgroundStyle != .wallpaper(url) else { return }
    saveCanvasEffectsState()
    if padding <= 0 {
      padding = 24
    }
    backgroundStyle = .wallpaper(url)
  }

  /// Плитка секции Blurred с точкой undo. Повторный клик по выбранной плитке снимает размытие.
  func selectBlurredBackgroundEffect(_ effect: BlurredBackgroundEffect) {
    guard backgroundStyle.supportsBlurredBackgroundEffect else { return }
    saveCanvasEffectsState()
    let isActive = isBlurredBackgroundEffectActive && blurredBackgroundEffect == effect
    if case .blurred(let url) = backgroundStyle {
      backgroundStyle = .wallpaper(url)
    }
    if isActive {
      isBlurredBackgroundEnabled = false
      return
    }
    if padding <= 0 {
      padding = 24
    }
    blurredBackgroundEffect = effect
    isBlurredBackgroundEnabled = true
  }

  /// Кнопка сетки Alignment с точкой undo. Не по центру при Padding меньше 24 ставит 24,
  /// из пустого фона – белый, иначе смещение не видно.
  func selectImageAlignment(_ alignment: ImageAlignment) {
    let needsPadding = padding < 24 && alignment != .center
    guard imageAlignment != alignment || needsPadding else { return }
    saveCanvasEffectsState()
    imageAlignment = alignment
    if needsPadding {
      padding = 24
      if backgroundStyle == .none {
        backgroundStyle = .solidColor(.white)
      }
    }
  }

  /// Пункт пресета в меню Presets... с точкой undo.
  func selectCanvasPresetFromSidebar(_ preset: AnnotateCanvasPreset) {
    saveCanvasEffectsState()
    applyCanvasPreset(preset)
  }

  /// Выбор сплошного цвета или прозрачного фона из палитры Plain color с точкой undo.
  func selectSolidColorBackground(_ color: Color) {
    if case .solidColor(let current) = backgroundStyle,
       AnnotateColorPaletteStore.colorsMatch(current, color) {
      return
    }
    saveCanvasEffectsState()
    backgroundStyle = .solidColor(color)
  }

  /// Жест непрерывного контрола фона, например подбора своего цвета Plain color:
  /// значение меняется на каждом шаге, а undo получает одну точку на весь жест.
  func setCanvasEffectsGestureEditing(_ isEditing: Bool) {
    guard isEditing != isCanvasEffectsGestureEditing else { return }
    isCanvasEffectsGestureEditing = isEditing
    didRecordCanvasEffectsGestureUndo = false
  }

  // Слайдеры Padding, Inset, Shadow и Corners. Во время жеста холст рисует
  // preview-значения, а сюда значение приходит один раз в конце жеста или
  // после ввода числа в поле. Поэтому каждое новое значение – одна точка undo,
  // а повтор того же значения ничего не пишет.

  func setBackgroundPadding(_ value: CGFloat) {
    guard padding != value else { return }
    saveCanvasEffectsState()
    padding = value
    // Padding виден только на фоне: из пустого фона ставим белый
    if value > 0, backgroundStyle == .none {
      backgroundStyle = .solidColor(.white)
    }
  }

  func setBackgroundInset(_ value: CGFloat) {
    guard inset != value else { return }
    saveCanvasEffectsState()
    inset = value
    // Inset виден только на фоне, как и Padding
    if value > 0, backgroundStyle == .none {
      backgroundStyle = .solidColor(.white)
    }
  }

  func setBackgroundShadowIntensity(_ value: CGFloat) {
    guard shadowIntensity != value else { return }
    saveCanvasEffectsState()
    shadowIntensity = value
  }

  func setBackgroundCornerRadius(_ value: CGFloat) {
    guard cornerRadius != value else { return }
    saveCanvasEffectsState()
    cornerRadius = value
  }

  /// Пункт popup Ratio панели Background с точкой undo.
  func selectBackgroundRatio(_ choice: AnnotateBackgroundRatioChoice) {
    guard AnnotateBackgroundRatioChoice(option: aspectRatio, orientation: aspectRatioOrientation) != choice else { return }
    saveCanvasEffectsState()
    aspectRatio = choice.option
    aspectRatioOrientation = choice.orientation
  }

  /// Checkbox Auto-balance с точкой undo. Из пустого фона ставит белый, как Padding.
  func setBackgroundAutoBalance(_ isEnabled: Bool) {
    guard autoBalance != isEnabled else { return }
    saveCanvasEffectsState()
    autoBalance = isEnabled
    if isEnabled, backgroundStyle == .none {
      backgroundStyle = .solidColor(.white)
    }
  }

  /// Кнопка None в сайдбаре: сброс фона и параметров холста с точкой undo.
  func selectNoneCanvasEffects() {
    guard !isNoneCanvasEffectsActive else { return }
    saveCanvasEffectsState()
    resetCanvasEffectsToNone()
  }

  func resetCanvasEffectsToNone() {
    let beforePayload = currentCanvasPresetPayload()
    withCanvasEffectChangeTrackingSuspended {
      backgroundStyle = .none
      isBlurredBackgroundEnabled = false
      blurredBackgroundEffect = .soft
      padding = 0
      inset = 0
      autoBalance = false
      shadowIntensity = 0
      cornerRadius = 0
      aspectRatio = .auto
      aspectRatioOrientation = .horizontal
      previewPadding = nil
      previewInset = nil
      previewShadowIntensity = nil
      previewCornerRadius = nil
    }
    selectedCanvasPresetId = nil
    isSelectedCanvasPresetDirty = false
    isDefaultCanvasPresetAutoApplied = false

    if let beforePayload,
       let afterPayload = currentCanvasPresetPayload(),
       beforePayload.approximatelyEquals(afterPayload) == false {
      hasUnsavedChanges = true
    }
  }

  func applyCanvasPreset(_ preset: AnnotateCanvasPreset, marksUnsaved: Bool = true) {
    let beforePayload = currentCanvasPresetPayload()
    withCanvasEffectChangeTrackingSuspended {
      let presetBackgroundStyle = preset.payload.backgroundStyle.toBackgroundStyle()
      backgroundStyle = presetBackgroundStyle
      isBlurredBackgroundEnabled = preset.payload.isBlurredBackgroundEnabled &&
        presetBackgroundStyle.supportsBlurredBackgroundEffect
      blurredBackgroundEffect = preset.payload.blurredBackgroundEffect
      padding = preset.payload.padding
      shadowIntensity = preset.payload.shadowIntensity
      cornerRadius = preset.payload.cornerRadius
      aspectRatio = preset.payload.aspectRatio
      aspectRatioOrientation = preset.payload.aspectRatioOrientation
      inset = preset.payload.inset
      autoBalance = preset.payload.autoBalance
      previewPadding = nil
      previewInset = nil
      previewShadowIntensity = nil
      previewCornerRadius = nil
    }
    selectedCanvasPresetId = preset.id
    isSelectedCanvasPresetDirty = false

    let afterPayload = currentCanvasPresetPayload()
    let didChange: Bool
    if let beforePayload, let afterPayload {
      didChange = beforePayload.approximatelyEquals(afterPayload) == false
    } else {
      didChange = beforePayload != nil || afterPayload != nil
    }

    if marksUnsaved && didChange {
      isDefaultCanvasPresetAutoApplied = false
    } else if !marksUnsaved {
      isDefaultCanvasPresetAutoApplied = didChange
    }

    if marksUnsaved && didChange {
      hasUnsavedChanges = true
    }
  }

  @discardableResult
  func saveCurrentCanvasAsPreset(name: String) -> CanvasPresetMutationResult {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName.isEmpty == false else {
      return .invalidName
    }

    guard canvasPresets.count < Self.canvasPresetLimit else {
      return .limitReached
    }

    guard let payload = currentCanvasPresetPayload() else {
      return .unavailablePayload
    }

    let uniqueName = uniqueCanvasPresetName(from: trimmedName)
    let preset = AnnotateCanvasPreset(name: uniqueName, payload: payload)
    canvasPresets.insert(preset, at: 0)
    selectedCanvasPresetId = preset.id
    isSelectedCanvasPresetDirty = false
    persistCanvasPresets()
    return .success
  }

  @discardableResult
  func updateSelectedCanvasPreset() -> CanvasPresetMutationResult {
    guard let selectedCanvasPresetId,
          let index = canvasPresets.firstIndex(where: { $0.id == selectedCanvasPresetId }) else {
      return .missingSelection
    }

    guard let payload = currentCanvasPresetPayload() else {
      return .unavailablePayload
    }

    var updatedPreset = canvasPresets[index]
    updatedPreset.payload = payload
    updatedPreset.updatedAt = Date()
    canvasPresets.remove(at: index)
    canvasPresets.insert(updatedPreset, at: 0)
    self.selectedCanvasPresetId = updatedPreset.id
    isSelectedCanvasPresetDirty = false
    persistCanvasPresets()
    return .success
  }

  @discardableResult
  func deleteSelectedCanvasPreset() -> Bool {
    guard let selectedCanvasPresetId else {
      return false
    }
    return deleteCanvasPreset(id: selectedCanvasPresetId)
  }

  @discardableResult
  func deleteCanvasPreset(id: UUID) -> Bool {
    let isDeletingSelectedPreset = selectedCanvasPresetId == id

    let countBefore = canvasPresets.count
    canvasPresets.removeAll(where: { $0.id == id })
    guard canvasPresets.count != countBefore else {
      return false
    }

    if isDeletingSelectedPreset {
      selectedCanvasPresetId = nil
      isSelectedCanvasPresetDirty = false
    } else {
      recomputeCanvasPresetDirtyState()
    }

    if defaultCanvasPresetId == id {
      clearDefaultCanvasPreset()
    }

    persistCanvasPresets()
    return true
  }

  func recomputeCanvasPresetDirtyState() {
    guard let selectedPreset = selectedCanvasPreset else {
      isSelectedCanvasPresetDirty = false
      return
    }

    guard let currentPayload = currentCanvasPresetPayload() else {
      isSelectedCanvasPresetDirty = true
      return
    }

    isSelectedCanvasPresetDirty = currentPayload.approximatelyEquals(selectedPreset.payload) == false
  }

  private func handleCanvasEffectDidChange() {
    recomputeCanvasPresetDirtyState()
    guard !suppressCanvasEffectChangeTracking else { return }
    isDefaultCanvasPresetAutoApplied = false
    hasUnsavedChanges = true
  }

  private func withCanvasEffectChangeTrackingSuspended(_ operation: () -> Void) {
    suppressCanvasEffectChangeTracking = true
    operation()
    suppressCanvasEffectChangeTracking = false
    recomputeCanvasPresetDirtyState()
  }

  private func currentCanvasPresetPayload() -> AnnotateCanvasPresetPayload? {
    guard let codableStyle = CodableBackgroundStyle(from: backgroundStyle) else {
      return nil
    }

    return AnnotateCanvasPresetPayload(
      backgroundStyle: codableStyle,
      isBlurredBackgroundEnabled: isBlurredBackgroundEffectActive,
      blurredBackgroundEffect: blurredBackgroundEffect,
      padding: padding,
      shadowIntensity: shadowIntensity,
      cornerRadius: cornerRadius,
      aspectRatio: aspectRatio,
      aspectRatioOrientation: aspectRatioOrientation,
      inset: inset,
      autoBalance: autoBalance
    )
  }

  private func restoreCanvasPresetSelection(
    preferredSelectedCanvasPresetId: UUID?,
    preferredPresetDirtyState: Bool?
  ) {
    if let preferredSelectedCanvasPresetId,
       canvasPresets.contains(where: { $0.id == preferredSelectedCanvasPresetId }) {
      selectedCanvasPresetId = preferredSelectedCanvasPresetId
      if let preferredPresetDirtyState {
        isSelectedCanvasPresetDirty = preferredPresetDirtyState
      } else {
        recomputeCanvasPresetDirtyState()
      }
      return
    }

    guard let currentPayload = currentCanvasPresetPayload(),
          let matchingPreset = canvasPresets.first(where: { $0.payload.approximatelyEquals(currentPayload) }) else {
      selectedCanvasPresetId = nil
      isSelectedCanvasPresetDirty = false
      return
    }

    selectedCanvasPresetId = matchingPreset.id
    isSelectedCanvasPresetDirty = false
  }

  private func uniqueCanvasPresetName(
    from baseName: String,
    excludingId: UUID? = nil
  ) -> String {
    let normalizedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedBaseName.isEmpty == false else {
      return nextSuggestedCanvasPresetName
    }

    let existingNames = Set(
      canvasPresets
        .filter({ preset in
          guard let excludingId else { return true }
          return preset.id != excludingId
        })
        .map { $0.name.lowercased() }
    )

    if existingNames.contains(normalizedBaseName.lowercased()) == false {
      return normalizedBaseName
    }

    var suffix = 2
    while suffix < 1_000 {
      let candidate = "\(normalizedBaseName) \(suffix)"
      if existingNames.contains(candidate.lowercased()) == false {
        return candidate
      }
      suffix += 1
    }

    return "\(normalizedBaseName) \(UUID().uuidString.prefix(4))"
  }

  private func persistCanvasPresets() {
    canvasPresetStore.savePresets(canvasPresets)
  }

  private func applyDefaultCanvasPresetForNewImageIfNeeded() {
    guard appliesDefaultCanvasPresetOnNewImages,
          let defaultCanvasPreset else { return }
    applyCanvasPreset(defaultCanvasPreset, marksUnsaved: false)
  }

  // MARK: - Preview Values (for smooth slider dragging)

  /// Preview values during slider drag - nil when not dragging
  @Published var previewPadding: CGFloat?
  @Published var previewInset: CGFloat?
  @Published var previewShadowIntensity: CGFloat?
  @Published var previewCornerRadius: CGFloat?

  /// Effective values for canvas rendering (preview overrides actual during drag)
  var effectivePadding: CGFloat { previewPadding ?? padding }
  var effectiveInset: CGFloat { previewInset ?? inset }
  var effectiveShadowIntensity: CGFloat { previewShadowIntensity ?? shadowIntensity }
  var effectiveCornerRadius: CGFloat { previewCornerRadius ?? cornerRadius }

  // MARK: - Background Inset

  private struct BackgroundInsetAnalysisCacheEntry {
    let image: NSImage
    let visibleBounds: CGRect
    let analysis: AnnotateImageEdgeAnalysis
  }

  private var backgroundInsetAnalysisCache: BackgroundInsetAnalysisCacheEntry?

  /// Отступ Inset/Auto-balance для видимой части изображения. Работает только на обычном
  /// холсте с фоном: в combine, mockup и во время crop-редактирования отступа нет.
  /// respectsActiveCrop = false нужен экспорту, который всегда рендерит применённый crop.
  func backgroundInsetLayout(
    for visibleBounds: CGRect,
    respectsActiveCrop: Bool = true
  ) -> AnnotateBackgroundInsetLayout {
    guard backgroundStyle != .none,
          !isCombineMode,
          editorMode != .mockup,
          !(respectsActiveCrop && isCropActive),
          let image = effectiveSourceImage else {
      return .none
    }
    let currentInset = effectiveInset
    guard currentInset > 0 || autoBalance else { return .none }
    return AnnotateBackgroundInset.layout(
      inset: currentInset,
      autoBalance: autoBalance,
      analysis: backgroundInsetAnalysis(image: image, visibleBounds: visibleBounds)
    )
  }

  /// Анализ краёв кэшируется на пару «изображение + видимая область»: превью
  /// пересчитывает раскладку на каждый кадр перетаскивания слайдера.
  private func backgroundInsetAnalysis(image: NSImage, visibleBounds: CGRect) -> AnnotateImageEdgeAnalysis {
    if let cached = backgroundInsetAnalysisCache,
       cached.image === image,
       cached.visibleBounds == visibleBounds {
      return cached.analysis
    }
    let analysis = AnnotateBackgroundInset.analyze(image: image, visibleBounds: visibleBounds)
    backgroundInsetAnalysisCache = BackgroundInsetAnalysisCacheEntry(
      image: image,
      visibleBounds: visibleBounds,
      analysis: analysis
    )
    return analysis
  }

  // MARK: - Display Metrics (for inset padding layout)

  /// Default canvas size when no image loaded
  private static let defaultCanvasWidth: CGFloat = 400
  private static let defaultCanvasHeight: CGFloat = 300

  /// Original image dimensions (points, not pixels)
  var imageWidth: CGFloat { effectiveSourceImage?.size.width ?? Self.defaultCanvasWidth }
  var imageHeight: CGFloat { effectiveSourceImage?.size.height ?? Self.defaultCanvasHeight }
  var imageAspectRatio: CGFloat { imageWidth / imageHeight }
  var sourceImageBounds: CGRect {
    CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight))
  }
  var activeAnnotationBounds: CGRect {
    cropRect?.standardized ?? effectiveContentBounds
  }

  /// Calculate display scale for given container size
  /// Image shrinks to fit within (container - padding*2)
  func displayScale(for containerSize: CGSize, margin: CGFloat = 40) -> CGFloat {
    let availableWidth = containerSize.width - margin * 2
    let availableHeight = containerSize.height - margin * 2

    // Available space for image after padding
    let imageAreaWidth = max(availableWidth - padding * 2, 1)
    let imageAreaHeight = max(availableHeight - padding * 2, 1)

    let scaleX = imageAreaWidth / imageWidth
    let scaleY = imageAreaHeight / imageHeight

    return min(scaleX, scaleY, 1.0) // Don't scale up
  }

  /// Calculate image offset within container based on alignment
  /// Note: ZStack centers children, so offset is relative to center (not top-left)
  /// - containerSize: The background size (already scaled)
  /// - imageDisplaySize: The image size (already scaled)
  /// - displayPadding: The padding in display coordinates (already scaled) - unused for seamless alignment
  func imageOffset(for containerSize: CGSize, imageDisplaySize: CGSize, displayPadding: CGFloat) -> CGPoint {
    // For SEAMLESS edge alignment: use total extra space (container - image)
    // This moves image to touch the background edge with NO gap
    let totalExtraWidth = containerSize.width - imageDisplaySize.width
    let totalExtraHeight = containerSize.height - imageDisplaySize.height

    // In ZStack, children are centered. Offset is relative to center.
    // For center: offset = 0
    // For edges: offset = +/- totalExtraSpace/2 (moves image to touch edge)
    let xOffset: CGFloat
    let yOffset: CGFloat

    switch imageAlignment {
    case .center:
      xOffset = 0
      yOffset = 0
    case .topLeft:
      xOffset = -totalExtraWidth / 2
      yOffset = -totalExtraHeight / 2  // Negative Y = move up toward top
    case .top:
      xOffset = 0
      yOffset = -totalExtraHeight / 2
    case .topRight:
      xOffset = totalExtraWidth / 2
      yOffset = -totalExtraHeight / 2
    case .left:
      xOffset = -totalExtraWidth / 2
      yOffset = 0
    case .right:
      xOffset = totalExtraWidth / 2
      yOffset = 0
    case .bottomLeft:
      xOffset = -totalExtraWidth / 2
      yOffset = totalExtraHeight / 2  // Positive Y = move down toward bottom
    case .bottom:
      xOffset = 0
      yOffset = totalExtraHeight / 2
    case .bottomRight:
      xOffset = totalExtraWidth / 2
      yOffset = totalExtraHeight / 2
    }

    return CGPoint(x: xOffset, y: yOffset)
  }

  // MARK: - Annotations

  @Published var annotations: [AnnotationItem] = [] {
    didSet {
      // Mutations outside `updateAnnotationProperties` are structural
      // (add/remove/undo/drag-commit) and can't be redrawn via dirty rects.
      if !isApplyingPropertyEdit {
        pendingFullCanvasInvalidation = true
      }
    }
  }

  /// True while `updateAnnotationProperties` applies mutations — lets the
  /// annotations observer tell property-only edits apart from structural ones.
  private var isApplyingPropertyEdit = false
  /// Image-space rects dirtied by property-only edits since the last flush.
  private var pendingPropertyEditRects: [CGRect] = []
  /// Set when a mutation can't be served by dirty rects (structural change, or
  /// a property affecting full-canvas layers such as spotlight dimming).
  private var pendingFullCanvasInvalidation = false

  /// Drains pending invalidation info for the canvas view. Scoped dirty rects
  /// let property slider drags redraw only the edited annotation instead of
  /// every layer in full bounds (see issue #335).
  func consumePendingCanvasInvalidation() -> (rects: [CGRect], needsFullRedraw: Bool) {
    defer {
      pendingPropertyEditRects.removeAll()
      pendingFullCanvasInvalidation = false
    }
    return (pendingPropertyEditRects, pendingFullCanvasInvalidation)
  }

  /// Imported image assets referenced by `.embeddedImage(assetId)` annotations.
  @Published private(set) var embeddedImageAssets: [UUID: NSImage] = [:]
  /// Non-blocking warning for large multi-image imports.
  @Published private(set) var importWarningMessage: String?
  /// Original bytes for imported assets when available (file drop/paste raw data).
  /// Reused for session snapshot to avoid expensive re-encode on save/copy path.
  private var embeddedImageSourceData: [UUID: Data] = [:]
  /// Cached serialized bytes for imported assets that did not have direct source data.
  private var embeddedImageSnapshotCacheData: [UUID: Data] = [:]
  /// Cached decoded CGImage for faster repeated canvas/export draws.
  private var embeddedImageCGImageCache: [UUID: CGImage] = [:]
  private var lastImportWarningSignature: String?
  private var isSynchronizingSelection = false
  @Published var selectedAnnotationId: UUID? {
    didSet {
      guard !isSynchronizingSelection else { return }
      selectedAnnotationIds = selectedAnnotationId.map { Set([$0]) } ?? []
    }
  }
  @Published private(set) var selectedAnnotationIds: Set<UUID> = []
  @Published var editingTextAnnotationId: UUID? {
    didSet {
      if editingTextAnnotationId == nil {
        textEditingUndoTransaction = nil
      }
    }
  }

  // MARK: - Counter Tool State (derived from annotations, not stored)

  /// Starting number из меню Counter: номер следующего создаваемого счётчика.
  @Published private(set) var counterStartingNumber: Int = AnnotateCounterSettings.defaultStartingNumber
  /// Счётчики, которые уже были на холсте в момент смены Starting number.
  /// Они не продолжают новую последовательность, но undo и удаление их не трогают.
  private var counterSequenceBaseline: Set<UUID> = []

  // MARK: - Crop State

  /// Current crop rectangle in image coordinates (nil = no crop, full image)
  @Published var cropRect: CGRect?
  /// Original crop rect when crop mode started (used as base for aspect ratio calculations)
  private var originalCropRect: CGRect?
  /// Context to restore after leaving crop mode.
  private var cropInteractionContext: CropInteractionContext?
  /// Whether crop mode is actively being edited
  @Published var isCropActive: Bool = false
  /// Заливка рамки Crop за пределами изображения (Background color эталона, ключ cropColor).
  /// nil – прозрачный фон.
  @Published var cropFillColor: NSColor? {
    didSet {
      guard oldValue != cropFillColor, !isApplyingDetectedCropFillColor else { return }
      hasUnsavedChanges = true
      isCropFillColorUserChosen = true
    }
  }
  /// Цвет выбран пользователем (в том числе прозрачный) – распознанный цвет его не заменяет.
  private var isCropFillColorUserChosen = false
  private var isApplyingDetectedCropFillColor = false
  /// Selected aspect ratio for crop
  @Published var cropAspectRatio: CropAspectRatio = .free
  @Published private(set) var customCropRatio: CGFloat?
  @Published private(set) var customCropRatioTitle: String?

  var effectiveCropRatio: CGFloat? {
    let ratio = customCropRatio ?? cropAspectRatio.ratio
    guard ratio > 0 else { return nil }
    return isCropPortraitOrientation ? 1 / ratio : ratio
  }

  private static let originalCropRatioTitle = "Original Ratio"

  var cropRatioTitle: String {
    customCropRatioTitle ?? (cropAspectRatio == .free ? "Freeform" : cropAspectRatio.effectiveDisplayName(isPortrait: isCropPortraitOrientation))
  }

  var originalCropSourceSize: OriginalCropSourceSize? {
    if let originalCropSourceSizeOverride { return originalCropSourceSizeOverride }
    guard let image = loadedSourceImage ?? effectiveSourceImage else { return nil }
    return Self.cropSourceSize(for: image)
  }

  private static func cropSourceSize(for image: NSImage) -> OriginalCropSourceSize? {
    let logicalSize = image.size
    let needsBackingSize = CropRatioFieldValues.reducedComponents(of: logicalSize) == nil
    let sourceSize = OriginalCropSourceSize(logicalSize: logicalSize,
      backingSize: needsBackingSize ? image.backingPixelSize : nil)
    return sourceSize.ratio == nil ? nil : sourceSize
  }

  var cropRatioFieldValues: (width: Int, height: Int)? {
    guard customCropRatioTitle == Self.originalCropRatioTitle else {
      return CropRatioFieldValues.components(fromTitle: cropRatioTitle)
    }
    guard let components = originalCropSourceSize?.components else { return nil }
    return isCropPortraitOrientation ? (components.height, components.width) : components
  }
  /// Whether crop aspect ratio is in portrait orientation
  @Published var isCropPortraitOrientation: Bool = false
  /// Whether to show rule of thirds grid
  @Published var showCropGrid: Bool = true
  /// Whether currently resizing (for dimension display)
  @Published var isCropResizing: Bool = false
  /// Whether Shift is held (for aspect ratio lock)
  @Published var isCropShiftLocked: Bool = false
  /// Restore sidebar when leaving crop if it was auto-collapsed on crop entry.
  private var shouldRestoreSidebarAfterCropInteraction: Bool = false
  /// True when current crop was auto-applied from the latest background cutout.
  private var didCutoutAutoApplyCrop: Bool = false
  /// Tracks the exact crop rect auto-applied by background cutout for safe revert behavior.
  private var cutoutAutoAppliedCropRect: CGRect?
  /// Whether crop handle drags snap to detected content borders (CleanShot X style).
  /// Persisted; defaults to true when the preference was never set.
  @Published var isCropEdgeSnappingEnabled: Bool = true {
    didSet {
      defaults.set(isCropEdgeSnappingEnabled, forKey: PreferencesKeys.annotateCropSnapToEdgesEnabled)
    }
  }
  /// Detected content borders of the current effective source image, in image
  /// points (cropRect space). Computed lazily by `prepareCropEdgeProfileIfNeeded()`;
  /// nilled whenever the effective image changes (load/cutout/rotation/...).
  private(set) var cropEdgeProfile: CropEdgeProfile?
  /// Identity of the NSImage the profile (or its in-flight computation) belongs
  /// to; guards against stale async results and repeat computation.
  private var cropEdgeProfileImageID: ObjectIdentifier?
  /// Whether highlighter drags snap to detected text lines (CleanShot X style).
  /// Persisted; defaults to true when the preference was never set.
  @Published var isHighlighterTextSnappingEnabled: Bool = true {
    didSet {
      defaults.set(isHighlighterTextSnappingEnabled, forKey: PreferencesKeys.annotateHighlighterTextSnappingEnabled)
      if isHighlighterTextSnappingEnabled, selectedTool == .highlighter {
        prepareTextLineProfileIfNeeded()
      }
    }
  }
  /// Detected text lines of the current effective source image, in image points
  /// (annotation space). Computed lazily by `prepareTextLineProfileIfNeeded()`;
  /// nilled whenever the effective image changes (load/cutout/rotation/...).
  private(set) var textLineProfile: AnnotateTextLineProfile?
  /// Identity of the NSImage the text profile (or its in-flight computation)
  /// belongs to; guards against stale async results and repeat computation.
  private var textLineProfileImageID: ObjectIdentifier?

  // MARK: - Measure State

  /// Source pixels for the Measure tool, built off-main when the tool is selected and dropped
  /// when it is left or the effective image changes. Nil while building.
  private(set) var measureMapper: AnnotateMeasureMapper?
  private var measureMapperImageID: ObjectIdentifier?
  private var measureMapperTask: Task<Void, Never>?
  /// Which directions a click measures (persisted).
  @Published var measureAxis: MeasureAxis = .both {
    didSet { defaults.set(measureAxis.rawValue, forKey: PreferencesKeys.annotateMeasureAxis) }
  }
  /// Unit for new measurements (persisted). Changing it with a measurement selected converts
  /// that one too (see `setMeasureUnit`).
  @Published private(set) var measureUnit: MeasureUnit = .points
  /// Edge tolerance, shared with Screen Ruler.
  var measureTolerance: Int { ScreenRulerPreferences(defaults: defaults).edgeTolerance }

  // MARK: - Cut Out State

  /// Whether cut-out mode is actively editing (a strip can be drawn/committed).
  @Published var isCutOutActive: Bool = false
  /// Strip being drawn or previewed, in image points, standardized. nil = none.
  @Published var cutOutPreviewStrip: CGRect?
  /// Horizontal strip bands the full image width (image shrinks vertically);
  /// vertical strips shrink horizontally.
  @Published var cutOutOrientation: CutOutOrientation = .horizontal
  /// Remove joins the halves; insert pushes content apart and adds space.
  @Published var cutOutMode: CutOutMode = .remove
  /// Context to restore after leaving cut-out mode (same shape as crop's).
  private var cutOutInteractionContext: CropInteractionContext?

  var isCutOutInteractionActive: Bool { selectedTool == .cutOut && isCutOutActive }

  /// True when the user may enter cut-out mode or commit a strip. Conflicts
  /// with crop (rect is in the same image coordinate space) and the combine /
  /// mockup surfaces, which own their own layout of the source image.
  var canApplyCutOut: Bool {
    hasImage && editorMode == .annotate && !isCombineMode
      && !isCropActive && !isCutoutProcessing && !isOCRProcessing
  }

  // MARK: - Mockup State

  @Published var mockupRotationX: Double = 0
  @Published var mockupRotationY: Double = 0
  @Published var mockupRotationZ: Double = 0
  @Published var mockupPerspective: Double = 0.5
  @Published var mockupShadowIntensity: Double = 0.3
  @Published var mockupCornerRadius: Double = 12
  @Published var mockupPadding: CGFloat = 40
  @Published var selectedMockupPresetId: UUID?

  /// Computed shadow properties for mockup
  var mockupShadowOffsetX: CGFloat { CGFloat(mockupRotationY) * 0.8 }
  var mockupShadowOffsetY: CGFloat { CGFloat(mockupRotationX) * 0.5 + 8 }
  var mockupShadowRadius: CGFloat { CGFloat(20 * (1.1 - mockupPerspective) * mockupShadowIntensity * 2) }
  var isCropInteractionActive: Bool { selectedTool == .crop && isCropActive }

  /// Apply mockup preset
  func applyMockupPreset(_ preset: MockupPreset) {
    DiagnosticLogger.shared.log(.info, .annotate, "Mockup preset applied", context: ["id": preset.id.uuidString])
    mockupRotationX = preset.rotationX
    mockupRotationY = preset.rotationY
    mockupRotationZ = preset.rotationZ
    mockupPerspective = preset.perspective
    mockupPadding = preset.padding
    selectedMockupPresetId = preset.id
    hasUnsavedChanges = true
  }

  /// Reset mockup to defaults
  func resetMockup() {
    DiagnosticLogger.shared.log(.info, .annotate, "Mockup reset")
    mockupRotationX = 0
    mockupRotationY = 0
    mockupRotationZ = 0
    mockupPerspective = 0.5
    mockupShadowIntensity = 0.3
    mockupCornerRadius = 12
    mockupPadding = 40
    selectedMockupPresetId = nil
  }

  // MARK: - Unsaved Changes Tracking

  /// Whether canvas has modifications not yet saved to disk
  @Published var hasUnsavedChanges: Bool = false

  // MARK: - Undo/Redo

  @Published var canUndo: Bool = false
  @Published var canRedo: Bool = false

  private var undoStack: [UndoEntry] = []
  private var redoStack: [UndoEntry] = []
  /// Накопленный сдвиг начала координат при изменении области Annotate Area.
  private var annotationOriginOffset = CGPoint.zero
  private var textEditingUndoTransaction: TextEditingUndoTransaction?

  init(
    image: NSImage,
    url: URL,
    quickAccessItemId: UUID? = nil,
    cloudURL: URL? = nil,
    cloudKey: String? = nil,
    isCloudStale: Bool = false,
    defaults: UserDefaults = .standard,
    canvasPresetStore: AnnotateCanvasPresetStore? = nil,
    appliesDefaultCanvasPresetOnNewImages: Bool = true,
    opensAtActualSize: Bool = true,
    originalCropSourceSize: OriginalCropSourceSize? = nil
  ) {
    self.defaults = defaults
    self.canvasPresetStore = canvasPresetStore ?? AnnotateCanvasPresetStore.shared
    self.appliesDefaultCanvasPresetOnNewImages = appliesDefaultCanvasPresetOnNewImages
    // Новый файл (URL-схема, Quick Access, автооткрытие после снимка) – 100% при первых
    // метриках окна. Восстановленная сессия или проект открываются вписанными, как раньше.
    self.pendingInitialActualSize = opensAtActualSize
    self.sourceImage = image
    self.loadedSourceImage = image
    if let originalCropSourceSize, originalCropSourceSize.ratio != nil {
      self.originalCropSourceSizeOverride = originalCropSourceSize
    }
    self.sourceURL = url
    self.quickAccessItemId = quickAccessItemId
    self.cloudURL = cloudURL
    self.cloudKey = cloudKey
    self.isCloudStale = isCloudStale
    self.dragToAppPreparationState = .ready
    self.isCropEdgeSnappingEnabled =
      defaults.object(forKey: PreferencesKeys.annotateCropSnapToEdgesEnabled) as? Bool ?? true
    self.isHighlighterTextSnappingEnabled =
      defaults.object(forKey: PreferencesKeys.annotateHighlighterTextSnappingEnabled) as? Bool ?? true
    self.measureAxis = defaults.string(forKey: PreferencesKeys.annotateMeasureAxis).flatMap(MeasureAxis.init(rawValue:)) ?? .both
    self.measureUnit = defaults.string(forKey: PreferencesKeys.annotateMeasureUnit).flatMap(MeasureUnit.init(rawValue:)) ?? .points
    self.showSidebar = annotatePreferences.rememberBackground && defaults.bool(forKey: OwnShotAnnotatePreferenceKeys.backgroundWasOpen)
    observeAnnotatePreferences()
    loadSharedAnnotationColor()
    loadSharedAnnotationParameterDefaults()
    loadAnnotationToolProperties()
    loadCanvasPresets()
    applyDefaultCanvasPresetForNewImageIfNeeded()
  }

  /// Empty initializer for drag-drop workflow
  init(
    defaults: UserDefaults = .standard,
    canvasPresetStore: AnnotateCanvasPresetStore? = nil,
    appliesDefaultCanvasPresetOnNewImages: Bool = true
  ) {
    self.defaults = defaults
    self.canvasPresetStore = canvasPresetStore ?? AnnotateCanvasPresetStore.shared
    self.appliesDefaultCanvasPresetOnNewImages = appliesDefaultCanvasPresetOnNewImages
    self.sourceImage = nil
    self.sourceURL = nil
    self.quickAccessItemId = nil
    self.cloudURL = nil
    self.cloudKey = nil
    self.dragToAppPreparationState = .unavailable
    self.isCropEdgeSnappingEnabled =
      defaults.object(forKey: PreferencesKeys.annotateCropSnapToEdgesEnabled) as? Bool ?? true
    self.isHighlighterTextSnappingEnabled =
      defaults.object(forKey: PreferencesKeys.annotateHighlighterTextSnappingEnabled) as? Bool ?? true
    self.measureAxis = defaults.string(forKey: PreferencesKeys.annotateMeasureAxis).flatMap(MeasureAxis.init(rawValue:)) ?? .both
    self.measureUnit = defaults.string(forKey: PreferencesKeys.annotateMeasureUnit).flatMap(MeasureUnit.init(rawValue:)) ?? .points
    self.showSidebar = annotatePreferences.rememberBackground && defaults.bool(forKey: OwnShotAnnotatePreferenceKeys.backgroundWasOpen)
    observeAnnotatePreferences()
    loadSharedAnnotationColor()
    loadSharedAnnotationParameterDefaults()
    loadAnnotationToolProperties()
    loadCanvasPresets()
  }

  private func observeAnnotatePreferences() {
    annotatePreferencesObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }
  }

  // MARK: - Image Loading

  /// Load image from URL with Retina scaling
  func loadImage(from url: URL) {
    DiagnosticLogger.shared.log(.info, .annotate, "Loading image from URL", context: ["file": url.lastPathComponent])
    guard let image = Self.loadImageWithCorrectScale(from: url) else {
      DiagnosticLogger.shared.log(.error, .annotate, "Failed to load image", context: ["file": url.lastPathComponent])
      return
    }
    resetCanvasForNewBaseImage(image: image, url: url)
  }

  /// Load image directly
  func loadImage(_ image: NSImage, url: URL? = nil) {
    DiagnosticLogger.shared.log(.info, .annotate, "Loading image directly", context: [
      "size": "\(Int(image.size.width))x\(Int(image.size.height))",
      "url": url?.lastPathComponent ?? "nil"
    ])
    resetCanvasForNewBaseImage(image: image, url: url)
  }

  /// Replace the backing screenshot while keeping editable annotations.
  /// Used by inline area annotate when the selected region moves or resizes.
  func replaceSourceImagePreservingAnnotations(_ image: NSImage, annotationOffset: CGPoint = .zero) {
    sourceImage = image
    originalCropSourceSizeOverride = Self.cropSourceSize(for: image)
    if annotationOffset != .zero {
      annotationOriginOffset.x += annotationOffset.x
      annotationOriginOffset.y += annotationOffset.y
      translateAnnotations(dx: annotationOffset.x, dy: annotationOffset.y)
    }
    cutoutImage = nil
    isCutoutApplied = false
    isCutoutProcessing = false
    cutoutErrorMessage = nil
    activeCutoutOperationID = nil
    cropRect = nil
    originalCropRect = nil
    cropInteractionContext = nil
    isCropActive = false
    cutOutInteractionContext = nil
    isCutOutActive = false
    cutOutPreviewStrip = nil
    selectedTool = switch selectedTool {
    case .crop, .cutOut: AnnotationToolType.selection
    default: selectedTool
    }
  }

  /// Import an image from a file URL.
  /// - Returns: true if import succeeded.
  @discardableResult
  func importImage(from url: URL) -> Bool {
    guard let image = Self.loadImageWithCorrectScale(from: url) else { return false }
    if !hasImage {
      loadImage(image, url: url)
      return true
    }

    addImportedImage(image, sourceData: Self.readImageData(from: url))
    return true
  }

  /// Import an image object. If the editor has no base image, this becomes the base image.
  /// Otherwise it is appended as a movable embedded-image layer.
  /// - Returns: true if import succeeded.
  @discardableResult
  func importImage(_ image: NSImage, sourceURL: URL? = nil, sourceData: Data? = nil) -> Bool {
    if !hasImage {
      loadImage(image, url: sourceURL)
      return true
    }

    addImportedImage(image, sourceData: sourceData)
    return true
  }

  /// ⌘V картинки или файла: как у эталона, объект-картинка встаёт под исходный снимок
  /// (холст растёт вниз). Без изображения – обычная загрузка.
  @discardableResult
  func pasteImage(from url: URL) -> Bool {
    guard let image = Self.loadImageWithCorrectScale(from: url) else { return false }
    guard hasImage else {
      loadImage(image, url: url)
      return true
    }
    return importImage(image, sourceData: Self.readImageData(from: url), placingOn: .bottom)
  }

  @discardableResult
  func pasteImage(_ image: NSImage, sourceData: Data? = nil) -> Bool {
    importImage(image, sourceData: sourceData, placingOn: .bottom)
  }

  /// Перетаскивание на холст с изображением: новое изображение встаёт к выбранной
  /// стороне (зоны «Place on the …» эталона). Без изображения – обычная загрузка.
  @discardableResult
  func importImage(_ image: NSImage, sourceData: Data?, placingOn edge: AnnotateImageDropEdge) -> Bool {
    guard hasImage else {
      loadImage(image, url: nil)
      return true
    }
    let countBefore = combineImageCount
    addImportedImage(image, sourceData: sourceData, edge: edge)
    guard combineImageCount > countBefore else { return false }
    // Авто-склейка раскладывает по направлению и порядку, свободный холст уже
    // получил рамку у нужной стороны в addImportedImage.
    if isCombineMode, combineMode == .autoStitch {
      setCombineDirection(edge.combineDirection)
      if edge.placesFirstInStitchOrder, combineImageCount > 1 {
        moveCombineImage(at: combineImageCount - 1, by: -(combineImageCount - 1))
      }
    }
    return true
  }

  /// Append an additional image layer into the current annotation canvas.
  func addImportedImage(_ image: NSImage, sourceData: Data? = nil, edge: AnnotateImageDropEdge? = nil) {
    guard hasImage else {
      loadImage(image, url: nil)
      return
    }

    let imageSize = normalizedCanvasImageSize(for: image)
    guard imageSize.width > 0, imageSize.height > 0 else { return }

    activateCombineMode(preferredMode: combineMode)

    let placementBounds = edge.map {
      $0.placementBounds(imageSize: imageSize, contentBounds: combineContentBounds, gap: combineGap)
    } ?? importedImagePlacementBounds(for: imageSize)
    let assetId = UUID()

    saveState()
    embeddedImageAssets[assetId] = image
    if let sourceData {
      embeddedImageSourceData[assetId] = sourceData
      embeddedImageSnapshotCacheData[assetId] = sourceData
    }
    embeddedImageCGImageCache.removeValue(forKey: assetId)
    let item = AnnotationItem(
      type: .embeddedImage(assetId),
      bounds: placementBounds,
      properties: AnnotationProperties(strokeColor: .clear, fillColor: .clear, strokeWidth: 1)
    )
    annotations.append(item)
    freeCombineBoundsByAnnotationID[item.id] = placementBounds
    refreshCombineLayout()
    selectedAnnotationId = item.id
    editingTextAnnotationId = nil
    selectedTool = .selection
    hasUnsavedChanges = true
    updateImportWarningIfNeeded()
  }

  func embeddedImage(for assetId: UUID) -> NSImage? {
    embeddedImageAssets[assetId]
  }

  func embeddedCGImage(for assetId: UUID) -> CGImage? {
    if let cached = embeddedImageCGImageCache[assetId] {
      return cached
    }
    guard let image = embeddedImageAssets[assetId],
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    embeddedImageCGImageCache[assetId] = cgImage
    return cgImage
  }

  /// Freeze every render input into a value-type snapshot so final-image rendering can run
  /// off the main actor. Warms lazy caches (embedded CGImage) and resolves main-bound
  /// resources (sandboxed wallpaper disk access, CI blur) before copying.
  func makeRenderSnapshot() -> AnnotateRenderSnapshot? {
    guard let sourceImage = effectiveSourceImage else { return nil }

    // Warm the lazy CGImage cache for every embedded asset referenced by annotations,
    // then freeze plain dictionary copies (off-main render must be read-only).
    for annotation in annotations {
      if case .embeddedImage(let assetId) = annotation.type {
        _ = embeddedCGImage(for: assetId)
      }
    }

    // Pre-resolve the background image for the active style (mirrors the exporter's
    // resolve logic: blurred preferred when the effect is active / for .blurred style).
    let resolvedBackgroundImage: NSImage?
    switch backgroundStyle {
    case .wallpaper(let url) where url.scheme != "preset":
      resolvedBackgroundImage = isBlurredBackgroundEffectActive
        ? blurredBackgroundImage(for: url)
        : backgroundImage(for: url)
    case .blurred(let url):
      resolvedBackgroundImage = blurredBackgroundImage(for: url)
    default:
      resolvedBackgroundImage = nil
    }

    return AnnotateRenderSnapshot(
      sourceImage: sourceImage,
      editorMode: editorMode,
      drawObjectShadow: annotatePreferences.drawObjectShadow,
      isCombineMode: isCombineMode,
      effectiveContentBounds: effectiveContentBounds,
      cropRect: cropRect,
      cropFillColor: cropRect == nil ? nil : cropFillColor?.usingColorSpace(.sRGB)?.cgColor,
      annotations: annotations,
      embeddedImages: embeddedImageAssets,
      embeddedCGImages: embeddedImageCGImageCache,
      backgroundStyle: backgroundStyle,
      isBlurredBackgroundEffectActive: isBlurredBackgroundEffectActive,
      blurredBackgroundEffect: blurredBackgroundEffect,
      resolvedBackgroundImage: resolvedBackgroundImage,
      padding: padding,
      cornerRadius: cornerRadius,
      shadowIntensity: shadowIntensity,
      backgroundInset: backgroundInsetLayout(
        for: isCombineMode ? effectiveContentBounds : (cropRect ?? effectiveContentBounds),
        respectsActiveCrop: false
      ),
      imageAlignment: imageAlignment,
      aspectRatio: aspectRatio,
      aspectRatioOrientation: aspectRatioOrientation,
      mockupRotationX: mockupRotationX,
      mockupRotationY: mockupRotationY,
      mockupRotationZ: mockupRotationZ,
      mockupPerspective: mockupPerspective,
      mockupShadowRadius: mockupShadowRadius,
      mockupShadowOffsetX: mockupShadowOffsetX,
      mockupShadowOffsetY: mockupShadowOffsetY
    )
  }

  func restoreEmbeddedImageAssets(from snapshot: [UUID: Data]) {
    var restored: [UUID: NSImage] = [:]
    for (assetId, data) in snapshot {
      guard let image = NSImage(data: data) else { continue }
      restored[assetId] = image
    }
    embeddedImageAssets = restored
    embeddedImageSourceData = snapshot
    embeddedImageSnapshotCacheData = snapshot
    embeddedImageCGImageCache.removeAll()
    // Prune only when annotations are already populated. Controllers restore assets BEFORE
    // assigning annotations, so pruning here would key off an empty annotation list and wipe
    // every restored asset — collapsing a stitched combine session back to the base image.
    // The persisted snapshot only ever contains in-use assets, so skipping prune is safe.
    if !annotations.isEmpty {
      pruneUnusedEmbeddedAssets()
    }
    updateImportWarningIfNeeded()
  }

  func embeddedImageAssetsSnapshotData() -> [UUID: Data] {
    let startedAt = CFAbsoluteTimeGetCurrent()
    pruneUnusedEmbeddedAssets()
    var result: [UUID: Data] = [:]
    let usedAssetIds = usedEmbeddedImageAssetIDs()
    for assetId in usedAssetIds {
      if let sourceData = embeddedImageSourceData[assetId] {
        result[assetId] = sourceData
        continue
      }
      if let cachedData = embeddedImageSnapshotCacheData[assetId] {
        result[assetId] = cachedData
        continue
      }
      guard let image = embeddedImageAssets[assetId] else { continue }
      if let tiffData = image.tiffRepresentation {
        embeddedImageSnapshotCacheData[assetId] = tiffData
        result[assetId] = tiffData
        continue
      }
      guard let pngData = Self.pngData(from: image) else { continue }
      embeddedImageSnapshotCacheData[assetId] = pngData
      result[assetId] = pngData
    }

    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
    let totalBytes = result.values.reduce(0) { $0 + $1.count }
    DiagnosticLogger.shared.log(.debug, .annotate, "Embedded image snapshot serialized", context: [
      "assets": "\(result.count)",
      "bytes": "\(totalBytes)",
      "durationMs": "\(durationMs)"
    ])
    return result
  }

  func pruneUnusedEmbeddedAssets() {
    let usedAssetIds = usedEmbeddedImageAssetIDs()
    embeddedImageAssets = embeddedImageAssets.filter { usedAssetIds.contains($0.key) }
    embeddedImageSourceData = embeddedImageSourceData.filter { usedAssetIds.contains($0.key) }
    embeddedImageSnapshotCacheData = embeddedImageSnapshotCacheData.filter { usedAssetIds.contains($0.key) }
    embeddedImageCGImageCache = embeddedImageCGImageCache.filter { usedAssetIds.contains($0.key) }
  }

  func consumeImportWarningMessage() {
    importWarningMessage = nil
  }

  func setDragToAppPreparationState(_ newState: DragToAppPreparationState) {
    guard dragToAppPreparationState != newState else { return }
    dragToAppPreparationState = newState
  }

  private func resetCanvasForNewBaseImage(image: NSImage, url: URL?) {
    let shouldApplyDefaultPreset = !hasImage
    resetBackgroundCutoutState(markUnsaved: false)
    cancelSensitiveRedactionScan()
    sourceImage = image
    loadedSourceImage = image
    originalCropSourceSizeOverride = nil
    transformedSourceImageDataCache = nil
    sourceURL = url
    // Reset annotations for new image
    annotations.removeAll()
    embeddedImageAssets.removeAll()
    embeddedImageSourceData.removeAll()
    embeddedImageSnapshotCacheData.removeAll()
    embeddedImageCGImageCache.removeAll()
    isCombineMode = false
    combineMode = .autoStitch
    combineDirection = .smart
    combineResolvedDirection = .horizontal
    combineGap = 0
    combineContentBounds = CGRect(origin: .zero, size: image.size)
    frozenCombineContentBounds = nil
    freeCombineBoundsByAnnotationID.removeAll()
    selectedAnnotationId = nil
    editingTextAnnotationId = nil
    undoStack.removeAll()
    redoStack.removeAll()
    annotationOriginOffset = .zero
    canUndo = false
    canRedo = false

    // Reset crop for new image
    cropRect = nil
    originalCropRect = nil
    cropInteractionContext = nil
    isCropActive = false
    cutOutInteractionContext = nil
    isCutOutActive = false
    cutOutPreviewStrip = nil
    editorMode = .annotate
    hasUnsavedChanges = false
    isDefaultCanvasPresetAutoApplied = false
    importWarningMessage = nil
    lastImportWarningSignature = nil
    dragToAppPreparationState = url == nil ? .preparing : .ready

    if shouldApplyDefaultPreset {
      applyDefaultCanvasPresetForNewImageIfNeeded()
    }
    // Масштаб выставится при первых метриках окна (updateViewportMetrics).
    zoomLevel = 1.0
    panOffset = .zero
    pendingInitialActualSize = true
    // Окно уже открыто и метрики могут не измениться (картинка того же размера):
    // тогда 100% выставляется после ближайшего обновления вида.
    if canvasContainerSize != .zero, baseCanvasDisplaySize != .zero {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.pendingInitialActualSize else { return }
        self.applyInitialActualSize()
      }
    }
  }

  // MARK: - Background Cutout

  func extractText() {
    guard canExtractText, let image = effectiveSourceImage else { return }

    let operationID = UUID()
    let imageID = ObjectIdentifier(image)
    activeOCROperationID = operationID
    isOCRProcessing = true
    ocrToast = AppToastManager.shared.show(
      message: L10n.OCR.extractingContent,
      style: .info,
      duration: nil,
      variant: .compact,
      iconMode: .spinner
    )
    DiagnosticLogger.shared.log(.info, .ocr, "Annotate OCR started", context: [
      "width": "\(Int(image.size.width))",
      "height": "\(Int(image.size.height))"
    ])

    Task { [weak self] in
      do {
        let text = try await OCRService.shared.recognizeText(
          from: image,
          contentType: .interfaceText
        )

        guard let self, self.finishOCRExtraction(operationID: operationID, imageID: imageID) else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
          DiagnosticLogger.shared.log(.warning, .ocr, "Annotate OCR found no text")
          OCRResultNotifier.shared.report(.noText)
          return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DiagnosticLogger.shared.log(.info, .ocr, "Annotate OCR text copied to clipboard", context: [
          "chars": "\(text.count)"
        ])
        OCRResultNotifier.shared.report(.copied(text))
      } catch OCRError.noTextFound {
        guard let self, self.finishOCRExtraction(operationID: operationID, imageID: imageID) else { return }
        DiagnosticLogger.shared.log(.warning, .ocr, "Annotate OCR found no text")
        OCRResultNotifier.shared.report(.noText)
      } catch {
        guard let self, self.finishOCRExtraction(operationID: operationID, imageID: imageID) else { return }
        DiagnosticLogger.shared.logError(.ocr, error, "Annotate OCR failed")
        OCRResultNotifier.shared.report(.failed(errorDescription: error.localizedDescription))
      }
    }
  }

  private func finishOCRExtraction(operationID: UUID, imageID: ObjectIdentifier) -> Bool {
    guard activeOCROperationID == operationID,
          effectiveSourceImage.map({ ObjectIdentifier($0) }) == imageID else { return false }
    activeOCROperationID = nil
    isOCRProcessing = false
    if let ocrToast {
      AppToastManager.shared.dismiss(ocrToast)
      self.ocrToast = nil
    }
    return true
  }

  private func cancelOCRExtraction() {
    activeOCROperationID = nil
    isOCRProcessing = false
    if let ocrToast {
      AppToastManager.shared.dismiss(ocrToast)
      self.ocrToast = nil
    }
  }

  func autoRedactSensitiveData() {
    guard !isSensitiveRedactionScanning else { return }
    guard let image = effectiveSourceImage else {
      showSensitiveRedactionToast(message: L10n.AnnotateUI.autoRedactionImageUnavailable, style: .warning)
      return
    }

    if editingTextAnnotationId != nil {
      commitTextEditing()
    }

    let operationID = UUID()
    activeSensitiveRedactionOperationID = operationID
    isSensitiveRedactionScanning = true
    sensitiveRedactionToast = AppToastManager.shared.show(
      message: L10n.AnnotateUI.autoRedactionScanning,
      style: .info,
      duration: nil,
      variant: .compact,
      iconMode: .spinner
    )

    Task {
      do {
        let result = try await AnnotateSensitiveRedactionService.shared.detectRegions(in: image)
        guard activeSensitiveRedactionOperationID == operationID else { return }

        isSensitiveRedactionScanning = false
        activeSensitiveRedactionOperationID = nil

        let insertedCount = applySensitiveRedactionRegions(result.regions)
        if insertedCount == 0 {
          updateSensitiveRedactionToast(message: L10n.AnnotateUI.autoRedactionNoMatches, style: .warning)
        } else {
          updateSensitiveRedactionToast(
            message: L10n.AnnotateUI.autoRedactionComplete(insertedCount),
            style: .success
          )
        }

        DiagnosticLogger.shared.log(.info, .annotate, "Sensitive redaction scan completed", context: [
          "regions": "\(insertedCount)"
        ])
      } catch {
        guard activeSensitiveRedactionOperationID == operationID else { return }

        isSensitiveRedactionScanning = false
        activeSensitiveRedactionOperationID = nil
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        updateSensitiveRedactionToast(message: message, style: .error)
        DiagnosticLogger.shared.log(.error, .annotate, "Sensitive redaction scan failed", context: [
          "error": String(describing: type(of: error))
        ])
      }
    }
  }

  @discardableResult
  func applySensitiveRedactionRegions(_ regions: [AnnotateSensitiveRedactionRegion]) -> Int {
    let clampedRegions = regions
      .map { region in
        AnnotateSensitiveRedactionRegion(
          kind: region.kind,
          bounds: region.bounds.standardized.intersection(sourceImageBounds).standardized,
          confidence: region.confidence
        )
      }
      .filter { !$0.bounds.isEmpty && $0.bounds.width >= 2 && $0.bounds.height >= 2 }

    guard !clampedRegions.isEmpty else { return 0 }

    saveState()
    let blurProperties = annotationCreationProperties(for: .blur)
    let redactionBlurType = blurType
    let newAnnotations = clampedRegions.map { region in
      AnnotationItem(
        type: .blur(redactionBlurType),
        bounds: region.bounds,
        properties: blurProperties
      )
    }

    annotations.append(contentsOf: newAnnotations)
    setSelectedAnnotationIds(Set(newAnnotations.map(\.id)))
    selectedTool = .selection
    finishTextEditing()
    return newAnnotations.count
  }

  private func cancelSensitiveRedactionScan() {
    activeSensitiveRedactionOperationID = nil
    isSensitiveRedactionScanning = false
    if let toast = sensitiveRedactionToast {
      AppToastManager.shared.dismiss(toast)
      sensitiveRedactionToast = nil
    }
  }

  private func showSensitiveRedactionToast(message: String, style: AppToastStyle) {
    AppToastManager.shared.show(
      message: message,
      style: style,
      variant: .compact
    )
  }

  private func updateSensitiveRedactionToast(message: String, style: AppToastStyle) {
    if let toast = sensitiveRedactionToast {
      AppToastManager.shared.update(
        toast,
        message: message,
        style: style,
        duration: 2.5,
        variant: .compact
      )
      sensitiveRedactionToast = nil
    } else {
      showSensitiveRedactionToast(message: message, style: style)
    }
  }

  func toggleBackgroundCutout() {
    if isCutoutApplied {
      resetBackgroundCutoutState(markUnsaved: true)
    } else {
      applyBackgroundCutout()
    }
  }

  func applyBackgroundCutout() {
    guard !isCutoutProcessing else { return }

    guard canUseBackgroundCutout else {
      cutoutErrorMessage = ForegroundCutoutError.unsupportedOS.localizedDescription
      return
    }

    guard let sourceImage,
          let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      cutoutErrorMessage = "Unable to load image data for background cutout."
      return
    }

    let operationID = UUID()
    activeCutoutOperationID = operationID
    clearCutoutAutoCropTracking()
    isCutoutProcessing = true
    cutoutErrorMessage = nil

    Task {
      do {
        let cutoutResult = try await ForegroundCutoutService.shared.extractForegroundResult(from: sourceCGImage)

        guard activeCutoutOperationID == operationID else { return }
        cutoutImage = NSImage(cgImage: cutoutResult.fullCanvasImage, size: sourceImage.size)
        isCutoutApplied = true
        isCutoutProcessing = false
        applyCutoutSuggestedAutoCropIfNeeded(
          cutoutResult: cutoutResult,
          sourceCGImage: sourceCGImage,
          autoCropEnabled: isBackgroundCutoutAutoCropEnabled
        )
        hasUnsavedChanges = true
      } catch {
        guard activeCutoutOperationID == operationID else { return }
        isCutoutProcessing = false

        if let localizedError = error as? LocalizedError, let message = localizedError.errorDescription {
          cutoutErrorMessage = message
        } else {
          cutoutErrorMessage = error.localizedDescription
        }
      }
    }
  }

  func resetBackgroundCutoutState(markUnsaved: Bool) {
    activeCutoutOperationID = nil
    isCutoutProcessing = false
    revertCutoutAutoCropIfNeeded()
    clearCutoutAutoCropTracking()
    cutoutImage = nil
    isCutoutApplied = false
    cutoutErrorMessage = nil

    if markUnsaved {
      hasUnsavedChanges = true
    }
  }

  /// Snapshot cutout state for Quick Access session caching.
  func cutoutSnapshot() -> (
    isApplied: Bool,
    cutoutImageData: Data?,
    didAutoApplyCrop: Bool,
    autoAppliedCropRect: CGRect?
  ) {
    guard isCutoutApplied, let cutoutImage else { return (false, nil, false, nil) }
    guard let cutoutImageData = Self.pngData(from: cutoutImage) else {
      DiagnosticLogger.shared.log(.warning, .annotate, "Cutout snapshot skipped: PNG encoding failed")
      return (false, nil, false, nil)
    }
    return (
      true,
      cutoutImageData,
      didCutoutAutoApplyCrop,
      didCutoutAutoApplyCrop ? cutoutAutoAppliedCropRect : nil
    )
  }

  /// Restore cutout state from Quick Access session cache.
  func restoreBackgroundCutout(
    isApplied: Bool,
    cutoutImageData: Data?,
    didAutoApplyCrop: Bool = false,
    autoAppliedCropRect: CGRect? = nil
  ) {
    activeCutoutOperationID = nil
    isCutoutProcessing = false
    cutoutErrorMessage = nil

    guard isApplied,
          let cutoutImageData,
          let restoredImage = NSImage(data: cutoutImageData) else {
      cutoutImage = nil
      isCutoutApplied = false
      clearCutoutAutoCropTracking()
      return
    }

    if let sourceImage {
      restoredImage.size = sourceImage.size
    }
    cutoutImage = restoredImage
    isCutoutApplied = true
    if didAutoApplyCrop, let autoAppliedCropRect {
      didCutoutAutoApplyCrop = true
      cutoutAutoAppliedCropRect = autoAppliedCropRect
    } else {
      clearCutoutAutoCropTracking()
    }
  }

  private func applyCutoutSuggestedAutoCropIfNeeded(
    cutoutResult: ForegroundCutoutResult,
    sourceCGImage: CGImage,
    autoCropEnabled: Bool
  ) {
    guard autoCropEnabled else { return }
    guard cropRect == nil, !isCropActive else { return }
    guard cutoutResult.autoCropDecision == .suggested,
          let suggestedPixelRect = cutoutResult.suggestedAutoCropRect else { return }

    let convertedRect = Self.convertAutoCropRectToImageCoordinates(
      pixelRectTopLeft: suggestedPixelRect,
      sourceImageSize: sourceImage?.size ?? .zero,
      sourcePixelSize: CGSize(width: sourceCGImage.width, height: sourceCGImage.height)
    )
    guard !convertedRect.isEmpty else { return }

    let clampedRect = constrainCropToImageBounds(convertedRect)
    cropRect = clampedRect
    didCutoutAutoApplyCrop = true
    cutoutAutoAppliedCropRect = clampedRect
  }

  private func revertCutoutAutoCropIfNeeded() {
    guard didCutoutAutoApplyCrop,
          let autoCropRect = cutoutAutoAppliedCropRect,
          let currentCropRect = cropRect else { return }
    if Self.rectApproximatelyEqual(currentCropRect, autoCropRect) {
      cropRect = nil
      isCropActive = false
    }
  }

  private func clearCutoutAutoCropTracking() {
    didCutoutAutoApplyCrop = false
    cutoutAutoAppliedCropRect = nil
  }

  private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
      abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
      abs(lhs.width - rhs.width) <= tolerance &&
      abs(lhs.height - rhs.height) <= tolerance
  }

  private static func convertAutoCropRectToImageCoordinates(
    pixelRectTopLeft: CGRect,
    sourceImageSize: CGSize,
    sourcePixelSize: CGSize
  ) -> CGRect {
    guard sourceImageSize.width > 0,
          sourceImageSize.height > 0,
          sourcePixelSize.width > 0,
          sourcePixelSize.height > 0 else { return .zero }

    let scaleX = sourceImageSize.width / sourcePixelSize.width
    let scaleY = sourceImageSize.height / sourcePixelSize.height

    let x = pixelRectTopLeft.origin.x * scaleX
    let width = pixelRectTopLeft.width * scaleX
    let height = pixelRectTopLeft.height * scaleY
    let topY = pixelRectTopLeft.origin.y * scaleY
    let y = sourceImageSize.height - topY - height

    return CGRect(x: x, y: y, width: width, height: height)
  }

  private static func pngData(from image: NSImage) -> Data? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    return bitmap.representation(using: .png, properties: [:])
  }

  /// Load image and adjust logical size for the density recorded in the file itself.
  static func loadImageWithCorrectScale(from url: URL) -> NSImage? {
    guard let image = SandboxFileAccessManager.shared.withScopedAccess(to: url, {
      NSImage(contentsOf: url)
    }) else { return nil }

    // Prefer the file's own DPI metadata (Snapzy writes scale × 72 DPI on save) so
    // native-density (1×) captures keep their authored logical size on any display
    // arrangement. Files without usable DPI (e.g. WebP) open at one pixel per point.
    // Без DPI эталон показывает файл как 1 px = 1 pt (spec-051: PNG 800×400 без pHYs – 800×400 pt).
    let scaleFactor = fileDensityScaleFactor(from: url) ?? 1.0
    if let normalizedSize = normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: scaleFactor) {
      image.size = normalizedSize
    }

    return image
  }

  /// Pixel density carried by the image file's own DPI metadata (DPI ÷ 72), read
  /// via ImageIO. Returns nil when the file has no usable DPI information, letting
  /// callers apply a fallback heuristic.
  static func fileDensityScaleFactor(from url: URL) -> CGFloat? {
    SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let dpiWidth = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
            let dpiHeight = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
            dpiWidth > 0, dpiHeight > 0 else {
        return nil
      }
      let scale = max(dpiWidth, dpiHeight) / 72.0
      guard scale.isFinite, scale > 0 else { return nil }
      return CGFloat(scale)
    }
  }

  /// Exposed (internal) for unit-testing the density-normalization branches.
  static func normalizedRetinaLogicalSizeIfNeeded(
    for image: NSImage,
    scaleFactor: CGFloat
  ) -> NSSize? {
    guard scaleFactor > 1 else { return nil }
    guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
      return nil
    }

    let pixelWidth = CGFloat(rep.pixelsWide)
    let pixelHeight = CGFloat(rep.pixelsHigh)
    let currentSize = image.size
    let expectedSize = NSSize(
      width: pixelWidth / scaleFactor,
      height: pixelHeight / scaleFactor
    )

    let isAlreadyScaled =
      abs(currentSize.width - expectedSize.width) < 0.5 &&
      abs(currentSize.height - expectedSize.height) < 0.5
    if isAlreadyScaled {
      return nil
    }

    let isUnscaledLogicalSize =
      abs(currentSize.width - pixelWidth) < 0.5 &&
      abs(currentSize.height - pixelHeight) < 0.5
    return isUnscaledLogicalSize ? expectedSize : nil
  }

  private static func readImageData(from url: URL) -> Data? {
    SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      try? Data(contentsOf: url, options: .mappedIfSafe)
    }
  }

  private func usedEmbeddedImageAssetIDs() -> Set<UUID> {
    Set(annotations.compactMap { annotation -> UUID? in
      guard case .embeddedImage(let assetId) = annotation.type else { return nil }
      return assetId
    })
  }

  private func totalEmbeddedImagePixelCount(for assetIds: Set<UUID>) -> Int64 {
    assetIds.reduce(into: Int64(0)) { total, assetId in
      guard let image = embeddedImageAssets[assetId] else { return }
      if let rep = image.representations.first {
        total += Int64(rep.pixelsWide) * Int64(rep.pixelsHigh)
        return
      }
      if let cgImage = embeddedCGImage(for: assetId) {
        total += Int64(cgImage.width) * Int64(cgImage.height)
        return
      }
      total += Int64(max(image.size.width, 0) * max(image.size.height, 0))
    }
  }

  private func updateImportWarningIfNeeded() {
    let usedAssetIds = usedEmbeddedImageAssetIDs()
    let layerCount = usedAssetIds.count
    let totalPixelCount = totalEmbeddedImagePixelCount(for: usedAssetIds)

    let shouldWarnByCount = layerCount > Self.importedImageCountWarningThreshold
    let shouldWarnByPixels = totalPixelCount > Self.importedImagePixelBudgetWarningThreshold
    guard shouldWarnByCount || shouldWarnByPixels else {
      lastImportWarningSignature = nil
      importWarningMessage = nil
      return
    }

    let totalMegaPixels = Double(totalPixelCount) / 1_000_000
    let warning = "Performance warning: imported layers \(layerCount), total ~\(String(format: "%.1f", totalMegaPixels))MP. Canvas may be less smooth."
    let signature = "\(layerCount)-\(totalPixelCount)"

    guard signature != lastImportWarningSignature else { return }
    lastImportWarningSignature = signature
    importWarningMessage = warning
    DiagnosticLogger.shared.log(.warning, .annotate, "Imported image budget warning", context: [
      "layers": "\(layerCount)",
      "pixels": "\(totalPixelCount)",
      "thresholdPixels": "\(Self.importedImagePixelBudgetWarningThreshold)"
    ])
  }

  private func normalizedCanvasImageSize(for image: NSImage) -> CGSize {
    if image.size.width > 0, image.size.height > 0 {
      return image.size
    }

    guard let rep = image.representations.first else { return .zero }
    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
  }

  private func combineLayoutItems() -> [CombineImagesLayoutItem] {
    var items = [
      CombineImagesLayoutItem(
        id: Self.combineBaseLayerID,
        size: CGSize(width: imageWidth, height: imageHeight)
      )
    ]
    for annotation in annotations {
      guard case .embeddedImage(let assetID) = annotation.type,
            let image = embeddedImageAssets[assetID] else { continue }
      let size = normalizedCanvasImageSize(for: image)
      guard size.width > 0, size.height > 0 else { continue }
      items.append(CombineImagesLayoutItem(id: annotation.id, size: size))
    }
    return items
  }

  private func applyAutomaticCombineLayout() {
    guard isCombineMode, hasImage else { return }
    let result = CombineImagesLayout.layout(
      items: combineLayoutItems(),
      direction: combineDirection,
      gap: combineGap
    )
    combineResolvedDirection = result.direction
    for index in annotations.indices {
      guard case .embeddedImage = annotations[index].type,
            let bounds = result.boundsByID[annotations[index].id] else { continue }
      annotations[index].bounds = bounds
    }
    combineContentBounds = result.contentBounds.isEmpty ? sourceImageBounds : result.contentBounds
  }

  private func captureCurrentFreeCombineBounds() {
    for annotation in annotations {
      guard case .embeddedImage = annotation.type else { continue }
      freeCombineBoundsByAnnotationID[annotation.id] = annotation.bounds
    }
  }

  private func restoreFreeCombineBounds() {
    for index in annotations.indices {
      guard case .embeddedImage = annotations[index].type else { continue }
      if let bounds = freeCombineBoundsByAnnotationID[annotations[index].id] {
        annotations[index].bounds = bounds
      } else {
        freeCombineBoundsByAnnotationID[annotations[index].id] = annotations[index].bounds
      }
    }
    updateCombineContentBounds()
  }

  private func updateCombineContentBounds() {
    guard isCombineMode else {
      combineContentBounds = sourceImageBounds
      return
    }
    let imageBounds = annotations.compactMap { annotation -> CGRect? in
      guard case .embeddedImage = annotation.type else { return nil }
      return annotation.bounds
    }
    combineContentBounds = imageBounds.reduce(sourceImageBounds) { $0.union($1) }
  }

  private func importedImagePlacementBounds(for imageSize: CGSize) -> CGRect {
    if isCombineMode {
      let baseHeight = max(imageHeight, 1)
      let scale = baseHeight / max(imageSize.height, 1)
      let targetSize = CGSize(width: imageSize.width * scale, height: baseHeight)
      return CGRect(
        origin: CGPoint(x: combineContentBounds.maxX + combineGap, y: combineContentBounds.minY),
        size: targetSize
      )
    }

    let drawingBounds: CGRect
    if let cropRect = cropRect, !isCropActive {
      drawingBounds = cropRect
    } else {
      drawingBounds = CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight))
    }

    let maxWidth = max(1, drawingBounds.width * Self.importedImageMaxCoverage)
    let maxHeight = max(1, drawingBounds.height * Self.importedImageMaxCoverage)
    let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
    let targetSize = CGSize(
      width: max(1, imageSize.width * scale),
      height: max(1, imageSize.height * scale)
    )

    let existingEmbeddedCount = annotations.reduce(into: 0) { count, annotation in
      if case .embeddedImage = annotation.type {
        count += 1
      }
    }
    let cascade = CGFloat(existingEmbeddedCount) * Self.importedImageCascadeStep
    let baseX = drawingBounds.midX - targetSize.width / 2 + cascade
    let baseY = drawingBounds.midY - targetSize.height / 2 - cascade

    let minX = drawingBounds.minX
    let maxX = drawingBounds.maxX - targetSize.width
    let minY = drawingBounds.minY
    let maxY = drawingBounds.maxY - targetSize.height

    let clampedX = min(max(baseX, minX), maxX)
    let clampedY = min(max(baseY, minY), maxY)

    return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: targetSize)
  }

  // MARK: - Undo/Redo Methods

  /// Bounds undo memory; per-tick slider snapshots previously grew the stack
  /// without limit during a single drag (see issue #335).
  private static let maxUndoStackSize = 50

  func saveState() {
    pushUndoSnapshot(currentSnapshot(), annotationCount: annotations.count)
  }

  private func pushUndoSnapshot(_ snapshot: AnnotationSnapshot, annotationCount: Int) {
    DiagnosticLogger.shared.log(.debug, .annotate, "Undo checkpoint", context: ["annotations": "\(annotationCount)"])
    undoStack.append(.annotations(snapshot))
    capUndoStack()
    redoStack.removeAll()
    canUndo = true
    canRedo = false
    hasUnsavedChanges = true
  }

  private func pushImageTransformUndo(_ snapshot: ImageTransformSnapshot) {
    DiagnosticLogger.shared.log(.debug, .annotate, "Undo checkpoint", context: ["kind": "imageTransform"])
    // Другая трансформация внутри Crop (Image size) уже сохранила состояние до входа,
    // второй точки с тем же состоянием при Apply не нужно.
    cropUndoSnapshot = nil
    undoStack.append(.imageTransform(snapshot))
    capUndoStack()
    redoStack.removeAll()
    canUndo = true
    canRedo = false
    hasUnsavedChanges = true
  }

  /// Точка undo перед сменой фона или параметров холста из сайдбара.
  /// Внутри жеста (`setCanvasEffectsGestureEditing`) пишется только первая
  /// точка: в ней состояние до жеста, остальные шаги жеста её не дублируют.
  func saveCanvasEffectsState() {
    if isCanvasEffectsGestureEditing {
      guard !didRecordCanvasEffectsGestureUndo else { return }
      didRecordCanvasEffectsGestureUndo = true
    }
    DiagnosticLogger.shared.log(.debug, .annotate, "Undo checkpoint", context: ["kind": "canvasEffects"])
    undoStack.append(.canvasEffects(currentCanvasEffectsUndoSnapshot()))
    capUndoStack()
    redoStack.removeAll()
    canUndo = true
    canRedo = false
  }

  private func currentCanvasEffectsUndoSnapshot() -> CanvasEffectsUndoSnapshot {
    CanvasEffectsUndoSnapshot(
      effects: canvasEffectsSnapshot,
      selectedCanvasPresetId: selectedCanvasPresetId,
      isSelectedCanvasPresetDirty: isSelectedCanvasPresetDirty
    )
  }

  private func applyCanvasEffectsUndoSnapshot(_ snapshot: CanvasEffectsUndoSnapshot) {
    previewPadding = nil
    previewInset = nil
    previewShadowIntensity = nil
    previewCornerRadius = nil
    applyCanvasEffects(
      snapshot.effects,
      preferredSelectedCanvasPresetId: snapshot.selectedCanvasPresetId,
      preferredPresetDirtyState: snapshot.isSelectedCanvasPresetDirty
    )
    isDefaultCanvasPresetAutoApplied = false
    hasUnsavedChanges = true
  }

  private func capUndoStack() {
    if undoStack.count > Self.maxUndoStackSize {
      undoStack.removeFirst(undoStack.count - Self.maxUndoStackSize)
    }
  }

  func undo() {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    DiagnosticLogger.shared.log(.debug, .annotate, "Undo", context: ["stackDepth": "\(undoStack.count)"])
    guard let previous = undoStack.popLast() else { return }
    switch previous {
    case .annotations(let snapshot):
      redoStack.append(.annotations(currentSnapshot()))
      applySnapshot(snapshot)
    case .imageTransform(let snapshot):
      redoStack.append(.imageTransform(currentImageTransformSnapshot()))
      applyImageTransformSnapshot(snapshot)
    case .canvasEffects(let snapshot):
      redoStack.append(.canvasEffects(currentCanvasEffectsUndoSnapshot()))
      applyCanvasEffectsUndoSnapshot(snapshot)
    }
    canUndo = !undoStack.isEmpty
    canRedo = true
  }

  func redo() {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    DiagnosticLogger.shared.log(.debug, .annotate, "Redo", context: ["stackDepth": "\(redoStack.count)"])
    guard let next = redoStack.popLast() else { return }
    switch next {
    case .annotations(let snapshot):
      undoStack.append(.annotations(currentSnapshot()))
      applySnapshot(snapshot)
    case .imageTransform(let snapshot):
      undoStack.append(.imageTransform(currentImageTransformSnapshot()))
      applyImageTransformSnapshot(snapshot)
    case .canvasEffects(let snapshot):
      undoStack.append(.canvasEffects(currentCanvasEffectsUndoSnapshot()))
      applyCanvasEffectsUndoSnapshot(snapshot)
    }
    canUndo = true
    canRedo = !redoStack.isEmpty
  }

  private func currentSnapshot() -> AnnotationSnapshot {
    AnnotationSnapshot(
      annotations: annotations,
      originOffset: annotationOriginOffset,
      embeddedImageAssets: embeddedImageAssets,
      embeddedImageSourceData: embeddedImageSourceData,
      embeddedImageSnapshotCacheData: embeddedImageSnapshotCacheData,
      autoSizingTextAnnotationIDs: autoSizingTextAnnotationIDs,
      freeCombineBoundsByAnnotationID: freeCombineBoundsByAnnotationID,
      selectedAnnotationIds: selectedAnnotationIds
    )
  }

  private func currentImageTransformSnapshot() -> ImageTransformSnapshot {
    ImageTransformSnapshot(
      sourceImage: sourceImage,
      cutoutImage: cutoutImage,
      isCutoutApplied: isCutoutApplied,
      embeddedImageAssets: embeddedImageAssets,
      embeddedImageSourceData: embeddedImageSourceData,
      embeddedImageSnapshotCacheData: embeddedImageSnapshotCacheData,
      annotations: annotations,
      cropRect: cropRect,
      originalCropRect: originalCropRect,
      cropAspectRatio: cropAspectRatio,
      customCropRatio: customCropRatio,
      customCropRatioTitle: customCropRatioTitle,
      isCropPortraitOrientation: isCropPortraitOrientation,
      didCutoutAutoApplyCrop: didCutoutAutoApplyCrop,
      cutoutAutoAppliedCropRect: cutoutAutoAppliedCropRect
    )
  }

  func beginTextEditing(id: UUID, recordsUndo: Bool = true) {
    if let activeId = editingTextAnnotationId, activeId != id {
      commitTextEditing()
    }

    if recordsUndo,
       let annotation = annotations.first(where: { $0.id == id }),
       case .text(let text) = annotation.type {
      textEditingUndoTransaction = TextEditingUndoTransaction(
        annotationId: id,
        snapshotBeforeEdit: currentSnapshot(),
        originalText: text
      )
    } else {
      textEditingUndoTransaction = nil
    }

    editingTextAnnotationId = id
  }

  func useAutomaticTextWidth(for id: UUID) {
    guard let annotation = annotations.first(where: { $0.id == id }),
          case .text = annotation.type else { return }
    autoSizingTextAnnotationIDs.insert(id)
  }

  func finishTextEditing() {
    editingTextAnnotationId = nil
  }

  private func recordTextEditingUndoIfNeeded(id: UUID, newText: String) {
    guard var transaction = textEditingUndoTransaction,
          transaction.annotationId == id,
          !transaction.didRecordUndo,
          transaction.originalText != newText else { return }

    pushUndoSnapshot(
      transaction.snapshotBeforeEdit,
      annotationCount: transaction.snapshotBeforeEdit.annotations.count
    )
    transaction.didRecordUndo = true
    textEditingUndoTransaction = transaction
  }

  private func applySnapshot(_ snapshot: AnnotationSnapshot) {
    let dx = annotationOriginOffset.x - snapshot.originOffset.x
    let dy = annotationOriginOffset.y - snapshot.originOffset.y
    if dx == 0 && dy == 0 {
      annotations = snapshot.annotations
    } else {
      annotations = snapshot.annotations.map { $0.translatedBy(dx: dx, dy: dy) }
    }
    embeddedImageAssets = snapshot.embeddedImageAssets
    embeddedImageSourceData = snapshot.embeddedImageSourceData
    embeddedImageSnapshotCacheData = snapshot.embeddedImageSnapshotCacheData
    embeddedImageCGImageCache.removeAll()
    autoSizingTextAnnotationIDs = snapshot.autoSizingTextAnnotationIDs
    freeCombineBoundsByAnnotationID = snapshot.freeCombineBoundsByAnnotationID
    pruneUnusedEmbeddedAssets()
    updateImportWarningIfNeeded()

    let validAnnotationIds = Set(annotations.map(\.id))
    setSelectedAnnotationIds(snapshot.selectedAnnotationIds.intersection(validAnnotationIds))

    if let editingTextAnnotationId,
       !annotations.contains(where: { $0.id == editingTextAnnotationId }) {
      self.editingTextAnnotationId = nil
    }
    refreshCombineLayout()
  }

  private func applyImageTransformSnapshot(_ snapshot: ImageTransformSnapshot) {
    sourceImage = snapshot.sourceImage
    cutoutImage = snapshot.cutoutImage
    isCutoutApplied = snapshot.isCutoutApplied
    embeddedImageAssets = snapshot.embeddedImageAssets
    embeddedImageSourceData = snapshot.embeddedImageSourceData
    embeddedImageSnapshotCacheData = snapshot.embeddedImageSnapshotCacheData
    embeddedImageCGImageCache.removeAll()
    annotations = snapshot.annotations
    cropRect = snapshot.cropRect
    originalCropRect = snapshot.originalCropRect
    cropAspectRatio = snapshot.cropAspectRatio
    customCropRatio = snapshot.customCropRatio
    customCropRatioTitle = snapshot.customCropRatioTitle
    isCropPortraitOrientation = snapshot.isCropPortraitOrientation
    didCutoutAutoApplyCrop = snapshot.didCutoutAutoApplyCrop
    cutoutAutoAppliedCropRect = snapshot.cutoutAutoAppliedCropRect

    // Rotation is gated on `!isCropActive` (see `canRotateImage`), so any rotation snapshot
    // by definition represents a non-crop state. If the user enters crop mode and then
    // undoes the rotation, we must clear the crop interaction so it doesn't keep editing
    // against the differently-sized restored image with stale bounds.
    if isCropActive {
      restoreSidebarAfterCropInteractionIfNeeded()
      isCropActive = false
      isCropResizing = false
      isCropShiftLocked = false
      cropInteractionContext = nil
      shouldRestoreSidebarAfterCropInteraction = false
      if selectedTool == .crop {
        selectedTool = .selection
      }
    }

    // An undo restores a differently-sized image; a stale strip would propose
    // the wrong band, so drop the preview while cut-out stays in mode.
    if cutOutPreviewStrip != nil {
      cutOutPreviewStrip = nil
    }

    pruneUnusedEmbeddedAssets()
    updateImportWarningIfNeeded()

    let validAnnotationIds = Set(annotations.map(\.id))
    setSelectedAnnotationIds(selectedAnnotationIds.intersection(validAnnotationIds))

    if let editingTextAnnotationId,
       !annotations.contains(where: { $0.id == editingTextAnnotationId }) {
      self.editingTextAnnotationId = nil
    }
  }

  // MARK: - Image size and reflection

  var cropPixelSize: CGSize {
    guard let source = effectiveSourceImage else { return .zero }
    let bounds = cropRect ?? CGRect(origin: .zero, size: source.size)
    let scale = AnnotateExporter.sourceImageScale(source)
    // Как у эталона: до ближайшего целого (600×400 и 7:3 → 600×257, а не 258).
    return CGSize(
      width: max(1, (bounds.width * scale).rounded()),
      height: max(1, (bounds.height * scale).rounded())
    )
  }

  func resizeImage(pixelWidth: Int, pixelHeight: Int, flattenAnnotations: Bool) {
    guard let source = sourceImage, !isCutOutActive, !isCutoutProcessing,
          !isCombineMode, pixelWidth > 0, pixelHeight > 0,
          pixelWidth <= 32768, pixelHeight <= 32768 else { return }
    // ANN-265: Resize полного снимка без изменения пикселей не меняет Crop,
    // исходник, dirty и undo. Настоящая обрезка и Flatten остаются операциями.
    if !flattenAnnotations, (cropRect == nil || cropRect == CGRect(origin: .zero, size: source.size)),
      source.backingPixelSize == CGSize(width: pixelWidth, height: pixelHeight) {
      return
    }
    if editingTextAnnotationId != nil { commitTextEditing() }
    let bounds = cropRect ?? CGRect(origin: .zero, size: source.size)
    guard bounds.width > 0, bounds.height > 0 else { return }
    var input = source
    if flattenAnnotations || cropRect != nil {
      guard var snapshot = makeRenderSnapshot() else { return }
      // Запекание остаётся на холсте: Secure сохраняет сетку предпросмотра без скачка.
      snapshot.secureExportSalt = 0
      if !flattenAnnotations {
        snapshot.sourceImage = source
        snapshot.annotations = []
      }
      guard let flattened = AnnotateExporter.renderMockupFlatImage(snapshot: snapshot) else { return }
      input = flattened
    }
    let pixelScale = AnnotateExporter.sourceImageScale(source)
    guard let resized = input.resizedToPixels(width: pixelWidth, height: pixelHeight, pixelScale: pixelScale) else { return }
    var resizedCutout: NSImage?
    if !flattenAnnotations, let cutoutImage, var snapshot = makeRenderSnapshot() {
      snapshot.sourceImage = cutoutImage
      snapshot.annotations = []
      guard let cropped = AnnotateExporter.renderMockupFlatImage(snapshot: snapshot),
            let transformed = cropped.resizedToPixels(width: pixelWidth, height: pixelHeight, pixelScale: pixelScale) else { return }
      resizedCutout = transformed
    }
    pushImageTransformUndo(currentImageTransformSnapshot())
    let sx = resized.size.width / bounds.width
    let sy = resized.size.height / bounds.height
    sourceImage = resized
    self.cutoutImage = resizedCutout
    if flattenAnnotations {
      // Запекание необратимо: старые снимки возвращали бы редактируемую разметку.
      undoStack.removeAll()
      redoStack.removeAll()
      canUndo = false
      canRedo = false
      annotations = []
      selectedAnnotationIds = []
      // Эффективный исходник уже содержит маску и запечённые аннотации.
      self.cutoutImage = nil
      isCutoutApplied = false
    } else {
      annotations = annotations.map {
        $0.translatedBy(dx: -bounds.minX, dy: -bounds.minY).scaledForImageResize(sx: sx, sy: sy)
      }
    }
    // Рамка уже применена к пикселям: рамка становится полной.
    let resizedBounds = CGRect(origin: .zero, size: resized.size)
    cropRect = cropRect.map { _ in resizedBounds }
    originalCropRect = originalCropRect.map { _ in resizedBounds }
    cutoutAutoAppliedCropRect = cutoutAutoAppliedCropRect.map { _ in resizedBounds }
    if let context = cropInteractionContext {
      cropInteractionContext = CropInteractionContext(
        selectedTool: context.selectedTool,
        selectedAnnotationIds: flattenAnnotations ? [] : context.selectedAnnotationIds,
        cropRect: context.cropRect.map { _ in resizedBounds },
        didCutoutAutoApplyCrop: !flattenAnnotations && context.didCutoutAutoApplyCrop,
        cutoutAutoAppliedCropRect: flattenAnnotations ? nil : context.cutoutAutoAppliedCropRect.map { _ in resizedBounds }
      )
    }
    hasUnsavedChanges = true
    // Эталон после Resize выходит из Crop в обычный редактор. Точку undo уже записал
    // pushImageTransformUndo выше, отдельная точка кадрирования не нужна.
    if isCropActive { exitCropAfterResize() }
  }

  private func exitCropAfterResize() {
    cropUndoSnapshot = nil
    isCropActive = false
    isCropResizing = false
    isCropShiftLocked = false
    restoreSidebarAfterCropInteractionIfNeeded()
    restoreContextAfterCropInteraction()
  }

  /// Отражение запекает аннотации только после явного выбора пункта меню.
  func flipImage(horizontal: Bool) {
    guard let source = sourceImage, !isCutOutActive, !isCutoutProcessing,
          !isCombineMode else { return }
    if editingTextAnnotationId != nil { commitTextEditing() }
    guard var snapshot = makeRenderSnapshot() else { return }
    snapshot.cropRect = nil
    // Запекание остаётся на холсте: Secure сохраняет сетку предпросмотра без скачка.
    snapshot.secureExportSalt = 0
    guard let flat = AnnotateExporter.renderMockupFlatImage(snapshot: snapshot),
          let flipped = flat.flippedImage(horizontal: horizontal) else { return }
    pushImageTransformUndo(currentImageTransformSnapshot())
    sourceImage = flipped
    cutoutImage = nil
    isCutoutApplied = false
    annotations = []
    func reflected(_ rect: CGRect) -> CGRect {
      CGRect(x: horizontal ? source.size.width - rect.maxX : rect.minX,
        y: horizontal ? rect.minY : source.size.height - rect.maxY,
        width: rect.width, height: rect.height)
    }
    cropRect = cropRect.map(reflected)
    originalCropRect = originalCropRect.map(reflected)
    cutoutAutoAppliedCropRect = cutoutAutoAppliedCropRect.map(reflected)
    hasUnsavedChanges = true
  }

  // MARK: - Rotation

  /// True when the user can rotate the source image 90°. Disabled while no image is loaded,
  /// while crop or cut-out is being actively edited, or while a background-cutout request is in flight.
  var canRotateImage: Bool {
    hasImage && !isCropActive && !isCutOutActive && !isCutoutProcessing
  }

  /// Rotate the source image 90° clockwise (or counter-clockwise) and bring all annotations,
  /// crop bounds, embedded image layers, and cutout state along for the ride. Pushes a
  /// dedicated rotation undo entry so this transform can be reversed without touching the
  /// annotation-only undo path.
  func rotateImage(clockwise: Bool) {
    guard canRotateImage,
          let source = sourceImage,
          let rotatedSource = source.rotated90(clockwise: clockwise) else {
      return
    }

    if editingTextAnnotationId != nil {
      commitTextEditing()
    }

    DiagnosticLogger.shared.log(.info, .annotate, "Image rotated", context: [
      "direction": clockwise ? "clockwise" : "counterclockwise",
      "oldSize": "\(Int(imageWidth))x\(Int(imageHeight))"
    ])

    let oldSize = CGSize(width: imageWidth, height: imageHeight)
    pushImageTransformUndo(currentImageTransformSnapshot())

    sourceImage = rotatedSource
    if let cutoutImage {
      self.cutoutImage = cutoutImage.rotated90(clockwise: clockwise)
    }

    // Rotate each embedded image asset so the rendered bitmap matches the rotated bounds, and
    // invalidate the serialised data caches so persistence re-encodes from the rotated NSImage.
    for (assetId, image) in embeddedImageAssets {
      guard let rotatedAsset = image.rotated90(clockwise: clockwise) else { continue }
      embeddedImageAssets[assetId] = rotatedAsset
      embeddedImageSourceData.removeValue(forKey: assetId)
      embeddedImageSnapshotCacheData.removeValue(forKey: assetId)
    }
    embeddedImageCGImageCache.removeAll()

    annotations = annotations.map { rotateAnnotation($0, oldSize: oldSize, clockwise: clockwise) }

    cropRect = cropRect.map { AnnotateImageRotation.rotateRect($0, oldSize: oldSize, clockwise: clockwise) }
    originalCropRect = originalCropRect.map { AnnotateImageRotation.rotateRect($0, oldSize: oldSize, clockwise: clockwise) }
    cutoutAutoAppliedCropRect = cutoutAutoAppliedCropRect.map {
      AnnotateImageRotation.rotateRect($0, oldSize: oldSize, clockwise: clockwise)
    }

    // Aspect-ratio presets such as 16:9 keep their identity but the physical orientation flips.
    if let ratio = effectiveCropRatio, ratio != 1 {
      isCropPortraitOrientation.toggle()
    }

    hasUnsavedChanges = true
  }

  private func rotateAnnotation(
    _ annotation: AnnotationItem,
    oldSize: CGSize,
    clockwise: Bool
  ) -> AnnotationItem {
    var rotated = annotation
    rotated.bounds = AnnotateImageRotation.rotateRect(annotation.bounds, oldSize: oldSize, clockwise: clockwise)

    switch annotation.type {
    case .arrow(let geometry):
      let newStart = AnnotateImageRotation.rotatePoint(geometry.start, oldSize: oldSize, clockwise: clockwise)
      let newEnd = AnnotateImageRotation.rotatePoint(geometry.end, oldSize: oldSize, clockwise: clockwise)
      let newControl = geometry.resolvedControlPoint.map {
        AnnotateImageRotation.rotatePoint($0, oldSize: oldSize, clockwise: clockwise)
      }
      let newGeometry = ArrowGeometry(
        start: newStart,
        end: newEnd,
        style: geometry.style,
        controlPoint: newControl,
        arrowType: geometry.arrowType,
        startHead: geometry.startHead,
        endHead: geometry.endHead
      )
      rotated.type = .arrow(newGeometry)
      rotated.bounds = newGeometry.bounds()

    case .line(let start, let end):
      let newStart = AnnotateImageRotation.rotatePoint(start, oldSize: oldSize, clockwise: clockwise)
      let newEnd = AnnotateImageRotation.rotatePoint(end, oldSize: oldSize, clockwise: clockwise)
      rotated.type = .line(start: newStart, end: newEnd)

    case .path(let points):
      rotated.type = .path(points.map {
        AnnotateImageRotation.rotatePoint($0, oldSize: oldSize, clockwise: clockwise)
      })

    case .highlight(let points):
      rotated.type = .highlight(points.map {
        AnnotateImageRotation.rotatePoint($0, oldSize: oldSize, clockwise: clockwise)
      })

    case .text:
      rotated.bounds = AnnotateImageRotation.rotateLayoutRectPreservingSize(
        annotation.bounds,
        oldSize: oldSize,
        clockwise: clockwise
      )

    case .counter:
      rotated.properties.counterArrowTarget = annotation.properties.counterArrowTarget.map {
        AnnotateImageRotation.rotatePoint($0, oldSize: oldSize, clockwise: clockwise)
      }

    case .measurement(let geometry):
      rotated.type = .measurement(geometry.rotated {
        AnnotateImageRotation.rotatePoint($0, oldSize: oldSize, clockwise: clockwise)
      })

    case .rectangle, .filledRectangle, .oval, .blur, .watermark, .embeddedImage, .spotlight:
      // Bounds-only annotations: the rotated `bounds` above is the full transform we need.
      // Watermark `rotationDegrees` is user-controlled and clamped to ±45°, so we leave it
      // unchanged while moving the watermark region with the canvas.
      break
    }

    return rotated
  }

  // MARK: - Counter

  /// Derive next counter value from existing annotations.
  /// This ensures undo/redo correctly adjusts future counter values.
  ///
  /// Последовательность – счётчики, созданные после последней смены Starting number.
  /// Следующий номер – максимум последовательности + 1, но не меньше Starting number.
  /// Пустая последовательность начинается с Starting number. Удаление счётчика
  /// перенумеровывает оставшиеся (renumberCounterSequence), поэтому дыр нет.
  func nextCounterValue() -> Int {
    let sequenceMax = annotations.compactMap { annotation -> Int? in
      guard case .counter(let v) = annotation.type,
            !counterSequenceBaseline.contains(annotation.id) else { return nil }
      return v
    }.max()
    guard let sequenceMax else { return counterStartingNumber }
    return max(sequenceMax + 1, counterStartingNumber)
  }

  /// Как у эталона: после удаления счётчики последовательности получают номера подряд
  /// от Starting number в порядке создания (1, 2, 3 без второго → 1, 2). Порядок создания
  /// совпадает с порядком номеров, поэтому слои (Bring to Front) на него не влияют.
  /// Счётчики до смены Starting number (counterSequenceBaseline) не трогаются.
  /// `start` – первый номер; nil – текущее начало последовательности (counterSequenceStart).
  func renumberCounterSequence(from start: Int? = nil) {
    let firstNumber = start ?? counterSequenceStart()
    let sequence = counterSequenceEntries()
    let ordered = sequence.sorted { lhs, rhs in
      lhs.value == rhs.value ? lhs.index < rhs.index : lhs.value < rhs.value
    }
    for (rank, entry) in ordered.enumerated() {
      let number = firstNumber + rank
      if entry.value != number {
        annotations[entry.index].type = .counter(number)
      }
    }
  }

  /// Начало последовательности: Starting number, а у открытого проекта, где счётчики
  /// начинаются с большего номера (7, 8, 9), – их наименьший номер.
  private func counterSequenceStart() -> Int {
    guard let minimum = counterSequenceEntries().map(\.value).min() else { return counterStartingNumber }
    return max(minimum, counterStartingNumber)
  }

  private func counterSequenceEntries() -> [(index: Int, value: Int)] {
    annotations.indices.compactMap { index -> (index: Int, value: Int)? in
      guard case .counter(let value) = annotations[index].type,
            !counterSequenceBaseline.contains(annotations[index].id) else { return nil }
      return (index, value)
    }
  }

  /// Задаёт номер следующего счётчика. Уже размещённые счётчики не перенумеровываются.
  func setCounterStartingNumber(_ value: Int) {
    counterStartingNumber = AnnotateCounterSettings.clampedStartingNumber(value)
    counterSequenceBaseline = Set(annotations.compactMap { annotation in
      if case .counter = annotation.type { return annotation.id }
      return nil
    })
  }

  private var selectedCounterAnnotations: [AnnotationItem] {
    selectedAnnotations.filter { annotation in
      if case .counter = annotation.type { return true }
      return false
    }
  }

  var activeCounterFormat: CounterNumberFormat {
    selectedCounterAnnotations.first?.properties.counterFormat
      ?? defaultAnnotationProperties(for: .counter).counterFormat
  }

  /// Формат нумерации меняется у всех счётчиков документа одним шагом undo и у новых.
  func setActiveCounterFormat(_ format: CounterNumberFormat) {
    let counters = annotations.filter { annotation in
      if case .counter = annotation.type { return true }
      return false
    }
    if counters.contains(where: { $0.properties.counterFormat != format }) {
      saveState()
      let ids = Set(counters.map(\.id))
      for index in annotations.indices where ids.contains(annotations[index].id) {
        annotations[index].properties.counterFormat = format
      }
      hasUnsavedChanges = true
    }
    updateDefaultAnnotationProperties(for: .counter, counterFormat: format)
  }

  /// Пункт подменю Size для выделенного счётчика или настроек инструмента.
  var activeCounterSize: Int? {
    AnnotateCounterSettings.size(forControlValue: quickStrokeWidthBinding.wrappedValue)
  }

  func setCounterSize(_ points: Int) {
    quickStrokeWidthBinding.wrappedValue = AnnotateCounterSettings.controlValue(forSize: points)
  }

  // MARK: - Crop Methods

  /// Collapse sidebar when user starts interacting with crop UI.
  func collapseSidebarForCropInteraction() {
    guard showSidebar else { return }
    shouldRestoreSidebarAfterCropInteraction = true
    withAnimation(.easeInOut(duration: 0.2)) {
      showSidebar = false
    }
  }

  /// Restore sidebar when crop interaction ends.
  func restoreSidebarAfterCropInteractionIfNeeded() {
    guard shouldRestoreSidebarAfterCropInteraction else { return }
    shouldRestoreSidebarAfterCropInteraction = false

    guard !showSidebar else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      showSidebar = true
    }
  }

  /// Activate crop tool from direct user interaction (toolbar/shortcut/canvas).
  func beginCropInteraction() {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    if cropInteractionContext == nil {
      cropUndoSnapshot = currentImageTransformSnapshot()
      cropInteractionContext = CropInteractionContext(
        selectedTool: selectedTool == .crop ? .selection : selectedTool,
        selectedAnnotationIds: selectedAnnotationIds,
        cropRect: cropRect,
        didCutoutAutoApplyCrop: didCutoutAutoApplyCrop,
        cutoutAutoAppliedCropRect: cutoutAutoAppliedCropRect
      )
    }

    collapseSidebarForCropInteraction()
    deselectAnnotation()
    selectedTool = .crop

    guard hasImage else { return }

    if cropRect == nil {
      initializeCrop()
    } else if let cropRect {
      originalCropRect = cropRect
      isCropActive = true
    }

    isCropResizing = false
    isCropShiftLocked = false

    applyDetectedCropFillColorIfNeeded()
    prepareCropEdgeProfileIfNeeded()
  }

  /// Как initColor эталона: при входе в Crop заливка рамки за краем снимка берёт цвет
  /// фона снимка, распознанный по краю (ANN-792). Выбор пользователя не трогается,
  /// пёстрый или прозрачный край оставляет расширение прозрачным.
  func applyDetectedCropFillColorIfNeeded() {
    guard !isCropFillColorUserChosen, cropFillColor == nil, !isCombineMode,
          let image = effectiveSourceImage,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let detected = CropBackgroundColorDetector.dominantEdgeColor(of: cgImage) else { return }
    isApplyingDetectedCropFillColor = true
    cropFillColor = detected
    isApplyingDetectedCropFillColor = false
  }

  /// Initialize crop to full image bounds
  func initializeCrop() {
    DiagnosticLogger.shared.log(.info, .annotate, "Crop initialized", context: ["imageSize": "\(Int(imageWidth))x\(Int(imageHeight))"])
    let fullImageRect = CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight))
    cropRect = fullImageRect
    originalCropRect = fullImageRect  // Save original for aspect ratio calculations
    isCropActive = true
  }

  /// Apply crop (confirm) - keeps cropRect for export
  func applyCrop() {
    DiagnosticLogger.shared.log(.info, .annotate, "Crop applied", context: [
      "rect": cropRect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
    ])
    if didCutoutAutoApplyCrop,
       let currentCropRect = cropRect,
       let autoCropRect = cutoutAutoAppliedCropRect,
       !Self.rectApproximatelyEqual(currentCropRect, autoCropRect) {
      clearCutoutAutoCropTracking()
    }
    pushCropUndoIfChanged()
    isCropActive = false
    hasUnsavedChanges = true
    restoreSidebarAfterCropInteractionIfNeeded()
  }

  /// Пишет точку undo для применённого кадрирования, если рамка или отношение
  /// изменились с момента входа в Crop. Без изменений undo не засоряется.
  private func pushCropUndoIfChanged() {
    guard let snapshot = cropUndoSnapshot else { return }
    cropUndoSnapshot = nil
    let normalizedBefore = snapshot.cropRect.flatMap { Self.rectApproximatelyEqual($0, sourceImageBounds) ? nil : $0 }
    let normalizedAfter = cropRect.flatMap { Self.rectApproximatelyEqual($0, sourceImageBounds) ? nil : $0 }
    let rectChanged: Bool
    switch (normalizedBefore, normalizedAfter) {
    case (nil, nil): rectChanged = false
    case let (before?, after?): rectChanged = !Self.rectApproximatelyEqual(before, after)
    default: rectChanged = true
    }
    guard rectChanged else { return }
    pushImageTransformUndo(snapshot)
  }

  /// Apply crop and return to the context active before crop mode.
  func confirmCropInteraction() {
    applyCrop()
    restoreContextAfterCropInteraction()
  }

  /// Reset unsaved changes flag after successful save
  func markAsSaved() {
    hasUnsavedChanges = false
    isDefaultCanvasPresetAutoApplied = false
  }

  /// Cancel crop and reset
  func cancelCrop() {
    DiagnosticLogger.shared.log(.info, .annotate, "Crop cancelled")
    cropUndoSnapshot = nil

    if let context = cropInteractionContext {
      cropRect = context.cropRect
      didCutoutAutoApplyCrop = context.didCutoutAutoApplyCrop
      cutoutAutoAppliedCropRect = context.cutoutAutoAppliedCropRect
    } else {
      cropRect = nil
      clearCutoutAutoCropTracking()
    }

    originalCropRect = nil
    isCropActive = false
    isCropResizing = false
    isCropShiftLocked = false
    restoreSidebarAfterCropInteractionIfNeeded()
    restoreContextAfterCropInteraction()
  }

  /// Reset crop to nil
  func resetCrop() {
    cropUndoSnapshot = nil
    customCropRatio = nil
    customCropRatioTitle = nil
    cropRect = nil
    originalCropRect = nil
    cropInteractionContext = nil
    isCropActive = false
    clearCutoutAutoCropTracking()
    cropAspectRatio = .free
    isCropPortraitOrientation = false
    isCropResizing = false
    isCropShiftLocked = false
  }

  /// Revert the active crop rect to the original image bounds while staying in crop mode.
  func revertCropToOriginalBounds() {
    guard hasImage else { return }
    customCropRatio = nil
    customCropRatioTitle = nil

    DiagnosticLogger.shared.log(.info, .annotate, "Crop reverted to original bounds")
    let fullImageRect = sourceImageBounds
    cropRect = fullImageRect
    originalCropRect = fullImageRect
    cropAspectRatio = .free
    isCropPortraitOrientation = false
    isCropActive = true
    isCropResizing = false
    isCropShiftLocked = false
    clearCutoutAutoCropTracking()
  }

  /// Apply aspect ratio to current crop rect
  func applyCropAspectRatio(_ ratio: CropAspectRatio) {
    customCropRatio = nil
    customCropRatioTitle = nil
    cropAspectRatio = ratio
    applyEffectiveCropRatio()
  }

  func applyCustomCropRatio(width: Double, height: Double) {
    guard width.isFinite, height.isFinite, width > 0, height > 0,
          (width / height).isFinite else { return }
    customCropRatio = CGFloat(width / height)
    customCropRatioTitle = "Custom Ratio"
    cropAspectRatio = .free
    isCropPortraitOrientation = false
    applyEffectiveCropRatio()
  }

  /// Ввод в поля отношения панели Crop: обе части задают отношение рамки, а не
  /// её размер в пикселях (spec-039 7/5 → 400×286 px на 400×800).
  func applyCropRatioFields(width: Int, height: Int) {
    guard width > 0, height > 0 else { return }
    applyCustomCropRatio(width: Double(width), height: Double(height))
    customCropRatioTitle = CropRatioFieldValues.title(width: width, height: height)
  }

  /// Revert to Original в footer Crop: рамка или отношение отличаются от исходных.
  var canRevertCropToOriginal: Bool {
    guard isCropActive, let cropRect else { return false }
    return customCropRatio != nil || cropAspectRatio != .free
      || !Self.rectApproximatelyEqual(cropRect, sourceImageBounds)
  }

  func applyOriginalCropRatio() {
    // Original Ratio относится к загруженному исходнику, независимо от поворотов.
    guard let ratio = originalCropSourceSize?.ratio else { return }
    customCropRatio = ratio
    customCropRatioTitle = Self.originalCropRatioTitle
    cropAspectRatio = .free
    isCropPortraitOrientation = false
    applyEffectiveCropRatio()
  }

  func setCropPixelSize(width: Int?, height: Int?) {
    guard let source = effectiveSourceImage, var rect = cropRect,
          width.map({ $0 > 0 && $0 <= 32768 }) ?? true,
          height.map({ $0 > 0 && $0 <= 32768 }) ?? true else { return }
    let scale = AnnotateExporter.sourceImageScale(source)
    var size = rect.size
    if let width { size.width = CGFloat(width) / scale }
    if let height { size.height = CGFloat(height) / scale }
    if let ratio = effectiveCropRatio {
      if width != nil { size.height = size.width / ratio }
      else if height != nil { size.width = size.height * ratio }
    }
    rect.origin.x += (rect.width - size.width) / 2
    rect.origin.y += (rect.height - size.height) / 2
    rect.size = size
    cropRect = rect
    originalCropRect = rect
    clearCutoutAutoCropTracking()
  }

  func swapCropDimensions() {
    guard var rect = cropRect else { return }
    let size = CGSize(width: rect.height, height: rect.width)
    rect.origin.x += (rect.width - size.width) / 2
    rect.origin.y += (rect.height - size.height) / 2
    rect.size = size
    if effectiveCropRatio != nil { isCropPortraitOrientation.toggle() }
    cropRect = rect
    originalCropRect = rect
    clearCutoutAutoCropTracking()
  }

  private func applyEffectiveCropRatio() {

    // Use original crop rect as base to prevent shrinking
    guard var rect = originalCropRect ?? cropRect, let targetRatio = effectiveCropRatio else { return }

    let currentRatio = rect.width / rect.height

    if currentRatio > targetRatio {
      // Too wide, reduce width
      let newWidth = rect.height * targetRatio
      rect.origin.x += (rect.width - newWidth) / 2
      rect.size.width = newWidth
    } else {
      // Too tall, reduce height
      let newHeight = rect.width / targetRatio
      rect.origin.y += (rect.height - newHeight) / 2
      rect.size.height = newHeight
    }

    let constrainedRect = constrainCropToImageBounds(rect)
    if didCutoutAutoApplyCrop,
       let autoCropRect = cutoutAutoAppliedCropRect,
       !Self.rectApproximatelyEqual(constrainedRect, autoCropRect) {
      clearCutoutAutoCropTracking()
    }
    cropRect = constrainedRect
  }

  /// Toggle crop orientation between landscape and portrait
  func toggleCropOrientation() {
    guard let ratio = effectiveCropRatio, ratio != 1 else { return }
    isCropPortraitOrientation.toggle()
    applyEffectiveCropRatio()
  }

  private func restoreContextAfterCropInteraction() {
    let context = cropInteractionContext
    cropInteractionContext = nil
    originalCropRect = nil

    let restoredTool: AnnotationToolType
    switch context?.selectedTool {
    case .crop, .cutOut, nil: restoredTool = .selection
    case .some(let tool): restoredTool = tool
    }
    selectedTool = restoredTool
    setSelectedAnnotationIds(context?.selectedAnnotationIds ?? [])
  }

  // MARK: - Cut Out

  /// Activate cut-out from direct user interaction (toolbar/shortcut/canvas).
  /// Mirrors `beginCropInteraction()`: stash the pre-mode context, collapse the
  /// sidebar, deselect, and force the tool.
  func beginCutOutInteraction() {
    guard canApplyCutOut else { return }
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    if cutOutInteractionContext == nil {
      cutOutInteractionContext = CropInteractionContext(
        selectedTool: selectedTool == .cutOut ? .selection : selectedTool,
        selectedAnnotationIds: selectedAnnotationIds,
        cropRect: cropRect,
        didCutoutAutoApplyCrop: didCutoutAutoApplyCrop,
        cutoutAutoAppliedCropRect: cutoutAutoAppliedCropRect
      )
    }

    collapseSidebarForCropInteraction()
    deselectAnnotation()
    selectedTool = .cutOut
    isCutOutActive = true
  }

  /// Preview/update the strip being drawn (image points, full-crossing).
  func updateCutOutStrip(_ rect: CGRect) {
    // A drag still in flight after Esc/Cancel must not resurrect a strip.
    guard canApplyCutOut, isCutOutInteractionActive else { return }
    cutOutPreviewStrip = rect.standardized.isNull ? nil : rect.standardized
  }

  /// Esc handling while cut-out owns the editor: the first press discards the
  /// drawn strip and keeps the mode, the next one leaves the mode. Never lets
  /// Esc fall through to closing the window.
  func cancelCutOutInteraction() {
    guard isCutOutInteractionActive else { return }
    if cutOutPreviewStrip != nil {
      cutOutPreviewStrip = nil
      return
    }
    cancelCutOut()
  }

  /// Leave cut-out mode and restore the tool/selection captured at entry.
  func cancelCutOut() {
    cutOutPreviewStrip = nil
    isCutOutActive = false
    restoreSidebarAfterCropInteractionIfNeeded()

    // Read the context before `selectedTool`'s didSet also clears it.
    let context = cutOutInteractionContext
    cutOutInteractionContext = nil
    guard let context else { return }
    selectedTool = context.selectedTool == .cutOut ? .selection : context.selectedTool
    setSelectedAnnotationIds(context.selectedAnnotationIds)
  }

  /// Commit the drawn strip: cut/insert the source image (and background
  /// cutout overlay), translate the content on the far side, push one
  /// image-transform undo entry, and stay in mode so several strips can be
  /// processed in a row.
  func commitCutOut() {
    guard canApplyCutOut, let strip = cutOutPreviewStrip, let image = sourceImage else {
      cutOutPreviewStrip = nil
      return
    }

    let orientation = cutOutOrientation
    let mode = cutOutMode
    let imageBounds = sourceImageBounds
    let fullStrip = AnnotateCutOutTransform.pixelAlignedStrip(
      AnnotateCutOutTransform.fullCrossingStrip(
        from: strip,
        orientation: orientation,
        imageBounds: imageBounds
      ),
      in: image,
      orientation: orientation
    )

    guard let newSource = AnnotateCutOutTransform.apply(
      to: image,
      strip: fullStrip,
      orientation: orientation,
      mode: mode
    ) else {
      DiagnosticLogger.shared.log(.info, .annotate, "Cut out rejected", context: [
        "reason": "strip covers whole image",
        "strip": "\(Int(fullStrip.width))x\(Int(fullStrip.height))"
      ])
      cutOutPreviewStrip = nil
      return
    }

    DiagnosticLogger.shared.log(.info, .annotate, "Cut out committed", context: [
      "orientation": orientation == .horizontal ? "horizontal" : "vertical",
      "mode": mode == .remove ? "remove" : "insert",
      "strip": "\(Int(fullStrip.width))x\(Int(fullStrip.height))"
    ])
    pushImageTransformUndo(currentImageTransformSnapshot())
    deselectAnnotation()

    sourceImage = newSource
    if let cutout = cutoutImage {
      // Same strip, same dimensions, so this mirrors the source result. If it
      // ever refuses, drop the overlay instead of leaving a misaligned cover.
      if let alignedCutout = AnnotateCutOutTransform.apply(to: cutout, strip: fullStrip, orientation: orientation, mode: mode) {
        cutoutImage = alignedCutout
      } else {
        cutoutImage = nil
        isCutoutApplied = false
      }
    }

    // Translate annotations across the strip: point-based geometry shifts per
    // point so shapes reconstruct faithfully across the joined band;
    // bounds-based shapes follow the majority-of-area half.
    let offset = AnnotateCutOutTransform.shiftOffset(strip: fullStrip, orientation: orientation, mode: mode)
    func shiftPoint(_ p: CGPoint) -> CGPoint {
      guard AnnotateCutOutTransform.isFarSidePoint(p, strip: fullStrip, orientation: orientation, mode: mode) else {
        return p
      }
      return CGPoint(x: p.x + offset.width, y: p.y + offset.height)
    }
    func shiftRect(_ r: CGRect) -> CGRect {
      AnnotateCutOutTransform.shiftRect(r, strip: fullStrip, orientation: orientation, mode: mode)
    }

    annotations = annotations.map { item -> AnnotationItem in
      var moved = item
      switch item.type {
      case .arrow(let geometry):
        let shifted = ArrowGeometry(
          start: shiftPoint(geometry.start),
          end: shiftPoint(geometry.end),
          style: geometry.style,
          controlPoint: geometry.resolvedControlPoint.map(shiftPoint),
          arrowType: geometry.arrowType,
          startHead: geometry.startHead,
          endHead: geometry.endHead
        )
        moved.type = .arrow(shifted)
        moved.bounds = shifted.bounds()
      case .line(let start, let end):
        let newStart = shiftPoint(start)
        let newEnd = shiftPoint(end)
        moved.type = .line(start: newStart, end: newEnd)
      case .path(let points):
        // Strokes render from their points, so shifting bounds alone leaves them behind.
        moved.type = .path(points.map(shiftPoint))
        moved.bounds = shiftRect(item.bounds)
      case .highlight(let points):
        moved.type = .highlight(points.map(shiftPoint))
        moved.bounds = shiftRect(item.bounds)
      case .counter:
        moved.properties.counterArrowTarget = item.properties.counterArrowTarget.map(shiftPoint)
        moved.bounds = shiftRect(item.bounds)
      case .text:
        moved.properties.calloutTailTarget = item.properties.calloutTailTarget.map(shiftPoint)
        moved.bounds = shiftRect(item.bounds)
      case .measurement(let geometry):
        // Move with the far side as one piece; a measured extent is never stretched.
        let shiftedBounds = shiftRect(item.bounds)
        moved.type = .measurement(geometry.translated(
          dx: shiftedBounds.minX - item.bounds.minX,
          dy: shiftedBounds.minY - item.bounds.minY
        ))
        moved.bounds = CGRect(origin: shiftedBounds.origin, size: item.bounds.size)
      case .rectangle, .filledRectangle, .oval, .blur, .embeddedImage, .spotlight, .watermark:
        moved.bounds = shiftRect(item.bounds)
      }

      return moved
    }

    // Crop state follows the joined image space with the same majority rule.
    cropRect = cropRect.map(shiftRect)
    originalCropRect = originalCropRect.map(shiftRect)
    cutoutAutoAppliedCropRect = cutoutAutoAppliedCropRect.map(shiftRect)

    cutOutPreviewStrip = nil
    hasUnsavedChanges = true
  }

  /// Update crop rect with bounds constraint
  func updateCropRect(_ newRect: CGRect) {
    let constrainedRect = constrainCropToImageBounds(newRect)
    if didCutoutAutoApplyCrop,
       let autoCropRect = cutoutAutoAppliedCropRect,
       !Self.rectApproximatelyEqual(constrainedRect, autoCropRect) {
      clearCutoutAutoCropTracking()
    }
    cropRect = constrainedRect
  }

  /// Минимальная рамка Crop эталона – 12 px изображения (b4-crop-handles-ref.txt).
  static let minimumCropPixelSize: CGFloat = CropEdgeSnapping.minimumCropPixelSize

  /// Минимальная сторона рамки Crop в точках изображения (12 px с учётом плотности снимка).
  var minimumCropSize: CGFloat {
    let scale = effectiveSourceImage.map(AnnotateExporter.sourceImageScale) ?? 1
    return Self.minimumCropPixelSize / max(scale, 1)
  }

  /// Normalize crop rect with minimum size. Crop expansion outside the source image is allowed.
  private func constrainCropToImageBounds(_ rect: CGRect) -> CGRect {
    var constrained = rect.standardized

    // Enforce minimum size
    let minSize = minimumCropSize
    if constrained.width < minSize { constrained.size.width = minSize }
    if constrained.height < minSize { constrained.size.height = minSize }

    return constrained
  }

  // MARK: - Crop Edge Profile (border snapping / auto-crop)

  /// Clear the cached image-analysis profiles (crop borders, text lines).
  /// Called automatically via didSet whenever the effective source image
  /// changes (load / cutout / rotation / undo); the matching
  /// `prepare…IfNeeded()` recomputes on demand.
  private func invalidateImageAnalysisProfiles() {
    cancelOCRExtraction()
    cropEdgeProfile = nil
    cropEdgeProfileImageID = nil
    textLineProfile = nil
    textLineProfileImageID = nil
    // The highlighter can already be active when the image arrives (remembered
    // tool, rotation, cutout), and the tool didSet has no second chance to run.
    if selectedTool == .highlighter {
      prepareTextLineProfileIfNeeded()
    }
    releaseMeasureMapper()
    if selectedTool == .measure {
      prepareMeasureMapperIfNeeded()
    }
  }

  // MARK: - Measure

  /// Builds the Measure raster for the current effective image unless it is built or building.
  func prepareMeasureMapperIfNeeded() {
    guard hasImage,
          let image = effectiveSourceImage,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let imageID = ObjectIdentifier(image)
    guard measureMapperImageID != imageID else { return }
    measureMapperTask?.cancel()
    measureMapper = nil
    measureMapperImageID = imageID
    let imageSize = image.size
    measureMapperTask = Task { [weak self] in
      let mapper = await Task.detached(priority: .userInitiated) {
        MeasureRaster(image: cgImage).flatMap { AnnotateMeasureMapper(raster: $0, imageSize: imageSize) }
      }.value
      guard !Task.isCancelled, let self, self.measureMapperImageID == imageID,
            self.effectiveSourceImage.map({ ObjectIdentifier($0) }) == imageID else { return }
      self.measureMapper = mapper
      if mapper == nil {
        self.measureMapperImageID = nil
      }
    }
  }

  func releaseMeasureMapper() {
    measureMapperTask?.cancel()
    measureMapperTask = nil
    measureMapper = nil
    measureMapperImageID = nil
  }

  /// Changes the unit for new measurements, and for the selected measurements as one undo step.
  func setMeasureUnit(_ unit: MeasureUnit) {
    measureUnit = unit
    defaults.set(unit.rawValue, forKey: PreferencesKeys.annotateMeasureUnit)
    let targets = selectedAnnotationIds
    let indices = annotations.indices.filter { index in
      guard targets.contains(annotations[index].id),
            case .measurement(let geometry) = annotations[index].type else { return false }
      return geometry.unit != unit
    }
    guard !indices.isEmpty else { return }
    saveState()
    for index in indices {
      guard case .measurement(var geometry) = annotations[index].type else { continue }
      geometry.unit = unit
      annotations[index].type = .measurement(geometry)
    }
    hasUnsavedChanges = true
  }

  /// Adds a finished measurement as one undo step and selects it.
  @discardableResult
  func addMeasurement(geometry: MeasureGeometry, bounds: CGRect) -> AnnotationItem {
    let item = AnnotationItem(
      type: .measurement(geometry),
      bounds: bounds,
      properties: annotationCreationProperties(for: .measure)
    )
    saveState()
    annotations.append(item)
    hasUnsavedChanges = true
    return item
  }

  /// Kick off content-border detection for the current image unless a profile
  /// is already computed (or in flight) for it. The result lands in
  /// `cropEdgeProfile` and backs border snapping and auto-crop.
  func prepareCropEdgeProfileIfNeeded() {
    guard hasImage,
          let image = effectiveSourceImage,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let imageID = ObjectIdentifier(image)
    guard cropEdgeProfileImageID != imageID else { return }
    cropEdgeProfile = nil
    let imagePointSize = image.size
    Task { [weak self] in
      let profile = await Self.detectCropEdgeProfile(cgImage: cgImage, imagePointSize: imagePointSize)
      // Bail when the effective image changed mid-compute. The ID is set only
      // on a non-nil profile — on failure a later prepare retries this image.
      guard let self, let profile,
            self.effectiveSourceImage.map({ ObjectIdentifier($0) }) == imageID else { return }
      self.cropEdgeProfile = profile
      self.cropEdgeProfileImageID = imageID
      DiagnosticLogger.shared.log(.info, .annotate, "Crop edge profile computed", context: [
        "verticalEdges": "\(profile.verticalEdges.count)",
        "horizontalEdges": "\(profile.horizontalEdges.count)"
      ])
    }
  }

  // MARK: - Text Line Profile (highlighter text snapping)

  /// Kick off text-line detection for the current image unless a profile is
  /// already computed (or in flight) for it. The result lands in
  /// `textLineProfile` and backs highlighter text snapping. Called when the
  /// highlighter becomes the active tool, so images the user never highlights
  /// on never pay for a Vision pass.
  func prepareTextLineProfileIfNeeded() {
    guard isHighlighterTextSnappingEnabled,
          hasImage,
          let image = effectiveSourceImage,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let imageID = ObjectIdentifier(image)
    guard textLineProfileImageID != imageID else { return }
    textLineProfile = nil
    textLineProfileImageID = imageID
    let imagePointSize = image.size

    Task { [weak self] in
      let profile = await Task.detached(priority: .userInitiated) {
        AnnotateTextSnapDetector.detectLines(in: cgImage, imagePointSize: imagePointSize)
      }.value
      // Bail when the effective image changed mid-compute.
      guard let self,
            self.effectiveSourceImage.map({ ObjectIdentifier($0) }) == imageID,
            self.textLineProfileImageID == imageID else { return }
      self.textLineProfile = profile
      DiagnosticLogger.shared.log(.info, .annotate, "Text line profile computed", context: [
        "lines": "\(profile.lines.count)"
      ])
    }
  }

  /// Edge detection off the main actor; shared by
  /// `prepareCropEdgeProfileIfNeeded` and `autoCropToContent`.
  private nonisolated static func detectCropEdgeProfile(
    cgImage: CGImage,
    imagePointSize: CGSize
  ) async -> CropEdgeProfile? {
    await Task.detached(priority: .userInitiated) {
      CropContentAnalyzer.edgeProfile(for: cgImage, imagePointSize: imagePointSize)
    }.value
  }

  /// Auto-crop the active crop rect to the detected content (Shottr-style `A`
  /// shortcut). Tries deterministic edge-profile tightening first; on macOS 14+
  /// falls back to the Vision foreground-subject heuristic. Shows an info toast
  /// and leaves the rect untouched when neither finds content. Stays in crop
  /// mode and does not touch the undo stacks (Esc still restores).
  func autoCropToContent() async {
    guard isCropActive, hasImage, !isCropResizing,
          let image = effectiveSourceImage,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    if cropRect == nil {
      initializeCrop()
    }
    guard let selection = cropRect else { return }

    // Direct invocations (A key, tests) can race the prepare task kicked off in
    // beginCropInteraction; compute inline when no profile is ready yet.
    if cropEdgeProfile == nil {
      let profile = await Self.detectCropEdgeProfile(cgImage: cgImage, imagePointSize: image.size)
      // Bail when the effective image changed mid-compute — the stale profile
      // must not be applied. Set the ID only on a non-nil profile so a failure
      // does not block prepare from retrying this image.
      guard effectiveSourceImage.map({ ObjectIdentifier($0) }) == ObjectIdentifier(image) else { return }
      if let profile {
        cropEdgeProfile = profile
        cropEdgeProfileImageID = ObjectIdentifier(image)
      }
    }

    if let profile = cropEdgeProfile,
       let tightened = CropContentAnalyzer.contentBounds(in: selection, profile: profile) {
      DiagnosticLogger.shared.log(.info, .annotate, "Auto-crop to content (edge profile)", context: [
        "from": "\(selection)", "to": "\(tightened)"
      ])
      withAnimation(.easeInOut(duration: 0.15)) {
        updateCropRect(tightened)
      }
      return
    }

    if canUseBackgroundCutout,
       let tightened = await visionSuggestedAutoCropRect(in: selection, image: image, cgImage: cgImage) {
      // The Vision pass can take ~1s; bail when the image changed or the user
      // kept dragging meanwhile — don't clobber their current rect.
      guard effectiveSourceImage.map({ ObjectIdentifier($0) }) == ObjectIdentifier(image),
            let currentCropRect = cropRect,
            Self.rectApproximatelyEqual(currentCropRect, selection) else { return }
      DiagnosticLogger.shared.log(.info, .annotate, "Auto-crop to content (Vision fallback)", context: [
        "from": "\(selection)", "to": "\(tightened)"
      ])
      withAnimation(.easeInOut(duration: 0.15)) {
        updateCropRect(tightened)
      }
      return
    }

    AppToastManager.shared.show(message: L10n.AnnotateUI.autoCropNoContent, style: .info)
  }

  /// Vision fallback for auto-crop: run foreground-subject detection on the
  /// selected region and convert its suggested crop back to image points.
  /// Returns nil on any failure (caller falls through to the no-content toast).
  private func visionSuggestedAutoCropRect(
    in selection: CGRect,
    image: NSImage,
    cgImage: CGImage
  ) async -> CGRect? {
    let selection = selection.standardized
    let pointSize = image.size
    guard selection.width > 0, selection.height > 0,
          pointSize.width > 0, pointSize.height > 0 else { return nil }

    // Selection (image points, bottom-left) -> backing pixels (top-left);
    // inverse of convertAutoCropRectToImageCoordinates.
    let scaleX = CGFloat(cgImage.width) / pointSize.width
    let scaleY = CGFloat(cgImage.height) / pointSize.height
    let pixelRect = CGRect(
      x: selection.minX * scaleX,
      y: (pointSize.height - selection.maxY) * scaleY,
      width: selection.width * scaleX,
      height: selection.height * scaleY
    ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
          let subImage = cgImage.cropping(to: pixelRect) else { return nil }

    guard let result = try? await ForegroundCutoutService.shared.extractForegroundResult(from: subImage),
          result.autoCropDecision == .suggested,
          let suggestedPixelRect = result.suggestedAutoCropRect else { return nil }

    // The sub-image's rect in image points: exact inverse of the pixel mapping
    // above, so this stays correct even when the selection extended beyond the
    // image and got clamped (crop expansion outside the source is allowed).
    let subPointRect = CGRect(
      x: pixelRect.minX / scaleX,
      y: pointSize.height - pixelRect.maxY / scaleY,
      width: pixelRect.width / scaleX,
      height: pixelRect.height / scaleY
    )
    // Suggested rect (sub-image pixels, top-left) -> sub-image points
    // (bottom-left), then offset into the full image's point space.
    let converted = Self.convertAutoCropRectToImageCoordinates(
      pixelRectTopLeft: suggestedPixelRect,
      sourceImageSize: subPointRect.size,
      sourcePixelSize: CGSize(width: subImage.width, height: subImage.height)
    )
    let tightened = converted
      .offsetBy(dx: subPointRect.minX, dy: subPointRect.minY)
      .standardized
      .intersection(selection)
    // Same acceptance rules as CropContentAnalyzer.contentBounds: non-empty,
    // >= 20pt per side, and a >= 5% area reduction.
    guard !tightened.isNull,
          tightened.width >= 20,
          tightened.height >= 20 else { return nil }
    let areaReduction = 1 - (tightened.width * tightened.height) / (selection.width * selection.height)
    guard areaReduction >= 0.05 else { return nil }
    return tightened
  }

  // MARK: - Annotation Selection

  @discardableResult
  func copySelectedAnnotations() -> Bool {
    guard editingTextAnnotationId == nil else { return false }

    var copyableItems: [AnnotationItem] = []
    var embeddedDataByAssetId: [UUID: Data] = [:]
    for annotation in selectedAnnotations {
      if case .embeddedImage(let assetId) = annotation.type {
        guard let data = embeddedImageData(for: assetId) else { continue }
        embeddedDataByAssetId[assetId] = data
      }
      copyableItems.append(annotation)
    }
    guard !copyableItems.isEmpty else { return false }

    let payload = AnnotationClipboardPayload(
      items: copyableItems,
      embeddedImageData: embeddedDataByAssetId
    )
    annotationClipboardPayload = payload
    annotationPasteCount = 0
    let pasteboard = annotationPasteboard
    pasteboard.clearContents()
    if let data = try? JSONEncoder().encode(payload) {
      pasteboard.setData(data, forType: Self.annotationPasteboardType)
    }
    annotationClipboardChangeCount = pasteboard.changeCount
    return true
  }

  /// Объекты для вставки: внутренний буфер, пока системный не менялся, иначе тип
  /// com.ownshot.annotate из системного буфера (копия из другого окна). Картинка или
  /// строка в буфере – nil, их обрабатывает вставка изображения.
  private func currentAnnotationClipboardPayload() -> AnnotationClipboardPayload? {
    let pasteboard = annotationPasteboard
    if let annotationClipboardPayload, annotationClipboardChangeCount == pasteboard.changeCount {
      return annotationClipboardPayload
    }
    guard let data = pasteboard.data(forType: Self.annotationPasteboardType),
          let payload = try? JSONDecoder().decode(AnnotationClipboardPayload.self, from: data) else {
      return nil
    }
    if annotationClipboardChangeCount != pasteboard.changeCount {
      annotationPasteCount = 0
    }
    annotationClipboardPayload = payload
    annotationClipboardChangeCount = pasteboard.changeCount
    return payload
  }

  /// Последняя точка курсора над холстом. Вставка её больше не использует
  /// (эталон кладёт копию в центр холста), значение хранится для холста.
  func updateCanvasMouseLocation(_ point: CGPoint?) {
    canvasMouseLocation = point
  }

  @discardableResult
  func pasteAnnotationsFromClipboard() -> Bool {
    guard editingTextAnnotationId == nil,
          let payload = currentAnnotationClipboardPayload() else {
      return false
    }

    var sourceItems = payload.annotationItems
    guard !sourceItems.isEmpty else { return false }
    // Копия счётчика получает следующий номер последовательности (1, 2, 3 → 4), как у эталона.
    var nextCounter = nextCounterValue()
    for index in sourceItems.indices {
      guard case .counter = sourceItems[index].type else { continue }
      sourceItems[index].type = .counter(nextCounter)
      nextCounter += 1
    }

    let pasteIndex = annotationPasteCount + 1
    let proposedOffset = pasteOffset(for: sourceItems, pasteIndex: pasteIndex)
    let offset = clampedAnnotationOffset(
      for: sourceItems,
      proposedOffset: proposedOffset
    )
    let result = cloneAnnotations(
      sourceItems,
      offset: offset,
      embeddedImageData: payload.embeddedImageData
    )
    guard !result.annotations.isEmpty else { return false }

    annotationPasteCount = pasteIndex
    appendClonedAnnotations(result)
    return true
  }

  /// Эталон кладёт вставку в центр холста; повторная вставка сдвигается на шаг дублирования.
  private func pasteOffset(
    for annotations: [AnnotationItem],
    pasteIndex: Int
  ) -> CGSize {
    let repeatedOffset = CGSize(
      width: Self.annotationDuplicationOffset.width * CGFloat(max(pasteIndex - 1, 0)),
      height: Self.annotationDuplicationOffset.height * CGFloat(max(pasteIndex - 1, 0))
    )

    let selectionBounds = annotations
      .map(\.selectionBounds)
      .reduce(CGRect.null) { $0.union($1) }
    let canvasBounds = (isCombineMode ? effectiveContentBounds : activeAnnotationBounds).standardized
    guard !selectionBounds.isNull, !selectionBounds.isEmpty,
          !canvasBounds.isNull, !canvasBounds.isEmpty else {
      return repeatedOffset
    }

    return CGSize(
      width: canvasBounds.midX - selectionBounds.midX + repeatedOffset.width,
      height: canvasBounds.midY - selectionBounds.midY + repeatedOffset.height
    )
  }

  @discardableResult
  func duplicateSelectedAnnotations() -> Bool {
    guard editingTextAnnotationId == nil,
          !selectedAnnotations.isEmpty else { return false }

    let sourceItems = selectedAnnotations
    let sourceAssetData: [UUID: Data] = Dictionary(uniqueKeysWithValues: sourceItems.compactMap { annotation in
      guard case .embeddedImage(let assetId) = annotation.type,
            let data = embeddedImageData(for: assetId) else { return nil }
      return (assetId, data)
    })
    let offset = clampedAnnotationOffset(
      for: sourceItems,
      proposedOffset: Self.annotationDuplicationOffset
    )
    let result = cloneAnnotations(
      sourceItems,
      offset: offset,
      embeddedImageData: sourceAssetData
    )
    guard !result.annotations.isEmpty else { return false }

    appendClonedAnnotations(result)
    return true
  }

  /// Option-перетаскивание: копии ложатся туда, куда дотащили, оригиналы остаются
  /// на месте. Одна точка undo, выделяются копии.
  @discardableResult
  func duplicateAnnotations(ids: Set<UUID>, offset: CGSize) -> Bool {
    guard editingTextAnnotationId == nil, offset != .zero else { return false }
    let sourceItems = annotations.filter { ids.contains($0.id) }
    guard !sourceItems.isEmpty else { return false }
    let sourceAssetData: [UUID: Data] = Dictionary(uniqueKeysWithValues: sourceItems.compactMap { annotation in
      guard case .embeddedImage(let assetId) = annotation.type,
            let data = embeddedImageData(for: assetId) else { return nil }
      return (assetId, data)
    })
    let result = cloneAnnotations(sourceItems, offset: offset, embeddedImageData: sourceAssetData)
    guard !result.annotations.isEmpty else { return false }
    appendClonedAnnotations(result)
    return true
  }

  var selectedAnnotations: [AnnotationItem] {
    annotations.filter { selectedAnnotationIds.contains($0.id) }
  }

  var hasSelectedAnnotations: Bool {
    !selectedAnnotationIds.isEmpty
  }

  func isAnnotationSelected(_ id: UUID) -> Bool {
    selectedAnnotationIds.contains(id)
  }

  private func cloneAnnotations(
    _ sourceItems: [AnnotationItem],
    offset: CGSize,
    embeddedImageData: [UUID: Data]
  ) -> AnnotationCloneResult {
    var result = AnnotationCloneResult()

    for source in sourceItems {
      var clone = source.duplicatedBy(dx: offset.width, dy: offset.height)
      if autoSizingTextAnnotationIDs.contains(source.id) {
        result.autoSizingTextAnnotationIDs.insert(clone.id)
      }

      if case .embeddedImage(let sourceAssetId) = source.type {
        guard let data = embeddedImageData[sourceAssetId],
              let image = NSImage(data: data) else {
          continue
        }
        let clonedAssetId = UUID()
        clone.type = .embeddedImage(clonedAssetId)
        result.embeddedImageAssets[clonedAssetId] = image
        result.embeddedImageData[clonedAssetId] = data
      }

      result.annotations.append(clone)
    }

    return result
  }

  private func appendClonedAnnotations(_ result: AnnotationCloneResult) {
    saveState()

    embeddedImageAssets.merge(result.embeddedImageAssets) { _, new in new }
    embeddedImageSourceData.merge(result.embeddedImageData) { _, new in new }
    embeddedImageSnapshotCacheData.merge(result.embeddedImageData) { _, new in new }
    annotations.append(contentsOf: result.annotations)
    autoSizingTextAnnotationIDs.formUnion(result.autoSizingTextAnnotationIDs)

    if isCombineMode, combineMode == .freeCanvas {
      for annotation in result.annotations {
        if case .embeddedImage = annotation.type {
          freeCombineBoundsByAnnotationID[annotation.id] = annotation.bounds
        }
      }
    }

    refreshCombineLayout()
    selectedTool = .selection
    setSelectedAnnotationIds(Set(result.annotations.map(\.id)))
    editingTextAnnotationId = nil
    hasUnsavedChanges = true
    updateImportWarningIfNeeded()
  }

  private func embeddedImageData(for assetId: UUID) -> Data? {
    if let sourceData = embeddedImageSourceData[assetId] {
      return sourceData
    }
    if let cachedData = embeddedImageSnapshotCacheData[assetId] {
      return cachedData
    }
    guard let image = embeddedImageAssets[assetId] else { return nil }
    if let tiffData = image.tiffRepresentation {
      embeddedImageSnapshotCacheData[assetId] = tiffData
      return tiffData
    }
    guard let pngData = Self.pngData(from: image) else { return nil }
    embeddedImageSnapshotCacheData[assetId] = pngData
    return pngData
  }

  private func clampedAnnotationOffset(
    for annotations: [AnnotationItem],
    proposedOffset: CGSize
  ) -> CGSize {
    guard !annotations.isEmpty else { return .zero }
    if expandsCanvasBeyondImage && cropRect == nil && !isCombineMode { return proposedOffset }
    let canvasBounds = (isCombineMode ? effectiveContentBounds : activeAnnotationBounds).standardized
    let selectionBounds = annotations
      .map(\.selectionBounds)
      .reduce(CGRect.null) { $0.union($1) }
    guard !canvasBounds.isEmpty, !selectionBounds.isNull, !selectionBounds.isEmpty else {
      return proposedOffset
    }

    let minimumDX = canvasBounds.minX - selectionBounds.minX
    let maximumDX = canvasBounds.maxX - selectionBounds.maxX
    let minimumDY = canvasBounds.minY - selectionBounds.minY
    let maximumDY = canvasBounds.maxY - selectionBounds.maxY
    let dx = minimumDX <= maximumDX
      ? min(max(proposedOffset.width, minimumDX), maximumDX)
      : 0
    let dy = minimumDY <= maximumDY
      ? min(max(proposedOffset.height, minimumDY), maximumDY)
      : 0
    return CGSize(width: dx, height: dy)
  }

  func selectAnnotation(at point: CGPoint) -> AnnotationItem? {
    // Find annotation at point (in reverse render order to select topmost)
    for annotation in annotations.renderOrdered.reversed() {
      // Quick bounds check first (optimization)
      let expandedBounds = annotation.selectionBounds.insetBy(dx: -10, dy: -10)
      guard expandedBounds.contains(point) else { continue }

      // Precise hit test
      if annotation.containsPoint(point) {
        setSelectedAnnotationIds([annotation.id])
        return annotation
      }
    }
    deselectAnnotation()
    return nil
  }

  @discardableResult
  func selectAnnotations(in rect: CGRect) -> [AnnotationItem] {
    let selectionRect = rect.standardized
    guard selectionRect.width > 0, selectionRect.height > 0 else {
      deselectAnnotation()
      return []
    }

    let selected = annotations.filter { annotation in
      let annotationBounds = annotation.selectionBounds
      return selectionRect.intersects(annotationBounds)
        || selectionRect.contains(annotationBounds)
    }
    setSelectedAnnotationIds(Set(selected.map(\.id)))
    return selected
  }

  /// ⌘A: выделяет все аннотации и переключает на Selection, чтобы их можно было
  /// двигать вместе. В Crop, Cut Out и вне режима Annotate ничего не делает.
  @discardableResult
  func selectAllAnnotations() -> Bool {
    guard editorMode == .annotate, !annotations.isEmpty,
          selectedTool != .crop, selectedTool != .cutOut,
          editingTextAnnotationId == nil else { return false }
    if selectedTool != .selection {
      activateTool(.selection)
    }
    setSelectedAnnotationIds(Set(annotations.map(\.id)))
    return true
  }

  func setSelectedAnnotationIds(_ ids: Set<UUID>) {
    let validIds = Set(annotations.map(\.id))
    let filteredIds = ids.intersection(validIds)
    let primaryId = filteredIds.count == 1 ? filteredIds.first : nil

    isSynchronizingSelection = true
    selectedAnnotationIds = filteredIds
    selectedAnnotationId = primaryId
    isSynchronizingSelection = false
  }

  func updateAnnotationBounds(id: UUID, bounds: CGRect) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }

    let oldBounds = annotations[index].resizeBounds
    let normalizedBounds = bounds.standardized
    annotations[index] = annotations[index].applyingResizeBounds(normalizedBounds)

    if case .text = annotations[index].type,
       abs(oldBounds.width - normalizedBounds.width) > 0.5 {
      autoSizingTextAnnotationIDs.remove(id)
    }

    if isCombineMode, combineMode == .freeCanvas,
       case .embeddedImage = annotations[index].type {
      freeCombineBoundsByAnnotationID[id] = annotations[index].bounds
      updateCombineContentBounds()
    }
  }

  /// Итог жеста ручек текста (ANN-801): ширина с переносом строк или кегль.
  /// Шаг undo холст записал в начале жеста, здесь итог только переносится в модель.
  func commitTextHandleResize(id: UUID, resized: AnnotationItem) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text = annotations[index].type,
          case .text = resized.type else { return }

    annotations[index].bounds = resized.bounds
    annotations[index].properties.fontSize = resized.properties.fontSize
    annotations[index].properties.calloutTailTarget = resized.properties.calloutTailTarget
    // Ширину задал пользователь: дальше ввод переносит строки, а не растягивает рамку.
    autoSizingTextAnnotationIDs.remove(id)
    hasUnsavedChanges = true
  }

  func updateLineEndpoint(id: UUID, start newStart: CGPoint? = nil, end newEnd: CGPoint? = nil) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .line(let start, let end) = annotations[index].type else { return }

    let updatedStart = newStart ?? start
    let updatedEnd = newEnd ?? end
    annotations[index].type = .line(start: updatedStart, end: updatedEnd)
    annotations[index].bounds = CGRect(
      x: min(updatedStart.x, updatedEnd.x),
      y: min(updatedStart.y, updatedEnd.y),
      width: abs(updatedEnd.x - updatedStart.x),
      height: abs(updatedEnd.y - updatedStart.y)
    ).standardized
  }

  /// Move an arrow's start/end endpoint (Figma-style line editing).
  /// Style, display type, and heads are preserved. Ручка изгиба сдвигается
  /// на половину смещения конца, с Shift встаёт в середину нового отрезка.
  func updateArrowEndpoint(
    id: UUID,
    start newStart: CGPoint? = nil,
    end newEnd: CGPoint? = nil,
    shiftHeld: Bool = false
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updatedStart = newStart ?? geometry.start
    let updatedEnd = newEnd ?? geometry.end
    let updated = geometry.withEndpoints(start: updatedStart, end: updatedEnd, shiftHeld: shiftHeld)
    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  /// Фиксирует итог перетаскивания конца стрелки. Холст считает ручку изгиба
  /// по шагам жеста (Shift можно нажать и отпустить посреди жеста), поэтому
  /// в модель уходит готовая геометрия, а не пересчёт от исходной.
  func commitArrowGeometry(id: UUID, geometry: ArrowGeometry) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let current) = annotations[index].type,
          current != geometry else { return }

    annotations[index].type = .arrow(geometry)
    annotations[index].bounds = geometry.bounds()
    hasUnsavedChanges = true
  }

  /// Move a curved arrow's quadratic Bezier control point.
  /// The canvas clamps the requested point to its active drawing bounds before
  /// calling this method; the model keeps the point and synchronizes the
  /// curved style with its actual side of the endpoint chord. Ближе 8 единиц
  /// к отрезку ручка прилипает к его середине, стрелка становится прямой.
  func updateArrowControlPoint(id: UUID, controlPoint: CGPoint) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type,
          geometry.style != .straight else { return }

    let updated = geometry.withControlPoint(controlPoint)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateAnnotationText(id: UUID, text: String) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text(let currentText) = annotations[index].type else { return }

    let currentBounds = annotations[index].bounds
    let newBounds = resizedTextBounds(
      id: id,
      text: text,
      properties: annotations[index].properties,
      currentBounds: currentBounds
    )

    let textChanged = currentText != text
    let boundsChanged = annotations[index].bounds != newBounds
    guard textChanged || boundsChanged else { return }

    if textChanged {
      recordTextEditingUndoIfNeeded(id: id, newText: text)
      annotations[index].type = .text(text)
    }
    annotations[index].bounds = newBounds
    if annotations[index].properties.textPresentation == .callout,
       let tailTarget = annotations[index].properties.calloutTailTarget,
       TextBubbleGeometry.isDefaultTail(tailTarget, for: currentBounds, fontSize: annotations[index].properties.fontSize) {
      annotations[index].properties.calloutTailTarget = defaultCalloutTailTarget(for: newBounds, fontSize: annotations[index].properties.fontSize)
    }
    hasUnsavedChanges = true
  }

  func updateWatermarkText(id: UUID, text: String) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .watermark = annotations[index].type else { return }

    annotations[index].type = .watermark(text)
  }

  func updateArrowStyle(id: UUID, style: ArrowStyle) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withStyle(style)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowType(id: UUID, arrowType: ArrowType) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withArrowType(arrowType)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowBendDirection(id: UUID, bendDirection: ArrowBendDirection) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type,
          geometry.style.supportsBendDirection else { return }

    let updated = geometry.withBendDirection(bendDirection)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowStartHead(id: UUID, head: ArrowEndpointStyle) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withStartHead(head)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowEndHead(id: UUID, head: ArrowEndpointStyle) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withEndHead(head)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateBlurType(id: UUID, blurType: BlurType) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .blur = annotations[index].type else { return }

    annotations[index].type = .blur(blurType)
  }

  /// Update annotation properties (strokeWidth, fontSize, colors)
  func updateAnnotationProperties(
    id: UUID,
    strokeWidth: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    strokeColor: Color? = nil,
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    opacity: CGFloat? = nil,
    rotationDegrees: CGFloat? = nil,
    watermarkStyle: WatermarkStyle? = nil,
    spotlightOpacity: CGFloat? = nil,
    lineStyle: LineDashStyle? = nil,
    recordsUndo: Bool = false
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    let colorUpdate = normalizedColorUpdate(
      for: annotations[index],
      strokeColor: strokeColor,
      fillColor: fillColor
    )

    // Re-selecting the current fill still matters for plain text: the
    // promotion below is what makes the fill visible, so an equal fill value
    // does not mean this update is a no-op.
    let fillPromotesTextPresentation: Bool = {
      guard let fillColor = colorUpdate.fillColor,
            fillColor != .clear,
            case .text = annotations[index].type,
            annotations[index].properties.textPresentation == .plain else {
        return false
      }
      return true
    }()

    guard annotationPropertiesWillChange(
      annotations[index],
      strokeWidth: strokeWidth,
      fontSize: fontSize,
      strokeColor: colorUpdate.strokeColor,
      fillColor: colorUpdate.fillColor,
      cornerRadius: cornerRadius,
      opacity: opacity,
      rotationDegrees: rotationDegrees,
      watermarkStyle: watermarkStyle,
      spotlightOpacity: spotlightOpacity,
      lineStyle: lineStyle
    ) || fillPromotesTextPresentation else { return }

    if recordsUndo {
      if let snapshot = propertySliderGestureUndoSnapshot {
        pushUndoSnapshot(snapshot, annotationCount: snapshot.annotations.count)
        propertySliderGestureUndoSnapshot = nil
      } else if !isPropertySliderGestureEditing {
        saveState()
      }
    }

    let oldSelectionBounds = annotations[index].selectionBounds
    isApplyingPropertyEdit = true
    defer { isApplyingPropertyEdit = false }

    if let strokeWidth = strokeWidth {
      let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
      annotations[index].properties.strokeWidth = clampedWidth
      if case .counter = annotations[index].type {
        let center = CGPoint(x: annotations[index].bounds.midX, y: annotations[index].bounds.midY)
        annotations[index].bounds = counterBounds(center: center, controlValue: clampedWidth)
      }
    }
    if let fontSize = fontSize {
      annotations[index].properties.fontSize = fontSize
      // Recalculate bounds for new font size
      if case .text(let content) = annotations[index].type {
        let currentBounds = annotations[index].bounds
        let properties = annotations[index].properties
        annotations[index].bounds = resizedTextBounds(
          id: id,
          text: content,
          properties: properties,
          currentBounds: currentBounds
        )
      }
    }
    if let strokeColor = colorUpdate.strokeColor {
      annotations[index].properties.strokeColor = strokeColor
    }
    if let fillColor = colorUpdate.fillColor {
      annotations[index].properties.fillColor = fillColor
      // The background fill only renders for label/callout presentations, so a
      // colored fill on plain text would stay invisible. Promote it to a label.
      if case .text = annotations[index].type,
         fillColor != .clear,
         annotations[index].properties.textPresentation == .plain {
        annotations[index].properties.textPresentation = .label
      }
    }
    if let cornerRadius = cornerRadius {
      annotations[index].properties.cornerRadius = max(0, cornerRadius)
    }
    if let opacity = opacity {
      annotations[index].properties.opacity = AnnotationProperties.clampedOpacity(opacity)
    }
    if let rotationDegrees = rotationDegrees {
      annotations[index].properties.rotationDegrees = AnnotationProperties.clampedRotationDegrees(rotationDegrees)
    }
    if let watermarkStyle = watermarkStyle {
      annotations[index].properties.watermarkStyle = watermarkStyle
    }
    if let spotlightOpacity = spotlightOpacity {
      annotations[index].properties.spotlightOpacity = AnnotationProperties.clampedSpotlightOpacity(spotlightOpacity)
    }
    if let lineStyle = lineStyle {
      annotations[index].properties.lineStyle = lineStyle
    }

    // Spotlight dimming paints the full canvas — its opacity edits need a full
    // redraw; everything else is scoped to the edited annotation's bounds.
    if spotlightOpacity != nil {
      pendingFullCanvasInvalidation = true
    } else {
      pendingPropertyEditRects.append(oldSelectionBounds.union(annotations[index].selectionBounds))
    }
    hasUnsavedChanges = true
  }

  func updateAnnotationPrimaryColor(
    id: UUID,
    color: Color,
    recordsUndo: Bool = false
  ) {
    let isSpotlight = annotations.first(where: { $0.id == id })?.type.toolType == .spotlight
    updateAnnotationProperties(
      id: id,
      strokeColor: color,
      recordsUndo: recordsUndo
    )
    if isSpotlight {
      updateDefaultAnnotationProperties(for: .spotlight, strokeColor: color)
      if !isTransparentColor(color), isQuickPropertiesSyncEnabled {
        rememberSharedAnnotationColor(color)
      }
    } else if isQuickPropertiesSyncEnabled {
      rememberSharedAnnotationColor(color)
    }
  }

  private func normalizedColorUpdate(
    for annotation: AnnotationItem,
    strokeColor: Color?,
    fillColor: Color?
  ) -> (strokeColor: Color?, fillColor: Color?) {
    if case .filledRectangle = annotation.type,
       let color = strokeColor ?? fillColor {
      return (color, color)
    }

    return (strokeColor, fillColor)
  }

  private func annotationPropertiesWillChange(
    _ annotation: AnnotationItem,
    strokeWidth: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    strokeColor: Color? = nil,
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    opacity: CGFloat? = nil,
    rotationDegrees: CGFloat? = nil,
    watermarkStyle: WatermarkStyle? = nil,
    spotlightOpacity: CGFloat? = nil,
    lineStyle: LineDashStyle? = nil
  ) -> Bool {
    let properties = annotation.properties
    let colorUpdate = normalizedColorUpdate(
      for: annotation,
      strokeColor: strokeColor,
      fillColor: fillColor
    )

    if let strokeWidth,
       properties.strokeWidth != AnnotationProperties.clampedControlValue(strokeWidth) {
      return true
    }
    if let fontSize,
       properties.fontSize != fontSize {
      return true
    }
    if let strokeColor = colorUpdate.strokeColor,
       properties.strokeColor != strokeColor {
      return true
    }
    if let fillColor = colorUpdate.fillColor,
       properties.fillColor != fillColor {
      return true
    }
    if let cornerRadius,
       properties.cornerRadius != max(0, cornerRadius) {
      return true
    }
    if let opacity,
       properties.opacity != AnnotationProperties.clampedOpacity(opacity) {
      return true
    }
    if let rotationDegrees,
       properties.rotationDegrees != AnnotationProperties.clampedRotationDegrees(rotationDegrees) {
      return true
    }
    if let watermarkStyle,
       properties.watermarkStyle != watermarkStyle {
      return true
    }
    if let spotlightOpacity,
       properties.spotlightOpacity != AnnotationProperties.clampedSpotlightOpacity(spotlightOpacity) {
      return true
    }
    if let lineStyle,
       properties.lineStyle != lineStyle {
      return true
    }
    return false
  }

  /// Calculate text bounds based on content and font size with word wrapping
  /// - Parameters:
  ///   - text: The text content
  ///   - fontSize: Desired font size (will be clamped to 8-144pt range)
  ///   - origin: Origin point for the text bounds
  ///   - constrainedWidth: Width to constrain text wrapping to (nil = auto-width from content)
  /// - Returns: Bounded CGRect with enforced maximum dimensions
  private func calculateTextBounds(
    text: String,
    fontSize: CGFloat,
    origin: CGPoint,
    fontName: String? = nil,
    textStyle: AnnotationTextStyle = .standard,
    constrainedWidth: CGFloat? = nil,
    maximumHeight: CGFloat = AnnotateTextLayout.maxHeight,
    presentation: TextPresentation = .plain
  ) -> CGRect {
    AnnotateTextLayout.bounds(
      text: text,
      font: AnnotateTextLayout.font(size: fontSize, fontName: fontName, textStyle: textStyle),
      origin: origin,
      constrainedWidth: constrainedWidth,
      maximumHeight: maximumHeight,
      presentation: presentation
    )
  }

  private func resizedTextBounds(
    id: UUID,
    text: String,
    properties: AnnotationProperties,
    currentBounds: CGRect
  ) -> CGRect {
    let font = AnnotateTextLayout.font(
      size: properties.fontSize,
      fontName: properties.fontName,
      textStyle: properties.textStyle
    )
    let annotationBounds = activeAnnotationBounds.standardized
    let topY = currentBounds.maxY
    let availableWidth = max(annotationBounds.maxX - currentBounds.minX, AnnotateTextLayout.minWidth)
    let availableHeight = max(topY - annotationBounds.minY, AnnotateTextLayout.minimumHeight(for: font, presentation: properties.textPresentation))
    let targetWidth: CGFloat
    if autoSizingTextAnnotationIDs.contains(id) {
      targetWidth = AnnotateTextLayout.preferredAutoWidth(
        text: text,
        font: font,
        // Новая рамка эталона не уже 100 pt и растёт только под длинный текст (ANN-043).
        minimumWidth: min(AnnotateTextFrameGeometry.newTextWidth, availableWidth),
        maximumWidth: availableWidth,
        presentation: properties.textPresentation
      )
    } else {
      targetWidth = AnnotateTextLayout.clampedWidth(
        currentBounds.width,
        maximumWidth: availableWidth
      )
    }

    var bounds = calculateTextBounds(
      text: text,
      fontSize: properties.fontSize,
      origin: currentBounds.origin,
      fontName: properties.fontName,
      textStyle: properties.textStyle,
      constrainedWidth: targetWidth,
      maximumHeight: availableHeight,
      presentation: properties.textPresentation
    )
    bounds.origin.y = topY - bounds.height
    return bounds
  }

  /// Get selected annotation if it's a text type
  var selectedTextAnnotation: AnnotationItem? {
    guard let annotation = selectedAnnotation,
          case .text = annotation.type else {
      return nil
    }
    return annotation
  }

  /// Get selected annotation (any type)
  var selectedAnnotation: AnnotationItem? {
    guard selectedAnnotationIds.count == 1,
          let id = selectedAnnotationIds.first else { return nil }
    return annotations.first { $0.id == id }
  }

  var selectedArrowAnnotation: AnnotationItem? {
    guard let annotation = selectedAnnotation,
          case .arrow = annotation.type else {
      return nil
    }
    return annotation
  }

  private var selectedArrowAnnotations: [AnnotationItem] {
    selectedAnnotations.filter { annotation in
      if case .arrow = annotation.type { return true }
      return false
    }
  }

  private var selectedBlurAnnotations: [AnnotationItem] {
    selectedAnnotations.filter { annotation in
      if case .blur = annotation.type { return true }
      return false
    }
  }

  private var selectedWatermarkAnnotations: [AnnotationItem] {
    selectedAnnotations.filter { annotation in
      if case .watermark = annotation.type { return true }
      return false
    }
  }

  var activeArrowStyle: ArrowStyle {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.style
    }
    return arrowStyle
  }

  var activeArrowPreset: AnnotateArrowPreset {
    if activeArrowType == .tapered { return .fancy }
    if activeArrowStyle != .straight {
      return activeArrowStartHead == .arrow ? .double : .curved
    }
    return .standard
  }

  func setArrowPreset(_ preset: AnnotateArrowPreset) {
    let arrows = selectedArrowAnnotations
    let changed = arrows.contains { annotation in
      guard case .arrow(let geometry) = annotation.type else { return false }
      return geometry.style != preset.style || geometry.arrowType != preset.arrowType
        || geometry.startHead != preset.startHead || geometry.endHead != .arrow
    }
    if changed { saveState() }
    arrowStyle = preset.style
    arrowType = preset.arrowType
    arrowStartHead = preset.startHead
    arrowEndHead = .arrow
    sharedAnnotationParameterDefaults.arrowStyle = arrowStyle.rawValue
    sharedAnnotationParameterDefaults.arrowType = arrowType.rawValue
    sharedAnnotationParameterDefaults.arrowStartHead = arrowStartHead.rawValue
    sharedAnnotationParameterDefaults.arrowEndHead = arrowEndHead.rawValue
    persistSharedAnnotationParameterDefaults()
    for annotation in arrows {
      updateArrowStyle(id: annotation.id, style: preset.style)
      updateArrowType(id: annotation.id, arrowType: preset.arrowType)
      updateArrowStartHead(id: annotation.id, head: preset.startHead)
      updateArrowEndHead(id: annotation.id, head: .arrow)
    }
  }

  func setActiveArrowStyle(_ style: ArrowStyle) {
    arrowStyle = style
    sharedAnnotationParameterDefaults.arrowStyle = style.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.style != style
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowStyle(id: $0.id, style: style) }
    } else {
      arrowStyle = style
    }
  }

  var activeArrowType: ArrowType {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.arrowType
    }
    return arrowType
  }

  func setActiveArrowType(_ type: ArrowType) {
    arrowType = type
    sharedAnnotationParameterDefaults.arrowType = type.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.arrowType != type
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowType(id: $0.id, arrowType: type) }
    } else {
      arrowType = type
    }
  }

  var activeArrowBendDirection: ArrowBendDirection {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.bendDirection
    }
    return arrowBendDirection
  }

  func setActiveArrowBendDirection(_ bendDirection: ArrowBendDirection) {
    arrowBendDirection = bendDirection
    sharedAnnotationParameterDefaults.arrowBendDirection = bendDirection.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.style.supportsBendDirection && geometry.bendDirection != bendDirection
      }) {
        saveState()
      }
      arrowAnnotations.forEach {
        updateArrowBendDirection(id: $0.id, bendDirection: bendDirection)
      }
    } else {
      arrowBendDirection = bendDirection
    }
  }

  var activeArrowStartHead: ArrowEndpointStyle {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.startHead
    }
    return arrowStartHead
  }

  func setActiveArrowStartHead(_ head: ArrowEndpointStyle) {
    arrowStartHead = head
    sharedAnnotationParameterDefaults.arrowStartHead = head.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.startHead != head
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowStartHead(id: $0.id, head: head) }
    }
  }

  var activeArrowEndHead: ArrowEndpointStyle {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.endHead
    }
    return arrowEndHead
  }

  func setActiveArrowEndHead(_ head: ArrowEndpointStyle) {
    arrowEndHead = head
    sharedAnnotationParameterDefaults.arrowEndHead = head.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.endHead != head
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowEndHead(id: $0.id, head: head) }
    }
  }

  var activeBlurType: BlurType {
    if let annotation = selectedBlurAnnotations.first,
       case .blur(let type) = annotation.type {
      return type
    }
    return blurType
  }

  func setActiveBlurType(_ type: BlurType) {
    let blurAnnotations = selectedBlurAnnotations
    if !blurAnnotations.isEmpty {
      guard blurAnnotations.contains(where: { $0.type != .blur(type) }) else { return }
      saveState()
      blurAnnotations.forEach { annotation in
        if Self.blurTypeStartsAtStrength10(type), annotation.type != .blur(type) {
          updateAnnotationProperties(id: annotation.id,
            strokeWidth: AnnotationProperties.secureBlurControlValue(for: 10))
        }
        updateBlurType(id: annotation.id, blurType: type)
      }
      hasUnsavedChanges = true
    } else {
      if Self.blurTypeStartsAtStrength10(type), blurType != type {
        rememberAnnotationStrokeWidth(AnnotationProperties.secureBlurControlValue(for: 10), for: .blur)
      }
      blurType = type
    }
    rememberRedactionStyle(type)
  }

  /// Blur (secure) и Blur (smooth) у эталона – слайдер 3…30, новая маска начинает с силы 10 (ANN-109).
  static func blurTypeStartsAtStrength10(_ type: BlurType) -> Bool {
    type == .secure || type == .gaussian
  }

  /// Стиль Redaction переживает перезапуск, как annotateLastPixelateStyle эталона.
  private func rememberRedactionStyle(_ type: BlurType) {
    guard sharedAnnotationParameterDefaults.blurType != type.rawValue else { return }
    sharedAnnotationParameterDefaults.blurType = type.rawValue
    persistSharedAnnotationParameterDefaults()
  }

  var activeWatermarkStyle: WatermarkStyle {
    selectedWatermarkAnnotations.first?.properties.watermarkStyle
      ?? defaultAnnotationProperties(for: .watermark).watermarkStyle
  }

  func setActiveWatermarkStyle(_ style: WatermarkStyle) {
    let rotationDegrees = style.defaultRotationDegrees
    let watermarkAnnotations = selectedWatermarkAnnotations
    if !watermarkAnnotations.isEmpty {
      watermarkAnnotations.forEach {
        updateAnnotationProperties(
          id: $0.id,
          rotationDegrees: rotationDegrees,
          watermarkStyle: style
        )
      }
    } else {
      updateDefaultAnnotationProperties(
        for: .watermark,
        rotationDegrees: rotationDegrees,
        watermarkStyle: style
      )
    }
  }

  private func loadSharedAnnotationColor() {
    guard let data = defaults.data(forKey: PreferencesKeys.annotatePrimaryColor),
          let rgba = try? JSONDecoder().decode(RGBAColor.self, from: data) else {
      return
    }
    sharedAnnotationColor = rgba.color
    strokeColor = rgba.color
  }

  private func rememberSharedAnnotationColor(_ color: Color) {
    guard let rgba = RGBAColor(color: color),
          let data = try? JSONEncoder().encode(rgba) else {
      return
    }

    sharedAnnotationColor = color
    defaults.set(data, forKey: PreferencesKeys.annotatePrimaryColor)
    applySharedAnnotationColorToToolDefaults(color)
  }

  private func isTransparentColor(_ color: Color) -> Bool {
    guard let rgba = RGBAColor(color: color) else {
      return color == .clear
    }
    return rgba.alpha <= 0.001
  }

  private func loadSharedAnnotationParameterDefaults() {
    guard let data = defaults.data(forKey: PreferencesKeys.annotateParameterDefaults),
          let decoded = try? JSONDecoder().decode(SharedAnnotationParameterDefaults.self, from: data)
    else { return }

    sharedAnnotationParameterDefaults = sanitizedSharedAnnotationParameterDefaults(decoded)

    if let savedBlurRaw = sharedAnnotationParameterDefaults.blurType,
       let savedBlur = BlurType(rawValue: savedBlurRaw),
       BlurType.redactionTypes.contains(savedBlur) {
      blurType = savedBlur
    }

    if let savedStyleRaw = sharedAnnotationParameterDefaults.arrowStyle,
       let savedStyle = ArrowStyle(rawValue: savedStyleRaw) {
      arrowStyle = savedStyle
    }
    if let savedTypeRaw = sharedAnnotationParameterDefaults.arrowType,
       let savedType = ArrowType(rawValue: savedTypeRaw) {
      arrowType = savedType
    }
    if let savedBendRaw = sharedAnnotationParameterDefaults.arrowBendDirection,
       let savedBend = ArrowBendDirection(rawValue: savedBendRaw) {
      arrowBendDirection = savedBend
    }
    if let savedStartHeadRaw = sharedAnnotationParameterDefaults.arrowStartHead,
       let savedStartHead = ArrowEndpointStyle(rawValue: savedStartHeadRaw) {
      arrowStartHead = savedStartHead
    }
    if let savedEndHeadRaw = sharedAnnotationParameterDefaults.arrowEndHead,
       let savedEndHead = ArrowEndpointStyle(rawValue: savedEndHeadRaw) {
      arrowEndHead = savedEndHead
    }
  }

  private func persistSharedAnnotationParameterDefaults() {
    guard let data = try? JSONEncoder().encode(sharedAnnotationParameterDefaults) else { return }
    defaults.set(data, forKey: PreferencesKeys.annotateParameterDefaults)
  }

  private func sanitizedSharedAnnotationParameterDefaults(
    _ defaults: SharedAnnotationParameterDefaults
  ) -> SharedAnnotationParameterDefaults {
    SharedAnnotationParameterDefaults(
      strokeWidth: defaults.strokeWidth.map(AnnotationProperties.clampedControlValue(_:)),
      cornerRadius: defaults.cornerRadius.map { max(0, $0) },
      fontSize: defaults.fontSize.map { AnnotationProperties.clampedFontSize($0) },
      watermarkOpacity: defaults.watermarkOpacity.map(AnnotationProperties.clampedOpacity(_:)),
      watermarkRotationDegrees: defaults.watermarkRotationDegrees.map(AnnotationProperties.clampedRotationDegrees(_:)),
      spotlightCornerRadius: defaults.spotlightCornerRadius.map { max(0, $0) },
      arrowStyle: defaults.arrowStyle,
      arrowType: defaults.arrowType,
      arrowBendDirection: defaults.arrowBendDirection,
      arrowStartHead: defaults.arrowStartHead,
      arrowEndHead: defaults.arrowEndHead,
      lineStyle: defaults.lineStyle,
      blurType: defaults.blurType
    )
  }

  private func loadAnnotationToolProperties() {
    guard let data = defaults.data(forKey: PreferencesKeys.annotateToolParameterDefaults),
          let decoded = try? JSONDecoder().decode([String: PersistedAnnotationProperties].self, from: data)
    else { return }

    annotationToolProperties = decoded.reduce(into: [:]) { result, entry in
      guard let tool = AnnotationToolType(rawValue: entry.key) else { return }
      result[tool] = sanitizedAnnotationProperties(entry.value.annotationProperties, for: tool)
    }
  }

  private func persistAnnotationToolProperties() {
    let payload = annotationToolProperties.reduce(into: [String: PersistedAnnotationProperties]()) { result, entry in
      guard let persisted = PersistedAnnotationProperties(entry.value) else { return }
      result[entry.key.rawValue] = persisted
    }

    guard let data = try? JSONEncoder().encode(payload) else { return }
    defaults.set(data, forKey: PreferencesKeys.annotateToolParameterDefaults)
  }

  private func sanitizedAnnotationProperties(
    _ properties: AnnotationProperties,
    for tool: AnnotationToolType
  ) -> AnnotationProperties {
    var sanitized = properties
    sanitized.strokeWidth = AnnotationProperties.clampedControlValue(properties.strokeWidth)
    sanitized.cornerRadius = max(0, properties.cornerRadius)
    sanitized.fontSize = AnnotationProperties.clampedFontSize(properties.fontSize)
    sanitized.opacity = AnnotationProperties.clampedOpacity(properties.opacity)
    sanitized.rotationDegrees = AnnotationProperties.clampedRotationDegrees(properties.rotationDegrees)
    sanitized.spotlightOpacity = AnnotationProperties.clampedSpotlightOpacity(properties.spotlightOpacity)
    if tool == .filledRectangle {
      sanitized.fillColor = sanitized.strokeColor
    }
    return sanitized
  }

  private func rememberSharedAnnotationStrokeWidth(_ strokeWidth: CGFloat) {
    let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    sharedAnnotationParameterDefaults.strokeWidth = clampedWidth
    persistSharedAnnotationParameterDefaults()

    for tool in AnnotationToolType.allCases where tool.supportsQuickStrokeWidth {
      updateDefaultAnnotationProperties(for: tool, strokeWidth: clampedWidth)
    }

    if !selectedTool.supportsQuickPropertiesBar {
      self.strokeWidth = clampedWidth
    }
  }

  private func rememberSharedAnnotationCornerRadius(_ cornerRadius: CGFloat) {
    let clampedRadius = max(0, cornerRadius)
    sharedAnnotationParameterDefaults.cornerRadius = clampedRadius
    persistSharedAnnotationParameterDefaults()

    for tool in AnnotationToolType.allCases where tool.supportsQuickCornerRadius && tool != .spotlight {
      updateDefaultAnnotationProperties(for: tool, cornerRadius: clampedRadius)
    }

    if !selectedTool.supportsQuickPropertiesBar {
      rectangleCornerRadius = clampedRadius
    }
  }

  private func rememberSharedSpotlightCornerRadius(_ cornerRadius: CGFloat) {
    let clampedRadius = max(0, cornerRadius)
    sharedAnnotationParameterDefaults.spotlightCornerRadius = clampedRadius
    persistSharedAnnotationParameterDefaults()
    updateDefaultAnnotationProperties(for: .spotlight, cornerRadius: clampedRadius)
  }

  private func rememberSharedAnnotationFontSize(_ fontSize: CGFloat) {
    let clampedSize = AnnotationProperties.clampedFontSize(fontSize)
    sharedAnnotationParameterDefaults.fontSize = clampedSize
    persistSharedAnnotationParameterDefaults()

    updateDefaultAnnotationProperties(for: .text, fontSize: clampedSize)
    updateDefaultAnnotationProperties(for: .watermark, fontSize: clampedSize)
  }

  private func rememberSharedWatermarkOpacity(_ opacity: CGFloat) {
    let clampedOpacity = AnnotationProperties.clampedOpacity(opacity)
    sharedAnnotationParameterDefaults.watermarkOpacity = clampedOpacity
    persistSharedAnnotationParameterDefaults()
    updateDefaultAnnotationProperties(for: .watermark, opacity: clampedOpacity)
  }

  private func rememberSharedWatermarkRotation(_ rotationDegrees: CGFloat) {
    let clampedRotation = AnnotationProperties.clampedRotationDegrees(rotationDegrees)
    sharedAnnotationParameterDefaults.watermarkRotationDegrees = clampedRotation
    persistSharedAnnotationParameterDefaults()
    updateDefaultAnnotationProperties(for: .watermark, rotationDegrees: clampedRotation)
  }

  private func rememberAnnotationPrimaryColor(_ color: Color, for tool: AnnotationToolType?) {
    if tool == .spotlight {
      updateDefaultAnnotationProperties(for: .spotlight, strokeColor: color)
      guard !isTransparentColor(color) else { return }
    }

    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationColor(color)
      return
    }

    if let tool, tool.supportsQuickStrokeColor {
      updateDefaultAnnotationProperties(for: tool, strokeColor: color)
    } else {
      strokeColor = color
    }
  }

  private func rememberAnnotationStrokeWidth(_ strokeWidth: CGFloat, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationStrokeWidth(strokeWidth)
      return
    }

    let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    if let tool, tool.supportsQuickStrokeWidth {
      updateDefaultAnnotationProperties(for: tool, strokeWidth: clampedWidth)
    } else {
      self.strokeWidth = clampedWidth
    }
  }

  private func rememberAnnotationCornerRadius(_ cornerRadius: CGFloat, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      if tool == .spotlight {
        rememberSharedSpotlightCornerRadius(cornerRadius)
      } else {
        rememberSharedAnnotationCornerRadius(cornerRadius)
      }
      return
    }

    let clampedRadius = max(0, cornerRadius)
    if let tool, tool.supportsQuickCornerRadius {
      updateDefaultAnnotationProperties(for: tool, cornerRadius: clampedRadius)
    } else {
      rectangleCornerRadius = clampedRadius
    }
  }

  private func rememberSharedAnnotationLineStyle(_ lineStyle: LineDashStyle) {
    sharedAnnotationParameterDefaults.lineStyle = lineStyle.rawValue
    persistSharedAnnotationParameterDefaults()

    for tool in AnnotationToolType.allCases where tool.supportsQuickLineStyle {
      updateDefaultAnnotationProperties(for: tool, lineStyle: lineStyle)
    }
  }

  private func rememberAnnotationLineStyle(_ lineStyle: LineDashStyle, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationLineStyle(lineStyle)
      return
    }

    if let tool, tool.supportsQuickLineStyle {
      updateDefaultAnnotationProperties(for: tool, lineStyle: lineStyle)
    }
  }

  private func rememberAnnotationFontSize(_ fontSize: CGFloat, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationFontSize(fontSize)
      return
    }

    let clampedSize = AnnotationProperties.clampedFontSize(fontSize)
    if let tool, tool == .text || tool == .watermark {
      updateDefaultAnnotationProperties(for: tool, fontSize: clampedSize)
    }
  }

  private func rememberWatermarkOpacity(_ opacity: CGFloat) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedWatermarkOpacity(opacity)
      return
    }

    updateDefaultAnnotationProperties(
      for: .watermark,
      opacity: AnnotationProperties.clampedOpacity(opacity)
    )
  }

  private func rememberWatermarkRotation(_ rotationDegrees: CGFloat) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedWatermarkRotation(rotationDegrees)
      return
    }

    updateDefaultAnnotationProperties(
      for: .watermark,
      rotationDegrees: AnnotationProperties.clampedRotationDegrees(rotationDegrees)
    )
  }

  private func applySharedAnnotationColorToToolDefaults(_ color: Color) {
    for tool in AnnotationToolType.allCases where tool.supportsQuickStrokeColor {
      if tool == .spotlight {
        guard let spotlightProperties = annotationToolProperties[.spotlight],
              !isTransparentColor(spotlightProperties.strokeColor) else {
          continue
        }
      }
      var properties = defaultAnnotationProperties(for: tool)
      properties.strokeColor = color
      if tool == .filledRectangle {
        properties.fillColor = color
      }
      annotationToolProperties[tool] = properties
    }
    persistAnnotationToolProperties()

    if selectedTool.supportsQuickPropertiesBar {
      applyToolPropertiesToLegacyState(defaultAnnotationProperties(for: selectedTool), for: selectedTool)
    } else {
      strokeColor = color
    }
  }

  private func defaultAnnotationProperties(for tool: AnnotationToolType?) -> AnnotationProperties {
    guard let tool else {
      var properties = AnnotationProperties(strokeColor: sharedAnnotationColor ?? .red)
      applySharedParameterDefaults(to: &properties, for: nil)
      return properties
    }
    var properties = annotationToolProperties[tool] ?? baseAnnotationProperties(for: tool)
    if isQuickPropertiesSyncEnabled {
      applySynchronizedQuickProperties(to: &properties, for: tool)
    }

    return properties
  }

  private func baseAnnotationProperties(for tool: AnnotationToolType) -> AnnotationProperties {
    if tool == .spotlight {
      var properties = AnnotationProperties(
        strokeColor: .clear,
        fillColor: .clear,
        strokeWidth: 3,
        cornerRadius: 14, // radius-lint:allow — annotation content default, not chrome
        opacity: 1.0,
        spotlightOpacity: spotlightOpacity
      )
      applySharedParameterDefaults(to: &properties, for: tool)
      return properties
    }
    if tool != .watermark {
      var properties = AnnotationProperties(strokeColor: sharedAnnotationColor ?? .red)
      if tool == .text {
        // Новый текст эталона начинается с 30 pt (annotateLastTextSize).
        properties.fontSize = AnnotationProperties.defaultTextFontSize
      }
      if tool == .blur {
        // Без сохранённой толщины Secure и Smooth начинают с силы 10, Pixelate – с наименьшего блока.
        properties.strokeWidth = Self.blurTypeStartsAtStrength10(blurType)
          ? AnnotationProperties.secureBlurControlValue(for: 10)
          : AnnotationProperties.controlValueRange.lowerBound
      }
      if tool == .highlighter {
        properties.strokeWidth = AnnotationProperties.defaultHighlighterStrokeWidth
      }
      applySharedParameterDefaults(to: &properties, for: tool)
      if tool == .filledRectangle {
        properties.fillColor = properties.strokeColor
      }
      return properties
    }

    let strokeColor = sharedAnnotationColor ?? Color.white
    var properties = AnnotationProperties(
      strokeColor: strokeColor,
      fillColor: .clear,
      strokeWidth: 3,
      cornerRadius: 0, // radius-lint:allow — watermark content default, not chrome
      fontSize: 36,
      fontName: "SF Pro",
      opacity: 0.22,
      rotationDegrees: WatermarkStyle.diagonal.defaultRotationDegrees,
      watermarkStyle: .diagonal
    )
    applySharedParameterDefaults(to: &properties, for: tool)
    return properties
  }

  private func applySynchronizedQuickProperties(
    to properties: inout AnnotationProperties,
    for tool: AnnotationToolType
  ) {
    let sharedProperties = baseAnnotationProperties(for: tool)

    if tool.supportsQuickStrokeColor, tool != .spotlight {
      properties.strokeColor = sharedProperties.strokeColor
      if tool == .filledRectangle {
        properties.fillColor = sharedProperties.strokeColor
      }
    }

    if tool.supportsQuickStrokeWidth {
      properties.strokeWidth = sharedProperties.strokeWidth
    }

    if tool.supportsQuickCornerRadius {
      properties.cornerRadius = sharedProperties.cornerRadius
    }

    if tool.supportsQuickLineStyle {
      properties.lineStyle = sharedProperties.lineStyle
    }

    if tool == .text || tool == .watermark {
      properties.fontSize = sharedProperties.fontSize
    }

    if tool == .watermark {
      if sharedAnnotationParameterDefaults.watermarkOpacity != nil {
        properties.opacity = sharedProperties.opacity
      }
      if sharedAnnotationParameterDefaults.watermarkRotationDegrees != nil {
        properties.rotationDegrees = sharedProperties.rotationDegrees
      }
    }
  }

  private func applySharedParameterDefaults(
    to properties: inout AnnotationProperties,
    for tool: AnnotationToolType?
  ) {
    let defaults = sharedAnnotationParameterDefaults

    if tool == nil || tool?.supportsQuickStrokeWidth == true,
       let strokeWidth = defaults.strokeWidth {
      properties.strokeWidth = strokeWidth
    }

    if tool == .spotlight {
      if let cornerRadius = defaults.spotlightCornerRadius {
        properties.cornerRadius = cornerRadius
      } else {
        properties.cornerRadius = 14
      }
    } else if tool == nil || tool?.supportsQuickCornerRadius == true {
      if let cornerRadius = defaults.cornerRadius {
        properties.cornerRadius = cornerRadius
      }
    }

    if tool == nil || tool == .text || tool == .watermark,
       let fontSize = defaults.fontSize {
      properties.fontSize = fontSize
    }

    if tool == nil || tool == .watermark {
      if let watermarkOpacity = defaults.watermarkOpacity {
        properties.opacity = watermarkOpacity
      }
      if let watermarkRotationDegrees = defaults.watermarkRotationDegrees {
        properties.rotationDegrees = watermarkRotationDegrees
      }
    }

    if tool == nil || tool?.supportsQuickLineStyle == true,
       let lineStyle = defaults.lineStyle.flatMap(LineDashStyle.init(rawValue:)) {
      properties.lineStyle = lineStyle
    }
  }

  func annotationCreationProperties(for tool: AnnotationToolType) -> AnnotationProperties {
    var properties = defaultAnnotationProperties(for: tool)
    if tool == .text, shouldUseRecommendedTextFontSize {
      properties.fontSize = recommendedTextFontSize()
    }
    if tool == .filledRectangle {
      properties.fillColor = properties.strokeColor
    }
    return properties
  }

  /// Starts new text at a readable size relative to the current image or combined canvas.
  /// A manually chosen text size is always preserved for subsequent annotations.
  func recommendedTextFontSize() -> CGFloat {
    let canvasSize = effectiveContentBounds.size
    let shortSide = max(min(canvasSize.width, canvasSize.height), 1)
    let suggested = shortSide * 0.026
    let stepped = (suggested / 2).rounded() * 2
    return min(max(stepped, 16), 36)
  }

  private var shouldUseRecommendedTextFontSize: Bool {
    sharedAnnotationParameterDefaults.fontSize == nil && annotationToolProperties[.text] == nil
  }

  private func updateDefaultAnnotationProperties(
    for tool: AnnotationToolType,
    strokeWidth: CGFloat? = nil,
    strokeColor: Color? = nil,
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    fontName: String? = nil,
    opacity: CGFloat? = nil,
    rotationDegrees: CGFloat? = nil,
    watermarkStyle: WatermarkStyle? = nil,
    spotlightOpacity: CGFloat? = nil,
    lineStyle: LineDashStyle? = nil,
    counterFormat: CounterNumberFormat? = nil
  ) {
    var properties = defaultAnnotationProperties(for: tool)

    if let counterFormat {
      properties.counterFormat = counterFormat
    }
    if let strokeWidth = strokeWidth {
      properties.strokeWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    }
    if tool == .filledRectangle,
       let color = strokeColor ?? fillColor {
      properties.strokeColor = color
      properties.fillColor = color
    } else {
      if let strokeColor = strokeColor {
        properties.strokeColor = strokeColor
      }
      if let fillColor = fillColor {
        properties.fillColor = fillColor
      }
    }
    if tool == .text,
       let fillColor = fillColor,
       fillColor != .clear,
       properties.textPresentation == .plain {
      properties.textPresentation = .label
    }
    if let cornerRadius = cornerRadius {
      properties.cornerRadius = max(0, cornerRadius)
    }
    if let fontSize = fontSize {
      properties.fontSize = AnnotationProperties.clampedFontSize(fontSize)
    }
    if let fontName = fontName {
      properties.fontName = fontName
    }
    if let opacity = opacity {
      properties.opacity = AnnotationProperties.clampedOpacity(opacity)
    }
    if let rotationDegrees = rotationDegrees {
      properties.rotationDegrees = AnnotationProperties.clampedRotationDegrees(rotationDegrees)
    }
    if let watermarkStyle = watermarkStyle {
      properties.watermarkStyle = watermarkStyle
    }
    if let spotlightOpacity = spotlightOpacity {
      properties.spotlightOpacity = AnnotationProperties.clampedSpotlightOpacity(spotlightOpacity)
    }
    if let lineStyle = lineStyle {
      properties.lineStyle = lineStyle
    }

    let sanitized = sanitizedAnnotationProperties(properties, for: tool)
    annotationToolProperties[tool] = sanitized
    persistAnnotationToolProperties()
    if selectedTool == tool {
      applyToolPropertiesToLegacyState(sanitized, for: tool)
    }
  }

  private func counterBounds(center: CGPoint, controlValue: CGFloat) -> CGRect {
    let diameter = AnnotationProperties.counterDiameter(for: controlValue)
    return CGRect(
      x: center.x - diameter / 2,
      y: center.y - diameter / 2,
      width: diameter,
      height: diameter
    )
  }

  private func syncActiveToolProperties() {
    guard selectedTool.supportsQuickPropertiesBar else { return }
    applyToolPropertiesToLegacyState(defaultAnnotationProperties(for: selectedTool), for: selectedTool)
  }

  private func applyToolPropertiesToLegacyState(
    _ properties: AnnotationProperties,
    for tool: AnnotationToolType
  ) {
    strokeColor = properties.strokeColor
    fillColor = properties.fillColor
    strokeWidth = properties.strokeWidth
    if tool.supportsQuickCornerRadius {
      rectangleCornerRadius = properties.cornerRadius
    }
    if tool == .spotlight {
      spotlightOpacity = properties.spotlightOpacity
    }
  }

  private var quickPropertiesSelectionAnnotations: [AnnotationItem] {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else { return [] }
    return selectedAnnotations
  }

  private var quickPropertiesSelectionTargets: [AnnotationItem] {
    let selected = quickPropertiesSelectionAnnotations
    guard !selected.isEmpty else { return [] }
    if selected.count == 1 {
      guard selected[0].type.supportsQuickPropertiesBar else { return [] }
    }
    return selected
  }

  private var quickPropertiesCommonSelectedTool: AnnotationToolType? {
    let selected = quickPropertiesSelectionAnnotations
    guard !selected.isEmpty else { return nil }
    let tools = Set(selected.map { $0.type.toolType })
    guard tools.count == 1 else { return nil }
    return tools.first
  }

  private func quickSelectionAnySupport(_ predicate: (AnnotationType) -> Bool) -> Bool {
    let selected = quickPropertiesSelectionTargets
    guard !selected.isEmpty else { return false }
    return selected.contains { predicate($0.type) }
  }

  private func quickSelectionTargets(matching predicate: (AnnotationType) -> Bool) -> [AnnotationItem] {
    quickPropertiesSelectionTargets.filter { predicate($0.type) }
  }

  func setQuickPropertiesControlEditing(_ isEditing: Bool) {
    if isEditing {
      beginQuickPropertiesGestureUndoIfNeeded()
    } else {
      isQuickPropertiesGestureEditing = false
      quickPropertiesGestureUndoSnapshot = nil
    }
  }

  /// Marks a sidebar property slider drag as one undo gesture. The pre-gesture
  /// snapshot is pushed once on the first actual change; a drag that changes
  /// nothing records no undo entry.
  func setPropertySliderGestureEditing(_ isEditing: Bool) {
    if isEditing {
      guard !isPropertySliderGestureEditing else { return }
      isPropertySliderGestureEditing = true
      propertySliderGestureUndoSnapshot = currentSnapshot()
    } else {
      isPropertySliderGestureEditing = false
      propertySliderGestureUndoSnapshot = nil
    }
  }

  private func beginQuickPropertiesGestureUndoIfNeeded() {
    guard !isQuickPropertiesGestureEditing,
          !quickPropertiesSelectionTargets.isEmpty else { return }
    isQuickPropertiesGestureEditing = true
    quickPropertiesGestureUndoSnapshot = currentSnapshot()
  }

  private func updateQuickSelectionProperties(
    strokeWidth: CGFloat? = nil,
    strokeColor: Color? = nil,
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    opacity: CGFloat? = nil,
    rotationDegrees: CGFloat? = nil,
    watermarkStyle: WatermarkStyle? = nil,
    spotlightOpacity: CGFloat? = nil,
    lineStyle: LineDashStyle? = nil,
    recordsUndo: Bool = false,
    matching predicate: ((AnnotationType) -> Bool)? = nil
  ) -> Bool {
    let selected = quickPropertiesSelectionTargets.filter { annotation in
      predicate?(annotation.type) ?? true
    }
    guard !selected.isEmpty else { return false }

    let shouldRecordUndo = recordsUndo && selected.contains(where: {
      annotationPropertiesWillChange(
        $0,
        strokeWidth: strokeWidth,
        fontSize: fontSize,
        strokeColor: strokeColor,
        fillColor: fillColor,
        cornerRadius: cornerRadius,
        opacity: opacity,
        rotationDegrees: rotationDegrees,
        watermarkStyle: watermarkStyle,
        spotlightOpacity: spotlightOpacity,
        lineStyle: lineStyle
      )
    })

    if shouldRecordUndo {
      if let snapshot = quickPropertiesGestureUndoSnapshot {
        pushUndoSnapshot(snapshot, annotationCount: snapshot.annotations.count)
        quickPropertiesGestureUndoSnapshot = nil
      } else if !isQuickPropertiesGestureEditing {
        saveState()
      }
    }

    for annotation in selected {
      updateAnnotationProperties(
        id: annotation.id,
        strokeWidth: strokeWidth,
        fontSize: fontSize,
        strokeColor: strokeColor,
        fillColor: fillColor,
        cornerRadius: cornerRadius,
        opacity: opacity,
        rotationDegrees: rotationDegrees,
        watermarkStyle: watermarkStyle,
        spotlightOpacity: spotlightOpacity,
        lineStyle: lineStyle
      )
    }
    return true
  }

  var quickPropertiesSupportsArrowStyle: Bool {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .arrow = $0.type { return true }
        return false
      }
    }

    return quickPropertiesTool == .arrow
  }

  var quickPropertiesSupportsArrowBendDirection: Bool {
    guard quickPropertiesSupportsArrowStyle else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.style.supportsBendDirection
      }
    }

    return quickPropertiesTool == .arrow && activeArrowStyle.supportsBendDirection
  }

  /// Per-endpoint head styles apply to the classic (stroked line) display type.
  var quickPropertiesSupportsArrowEndpoints: Bool {
    guard quickPropertiesSupportsArrowStyle else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.arrowType == .classic
      }
    }

    return quickPropertiesTool == .arrow && activeArrowType == .classic
  }

  var quickArrowStyleBinding: Binding<ArrowStyle> {
    Binding(
      get: { [weak self] in
        self?.activeArrowStyle ?? .straight
      },
      set: { [weak self] newStyle in
        self?.setActiveArrowStyle(newStyle)
      }
    )
  }

  var quickArrowTypeBinding: Binding<ArrowType> {
    Binding(
      get: { [weak self] in
        self?.activeArrowType ?? .tapered
      },
      set: { [weak self] newType in
        self?.setActiveArrowType(newType)
      }
    )
  }

  var quickArrowBendDirectionBinding: Binding<ArrowBendDirection> {
    Binding(
      get: { [weak self] in
        self?.activeArrowBendDirection ?? .primary
      },
      set: { [weak self] newDirection in
        self?.setActiveArrowBendDirection(newDirection)
      }
    )
  }

  var quickArrowStartHeadBinding: Binding<ArrowEndpointStyle> {
    Binding(
      get: { [weak self] in
        self?.activeArrowStartHead ?? .none
      },
      set: { [weak self] newHead in
        self?.setActiveArrowStartHead(newHead)
      }
    )
  }

  var quickArrowEndHeadBinding: Binding<ArrowEndpointStyle> {
    Binding(
      get: { [weak self] in
        self?.activeArrowEndHead ?? .arrow
      },
      set: { [weak self] newHead in
        self?.setActiveArrowEndHead(newHead)
      }
    )
  }

  var quickPropertiesSupportsTextFontSize: Bool {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        switch $0.type {
        case .text, .watermark:
          return true
        default:
          return false
        }
      }
    }

    return quickPropertiesTool == .text || quickPropertiesTool == .watermark
  }

  var quickPropertiesSupportsTextBackground: Bool {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .text = $0.type { return true }
        return false
      }
    }

    return quickPropertiesTool == .text
  }

  var quickPropertiesSupportsTextPresentation: Bool {
    quickPropertiesSupportsTextBackground
  }

  var quickTextPresentation: TextPresentation {
    quickSelectionTargets(matching: {
      if case .text = $0 { return true }
      return false
    }).first?.properties.textPresentation
      ?? defaultAnnotationProperties(for: quickPropertiesTool).textPresentation
  }

  func setTextPresentation(_ presentation: TextPresentation) {
    let selected = quickSelectionTargets(matching: {
      if case .text = $0 { return true }
      return false
    })

    guard !selected.isEmpty else {
      guard quickPropertiesTool == .text else { return }
      var properties = defaultAnnotationProperties(for: .text)
      properties.textPresentation = presentation
      properties.calloutTailTarget = nil
      if presentation != .plain, properties.fillColor == .clear {
        properties.fillColor = .black
      }
      if presentation != .plain {
        properties.textStyle = properties.textStyle.withoutBackdrop
      }
      annotationToolProperties[.text] = properties
      persistAnnotationToolProperties()
      return
    }

    saveState()
    for annotation in selected {
      guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { continue }
      annotations[index].properties.textPresentation = presentation
      if presentation == .plain {
        annotations[index].properties.calloutTailTarget = nil
      } else if presentation == .callout {
        annotations[index].properties.calloutTailTarget = annotations[index].properties.calloutTailTarget
          ?? defaultCalloutTailTarget(for: annotations[index].bounds, fontSize: annotations[index].properties.fontSize)
      } else {
        annotations[index].properties.calloutTailTarget = nil
      }
      if presentation != .plain, annotations[index].properties.fillColor == .clear {
        annotations[index].properties.fillColor = .black
      }
      if presentation != .plain {
        // Label/callout и построчная подложка Box не накладываются друг на друга.
        annotations[index].properties.textStyle = annotations[index].properties.textStyle.withoutBackdrop
      }
    }
    hasUnsavedChanges = true
  }

  /// Стиль текста из меню Text style: выбранный текст или параметр инструмента Text.
  var quickTextStyle: AnnotationTextStyle {
    quickSelectionTargets(matching: {
      if case .text = $0 { return true }
      return false
    }).first?.properties.textStyle
      ?? defaultAnnotationProperties(for: quickPropertiesTool).textStyle
  }

  /// Применяет стиль к выбранным текстам (одним шагом undo) либо запоминает его
  /// для следующих текстов. Стиль с подложкой снимает label/callout, иначе под
  /// текстом окажутся две подложки.
  func setTextStyle(_ style: AnnotationTextStyle) {
    let selected = quickSelectionTargets(matching: {
      if case .text = $0 { return true }
      return false
    })

    guard !selected.isEmpty else {
      guard quickPropertiesTool == .text else { return }
      var properties = defaultAnnotationProperties(for: .text)
      properties.textStyle = style
      if style.backdrop != nil {
        properties.textPresentation = .plain
        properties.calloutTailTarget = nil
      }
      annotationToolProperties[.text] = properties
      persistAnnotationToolProperties()
      return
    }

    guard selected.contains(where: { $0.properties.textStyle != style }) else { return }

    saveState()
    for annotation in selected {
      guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { continue }
      annotations[index].properties.textStyle = style
      if style.backdrop != nil {
        annotations[index].properties.textPresentation = .plain
        annotations[index].properties.calloutTailTarget = nil
      }
      // Mono меняет ширину glyph и перенос строк, поэтому высоту рамки пересчитываем.
      if case .text(let content) = annotations[index].type {
        annotations[index].bounds = resizedTextBounds(
          id: annotation.id,
          text: content,
          properties: annotations[index].properties,
          currentBounds: annotations[index].bounds
        )
      }
    }
    hasUnsavedChanges = true
  }

  func prepareTextCalloutTail(for id: UUID) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text = annotations[index].type,
          annotations[index].properties.textPresentation == .callout,
          annotations[index].properties.calloutTailTarget == nil else { return }
    annotations[index].properties.calloutTailTarget = defaultCalloutTailTarget(for: annotations[index].bounds, fontSize: annotations[index].properties.fontSize)
  }

  /// The canvas records the undo checkpoint once before committing its local gesture.
  func updateCounterArrowTarget(id: UUID, target: CGPoint?) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .counter = annotations[index].type else { return }
    let resolved = annotations[index].normalizedCounterArrowTarget(target)
    guard annotations[index].properties.counterArrowTarget != resolved else { return }
    annotations[index].properties.counterArrowTarget = resolved
    hasUnsavedChanges = true
  }

  func updateTextCalloutTail(id: UUID, target: CGPoint) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text = annotations[index].type,
          annotations[index].properties.textPresentation == .callout else { return }
    annotations[index].properties.calloutTailTarget = TextBubbleGeometry.resolvedTailTarget(
      in: annotations[index].bounds,
      requestedTarget: target,
      fontSize: annotations[index].properties.fontSize
    )
    hasUnsavedChanges = true
  }

  private func defaultCalloutTailTarget(for bounds: CGRect, fontSize: CGFloat) -> CGPoint {
    TextBubbleGeometry.defaultTailTarget(for: bounds, fontSize: fontSize)
  }

  var quickTextFontSizeBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 16 }
        return self.quickSelectionTargets(matching: {
          switch $0 {
          case .text, .watermark:
            return true
          default:
            return false
          }
        }).first?.properties.fontSize
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).fontSize
      },
      set: { [weak self] newSize in
        guard let self else { return }
        let clampedSize = AnnotationProperties.clampedFontSize(newSize)
        if !self.updateQuickSelectionProperties(
          fontSize: clampedSize,
          recordsUndo: true,
          matching: {
            switch $0 {
            case .text, .watermark:
              return true
            default:
              return false
            }
          }
        ) {
          self.rememberAnnotationFontSize(clampedSize, for: self.quickPropertiesTool)
        }
      }
    )
  }

  var quickTextBackgroundBinding: Binding<Color> {
    Binding(
      get: { [weak self] in
        guard let self else { return .clear }
        return self.quickSelectionTargets(matching: {
          if case .text = $0 { return true }
          return false
        }).first?.properties.fillColor
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).fillColor
      },
      set: { [weak self] newColor in
        guard let self else { return }
        if !self.updateQuickSelectionProperties(
          fillColor: newColor,
          recordsUndo: true,
          matching: {
            if case .text = $0 { return true }
            return false
          }
        ) {
          if let tool = self.quickPropertiesTool {
            self.updateDefaultAnnotationProperties(for: tool, fillColor: newColor)
          }
        }
      }
    )
  }

  var quickPropertiesSupportsBlurType: Bool {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .blur = $0.type { return true }
        return false
      }
    }

    return quickPropertiesTool == .blur
  }

  var quickBlurTypeBinding: Binding<BlurType> {
    Binding(
      get: { [weak self] in
        self?.activeBlurType ?? .pixelated
      },
      set: { [weak self] newType in
        self?.setActiveBlurType(newType)
      }
    )
  }

  var quickPropertiesSupportsWatermark: Bool {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .watermark = $0.type { return true }
        return false
      }
    }

    return quickPropertiesTool == .watermark
  }

  var quickWatermarkTextBinding: Binding<String> {
    Binding(
      get: { [weak self] in
        guard let self else { return "Snapzy" }
        if let annotation = self.quickSelectionTargets(matching: {
          if case .watermark = $0 { return true }
          return false
        }).first,
           case .watermark(let text) = annotation.type {
          return text
        }
        return self.watermarkText
      },
      set: { [weak self] newText in
        guard let self else { return }
        let selected = self.quickSelectionTargets(matching: {
          if case .watermark = $0 { return true }
          return false
        })
        if selected.isEmpty {
          self.watermarkText = newText
        } else {
          selected.forEach { self.updateWatermarkText(id: $0.id, text: newText) }
        }
      }
    )
  }

  var quickWatermarkStyleBinding: Binding<WatermarkStyle> {
    Binding(
      get: { [weak self] in
        self?.activeWatermarkStyle ?? .diagonal
      },
      set: { [weak self] newStyle in
        self?.setActiveWatermarkStyle(newStyle)
      }
    )
  }

  var quickWatermarkOpacityBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 0.22 }
        return self.quickSelectionTargets(matching: {
          if case .watermark = $0 { return true }
          return false
        }).first?.properties.opacity
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).opacity
      },
      set: { [weak self] newOpacity in
        guard let self else { return }
        let clampedOpacity = AnnotationProperties.clampedOpacity(newOpacity)
        if !self.updateQuickSelectionProperties(
          opacity: clampedOpacity,
          recordsUndo: true,
          matching: {
            if case .watermark = $0 { return true }
            return false
          }
        ) {
          self.rememberWatermarkOpacity(clampedOpacity)
        }
      }
    )
  }

  var quickWatermarkRotationBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return -24 }
        return self.quickSelectionTargets(matching: {
          if case .watermark = $0 { return true }
          return false
        }).first?.properties.rotationDegrees
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).rotationDegrees
      },
      set: { [weak self] newRotation in
        guard let self else { return }
        let clampedRotation = AnnotationProperties.clampedRotationDegrees(newRotation)
        if !self.updateQuickSelectionProperties(
          rotationDegrees: clampedRotation,
          recordsUndo: true,
          matching: {
            if case .watermark = $0 { return true }
            return false
          }
        ) {
          self.rememberWatermarkRotation(clampedRotation)
        }
      }
    )
  }

  var quickPropertiesAnnotation: AnnotationItem? {
    guard let annotation = quickPropertiesSelectionAnnotations.first,
          quickPropertiesSelectionAnnotations.count == 1,
          annotation.type.supportsQuickPropertiesBar else {
      return nil
    }
    return annotation
  }

  var quickPropertiesMode: QuickPropertiesMode {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return .selectedItem
    }
    if quickPropertiesTool != nil {
      return .toolDefaults
    }
    return .hidden
  }

  var quickPropertiesTool: AnnotationToolType? {
    if let annotation = quickPropertiesAnnotation {
      return annotation.type.toolType
    }

    if quickPropertiesSelectionAnnotations.count == 1 {
      return quickPropertiesSelectionAnnotations[0].type.toolType
    }

    if quickPropertiesSelectionAnnotations.count > 1 {
      return quickPropertiesCommonSelectedTool ?? .selection
    }

    guard editorMode == .annotate,
          selectedTool != .crop,
          selectedTool != .cutOut,
          selectedTool.supportsQuickPropertiesBar else {
      return nil
    }
    return selectedTool
  }

  var quickPropertiesSelectedAnnotationCount: Int {
    quickPropertiesSelectionAnnotations.count
  }

  var quickPropertiesShowsSelectionStyle: Bool {
    guard editorMode == .annotate,
          selectedTool != .crop, selectedTool != .cutOut else {
      return false
    }

    if quickPropertiesSelectionAnnotations.isEmpty {
      return selectedTool == .selection
    }

    return quickPropertiesSelectionAnnotations.allSatisfy { annotation in
      annotation.type.toolType == .selection || !annotation.type.supportsQuickPropertiesBar
    }
  }

  var showsQuickPropertiesBar: Bool {
    quickPropertiesMode != .hidden
  }

  var quickPropertiesContextTitle: String {
    switch quickPropertiesMode {
    case .selectedItem:
      if quickPropertiesSelectionAnnotations.count > 1 {
        return L10n.AnnotateContext.selected("\(quickPropertiesSelectionAnnotations.count)")
      }
      let tool = quickPropertiesCommonSelectedTool ?? quickPropertiesTool
      guard let tool, tool != .selection else {
        return L10n.AnnotateContext.selected(L10n.AnnotateUI.annotation)
      }
      return L10n.AnnotateContext.selected(tool.displayName)
    case .toolDefaults:
      guard let tool = quickPropertiesTool else { return "" }
      return L10n.AnnotateContext.defaults(tool.displayName)
    case .hidden:
      return ""
    }
  }

  var quickPropertiesSupportsStrokeColor: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickStrokeColor }
    }
    return quickPropertiesTool?.supportsQuickStrokeColor ?? false
  }

  var quickPropertiesSupportsFill: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickFillColor }
    }
    return quickPropertiesTool?.supportsQuickFillColor ?? false
  }

  var quickPropertiesSupportsStrokeWidth: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickStrokeWidth }
    }
    return quickPropertiesTool?.supportsQuickStrokeWidth ?? false
  }

  /// Dash styles apply to stroked geometry only; the arrow tool qualifies just
  /// for the classic (stroked) display type.
  var quickPropertiesSupportsLineStyle: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickLineStyle }
    }
    guard let tool = quickPropertiesTool, tool.supportsQuickLineStyle else { return false }
    return tool != .arrow || activeArrowType == .classic
  }

  /// Text snapping shapes new strokes, so it belongs to the highlighter's
  /// defaults context — a committed highlight's geometry is already fixed, and
  /// every control in the selected-item context edits that item.
  var quickPropertiesSupportsHighlighterTextSnapping: Bool {
    quickPropertiesMode == .toolDefaults && quickPropertiesTool == .highlighter
  }

  /// Axis shapes new measurements only, like text snapping; a pinned span keeps its axis.
  var quickPropertiesSupportsMeasureAxis: Bool {
    quickPropertiesMode == .toolDefaults && quickPropertiesTool == .measure
  }

  /// Unit applies to new measurements and converts selected ones.
  var quickPropertiesSupportsMeasureUnit: Bool {
    quickPropertiesTool == .measure
  }

  var quickMeasureAxisBinding: Binding<MeasureAxis> {
    Binding(
      get: { [weak self] in self?.measureAxis ?? .both },
      set: { [weak self] axis in self?.measureAxis = axis }
    )
  }

  /// The selected measurement's unit when one is selected, otherwise the tool's.
  var quickMeasureUnitBinding: Binding<MeasureUnit> {
    Binding(
      get: { [weak self] in
        guard let self else { return .points }
        for annotation in self.quickPropertiesSelectionTargets {
          if case .measurement(let geometry) = annotation.type { return geometry.unit }
        }
        return self.measureUnit
      },
      set: { [weak self] unit in self?.setMeasureUnit(unit) }
    )
  }

  var quickHighlighterTextSnappingBinding: Binding<Bool> {
    Binding(
      get: { [weak self] in self?.isHighlighterTextSnappingEnabled ?? true },
      set: { [weak self] isEnabled in self?.isHighlighterTextSnappingEnabled = isEnabled }
    )
  }

  var quickStrokeWidthLabel: String {
    quickStrokeWidthUsesSizeLabel ? L10n.Common.size : L10n.Common.stroke
  }

  var quickStrokeWidthIcon: String {
    quickStrokeWidthUsesSizeLabel ? "arrow.up.left.and.arrow.down.right" : "line.diagonal"
  }

  var quickStrokeWidthDisplayText: String {
    let controlValue = quickStrokeWidthValue

    switch quickStrokeWidthSemanticTool {
    case .counter:
      return "\(Int(AnnotationProperties.counterDiameter(for: controlValue).rounded()))"
    case .blur:
      let value: CGFloat
      switch activeBlurType {
      case .pixelated:
        value = AnnotationProperties.pixelatedBlurSize(for: controlValue)
      case .secure:
        value = AnnotationProperties.secureBlurStrength(for: controlValue)
      case .blackOut:
        return ""
      case .gaussian:
        // Подпись по шкале слайдера эталона 3…30, как у Secure (ANN-109).
        value = AnnotationProperties.secureBlurStrength(for: controlValue)
      case .hexagonal:
        value = AnnotationProperties.hexagonalScale(for: controlValue)
      case .crystallized:
        value = AnnotationProperties.crystallizeRadius(for: controlValue)
      case .pointillism:
        value = AnnotationProperties.pointillismRadius(for: controlValue)
      case .halftone:
        value = AnnotationProperties.halftoneWidth(for: controlValue)
      case .tape:
        value = AnnotationProperties.tapePatternSpacing(for: controlValue)
      case .washi:
        value = AnnotationProperties.washiPatternSpacing(for: controlValue)
      }
      return "\(Int(value.rounded()))"
    default:
      return "\(Int(controlValue.rounded()))"
    }
  }

  private var quickStrokeWidthUsesSizeLabel: Bool {
    switch quickStrokeWidthSemanticTool {
    case .blur, .counter:
      return true
    default:
      return false
    }
  }

  private var quickStrokeWidthSemanticTool: AnnotationToolType? {
    let selectedStrokeTargets = quickSelectionTargets(matching: { $0.supportsQuickStrokeWidth })
    if !selectedStrokeTargets.isEmpty {
      let tools = Set(selectedStrokeTargets.map { $0.type.toolType })
      guard tools.count == 1 else { return nil }
      return tools.first
    }
    return quickPropertiesTool
  }

  private var quickStrokeWidthValue: CGFloat {
    quickSelectionTargets(matching: { $0.supportsQuickStrokeWidth }).first?.properties.strokeWidth
      ?? defaultAnnotationProperties(for: quickPropertiesTool).strokeWidth
  }

  var quickPropertiesSupportsCornerRadius: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.toolType.supportsQuickCornerRadius }
    }
    return quickPropertiesTool?.supportsQuickCornerRadius ?? false
  }

  var quickPropertiesSupportsSpotlightOpacity: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { if case .spotlight = $0 { return true }; return false }
    }
    return quickPropertiesTool == .spotlight
  }

  var quickStrokeColorBinding: Binding<Color> {
    Binding(
      get: { [weak self] in
        guard let self else { return .red }
        return self.quickSelectionTargets(matching: { $0.supportsQuickStrokeColor }).first?.properties.strokeColor
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).strokeColor
      },
      set: { [weak self] newColor in
        guard let self else { return }
        let selectedStrokeTargets = self.quickSelectionTargets(matching: { $0.supportsQuickStrokeColor })
        let hasSpotlightTarget = selectedStrokeTargets.contains { $0.type.toolType == .spotlight }
        let didUpdateSelection = self.updateQuickSelectionProperties(
          strokeColor: newColor,
          recordsUndo: true,
          matching: { $0.supportsQuickStrokeColor }
        )
        if didUpdateSelection {
          if hasSpotlightTarget {
            self.updateDefaultAnnotationProperties(for: .spotlight, strokeColor: newColor)
          }
          if self.isQuickPropertiesSyncEnabled && !(
            hasSpotlightTarget && self.isTransparentColor(newColor)
          ) {
            self.rememberSharedAnnotationColor(newColor)
          }
        } else {
          self.rememberAnnotationPrimaryColor(newColor, for: self.quickPropertiesTool)
        }
        if !didUpdateSelection, self.quickPropertiesTool == nil {
          self.strokeColor = newColor
        }
      }
    )
  }

  var quickFillColorBinding: Binding<Color> {
    Binding(
      get: { [weak self] in
        guard let self else { return .clear }
        return self.quickSelectionTargets(matching: { $0.supportsQuickFillColor }).first?.properties.fillColor
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).fillColor
      },
      set: { [weak self] newColor in
        guard let self else { return }
        if !self.updateQuickSelectionProperties(
          fillColor: newColor,
          recordsUndo: true,
          matching: { $0.supportsQuickFillColor }
        ) {
          if let tool = self.quickPropertiesTool {
            self.updateDefaultAnnotationProperties(for: tool, fillColor: newColor)
          } else {
            self.fillColor = newColor
          }
        }
      }
    )
  }

  var quickStrokeWidthBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 3 }
        return self.quickSelectionTargets(matching: { $0.supportsQuickStrokeWidth }).first?.properties.strokeWidth
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).strokeWidth
      },
      set: { [weak self] newWidth in
        guard let self else { return }
        if !self.updateQuickSelectionProperties(
          strokeWidth: newWidth,
          recordsUndo: true,
          matching: { $0.supportsQuickStrokeWidth }
        ) {
          self.rememberAnnotationStrokeWidth(newWidth, for: self.quickPropertiesTool)
        }
      }
    )
  }

  var quickCornerRadiusBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 0 }
        return self.quickSelectionTargets(matching: { $0.toolType.supportsQuickCornerRadius }).first?.properties.cornerRadius
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).cornerRadius
      },
      set: { [weak self] newRadius in
        guard let self else { return }
        let clampedRadius = max(0, newRadius)
        if !self.updateQuickSelectionProperties(
          cornerRadius: clampedRadius,
          recordsUndo: true,
          matching: { $0.toolType.supportsQuickCornerRadius }
        ) {
          self.rememberAnnotationCornerRadius(clampedRadius, for: self.quickPropertiesTool)
        }
      }
    )
  }

  var quickLineStyleBinding: Binding<LineDashStyle> {
    Binding(
      get: { [weak self] in
        guard let self else { return .solid }
        return self.quickSelectionTargets(matching: { $0.supportsQuickLineStyle }).first?.properties.lineStyle
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).lineStyle
      },
      set: { [weak self] newStyle in
        guard let self else { return }
        if !self.updateQuickSelectionProperties(
          lineStyle: newStyle,
          recordsUndo: true,
          matching: { $0.supportsQuickLineStyle }
        ) {
          self.rememberAnnotationLineStyle(newStyle, for: self.quickPropertiesTool)
        }
      }
    )
  }

  var quickSpotlightOpacityBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 0.5 }
        return self.quickSelectionTargets(matching: { if case .spotlight = $0 { return true }; return false }).first?.properties.spotlightOpacity
          ?? self.defaultAnnotationProperties(for: self.quickPropertiesTool).spotlightOpacity
      },
      set: { [weak self] newOpacity in
        guard let self else { return }
        if !self.updateQuickSelectionProperties(
          spotlightOpacity: newOpacity,
          recordsUndo: true,
          matching: { if case .spotlight = $0 { return true }; return false }
        ) {
          self.rememberAnnotationSpotlightOpacity(newOpacity, for: self.quickPropertiesTool)
        }
      }
    )
  }

  private func rememberAnnotationSpotlightOpacity(_ opacity: CGFloat, for tool: AnnotationToolType?) {
    let clampedOpacity = AnnotationProperties.clampedSpotlightOpacity(opacity)
    // Always sync the global published value so annotationCreationProperties picks it up for new regions.
    self.spotlightOpacity = clampedOpacity
    if let tool, tool == .spotlight {
      updateDefaultAnnotationProperties(for: tool, spotlightOpacity: clampedOpacity)
    }
  }

  // MARK: - Spotlight shape

  /// Форма из меню Spotlight shape: выбранный Spotlight или параметр инструмента.
  var quickSpotlightShape: SpotlightShape {
    quickSelectionTargets(matching: { if case .spotlight = $0 { return true }; return false })
      .first?.properties.spotlightShape
      ?? defaultAnnotationProperties(for: .spotlight).spotlightShape
  }

  /// Меняет форму выбранных Spotlight одним шагом undo и всегда запоминает её
  /// для следующих, как annotateLastHighlightShape эталона.
  func setSpotlightShape(_ shape: SpotlightShape) {
    let selected = quickSelectionTargets(matching: { if case .spotlight = $0 { return true }; return false })
    var properties = defaultAnnotationProperties(for: .spotlight)
    properties.spotlightShape = shape
    annotationToolProperties[.spotlight] = properties
    persistAnnotationToolProperties()

    guard selected.contains(where: { $0.properties.spotlightShape != shape }) else { return }
    saveState()
    for annotation in selected {
      guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { continue }
      annotations[index].properties.spotlightShape = shape
    }
    hasUnsavedChanges = true
  }

  /// Меню формы и слайдер Spotlight в inline-панели.
  var quickPropertiesSupportsSpotlightShape: Bool {
    guard editorMode == .annotate, selectedTool != .crop, selectedTool != .cutOut else { return false }
    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains { if case .spotlight = $0.type { return true }; return false }
    }
    return quickPropertiesTool == .spotlight
  }

  /// Кнопка Lock canvas: у эталона только у Draw и Highlighter.
  var quickPropertiesSupportsCanvasLock: Bool {
    guard editorMode == .annotate, quickPropertiesSelectionAnnotations.isEmpty else { return false }
    return quickPropertiesTool == .pencil || quickPropertiesTool == .highlighter
  }

  /// Аннотации могут выходить за изображение и расширять холст: либо включена
  /// настройка «Automatically expand canvas», либо холст разблокирован кнопкой.
  var expandsCanvasBeyondImage: Bool {
    annotatePreferences.automaticallyExpandCanvas || !AnnotateCanvasLock.isLocked(defaults)
  }

  func activateTool(_ tool: AnnotationToolType) {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    if tool != .selection {
      // A selected combined-image layer must not keep its handles or consume
      // clicks after the user switches back to drawing annotations.
      deselectAnnotation()
    }
    selectedTool = tool
    onToolActivated?(tool)
  }

  func deleteSelectedAnnotation() {
    let selectedIds = selectedAnnotationIds
    guard !selectedIds.isEmpty else { return }
    DiagnosticLogger.shared.log(.debug, .annotate, "Delete annotation", context: [
      "count": "\(selectedIds.count)"
    ])
    saveState()
    let removedCounter = annotations.contains { annotation in
      guard selectedIds.contains(annotation.id), case .counter = annotation.type else { return false }
      return true
    }
    let sequenceStart = counterSequenceStart()
    annotations.removeAll { selectedIds.contains($0.id) }
    // Перенумерация входит в тот же шаг undo, что и удаление (Delete и Backspace).
    if removedCounter { renumberCounterSequence(from: sequenceStart) }
    autoSizingTextAnnotationIDs.subtract(selectedIds)
    selectedIds.forEach { freeCombineBoundsByAnnotationID.removeValue(forKey: $0) }
    pruneUnusedEmbeddedAssets()
    updateImportWarningIfNeeded()
    refreshCombineLayout()
    deselectAnnotation()
  }

  /// Commit the current text editing and exit edit mode
  func commitTextEditing() {
    guard let editingId = editingTextAnnotationId else { return }

    if let annotation = annotations.first(where: { $0.id == editingId }),
       case .text(let text) = annotation.type {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        recordTextEditingUndoIfNeeded(id: editingId, newText: trimmed)
        annotations.removeAll { $0.id == editingId }
        selectedAnnotationId = nil
        hasUnsavedChanges = true
      } else {
        updateAnnotationText(id: editingId, text: trimmed)
      }
    }
    finishTextEditing()
  }

  /// Deselect current annotation
  func deselectAnnotation() {
    setSelectedAnnotationIds([])
    finishTextEditing()
  }

  /// Nudge selected annotation by delta
  func nudgeSelectedAnnotation(dx: CGFloat, dy: CGFloat) {
    let selectedIds = selectedAnnotationIds
    guard !selectedIds.isEmpty else { return }

    saveState()
    for index in annotations.indices where selectedIds.contains(annotations[index].id) {
      translateAnnotation(at: index, dx: dx, dy: dy)
    }
  }

  private func translateAnnotations(dx: CGFloat, dy: CGFloat) {
    guard dx != 0 || dy != 0 else { return }
    for index in annotations.indices {
      translateAnnotation(at: index, dx: dx, dy: dy)
    }
  }

  private func translateAnnotation(at index: Int, dx: CGFloat, dy: CGFloat) {
    annotations[index] = annotations[index].translatedBy(dx: dx, dy: dy)
  }
}

nonisolated enum AnnotateTextLayout {
  static let horizontalPadding: CGFloat = 4
  static let verticalPadding: CGFloat = 4
  static let minWidth: CGFloat = 30
  static let minContentWidth: CGFloat = 20
  static let defaultInitialWidth: CGFloat = 200
  static let maxWidth: CGFloat = 2000
  static let maxHeight: CGFloat = 2000

  static func font(
    size: CGFloat,
    fontName: String? = nil,
    textStyle: AnnotationTextStyle = .standard
  ) -> NSFont {
    // Верхняя граница – последний пункт меню Font size эталона (288 pt).
    let clampedSize = min(max(size, 8), AnnotationProperties.fontSizeRange.upperBound)

    let baseFont: NSFont
    if let fontName,
       let namedFont = NSFont(name: fontName, size: clampedSize) {
      baseFont = namedFont
    } else {
      baseFont = NSFont.systemFont(ofSize: clampedSize)
    }

    return styledFont(baseFont, design: textStyle.fontDesign)
  }

  /// Применяет семейство стиля (Rounded, Mono) к шрифту. Конкретные гарнитуры
  /// эталона не установлены (ANN-767, ANN-769): берём системные SF Rounded и SF Mono.
  /// TODO: сверить гарнитуру и насыщенность Rounded/Mono с эталоном, данных нет.
  private static func styledFont(_ font: NSFont, design: AnnotationTextStyle.FontDesign) -> NSFont {
    let systemDesign: NSFontDescriptor.SystemDesign
    switch design {
    case .standard:
      return font
    case .rounded:
      systemDesign = .rounded
    case .monospaced:
      systemDesign = .monospaced
    }

    if let descriptor = font.fontDescriptor.withDesign(systemDesign),
       let designed = NSFont(descriptor: descriptor, size: font.pointSize) {
      return designed
    }
    // Именованный шрифт без варианта нужного дизайна – откатываемся на системный.
    if design == .monospaced {
      return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    }
    if let descriptor = NSFont.systemFont(ofSize: font.pointSize).fontDescriptor.withDesign(systemDesign),
       let designed = NSFont(descriptor: descriptor, size: font.pointSize) {
      return designed
    }
    return font
  }

  static func displayFont(
    size: CGFloat,
    fontName: String? = nil,
    textStyle: AnnotationTextStyle = .standard,
    scale: CGFloat
  ) -> NSFont {
    let baseFont = font(size: size, fontName: fontName, textStyle: textStyle)
    let displaySize = max(baseFont.pointSize * scale, 1)

    if let scaledFont = NSFont(descriptor: baseFont.fontDescriptor, size: displaySize) {
      return scaledFont
    }

    return NSFont.systemFont(ofSize: displaySize)
  }

  static func bounds(
    text: String,
    font: NSFont,
    origin: CGPoint,
    constrainedWidth: CGFloat? = nil,
    maximumHeight: CGFloat = maxHeight,
    presentation: TextPresentation = .plain
  ) -> CGRect {
    let finalWidth: CGFloat

    if let constrainedWidth = constrainedWidth {
      finalWidth = clampedWidth(constrainedWidth)
    } else {
      finalWidth = preferredAutoWidth(text: text, font: font, presentation: presentation)
    }

    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    let contentWidth = max(finalWidth - insets.width * 2, minContentWidth)
    let contentHeight = ceil(contentSize(for: text, font: font, constrainedWidth: contentWidth).height)
    let resolvedMaximumHeight = max(minimumHeight(for: font), min(maximumHeight, maxHeight))
    let finalHeight = min(max(contentHeight + insets.height * 2, minimumHeight(for: font, presentation: presentation)), resolvedMaximumHeight)

    return CGRect(
      x: origin.x,
      y: origin.y,
      width: finalWidth,
      height: finalHeight
    )
  }

  static func textRect(for text: String, font: NSFont, in bounds: CGRect, presentation: TextPresentation = .plain) -> CGRect {
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    let contentWidth = max(bounds.width - insets.width * 2, minContentWidth)
    let contentHeight = ceil(contentSize(for: text, font: font, constrainedWidth: contentWidth).height)
    let drawHeight = min(contentHeight, max(bounds.height, 0))
    let verticalInset = max((bounds.height - drawHeight) / 2, 0)

    return CGRect(
      x: bounds.minX + insets.width,
      y: bounds.minY + verticalInset,
      width: contentWidth,
      height: drawHeight
    )
  }

  static func measuredHeight(text: String, font: NSFont, constrainedWidth: CGFloat) -> CGFloat {
    bounds(
      text: text,
      font: font,
      origin: .zero,
      constrainedWidth: constrainedWidth
    ).height
  }

  static func textEditorInset(scale: CGFloat, presentation: TextPresentation = .plain, fontSize: CGFloat = 16) -> NSSize {
    let resolvedScale = max(scale, 0.0001)
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: fontSize)
    return NSSize(
      width: insets.width * resolvedScale,
      height: insets.height * resolvedScale
    )
  }

  static func clampedWidth(_ width: CGFloat, maximumWidth: CGFloat = maxWidth) -> CGFloat {
    let resolvedMaximumWidth = max(minWidth, min(maximumWidth, maxWidth))
    return min(max(width, minWidth), resolvedMaximumWidth)
  }

  static func preferredAutoWidth(
    text: String,
    font: NSFont,
    minimumWidth: CGFloat = defaultInitialWidth,
    maximumWidth: CGFloat = maxWidth,
    presentation: TextPresentation = .plain
  ) -> CGFloat {
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    let measuredWidth = ceil(singleLineSize(for: text, font: font).width) + insets.width * 2
    let resolvedMaximumWidth = max(minWidth, min(maximumWidth, maxWidth))
    let resolvedMinimumWidth = min(max(minimumWidth, minWidth), resolvedMaximumWidth)
    return min(max(measuredWidth, resolvedMinimumWidth), resolvedMaximumWidth)
  }

  static func minimumHeight(for font: NSFont, presentation: TextPresentation = .plain) -> CGFloat {
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    return ceil(font.ascender - font.descender + font.leading) + insets.height * 2
  }

  private static func singleLineSize(for text: String, font: NSFont) -> CGSize {
    (measurementText(for: text) as NSString).size(withAttributes: textAttributes(font: font))
  }

  private static func contentSize(for text: String, font: NSFont, constrainedWidth: CGFloat) -> CGSize {
    let rect = (measurementText(for: text) as NSString).boundingRect(
      with: CGSize(width: constrainedWidth, height: maxHeight),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: textAttributes(font: font)
    )
    return rect.size
  }

  private static func measurementText(for text: String) -> String {
    text.isEmpty ? " " : text
  }

  private static func textAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping

    return [
      .font: font,
      .paragraphStyle: paragraphStyle
    ]
  }
}
