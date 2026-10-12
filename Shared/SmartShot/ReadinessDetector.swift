import CoreMedia
import CoreVideo
import Foundation
import Vision

/// One person the detector is following across frames.
struct FaceStatus: Identifiable, Equatable {
    let id: Int
    /// Normalized rect in the viewfinder, top-left origin.
    var box: CGRect
    var eyesOpen: Bool
    var facingCamera: Bool
    var still: Bool

    var isSettled: Bool { facingCamera && still }
    var isReady: Bool { isSettled && eyesOpen }
}

enum ReadinessPhase: Equatable {
    /// Nobody in the frame.
    case noPeople
    /// The number of people is still changing (someone is walking into the shot).
    case gathering
    /// Everyone is here, but someone isn't looking, is moving or has their eyes closed.
    case waiting
    /// Everyone is ready; holding for a beat to make sure. Progress is 0...1.
    case holding(Double)
}

struct ReadinessSnapshot: Equatable {
    var faces: [FaceStatus] = []
    var phase: ReadinessPhase = .noPeople
    /// True on the single frame where the shot should be taken.
    var shouldCapture = false

    var total: Int { faces.count }
    var readyCount: Int { faces.filter(\.isReady).count }

    static let empty = ReadinessSnapshot()
}

/// Decides when everyone in the frame is ready for a photo.
///
/// A person is ready when they face the camera, hold still and have their eyes open.
/// The group is ready once the head count has stopped changing and every person has
/// been ready for `holdDuration`. The shot fires on the first frame after that where
/// nobody is blinking. Not thread-safe: call it from the video data queue only.
final class ReadinessDetector {
    var holdDuration: TimeInterval = 0.7
    var countStableDuration: TimeInterval = 1.0
    var stillnessWindow: TimeInterval = 0.5
    /// How the camera's frames must be turned to look like the viewfinder. Letting Vision
    /// handle this is far cheaper than having the capture connection rotate every frame.
    var orientation: CGImagePropertyOrientation = .up

    private struct Track {
        let id: Int
        var box: CGRect
        var history: [(time: TimeInterval, box: CGRect)] = []
        var eyeBaseline: CGFloat = 0
        var lastSeen: TimeInterval
        var status: FaceStatus
    }

    private var tracks: [Track] = []
    private var nextTrackID = 0
    private var lastCount = 0
    private var countChangedAt: TimeInterval = 0
    private var readySince: TimeInterval?
    private var lastProcessed: TimeInterval = 0
    private let minimumFrameInterval: TimeInterval = 1.0 / 15.0

    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()

    func reset() {
        tracks = []
        lastCount = 0
        countChangedAt = 0
        readySince = nil
    }

    /// Restarts the hold so a fresh "everyone ready" moment is needed.
    func rearm() {
        readySince = nil
    }

    /// Returns nil when the frame was skipped to keep the frame rate down.
    func process(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> ReadinessSnapshot? {
        guard time - lastProcessed >= minimumFrameInterval else { return nil }
        lastProcessed = time

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([landmarksRequest])
        } catch {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        // Landmark points are in the upright image, so swap sides for quarter turns.
        let quarterTurn: Set<CGImagePropertyOrientation> = [.left, .right, .leftMirrored, .rightMirrored]
        let imageSize = quarterTurn.contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        let observations = (landmarksRequest.results ?? [])
            .filter { $0.confidence > 0.5 && $0.boundingBox.width > 0.04 }
        updateTracks(with: observations, imageSize: imageSize, time: time)
        return snapshot(at: time)
    }

    // MARK: - Tracking

    private func updateTracks(with observations: [VNFaceObservation], imageSize: CGSize, time: TimeInterval) {
        var unmatched = Array(tracks.indices)
        var updated: [Track] = []

        for face in observations {
            // Vision uses a bottom-left origin; the viewfinder uses top-left.
            let b = face.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)

            // Match to the nearest existing track by center distance.
            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for i in unmatched {
                let d = box.center.distance(to: tracks[i].box.center)
                if d < bestDistance && d < max(box.width, tracks[i].box.width) * 0.8 {
                    bestDistance = d
                    bestIndex = i
                }
            }

            var track: Track
            if let i = bestIndex {
                track = tracks[i]
                unmatched.removeAll { $0 == i }
            } else {
                track = Track(id: nextTrackID, box: box, lastSeen: time,
                              status: FaceStatus(id: nextTrackID, box: box, eyesOpen: false,
                                                 facingCamera: false, still: false))
                nextTrackID += 1
            }

            track.box = box
            track.lastSeen = time
            track.history.append((time, box))
            track.history.removeAll { time - $0.time > stillnessWindow }

            let openness = eyeOpenness(face, imageSize: imageSize)
            if let openness {
                // Learn each person's "eyes open" level so narrow eyes aren't read as closed.
                track.eyeBaseline = max(openness, track.eyeBaseline * 0.995)
            }
            let eyesOpen = openness.map { $0 > 0.12 && $0 > track.eyeBaseline * 0.6 } ?? false

            let yaw = abs(face.yaw?.doubleValue ?? 0)
            let pitch = abs(face.pitch?.doubleValue ?? 0)
            let facing = yaw < 0.35 && pitch < 0.4

            track.status = FaceStatus(id: track.id, box: box, eyesOpen: eyesOpen,
                                      facingCamera: facing, still: isStill(track, now: time))
            updated.append(track)
        }

        // Keep briefly-lost faces for a moment so a missed frame doesn't reset everything.
        for i in unmatched where time - tracks[i].lastSeen < 0.4 {
            updated.append(tracks[i])
        }
        tracks = updated

        if tracks.count != lastCount {
            lastCount = tracks.count
            countChangedAt = time
        }
    }

    private func isStill(_ track: Track, now: TimeInterval) -> Bool {
        guard let first = track.history.first,
              now - first.time >= stillnessWindow * 0.8 else { return false }
        let size = track.box.width
        for sample in track.history {
            if sample.box.center.distance(to: track.box.center) > size * 0.08 { return false }
            if abs(sample.box.width - size) > size * 0.1 { return false }
        }
        return true
    }

    /// Height-to-width ratio of the eye outline, averaged over both eyes.
    private func eyeOpenness(_ face: VNFaceObservation, imageSize: CGSize) -> CGFloat? {
        guard let landmarks = face.landmarks else { return nil }
        let ratios = [landmarks.leftEye, landmarks.rightEye].compactMap { region -> CGFloat? in
            guard let region, region.pointCount >= 6 else { return nil }
            let points = region.pointsInImage(imageSize: imageSize)
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                  maxX - minX > 1 else { return nil }
            return (maxY - minY) / (maxX - minX)
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / CGFloat(ratios.count)
    }

    // MARK: - Group decision

    private func snapshot(at time: TimeInterval) -> ReadinessSnapshot {
        var result = ReadinessSnapshot(faces: tracks.map(\.status).sorted { $0.box.minX < $1.box.minX })

        guard !tracks.isEmpty else {
            readySince = nil
            result.phase = .noPeople
            return result
        }
        guard time - countChangedAt >= countStableDuration else {
            readySince = nil
            result.phase = .gathering
            return result
        }
        guard result.faces.allSatisfy(\.isSettled) else {
            readySince = nil
            result.phase = .waiting
            return result
        }

        let since = readySince ?? time
        readySince = since
        let progress = min(1, (time - since) / holdDuration)
        result.phase = .holding(progress)
        // Fire only on a frame where nobody is mid-blink.
        result.shouldCapture = progress >= 1 && result.faces.allSatisfy(\.eyesOpen)
        return result
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
