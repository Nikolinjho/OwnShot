import AppKit
import Foundation

struct OwnShotAutomationRequest: Equatable {
  static let fileCommands: Set<String> = ["pin", "open-annotate", "add-quick-access-overlay"]

  let command: String
  let bounds: CGRect?
  let display: Int?
  let fileURL: URL?
  let action: String?
  let language: String?
  let mode: String?
  let preserveBreaks: Bool?
  let startImmediately: Bool
  let autoScroll: Bool

  var remembersArea: Bool {
    command != "capture-fullscreen" && !(command == "self-timer" && mode == "fullscreen" && bounds == nil)
  }

  init?(command: String, components: URLComponents?) {
    self.command = command
    let items = components?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
    let coordinateNames = ["x", "y", "width", "height"]
    if coordinateNames.contains(where: { name in items.contains(where: { $0.name.lowercased() == name }) }) {
      let coordinates = coordinateNames.compactMap { value($0).flatMap(Double.init) }
      guard coordinates.count == 4, coordinates.allSatisfy(\.isFinite), coordinates[2] > 0, coordinates[3] > 0 else { return nil }
      bounds = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
    } else if let raw = value("bounds") {
      let parts = raw.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
      guard parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 else { return nil }
      bounds = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    } else { bounds = nil }
    if let raw = value("display") {
      guard let number = Int(raw), number >= 1 else { return nil }
      display = number
    } else { display = nil }
    if (Self.fileCommands.contains(command) || command == "capture-text"),
       let path = value("filepath"), !path.isEmpty {
      if let url = URL(string: path), url.isFileURL { fileURL = url.standardizedFileURL }
      else {
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
      }
    } else { fileURL = nil }
    func flag(_ name: String) -> Bool? {
      guard let raw = value(name)?.lowercased() else { return false }
      if ["true", "1", "yes"].contains(raw) { return true }
      if ["false", "0", "no"].contains(raw) { return false }
      return nil
    }
    guard let start = flag("start"), let scrolling = flag("autoscroll") else { return nil }
    startImmediately = start
    autoScroll = scrolling
    action = value("action")?.lowercased()
    language = value("language")
    mode = value("mode")?.lowercased()
    preserveBreaks = (value("linebreaks") ?? value("breaks")).map {
      !["false", "0", "no"].contains($0.lowercased())
    }
  }

  @MainActor func resolvedRect(screens: [NSScreen] = NSScreen.screens, mouseLocation: CGPoint = NSEvent.mouseLocation) -> CGRect? {
    resolvedArea(screens: screens, mouseLocation: mouseLocation)?.rect
  }

  @MainActor func resolvedArea(
    screens: [NSScreen] = NSScreen.screens, mouseLocation: CGPoint = NSEvent.mouseLocation
  ) -> (screen: NSScreen, rect: CGRect)? {
    guard let area = resolvedGeometry(screenFrames: screens.map(\.frame), mouseLocation: mouseLocation) else { return nil }
    return (screens[area.screenIndex], area.rect)
  }

  func resolvedRect(screenFrames: [CGRect], mouseLocation: CGPoint) -> CGRect? {
    resolvedGeometry(screenFrames: screenFrames, mouseLocation: mouseLocation)?.rect
  }

  /// display=1 — основной экран. Без display, по контракту эталона, экран под курсором.
  private func resolvedGeometry(screenFrames: [CGRect], mouseLocation: CGPoint)
    -> (screenIndex: Int, rect: CGRect)? {
    let index: Int
    if let display {
      index = display - 1
    } else {
      index = screenFrames.firstIndex { $0.contains(mouseLocation) } ?? 0
    }
    guard screenFrames.indices.contains(index) else { return nil }
    let frame = screenFrames[index]
    guard let bounds else { return (index, frame) }
    let rect = bounds.offsetBy(dx: frame.minX, dy: frame.minY)
    guard frame.contains(rect) else { return nil }
    return (index, rect)
  }
}
