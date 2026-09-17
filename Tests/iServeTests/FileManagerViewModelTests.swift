import XCTest
@testable import iServe

final class FileManagerViewModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileManagerViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `StubFolderAccess` (from `FolderRootManagerTests.swift`) ignores
    /// whatever URL `select(_:)` is given and always grants scope, so it
    /// works fine here with a real temporary directory as the root, exactly
    /// as `LiveServerServiceTests.swift` already relies on.
    @MainActor
    private func makeStartedModel() -> FileManagerViewModel {
        let folders = FolderRootManager(access: StubFolderAccess(), store: MemoryBookmarkStore())
        folders.select(root)
        let model = FileManagerViewModel(folders: folders)
        model.start()
        return model
    }

    @MainActor
    func testEntriesListsFoldersBeforeFilesAlphabetically() throws {
        try Data().write(to: root.appendingPathComponent("b.txt"))
        try Data().write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ZFolder"), withIntermediateDirectories: true
        )

        let model = makeStartedModel()
        XCTAssertEqual(model.entries(in: root).map(\.name), ["ZFolder", "a.txt", "b.txt"])
        model.stop()
    }

    @MainActor
    func testRenameMovesFileAndRefusesNameCollision() throws {
        let fileURL = root.appendingPathComponent("original.txt")
        try Data("hi".utf8).write(to: fileURL)
        try Data("other".utf8).write(to: root.appendingPathComponent("taken.txt"))

        let model = makeStartedModel()
        model.rename(FileManagerEntry(url: fileURL), to: "renamed.txt", in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        XCTAssertNil(model.errorMessage)

        let renamedEntry = FileManagerEntry(url: root.appendingPathComponent("renamed.txt"))
        model.rename(renamedEntry, to: "taken.txt", in: root)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        model.stop()
    }

    /// A rename to ".." must never be treated as "move to the parent
    /// directory" — it should be refused outright, the same way a "/" in
    /// the requested name is.
    @MainActor
    func testRenameRefusesDotDotAndSlashNames() throws {
        let fileURL = root.appendingPathComponent("stay.txt")
        try Data("here".utf8).write(to: fileURL)

        let model = makeStartedModel()
        model.rename(FileManagerEntry(url: fileURL), to: "..", in: root)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        model.errorMessage = nil
        model.rename(FileManagerEntry(url: fileURL), to: "sub/escaped.txt", in: root)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        model.stop()
    }

    @MainActor
    func testDeleteRemovesFileFromDisk() throws {
        let fileURL = root.appendingPathComponent("gone.txt")
        try Data().write(to: fileURL)

        let model = makeStartedModel()
        model.delete([FileManagerEntry(url: fileURL)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    @MainActor
    func testDeleteReportsFailureWithoutStoppingOtherDeletions() throws {
        let existing = root.appendingPathComponent("existing.txt")
        try Data().write(to: existing)
        let missing = root.appendingPathComponent("missing.txt")

        let model = makeStartedModel()
        model.delete([FileManagerEntry(url: existing), FileManagerEntry(url: missing)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path))
        XCTAssertNotNil(model.errorMessage)
        model.stop()
    }

    @MainActor
    func testMoveRelocatesFileIntoDestinationDirectory() throws {
        let fileURL = root.appendingPathComponent("movable.txt")
        try Data("payload".utf8).write(to: fileURL)
        let destinationDir = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let model = makeStartedModel()
        model.move([FileManagerEntry(url: fileURL)], to: destinationDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let movedURL = destinationDir.appendingPathComponent("movable.txt")
        XCTAssertEqual(try String(contentsOf: movedURL, encoding: .utf8), "payload")
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    @MainActor
    func testMoveRefusesToMoveADirectoryIntoItsOwnDescendant() throws {
        let folderURL = root.appendingPathComponent("Parent", isDirectory: true)
        let nested = folderURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let model = makeStartedModel()
        model.move([FileManagerEntry(url: folderURL)], to: nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertNotNil(model.errorMessage)
        model.stop()
    }

    @MainActor
    func testCopyDuplicatesFileLeavingOriginalInPlace() throws {
        let fileURL = root.appendingPathComponent("source.txt")
        try Data("payload".utf8).write(to: fileURL)
        let destinationDir = root.appendingPathComponent("CopyDestination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let model = makeStartedModel()
        model.copy([FileManagerEntry(url: fileURL)], to: destinationDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let copiedURL = destinationDir.appendingPathComponent("source.txt")
        XCTAssertEqual(try String(contentsOf: copiedURL, encoding: .utf8), "payload")
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    @MainActor
    func testTextFileRoundTripsThroughReadAndWrite() throws {
        let fileURL = root.appendingPathComponent("notes.txt")
        try Data("before".utf8).write(to: fileURL)

        let model = makeStartedModel()
        XCTAssertEqual(model.readTextFile(fileURL), "before")
        XCTAssertTrue(model.writeTextFile("after", to: fileURL))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after")
        model.stop()
    }

    @MainActor
    func testCreateAndExtractZipArchiveRoundTrip() throws {
        let fileURL = root.appendingPathComponent("zipped.txt")
        try Data("zip me".utf8).write(to: fileURL)

        let model = makeStartedModel()
        model.createArchive(containing: [FileManagerEntry(url: fileURL)], in: root)
        let archiveURL = root.appendingPathComponent("Archive.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertNil(model.errorMessage)

        model.extractArchive(FileManagerEntry(url: archiveURL), in: root)
        let extractedURL = root.appendingPathComponent("Archive/zipped.txt")
        XCTAssertEqual(try String(contentsOf: extractedURL, encoding: .utf8), "zip me")
        model.stop()
    }

    /// Confirms the view model's `.7z` dispatch (based on
    /// `FileManagerEntry.archiveKind`) actually reaches
    /// `ArchiveManager.extractSevenZipArchive`, not just that the
    /// underlying function works in isolation (already covered by
    /// `ArchiveManagerTests`).
    @MainActor
    func testExtractArchiveDispatchesSevenZipEntriesToSevenZipContainer() throws {
        let base64 = """
        N3q8ryccAAQOX7LodgAAAAAAAAAhAAAAAAAAAAIuwuIBAAZkZWVwdG9wAAAAgTMHrg/Oha6S96Bt\
        85fwn+Bzo/TAs0/CGgr0x3mfN4C9TGOEUUYRDrMOcALoScfTzR1B8jpn6z/GPfGNcLS97rRcNzVQ\
        CcN0Lg1h6O1A+tcJpZdASjLz8gprk9IMAxH4KWJwaO/AAAAAFwYLAQlrAAcLAQABIwMBAQVdABA\
        AAAyAkgoBkzHQOwAA
        """
        guard let data = Data(base64Encoded: base64) else {
            XCTFail("failed to decode embedded 7z fixture")
            return
        }
        let archiveURL = root.appendingPathComponent("sample.7z")
        try data.write(to: archiveURL)

        let model = makeStartedModel()
        model.extractArchive(FileManagerEntry(url: archiveURL), in: root)

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sample/top.txt"), encoding: .utf8), "top")
        XCTAssertNil(model.errorMessage)
        model.stop()
    }
}
