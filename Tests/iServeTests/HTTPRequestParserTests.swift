import XCTest
@testable import iServe

final class HTTPRequestParserTests: XCTestCase {
    // MARK: - Valid requests

    func testParsesSimpleGetRequestInOneChunk() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n"
        let request = try XCTUnwrap(try parser.feed(Data(raw.utf8)))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.target, "/index.html")
        XCTAssertEqual(request.httpVersion, "HTTP/1.1")
        XCTAssertEqual(request.headers["Host"], "example.com")
    }

    func testParsesRequestFedOneByteAtATime() throws {
        var parser = HTTPRequestParser()
        let raw = "HEAD /a/b.css HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n"
        var completed: HTTPRequest?
        for byte in raw.utf8 {
            if let request = try parser.feed(Data([byte])) {
                completed = request
                break
            }
        }
        let request = try XCTUnwrap(completed)
        XCTAssertEqual(request.method, "HEAD")
        XCTAssertEqual(request.target, "/a/b.css")
        XCTAssertEqual(request.headers["Accept"], "*/*")
    }

    func testHeaderLookupIsCaseInsensitiveAndValuesAreTrimmed() throws {
        var parser = HTTPRequestParser()
        let raw = "GET / HTTP/1.1\r\nContent-Type:   text/plain   \r\n\r\n"
        let request = try XCTUnwrap(try parser.feed(Data(raw.utf8)))
        XCTAssertEqual(request.headers["content-type"], "text/plain")
        XCTAssertEqual(request.headers["CONTENT-TYPE"], "text/plain")
    }

    func testHttp10VersionIsAccepted() throws {
        var parser = HTTPRequestParser()
        let raw = "GET / HTTP/1.0\r\n\r\n"
        let request = try XCTUnwrap(try parser.feed(Data(raw.utf8)))
        XCTAssertEqual(request.httpVersion, "HTTP/1.0")
    }

    func testReturnsNilUntilBlankLineArrives() throws {
        var parser = HTTPRequestParser()
        XCTAssertNil(try parser.feed(Data("GET / HTTP/1.1\r\n".utf8)))
        XCTAssertNil(try parser.feed(Data("Host: example.com\r\n".utf8)))
        XCTAssertNotNil(try parser.feed(Data("\r\n".utf8)))
    }

    func testDrainRemainderReturnsBodyBytesThatArrivedInTheSameReadAsTheBlankLine() throws {
        var parser = HTTPRequestParser()
        // A real POST client very often writes headers and body in one
        // call, so they land in the very same network read.
        let raw = "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        let request = try XCTUnwrap(try parser.feed(Data(raw.utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(parser.drainRemainder(), Data("hello".utf8))
    }

    func testDrainRemainderIsEmptyWhenNothingFollowedTheBlankLine() throws {
        var parser = HTTPRequestParser()
        _ = try XCTUnwrap(try parser.feed(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertEqual(parser.drainRemainder(), Data())
    }

    // MARK: - Bounded limits

    func testRejectsRequestLineTooLong() {
        var parser = HTTPRequestParser(limits: .init(
            maxRequestLineLength: 16, maxHeaderLineLength: 1024, maxHeaderCount: 10, maxTotalHeaderBytes: 1024
        ))
        let raw = "GET /this-target-is-way-too-long-for-the-limit HTTP/1.1\r\n\r\n"
        XCTAssertThrowsError(try parser.feed(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .requestLineTooLong)
        }
    }

    func testRejectsRequestLineWithoutTerminatorOnceOverLimit() {
        var parser = HTTPRequestParser(limits: .init(
            maxRequestLineLength: 8, maxHeaderLineLength: 1024, maxHeaderCount: 10, maxTotalHeaderBytes: 1024
        ))
        // No CRLF anywhere in this chunk, so the parser must still bound its buffer.
        XCTAssertThrowsError(try parser.feed(Data("GET /much-too-long-a-target".utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .requestLineTooLong)
        }
    }

    func testRejectsHeaderLineTooLong() {
        var parser = HTTPRequestParser(limits: .init(
            maxRequestLineLength: 1024, maxHeaderLineLength: 16, maxHeaderCount: 10, maxTotalHeaderBytes: 1024
        ))
        let raw = "GET / HTTP/1.1\r\nX-Long: this-value-is-too-long\r\n\r\n"
        XCTAssertThrowsError(try parser.feed(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .headerLineTooLong)
        }
    }

    func testRejectsTooManyHeaders() {
        var parser = HTTPRequestParser(limits: .init(
            maxRequestLineLength: 1024, maxHeaderLineLength: 1024, maxHeaderCount: 2, maxTotalHeaderBytes: 4096
        ))
        let raw = "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n"
        XCTAssertThrowsError(try parser.feed(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .tooManyHeaders)
        }
    }

    func testRejectsHeaderSectionTooLargeEvenWithIndividuallyShortLines() {
        var parser = HTTPRequestParser(limits: .init(
            maxRequestLineLength: 1024, maxHeaderLineLength: 64, maxHeaderCount: 100, maxTotalHeaderBytes: 20
        ))
        let raw = "GET / HTTP/1.1\r\nA: 111\r\nB: 222\r\nC: 333\r\nD: 444\r\nE: 555\r\n\r\n"
        XCTAssertThrowsError(try parser.feed(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .headerSectionTooLarge)
        }
    }

    // MARK: - Malformed input

    func testRejectsRequestLineWithWrongTokenCount() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.feed(Data("GET /\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .malformedRequestLine)
        }
    }

    func testRejectsUnsupportedHttpVersion() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.feed(Data("GET / HTTP/2.0\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .unsupportedVersion)
        }
    }

    func testRejectsHeaderLineMissingColon() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.feed(Data("GET / HTTP/1.1\r\nNotAHeader\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .malformedHeaderLine)
        }
    }

    func testRejectsEmptyHeaderName() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.feed(Data("GET / HTTP/1.1\r\n: value\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .malformedHeaderLine)
        }
    }

    func testRejectsObsoleteHeaderLineFolding() {
        var parser = HTTPRequestParser()
        // A continuation line (leading whitespace, no colon) is rejected rather
        // than unfolded, per RFC 7230's guidance that senders must not use it.
        let raw = "GET / HTTP/1.1\r\nX-Custom: value\r\n continued\r\n\r\n"
        XCTAssertThrowsError(try parser.feed(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParser.ParseError, .malformedHeaderLine)
        }
    }
}
