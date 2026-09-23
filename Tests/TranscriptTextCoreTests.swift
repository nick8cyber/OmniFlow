import Foundation

enum TranscriptTextCoreTests {
    static func run() {
        testJSONTranscriptParsing()
        testNonTranscriptJSONFallsBackToUTF8()
        testInvalidTranscriptResponses()
        testHighConfidenceHallucinationsAreSuppressed()
        testPossibleRealSpeechIsPreserved()
        testPostProcessedTranscriptSanitization()
        testModeSpecificSanitization()
        testInstructionExecutionGuard()
    }

    private static func jsonData(_ string: String) -> Data {
        Data(string.utf8)
    }

    private static func parseOrCrash(_ data: Data,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) -> String {
        do {
            return try TranscriptionResponseParser.parse(data)
        } catch {
            fatalError("\(file):\(line): parse unexpectedly threw \(error)")
        }
    }

    // MARK: - 1

    private static func testJSONTranscriptParsing() {
        expectEqual(parseOrCrash(jsonData(#"{"text": "Synthetic transcript."}"#)),
                    "Synthetic transcript.",
                    "JSON text field is returned")
        expectEqual(parseOrCrash(jsonData(#"{"text": ""}"#)),
                    "",
                    "empty JSON text field stays empty")
    }

    // MARK: - 2

    private static func testNonTranscriptJSONFallsBackToUTF8() {
        // Body deliberately formatted with a two-space indent: the newline-join
        // fallback must preserve the original spacing of the source body.
        let body = "{\n  \"synthetic\": \"fallback\"\n}"
        expectEqual(parseOrCrash(jsonData(body)),
                    "{   \"synthetic\": \"fallback\" }",
                    "non-transcript JSON body is returned as joined UTF-8 text")
    }

    // MARK: - 3

    private static func testInvalidTranscriptResponses() {
        expectEqual(try? TranscriptionResponseParser.parse(Data()),
                    String?.none,
                    "empty body must throw, not return")
        expectThrows(try TranscriptionResponseParser.parse(jsonData(" \n\t ")),
                     "whitespace-only body must throw")
        expectThrows(try TranscriptionResponseParser.parse(jsonData("{malformed synthetic JSON")),
                     "malformed JSON must throw")
        expectThrows(try TranscriptionResponseParser.parse(Data([0xFF, 0xFE])),
                     "invalid UTF-8 body must throw")
    }

    // MARK: - 4

    private static func testHighConfidenceHallucinationsAreSuppressed() {
        expectEqual(parseOrCrash(jsonData(
            #"{"text": "Thank you.", "segments":[{"no_speech_prob": 0.1}]}"#)),
            "",
            "hallucination phrase with no_speech_prob at the 0.1 threshold is suppressed")
        expectEqual(parseOrCrash(jsonData(
            #"{"text": "  THANK YOU FOR WATCHING!!!  ", "segments":[{"no_speech_prob": 0.9}]}"#)),
            "",
            "normalized hallucination phrase with high no_speech_prob is suppressed")
    }

    // MARK: - 5

    private static func testPossibleRealSpeechIsPreserved() {
        expectEqual(parseOrCrash(jsonData(
            #"{"text": "Thank you.", "segments":[{"no_speech_prob": 0.099}]}"#)),
            "Thank you.",
            "no_speech_prob below the threshold keeps the text")
        expectEqual(parseOrCrash(jsonData(
            #"{"text": "Thank you.", "segments":[{"avg_logprob": -0.3}]}"#)),
            "Thank you.",
            "segments without no_speech_prob keep the text")
        expectEqual(parseOrCrash(jsonData(#"{"text": "Thank you."}"#)),
                    "Thank you.",
                    "response without segments keeps the text")
        expectEqual(parseOrCrash(jsonData(
            #"{"text": "Synthetic project update.", "segments":[{"no_speech_prob": 0.95}]}"#)),
            "Synthetic project update.",
            "non-hallucination speech is kept even with high no_speech_prob")
    }

    // MARK: - 6

    private static func testPostProcessedTranscriptSanitization() {
        expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("  \"Synthetic output.\" \n"),
                    "Synthetic output.",
                    "trims surrounding whitespace and one quote pair")
        expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("EMPTY"),
                    "",
                    "EMPTY sentinel becomes an empty string")
        expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("  \"EMPTY\"  "),
                    "",
                    "quoted EMPTY sentinel becomes an empty string")
        expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("empty"),
                    "empty",
                    "lowercase 'empty' is not a sentinel")
        expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("   \n\t "),
                    "",
                    "whitespace-only output becomes an empty string")
    }

    // MARK: - 7

    private static func testModeSpecificSanitization() {
        expectEqual(TranscriptOutputSanitizer.verbatimTranslation("  \"Synthetic translation.\" "),
                    "Synthetic translation.",
                    "verbatim translation strips whitespace and one quote pair")
        expectEqual(TranscriptOutputSanitizer.verbatimTranslation("\"EMPTY\""),
                    "EMPTY",
                    "verbatim translation preserves the literal EMPTY word")
        expectEqual(TranscriptOutputSanitizer.commandModeTranscript("  Keep \"command\" quotes  "),
                    "Keep \"command\" quotes",
                    "command mode only trims whitespace, inner quotes survive")
    }

    // MARK: - 8

    private static func testInstructionExecutionGuard() {
        // Assistant-style answer to a write request.
        expect(TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
            rawTranscript: "Write an email to the team about the launch.",
            cleanedTranscript: "Sure, here's a draft: Hi team, the launch is on Friday.",
            outputLanguage: ""),
               "assistant preamble on a write request must be flagged")

        // Low-overlap fulfillment: the model wrote the haiku instead of cleaning.
        expect(TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
            rawTranscript: "Write a haiku about the moon",
            cleanedTranscript: "Silver light above\nThe quiet mountain listens\nNight whispers softly",
            outputLanguage: ""),
               "low-overlap fulfillment must be flagged")

        // Honest cleanup of the same text.
        expect(!TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
            rawTranscript: "Please send an email to the team about Friday.",
            cleanedTranscript: "Please send an email to the team about Friday.",
            outputLanguage: ""),
               "identical honest cleanup must not be flagged")

        // Speaker really said "Sure, ..." — no assistant preamble added.
        expect(!TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
            rawTranscript: "Sure, the synthetic launch is Friday.",
            cleanedTranscript: "Sure, the synthetic launch is Friday.",
            outputLanguage: ""),
               "raw that already starts with the preamble must not be flagged")

        // Explicit output language disables the guard even for a translate request.
        expect(!TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
            rawTranscript: "Translate this to Italian",
            cleanedTranscript: "Traduci questo in italiano",
            outputLanguage: "Italian"),
               "explicit output language must bypass the guard")
    }
}
