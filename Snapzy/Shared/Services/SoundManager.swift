//
//  SoundManager.swift
//  Snapzy
//
//  Centralized sound playback gated by the user's "Play Sounds" preference
//

import AppKit

/// Gates all sound playback on the `playSounds` user preference.
enum SoundManager {
  static let screenshotSoundKey = "ownshot.capture.shutterSound"
  static let shutterSoundNames = ["System Default", "Classic", "Pop", "Subtle", "8-Bit"]

  static func selectedScreenshotSound(defaults: UserDefaults = .standard) -> String {
    let stored = defaults.string(forKey: screenshotSoundKey) ?? "System Default"
    return normalizedScreenshotSound(stored)
  }

  static func normalizedScreenshotSound(_ stored: String) -> String {
    let name = ["Glass": "Classic", "Funk": "8-Bit", "Tink": "Subtle", "Submarine": "Subtle"][stored] ?? stored
    return shutterSoundNames.contains(name) ? name : "System Default"
  }

  private static let fallbackScreenshotSoundName = "Glass"
  private static let screenshotSoundTemplate: NSSound? = {
    let candidatePaths = [
      // Current macOS native screenshot sound.
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
      // Legacy fallback present on older systems.
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
    ]

    for path in candidatePaths {
      let url = URL(fileURLWithPath: path)
      if let sound = NSSound(contentsOf: url, byReference: true) {
        return sound
      }
    }

    return nil
  }()

  private static var soundsEnabled: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.playSounds) as? Bool ?? true
  }

  /// Play a named system sound only if the user hasn't disabled sounds.
  /// - Parameter name: System sound name (e.g. "Glass", "Pop", "Funk")
  static func play(_ name: String) {
    guard soundsEnabled else { return }
    NSSound(named: name)?.play()
  }

  enum RecordingSound: String, CaseIterable {
    case start = "Tink"
    case stop = "Pop"
    case pause = "Purr"
    case countdown = "Morse"
  }

  /// События записи используют системные звуки и общую настройку Play Sounds.
  static func play(_ sound: RecordingSound) {
    play(sound.rawValue)
  }

  /// Play the closest available native macOS screenshot sound.
  static func playScreenshotCapture() {
    guard soundsEnabled else { return }

    let selected = selectedScreenshotSound()
    if selected == "Pop" { play("Pop"); return }
    if selected != "System Default" {
      if let sound = NSSound(data: shutterSoundData(named: selected)) { sound.play() }
      return
    }

    if let sound = screenshotSoundTemplate?.copy() as? NSSound, sound.play() {
      return
    }

    play(fallbackScreenshotSoundName)
  }

  /// Короткие собственные звуки. Не зависят от набора системных аудиофайлов.
  static func shutterSoundData(named name: String) -> Data {
    let rate = 22050
    let duration = name == "Subtle" ? 0.055 : 0.12
    let count = Int(Double(rate) * duration)
    var pcm = Data(capacity: count * 2)
    var noise: UInt32 = 0x4F574E
    for index in 0..<count {
      let time = Double(index) / Double(rate)
      let envelope = exp(-time * (name == "Subtle" ? 90 : 38))
      noise = 1664525 &* noise &+ 1013904223
      let sample: Double
      switch name {
      case "8-Bit": sample = sin(time * 2 * .pi * (time < 0.055 ? 880 : 440)) > 0 ? 0.2 : -0.2
      case "Subtle": sample = sin(time * 2 * .pi * 1200) * 0.18
      default: sample = (Double(noise >> 16) / 32767.5 - 1) * 0.4
      }
      var value = Int16(max(-1, min(1, sample * envelope)) * 32767).littleEndian
      withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
    }
    var wav = Data()
    func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
    func uint32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
    func uint16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
    ascii("RIFF"); uint32(UInt32(36 + pcm.count)); ascii("WAVEfmt "); uint32(16)
    uint16(1); uint16(1); uint32(UInt32(rate)); uint32(UInt32(rate * 2)); uint16(2); uint16(16)
    ascii("data"); uint32(UInt32(pcm.count)); wav.append(pcm)
    return wav
  }
}
