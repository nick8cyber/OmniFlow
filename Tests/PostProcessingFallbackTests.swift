import Foundation

/// Fallback matrices of `PostProcessingService` (spec 11 §4.5–4.7) exercised
/// on a scripted in-process transport: no network, no AppKit.
enum PostProcessingFallbackTests {
    static func run() {
        testCleanupRetriesOnRateLimitThenSucceeds()
        testCleanupThrowsWhenBothAttemptsAreRateLimited()
        testCleanupRetriesOnEmptyOutput()
        testCleanupThrowsWhenBothAttemptsReturnEmptyOutput()
        testCleanupEmptySentinelIsNotRetried()
        testCleanupFallsBackToRawOnSuspectedInstructionExecution()
        testCleanupDoesNotRetryNonRetryableErrors()
        testCleanupCircuitBreakerSkipsTheRequest()
        testCommandPathRetriesOnRateLimit()
        testCommandPathHasNoInstructionGuard()
        testCommandPathCircuitBreakerReturnsSelectedText()
        testTranslatePathRetriesOnEmptyOutput()
        testTranslatePathDoesNotRegisterCooldowns()
    }

    // MARK: - Scripted transport

    private final class ScriptedTransport {
        enum Reaction {
            case content(String)
            case httpStatus(Int)
        }

        private let lock = NSLock()
        private let reactions: [String: Reaction]
        private let defaultReaction: Reaction
        private var requestedModels: [String] = []

        init(defaultReaction: Reaction, reactions: [String: Reaction] = [:]) {
            self.defaultReaction = defaultReaction
            self.reactions = reactions
        }

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requestedModels
        }

        func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let model = Self.model(in: request)
            let reaction = record(model)
            guard let url = request.url else {
                fatalError("ScriptedTransport: request without URL")
            }
            switch reaction {
            case .content(let text):
                let payload: [String: Any] = ["choices": [["message": ["content": text]]]]
                return (try JSONSerialization.data(withJSONObject: payload),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .httpStatus(let code):
                return (Data("synthetic error body".utf8),
                        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
        }

        private func record(_ model: String) -> Reaction {
            lock.lock()
            defer { lock.unlock() }
            requestedModels.append(model)
            return reactions[model] ?? defaultReaction
        }

        private static func model(in request: URLRequest) -> String {
            guard let body = request.httpBody,
                  let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return ""
            }
            return json["model"] as? String ?? ""
        }
    }

    // MARK: - Fixtures

    private static func makeContext() -> AppContext {
        AppContext(appName: nil,
                   bundleIdentifier: nil,
                   windowTitle: nil,
                   selectedText: nil,
                   currentActivity: "fallback suite",
                   contextSystemPrompt: nil,
                   contextPrompt: nil,
                   screenshotDataURL: nil,
                   screenshotMimeType: nil,
                   screenshotError: nil)
    }

    private static func makeService(primary: String,
                                    fallback: String,
                                    transport: ScriptedTransport,
                                    instructionGuard: Bool = true) -> PostProcessingService {
        PostProcessingService(apiKey: "synthetic-key",
                              baseURL: "https://provider.example/openai/v1",
                              preferredModel: primary,
                              preferredFallbackModel: fallback,
                              instructionExecutionGuardEnabled: instructionGuard,
                              transport: { try await transport.handle($0) })
    }

    private static func assertThrows(_ error: Error,
                                     is expected: PostProcessingError,
                                     _ message: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard let postError = error as? PostProcessingError else {
            fatalError("\(file):\(line): \(message) — expected PostProcessingError, got \(error)")
        }
        switch (postError, expected) {
        case (.rateLimited(let leftModel, _), .rateLimited(let rightModel, _)):
            expect(leftModel == rightModel, "\(file):\(line): \(message) — model \(leftModel) != \(rightModel)")
        case (.emptyOutput, .emptyOutput):
            break
        case (.requestFailed(let leftStatus, _), .requestFailed(let rightStatus, _)):
            expect(leftStatus == rightStatus, "\(file):\(line): \(message) — status \(leftStatus) != \(rightStatus)")
        default:
            fatalError("\(file):\(line): \(message) — unexpected error pair \(postError) / \(expected)")
        }
    }

    // MARK: - Cleanup path (spec 11 §4.5)

    private static func testCleanupRetriesOnRateLimitThenSucceeds() {
        runAndWait {
            let primary = "synthetic/cl.primary"
            let fallback = "synthetic/cl.fallback"
            let transport = ScriptedTransport(defaultReaction: .httpStatus(429),
                                              reactions: [fallback: .content("Cleaned text.")])
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.postProcess(transcript: "soo the synthetic cleanup retry",
                                                           context: makeContext(),
                                                           customVocabulary: "")
                expectEqual(result.transcript, "Cleaned text.",
                            "fallback model output is returned after the primary was rate-limited")
                expect(result.prompt.contains(fallback),
                       "the prompt must name the model that actually answered")
                expectEqual(transport.calls, [primary, fallback],
                            "rate-limited primary is retried on the fallback model")
            } catch {
                fatalError("\(#file):\(#line): postProcess unexpectedly threw \(error)")
            }
        }
    }

    private static func testCleanupThrowsWhenBothAttemptsAreRateLimited() {
        runAndWait {
            let primary = "synthetic/cl.rr.primary"
            let fallback = "synthetic/cl.rr.fallback"
            let transport = ScriptedTransport(defaultReaction: .httpStatus(429))
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                _ = try await service.postProcess(transcript: "synthetic both rate limited",
                                                  context: makeContext(),
                                                  customVocabulary: "")
                expect(false, "both models rate-limited must throw")
            } catch {
                assertThrows(error, is: .rateLimited(model: fallback, retryAfter: 60),
                             "the fallback's rate limit is the surfaced failure")
                expectEqual(transport.calls, [primary, fallback],
                            "both models were asked")
            }
        }
    }

    private static func testCleanupRetriesOnEmptyOutput() {
        runAndWait {
            let primary = "synthetic/cl.empty.primary"
            let fallback = "synthetic/cl.empty.fallback"
            let transport = ScriptedTransport(defaultReaction: .httpStatus(429),
                                              reactions: [primary: .content("   "),
                                                          fallback: .content("Recovered transcript.")])
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.postProcess(transcript: "synthetic empty output retry",
                                                           context: makeContext(),
                                                           customVocabulary: "")
                expectEqual(result.transcript, "Recovered transcript.",
                            "whitespace-only output is treated as retryable")
                expectEqual(transport.calls, [primary, fallback],
                            "empty primary output falls through to the fallback model")
            } catch {
                fatalError("\(#file):\(#line): postProcess unexpectedly threw \(error)")
            }
        }
    }

    private static func testCleanupThrowsWhenBothAttemptsReturnEmptyOutput() {
        runAndWait {
            let transport = ScriptedTransport(defaultReaction: .content(" \n\t "))
            let service = makeService(primary: "synthetic/cl.ee.primary",
                                      fallback: "synthetic/cl.ee.fallback",
                                      transport: transport)
            do {
                _ = try await service.postProcess(transcript: "synthetic both empty",
                                                  context: makeContext(),
                                                  customVocabulary: "")
                expect(false, "both models returning empty output must throw")
            } catch {
                assertThrows(error, is: .emptyOutput, "the second empty output surfaces")
            }
        }
    }

    private static func testCleanupEmptySentinelIsNotRetried() {
        // Parity with the reference: the empty check runs on the raw model
        // output, before sanitization — so a literal EMPTY sentinel (which the
        // sanitizer maps to "") is returned as an empty success and does NOT
        // trigger the fallback. Pinned on purpose.
        runAndWait {
            let primary = "synthetic/cl.sentinel.primary"
            let transport = ScriptedTransport(defaultReaction: .content("EMPTY"))
            let service = makeService(primary: primary,
                                      fallback: "synthetic/cl.sentinel.fallback",
                                      transport: transport)
            do {
                let result = try await service.postProcess(transcript: "synthetic sentinel output",
                                                           context: makeContext(),
                                                           customVocabulary: "")
                expectEqual(result.transcript, "",
                            "the EMPTY sentinel sanitizes to an empty transcript")
                expectEqual(transport.calls, [primary],
                            "the sentinel does not trigger the fallback model")
            } catch {
                fatalError("\(#file):\(#line): postProcess unexpectedly threw \(error)")
            }
        }
    }

    private static func testCleanupFallsBackToRawOnSuspectedInstructionExecution() {
        runAndWait {
            let transcript = "Write a short story about the moon"
            let answered = "Sure, here's a short story about the moon and a quiet night."
            let transport = ScriptedTransport(defaultReaction: .content(answered))
            let service = makeService(primary: "synthetic/cl.guard.primary",
                                      fallback: "synthetic/cl.guard.fallback",
                                      transport: transport)
            do {
                let result = try await service.postProcess(transcript: transcript,
                                                           context: makeContext(),
                                                           customVocabulary: "")
                expectEqual(result.transcript, transcript,
                            "both attempts answering the instruction fall back to the raw transcript")
                expectEqual(result.prompt, "",
                            "the raw fallback carries no prompt")
                expectEqual(transport.calls.count, 2,
                            "the guard sends the retry to the fallback model before giving up")
            } catch {
                fatalError("\(#file):\(#line): postProcess unexpectedly threw \(error)")
            }
        }
    }

    private static func testCleanupDoesNotRetryNonRetryableErrors() {
        runAndWait {
            let transport = ScriptedTransport(defaultReaction: .httpStatus(500))
            let service = makeService(primary: "synthetic/cl.500.primary",
                                      fallback: "synthetic/cl.500.fallback",
                                      transport: transport)
            do {
                _ = try await service.postProcess(transcript: "synthetic server error",
                                                  context: makeContext(),
                                                  customVocabulary: "")
                expect(false, "HTTP 500 must throw")
            } catch {
                assertThrows(error, is: .requestFailed(500, ""), "HTTP 500 surfaces as requestFailed")
                expectEqual(transport.calls, ["synthetic/cl.500.primary"],
                            "a non-retryable error must not reach the fallback model")
            }
        }
    }

    private static func testCleanupCircuitBreakerSkipsTheRequest() {
        runAndWait {
            let primary = "synthetic/cl.cb.primary"
            let fallback = "synthetic/cl.cb.fallback"
            await LLMCooldownManager.shared.setCooldown(primary, retryAfterSeconds: 300)
            await LLMCooldownManager.shared.setCooldown(fallback, retryAfterSeconds: 300)
            let transport = ScriptedTransport(defaultReaction: .content("should not be reached"))
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.postProcess(transcript: "synthetic circuit breaker",
                                                           context: makeContext(),
                                                           customVocabulary: "")
                expectEqual(result.transcript, "synthetic circuit breaker",
                            "circuit breaker returns the raw transcript")
                expectEqual(result.skippedCooldown, true,
                            "circuit breaker must be flagged via skippedCooldown")
                expectEqual(transport.calls, [],
                            "no request is sent when both models are cooling down")
            } catch {
                fatalError("\(#file):\(#line): postProcess unexpectedly threw \(error)")
            }
        }
    }

    // MARK: - Command path (spec 11 §4.6)

    private static func testCommandPathRetriesOnRateLimit() {
        runAndWait {
            let primary = "synthetic/cmd.rl.primary"
            let fallback = "synthetic/cmd.rl.fallback"
            let transport = ScriptedTransport(defaultReaction: .httpStatus(429),
                                              reactions: [fallback: .content("Edited text")])
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.commandTransform(selectedText: "  Selected text  ",
                                                                voiceCommand: "make it formal",
                                                                context: makeContext(),
                                                                customVocabulary: "")
                expectEqual(result.transcript, "Edited text",
                            "command transform uses the fallback model after a rate limit")
                expectEqual(transport.calls, [primary, fallback],
                            "rate-limited command attempt is retried once")
            } catch {
                fatalError("\(#file):\(#line): commandTransform unexpectedly threw \(error)")
            }
        }
    }

    private static func testCommandPathHasNoInstructionGuard() {
        runAndWait {
            // The cleanup guard would flag an assistant preamble; the command
            // path must accept the answer as the replacement text.
            let transport = ScriptedTransport(defaultReaction: .content("Sure, here's your formal rewrite."))
            let service = makeService(primary: "synthetic/cmd.guard.primary",
                                      fallback: "synthetic/cmd.guard.fallback",
                                      transport: transport)
            do {
                let result = try await service.commandTransform(selectedText: "Selected text",
                                                                voiceCommand: "write an email reply",
                                                                context: makeContext(),
                                                                customVocabulary: "")
                expectEqual(result.transcript, "Sure, here's your formal rewrite.",
                            "command output is accepted without the instruction guard")
                expectEqual(transport.calls.count, 1,
                            "no instruction-guard retry happens on the command path")
            } catch {
                fatalError("\(#file):\(#line): commandTransform unexpectedly threw \(error)")
            }
        }
    }

    private static func testCommandPathCircuitBreakerReturnsSelectedText() {
        runAndWait {
            let primary = "synthetic/cmd.cb.primary"
            let fallback = "synthetic/cmd.cb.fallback"
            await LLMCooldownManager.shared.setCooldown(primary, retryAfterSeconds: 300)
            await LLMCooldownManager.shared.setCooldown(fallback, retryAfterSeconds: 300)
            let transport = ScriptedTransport(defaultReaction: .content("should not be reached"))
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.commandTransform(selectedText: "  Selected text  ",
                                                                voiceCommand: "make it formal",
                                                                context: makeContext(),
                                                                customVocabulary: "")
                // Spec 11 §6: the command path returns the selected text with
                // an empty prompt and (unlike cleanup) no skippedCooldown flag.
                expectEqual(result.transcript, "Selected text",
                            "command circuit breaker keeps the selected text trimmed")
                expectEqual(result.prompt, "",
                            "command circuit breaker carries no prompt")
                expectEqual(transport.calls, [], "no request is sent")
            } catch {
                fatalError("\(#file):\(#line): commandTransform unexpectedly threw \(error)")
            }
        }
    }

    // MARK: - Translate path (spec 11 §4.7)

    private static func testTranslatePathRetriesOnEmptyOutput() {
        runAndWait {
            let primary = "synthetic/tr.empty.primary"
            let fallback = "synthetic/tr.empty.fallback"
            let transport = ScriptedTransport(defaultReaction: .httpStatus(429),
                                              reactions: [primary: .content("   "),
                                                          fallback: .content("Parole sintetiche")])
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.translateVerbatim(transcript: "Synthetic words",
                                                                 targetLanguage: "Italian")
                expectEqual(result.transcript, "Parole sintetiche",
                            "empty translation output retries on the fallback model")
                expectEqual(transport.calls, [primary, fallback],
                            "both models were asked")
            } catch {
                fatalError("\(#file):\(#line): translateVerbatim unexpectedly threw \(error)")
            }
        }
    }

    private static func testTranslatePathDoesNotRegisterCooldowns() {
        runAndWait {
            let primary = "synthetic/tr.429.primary"
            let fallback = "synthetic/tr.429.fallback"
            let transport = ScriptedTransport(defaultReaction: .httpStatus(429),
                                              reactions: [fallback: .content("Traduzione sintetica")])
            let service = makeService(primary: primary, fallback: fallback, transport: transport)
            do {
                let result = try await service.translateVerbatim(transcript: "Synthetic words",
                                                                 targetLanguage: "Italian")
                expectEqual(result.transcript, "Traduzione sintetica",
                            "translate retries after HTTP 429")
            } catch {
                fatalError("\(#file):\(#line): translateVerbatim unexpectedly threw \(error)")
            }
            let cooldown = LLMCooldownManager.shared
            let primaryCooling = await cooldown.isInCooldown(primary)
            let fallbackCooling = await cooldown.isInCooldown(fallback)
            expect(!primaryCooling,
                   "translate path must not write rate-limit cooldowns (primary)")
            expect(!fallbackCooling,
                   "translate path must not write rate-limit cooldowns (fallback)")
        }
    }

    // MARK: - Helpers

    private static func runAndWait(_ body: @escaping () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            semaphore.signal()
        }
        semaphore.wait()
    }
}
