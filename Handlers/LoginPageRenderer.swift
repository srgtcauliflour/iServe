import Foundation

/// Renders the password-only login page (v0.3,
/// `docs/adr/0008-password-only-cookie-login.md`) shown to a plain
/// browser `GET`/`HEAD` when password protection is on and the request
/// carries neither a valid session cookie nor valid HTTP Basic
/// credentials. No JavaScript, matching every other form this project
/// renders (`Handlers/DirectoryListingRenderer.swift`'s upload/ZIP-selection
/// forms) — a plain `POST` back to `path`, which `ServerCore/HTTPConnection.swift`
/// intercepts before it ever reaches `SecurePathResolver`/the router.
enum LoginPageRenderer {
    static let path = "/__iserve/login"
    static let sessionCookieName = "iserve_session"

    static func render(redirect: String, errorMessage: String? = nil) -> Data {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>iServe — Password Required</title>
        <style>
        body { font-family: -apple-system, sans-serif; margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; color: #1c1c1e; background: #f2f2f7; }
        form { width: 100%; max-width: 20em; padding: 2em; box-sizing: border-box; }
        h1 { font-size: 1.2em; text-align: center; margin-bottom: 1.2em; }
        input[type="password"] { display: block; width: 100%; padding: 0.6em; font-size: 1em; box-sizing: border-box; margin-bottom: 1em; border: 1px solid #c7c7cc; border-radius: 8px; }
        button { display: block; width: 100%; padding: 0.6em; font-size: 1em; border: none; border-radius: 8px; background: #ff8a3d; color: white; }
        p.error { color: #d70015; text-align: center; margin-top: 0; }
        </style>
        </head>
        <body>
        <form method="POST" action="\(path)">
        <h1>🔒 Password Required</h1>

        """
        if let errorMessage {
            html += "<p class=\"error\">\(escapeText(errorMessage))</p>\n"
        }
        html += """
        <input type="password" name="password" placeholder="Password" autofocus>
        <input type="hidden" name="redirect" value="\(escapeAttribute(redirect))">
        <button type="submit">Unlock</button>
        </form>
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
