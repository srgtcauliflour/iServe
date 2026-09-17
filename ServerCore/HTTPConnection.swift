import Foundation
import Network

/// Owns exactly one accepted `NWConnection`: reads bounded chunks, feeds them to
/// an `HTTPRequestParser`, dispatches a completed request through the shared
/// `HTTPRouter`, writes one response, then closes.
///
/// v0.1 does not support keep-alive or pipelining: every connection serves at most
/// one response before being cancelled. That keeps this first transport
/// implementation's lifecycle simple and trivially bounded; a later issue can add
/// persistent connections behind an ADR if the product needs them.
actor HTTPConnection {
    nonisolated let id = UUID()

    private let connection: NWConnection
    private let router: any HTTPRouter
    private let limits: HTTPServerLimits
    private let requestLog: RequestLog?
    /// `nil` means every request is let through unchecked — see
    /// `ServerCore/ServerCredentials.swift`.
    private let credentials: ServerCredentials?
    /// Shared with every other connection this session accepts (v0.3,
    /// password-only cookie login — `docs/adr/0008-password-only-cookie-login.md`)
    /// — a session cookie minted on one connection must be honored by the
    /// next, unlike everything else here, which is scoped to just this
    /// one connection.
    private let sessionTokens: SessionTokenStore
    private let onClose: @Sendable (UUID) -> Void

    private var parser: HTTPRequestParser
    private var idleTimeoutTask: Task<Void, Never>?
    private var lifetimeTimeoutTask: Task<Void, Never>?
    private var streamingFile: FileChunkReader?
    private var uploadState: UploadState?
    private var zipDownloadState: ZipDownloadState?
    private var webDAVPutState: WebDAVPutState?
    private var loginState: LoginState?
    /// A ZIP built for the *current* response, in the app's own temporary
    /// directory rather than the served root. Set just before responding
    /// with it, deleted in `close()` — the one place every termination
    /// path (a clean finish, a client disconnect mid-stream, a timeout)
    /// already funnels through — so it's cleaned up exactly once no matter
    /// how the connection ends.
    private var pendingZipCleanupURL: URL?
    private var didClose = false
    private var didRespond = false

    /// Everything `HTTPConnection` tracks while streaming a POST upload's
    /// body straight to disk (v0.2). One struct rather than several loose
    /// optionals so `close()`/failure paths can't forget to clean up part
    /// of it.
    private struct UploadState {
        let request: HTTPRequest
        let directoryPath: String
        var parser: MultipartFormDataParser
        let contentLength: Int
        var bytesConsumed = 0
        var currentFileWriter: FileChunkWriter?
        var currentFileURL: URL?
        var uploadedFileNames: [String] = []
    }

    /// Everything tracked while accumulating a "download selected as ZIP"
    /// POST body (v0.3) — just a small list of selected names, so unlike
    /// `UploadState` this only ever buffers in memory, bounded by
    /// `limits.maxZipSelectionBytes`.
    private struct ZipDownloadState {
        let request: HTTPRequest
        let directoryPath: String
        let contentLength: Int
        var buffer = Data()
    }

    /// Everything tracked while streaming a WebDAV `PUT`'s body to its
    /// temporary sibling file (v0.3, `docs/adr/0005-webdav-write-operations.md`).
    /// The real destination is never touched until `finishWebDAVPut()`
    /// replaces it in one atomic step, so a failure at any point here only
    /// ever costs the temporary file, never a pre-existing destination.
    private struct WebDAVPutState {
        let request: HTTPRequest
        let authorization: WebDAVPutAuthorization
        let writer: FileChunkWriter
        let contentLength: Int
        var bytesConsumed = 0
    }

    /// Everything tracked while accumulating the password-only login
    /// form's POST body (v0.3, `docs/adr/0008-password-only-cookie-login.md`)
    /// — just a password and a redirect path, so like `ZipDownloadState`
    /// this only ever buffers in memory, bounded by `limits.maxLoginBodyBytes`.
    private struct LoginState {
        let request: HTTPRequest
        let contentLength: Int
        var buffer = Data()
    }

    init(
        connection: NWConnection,
        router: any HTTPRouter,
        limits: HTTPServerLimits,
        requestLog: RequestLog? = nil,
        credentials: ServerCredentials? = nil,
        sessionTokens: SessionTokenStore = SessionTokenStore(),
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.limits = limits
        self.requestLog = requestLog
        self.credentials = credentials
        self.sessionTokens = sessionTokens
        self.onClose = onClose
        self.parser = HTTPRequestParser(limits: limits.parserLimits)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleState(state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        scheduleLifetimeTimeout()
        scheduleIdleTimeout()
        receiveMore()
    }

    /// Cancels the connection and any pending timeouts. Safe to call more than
    /// once; only the first call has any effect.
    func close() {
        guard !didClose else { return }
        didClose = true
        idleTimeoutTask?.cancel()
        lifetimeTimeoutTask?.cancel()
        idleTimeoutTask = nil
        lifetimeTimeoutTask = nil
        streamingFile?.close()
        streamingFile = nil
        discardIncompleteUpload()
        zipDownloadState = nil
        loginState = nil
        discardIncompleteWebDAVPut()
        if let pendingZipCleanupURL {
            try? FileManager.default.removeItem(at: pendingZipCleanupURL)
            self.pendingZipCleanupURL = nil
        }
        connection.cancel()
        onClose(id)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            close()
        default:
            break
        }
    }

    private func receiveMore() {
        guard !didClose, !didRespond else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: limits.readChunkSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, didError: error != nil) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, didError: Bool) async {
        guard !didClose, !didRespond else { return }
        if didError {
            close()
            return
        }
        if let data, !data.isEmpty {
            resetIdleTimeout()
            if uploadState != nil {
                processUploadBytes(data)
                guard !didRespond, !didClose else { return }
            } else if zipDownloadState != nil {
                processZipDownloadBytes(data)
                guard !didRespond, !didClose else { return }
            } else if webDAVPutState != nil {
                processWebDAVPutBytes(data)
                guard !didRespond, !didClose else { return }
            } else if loginState != nil {
                processLoginBytes(data)
                guard !didRespond, !didClose else { return }
            } else {
                do {
                    if let request = try parser.feed(data) {
                        let leftover = parser.drainRemainder()
                        await respond(to: request, leftoverBodyBytes: leftover)
                        guard !didRespond, !didClose else { return }
                    }
                } catch {
                    respond(withParseError: error)
                    return
                }
            }
        }
        if isComplete {
            close()
            return
        }
        receiveMore()
    }

    /// `docs/SECURITY.md`'s mandatory pipeline: authenticate before
    /// authorizing a capability, so this runs before `dispatch(_:leftoverBodyBytes:)`
    /// — GET/HEAD never reach `router.route(_:)`, and POST never reaches
    /// `beginUpload`/`beginZipDownload`, without the right credentials.
    /// Nothing about the request has been authorized yet at this point, so
    /// no body byte has been read either way.
    ///
    /// Checked in order (v0.3, password-only cookie login —
    /// `docs/adr/0008-password-only-cookie-login.md`): a valid session
    /// cookie (minted by an earlier successful login on *any* connection
    /// this session has accepted — `sessionTokens` is shared); a `POST`
    /// to the reserved login path, handled entirely here rather than ever
    /// reaching `dispatch`; or valid HTTP Basic credentials, kept working
    /// unchanged for WebDAV/API-style clients that have no way to follow
    /// an HTML login form or hold a cookie the way a browser does.
    ///
    /// Failing all three, the login page (instead of a bare `401`) is
    /// shown only for a `GET`/`HEAD` — what a browser actually navigates
    /// with — that carries *no* `Authorization` header at all: a client
    /// that already attempted Basic Auth (a WebDAV client, `curl -u`, or
    /// a browser with cached credentials) gets the exact same `401`/
    /// `WWW-Authenticate` challenge as before, so its own retry-with-
    /// credentials flow keeps working unchanged. This makes the login
    /// page strictly additive: nothing that was already sending
    /// `Authorization` sees any behavior change at all.
    private func respond(to request: HTTPRequest, leftoverBodyBytes: Data) async {
        guard let credentials else {
            dispatch(request, leftoverBodyBytes: leftoverBodyBytes)
            return
        }
        if let token = Self.sessionCookie(from: request), await sessionTokens.isValid(token) {
            dispatch(request, leftoverBodyBytes: leftoverBodyBytes)
            return
        }
        if request.method == "POST", let path = Self.pathIgnoringQuery(request.target), path == LoginPageRenderer.path {
            beginLoginSubmission(for: request, leftoverBodyBytes: leftoverBodyBytes)
            return
        }
        if Self.isAuthorized(request, credentials: credentials) {
            dispatch(request, leftoverBodyBytes: leftoverBodyBytes)
            return
        }
        guard (request.method == "GET" || request.method == "HEAD"), request.headers["Authorization"] == nil else {
            respond(with: .unauthorized(), request: request)
            return
        }
        let redirect = Self.sanitizedRedirectPath(Self.pathIgnoringQuery(request.target))
        respond(
            with: .html(LoginPageRenderer.render(redirect: redirect)),
            suppressBody: request.method == "HEAD",
            request: request
        )
    }

    private func dispatch(_ request: HTTPRequest, leftoverBodyBytes: Data) {
        switch request.method {
        case "GET", "HEAD":
            respond(with: router.route(request), suppressBody: request.method == "HEAD", request: request)
        case "POST":
            if Self.isFormURLEncoded(request.headers["Content-Type"]) {
                beginZipDownload(for: request, leftoverBodyBytes: leftoverBodyBytes)
            } else {
                beginUpload(for: request, leftoverBodyBytes: leftoverBodyBytes)
            }
        case "OPTIONS":
            respond(with: .webDAVOptions(), request: request)
        case "PROPFIND":
            respondToPropfind(request)
        case "MKCOL":
            respondToWebDAVRoute(request) { router.routeWebDAVMkcol(path: $0) }
        case "DELETE":
            respondToWebDAVRoute(request) { router.routeWebDAVDelete(path: $0) }
        case "MOVE":
            respondToWebDAVCopyOrMove(request, isMove: true)
        case "COPY":
            respondToWebDAVCopyOrMove(request, isMove: false)
        case "PUT":
            beginWebDAVPut(for: request, leftoverBodyBytes: leftoverBodyBytes)
        default:
            respond(with: .notImplemented(method: request.method), request: request)
        }
    }

    // MARK: - WebDAV (v0.3 read operations)

    /// Unlike an upload or ZIP selection, `PROPFIND`'s own request body (if
    /// any) is never read — this server doesn't parse it
    /// (`docs/adr/0004-webdav-read-operations.md`), so there's nothing to
    /// buffer: this responds synchronously from headers alone, exactly like
    /// GET/HEAD.
    private func respondToPropfind(_ request: HTTPRequest) {
        guard let path = Self.pathIgnoringQuery(request.target) else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let depth = Self.webDAVDepth(from: request.headers["Depth"]) else {
            respond(with: .badRequest("Depth must be 0 or 1"), request: request)
            return
        }
        guard let response = router.routeWebDAVPropfind(path: path, depth: depth) else {
            respond(with: .notImplemented(method: request.method), request: request)
            return
        }
        respond(with: response, request: request)
    }

    /// Only `0` and `1` are accepted — a missing header, `infinity`, or
    /// anything else is `nil`, which the caller turns into `400`. See
    /// `ServerCore/HTTPRouter.swift`'s `WebDAVDepth` and
    /// `docs/adr/0004-webdav-read-operations.md`.
    private static func webDAVDepth(from header: String?) -> WebDAVDepth? {
        switch header {
        case "0": return .zero
        case "1": return .one
        default: return nil
        }
    }

    // MARK: - WebDAV (v0.3 write operations)

    /// Shared shape for `MKCOL`/`DELETE`: like `PROPFIND`, neither reads a
    /// request body, so this responds synchronously from the path alone.
    /// See `docs/adr/0005-webdav-write-operations.md`.
    private func respondToWebDAVRoute(_ request: HTTPRequest, _ route: (String) -> HTTPResponse?) {
        guard let path = Self.pathIgnoringQuery(request.target) else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let response = route(path) else {
            respond(with: .notImplemented(method: request.method), request: request)
            return
        }
        respond(with: response, request: request)
    }

    /// `MOVE`/`COPY` read no body either — the source path plus the
    /// `Destination`/`Overwrite` headers fully determine the response.
    private func respondToWebDAVCopyOrMove(_ request: HTTPRequest, isMove: Bool) {
        guard let path = Self.pathIgnoringQuery(request.target) else {
            respond(with: .notFound(), request: request)
            return
        }
        // RFC 4918 §10.6: any value other than exactly "F" means overwrite.
        let overwrite = request.headers["Overwrite"]?.uppercased() != "F"
        let destination = request.headers["Destination"]
        let response = isMove
            ? router.routeWebDAVMove(sourcePath: path, destinationHeader: destination, overwrite: overwrite)
            : router.routeWebDAVCopy(sourcePath: path, destinationHeader: destination, overwrite: overwrite)
        guard let response else {
            respond(with: .notImplemented(method: request.method), request: request)
            return
        }
        respond(with: response, request: request)
    }

    /// Called once headers are parsed for a `PUT`. Authorizes the whole
    /// request up front exactly like `beginUpload` — `Content-Length`
    /// present and within `limits.maxWebDAVPutBytes`, and
    /// `router.authorizeWebDAVPut` accepts the path — before reading a
    /// single body byte.
    private func beginWebDAVPut(for request: HTTPRequest, leftoverBodyBytes: Data) {
        guard let path = Self.pathIgnoringQuery(request.target) else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let contentLengthText = request.headers["Content-Length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            respond(with: .lengthRequired(), request: request)
            return
        }
        guard contentLength <= limits.maxWebDAVPutBytes else {
            respond(with: .payloadTooLarge(), request: request)
            return
        }
        guard let authorization = router.authorizeWebDAVPut(path: path) else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let writer = FileChunkWriter(url: authorization.temporaryURL, maxBytes: limits.maxWebDAVPutBytes) else {
            respond(with: .internalServerError(), request: request)
            return
        }

        webDAVPutState = WebDAVPutState(
            request: request, authorization: authorization, writer: writer, contentLength: contentLength
        )
        guard !leftoverBodyBytes.isEmpty else { return }
        processWebDAVPutBytes(leftoverBodyBytes)
    }

    /// Writes newly received bytes straight to the temporary sibling file,
    /// bounded to at most this `PUT`'s declared `Content-Length` regardless
    /// of how much more the client actually sends — the same discipline as
    /// an upload's body.
    private func processWebDAVPutBytes(_ data: Data) {
        guard var state = webDAVPutState else { return }
        let remainingAllowed = max(0, state.contentLength - state.bytesConsumed)
        let consuming = Data(data.prefix(remainingAllowed))
        state.bytesConsumed += consuming.count
        do {
            try state.writer.write(consuming)
        } catch {
            webDAVPutState = state
            failWebDAVPut()
            return
        }
        webDAVPutState = state
        if state.bytesConsumed >= state.contentLength {
            finishWebDAVPut()
        }
    }

    /// Every declared body byte has arrived: close the temporary file and
    /// replace the real destination with it in one step — `replaceItemAt`
    /// when it already existed (an atomic overwrite), `moveItem` otherwise
    /// (an atomic same-volume rename) — so a pre-existing file is never
    /// left partially overwritten.
    private func finishWebDAVPut() {
        guard let state = webDAVPutState else { return }
        webDAVPutState = nil
        state.writer.close()
        do {
            if state.authorization.alreadyExists {
                _ = try FileManager.default.replaceItemAt(state.authorization.destinationURL, withItemAt: state.authorization.temporaryURL)
            } else {
                try FileManager.default.moveItem(at: state.authorization.temporaryURL, to: state.authorization.destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: state.authorization.temporaryURL)
            respond(with: .internalServerError(), request: state.request)
            return
        }
        respond(with: state.authorization.alreadyExists ? .noContent() : .created(), request: state.request)
    }

    private func failWebDAVPut() {
        guard let state = webDAVPutState else { return }
        discardIncompleteWebDAVPut()
        respond(with: .badRequest("Upload failed"), request: state.request)
    }

    /// Closes the writer and deletes the temporary file only — the real
    /// destination (if any) was never touched, so there's nothing else to
    /// undo. Safe to call with no `PUT` in flight.
    private func discardIncompleteWebDAVPut() {
        guard let state = webDAVPutState else { return }
        state.writer.close()
        try? FileManager.default.removeItem(at: state.authorization.temporaryURL)
        webDAVPutState = nil
    }

    private func respond(withParseError error: Error) {
        guard let parseError = error as? HTTPRequestParser.ParseError else {
            respond(with: .badRequest())
            return
        }
        switch parseError {
        case .requestLineTooLong:
            respond(with: .uriTooLong())
        case .headerLineTooLong, .tooManyHeaders, .headerSectionTooLarge:
            respond(with: .requestHeaderFieldsTooLarge())
        case .malformedRequestLine, .malformedHeaderLine, .unsupportedVersion:
            respond(with: .badRequest())
        }
    }

    private func respond(with response: HTTPResponse, suppressBody: Bool = false, request: HTTPRequest? = nil) {
        guard !didClose, !didRespond else { return }
        didRespond = true
        // The idle-read timeout only guards the request-reading phase; once a
        // response begins, backpressure on the send (and the connection-lifetime
        // cap) is what bounds things, so a slow-but-progressing file transfer
        // isn't cut short by a timer meant for a client that stalls mid-request.
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil

        if let request, let requestLog {
            let bytes = suppressBody ? 0 : Self.declaredBodyLength(response.body)
            Task {
                await requestLog.record(method: request.method, path: request.target, status: response.status, bytes: bytes)
            }
        }

        let head = response.headEncoded()
        switch response.body {
        case .empty:
            sendFinal(head)
        case .data(let data):
            var payload = head
            if !suppressBody { payload.append(data) }
            sendFinal(payload)
        case .file(let file):
            guard !suppressBody else {
                sendFinal(head)
                return
            }
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    Task { await self.close() }
                    return
                }
                Task { await self.beginStreaming(file) }
            })
        }
    }

    private func sendFinal(_ payload: Data) {
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { await self.close() }
        })
    }

    private func beginStreaming(_ file: HTTPFileBody) {
        guard !didClose else { return }
        guard let reader = FileChunkReader(url: file.url, offset: file.offset, length: file.length, chunkSize: limits.writeChunkSize) else {
            close()
            return
        }
        streamingFile = reader
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard !didClose, let reader = streamingFile else { return }
        let chunk: Data?
        do {
            chunk = try reader.nextChunk()
        } catch {
            finishStreaming()
            return
        }
        guard let chunk else {
            finishStreaming()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { await self.sendNextChunk() }
        })
    }

    private func finishStreaming() {
        streamingFile?.close()
        streamingFile = nil
        close()
    }

    // MARK: - Uploads

    /// Called once headers are parsed for a POST. Authorizes the whole
    /// request up front — target is a directory, `Content-Type` names a
    /// multipart boundary, `Content-Length` is present and within
    /// `limits.maxUploadBytes`, and `router.authorizeUpload` accepts the
    /// directory — before reading a single body byte. Anything short of
    /// that responds immediately and never touches the body at all;
    /// v0.1 has no keep-alive to preserve, so there's no need to drain and
    /// discard bytes the client is still sending.
    private func beginUpload(for request: HTTPRequest, leftoverBodyBytes: Data) {
        guard let path = Self.pathIgnoringQuery(request.target), path.hasSuffix("/") else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let contentType = request.headers["Content-Type"],
              let boundary = Self.multipartBoundary(from: contentType) else {
            respond(with: .badRequest("Expected multipart/form-data"), request: request)
            return
        }
        guard let contentLengthText = request.headers["Content-Length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            respond(with: .lengthRequired(), request: request)
            return
        }
        guard contentLength <= limits.maxUploadBytes else {
            respond(with: .payloadTooLarge(), request: request)
            return
        }
        guard router.authorizeUpload(directoryPath: path) else {
            respond(with: .notFound(), request: request)
            return
        }

        uploadState = UploadState(
            request: request,
            directoryPath: path,
            parser: MultipartFormDataParser(boundary: boundary),
            contentLength: contentLength
        )
        guard !leftoverBodyBytes.isEmpty else { return }
        processUploadBytes(leftoverBodyBytes)
    }

    /// Feeds newly received bytes into the active upload's multipart
    /// parser, bounded to at most this upload's declared `Content-Length`
    /// regardless of how much more the client actually sends.
    private func processUploadBytes(_ data: Data) {
        guard var state = uploadState else { return }

        let remainingAllowed = max(0, state.contentLength - state.bytesConsumed)
        let consuming = Data(data.prefix(remainingAllowed))
        state.bytesConsumed += consuming.count

        let events: [MultipartFormDataParser.Event]
        do {
            events = try state.parser.feed(consuming)
        } catch {
            uploadState = state
            failUpload()
            return
        }
        uploadState = state

        for event in events {
            handle(uploadEvent: event)
            guard uploadState != nil else { return } // a prior event already finished/failed the request
        }

        if let current = uploadState, current.bytesConsumed >= current.contentLength {
            // Every declared body byte has arrived but the parser never
            // reported .finished - a truncated or malformed body.
            failUpload()
        }
    }

    private func handle(uploadEvent event: MultipartFormDataParser.Event) {
        guard var state = uploadState else { return }
        switch event {
        case .partBegan(_, let filename):
            guard let filename, !filename.isEmpty,
                  let fileURL = router.authorizeUploadedFile(directoryPath: state.directoryPath, filename: filename),
                  let writer = FileChunkWriter(url: fileURL, maxBytes: limits.maxUploadBytes) else {
                state.currentFileWriter = nil
                state.currentFileURL = nil
                uploadState = state
                return
            }
            state.currentFileWriter = writer
            state.currentFileURL = fileURL
            uploadState = state

        case .partBodyChunk(let chunk):
            guard let writer = state.currentFileWriter else { return }
            do {
                try writer.write(chunk)
            } catch {
                writer.close()
                if let url = state.currentFileURL { try? FileManager.default.removeItem(at: url) }
                state.currentFileWriter = nil
                state.currentFileURL = nil
                uploadState = state
                failUpload()
            }

        case .partEnded:
            if let writer = state.currentFileWriter, let url = state.currentFileURL {
                writer.close()
                state.uploadedFileNames.append(url.lastPathComponent)
            }
            state.currentFileWriter = nil
            state.currentFileURL = nil
            uploadState = state

        case .finished:
            uploadState = state
            finishUpload()
        }
    }

    private func finishUpload() {
        guard let state = uploadState else { return }
        uploadState = nil
        let response: HTTPResponse = state.uploadedFileNames.isEmpty
            ? .badRequest("No file was uploaded")
            : .redirect(to: state.directoryPath, status: 303, reason: "See Other")
        respond(with: response, request: state.request)
    }

    private func failUpload() {
        guard let state = uploadState else { return }
        discardIncompleteUpload()
        respond(with: .badRequest("Upload failed"), request: state.request)
    }

    /// Closes and deletes whatever file the active upload was mid-write on,
    /// then clears upload state entirely. Already-completed files from
    /// earlier parts in the same request are left in place — a failure is
    /// reported for the request as a whole, but doesn't retroactively
    /// undo parts that had already finished successfully.
    private func discardIncompleteUpload() {
        guard let state = uploadState else { return }
        state.currentFileWriter?.close()
        if let url = state.currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        uploadState = nil
    }

    // MARK: - ZIP downloads

    /// Called once headers are parsed for a POST whose `Content-Type` is
    /// `application/x-www-form-urlencoded` — a directory listing's
    /// "Download Selected" form (`Handlers/DirectoryListingRenderer.swift`).
    /// Authorized the same way an upload is: target is a directory,
    /// `Content-Length` is present and within `limits.maxZipSelectionBytes`
    /// (this body is just a list of names, never file content, so the cap
    /// is small), and `router.authorizeZipDownload` accepts the directory —
    /// all before reading a single body byte.
    private func beginZipDownload(for request: HTTPRequest, leftoverBodyBytes: Data) {
        guard let path = Self.pathIgnoringQuery(request.target), path.hasSuffix("/") else {
            respond(with: .notFound(), request: request)
            return
        }
        guard let contentLengthText = request.headers["Content-Length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            respond(with: .lengthRequired(), request: request)
            return
        }
        guard contentLength > 0 else {
            respond(with: .badRequest("No items selected"), request: request)
            return
        }
        guard contentLength <= limits.maxZipSelectionBytes else {
            respond(with: .payloadTooLarge(), request: request)
            return
        }
        guard router.authorizeZipDownload(directoryPath: path) else {
            respond(with: .notFound(), request: request)
            return
        }

        zipDownloadState = ZipDownloadState(request: request, directoryPath: path, contentLength: contentLength)
        guard !leftoverBodyBytes.isEmpty else { return }
        processZipDownloadBytes(leftoverBodyBytes)
    }

    /// Buffers newly received bytes for the active selection body, bounded
    /// to at most its declared `Content-Length` regardless of how much more
    /// the client actually sends — the same discipline as upload bytes,
    /// just accumulated in memory since this body is always small.
    private func processZipDownloadBytes(_ data: Data) {
        guard var state = zipDownloadState else { return }
        let remainingAllowed = max(0, state.contentLength - state.buffer.count)
        state.buffer.append(data.prefix(remainingAllowed))
        zipDownloadState = state
        if state.buffer.count >= state.contentLength {
            finishZipDownloadBody()
        }
    }

    private func finishZipDownloadBody() {
        guard let state = zipDownloadState else { return }
        zipDownloadState = nil
        let names = Self.parseSelectedNames(from: state.buffer)
        guard !names.isEmpty else {
            respond(with: .badRequest("No items selected"), request: state.request)
            return
        }
        guard names.count <= limits.maxZipEntryCount else {
            respond(with: .payloadTooLarge(), request: state.request)
            return
        }
        guard let urls = router.resolveZipEntries(directoryPath: state.directoryPath, names: names) else {
            respond(with: .notFound(), request: state.request)
            return
        }
        Task { await self.buildAndStreamZip(urls, directoryPath: state.directoryPath, request: state.request) }
    }

    /// Builds the archive in the app's own temporary directory — never
    /// inside the served root, since it isn't part of what the user chose
    /// to share — then responds with it as a `.file` body exactly like any
    /// other download. `close()` deletes the temp file once this response
    /// (successful or not) is fully done with it.
    private func buildAndStreamZip(_ urls: [URL], directoryPath: String, request: HTTPRequest) async {
        guard !didClose, !didRespond else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iserve-download-\(UUID().uuidString).zip")
        do {
            try ArchiveManager.createArchive(
                containing: urls, at: tempURL, maxUncompressedBytes: limits.maxZipUncompressedBytes
            )
        } catch ArchiveManager.ArchiveError.selectionTooLarge {
            try? FileManager.default.removeItem(at: tempURL)
            respond(with: .payloadTooLarge(), request: request)
            return
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            respond(with: .badRequest("Could not create the archive"), request: request)
            return
        }
        guard !didClose, !didRespond else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let size = attributes[.size] as? Int else {
            try? FileManager.default.removeItem(at: tempURL)
            respond(with: .internalServerError(), request: request)
            return
        }
        pendingZipCleanupURL = tempURL
        respond(with: .attachment(url: tempURL, length: size, filename: Self.zipFilename(for: directoryPath)), request: request)
    }

    /// Derives a human-readable download filename from the directory's
    /// request path — "/Photos/" -> "Photos.zip", root "/" -> "Download.zip".
    private static func zipFilename(for directoryPath: String) -> String {
        let trimmed = directoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? ""
        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        return (decoded.isEmpty ? "Download" : decoded) + ".zip"
    }

    /// Parses an `application/x-www-form-urlencoded` body for every
    /// `select=<name>` pair, form-urldecoding each value. Anything else in
    /// the body (a different field, a malformed pair) is ignored rather
    /// than rejecting the whole request.
    private static func parseSelectedNames(from data: Data) -> [String] {
        guard let bodyString = String(data: data, encoding: .utf8) else { return [] }
        var names: [String] = []
        for pair in bodyString.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "select", let decoded = formURLDecode(String(parts[1])) else {
                continue
            }
            names.append(decoded)
        }
        return names
    }

    private static func formURLDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func isFormURLEncoded(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let base = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return base.caseInsensitiveCompare("application/x-www-form-urlencoded") == .orderedSame
    }

    // MARK: - Password-only cookie login (v0.3, docs/adr/0008-password-only-cookie-login.md)

    /// Called once headers are parsed for a `POST` to `LoginPageRenderer.path`.
    /// Authorized the same shape as `beginZipDownload` — `Content-Length`
    /// present and within `limits.maxLoginBodyBytes` — before reading a
    /// single body byte; there's no directory/router authorization step
    /// here, since this path never reaches the router at all.
    private func beginLoginSubmission(for request: HTTPRequest, leftoverBodyBytes: Data) {
        guard let contentLengthText = request.headers["Content-Length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            respond(with: .lengthRequired(), request: request)
            return
        }
        guard contentLength > 0 else {
            respond(with: .badRequest("Password is required"), request: request)
            return
        }
        guard contentLength <= limits.maxLoginBodyBytes else {
            respond(with: .payloadTooLarge(), request: request)
            return
        }
        loginState = LoginState(request: request, contentLength: contentLength)
        guard !leftoverBodyBytes.isEmpty else { return }
        processLoginBytes(leftoverBodyBytes)
    }

    /// Buffers newly received bytes for the active login body, bounded to
    /// at most its declared `Content-Length` — the same discipline as a
    /// ZIP-selection body.
    private func processLoginBytes(_ data: Data) {
        guard var state = loginState else { return }
        let remainingAllowed = max(0, state.contentLength - state.buffer.count)
        state.buffer.append(data.prefix(remainingAllowed))
        loginState = state
        if state.buffer.count >= state.contentLength {
            finishLoginSubmission()
        }
    }

    /// A wrong password re-shows the same page with an error, never a
    /// generic `401` — the whole point of this flow is that a browser
    /// never sees Basic Auth's native username/password prompt. A correct
    /// one mints a new session token (shared with every other connection
    /// this session accepts, via `sessionTokens`) and redirects back to
    /// wherever the hidden `redirect` field says the client was actually
    /// trying to go.
    private func finishLoginSubmission() {
        guard let state = loginState else { return }
        loginState = nil
        guard let credentials else {
            respond(with: .notFound(), request: state.request)
            return
        }
        let fields = Self.parseFormFields(from: state.buffer)
        let suppliedPassword = fields["password"] ?? ""
        let redirect = Self.sanitizedRedirectPath(fields["redirect"])
        guard Self.constantTimeEquals(suppliedPassword, credentials.password) else {
            respond(
                with: .html(LoginPageRenderer.render(redirect: redirect, errorMessage: "Incorrect password.")),
                request: state.request
            )
            return
        }
        Task { await self.completeLogin(redirect: redirect, request: state.request) }
    }

    /// Mints the session token and responds — split out from
    /// `finishLoginSubmission` so the one truly async step (minting the
    /// token via the shared, cross-connection `sessionTokens` actor) runs
    /// inside a proper `async` method, matching `buildAndStreamZip`'s
    /// existing shape, rather than inline in a bare `Task { ... }`
    /// closure where ordinary property access would need its own
    /// isolation handling.
    private func completeLogin(redirect: String, request: HTTPRequest) async {
        let token = await sessionTokens.mint()
        guard !didRespond, !didClose else { return }
        respond(with: Self.loginSuccessResponse(token: token, redirect: redirect), request: request)
    }

    /// `303 See Other` back to `redirect` — the standard "POST, then
    /// redirect the browser to GET something else" status, so the browser
    /// never resubmits the password form on back/refresh — with
    /// `Set-Cookie` minting the session a browser will now send with
    /// every later request. No `Secure` flag, since this server only ever
    /// speaks plain HTTP (`docs/adr/0002-http-basic-authentication.md`
    /// already accepts that trade-off for the password itself);
    /// `HttpOnly` and `SameSite=Strict` regardless, so the cookie is never
    /// exposed to script (there is none) and never sent on a cross-site
    /// request.
    private static func loginSuccessResponse(token: String, redirect: String) -> HTTPResponse {
        var response = HTTPResponse.redirect(to: redirect, status: 303, reason: "See Other")
        response.headers.add(
            name: "Set-Cookie",
            value: "\(LoginPageRenderer.sessionCookieName)=\(token); Path=/; HttpOnly; SameSite=Strict"
        )
        return response
    }

    /// Parses an `application/x-www-form-urlencoded` body into a
    /// name-to-value dictionary, form-urldecoding both sides. The first
    /// occurrence of a repeated name wins; nothing here needs more than
    /// one value per field.
    private static func parseFormFields(from data: Data) -> [String: String] {
        guard let bodyString = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in bodyString.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = formURLDecode(String(parts[0])),
                  let value = formURLDecode(String(parts[1])) else {
                continue
            }
            if fields[name] == nil { fields[name] = value }
        }
        return fields
    }

    /// Only a same-origin, root-relative path is ever honored — never an
    /// absolute URL or a scheme-relative `//host/...` one, either of which
    /// would turn this into an open redirect. Also refuses a value
    /// containing a bare CR or LF: unlike `request.target` (which can
    /// never contain either — the request line they'd appear in has
    /// already ended by the time a parsed target exists), this value
    /// round-trips through a client-controlled form field, so it must be
    /// checked before ever being placed in a response header, or a
    /// crafted `redirect` could inject additional header lines. Falls
    /// back to "/" for anything else, including a missing field.
    ///
    /// Checks `unicodeScalars`, not `value.contains("\r")`/`"\n"` directly:
    /// Swift's `String` is grapheme-cluster-based, and `"\r\n"` — the
    /// realistic CRLF-injection payload — collapses into a *single*
    /// `Character` distinct from either `"\r"` or `"\n"` alone, so a
    /// `Character`-level `contains` check silently passes exactly the
    /// input this guard exists to catch. Scanning `unicodeScalars` instead
    /// sees the CR (U+000D) and LF (U+000A) as the two separate code
    /// points they actually are, regardless of clustering.
    private static func sanitizedRedirectPath(_ value: String?) -> String {
        guard let value, value.hasPrefix("/"), !value.hasPrefix("//"),
              !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            return "/"
        }
        return value
    }

    /// The value of this server's own session cookie from a `Cookie`
    /// header, if present — a browser sends every cookie for the origin
    /// in one header, semicolon-separated.
    private static func sessionCookie(from request: HTTPRequest) -> String? {
        guard let cookieHeader = request.headers["Cookie"] else { return nil }
        for pair in cookieHeader.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[trimmed.startIndex..<equalsIndex] == LoginPageRenderer.sessionCookieName else { continue }
            return String(trimmed[trimmed.index(after: equalsIndex)...])
        }
        return nil
    }

    // MARK: - Authentication (v0.3, optional HTTP Basic Auth)

    /// `credentials` is password-only (`ServerCore/ServerCredentials.swift`):
    /// a client's Basic header still names a username, but it's decoded and
    /// discarded rather than checked.
    private static func isAuthorized(_ request: HTTPRequest, credentials: ServerCredentials) -> Bool {
        guard let header = request.headers["Authorization"], header.hasPrefix("Basic ") else {
            return false
        }
        let encoded = header.dropFirst("Basic ".count)
        guard let data = Data(base64Encoded: String(encoded)),
              let decoded = String(data: data, encoding: .utf8) else {
            return false
        }
        let suppliedPassword: String
        if let colonIndex = decoded.firstIndex(of: ":") {
            suppliedPassword = String(decoded[decoded.index(after: colonIndex)...])
        } else {
            suppliedPassword = decoded
        }
        return constantTimeEquals(suppliedPassword, credentials.password)
    }

    /// A byte-for-byte comparison that always examines every byte of the
    /// longer operand, rather than returning as soon as a mismatch is
    /// found the way an ordinary `==` does — otherwise a sufficiently
    /// patient remote attacker could recover the password one byte at a
    /// time from response timing.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var mismatch: UInt8 = lhsBytes.count == rhsBytes.count ? 0 : 1
        for index in 0..<max(lhsBytes.count, rhsBytes.count) {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            mismatch |= left ^ right
        }
        return mismatch == 0
    }

    private static func pathIgnoringQuery(_ target: String) -> String? {
        guard !target.isEmpty else { return nil }
        guard let queryIndex = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<queryIndex])
    }

    private static func multipartBoundary(from contentType: String) -> String? {
        let parts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let kind = parts.first, kind.caseInsensitiveCompare("multipart/form-data") == .orderedSame else {
            return nil
        }
        for parameter in parts.dropFirst() where parameter.lowercased().hasPrefix("boundary=") {
            var value = String(parameter.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func scheduleIdleTimeout() {
        idleTimeoutTask?.cancel()
        let timeout = limits.idleTimeout
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.close()
        }
    }

    private func resetIdleTimeout() {
        scheduleIdleTimeout()
    }

    private static func declaredBodyLength(_ body: HTTPResponseBody) -> Int {
        switch body {
        case .empty:
            return 0
        case .data(let data):
            return data.count
        case .file(let file):
            return file.length
        }
    }

    private func scheduleLifetimeTimeout() {
        let timeout = limits.maxConnectionLifetime
        lifetimeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.close()
        }
    }
}
