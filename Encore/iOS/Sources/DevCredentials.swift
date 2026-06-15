import Foundation

/// Optional developer convenience: a YouTube Music `cookie:` header used to
/// auto-sign-in on launch so you don't re-paste after every reinstall.
///
/// ⚠️ SECURITY: leave this EMPTY in version control. The cookie is a full
/// account credential. To use it locally, paste your cookie below and run:
///
///     git update-index --skip-worktree Encore/iOS/Sources/DevCredentials.swift
///
/// so your local secret is never committed/pushed. Run `--no-skip-worktree`
/// to undo.
enum DevCredentials {
    static let cookie = ""
}
