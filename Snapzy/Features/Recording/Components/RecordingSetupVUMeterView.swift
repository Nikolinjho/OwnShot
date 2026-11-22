//
//  RecordingSetupVUMeterView.swift
//  Snapzy
//
//  Полоска уровня под глифом кнопки микрофона или системного звука,
//  как levelLayer у AudioToggleButton эталона.
//

import SwiftUI

struct RecordingSetupVUMeterView: View {
  @ObservedObject var meter: RecordingAudioLevelMeter
  var isEnabled: Bool

  static let width: CGFloat = 18
  static let height: CGFloat = 2

  /// Ширина заполнения, уровень зажат в 0...1.
  static func fillWidth(level: Float) -> CGFloat {
    width * CGFloat(max(0, min(1, level)))
  }

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(.white.opacity(0.15))
      Capsule()
        .fill(.white)
        .frame(width: Self.fillWidth(level: meter.level))
        .animation(.linear(duration: 0.08), value: meter.level)
    }
    .frame(width: Self.width, height: Self.height)
    .opacity(isEnabled ? 1 : 0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
