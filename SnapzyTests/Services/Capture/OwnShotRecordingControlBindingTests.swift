import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Snapzy

@MainActor
struct OwnShotRecordingControlBindingTests {
  @Test("Чтение процентов GIF сохраняет старое дробное качество без округления",
    arguments: [0.0, 0.125, 0.375, 0.999, 1.0])
  func readingPercentagePreservesStoredFraction(quality: Double) throws {
    let name = "ownshot.recording.bindings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let key = OwnShotRecordingPreferenceKeys.gifQuality
    defaults.set(quality, forKey: key)
    let stored = Binding<Double>(get: { defaults.double(forKey: key) },
      set: { defaults.set($0, forKey: key) })
    let control = OwnShotRecordingPreferences.percentageBinding(stored)

    #expect(abs(control.wrappedValue - quality * 100) < 0.0000001)
    #expect(defaults.double(forKey: key) == quality)
    #expect(OwnShotRecordingPreferences.gifOptions(defaults: defaults).quality == quality)
  }

  @Test("Дробные проценты GIF сохраняются в прежнем диапазоне и доходят до квантования",
    arguments: [0.0, 12.5, 37.5, 99.9, 100.0])
  func writingPercentagePreservesEncoderQuality(percent: Double) throws {
    let name = "ownshot.recording.bindings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let key = OwnShotRecordingPreferenceKeys.gifQuality
    let stored = Binding<Double>(get: { defaults.double(forKey: key) },
      set: { defaults.set($0, forKey: key) })
    let control = OwnShotRecordingPreferences.percentageBinding(stored)
    control.wrappedValue = percent

    let normalized = percent / 100
    #expect(abs(defaults.double(forKey: key) - normalized) < 0.0000001)
    #expect(abs(control.wrappedValue - percent) < 0.0000001)
    let options = OwnShotRecordingPreferences.gifOptions(defaults: defaults)
    #expect(abs(options.quality - normalized) < 0.0000001)
    let image = try sampleImage()
    let actual = try #require(GIFFrameProcessing.quantized(image, quality: options.quality))
    let previous = try #require(GIFFrameProcessing.quantized(image, quality: normalized))
    #expect(actual.dataProvider?.data as Data? == previous.dataProvider?.data as Data?)
  }

  private func sampleImage() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
      bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    context.setFillColor(CGColor(red: 0.17, green: 0.73, blue: 0.39, alpha: 1))
    context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    return try #require(context.makeImage())
  }
}
