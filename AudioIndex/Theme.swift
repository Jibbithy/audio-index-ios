import SwiftUI

/// The app's own metrics and type roles, on top of Deck Cream.
///
/// Every COLOUR is a `Deck.*` token, used directly at the call site - there is
/// no second palette here to drift from the shared one. What stays is what
/// only this app decides: how big a cover is in a row, and which Deck face a
/// row's two lines are set in, so every track list in the app lines up.
enum Theme {

    // MARK: Metrics

    static let rowArt: CGFloat = 52
    static let miniArt: CGFloat = 44

    // MARK: Type
    //
    // Deck faces only, each relative to a text style so Dynamic Type scales
    // them. Space Grotesk says what a row IS; IBM Plex Mono is the data under
    // it.

    static let rowTitle = Deck.sans(15, .bold, relativeTo: .body)
    static let rowSubtitle = Deck.mono(12, .regular, relativeTo: .footnote)
}
