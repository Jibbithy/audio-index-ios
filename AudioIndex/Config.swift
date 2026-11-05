import Foundation

enum Config {
    /// Tailnet only. There is no public route to this and there must not be -
    /// it serves a personal listening history.
    static let indexBaseURL = URL(string: "https://your-server.example")!

    /// Not a secret. A Spotify client ID ships inside every app binary that
    /// uses it; the client SECRET is the sensitive half and this app has none,
    /// because it authenticates with PKCE.
    static let spotifyClientID = "YOUR_SPOTIFY_CLIENT_ID"

    /// Must match the dashboard byte for byte or auth fails with INVALID_CLIENT.
    static let spotifyRedirectURL = URL(string: "audioindex://callback")!
}
