import SwiftUI

/// What a row's checkmark column is saying.
///
/// Nil everywhere else in the app: a row that is not being picked has no
/// checkmark column at all, so the artwork sits exactly where it sits on the
/// other two screens and the list does not read as a different list.
enum RowSelection: Equatable {
    case unpicked
    case picked
    /// On screen and not pickable - there is nothing to put in a playlist.
    /// Shown rather than hidden, for the reason the dead playlist row is shown:
    /// the owner cannot fix what they cannot see.
    case unavailable

    var symbol: String {
        switch self {
        case .unpicked: return "circle"
        case .picked: return "checkmark.circle.fill"
        case .unavailable: return "slash.circle"
        }
    }
}

/// One row's checkmark, at a fixed width so the artwork below it lines up down
/// the whole list whether or not a given row can be picked.
///
/// A Deck checkbox rather than the SF circle: picked is the inverted ink
/// square, unavailable a dashed one - both readable without the colour.
struct SelectionMark: View {
    let state: RowSelection

    var body: some View {
        DeckCheck(state: mark)
            .frame(width: 22)
    }

    private var mark: DeckCheck.Mark {
        switch state {
        case .unpicked: return .off
        case .picked: return .on
        case .unavailable: return .unavailable
        }
    }
}

/// The row that turns picking on and off, and says how much is picked.
///
/// Inside the screen, not in the shell's header. That header belongs to the
/// APP - one title, one gear, in the same corner on all three tabs - and a
/// "Select" that appeared up there on two tabs and not the third would make the
/// chrome move under the user's thumb depending on which list happened to be
/// showing.
///
/// "Select all" carries its own number. Under a search box that is holding four
/// of a few thousand songs, a bare "Select all" is a question the user has to
/// guess the answer to; "Select all 4" is the answer.
struct SelectionBar: View {
    let isSelecting: Bool
    let pickedCount: Int
    /// How many rows are on screen right now - after the search, not before it.
    let visibleCount: Int
    let allVisiblePicked: Bool
    let onStart: () -> Void
    let onDone: () -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    /// Start everything on screen. Optional because only the library browser
    /// has them - a playlist's Play lives in its own header, where the name and
    /// the count already are - and because they must not appear while picking:
    /// this row is then about the selection, and a Play beside "3 SELECTED"
    /// reads as "play those three".
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            if !isSelecting, let onPlay, let onShuffle {
                HStack(spacing: 8) {
                    BarButton(
                        title: "Play", icon: "play.fill",
                        isEnabled: visibleCount > 0, action: onPlay)
                    BarButton(
                        title: "Shuffle", icon: "shuffle",
                        isEnabled: visibleCount > 0, action: onShuffle)
                }
            }
            if isSelecting {
                // `deckLabel()`'s face, not the modifier itself: its muted
                // colour would win over this one, and a count of something
                // picked is ink.
                Text(countLabel)
                    .font(Deck.label)
                    .tracking(0.66)
                    .foregroundStyle(pickedCount == 0 ? Deck.muted : Deck.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSelecting {
                Button(allVisiblePicked ? "Deselect all" : "Select all \(visibleCount)") {
                    allVisiblePicked ? onDeselectAll() : onSelectAll()
                }
                .buttonStyle(.deckGhost)
                .disabled(visibleCount == 0)

                Button("Done", action: onDone)
                    .buttonStyle(.deckInk)
            } else {
                Button("Select", action: onStart)
                    .buttonStyle(.deck)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(minHeight: 22)
    }

    private var countLabel: String {
        switch pickedCount {
        case 0: return "NOTHING SELECTED"
        case 1: return "1 SELECTED"
        default: return "\(pickedCount) SELECTED"
        }
    }
}

/// A plain Deck button in the bar above a list.
///
/// Deliberately not `SelectionAction`: that one is full-width and solid accent
/// because it is the answer to a selection the user has just made. These two
/// sit permanently over a list nobody has asked anything about yet, and a
/// full-width orange button there would shout down the list it is for.
struct BarButton: View {
    let title: String
    let icon: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title)
            }
        }
        .buttonStyle(.deck)
        .disabled(!isEnabled)
    }
}

/// One thing a selection can be handed to.
///
/// The Deck primary button, like the Play button on a playlist, because it is
/// the same kind of control in the same app - something that starts over a
/// list of tracks - and two shapes for that would read as two apps.
struct SelectionAction: View {
    let title: String
    let icon: String
    let isEnabled: Bool
    /// Crit-ink text on a plain surface button rather than the red fill: this
    /// is Remove, it sits next to Move, and a solid red block is louder than a
    /// reversible removal of nine rows deserves. The minus icon is the shape.
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(title)
            }
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(isDestructive ? DeckButtonStyle(.plain) : DeckButtonStyle(.primary))
        // Disabled, and visibly so - never a live-looking button that quietly
        // does nothing. "Add to playlist…" with nothing picked has no answer to
        // give, and a tap that produces silence is indistinguishable from a tap
        // that produced an error nobody showed. Deck draws it dashed.
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : "Pick some tracks first")
    }

    /// Set on the label because the destructive one needs crit-ink, and an
    /// inner `foregroundStyle` replaces the style's - so the style's other
    /// two answers (muted when disabled, on-fill on the accent) are restated.
    private var labelColor: Color {
        guard isEnabled else { return Deck.muted }
        return isDestructive ? Deck.critInk : Deck.onFill
    }
}
