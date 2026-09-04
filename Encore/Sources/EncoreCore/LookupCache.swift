import Foundation
import os

/// A name/id → String lookup cache with an empty string standing for a known
/// miss (so a failed lookup is remembered instead of retried every time).
/// Backed by `OSAllocatedUnfairLock` — NSLock's lock()/unlock() are
/// unavailable from async contexts under the Swift 6 language mode.
///
/// Pass `defaultsKey` for a cache that should survive relaunches (e.g.
/// `NativeNames`); leave it nil for a memory-only, per-launch cache (e.g.
/// `ArtistInfo`, `AlbumYear`).
public final class LookupCache: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let defaultsKey: String?

    public init(defaultsKey: String? = nil) {
        self.defaultsKey = defaultsKey
    }

    public enum State: Equatable {
        case notCached
        case miss
        case hit(String)
    }

    /// The cached state for `key`, memory-only (no disk fallback).
    public func state(for key: String) -> State {
        switch lock.withLock({ $0[key] }) {
        case nil: return .notCached
        case "": return .miss
        case let value?: return .hit(value)
        }
    }

    /// Stores `value` (nil = a known miss) in memory, and on disk when this
    /// cache has a `defaultsKey`.
    public func store(_ value: String?, for key: String) {
        setMemory(value ?? "", for: key)
        if defaultsKey != nil { persistToDisk(value ?? "", for: key) }
    }

    // MARK: - Lower-level access for callers that split memory/disk timing
    // (NativeNames checks memory, then a fresh disk read, before doing any
    // network work — see `diskValue`/`mergeDiskIntoMemory`).

    /// Raw memory value: nil = not cached, "" = cached miss.
    public func memoryValue(for key: String) -> String? {
        lock.withLock { $0[key] }
    }

    public func setMemory(_ value: String, for key: String) {
        lock.withLock { $0[key] = value }
    }

    /// A fresh point read from disk (not cached), or nil if this cache has no
    /// `defaultsKey` or disk has nothing for `key`.
    public func diskValue(for key: String) -> String? {
        guard let defaultsKey else { return nil }
        return (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[key]
    }

    public func persistToDisk(_ value: String, for key: String) {
        guard let defaultsKey else { return }
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        all[key] = value
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// Merges every disk-persisted entry into memory, without overwriting an
    /// already-cached key.
    public func mergeDiskIntoMemory() {
        guard let defaultsKey,
              let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
              !saved.isEmpty else { return }
        lock.withLock { current in
            for (k, v) in saved where current[k] == nil { current[k] = v }
        }
    }
}
