import Foundation

@MainActor
final class InferenceAPIController: LocalAPIRouteHandler {
    struct TranscribeJSONRequest: Decodable {
        let path: String?
        let audioBase64: String?
        let filename: String?
    }

    struct TranscribeResponse: Encodable {
        let text: String
        let confidence: Float
        let sampleCount: Int
        let provider: String
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "POST" else {
            return LocalAPI.error("Method not allowed.", status: 405)
        }

        switch request.path {
        case "/v1/transcribe":
            return await self.transcribe(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func transcribe(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            if let fileURL = try self.decodeFilePath(from: request) {
                let apiResult = try await AppServices.shared.asr.transcribeFileForAPI(fileURL)
                return LocalAPI.json(
                    TranscribeResponse(
                        text: apiResult.result.text,
                        confidence: apiResult.result.confidence,
                        sampleCount: apiResult.sampleCount,
                        provider: SettingsStore.shared.selectedSpeechModel.displayName
                    )
                )
            }

            let samples = try self.decodeAudioSamples(from: request)
            let result = try await AppServices.shared.asr.transcribeSamplesForAPI(samples)
            return LocalAPI.json(
                TranscribeResponse(
                    text: result.text,
                    confidence: result.confidence,
                    sampleCount: samples.count,
                    provider: SettingsStore.shared.selectedSpeechModel.displayName
                )
            )
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func decodeFilePath(from request: LocalAPI.Request) throws -> URL? {
        guard self.isJSON(request) else { return nil }
        let payload: TranscribeJSONRequest
        do {
            payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
        } catch {
            throw NSError(domain: "InferenceAPIController", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON audio payload."])
        }

        guard let path = payload.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func decodeAudioSamples(from request: LocalAPI.Request) throws -> [Float] {
        if self.isJSON(request) {
            let payload: TranscribeJSONRequest
            do {
                payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
            } catch {
                throw NSError(domain: "InferenceAPIController", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON audio payload."])
            }

            if let path = payload.path, !path.isEmpty {
                return try LocalAPIAudioDecoder.samples(from: URL(fileURLWithPath: path))
            }

            if let audioBase64 = payload.audioBase64,
               let data = Data(base64Encoded: audioBase64)
            {
                return try LocalAPIAudioDecoder.samples(
                    fromAudioData: data,
                    suggestedExtension: payload.filename.flatMap { URL(fileURLWithPath: $0).pathExtension } ?? "wav"
                )
            }

            throw NSError(domain: "InferenceAPIController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing audio path or audioBase64."])
        }

        guard !request.body.isEmpty else {
            throw NSError(domain: "InferenceAPIController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing audio body."])
        }

        let filename = request.headers["x-filename"] ?? "audio.wav"
        return try LocalAPIAudioDecoder.samples(
            fromAudioData: request.body,
            suggestedExtension: URL(fileURLWithPath: filename).pathExtension
        )
    }

    private func isJSON(_ request: LocalAPI.Request) -> Bool {
        request.headers["content-type"]?.lowercased().contains("application/json") == true
    }
}
