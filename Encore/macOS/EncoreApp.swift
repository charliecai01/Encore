import SwiftUI
import AppKit
import EncoreCore

@main
struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var nav = Nav.shared
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(nav)
                .environmentObject(library)
                // Min width fits sidebar (224) + a comfortable content column
                // + the pinned Up Next pane (300) with dividers, so nothing is
                // clipped at the smallest window size.
                .frame(minWidth: 1140, minHeight: 680)
                .preferredColorScheme(.dark)
                .task { await auth.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                    .disabled(player.current == nil)
                Button("Next") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Shuffle") { player.toggleShuffle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Repeat") { player.cycleRepeat() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Reload") { nav.reload() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("Quick Search…") { nav.paletteShown.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Back") { nav.goBack() }
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!nav.canGoBack)
                Button("Forward") { nav.goForward() }
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(!nav.canGoForward)
                Divider()
                Button("Home") { nav.go(.home) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Explore") { nav.go(.explore) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Library") { nav.go(.library(.playlists)) }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let saved = UserDefaults.standard.string(forKey: "lyricsProvider"),
           let provider = LyricsService.Provider(rawValue: saved) {
            LyricsService.shared.preferred = provider
        }
        URLCache.shared = URLCache(memoryCapacity: 256 * 1024 * 1024,
                                   diskCapacity: 1024 * 1024 * 1024)

        // Space toggles playback, Esc closes the now-playing overlay —
        // anywhere except while typing in a text field.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
                || NSApp.keyWindow?.firstResponder is NSTextField
            if event.keyCode == 49, !typing, PlayerEngine.shared.current != nil {
                PlayerEngine.shared.togglePlay()
                return nil
            }
            if event.keyCode == 53, !typing, PlayerEngine.shared.showNowPlaying {
                PlayerEngine.shared.showNowPlaying = false
                return nil
            }
            return event
        }

        // Mouse back/forward buttons navigate like Safari.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3:
                if PlayerEngine.shared.showNowPlaying {
                    PlayerEngine.shared.showNowPlaying = false
                } else {
                    Nav.shared.goBack()
                }
                return nil
            case 4:
                Nav.shared.goForward()
                return nil
            default:
                return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerEngine.shared.persistSnapshot()
    }
}
