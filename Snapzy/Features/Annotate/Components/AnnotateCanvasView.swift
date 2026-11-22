//
//  AnnotateCanvasView.swift
//  Snapzy
//
//  Canvas view displaying the image with annotations
//

import SwiftUI
import UniformTypeIdentifiers

private struct AnnotateViewportMetrics: Equatable {
  let containerSize: CGSize
  let baseCanvasSize: CGSize
  let fitScale: CGFloat
}

struct AnnotateDroppedImage {
  let image: NSImage
  let data: Data?
}

enum AnnotateImageDropLoader {
  @discardableResult
  static func load(
    from provider: NSItemProvider,
    completion: @escaping (AnnotateDroppedImage?) -> Void
  ) -> Bool {
    if provider.canLoadObject(ofClass: NSImage.self) {
      provider.loadObject(ofClass: NSImage.self) { object, _ in
        guard let image = object as? NSImage else {
          completion(nil)
          return
        }
        completion(AnnotateDroppedImage(image: image, data: image.tiffRepresentation))
      }
      return true
    }

    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      return false
    }

    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
      guard error == nil, let url else {
        completion(nil)
        return
      }

      defer { try? FileManager.default.removeItem(at: url) }
      guard let data = try? Data(contentsOf: url),
            let image = NSImage(data: data) else {
        completion(nil)
        return
      }
      completion(AnnotateDroppedImage(image: image, data: data))
    }
    return true
  }
}

/// Canvas view for displaying and annotating the image
struct AnnotateCanvasView: View {
  @ObservedObject var state: AnnotateState
  let eventRouter: AnnotateWindowEventRouter
  @FocusState private var isCanvasFocused: Bool
  @State private var isDragOver = false
  /// Сторона, к которой встанет перетаскиваемое изображение (холст уже с изображением).
  @State private var dropEdge: AnnotateImageDropEdge?
  @State private var dropAreaSize: CGSize = .zero
  @State private var showDropError = false
  @State private var dropErrorMessage = ""
  @StateObject private var canvasInteractionBridge = CanvasInteractionBridge()

  /// Supported image types for drag-drop
  static let supportedImageTypes: [UTType] = [
    .png, .jpeg, .gif, .tiff, .bmp, .heic
  ]

  /// Check if any mockup transforms have been applied
  private var hasMockupTransforms: Bool {
    state.mockupRotationX != 0 ||
    state.mockupRotationY != 0 ||
    state.mockupRotationZ != 0
  }

  /// Whether to show mockup transforms (only in mockup or preview mode)
  private var shouldShowMockupTransforms: Bool {
    (state.editorMode == .mockup || state.editorMode == .preview) && hasMockupTransforms
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Background
//        Color(nsColor: .textBackgroundColor)

        if state.hasImage {
          let thickness = AnnotateCanvasScrollbar.thickness
          let rendered = CGSize(width: state.baseCanvasDisplaySize.width * state.zoomLevel,
            height: state.baseCanvasDisplaySize.height * state.zoomLevel)
          let initialHorizontal = rendered.width > geometry.size.width + 0.5
          let vertical = rendered.height > geometry.size.height - (initialHorizontal ? thickness : 0) + 0.5
          let horizontal = rendered.width > geometry.size.width - (vertical ? thickness : 0) + 0.5
          let viewport = CGSize(width: max(1, geometry.size.width - (vertical ? thickness : 0)),
            height: max(1, geometry.size.height - (horizontal ? thickness : 0)))
          // Полосы занимают место за viewport; появление полосы не меняет масштаб Fit.
          canvasContent(in: viewport, fittingSize: geometry.size)
            .frame(width: viewport.width, height: viewport.height)
            .clipped()
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay(alignment: .trailing) {
              if vertical {
                AnnotateCanvasScrollbar(state: state, vertical: true)
                  .frame(width: thickness)
                  .padding(.bottom, horizontal ? thickness : 0)
              }
            }
            .overlay(alignment: .bottom) {
              if horizontal {
                AnnotateCanvasScrollbar(state: state, vertical: false)
                  .frame(height: thickness)
                  .padding(.trailing, vertical ? thickness : 0)
              }
            }
        } else {
          // Drop zone when no image loaded
          AnnotateDropZoneView(isDragOver: $isDragOver)
            .onAppear {
              state.updateViewportMetrics(containerSize: geometry.size, baseCanvasSize: .zero, fitScale: 1.0)
            }
            .onChange(of: geometry.size) { newSize in
              state.updateViewportMetrics(containerSize: newSize, baseCanvasSize: .zero, fitScale: 1.0)
            }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onReceive(eventRouter.publisher(for: .annotateScrollZoom)) { notification in
      guard state.hasImage,
            let delta = notification.userInfo?["delta"] as? CGFloat else { return }
      let step = delta * 0.1
      withAnimation(.easeOut(duration: 0.15)) {
        state.zoomLevel = state.clampedZoom(state.zoomLevel + step)
      }
    }
    .onReceive(eventRouter.publisher(for: .annotateMagnifyZoom)) { notification in
      guard state.hasImage,
            let magnification = notification.userInfo?["magnification"] as? CGFloat else { return }
      withAnimation(.easeOut(duration: 0.1)) {
        state.zoomLevel = state.clampedZoom(state.zoomLevel + magnification)
      }
    }
    .onReceive(eventRouter.publisher(for: .annotateZoomIn)) { _ in
      guard state.hasImage else { return }
      withAnimation(.easeOut(duration: 0.15)) {
        state.zoomLevel = state.clampedZoom(state.zoomLevel + 0.25)
      }
    }
    .onReceive(eventRouter.publisher(for: .annotateZoomOut)) { _ in
      guard state.hasImage else { return }
      withAnimation(.easeOut(duration: 0.15)) {
        state.zoomLevel = state.clampedZoom(state.zoomLevel - 0.25)
      }
    }
    .onReceive(eventRouter.publisher(for: .annotateZoomReset)) { _ in
      guard state.hasImage else { return }
      withAnimation(.easeOut(duration: 0.15)) {
        state.zoomLevel = 1.0
      }
    }
    // ⌘0 эталона – 100%, а не Fit.
    .onReceive(eventRouter.publisher(for: .annotateZoomActualSize)) { _ in
      guard state.hasImage else { return }
      withAnimation(.easeOut(duration: 0.15)) {
        state.zoomLevel = state.zoomLevel(forDisplayedPercent: 100)
      }
    }
    .onReceive(eventRouter.publisher(for: .annotateSpaceDown)) { _ in
      guard state.hasImage,
            state.canPanInteractively,
            state.editingTextAnnotationId == nil else { return }
      state.isSpacePanning = true
    }
    .onReceive(eventRouter.publisher(for: .annotateSpaceUp)) { _ in
      state.isSpacePanning = false
    }
    .onReceive(eventRouter.publisher(for: .annotatePanDrag)) { notification in
      guard state.isSpacePanning || state.isCanvasPanningMode,
            let dx = notification.userInfo?["deltaX"] as? CGFloat,
            let dy = notification.userInfo?["deltaY"] as? CGFloat else { return }
      state.pan(by: CGSize(width: dx, height: dy))
    }
    .onReceive(eventRouter.publisher(for: .annotatePanScroll)) { notification in
      guard state.hasImage,
            state.canPanInteractively,
            state.editingTextAnnotationId == nil,
            let dx = notification.userInfo?["deltaX"] as? CGFloat,
            let dy = notification.userInfo?["deltaY"] as? CGFloat else { return }
      state.pan(by: CGSize(width: dx, height: dy))
    }
    .onChange(of: state.zoomLevel) { _ in
      state.resetPanIfNeeded()
    }
    .onChange(of: state.importWarningMessage) { message in
      guard let message else { return }
      showError(message)
      state.consumeImportWarningMessage()
    }
    .overlay {
      if state.hasImage, isDragOver, let dropEdge {
        AnnotateImageDropZoneOverlay(edge: dropEdge)
          .allowsHitTesting(false)
      }
    }
    .background(GeometryReader { proxy in
      Color.clear.preference(key: AnnotateDropAreaSizeKey.self, value: proxy.size)
    })
    .onPreferenceChange(AnnotateDropAreaSizeKey.self) { dropAreaSize = $0 }
    .onDrop(of: [.fileURL, .image], delegate: AnnotateImageDropDelegate(
      areaSize: dropAreaSize,
      hasImage: state.hasImage,
      isDragOver: $isDragOver,
      edge: $dropEdge,
      perform: { providers, edge in handleDrop(providers: providers, edge: edge) }
    ))
    .focusable()
    .modifier(FocusEffectDisabledModifier())
    .focused($isCanvasFocused)
    .background(
      KeyEventHandlerView { char in
        handleToolShortcutChar(char)
      }
    )
    .onAppear {
      isCanvasFocused = true
    }
    .overlay(alignment: .bottom) {
      if showDropError {
        dropErrorBanner
      }
    }
  }

  /// Error banner for invalid file drops
  private var dropErrorBanner: some View {
    Text(dropErrorMessage)
      .font(.callout)
      .foregroundColor(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Color.red.opacity(0.9))
      .cornerRadius(Radius.card)
      .padding(.bottom, 20)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .animation(.easeInOut(duration: 0.3), value: showDropError)
  }

  /// Show error message temporarily
  private func showError(_ message: String) {
    Task { @MainActor in
      dropErrorMessage = message
      withAnimation {
        showDropError = true
      }
      try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
      withAnimation {
        showDropError = false
      }
    }
  }

  private func canvasContent(in containerSize: CGSize, fittingSize: CGSize) -> some View {
    let margin: CGFloat = 40
    let availableWidth = max(fittingSize.width - margin * 2, 1)
    let availableHeight = max(fittingSize.height - margin * 2, 1)

    // Use effective values for smooth preview during slider drag
    let currentPadding = state.effectivePadding

    // Calculate alignment space needed for non-center alignments
    // This expands the background to allow image movement
    let alignmentSpace: CGFloat = state.imageAlignment != .center ? 40 : 0

    let imageBounds = state.sourceImageBounds
    let combineBounds = state.effectiveContentBounds
    let cropBounds = state.cropRect?.standardized

    let fitBounds: CGRect
    if state.isCombineMode {
      fitBounds = combineBounds
    } else if let cropBounds, !state.isCropActive {
      fitBounds = cropBounds
    } else {
      fitBounds = state.effectiveContentBounds
    }

    // Scale is tied to the currently fitted image/crop, not to the live crop rect.
    // This keeps crop dimensions predictable while users drag handles outward.
    let fitInsetEdges = state.backgroundInsetLayout(for: fitBounds).edges
    let fitLogicalCanvasSize = state.isCombineMode
      ? CGSize(width: fitBounds.width + currentPadding * 2, height: fitBounds.height + currentPadding * 2)
      : state.aspectRatio.canvasSize(
        for: fitInsetEdges.expandedSize(fitBounds.size),
        padding: currentPadding,
        alignmentSpace: alignmentSpace,
        orientation: state.aspectRatioOrientation
      )
    let scaleX = availableWidth / fitLogicalCanvasSize.width
    let scaleY = availableHeight / fitLogicalCanvasSize.height
    let scale = min(scaleX, scaleY, 1.0)

    let foregroundBounds: CGRect
    if state.isCombineMode {
      foregroundBounds = combineBounds
    } else if let cropBounds {
      if state.isCropActive {
        foregroundBounds = cropWorkspaceBounds(
          for: imageBounds,
          availableSize: CGSize(width: availableWidth, height: availableHeight),
          scale: scale
        )
      } else {
        foregroundBounds = cropBounds
      }
    } else {
      foregroundBounds = state.effectiveContentBounds
    }

    // Inset: изображение лежит в карточке, карточка выравнивается внутри фона.
    let insetLayout = state.backgroundInsetLayout(for: foregroundBounds)
    let insetEdges = insetLayout.edges
    let logicalCanvasSize = state.isCombineMode
      ? CGSize(width: foregroundBounds.width + currentPadding * 2, height: foregroundBounds.height + currentPadding * 2)
      : state.aspectRatio.canvasSize(
        for: insetEdges.expandedSize(foregroundBounds.size),
        padding: currentPadding,
        alignmentSpace: alignmentSpace,
        orientation: state.aspectRatioOrientation
      )

    // Background = logical canvas * scale (includes padding + alignment space)
    let bgWidth = logicalCanvasSize.width * scale
    let bgHeight = logicalCanvasSize.height * scale
    let viewportMetrics = AnnotateViewportMetrics(
      containerSize: containerSize,
      baseCanvasSize: CGSize(width: bgWidth, height: bgHeight),
      fitScale: scale
    )

    let foregroundWidth = foregroundBounds.width * scale
    let foregroundHeight = foregroundBounds.height * scale
    let cardDisplaySize = CGSize(
      width: (foregroundBounds.width + insetEdges.horizontal) * scale,
      height: (foregroundBounds.height + insetEdges.vertical) * scale
    )
    let cardOffset = state.isCombineMode ? .zero : state.imageOffset(
      for: CGSize(width: bgWidth, height: bgHeight),
      imageDisplaySize: cardDisplaySize,
      displayPadding: currentPadding * scale
    )
    // В SwiftUI ось Y направлена вниз: смещение изображения внутри карточки.
    let offset = CGPoint(
      x: cardOffset.x + (insetEdges.left - insetEdges.right) / 2 * scale,
      y: cardOffset.y + (insetEdges.top - insetEdges.bottom) / 2 * scale
    )

    return ZStack {
      // Scaled content group
      ZStack {
        // Background layer (scaled canvas with padding) - NOT transformed
        backgroundLayer(width: bgWidth, height: bgHeight)

        if insetLayout.drawsCard {
          insetCardLayer(layout: insetLayout, size: cardDisplaySize, scale: scale,
            shadowClip: AnnotateCanvasShadowClip(backgroundSize: CGSize(width: bgWidth, height: bgHeight),
              centerOffset: cardOffset))
            .offset(x: cardOffset.x, y: cardOffset.y)
        }

        // GROUP: Image + Annotations (transformed together in mockup mode)
        Group {
          sourceImageLayer(visibleBounds: foregroundBounds, scale: scale, insetLayout: insetLayout,
            shadowClip: AnnotateCanvasShadowClip(backgroundSize: CGSize(width: bgWidth, height: bgHeight),
              centerOffset: offset))

          CanvasDrawingView(
            state: state,
            displayScale: scale,
            canvasBounds: foregroundBounds,
            interactionBridge: canvasInteractionBridge
          )
          .frame(width: foregroundWidth, height: foregroundHeight)

          // Text editing overlay (when editing a text annotation)
          if state.editingTextAnnotationId != nil {
            TextEditOverlay(
              state: state,
              scale: scale,
              canvasBounds: foregroundBounds,
              interactionBridge: canvasInteractionBridge
            )
            .frame(width: foregroundWidth, height: foregroundHeight)
            .clipped()
          }
        }
        .offset(x: offset.x, y: offset.y)
        .modifier(MockupTransformModifier(state: state, isEnabled: shouldShowMockupTransforms))

        // Crop overlay - ONLY shown during active crop editing (NOT when crop is just applied)
        // This prevents CropSolidMask from covering the gradient/wallpaper background
        if state.selectedTool == .crop && state.isCropActive {
          CropOverlayView(
            state: state,
            scale: scale,
            canvasBounds: foregroundBounds
          )
          .frame(width: foregroundWidth, height: foregroundHeight)
          .offset(x: offset.x, y: offset.y)
        }

        // Cut out overlay - strip highlight + size badge while the tool is active.
        if state.selectedTool == .cutOut && state.isCutOutActive {
          CutOutOverlayView(
            state: state,
            scale: scale,
            canvasBounds: foregroundBounds
          )
          .frame(width: foregroundWidth, height: foregroundHeight)
          .offset(x: offset.x, y: offset.y)
        }
      }
      .frame(width: bgWidth, height: bgHeight)
      .modifier(CombineCanvasClipModifier(
        isEnabled: state.isCombineMode,
        cornerRadius: AnnotateBackgroundCorners.radius(forSlider: state.effectiveCornerRadius) * scale
      ))
      .scaleEffect(state.zoomLevel)
      .offset(x: state.panOffset.width, y: state.panOffset.height)
      // AppKit conversion exposes the layout transform, not a Core Animation
      // presentation transform. Apply zoom atomically so a pointer cannot be
      // mapped through a completed transform while pixels are mid-animation.
      .animation(nil, value: state.zoomLevel)

      // Keep AppKit input aligned with the transformed visual footprint. SwiftUI
      // scales the canvas layer but leaves the representable's hit frame at its
      // fit size, which otherwise makes portions of a zoomed tall capture inert.
      // Native text input is registered with the bridge and receives priority
      // within its transformed bounds. Perspective mockups have non-rectangular
      // projected bounds, so the rectangular proxy yields to their existing interaction
      // path rather than accepting clicks in visually empty corners.
      if !shouldShowMockupTransforms {
        CanvasInteractionProxy(bridge: canvasInteractionBridge)
          .frame(width: containerSize.width, height: containerSize.height)
      }
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button {
        state.extractText()
      } label: {
        Label(L10n.AnnotateUI.extractText, systemImage: "text.viewfinder")
      }
      .disabled(!state.canExtractText)
    }
    .onAppear {
      state.updateViewportMetrics(
        containerSize: viewportMetrics.containerSize,
        baseCanvasSize: viewportMetrics.baseCanvasSize,
        fitScale: viewportMetrics.fitScale
      )
    }
    .onChange(of: viewportMetrics) { newMetrics in
      state.updateViewportMetrics(
        containerSize: newMetrics.containerSize,
        baseCanvasSize: newMetrics.baseCanvasSize,
        fitScale: newMetrics.fitScale
      )
    }
  }

  private func cropWorkspaceBounds(for imageBounds: CGRect, availableSize: CGSize, scale: CGFloat) -> CGRect {
    let normalizedScale = max(scale, 0.0001)
    let minimumZoom = max(AnnotateState.minimumZoomLevel, 0.0001)
    let visibleWidthAtMinimumZoom = availableSize.width / (normalizedScale * minimumZoom)
    let visibleHeightAtMinimumZoom = availableSize.height / (normalizedScale * minimumZoom)
    let workspaceWidth = max(imageBounds.width * 3, visibleWidthAtMinimumZoom)
    let workspaceHeight = max(imageBounds.height * 3, visibleHeightAtMinimumZoom)

    return CGRect(
      x: imageBounds.midX - workspaceWidth / 2,
      y: imageBounds.midY - workspaceHeight / 2,
      width: workspaceWidth,
      height: workspaceHeight
    ).standardized
  }

  // MARK: - Background Layer

  @ViewBuilder
  private func backgroundLayer(width: CGFloat, height: CGFloat) -> some View {
    let currentShadowIntensity = state.effectiveShadowIntensity

    Group {
      switch state.backgroundStyle {
      case .none:
        EmptyView()

      case .gradient(let preset):
        GradientPresetFill(preset: preset)
          .frame(width: width, height: height)
          .shadow(
            color: .black.opacity(currentShadowIntensity),
            radius: 20,
            x: 0,
            y: 10
          )

      case .wallpaper(let url):
        // Check if this is a preset wallpaper
        if url.scheme == "preset", let presetName = url.host,
           let preset = WallpaperPreset(rawValue: presetName) {
          Rectangle()
            .fill(preset.gradient)
            .frame(width: width, height: height)
            .shadow(
              color: .black.opacity(currentShadowIntensity),
              radius: 20,
              x: 0,
              y: 10
            )
        } else {
          wallpaperLayer(url: url, width: width, height: height)
        }

      case .blurred(let url):
        if url.scheme == "preset" {
          EmptyView()
        } else {
          wallpaperLayer(url: url, width: width, height: height, forceBlurred: true)
        }

      case .solidColor(let color):
        solidColorLayer(color, width: width, height: height)
          .shadow(
            color: .black.opacity(currentShadowIntensity),
            radius: 20,
            x: 0,
            y: 10
          )
      }
    }
    .drawingGroup() // Rasterize to Metal texture for performance
  }

  @ViewBuilder
  private func wallpaperLayer(
    url: URL,
    width: CGFloat,
    height: CGFloat,
    forceBlurred: Bool = false
  ) -> some View {
    let shouldBlur = forceBlurred || state.isBlurredBackgroundEffectActive

    if shouldBlur, let nsImage = state.cachedBlurredBackgroundImage(for: url) {
      blurredImageLayer(nsImage, width: width, height: height, appliesLiveEffect: false)
    } else if shouldBlur, let nsImage = state.cachedBackgroundImage(for: url) {
      blurredImageLayer(nsImage, width: width, height: height, appliesLiveEffect: true)
    } else if let nsImage = state.cachedBackgroundImage(for: url) {
      Image(nsImage: nsImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: width, height: height)
        .clipped()
    }
  }

  private func solidColorLayer(
    _ color: Color,
    width: CGFloat,
    height: CGFloat
  ) -> some View {
    let effect = state.isBlurredBackgroundEffectActive ? state.blurredBackgroundEffect : nil
    return Rectangle()
      .fill(color)
      .frame(width: width, height: height)
      .brightness(effect?.brightness ?? 0)
      .overlay((effect?.tintColor ?? .clear).opacity(effect?.tintOpacity ?? 0))
  }

  @ViewBuilder
  private func blurredImageLayer(
    _ nsImage: NSImage,
    width: CGFloat,
    height: CGFloat,
    appliesLiveEffect: Bool
  ) -> some View {
    let effect = state.blurredBackgroundEffect

    if appliesLiveEffect {
      Image(nsImage: nsImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: width, height: height)
        .blur(radius: effect.blurRadius)
        .saturation(effect.saturation)
        .brightness(effect.brightness)
        .overlay(effect.tintColor.opacity(effect.tintOpacity))
        .clipped()
    } else {
      Image(nsImage: nsImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: width, height: height)
        .overlay(effect.tintColor.opacity(effect.tintOpacity))
        .clipped()
    }
  }

  // MARK: - Image Layer

  /// Карточка Inset: заливка цветом края изображения, тень и скругление холста.
  /// Радиус угла холста в точках экрана: слайдер Corners пересчитан в пункты снимка
  /// и умножен на масштаб превью, как в экспорте (ANN-289).
  private func canvasCornerRadius(scale: CGFloat) -> CGFloat {
    AnnotateBackgroundCorners.radius(forSlider: state.effectiveCornerRadius) * scale
  }

  private func insetCardLayer(layout: AnnotateBackgroundInsetLayout, size: CGSize, scale: CGFloat,
    shadowClip: AnnotateCanvasShadowClip? = nil) -> some View {
    let cornerRadius = canvasCornerRadius(scale: scale)
    return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill((layout.fillColor ?? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)).color)
      .frame(width: size.width, height: size.height)
      .background(AnnotateCanvasShadowLayer(size: size, cornerRadius: cornerRadius,
        intensity: state.effectiveShadowIntensity, scale: scale, clip: shadowClip))
  }

  @ViewBuilder
  private func sourceImageLayer(
    visibleBounds: CGRect,
    scale: CGFloat,
    insetLayout: AnnotateBackgroundInsetLayout = .none,
    shadowClip: AnnotateCanvasShadowClip? = nil
  ) -> some View {
    // С карточкой Inset тень у карточки, а изображение скруглено концентрично.
    let currentCornerRadius = insetLayout.drawsCard
      ? max(canvasCornerRadius(scale: scale) - insetLayout.edges.minimum * scale, 0)
      : canvasCornerRadius(scale: scale)
    let currentShadowIntensity = insetLayout.drawsCard ? 0 : state.effectiveShadowIntensity
    let imageBounds = state.sourceImageBounds
    let imageOffset = displayOffset(for: imageBounds, in: visibleBounds, scale: scale)

    if let sourceImage = state.effectiveSourceImage {
      ZStack {
        // Background color рамки Crop: заливка под изображением на всю рамку,
        // видна там, где рамка выходит за изображение (как в экспорте).
        if !state.isCombineMode, let fill = state.cropFillColor, let crop = state.cropRect?.standardized {
          let fillOffset = displayOffset(for: crop, in: visibleBounds, scale: scale)
          Rectangle()
            .fill(Color(nsColor: fill))
            .frame(width: crop.width * scale, height: crop.height * scale)
            .offset(x: fillOffset.x, y: fillOffset.y)
        }
        Image(nsImage: sourceImage)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: imageBounds.width * scale, height: imageBounds.height * scale)
          .offset(x: imageOffset.x, y: imageOffset.y)
      }
        .frame(width: visibleBounds.width * scale, height: visibleBounds.height * scale)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
        // Без фона остаётся прежняя короткая тень, с фоном – двухслойная тень эталона (ANN-288).
        .shadow(
          color: .black.opacity(state.backgroundStyle == .none ? currentShadowIntensity : 0),
          radius: 3,
          x: 0,
          y: 2
        )
        .background {
          if state.backgroundStyle != .none {
            AnnotateCanvasShadowLayer(
              size: CGSize(width: visibleBounds.width * scale, height: visibleBounds.height * scale),
              cornerRadius: currentCornerRadius,
              intensity: currentShadowIntensity,
              scale: scale,
              clip: shadowClip
            )
          }
        }
    }
  }

  private func displayOffset(for contentBounds: CGRect, in visibleBounds: CGRect, scale: CGFloat) -> CGPoint {
    return CGPoint(
      x: (contentBounds.midX - visibleBounds.midX) * scale,
      y: (visibleBounds.midY - contentBounds.midY) * scale
    )
  }

  // MARK: - Drag and Drop

  // MARK: - Keyboard Shortcuts

  /// Handle tool switching keyboard shortcuts (macOS 13+ compatible)
  private func handleToolShortcutChar(_ char: Character) {
    // Skip if no image loaded
    guard state.hasImage else { return }

    let lowered = Character(String(char).lowercased())

    // Crop mode owns `A` (auto-crop to content) even if the user bound it to a
    // tool — mirrors the keyDown path in AnnotateCanvasDrawingView.
    if state.isCropInteractionActive, lowered == "a" {
      Task { @MainActor in
        await state.autoCropToContent()
      }
      return
    }

    if lowered == "b", AnnotateShortcutManager.shared.tool(for: lowered) == nil,
       AnnotateShortcutManager.shared.toggleSidebarShortcut == AnnotateShortcutManager.defaultToggleSidebar {
      state.showSidebar = true
      return
    }

    // Look up tool for this key
    guard let tool = AnnotateShortcutManager.shared.tool(for: lowered) else { return }

    if tool == .crop {
      state.beginCropInteraction()
    } else if tool == .cutOut {
      state.beginCutOutInteraction()
    } else {
      // Commit any active text edit before switching
      if state.editingTextAnnotationId != nil {
        state.commitTextEditing()
      }

      // Deselect active annotation when switching tools
      state.selectedAnnotationId = nil
      state.activateTool(tool)
    }
  }

  /// Handle dropped image files
  private func handleDrop(providers: [NSItemProvider], edge: AnnotateImageDropEdge? = nil) -> Bool {
    for provider in providers {
      let didAccept = AnnotateImageDropLoader.load(from: provider) { droppedImage in
        guard let droppedImage else {
          Task { @MainActor in
            showError("Failed to load image data")
          }
          return
        }

        Task { @MainActor in
          let imported = if let edge {
            state.importImage(droppedImage.image, sourceData: droppedImage.data, placingOn: edge)
          } else {
            state.importImage(droppedImage.image, sourceURL: nil, sourceData: droppedImage.data)
          }
          if !imported {
            showError("Failed to import image")
          }
        }
        return
      }
      if didAccept { return true }
    }

    // No valid provider found
    showError("Unsupported file type")
    return false
  }

  /// Validate file is a supported image format
  static func isValidImageFile(url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else {
      return false
    }
    return supportedImageTypes.contains { type.conforms(to: $0) }
  }
}

/// Фон холста относительно силуэта: тень, как в экспорте, обрезается краем фона.
private struct AnnotateCanvasShadowClip {
  let backgroundSize: CGSize
  /// Центр силуэта минус центр фона в точках экрана (ось Y вниз).
  let centerOffset: CGPoint
}

/// Тень холста в превью: те же два слоя, что и в экспорте, только снаружи силуэта,
/// поэтому прозрачные пиксели снимка тень не заливает.
private struct AnnotateCanvasShadowLayer: View {
  let size: CGSize
  let cornerRadius: CGFloat
  let intensity: CGFloat
  let scale: CGFloat
  var clip: AnnotateCanvasShadowClip?

  var body: some View {
    let margin = AnnotateCanvasShadowProfile.extent * scale
    if intensity > 0, size.width > 0, size.height > 0 {
      Canvas { context, canvasSize in
        let rect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let silhouette = Path(AnnotateBackgroundCorners.path(in: rect, radius: cornerRadius))
        var outside = Path(CGRect(origin: .zero, size: canvasSize))
        outside.addPath(silhouette)
        context.clip(to: outside, style: FillStyle(eoFill: true))
        if let clip {
          context.clip(to: Path(CGRect(
            x: canvasSize.width / 2 - clip.centerOffset.x - clip.backgroundSize.width / 2,
            y: canvasSize.height / 2 - clip.centerOffset.y - clip.backgroundSize.height / 2,
            width: clip.backgroundSize.width, height: clip.backgroundSize.height)))
        }
        for layer in AnnotateCanvasShadowProfile.layers {
          var layerContext = context
          layerContext.addFilter(.shadow(color: .black.opacity(min(1, layer.opacity * intensity)),
            radius: layer.sigma * scale, x: 0, y: layer.offsetY * scale, options: .shadowOnly))
          layerContext.fill(silhouette, with: .color(.black))
        }
      }
      .frame(width: size.width + margin * 2, height: size.height + margin * 2)
      .allowsHitTesting(false)
    }
  }
}

private struct CombineCanvasClipModifier: ViewModifier {
  let isEnabled: Bool
  let cornerRadius: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      content
    }
  }
}



// MARK: - Focus Effect Disabled Modifier (macOS 13 compat)

/// Wraps `.focusEffectDisabled()` which is only available on macOS 14+
private struct FocusEffectDisabledModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.focusEffectDisabled()
    } else {
      content
    }
  }
}

// MARK: - Key Event Handler (macOS 13 compat, replaces .onKeyPress)

/// NSViewRepresentable that intercepts keyboard events via AppKit for macOS 13 compatibility
struct KeyEventHandlerView: NSViewRepresentable {
  let onKey: (Character) -> Void

  func makeNSView(context: Context) -> KeyEventNSView {
    KeyEventNSView(onKey: onKey)
  }

  func updateNSView(_ nsView: KeyEventNSView, context: Context) {
    nsView.onKey = onKey
  }
}

final class KeyEventNSView: NSView {
  var onKey: (Character) -> Void
  private var windowObserver: NSObjectProtocol?

  init(onKey: @escaping (Character) -> Void) {
    self.onKey = onKey
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Remove old observer
    if let obs = windowObserver {
      NotificationCenter.default.removeObserver(obs)
      windowObserver = nil
    }

    guard let window = window else { return }

    // Grab first responder on initial attach
    DispatchQueue.main.async { [weak self] in
      self?.window?.makeFirstResponder(self)
    }

    // Watch for first responder changes — reclaim when focus goes
    // to a generic view (not DrawingCanvasNSView or text editor)
    windowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didUpdateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.reclaimFirstResponderIfNeeded()
    }
  }

  /// Reclaim first responder if no important view holds it
  private func reclaimFirstResponderIfNeeded() {
    guard let window = window else { return }
    let current = window.firstResponder

    // Already the first responder — nothing to do
    if current === self { return }

    // DrawingCanvasNSView has focus — it handles shortcuts too, leave it
    if current is DrawingCanvasNSView { return }

    // A text view has focus (e.g. TextEditor) — leave it for typing
    if current is NSTextView { return }

    // Generic view has focus (e.g. clicked empty area) — reclaim
    window.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    // Bare keys only — ⌘ combos are handled by AnnotateWindow.performKeyEquivalent.
    guard !event.modifierFlags.contains(.command),
          let chars = event.charactersIgnoringModifiers, let char = chars.first else {
      super.keyDown(with: event)
      return
    }
    onKey(char)
  }

  deinit {
    if let obs = windowObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }
}
