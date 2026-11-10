import Foundation

enum ModelListServiceTests {
    static func run() {
        testDecodeModelIDs()
        testDecodeModelIDsRejectsGarbage()
        testFilterLLMModels()
        testDecodeDeduplicatesKeepingOrder()
    }

    private static func testDecodeModelIDs() {
        let json = """
        {"data":[{"id":"gemini-3.1-flash-lite"},{"id":"gemini-3.6-flash"},{"id":"gemini-embedding-2"}]}
        """.data(using: .utf8)!
        TestSupport.expectEqual(ModelListService.decodeModelIDs(json),
                                ["gemini-3.1-flash-lite", "gemini-3.6-flash", "gemini-embedding-2"])
    }

    private static func testDecodeModelIDsRejectsGarbage() {
        TestSupport.expectEqual(ModelListService.decodeModelIDs(Data("not json".utf8)), [])
        TestSupport.expectEqual(ModelListService.decodeModelIDs(Data("{\"models\":[]}".utf8)), [])
    }

    private static func testFilterLLMModels() {
        let filtered = ModelListService.filterLLMModels([
            "gemini-3.1-flash-lite",
            "gemini-embedding-2",
            "imagen-4",
            "gemini-3.5-transcribe",
            "gemini-2.5-flash-tts",
            "openai/gpt-oss-20b",
        ])
        TestSupport.expectEqual(filtered, ["gemini-3.1-flash-lite", "openai/gpt-oss-20b"])
    }

    private static func testDecodeDeduplicatesKeepingOrder() {
        let json = """
        {"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}
        """.data(using: .utf8)!
        TestSupport.expectEqual(ModelListService.decodeModelIDs(json), ["b", "a"])
    }
}
