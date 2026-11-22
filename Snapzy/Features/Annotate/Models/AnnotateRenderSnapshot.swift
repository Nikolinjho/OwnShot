//
//  AnnotateRenderSnapshot.swift
//  Snapzy
//
//  Immutable value-type snapshot of everything final-image rendering needs.
//

import AppKit

/// Frozen copy of every `AnnotateState` input used by `AnnotateExporter` rendering.
/// Built on the main actor (lazy caches pre-warmed, background images pre-resolved),
/// then consumed from any queue — rendering never touches live state.
///
/// Contract: the referenced `NSImage` instances are treated as immutable during render
/// (state replaces rather than mutates them post-load).
struct AnnotateRenderSnapshot {
  var sourceImage: NSImage
  var editorMode: AnnotateState.EditorMode
  var drawObjectShadow: Bool = true
  var isCombineMode: Bool
  var effectiveContentBounds: CGRect
  var cropRect: CGRect?
  /// Заливка части рамки Crop вне изображения; nil – прозрачная.
  var cropFillColor: CGColor? = nil
  var annotations: [AnnotationItem]
  var embeddedImages: [UUID: NSImage]
  var embeddedCGImages: [UUID: CGImage]
  /// Соль сетки Secure. nil – новая случайная соль на каждый рендер экспорта, как у эталона.
  /// Ноль повторяет сетку холста, остальные значения фиксируют одну сетку для повторов.
  var secureExportSalt: UInt64? = nil

  var backgroundStyle: BackgroundStyle
  var isBlurredBackgroundEffectActive: Bool
  var blurredBackgroundEffect: BlurredBackgroundEffect
  /// Wallpaper/blurred background for the active `backgroundStyle` URL, resolved on main
  /// (cache + sandbox access + blur are main-bound). Nil for `.none`/`.gradient`/preset URLs.
  var resolvedBackgroundImage: NSImage?

  var padding: CGFloat
  var cornerRadius: CGFloat
  var shadowIntensity: CGFloat
  /// Inset/Auto-balance, посчитанные на main по видимой части изображения.
  var backgroundInset: AnnotateBackgroundInsetLayout = .none
  var imageAlignment: ImageAlignment
  var aspectRatio: AspectRatioOption
  var aspectRatioOrientation: AspectRatioOrientation

  var mockupRotationX: CGFloat
  var mockupRotationY: CGFloat
  var mockupRotationZ: CGFloat
  var mockupPerspective: CGFloat
  var mockupShadowRadius: CGFloat
  var mockupShadowOffsetX: CGFloat
  var mockupShadowOffsetY: CGFloat
}
