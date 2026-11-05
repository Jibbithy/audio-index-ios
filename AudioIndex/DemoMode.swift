import Foundation

/// A fake, offline session so the UI can be looked at.
///
/// The simulator cannot authenticate with Spotify - App Remote needs the real
/// Spotify app on a real device - so without this every screen past "Connect
/// Spotify" is unreachable and the design cannot be reviewed at all.
///
/// Activated ONLY by a launch argument, and only in a debug build: `isActive`
/// is a plain `false` in release, so every branch guarded by it is dead code
/// the optimiser removes. Nothing here touches the network, the SDK or the
/// Keychain.
enum DemoMode {

    /// `xcrun simctl launch booted com.example.audioindex -AudioIndexDemo`
    static var isActive: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("-AudioIndexDemo")
        #else
            return false
        #endif
    }

    /// ...`-AudioIndexNowPlaying` to land straight on the expanded player,
    /// which is otherwise only reachable by tapping the mini bar.
    static var opensNowPlaying: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexNowPlaying")
        #else
            return false
        #endif
    }

    /// ...or `-AudioIndexSettings` to land on the connection sheet, so the
    /// state that is otherwise only reachable through a tap can be reviewed
    /// too.
    static var opensSettings: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexSettings")
        #else
            return false
        #endif
    }

    /// ...or `-AudioIndexLibrary` to land on the library browser, which is
    /// otherwise one tap in from the queue - and the simulator has no way to
    /// make that tap from a script.
    static var opensLibrary: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexLibrary")
        #else
            return false
        #endif
    }

    /// ...or `-AudioIndexQueue` to land on the ranked queue. The app opens on
    /// the library, so the queue is one tap on the segmented control away -
    /// and `simctl` cannot make that tap either.
    static var opensQueue: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexQueue")
        #else
            return false
        #endif
    }

    /// ...or `-AudioIndexSelect` alongside any of them to land on whichever
    /// list that was, ALREADY picking rows and with several of them ticked.
    ///
    /// `simctl` can launch an app and screenshot it and nothing else - there is
    /// no way to tap a row from a script, and this Xcode has no `simctl io
    /// tap` - so selection mode, which is several taps in and only interesting
    /// once something is picked, would otherwise be impossible to look at.
    static var opensSelection: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexSelect")
        #else
            return false
        #endif
    }

    /// ...or `-AudioIndexPlaylists` to land on the playlists tab, which is two
    /// taps in from the queue and, like the library, cannot be reached by a
    /// script - `simctl` has no way to tap a segmented control.
    static var opensPlaylists: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexPlaylists")
        #else
            return false
        #endif
    }

    /// ...and `-AudioIndexPlaylistDetail` alongside it to land INSIDE the first
    /// one, which is the only place the mixed-source rows and the dead
    /// `source: null` row can be looked at.
    static var opensPlaylistDetail: Bool {
        #if DEBUG
            return opensPlaylists
                && ProcessInfo.processInfo.arguments.contains("-AudioIndexPlaylistDetail")
        #else
            return false
        #endif
    }

    /// ...or `-AudioIndexPlaylistEmpty` to land inside the EMPTY one, which is
    /// the state that now offers a picker rather than a signpost.
    static var opensEmptyPlaylist: Bool {
        #if DEBUG
            return opensPlaylists
                && ProcessInfo.processInfo.arguments.contains("-AudioIndexPlaylistEmpty")
        #else
            return false
        #endif
    }

    /// ...and `-AudioIndexAddSongs` alongside either of those to raise the
    /// "Add songs" sheet, which is one tap further in again.
    static var opensAddSongs: Bool {
        #if DEBUG
            return isActive && ProcessInfo.processInfo.arguments.contains("-AudioIndexAddSongs")
        #else
            return false
        #endif
    }

    #if DEBUG

        /// Deliberately awkward data: a title long enough to truncate at every
        /// width, one-word titles, a very long artist name, and an entry with a
        /// `spotify:local:` ref that can never have artwork - the row that proves
        /// the placeholder path renders instead of leaving a gap.
        static let tracks: [TrackRef] = [
            ref("DemoTrack0000000000001", "Never Quite Home", "Harlan Moss"),
            ref("DemoTrack0000000000002", "Cartographers of Dust", "Kestrel"),
            ref(
                "DemoTrack0000000000003",
                "Everything Left Unsaid (Live at the Lakeside Pavilion, Remastered)",
                "Cold Orchard"),
            ref("DemoTrack0000000000004", "Redbrick", "Young Alder"),
            ref("DemoTrack0000000000005", "Mr. Halloran", "The Lanterns"),
            ref("DemoTrack0000000000006", "Hours", "Ilse Marrow"),
            local("Tape 04 — Basement Session", "Foxglove"),
            ref("DemoTrack0000000000007", "Solamente", "Luz Tavera, Papa Ruiz"),
            ref("DemoTrack0000000000008", "Hollow Android", "Cold Orchard"),
            ref(
                "DemoTrack0000000000009",
                "Drift (Extended Ambient Mix for Long Journeys)",
                "Slow Tide Union & The Very Long Ensemble Name Society"),
            ref("DemoTrack0000000000010", "Glad", "Perry Wills"),
            ref("DemoTrack0000000000011", "Afterglow", "Velour"),
        ]

        /// Index of the track pretending to be playing. Not zero, so the "already
        /// played" styling above the current row is visible too.
        static let playingIndex = 2

        static let durationMs = 249_000
        static let positionMs = 87_000
        static let syncedTrackCount = 1_247
        static let pendingScrobbles = 3

        /// A Navidrome library with the rough edges a real one has.
        ///
        /// Most of it is untagged MP3s whose whole
        /// FILENAME is the title and whose artist is the literal string
        /// `"[Unknown Artist]"`. Those files are not to be tidied up, on the server
        /// or on the way to the screen, so the browser has to be reviewed against
        /// them - a demo library of neat titles would hide the only wrapping and
        /// truncation problem this screen really has.
        ///
        /// The tagged rows at the end are the search's test: an accented artist for
        /// the diacritic-insensitive match, and a lower-case one for the case fold.
        static let songs: [SubsonicSong] = [
            song("nd-01", "01 - Lumenfall - Harbor.mp3", duration: 247),
            song("nd-02", "02 - Lumenfall - Lov(sic) Part 3 (feat. Kito9).mp3", duration: 383),
            song("nd-03", "velvet static - #3 [collected drift works vol II].mp3", duration: 522),
            song("nd-04", "Maple Signal - Prismatic.mp3", duration: 151),
            song("nd-05", "track01.mp3", duration: 96),
            song("nd-06", "unknown - 2001-01-01 - side b (tape rip, unedited).mp3", duration: 1_684),
            song("nd-07", "DJ Fathom - Midnight In A Quiet City.mp3", duration: 297),
            song("nd-08", "r marlow - Hours: The Weight of the Heart.mp3", duration: 117),
            song("nd-09", "Vetur Ljós", artist: "Vetur Ljós", album: "( )", duration: 402),
            song("nd-10", "Déjà Vu (Live)", artist: "Renée", album: "Second Day", duration: 240),
            song(
                "nd-11", "everything left unsaid", artist: "cold orchard",
                album: "Side A", duration: 251),
        ]

        /// The row the browser opens already playing, so the marked row, the
        /// equaliser bars and the mini player can all be reviewed at once.
        static var playingSong: SubsonicSong? { songs.count > 2 ? songs[2] : songs.first }

        // MARK: The library browser

        /// What the browser shows offline: the Spotify tracks and the local files
        /// in ONE list, ordered artist then title, exactly as atlas returns them.
        ///
        /// Mixed on purpose. The whole point of moving this screen off Navidrome is
        /// that one shelf holds both sources, and a demo library of only files
        /// would screenshot the screen this one replaced.
        static let libraryTracks: [TrackRef] = {
            let files = songs.compactMap(trackRef(from:))
            return (tracks + files).sorted {
                let byArtist = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }()

        /// `track_id -> genres`, shaped like what Spotify actually hands back:
        /// artist-level, narrow, lowercase, and absent for a good half of the
        /// library - the local files have no Spotify artist to look up at all.
        private static let genresByTrack: [String: [String]] = {
            var out: [String: [String]] = [:]
            for track in tracks {
                switch track.artist {
                case "Cold Orchard": out[track.track_id] = ["alternative rock", "art rock"]
                case "Kestrel": out[track.track_id] = ["alternative rock", "rock"]
                case "The Lanterns": out[track.track_id] = ["alternative rock", "indie rock"]
                case "Velour": out[track.track_id] = ["synthwave", "electronic"]
                case "Ilse Marrow": out[track.track_id] = ["soundtrack"]
                case "Young Alder": out[track.track_id] = ["hip hop"]
                case "Perry Wills": out[track.track_id] = ["pop", "hip hop"]
                case "Harlan Moss": out[track.track_id] = ["pop"]
                default: break
                }
            }
            return out
        }()

        /// The chip row's numbers, derived from the fixture rather than typed out:
        /// a hand-written count that disagrees with the list is the one bug a demo
        /// screenshot cannot show.
        static var genreSummary: GenreSummary {
            var counts: [String: Int] = [:]
            var untagged = 0
            for track in libraryTracks {
                let genres = genresByTrack[track.track_id] ?? []
                if genres.isEmpty { untagged += 1 }
                for genre in genres { counts[genre, default: 0] += 1 }
            }
            // Count then name, the order atlas sends and the chips rely on.
            let rows = counts.map { GenreCount(genre: $0.key, track_count: $0.value) }
                .sorted {
                    $0.track_count == $1.track_count
                        ? $0.genre < $1.genre
                        : $0.track_count > $1.track_count
                }
            return GenreSummary(genres: rows, untagged: untagged)
        }

        /// The library under one chip, filtered the way the server would.
        static func libraryTracks(for filter: GenreFilter) -> [TrackRef] {
            switch filter {
            case .all:
                return libraryTracks
            case .untagged:
                return libraryTracks.filter { (genresByTrack[$0.track_id] ?? []).isEmpty }
            case .genre(let name):
                return libraryTracks.filter { (genresByTrack[$0.track_id] ?? []).contains(name) }
            }
        }

        /// Which library rows `-AudioIndexSelect` starts with picked, by track_id.
        ///
        /// Deliberately not a block from the top, for the reason below, and
        /// deliberately spanning BOTH sources: a selection that can hold a Spotify
        /// track and a file together is the thing worth screenshotting.
        static var selectedTrackIDs: Set<String> {
            Set(
                libraryTracks.enumerated()
                    .filter { [1, 2, 5, 9].contains($0.offset) }
                    .map(\.element.track_id))
        }

        /// Which playlist rows `-AudioIndexSelect` starts with picked: every other
        /// one, which in the first demo list puts the dead `source: null` row in
        /// the selection. That row is the only interesting thing about having two
        /// buttons - Remove can take it and Move cannot - so it has to be pickable
        /// in the screenshot that is meant to show them.
        static func selectedEntryIDs(of entries: [PlaylistEntry]) -> Set<String> {
            Set(
                entries.enumerated().filter { $0.offset.isMultiple(of: 2) == false }
                    .map(\.element.entry_id))
        }

        // MARK: Playlists

        /// Three playlists, shaped like the states the screen has to survive: one
        /// long list, one short one, and one that is EMPTY - an empty playlist is
        /// not an error and has to be seen not to look like one. The long name is
        /// there to be truncated.
        /// In the order atlas sends them: by NAME, case insensitively, not by
        /// when each was last touched. The fixture keeps the server's order so a
        /// demo screenshot is the real screen.
        static let playlists: [Playlist] = [
            Playlist(
                id: "demo-pl-drive", name: "Late drive", track_count: 5,
                updated_at: 1_757_300_000_000),
            Playlist(
                id: "demo-pl-new", name: "Sunday morning", track_count: 0,
                updated_at: 1_756_900_000_000),
            Playlist(
                id: "demo-pl-tapes", name: "Tapes, files and things off the shelf",
                track_count: 2, updated_at: 1_757_100_000_000),
        ]

        /// One playlist's entries, offline.
        ///
        /// The first list is the whole point of the feature in one screen: Spotify
        /// tracks and a Navidrome file in ONE ordered list, plus an entry atlas
        /// knows about and has nowhere to play from. That last row is not a
        /// mistake in the fixture - it is the `source: null` case, and it is here
        /// so the greyed, unplayable row can be reviewed.
        static func playlistDetail(id: String, name: String) -> PlaylistDetail {
            PlaylistDetail(id: id, name: name, tracks: entries(for: id))
        }

        private static func entries(for id: String) -> [PlaylistEntry] {
            switch id {
            case "demo-pl-tapes":
                return [
                    entry(0, tracks[6]),
                    fileEntry(1, songs[5]),
                ]
            case "demo-pl-new":
                return []
            default:
                return [
                    entry(0, tracks[2]),
                    entry(1, tracks[8]),
                    fileEntry(2, songs[0]),
                    deadEntry(3, artist: "Say Say", title: "Green Field"),
                    entry(4, tracks[11]),
                ]
            }
        }

        private static func entry(_ position: Int, _ track: TrackRef) -> PlaylistEntry {
            PlaylistEntry(
                entry_id: demoEntryId(position), position: position,
                track_id: track.track_id, source: track.source,
                source_ref: track.source_ref, artist: track.artist, title: track.title,
                // The same genres the library fixture gives this artist,
                // so the chips inside a playlist and the chips on the
                // library tab cannot disagree in a screenshot.
                genres: demoGenres(for: track))
        }

        /// A stand-in for the id atlas mints per entry. Only has to be unique
        /// inside the one playlist being shown, which is what the position gives
        /// it - and this is the ONLY place a position is allowed near an identity.
        private static func demoEntryId(_ position: Int) -> String { "demo-entry-\(position)" }

        /// A local file in the same list as the Spotify rows above it.
        private static func fileEntry(_ position: Int, _ song: SubsonicSong) -> PlaylistEntry {
            PlaylistEntry(
                entry_id: demoEntryId(position), position: position,
                track_id: navidromeRefPrefix + song.id,
                source: "file", source_ref: navidromeRefPrefix + song.id,
                artist: song.artist ?? "", title: song.title,
                // Untagged files, exactly as on the server: this is the
                // row the "No genre" chip is for.
                genres: [])
        }

        /// One track's genres in the fixture, read out of the same map the library
        /// browser uses so the two screens agree.
        private static func demoGenres(for track: TrackRef) -> [String] {
            genresByTrack[track.track_id] ?? []
        }

        /// A track atlas holds with no source to play it from. Both `source` and
        /// `source_ref` are null on the wire, and both are nil here.
        private static func deadEntry(
            _ position: Int, artist: String,
            title: String
        ) -> PlaylistEntry {
            PlaylistEntry(
                entry_id: demoEntryId(position), position: position,
                track_id: "demo-orphan-\(position)", source: nil,
                source_ref: nil, artist: artist, title: title)
        }

        private static func song(
            _ id: String, _ title: String,
            artist: String = "[Unknown Artist]",
            album: String = "Unknown Album",
            duration: Int
        ) -> SubsonicSong {
            // No `coverArt`: nothing here may reach a server, so every row falls
            // through to the generated placeholder in `ArtworkView`.
            SubsonicSong(
                id: id, title: title, artist: artist, album: album,
                duration: duration, coverArt: nil)
        }

        private static func ref(_ id: String, _ title: String, _ artist: String) -> TrackRef {
            TrackRef(
                track_id: "demo-\(id)", source: "spotify",
                source_ref: "spotify:track:\(id)", artist: artist, title: title)
        }

        /// A saved local file: no Spotify id, so no album art exists for it.
        private static func local(_ title: String, _ artist: String) -> TrackRef {
            TrackRef(
                track_id: "demo-local-\(title.count)", source: "spotify",
                source_ref: "spotify:local:::\(title):0", artist: artist, title: title)
        }

    #endif
}
