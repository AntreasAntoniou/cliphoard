import Foundation

/// Deterministic temporal sampling only. These presets do not identify semantic
/// highlights; future scene/VAD refinement needs its own bounded policy.
enum MediaSamplingPreset: String, CaseIterable, Sendable {
    case lightweight, balanced, detailed

    /// Owner-selected initial choice; this constant does not persist preferences.
    static let defaultPreset: Self = .balanced

    fileprivate var video: (window: Double, interval: Double, frames: Int) {
        switch self {
        case .lightweight: return (2, 60, 2)
        case .balanced: return (3, 30, 3)
        case .detailed: return (3, 10, 3)
        }
    }
    fileprivate var audio: (window: Double, interval: Double) {
        switch self {
        case .lightweight: return (3, 60)
        case .balanced: return (10, 30)
        case .detailed: return (30, 30)
        }
    }
}

enum MediaSamplingModality: Sendable { case video, audio }

struct MediaSampleWindow: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    /// Video-only frame centers. Audio uses the entire [start, end) window and
    /// therefore has no frame timestamps. Rounding may reduce tiny-video counts.
    let frameTimestamps: [TimeInterval]
    var duration: TimeInterval { end - start }
}

/// Pure schedule: no decoding, model loading, files, preferences or shipping caller.
struct MediaSamplingPlan: Equatable, Sendable {
    enum PlanningError: Error, Equatable {
        case invalidDuration
        case unrepresentableTimeline
    }
    static let maximumSegments = 120

    /// Count before the cap. Kept as Double so a large valid duration cannot trap
    /// during Int conversion. Counts beyond Double's exact integer range are
    /// approximate disclosure values, never allocation sizes.
    let requestedSegmentCount: Double
    let effectiveInterval: TimeInterval
    let segments: [MediaSampleWindow]
    var actualSegmentCount: Int { segments.count }
    /// Sum of scheduled window spans. For audio this is planned decoded duration; for
    /// video it is window-span accounting, NOT continuous coverage by sparse frames.
    let sampledDuration: TimeInterval
    /// Scheduled window spans / asset duration; does not imply exhaustive video
    /// inspection or semantic coverage. Zero-length assets have zero coverage.
    let coverageFraction: Double

    private init(requestedSegmentCount: Double, effectiveInterval: TimeInterval,
                 segments: [MediaSampleWindow], sampledDuration: TimeInterval,
                 coverageFraction: Double) {
        self.requestedSegmentCount = requestedSegmentCount
        self.effectiveInterval = effectiveInterval
        self.segments = segments
        self.sampledDuration = sampledDuration
        self.coverageFraction = coverageFraction
    }

    static func make(duration: TimeInterval, preset: MediaSamplingPreset,
                     modality: MediaSamplingModality) throws -> Self {
        guard duration.isFinite, duration >= 0 else { throw PlanningError.invalidDuration }
        guard duration > 0 else {
            return Self(requestedSegmentCount: 0, effectiveInterval: 0, segments: [],
                        sampledDuration: 0, coverageFraction: 0)
        }
        let window = modality == .video ? preset.video.window : preset.audio.window
        let cadence = modality == .video ? preset.video.interval : preset.audio.interval
        let frameCount = modality == .video ? preset.video.frames : 0
        // Positive subnormal duration / cadence can underflow to zero; it still
        // describes one short asset, not an empty asset.
        let requested = max(1, ceil(duration / cadence))
        guard requested.isFinite else { throw PlanningError.unrepresentableTimeline }
        let capped = requested > Double(maximumSegments)
        // The only Double→Int conversion is already bounded to [1, 120].
        let count = capped ? maximumSegments : Int(requested)
        let interval = capped ? duration / Double(count) : min(cadence, duration)
        var segments: [MediaSampleWindow] = []
        segments.reserveCapacity(count)
        var sampledDuration = 0.0
        var previousEnd = 0.0
        for index in 0..<count {
            // Multiply by a ratio <=1, not by duration*index (which can overflow).
            // When capped, every bucket covers its share of the WHOLE asset.
            let bucketStart = capped ? duration * (Double(index) / Double(count)) : Double(index) * cadence
            let bucketEnd = capped
                ? (index == count - 1 ? duration : duration * (Double(index + 1) / Double(count)))
                : min(duration, bucketStart + cadence)
            let bucketWidth = bucketEnd - bucketStart
            let width = min(window, bucketWidth)
            let start = bucketStart + (bucketWidth - width) / 2
            var end = min(bucketEnd, start + width)
            // Centering/addition can round an ordinary 3s span to slightly more
            // than 3s. Move inward by one representable timestamp, never expand
            // the cap with a tolerance. Exact guards below still reject collapse.
            if end - start > window { end = end.nextDown }
            // Huge finite timelines can have ULPs wider than a sampling window.
            // Refuse rather than emit zero-width/reversed/out-of-bounds segments.
            guard start.isFinite, end.isFinite, start >= previousEnd,
                  start >= 0, end > start, end <= duration, end - start <= window else {
                throw PlanningError.unrepresentableTimeline
            }
            var frames: [Double] = []
            frames.reserveCapacity(frameCount)
            for frame in 0..<frameCount {
                let fraction = (Double(frame) + 0.5) / Double(frameCount)
                let timestamp = min(end.nextDown, max(start, start + (end - start) * fraction))
                guard timestamp.isFinite, timestamp >= start, timestamp < end else {
                    throw PlanningError.unrepresentableTimeline
                }
                if frames.last != timestamp { frames.append(timestamp) }
            }
            segments.append(MediaSampleWindow(start: start, end: end, frameTimestamps: frames))
            sampledDuration += end - start
            previousEnd = end
        }
        // Each positive window is <=30 seconds and at most120 windows exist.
        // Clamp the quotient only for floating-point sum roundoff at full coverage.
        return Self(requestedSegmentCount: requested, effectiveInterval: interval,
                    segments: segments, sampledDuration: sampledDuration,
                    coverageFraction: min(1, sampledDuration / duration))
    }
}
