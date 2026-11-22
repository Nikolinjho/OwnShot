//
//  QuickAccessMediaInfo.swift
//  Snapzy
//
//  Сведения о записи для инфо-плашки карточки
//

import AVFoundation

enum QuickAccessMediaInfo {
  /// true, если в файле есть звуковая дорожка
  static func hasAudioTrack(_ url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
    return !tracks.isEmpty
  }
}
