import SwiftUI

/// Everything that is setup rather than listening.
///
/// This is where the whole of the old single screen went: Spotify sign-in, the
/// atlas token, library sync and the pending-scrobble count. None of it was
/// dropped in the restyle - it was moved off the surface the app is actually
/// used on, because after first launch none of it is touched again.
struct SettingsSheet: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var local: LocalPlayer
    @EnvironmentObject private var spotify: SpotifySession
    @Environment(\.dismiss) private var dismiss

    @State private var tokenDraft = ""
    @State private var isEditingToken = false

    @State private var navidromeURLDraft = ""
    @State private var navidromeUserDraft = ""
    @State private var navidromePasswordDraft = ""
    @State private var isEditingNavidrome = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modeSection
                    spotifySection
                    tokenSection
                    navidromeSection
                    librySection
                    themeSection
                    messages
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .background(Deck.ground)
        .onAppear {
            isEditingToken = !player.hasToken
            isEditingNavidrome = !player.hasNavidrome
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(Deck.title)
                .textCase(.uppercase)
                .foregroundStyle(Deck.ink)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.deckInk)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .deckBar(.top)
    }

    // MARK: Who chooses

    /// The one setting that changes what the app IS rather than what it can
    /// reach, so it sits at the top, above the connections that serve it.
    ///
    /// A `Binding` through `setMode` rather than a bound `@Published`: the mode
    /// has to be written to `UserDefaults` and the last DJ failure cleared on
    /// every change, and a two-way binding straight into the property would
    /// skip both.
    private var modeSection: some View {
        DeckFormSection(title: "WHO CHOOSES") {
            DeckSegmented(
                selection: Binding(
                    get: { player.mode },
                    set: { player.setMode($0) }),
                options: PlaybackMode.allCases.map { ($0, $0.label) }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Who chooses")
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            switch player.mode {
            case .rankedQueue:
                Note(
                    "Atlas ranks a queue from your own play history and this app plays it, "
                        + "across Spotify and your Navidrome files.")
            case .spotifyDJ:
                Note(
                    "Spotify's DJ picks the streamed tracks and this app records every play "
                        + "to atlas anyway — a play is a play whoever chose it, so your ranking "
                        + "keeps training while you listen. Your library and playlists are "
                        + "unaffected: tapping one still takes over, and the DJ will not resume "
                        + "by itself afterwards.")
                if let failure = player.djFailure {
                    Row {
                        DeckErrorText("Spotify refused the DJ: \(failure)")
                        Spacer()
                    }
                }
                Row {
                    Text(
                        "Asks for \(spotifyDJContextURI). Spotify does not document whether "
                            + "the DJ can be started by another app at all, so this may be "
                            + "refused — if it is, the ranked queue plays instead and the reason "
                            + "is shown."
                    )
                    .font(Deck.small)
                    .foregroundStyle(Deck.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    // MARK: Theme

    /// Auto / Cream / Dark - the web specimen's switch. Last, because it is
    /// the one setting that changes nothing about what plays.
    private var themeSection: some View {
        DeckFormSection(title: "THEME") {
            DeckThemePicker()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Note("Auto follows the phone.")
        }
    }

    // MARK: Spotify

    private var spotifySection: some View {
        DeckFormSection(title: "SPOTIFY") {
            Row {
                Text(spotify.isAuthorized ? "Signed in" : "Not signed in")
                    .font(Deck.sans(15, .bold))
                    .foregroundStyle(Deck.ink)
                Spacer()
                StatusDot(ok: spotify.isAuthorized)
            }
            if spotify.isAuthorized {
                Row {
                    Text(
                        spotify.isConnected
                            ? "App Remote connected"
                            : "App Remote not connected"
                    )
                    .font(Deck.small)
                    .foregroundStyle(Deck.muted)
                    Spacer()
                    StatusDot(ok: spotify.isConnected)
                }
            }
            ActionRow(
                title: spotify.isAuthorized ? "Reconnect Spotify" : "Connect Spotify",
                systemImage: "link"
            ) {
                spotify.authorize()
            }
            if !spotify.isSpotifyInstalled {
                Note(
                    "The Spotify app is not installed. Sign-in falls back to a web sheet, "
                        + "but playback needs the app.")
            }
        }
    }

    // MARK: Atlas token

    private var tokenSection: some View {
        DeckFormSection(title: "ATLAS TOKEN") {
            if player.hasToken && !isEditingToken {
                Row {
                    Text("Token saved to the Keychain")
                        .font(Deck.sans(15, .bold))
                        .foregroundStyle(Deck.ink)
                    Spacer()
                    StatusDot(ok: true)
                }
                ActionRow(title: "Change atlas token", systemImage: "key.horizontal") {
                    tokenDraft = ""
                    isEditingToken = true
                }
            } else {
                Note(
                    "The bearer token from /var/lib/audio-index/config.json on atlas. "
                        + "It is stored in the Keychain on this device only, and never leaves it.")
                FieldBox {
                    SecureField(
                        "Paste token", text: $tokenDraft,
                        prompt: Text("Paste token").foregroundStyle(Deck.muted))
                }

                HStack(spacing: 10) {
                    Button("Save token") {
                        player.saveToken(tokenDraft)
                        tokenDraft = ""
                        isEditingToken = false
                    }
                    .buttonStyle(.deckPrimary)
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if player.hasToken {
                        Button("Cancel") {
                            tokenDraft = ""
                            isEditingToken = false
                        }
                        .buttonStyle(.deckGhost)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: Navidrome

    /// The second library source: the user's own files, on their own server.
    ///
    /// Optional by design. Everything here is allowed to be blank, and a blank
    /// server is skipped in silence at sync time rather than being reported as
    /// something the user forgot to do.
    private var navidromeSection: some View {
        DeckFormSection(title: "NAVIDROME") {
            if player.hasNavidrome && !isEditingNavidrome {
                Row {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server saved to the Keychain")
                            .font(Deck.sans(15, .bold))
                            .foregroundStyle(Deck.ink)
                        if let summary = player.navidromeSummary {
                            Text(summary)
                                .font(Theme.rowSubtitle)
                                .foregroundStyle(Deck.muted)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    StatusDot(ok: true)
                }
                ActionRow(title: "Test connection", systemImage: "antenna.radiowaves.left.and.right") {
                    Task { await player.testNavidrome() }
                }
                ActionRow(title: "Change Navidrome server", systemImage: "externaldrive.connected.to.line.below") {
                    navidromeURLDraft = ""
                    navidromeUserDraft = ""
                    navidromePasswordDraft = ""
                    isEditingNavidrome = true
                }
            } else {
                Note(
                    "Your own files, alongside Spotify. Atlas resolves both onto one track, "
                        + "so a song you own and the same song streamed share a play history. "
                        + "Tailnet address, username and password — stored in the Keychain on "
                        + "this device only.")
                FieldBox {
                    TextField(
                        "http://your-server.example", text: $navidromeURLDraft,
                        // Verbatim: a string literal is a LocalizedStringKey, whose
                        // Markdown pass turns a URL into a blue link.
                        prompt: Text(verbatim: "http://your-server.example")
                            .foregroundStyle(Deck.muted)
                    )
                    .keyboardType(.URL)
                }
                FieldBox {
                    TextField(
                        "Username", text: $navidromeUserDraft,
                        prompt: Text("Username").foregroundStyle(Deck.muted))
                }
                FieldBox {
                    SecureField(
                        "Password", text: $navidromePasswordDraft,
                        prompt: Text("Password").foregroundStyle(Deck.muted))
                }

                HStack(spacing: 10) {
                    Button("Save server") {
                        player.saveNavidrome(
                            baseURL: navidromeURLDraft,
                            username: navidromeUserDraft,
                            password: navidromePasswordDraft)
                        // Held only until it reaches the Keychain. Leaving the
                        // password in a @State string keeps it in memory for as
                        // long as the sheet exists.
                        navidromePasswordDraft = ""
                        if player.hasNavidrome { isEditingNavidrome = false }
                    }
                    .buttonStyle(.deckPrimary)

                    if player.hasNavidrome {
                        Button("Cancel") {
                            navidromePasswordDraft = ""
                            isEditingNavidrome = false
                        }
                        .buttonStyle(.deckGhost)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if let result = player.navidromeTest {
                Row {
                    Text(result)
                        .font(Deck.small)
                        .foregroundStyle(Deck.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    // MARK: Library

    private var librySection: some View {
        DeckFormSection(title: "LIBRARY") {
            ActionRow(title: "Sync library", systemImage: "arrow.triangle.2.circlepath") {
                Task { await player.syncLibrary() }
            }
            .disabled(player.isWorking)

            // One row per source. A single total would hide the case that
            // actually goes wrong: one source syncing and the other not.
            if let count = player.lastSyncCount {
                Row {
                    Text("Spotify: \(count) tracks in the index")
                        .font(Deck.small)
                        .foregroundStyle(Deck.muted)
                    Spacer()
                }
            }
            if let count = player.lastNavidromeSyncCount {
                Row {
                    Text("Navidrome: \(count) tracks in the index")
                        .font(Deck.small)
                        .foregroundStyle(Deck.muted)
                    Spacer()
                }
            }
            // Zero is the normal state, not information worth a row.
            if player.pendingScrobbles > 0 {
                Row {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(Deck.muted)
                    Text("\(player.pendingScrobbles) plays waiting to send")
                        .font(Deck.small)
                        .foregroundStyle(Deck.muted)
                    Spacer()
                }
            }
        }
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = player.status {
                DeckHint(status)
            }
            if let error = player.error {
                DeckErrorText(error)
            }
            if let spotifyError = spotify.lastError {
                DeckErrorText("Spotify: \(spotifyError)")
            }
            if let fileError = local.lastError {
                DeckErrorText("Files: \(fileError)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

// MARK: - Pieces

// The titled cards are `DeckFormSection` (DeckExtras): a mono label over a
// Deck tile, with a hair between rows. Not SwiftUI's `Form`/`List`, which
// bring their own grouped chrome that would have to be undone row by row.

private struct Row<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    /// Read so a disabled row ("Sync library" while working) looks disabled
    /// in Deck's terms - muted - rather than relying on the plain style's dim.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isEnabled ? Deck.accentInk : Deck.muted)
                    .frame(width: 20)
                Text(title)
                    .font(Deck.sans(15, .bold))
                    .foregroundStyle(isEnabled ? Deck.ink : Deck.muted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Deck.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A form field in `DeckFieldStyle`. Shared by the atlas token and the three
/// Navidrome fields, because four inline copies would drift apart.
private struct FieldBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .textFieldStyle(DeckFieldStyle(mono: true))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Deck.small)
            .foregroundStyle(Deck.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}

/// Connected or not, by SHAPE as well as colour: a filled ok dot, or the hollow
/// idle ring. The row's own words say it too.
private struct StatusDot: View {
    let ok: Bool

    var body: some View {
        DeckDot(ok ? .ok : .idle, size: 10)
    }
}
