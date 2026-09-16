import XCTest
@testable import iServe

final class MultipartFormDataParserTests: XCTestCase {
    private let boundary = "BOUNDARY123"

    private func body(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    func testParsesASingleFilePart() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let raw = body(
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\n" +
            "Content-Type: text/plain\r\n" +
            "\r\n" +
            "Hello, world!\r\n" +
            "--BOUNDARY123--\r\n"
        )

        let events = try parser.feed(raw)

        XCTAssertEqual(events, [
            .partBegan(fieldName: "file", filename: "hello.txt"),
            .partBodyChunk(Data("Hello, world!".utf8)),
            .partEnded,
            .finished,
        ])
    }

    func testParsesMultipleFileParts() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let raw = body(
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" +
            "\r\n" +
            "AAA\r\n" +
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"b.txt\"\r\n" +
            "\r\n" +
            "BBB\r\n" +
            "--BOUNDARY123--\r\n"
        )

        let events = try parser.feed(raw)

        XCTAssertEqual(events, [
            .partBegan(fieldName: "file", filename: "a.txt"),
            .partBodyChunk(Data("AAA".utf8)),
            .partEnded,
            .partBegan(fieldName: "file", filename: "b.txt"),
            .partBodyChunk(Data("BBB".utf8)),
            .partEnded,
            .finished,
        ])
    }

    func testNonFileFormFieldHasNilFilename() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let raw = body(
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"description\"\r\n" +
            "\r\n" +
            "hi\r\n" +
            "--BOUNDARY123--\r\n"
        )

        let events = try parser.feed(raw)

        XCTAssertEqual(events.first, .partBegan(fieldName: "description", filename: nil))
    }

    func testEmptyFileBodyProducesNoBodyChunkButStillEndsTheProperly() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let raw = body(
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"empty.txt\"\r\n" +
            "\r\n" +
            "\r\n" +
            "--BOUNDARY123--\r\n"
        )

        let events = try parser.feed(raw)

        XCTAssertEqual(events, [
            .partBegan(fieldName: "file", filename: "empty.txt"),
            .partEnded,
            .finished,
        ])
    }

    func testNoPartsAtAllJustTheFinalBoundary() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let events = try parser.feed(body("--BOUNDARY123--\r\n"))
        XCTAssertEqual(events, [.finished])
    }

    func testFilenameWithSpacesAndUnicodeParsesVerbatim() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let raw = body(
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"my café pic (1).jpg\"\r\n" +
            "\r\n" +
            "x\r\n" +
            "--BOUNDARY123--\r\n"
        )

        let events = try parser.feed(raw)

        XCTAssertEqual(events.first, .partBegan(fieldName: "file", filename: "my café pic (1).jpg"))
    }

    func testRejectsBodyNotStartingWithTheBoundary() {
        var parser = MultipartFormDataParser(boundary: boundary)
        XCTAssertThrowsError(try parser.feed(body("not a boundary at all, way too long to be ambiguous\r\n"))) { error in
            XCTAssertEqual(error as? MultipartFormDataParser.ParseError, .malformedDelimiter)
        }
    }

    func testPreservesExactBinaryContentIncludingBytesThatLookLikePartOfTheBoundary() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        // Includes a stray CR LF -- B sequence: a coincidental prefix match
        // of the real delimiter ("\r\n--BOUNDARY123") that must not trigger
        // an early, incorrect part end.
        let binary = Data([0x00, 0xFF, 0x10, 0x0D, 0x0A, 0x2D, 0x2D, 0x42, 0x01, 0x02])
        var raw = body("--BOUNDARY123\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bin\"\r\n\r\n")
        raw.append(binary)
        raw.append(body("\r\n--BOUNDARY123--\r\n"))

        let events = try parser.feed(raw)

        let chunks: [Data] = events.compactMap {
            if case .partBodyChunk(let data) = $0 { return data }
            return nil
        }
        let reconstructed = chunks.reduce(Data(), +)
        XCTAssertEqual(reconstructed, binary)
        XCTAssertEqual(events.last, .finished)
    }

    func testFeedingOneByteAtATimeReconstructsTheSameContentAsOneChunk() throws {
        var parser = MultipartFormDataParser(boundary: boundary)
        let raw = body(
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" +
            "\r\n" +
            "The quick brown fox jumps over the lazy dog.\r\n" +
            "--BOUNDARY123\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"b.txt\"\r\n" +
            "\r\n" +
            "second file\r\n" +
            "--BOUNDARY123--\r\n"
        )

        var allEvents: [MultipartFormDataParser.Event] = []
        for byte in raw {
            allEvents.append(contentsOf: try parser.feed(Data([byte])))
        }

        var filenames: [String?] = []
        var bodiesByPart: [[Data]] = []
        var currentPart: [Data]?
        for event in allEvents {
            switch event {
            case .partBegan(_, let filename):
                filenames.append(filename)
                if let currentPart { bodiesByPart.append(currentPart) }
                currentPart = []
            case .partBodyChunk(let chunk):
                currentPart?.append(chunk)
            case .partEnded:
                if let currentPart { bodiesByPart.append(currentPart) }
                currentPart = nil
            case .finished:
                break
            }
        }

        XCTAssertEqual(filenames, ["a.txt", "b.txt"])
        XCTAssertEqual(bodiesByPart.map { $0.reduce(Data(), +) }, [
            Data("The quick brown fox jumps over the lazy dog.".utf8),
            Data("second file".utf8),
        ])
        XCTAssertEqual(allEvents.last, .finished)
    }
}
