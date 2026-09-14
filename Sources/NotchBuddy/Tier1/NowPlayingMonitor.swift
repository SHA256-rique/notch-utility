import Foundation
import AppKit
import Combine

/// Now Playing for the collapsed pill.
///
/// ## Honest status of this API on modern macOS
/// There has never been a public read API for "what is the system playing".
/// `MPNowPlayingInfoCenter` only *publishes* your own app's state. Everyone in
/// this app category reads the private `MediaRemote.framework` instead.
///
/// As of macOS 15.4 Apple gated `MRMediaRemoteGetNowPlayingInfo` behind a
/// private entitlement; unentitled callers get nothing back. So this monitor is
/// written to **degrade, never crash**:
///
///   * Everything is resolved at runtime with `dlopen`/`dlsym`. No link-time
///     dependency on a private framework, so the app launches fine on a system
///     where MediaRemote has moved, been renamed, or been removed entirely.
///     A hard link against a private framework is how apps in this category end
///     up refusing to launch after an OS update.
///   * If the symbols are missing or the call returns nothing, `isAvailable`
///     goes false and the Now Playing pill item simply never appears. The
///     Settings screen explains why rather than leaving a dead toggle.
///   * We register for MediaRemote's *notification* rather than polling, so on
///     systems where it does work, the cost is zero between track changes.
///
/// The fallback when MediaRemote is unavailable is deliberately **nothing**, not
/// a worse heuristic. Scraping audio-device activity or AppleScripting Music.app
/// would mean Apple Events prompts and per-app special-casing for a cosmetic
/// feature -- a bad trade against this app's stated principles.
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    struct Track: Equatable {
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var isPlaying = false
        var duration: Double = 0
        var elapsed: Double = 0
        var appName: String = ""
        var progress: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }
    }

    @Published private(set) var track: Track?
    /// False when MediaRemote could not be resolved on this system.
    @Published private(set) var isAvailable = false
    /// Set when we resolved the framework but the OS refused to return data,
    /// which is the macOS 15.4+ entitlement case specifically.
    @Published private(set) var isEntitlementBlocked = false

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    private var handle: UnsafeMutableRawPointer?
    private var getInfo: GetInfoFn?
    private var observerToken: NSObjectProtocol?
    private var didReceiveAnyPayload = false

    private init() {}

    func start() {
        guard Settings.shared.data.showNowPlayingInPill else { return }
        guard resolveSymbols() else {
            Log.tier1.notice("MediaRemote unavailable -- Now Playing disabled (expected on macOS 15.4+ without the private entitlement)")
            isAvailable = false
            return
        }
        isAvailable = true

        // Event-driven: MediaRemote posts this on every play/pause/track change.
        observerToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }

        refresh()
        Log.tier1.info("now-playing monitor armed (event-driven)")
    }

    func stop() {
        if let observerToken { DistributedNotificationCenter.default().removeObserver(observerToken) }
        observerToken = nil
        NotchArbiter.shared.withdraw("nowplaying")
    }

    private func resolveSymbols() -> Bool {
        // RTLD_LAZY: we only need the two symbols, not the whole framework
        // eagerly bound.
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else {
            return false
        }
        handle = h
        guard let infoSym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo"),
              let regSym = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") else {
            dlclose(h); handle = nil
            return false
        }
        getInfo = unsafeBitCast(infoSym, to: GetInfoFn.self)
        let register = unsafeBitCast(regSym, to: RegisterFn.self)
        register(.main)
        return true
    }

    private func refresh() {
        guard let getInfo else { return }
        getInfo(.main) { [weak self] info in
            guard let self else { return }
            guard !info.isEmpty else {
                // Empty on the very first call usually means "nothing playing";
                // empty on *every* call means the entitlement gate.
                if !self.didReceiveAnyPayload { self.isEntitlementBlocked = true }
                self.track = nil
                NotchArbiter.shared.withdraw("nowplaying")
                return
            }
            self.didReceiveAnyPayload = true
            self.isEntitlementBlocked = false

            var t = Track()
            t.title    = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            t.artist   = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            t.album    = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            t.duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            t.elapsed  = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            // Rate 0 means paused. This is why the pill can correctly stay quiet
            // for a paused track rather than showing a frozen scrubber.
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            t.isPlaying = rate > 0

            guard !t.title.isEmpty else {
                self.track = nil
                NotchArbiter.shared.withdraw("nowplaying")
                return
            }
            self.track = t
            self.publishClaim(t)
        }
    }

    /// Now Playing is ambient and -- per the brief -- only claims the pill while
    /// something is *actually playing*. A paused track shows nothing.
    private func publishClaim(_ t: Track) {
        guard t.isPlaying, Settings.shared.data.showNowPlayingInPill else {
            NotchArbiter.shared.withdraw("nowplaying")
            return
        }
        NotchArbiter.shared.claim(PillClaim(
            id: "nowplaying", priority: .ambient, module: .media,
            symbol: "waveform", text: t.title,
            detail: t.artist.isEmpty ? nil : t.artist,
            rank: 5,    // beats battery and stats for the ambient slot
            expiresAt: nil, progress: t.progress))
    }
}
