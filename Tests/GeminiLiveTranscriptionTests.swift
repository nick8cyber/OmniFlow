import Foundation

enum GeminiLiveTranscriptionTests {
    static func run() {
        testOnlyLiveModelsAreRouted()
        testSocketURLIsDerivedFromAnyGeminiBase()
        testSetupAsksForSmartModeAndVocabulary()
        testAudioFramesDeclareTheRealSampleRate()
        testServerFramesAreClassified()
    }

    private static let expectedSocketURL =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private static func jsonOrCrash(_ message: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else {
                fatalError("\(file):\(line): message is not a JSON object")
            }
            return json
        } catch {
            fatalError("\(file):\(line): message is invalid JSON: \(error)")
        }
    }

    private static func setupMessageOrCrash(model: String,
                                            customVocabulary: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) -> String {
        do {
            return try GeminiLiveTranscription.setupMessage(model: model, customVocabulary: customVocabulary)
        } catch {
            fatalError("\(file):\(line): setupMessage unexpectedly threw \(error)")
        }
    }

    private static func audioMessageOrCrash(pcm16: Data,
                                            sampleRate: Int,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) -> String {
        do {
            return try GeminiLiveTranscription.audioMessage(pcm16: pcm16, sampleRate: sampleRate)
        } catch {
            fatalError("\(file):\(line): audioMessage unexpectedly threw \(error)")
        }
    }

    private static func audioStreamEndMessageOrCrash(file: StaticString = #filePath,
                                                     line: UInt = #line) -> String {
        do {
            return try GeminiLiveTranscription.audioStreamEndMessage()
        } catch {
            fatalError("\(file):\(line): audioStreamEndMessage unexpectedly threw \(error)")
        }
    }

    // MARK: - 1

    private static func testOnlyLiveModelsAreRouted() {
        expect(GeminiLiveTranscription.handlesModel("gemini-3.5-transcribe-live"),
               "live model must be routed to the live service")
        expect(GeminiLiveTranscription.handlesModel(" Gemini-3.5-Transcribe-Live "),
               "routing normalizes case and surrounding whitespace")
        expect(!GeminiLiveTranscription.handlesModel("gemini-3.5-transcribe"),
               "batch Gemini model must not use the live path")
        expect(!GeminiLiveTranscription.handlesModel("whisper-large-v3"),
               "Whisper model must not use the live path")

        for model in ["gemini-3.5-transcribe", "gemini-3.5-transcribe-live", "whisper-large-v3"] {
            let batch = GeminiTranscription.handlesModel(model)
            let live = GeminiLiveTranscription.handlesModel(model)
            expect(!(batch && live), "batch and live routers must not both claim \(model)")
        }
    }

    // MARK: - 2

    private static func testSocketURLIsDerivedFromAnyGeminiBase() {
        expectEqual(GeminiLiveTranscription.socketURL(baseURL: "")?.absoluteString,
                    expectedSocketURL,
                    "empty base falls back to the default socket")
        expectEqual(GeminiLiveTranscription.socketURL(baseURL: "https://generativelanguage.googleapis.com/v1beta")?.absoluteString,
                    expectedSocketURL,
                    "https REST base upgrades to wss with the service path")
        expectEqual(GeminiLiveTranscription.socketURL(baseURL: "https://api.groq.com/openai/v1")?.absoluteString,
                    expectedSocketURL,
                    "non-Google (Groq) base falls back to the default socket")
        expectEqual(GeminiLiveTranscription.socketURL(baseURL: "wss://generativelanguage.googleapis.com/v1beta?key=secret")?.absoluteString,
                    expectedSocketURL,
                    "query parameters (secrets) are dropped")
        expectEqual(GeminiLiveTranscription.socketURL(baseURL: "ftp://example.com")?.absoluteString,
                    String?.none,
                    "unsupported scheme yields no socket URL")
    }

    // MARK: - 3

    private static func testSetupAsksForSmartModeAndVocabulary() {
        let message = setupMessageOrCrash(model: "gemini-3.5-transcribe-live",
                                          customVocabulary: "OmniFlow\nGroq,OmniFlow")
        let setup = jsonOrCrash(message)["setup"] as? [String: Any]
        expect(setup != nil, "setup message must contain a setup object")
        guard let setup = setup else { return }
        expectEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live",
                    "setup model is namespaced under models/")

        let generationConfig = setup["generationConfig"] as? [String: Any]
        expectEqual(generationConfig?["responseModalities"] as? [String], ["TEXT"],
                    "response modalities must be TEXT")

        let inputAudioTranscription = setup["inputAudioTranscription"] as? [String: Any]
        expectEqual(inputAudioTranscription?["mode"] as? String, "SMART",
                    "live smart mode is uppercase, unlike the batch API")
        expectEqual(inputAudioTranscription?["custom_vocabulary"] as? [String], ["OmniFlow", "Groq"],
                    "custom vocabulary is deduplicated")
        expect(inputAudioTranscription?["language_codes"] == nil,
               "language is auto-detected: language_codes must not be sent")

        let namespaced = setupMessageOrCrash(model: "models/gemini-3.5-transcribe-live",
                                             customVocabulary: "OmniFlow")
        expectEqual((jsonOrCrash(namespaced)["setup"] as? [String: Any])?["model"] as? String,
                    "models/gemini-3.5-transcribe-live",
                    "existing models/ prefix is not duplicated")

        let noVocabulary = setupMessageOrCrash(model: "gemini-3.5-transcribe-live",
                                               customVocabulary: "")
        let noVocabularySetup = (jsonOrCrash(noVocabulary)["setup"] as? [String: Any])?["inputAudioTranscription"] as? [String: Any]
        expect(noVocabularySetup?["custom_vocabulary"] == nil,
               "empty vocabulary is omitted, not sent as an empty list")
    }

    // MARK: - 4

    private static func testAudioFramesDeclareTheRealSampleRate() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let realtimeInput = jsonOrCrash(audioMessageOrCrash(pcm16: pcm, sampleRate: 24_000))["realtimeInput"] as? [String: Any]
        let audio = realtimeInput?["audio"] as? [String: Any]
        expectEqual(audio?["mimeType"] as? String, "audio/pcm;rate=24000",
                    "audio frames must declare the real 24 kHz rate")
        expectEqual(audio?["data"] as? String, pcm.base64EncodedString(),
                    "audio payload is base64 PCM")

        let endInput = jsonOrCrash(audioStreamEndMessageOrCrash())["realtimeInput"] as? [String: Any]
        expectEqual(endInput?["audioStreamEnd"] as? Bool, true,
                    "stream end message sets audioStreamEnd")
    }

    // MARK: - 5

    private static func testServerFramesAreClassified() {
        let partial = GeminiLiveTranscription.parseServerFrame(
            #"{"serverContent": {"inputTranscription": {"text": "Hi"}}}"#)
        expectEqual(partial.transcript, "Hi", "input transcription text is the transcript")
        expect(!partial.isComplete, "partial frame is not complete")
        expectEqual(partial.errorMessage, String?.none, "partial frame has no error")
        expect(!partial.isSetupComplete, "partial frame is not setup")

        let turnComplete = GeminiLiveTranscription.parseServerFrame(
            #"{"serverContent": {"turnComplete": true}}"#)
        expect(turnComplete.isComplete, "turnComplete completes the turn")
        expectEqual(turnComplete.transcript, String?.none, "turnComplete frame has no transcript")

        let generationComplete = GeminiLiveTranscription.parseServerFrame(
            #"{"serverContent": {"generationComplete": true}}"#)
        expect(generationComplete.isComplete, "generationComplete completes the turn")

        let setup = GeminiLiveTranscription.parseServerFrame(#"{"setupComplete": {}}"#)
        expect(setup.isSetupComplete, "setupComplete sets the flag")
        expect(!setup.isComplete, "setupComplete is not a completion")

        let failure = GeminiLiveTranscription.parseServerFrame(
            #"{"error": {"message": "Quota exceeded"}}"#)
        expectEqual(failure.errorMessage, "Quota exceeded", "error message surfaces")
        expect(failure.isComplete, "an error completes the turn")

        let junk = GeminiLiveTranscription.parseServerFrame("not json")
        expectEqual(junk.transcript, String?.none, "junk frame has no transcript")
        expect(!junk.isComplete, "junk frame is not complete")
        expectEqual(junk.errorMessage, String?.none, "junk frame has no error")
        expect(!junk.isSetupComplete, "junk frame is not setup")
    }
}
