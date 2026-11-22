import AppKit
import SwiftUI

nonisolated enum OwnShotDeferredFeature: String, CaseIterable {
  case studio = "Studio"
  case cloud = "Cloud"

  var message: String {
    switch self {
    case .studio: return "Studio is coming later. Screen recording and local MP4/GIF export are available."
    case .cloud: return "Cloud is coming later. Files stay on this Mac."
    }
  }
}

nonisolated struct OwnShotFeatureUnavailable: LocalizedError {
  let feature: OwnShotDeferredFeature
  var errorDescription: String? { feature.message }
}

nonisolated enum OwnShotFeaturePolicy {
  static func isAvailable(_ feature: OwnShotDeferredFeature) -> Bool { false }

  static func require(_ feature: OwnShotDeferredFeature) throws {
    guard isAvailable(feature) else { throw OwnShotFeatureUnavailable(feature: feature) }
  }

  @MainActor
  static func allow(_ feature: OwnShotDeferredFeature) -> Bool {
    guard isAvailable(feature) else {
      OwnShotPlaceholderPresenter.shared.show(feature)
      return false
    }
    return true
  }
}

struct OwnShotFeaturePlaceholder: View {
  let feature: OwnShotDeferredFeature

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: feature == .cloud ? "icloud" : "film.stack")
        .font(.system(size: 40)).foregroundStyle(.secondary)
      Text("OwnShot \(feature.rawValue)").font(.title2.bold())
      Text("Coming later").font(.headline)
      Text(feature.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

@MainActor
final class OwnShotPlaceholderPresenter {
  static let shared = OwnShotPlaceholderPresenter()
  private var windows: [OwnShotDeferredFeature: NSWindow] = [:]

  func show(_ feature: OwnShotDeferredFeature) {
    // Тестовый хост не открывает окна и не забирает фокус.
    guard !AppLaunchPolicy().isRunningUnderXCTest else { return }
    let window: NSWindow
    if let existing = windows[feature] {
      window = existing
    } else {
      window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "OwnShot \(feature.rawValue)"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: OwnShotFeaturePlaceholder(feature: feature))
      window.center()
      windows[feature] = window
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
