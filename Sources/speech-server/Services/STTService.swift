import Foundation
import Vapor

struct WordTiming {
    let word: String
    let start: Double
    let end: Double
}

struct SegmentResult {
    let text: String
    let start: Double
    let end: Double
    let words: [WordTiming]
    let confidence: Float
}

struct TranscriptionResult {
    let text: String
    let duration: Double
    let words: [WordTiming]
    let segments: [SegmentResult]
}

protocol STTService: Sendable {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

/// Serializes access to a shared STT service across every server protocol.
///
/// Actor isolation alone is insufficient because actors are reentrant while an
/// inference call is suspended. This explicit FIFO gate remains held for the
/// entire async `transcribe` call.
final class SerializedSTTService: STTService, Sendable {
    private let service: any STTService
    private let gate = STTInferenceGate()

    init(service: any STTService) {
        self.service = service
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await service.transcribe(audioURL: audioURL)
            await gate.release()
            return result
        }
        catch {
            await gate.release()
            throw error
        }
    }
}

private actor STTInferenceGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

// MARK: - Vapor DI

struct STTServiceKey: StorageKey {
    typealias Value = SerializedSTTService
}

extension Application {
    var sttService: any STTService {
        get { storage[STTServiceKey.self]! }
        set {
            storage[STTServiceKey.self] =
                (newValue as? SerializedSTTService) ?? SerializedSTTService(service: newValue)
        }
    }
}

extension Request {
    var sttService: any STTService {
        application.sttService
    }
}
