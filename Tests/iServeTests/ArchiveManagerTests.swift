import XCTest
import ZIPFoundation
@testable import iServe

final class ArchiveManagerTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Round trip

    func testByteExactRoundTripForASingleFile() throws {
        let source = workDir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data((0..<10_000).map { UInt8($0 % 256) })
        let file = source.appendingPathComponent("data.bin")
        try payload.write(to: file)

        let archiveURL = workDir.appendingPathComponent("archive.zip")
        try ArchiveManager.createArchive(containing: [file], at: archiveURL)

        let destination = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ArchiveManager.extractArchive(at: archiveURL, to: destination)

        let extracted = try Data(contentsOf: destination.appendingPathComponent("data.bin"))
        XCTAssertEqual(extracted, payload)
    }

    func testNestedDirectoriesAreRecreatedExactly() throws {
        let source = workDir.appendingPathComponent("Folder", isDirectory: true)
        let nested = source.appendingPathComponent("Sub/Deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("top".utf8).write(to: source.appendingPathComponent("top.txt"))
        try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        // An empty directory should round-trip too.
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        let archiveURL = workDir.appendingPathComponent("nested.zip")
        try ArchiveManager.createArchive(containing: [source], at: archiveURL)

        let destination = workDir.appendingPathComponent("extracted-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ArchiveManager.extractArchive(at: archiveURL, to: destination)

        let topPath = destination.appendingPathComponent("Folder/top.txt")
        let deepPath = destination.appendingPathComponent("Folder/Sub/Deeper/deep.txt")
        var isDirectory: ObjCBool = false
        let emptyExists = FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Folder/Empty").path,
            isDirectory: &isDirectory
        )

        XCTAssertEqual(try String(contentsOf: topPath, encoding: .utf8), "top")
        XCTAssertEqual(try String(contentsOf: deepPath, encoding: .utf8), "deep")
        XCTAssertTrue(emptyExists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testMultipleSelectedItemsFromTheSameParentAreAllIncluded() throws {
        let parent = workDir.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fileA = parent.appendingPathComponent("a.txt")
        let fileB = parent.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)

        let archiveURL = workDir.appendingPathComponent("multi.zip")
        try ArchiveManager.createArchive(containing: [fileA, fileB], at: archiveURL)

        let destination = workDir.appendingPathComponent("extracted-multi", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ArchiveManager.extractArchive(at: archiveURL, to: destination)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8), "B")
    }

    // MARK: - Zip Slip protection

    func testEntryPathEscapingRootIsRejectedWithoutWritingAnything() throws {
        let archiveURL = workDir.appendingPathComponent("slip.zip")
        try makeRawArchive(at: archiveURL) { archive in
            try archive.addEntry(
                with: "../outside.txt",
                type: .file,
                uncompressedSize: Int64(4),
                provider: { _, _ in Data("evil".utf8) }
            )
        }

        let destination = workDir.appendingPathComponent("extracted-slip", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ArchiveManager.extractArchive(at: archiveURL, to: destination)) { error in
            XCTAssertEqual(error as? ArchiveManager.ArchiveError, .entryEscapesDestination)
        }
        let escapedPath = destination.deletingLastPathComponent().appendingPathComponent("outside.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedPath.path))
    }

    func testEntryPathWithEmbeddedTraversalComponentIsRejected() throws {
        let archiveURL = workDir.appendingPathComponent("slip2.zip")
        try makeRawArchive(at: archiveURL) { archive in
            try archive.addEntry(
                with: "sub/../../outside2.txt",
                type: .file,
                uncompressedSize: Int64(4),
                provider: { _, _ in Data("evil".utf8) }
            )
        }

        let destination = workDir.appendingPathComponent("extracted-slip2", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ArchiveManager.extractArchive(at: archiveURL, to: destination)) { error in
            XCTAssertEqual(error as? ArchiveManager.ArchiveError, .entryEscapesDestination)
        }
    }

    func testSymlinkEntryIsRefusedRatherThanMaterialized() throws {
        let archiveURL = workDir.appendingPathComponent("symlink.zip")
        try makeRawArchive(at: archiveURL) { archive in
            let target = Data("/etc/passwd".utf8)
            try archive.addEntry(
                with: "link",
                type: .symlink,
                uncompressedSize: Int64(target.count),
                provider: { _, _ in target }
            )
        }

        let destination = workDir.appendingPathComponent("extracted-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ArchiveManager.extractArchive(at: archiveURL, to: destination)) { error in
            XCTAssertEqual(error as? ArchiveManager.ArchiveError, .entrySymlinkRefused)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("link").path))
    }

    // MARK: - Helpers

    private func makeRawArchive(at url: URL, _ populate: (Archive) throws -> Void) throws {
        let archive = try Archive(url: url, accessMode: .create)
        try populate(archive)
    }
}
