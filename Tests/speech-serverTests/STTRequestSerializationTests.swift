import Foundation
import XCTVapor
import XCTest

@testable import speech_server

final class STTRequestSerializationTests: XCTestCase {
    func testHTTPAndWyomingRequestsNeverOverlapModelInference() async throws {
        let tracker = STTInferenceTracker()
        let app = try await Application.make(.testing)
        addTeardownBlock {
            try await app.asyncShutdown()
        }

        app.sttService = TrackingSTTService(tracker: tracker)
        try app.register(collection: TranscriptionController())
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: app.sttService
        )

        let boundary = "STTSerializationBoundary"
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
        let body = makeMultipartBody(
            boundary: boundary,
            file: Data([0x01]),
            filename: "http.wav"
        )
        let httpRequest = Task {
            try await app.test(
                .POST,
                "/audio/transcriptions",
                headers: headers,
                body: ByteBuffer(data: body)
            ) { response async throws in
                XCTAssertEqual(response.status, .ok)
            }
        }
        await tracker.waitUntilInferenceStarts()

        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-start",
                data: ["rate": .int(16_000), "width": .int(2), "channels": .int(1)]
            ))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-chunk",
                payload: Data(repeating: 0, count: 32_000)
            ))
        let wyomingResponses = Task {
            var responses: [Data] = []
            for await response in await session.handle(event: WyomingEvent(type: "audio-stop")) {
                responses.append(response)
            }
            return responses
        }

        _ = try await httpRequest.value
        let responses = await wyomingResponses.value
        let maximumConcurrentInference = await tracker.maximumConcurrentInference
        let completedInferenceCount = await tracker.completedInferenceCount
        XCTAssertFalse(responses.isEmpty)
        XCTAssertEqual(maximumConcurrentInference, 1)
        XCTAssertEqual(completedInferenceCount, 2)
    }
}

private struct TrackingSTTService: STTService {
    let tracker: STTInferenceTracker

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        await tracker.inferenceStarted()
        try await Task.sleep(for: .milliseconds(100))
        await tracker.inferenceFinished()
        return TranscriptionResult(text: "tracked", duration: 1, words: [], segments: [])
    }
}

private actor STTInferenceTracker {
    private var activeInferenceCount = 0
    private(set) var maximumConcurrentInference = 0
    private(set) var completedInferenceCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func inferenceStarted() {
        activeInferenceCount += 1
        maximumConcurrentInference = max(maximumConcurrentInference, activeInferenceCount)
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func inferenceFinished() {
        activeInferenceCount -= 1
        completedInferenceCount += 1
    }

    func waitUntilInferenceStarts() async {
        guard activeInferenceCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}
