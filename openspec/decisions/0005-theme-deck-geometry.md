# 0005. Bottom-anchored arc deck on the pointer's screen

- Status: accepted
- Date: 2026-11-27

## Context

The 2.19 gallery was a windowed grid. It felt like a settings browser, not a
picker, and it could open on a screen the user was not looking at. Multi-display
and portrait setups made fixed card sizes either overflow or leave the screen
half empty.

## Options considered

- **Keep the grid and improve it.** Familiar, but a grid of 138 cards is a
  scroll surface, not a one-keystroke choice.
- **A centred fan with fixed card size.** Closer to a card picker, but it
  letterboxes on short screens and ignores the display the user is on.
- **A bottom-anchored arc sized from the pointer's display.** Fills the usable
  width, scales with height, and opens where the pointer is.

## Decision

The deck is a non-activating panel spanning the usable width of the display
under the pointer, resting on its bottom edge. Cards are 260×368 pt at full
scale; the deck takes 60% of usable height, never below a 0.35 scale, with
24 pt side/bottom insets and an 88 pt chrome allowance. The hand rides a
circular arc (radius ~2200 pt, 2.7° steps, 34° maximum in layout): the selection
is the apex, neighbours descend and tilt by the tangent, side cards are smaller
and dimmed, and a short hand drops to the bottom inset. Reach is 2–9 cards. The
hand deals in from below and honours Reduce Motion.

## Consequences

- One layout works on a 1024×640 laptop, a portrait panel and an ultrawide.
- The deck and the SwiftUI view must read the same metrics or the hand spills.
- The pointer's screen is resolved on every open; a screen change re-lays out.
- Real arrow keys, typing, click-to-deal and drag stay manual checks.

## Links

- [specs/theme-deck](../specs/theme-deck/spec.md)
- [specs/accessibility](../specs/accessibility/spec.md)
