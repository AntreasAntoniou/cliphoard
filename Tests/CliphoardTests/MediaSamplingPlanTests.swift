import XCTest
@testable import Cliphoard

final class MediaSamplingPlanTests: XCTestCase {
    func testOrdinaryBucketBoundariesDoNotRefuseForRounding() throws {
        let cases: [(Double, MediaSamplingPreset, MediaSamplingModality, Double)] = [
            (30.0.nextDown, .lightweight, .audio, 3),
            (30.0.nextDown, .balanced, .video, 3),
            (30.0.nextDown, .balanced, .audio, 10),
            (7200.0.nextDown, .balanced, .audio, 10),
            (3600.0.nextDown, .detailed, .video, 3),
            (7200.0.nextDown, .detailed, .audio, 30)
        ]
        for (duration, preset, modality, maximumWindow) in cases {
            let plan = try MediaSamplingPlan.make(duration: duration, preset: preset, modality: modality)
            XCTAssertFalse(plan.segments.isEmpty)
            XCTAssertTrue(plan.segments.allSatisfy { $0.duration <= maximumWindow })
            assertBounds(plan, duration: duration)
        }
    }
    func testDefaultPresetProducesBalancedSchedules() throws {
        let video = try MediaSamplingPlan.make(duration: 60, preset: .defaultPreset, modality: .video)
        let audio = try MediaSamplingPlan.make(duration: 60, preset: .defaultPreset, modality: .audio)
        XCTAssertEqual(video.actualSegmentCount, 2)
        XCTAssertEqual(video.sampledDuration, 6)
        XCTAssertEqual(video.effectiveInterval, 30)
        XCTAssertEqual(video.segments.map { $0.frameTimestamps.count }, [3, 3])
        XCTAssertEqual(audio.actualSegmentCount, 2)
        XCTAssertEqual(audio.sampledDuration, 20)
        XCTAssertEqual(audio.effectiveInterval, 30)
        XCTAssertTrue(audio.segments.allSatisfy { $0.frameTimestamps.isEmpty })
    }
    func testPresetVideoWindowsAndFrameCounts() throws {
        for (preset, length, cadence, frames) in [(MediaSamplingPreset.lightweight, 2.0, 60.0, 2), (.balanced, 3, 30, 3), (.detailed, 3, 10, 3)] {
            let plan = try MediaSamplingPlan.make(duration: cadence * 2, preset: preset, modality: .video)
            XCTAssertEqual(plan.requestedSegmentCount, 2)
            XCTAssertEqual(plan.actualSegmentCount, 2)
            XCTAssertEqual(plan.effectiveInterval, cadence)
            XCTAssertEqual(plan.segments[0].start, (cadence - length) / 2)
            XCTAssertEqual(plan.segments[1].end, cadence + (cadence + length) / 2)
            XCTAssertEqual(plan.sampledDuration, 2 * length)
            XCTAssertEqual(plan.coverageFraction, length / cadence, accuracy: 1e-12)
            XCTAssertTrue(plan.segments.allSatisfy { $0.frameTimestamps.count == frames })
            assertBounds(plan, duration: cadence * 2)
        }
    }
    func testAudioDurationsAreWindowsNotFrameCounts() throws {
        for (preset, length, cadence) in [(MediaSamplingPreset.lightweight, 3.0, 60.0), (.balanced, 10, 30), (.detailed, 30, 30)] {
            let plan = try MediaSamplingPlan.make(duration: cadence * 3, preset: preset, modality: .audio)
            XCTAssertEqual(plan.actualSegmentCount, 3)
            XCTAssertEqual(plan.sampledDuration, 3 * length)
            XCTAssertTrue(plan.segments.allSatisfy { $0.frameTimestamps.isEmpty })
            assertBounds(plan, duration: cadence * 3)
        }
    }
    func testShortAssetIsSampledOnceAndClamped() throws {
        for preset in MediaSamplingPreset.allCases {
            for modality in [MediaSamplingModality.audio, .video] {
                let plan = try MediaSamplingPlan.make(duration: 0.25, preset: preset, modality: modality)
                XCTAssertEqual(plan.actualSegmentCount, 1)
                XCTAssertEqual(plan.segments[0].start, 0)
                XCTAssertEqual(plan.segments[0].end, 0.25)
                XCTAssertEqual(plan.coverageFraction, 1)
                assertBounds(plan, duration: 0.25)
            }
        }
    }
    func testLastPartialBucketUsesItsOwnMidpoint() throws {
        let plan = try MediaSamplingPlan.make(duration: 61, preset: .lightweight, modality: .video)
        XCTAssertEqual(plan.segments.map(\.start), [29, 60])
        XCTAssertEqual(plan.segments.map(\.end), [31, 61])
        XCTAssertEqual(plan.sampledDuration, 3)
        assertBounds(plan, duration: 61)
    }
    func testExactCapBoundaryAndJustBeyondSpreadWholeAsset() throws {
        let exact = try MediaSamplingPlan.make(duration: 7200, preset: .lightweight, modality: .video)
        XCTAssertEqual(exact.requestedSegmentCount, 120)
        XCTAssertEqual(exact.effectiveInterval, 60)
        let capped = try MediaSamplingPlan.make(duration: 7201, preset: .lightweight, modality: .video)
        XCTAssertEqual(capped.requestedSegmentCount, 121)
        XCTAssertEqual(capped.actualSegmentCount, 120)
        XCTAssertEqual(capped.effectiveInterval, 7201.0 / 120)
        XCTAssertEqual(capped.segments.last!.start, 7201 - capped.effectiveInterval / 2 - 1, accuracy: 1e-9)
        assertBounds(capped, duration: 7201)
    }
    func testLongMediaKeepsLastBucketAndCoverageDisclosure() throws {
        for modality in [MediaSamplingModality.audio, .video] {
            let duration = 86400.0 * 365
            let plan = try MediaSamplingPlan.make(duration: duration, preset: .detailed, modality: modality)
            XCTAssertEqual(plan.actualSegmentCount, 120)
            XCTAssertGreaterThan(plan.requestedSegmentCount, 120)
            XCTAssertGreaterThan(plan.segments.last!.start, duration * 0.99)
            XCTAssertEqual(plan.sampledDuration, modality == .audio ? 3600 : 360)
            XCTAssertEqual(plan.coverageFraction, plan.sampledDuration / duration)
            assertBounds(plan, duration: duration)
        }
    }
    func testLargeRepresentableTimelineDoesNotConvertUnboundedCount() throws {
        let plan = try MediaSamplingPlan.make(duration: 1e15, preset: .balanced, modality: .video)
        XCTAssertEqual(plan.actualSegmentCount, 120)
        XCTAssertGreaterThan(plan.requestedSegmentCount, Double(Int32.max))
        assertBounds(plan, duration: 1e15)
    }
    func testUnrepresentableHugeTimelineFailsRatherThanFabricatingWindows() {
        for duration in [Double.greatestFiniteMagnitude, 1e100] {
            XCTAssertThrowsError(try MediaSamplingPlan.make(duration: duration, preset: .lightweight, modality: .video)) {
                XCTAssertEqual($0 as? MediaSamplingPlan.PlanningError, .unrepresentableTimeline)
            }
        }
    }
    func testRoundingCannotExpandWindowsBeyondPresetDuration() throws {
        let plan = try MediaSamplingPlan.make(duration: 1e16, preset: .balanced, modality: .video)
        XCTAssertEqual(plan.actualSegmentCount, 120)
        XCTAssertTrue(plan.segments.allSatisfy { $0.duration <= 3 })
        assertBounds(plan, duration: 1e16)
    }
    func testTinyPositiveDurationDeduplicatesRoundedFrames() throws {
        for duration in [Double.leastNonzeroMagnitude, 1e-300, 1e-12] {
            let plan = try MediaSamplingPlan.make(duration: duration, preset: .detailed, modality: .video)
            XCTAssertEqual(plan.actualSegmentCount, 1)
            XCTAssertEqual(plan.coverageFraction, 1)
            XCTAssertFalse(plan.segments[0].frameTimestamps.isEmpty)
            assertBounds(plan, duration: duration)
        }
    }
    func testZeroDurationIsAnExplicitEmptyPlan() throws {
        let plan = try MediaSamplingPlan.make(duration: 0, preset: .balanced, modality: .audio)
        XCTAssertEqual(plan.requestedSegmentCount, 0)
        XCTAssertEqual(plan.actualSegmentCount, 0)
        XCTAssertEqual(plan.effectiveInterval, 0)
        XCTAssertEqual(plan.sampledDuration, 0)
        XCTAssertEqual(plan.coverageFraction, 0)
    }
    func testInvalidDurationsRejectBeforeAllocation() {
        for duration in [Double.nan, .infinity, -.infinity, -1, -Double.leastNonzeroMagnitude] {
            XCTAssertThrowsError(try MediaSamplingPlan.make(duration: duration, preset: .balanced, modality: .audio)) {
                XCTAssertEqual($0 as? MediaSamplingPlan.PlanningError, .invalidDuration)
            }
        }
    }
    func testDeterminismAndBothModalityCaps() throws {
        for preset in MediaSamplingPreset.allCases {
            for modality in [MediaSamplingModality.audio, .video] {
                let one = try MediaSamplingPlan.make(duration: 999999, preset: preset, modality: modality)
                let two = try MediaSamplingPlan.make(duration: 999999, preset: preset, modality: modality)
                XCTAssertEqual(one, two)
                XCTAssertEqual(one.actualSegmentCount, 120)
                assertBounds(one, duration: 999999)
            }
        }
    }
    private func assertBounds(_ plan: MediaSamplingPlan, duration: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(plan.segments.count, 120, file: file, line: line)
        var previousEnd = 0.0
        for segment in plan.segments {
            XCTAssertTrue(segment.start.isFinite && segment.end.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(segment.start, previousEnd, file: file, line: line)
            XCTAssertGreaterThan(segment.end, segment.start, file: file, line: line)
            XCTAssertLessThanOrEqual(segment.end, duration, file: file, line: line)
            XCTAssertEqual(segment.frameTimestamps, Array(Set(segment.frameTimestamps)).sorted(), file: file, line: line)
            for frame in segment.frameTimestamps {
                XCTAssertTrue(frame.isFinite, file: file, line: line)
                XCTAssertGreaterThanOrEqual(frame, segment.start, file: file, line: line)
                XCTAssertLessThan(frame, segment.end, file: file, line: line)
            }
            previousEnd = segment.end
        }
    }
}
