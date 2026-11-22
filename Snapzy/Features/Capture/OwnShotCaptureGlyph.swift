import SwiftUI

struct OwnShotCaptureGlyph: View {
  enum Kind: Equatable {
    case area, fullscreen, window, scrolling, timer, ocr, recording, microphone, systemAudio, camera
  }
  let kind: Kind
  var enabled = true

  @MainActor
  var menuImage: Image {
    // Нативный Menu переносит Image в кнопку AppKit, а Canvas в его подписи исчезает.
    let renderer = ImageRenderer(content: self)
    renderer.scale = 2
    if let image = renderer.nsImage { return Image(nsImage: image) }
    return Image(systemName: kind == .microphone ? "mic" : "video")
  }

  var body: some View {
    OwnShotIcons.image(resourceName)
      .renderingMode(.template)
      // Цвет значка показывает, включён ли источник.
      .foregroundStyle(Color(nsColor: enabled ? OwnShotHUDStyle.primaryForeground : OwnShotHUDStyle.inactiveForeground))
      .frame(width: 20, height: 20)
      .accessibilityHidden(true)
  }

  private var resourceName: String {
    switch kind {
    case .area: "oneOverlayArea"
    case .fullscreen: "oneOverlayFullscreen"
    case .window: "oneOverlayWindow"
    case .scrolling: "oneOverlayScrollingCapture"
    case .timer: "oneOverlaySelfTimer"
    case .ocr: "oneOverlayOCR"
    case .recording: "oneOverlayRecord"
    case .microphone: "recorderMicrophone"
    case .systemAudio: "recorderSystemSound"
    case .camera: "recorderCamera"
    }
  }
}
