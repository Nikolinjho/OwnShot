import AVFoundation

@MainActor
struct VideoEditorFrameTiming {
  /// AVSampleCursor reports media time, before a video track's edit list applies
  /// offsets and scaling. B-frame recordings commonly start at a nonzero media PTS.
  private struct EditSegment {
    let media: Range<TimeInterval>
    let timeline: Range<TimeInterval>

    init?(_ segment: AVAssetTrackSegment) {
      let source = segment.timeMapping.source
      let target = segment.timeMapping.target
      guard !segment.isEmpty,
            source.start.isNumeric, source.end.isNumeric, source.start.seconds < source.end.seconds,
            target.start.isNumeric, target.end.isNumeric, target.start.seconds < target.end.seconds else { return nil }
      media = source.start.seconds ..< source.end.seconds
      timeline = target.start.seconds ..< target.end.seconds
    }

    func mediaTime(at time: TimeInterval) -> TimeInterval {
      media.lowerBound + (time - timeline.lowerBound) * (media.upperBound - media.lowerBound)
        / (timeline.upperBound - timeline.lowerBound)
    }

    func timelineTime(at sample: TimeInterval) -> TimeInterval {
      timeline.lowerBound + (sample - media.lowerBound) * (timeline.upperBound - timeline.lowerBound)
        / (media.upperBound - media.lowerBound)
    }
  }

  private let sampleTrack: AVAssetTrack?
  private let frameDuration: TimeInterval
  private let editSegments: [EditSegment]

  static let fallback = Self(sampleTrack: nil, frameDuration: 1.0 / 30, editSegments: [])

  private init(sampleTrack: AVAssetTrack?, frameDuration: TimeInterval, editSegments: [EditSegment]) {
    self.sampleTrack = sampleTrack
    self.frameDuration = frameDuration
    self.editSegments = editSegments
  }

  init(track: AVAssetTrack) async {
    let supportsCursor = (try? await track.load(.canProvideSampleCursors)) == true
    let nominalRate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
    let minDuration = (try? await track.load(.minFrameDuration))?.seconds ?? 0
    let duration = if nominalRate.isFinite, nominalRate > 0 {
      1 / nominalRate
    } else if minDuration.isFinite, minDuration > 0 {
      minDuration
    } else {
      Self.fallback.frameDuration
    }
    let segments = supportsCursor ? ((try? await track.load(.segments)) ?? []) : []
    self.init(sampleTrack: supportsCursor ? track : nil, frameDuration: duration,
              editSegments: segments.compactMap(EditSegment.init))
  }

  func adjacentFrame(to time: TimeInterval, forward: Bool) -> TimeInterval? {
    // The structural playhead is stored at 600 ticks per second. Allow half
    // a tick so a fractional-rate frame rounded down is still the current sample.
    let tolerance = min(0.00084, frameDuration * 0.25)
    if let index = editSegments.firstIndex(where: { $0.timeline.contains(time + tolerance) || $0.timeline.contains(time) }) {
      let edit = editSegments[index]
      if let cursor = cursor(at: edit.mediaTime(at: time + tolerance)) {
        let original = edit.timelineTime(at: cursor.presentationTimeStamp.seconds)
        let step: Int64 = forward ? 1 : -1
        if (!forward && original < time - tolerance) || cursor.stepInPresentationOrder(byCount: step) == step {
          let sample = cursor.presentationTimeStamp.seconds
          if edit.media.contains(sample) {
            let frame = edit.timelineTime(at: sample)
            if forward ? frame > time : frame < time { return frame }
          }
        }
        let neighborIndex = index + (forward ? 1 : -1)
        guard editSegments.indices.contains(neighborIndex) else { return nil }
        let neighbor = editSegments[neighborIndex]
        return forward ? neighbor.timeline.lowerBound : lastFrame(before: neighbor.timeline.upperBound)
      }
    }

    let index = forward
      ? floor((time + tolerance) / frameDuration) + 1
      : ceil((time - tolerance) / frameDuration) - 1
    return index * frameDuration
  }

  func lastFrame(before end: TimeInterval) -> TimeInterval {
    let epsilon = min(0.0001, frameDuration * 0.01)
    if let edit = editSegments.last(where: { $0.timeline.lowerBound < end }) {
      let trackTime = min(end, edit.timeline.upperBound) - epsilon
      if let sample = cursor(at: edit.mediaTime(at: trackTime))?.presentationTimeStamp.seconds,
         sample.isFinite {
        let frame = max(edit.timeline.lowerBound, edit.timelineTime(at: sample))
        if frame < end { return frame }
      }
    }
    return (ceil((end - epsilon) / frameDuration) - 1) * frameDuration
  }

  private func cursor(at seconds: TimeInterval) -> AVSampleCursor? {
    sampleTrack?.makeSampleCursor(
      presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60_000)
    )
  }
}
