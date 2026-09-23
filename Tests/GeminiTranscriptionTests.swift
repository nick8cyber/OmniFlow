import Foundation

enum GeminiTranscriptionTests {
    static func run() {
        testOnlyInteractionsCapableModelsAreRouted()
        testGroqProviderURLIsReplacedWithGoogleHost()
        testRequestAsksForSmartModeWithInlineAudio()
        testVocabularyIsSplitDeduplicatedAndCapped()
        testTranscriptIsReadFromModelOutput()
        testFailuresSurfaceGoogleMessage()
    }

    private static func buildBody(_ body: Data,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                fatalError("\(file):\(line): request body is not a JSON object")
            }
            return json
        } catch {
            fatalError("\(file):\(line): request body is invalid JSON: \(error)")
        }
    }

    private static func requestBodyOrCrash(model: String,
                                           audioData: Data,
                                           mimeType: String,
                                           customVocabulary: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) -> Data {
        do {
            return try GeminiTranscription.requestBody(model: model,
                                                       audioData: audioData,
                                                       mimeType: mimeType,
                                                       customVocabulary: customVocabulary)
        } catch {
            fatalError("\(file):\(line): requestBody unexpectedly threw \(error)")
        }
    }

    // MARK: - 1

    private static func testOnlyInteractionsCapableModelsAreRouted() {
        expect(GeminiTranscription.handlesModel("gemini-3.5-transcribe"),
               "batch Gemini transcribe model must be routed")
        expect(GeminiTranscription.handlesModel(" GEMINI-3.5-TRANSCRIBE "),
               "routing normalizes whitespace and case")
        expect(!GeminiTranscription.handlesModel("gemini-3.5-transcribe-live"),
               "live models must not use the batch path")
        expect(!GeminiTranscription.handlesModel("whisper-large-v3"),
               "Whisper models must not use the Gemini path")
        expect(!GeminiTranscription.handlesModel("gemini-3.5-flash"),
               "non-transcribe Gemini models must not be routed")
    }

    // MARK: - 2

    private static func testGroqProviderURLIsReplacedWithGoogleHost() {
        expectEqual(GeminiTranscription.resolvedBaseURL(from: "https://api.groq.com/openai/v1"),
                    GeminiTranscription.defaultBaseURL,
                    "Groq host is replaced with the Google host")
        expectEqual(GeminiTranscription.resolvedBaseURL(from: ""),
                    GeminiTranscription.defaultBaseURL,
                    "empty URL falls back to the Google host")
        expectEqual(GeminiTranscription.resolvedBaseURL(from: "https://generativelanguage.googleapis.com/v1beta/custom"),
                    "https://generativelanguage.googleapis.com/v1beta/custom",
                    "explicit Google URL is preserved")
        expectEqual(GeminiTranscription.endpoint(baseURL: URL(string: GeminiTranscription.defaultBaseURL)!),
                    URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
                    "endpoint appends /interactions")
    }

    // MARK: - 3

    private static func testRequestAsksForSmartModeWithInlineAudio() {
        let body = requestBodyOrCrash(model: "gemini-3.5-transcribe",
                                      audioData: Data([1, 2, 3]),
                                      mimeType: "audio/wav",
                                      customVocabulary: "OmniFlow\nGroq")
        let json = buildBody(body)
        expectEqual(json["model"] as? String, "gemini-3.5-transcribe", "model field")

        let input = json["input"] as? [[String: Any]]
        expectEqual(input?.count, 1, "input has exactly one element")
        let audio = input?.first
        expectEqual(audio?["type"] as? String, "audio", "input type")
        expectEqual(audio?["mime_type"] as? String, "audio/wav", "input mime_type")
        expectEqual(audio?["data"] as? String, Data([1, 2, 3]).base64EncodedString(), "inline base64 audio")

        let generationConfig = json["generation_config"] as? [String: Any]
        let transcriptionConfig = generationConfig?["transcription_config"] as? [String: Any]
        let mode = transcriptionConfig?["mode"] as? [String: Any]
        expectEqual(mode?["type"] as? String, "smart", "smart mode type (lowercase)")
        expectEqual(transcriptionConfig?["custom_vocabulary"] as? [String], ["OmniFlow", "Groq"],
                    "custom vocabulary terms")

        expect(json["language_codes"] == nil, "language_codes must never be sent at the root")
        expect(transcriptionConfig?["language_codes"] == nil,
               "language_codes must never be sent in transcription_config")
        expect(json["timestamp_granularities"] == nil, "timestamp_granularities must not be sent")
        expect(transcriptionConfig?["diarization_mode"] == nil, "diarization_mode must not be sent")
    }

    // MARK: - 4

    private static func testVocabularyIsSplitDeduplicatedAndCapped() {
        expectEqual(GeminiTranscription.vocabularyTerms(from: "Kubernetes\nBigQuery; Groq , Groq"),
                    ["Kubernetes", "BigQuery", "Groq"],
                    "vocabulary split on newlines/commas/semicolons, deduplicated")
        expectEqual(GeminiTranscription.vocabularyTerms(from: "  ,,, ;;\n "),
                    [],
                    "junk vocabulary yields an empty list")

        let many = (0..<1200).map { "term\($0)" }.joined(separator: ",")
        let capped = GeminiTranscription.vocabularyTerms(from: many)
        expectEqual(capped.count, 1000, "vocabulary is capped at 1000 terms")
        expectEqual(capped.first, "term0", "cap keeps the first terms")

        let body = requestBodyOrCrash(model: "gemini-3.5-transcribe",
                                      audioData: Data([1]),
                                      mimeType: "audio/wav",
                                      customVocabulary: "")
        let json = buildBody(body)
        let transcriptionConfig = ((json["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        expect(transcriptionConfig?["custom_vocabulary"] == nil,
               "empty vocabulary is omitted from the request body, not sent as an empty list")
    }

    // MARK: - 5

    private static func testTranscriptIsReadFromModelOutput() {
        let ok = #"{"status": "completed", "steps": [{"type": "model_output", "content": [{"text": "Hello "}, {"text": "there."}]}]}"#
        let parsed: String
        do {
            parsed = try GeminiTranscription.transcript(fromResponse: Data(ok.utf8))
        } catch {
            fatalError("\(#filePath):\(#line): transcript unexpectedly threw \(error)")
        }
        expectEqual(parsed, "Hello there.", "transcript joins model_output step texts")

        let empty = #"{"status": "completed", "steps": [{"type": "model_output", "content": [{"text": "   "}]}]}"#
        expectThrows(try GeminiTranscription.transcript(fromResponse: Data(empty.utf8)),
                     "whitespace-only transcript must throw")

        let failed = #"{"status": "failed", "steps": [{"type": "model_output", "content": [{"text": "Hello there."}]}]}"#
        expectThrows(try GeminiTranscription.transcript(fromResponse: Data(failed.utf8)),
                     "non-completed status must throw")

        expectThrows(try GeminiTranscription.transcript(fromResponse: Data("not json".utf8)),
                     "unreadable response must throw")
    }

    // MARK: - 6

    private static func testFailuresSurfaceGoogleMessage() {
        let quota = #"{"error": {"code": 429, "message": "You exceeded your current quota.", "status": "RESOURCE_EXHAUSTED"}}"#
        expectEqual(GeminiTranscription.failureMessage(fromResponse: Data(quota.utf8), fallback: "HTTP 500"),
                    "You exceeded your current quota.",
                    "bare error object surfaces the Google message")
        expectEqual(GeminiTranscription.failureMessage(fromResponse: Data("not json".utf8), fallback: "HTTP 500"),
                    "HTTP 500",
                    "unreadable body falls back to the HTTP message")
        let wrapped = #"[{"error": {"message": "API key not valid."}}]"#
        expectEqual(GeminiTranscription.failureMessage(fromResponse: Data(wrapped.utf8), fallback: "HTTP 500"),
                    "API key not valid.",
                    "array-wrapped auth errors are recognized")
        expectThrows(try GeminiTranscription.transcript(fromResponse: Data(quota.utf8)),
                     "error body at HTTP 200 must not parse as a transcript")
    }
}
