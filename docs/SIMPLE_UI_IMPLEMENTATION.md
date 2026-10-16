# Simple UI implementation

> Historical, discarded UI direction. The current design uses native AppKit with Transmission as its reference.
> See [Native AppKit UI](NATIVE_APPKIT_UI.md). Retain these images and notes as history, not implementation targets.


Historical status: the G3 experiment was discarded. The approved native replacement and its completion status
are documented in [Native AppKit UI](NATIVE_APPKIT_UI.md).

## Selected design

The host remains a configuration utility. Finder remains the movie browser. All windows use programmatic AppKit
and MVVM-C with Swift 6 concurrency; no additional dependencies, watchers, or background services were introduced.

- Main: collection table with Done, Not found, Several matches, and Total columns; Collection + header;
  hover-only removal control at the right of each row; Log at bottom left and Settings at bottom right.
- Settings: separate reusable window with Poster layout, TMDb, and App theme panes.
- Poster layout: Raw, Soft finish (default), and graphite Matte frame, with rendered previews.
- App theme: independent System / Light / Dark and G0 / G1 / G2 / G3 choices, with miniature window previews.
  Defaults are System and G3. Theme changes apply to all open windows and persist independently of poster layout.
- Log: separate reusable Time / Text / Category table, with Clear at bottom right.

G0 uses opaque presentation; G1 uses native window chrome; G2 adds glass surfaces around controls;
G3 extends a continuous native frosted backdrop across titlebar and content using an active, behind-window
`NSVisualEffectView` with the HUD material. G1 uses that backdrop only behind the titlebar; its content remains opaque.
G2 also uses a standard frosted window backdrop. Genuine Liquid Glass is selective: Add, Save/Remove Token,
and Clear use native `NSButton.BezelStyle.glass` in G2/G3. Add retains a native circular border shape, and Save uses
primary tint prominence. Footer icons remain borderless. G0/G1 retain conventional button styles.
The miniature demonstrations use regular `NSGlassEffectView` for navigation/control areas, with related effects
sharing one `NSGlassEffectContainerView`; table content uses standard frosting. Materials respond to the desktop
and system appearance. The frosted full-window aesthetic is a product choice, not a claim that the content table
is itself Liquid Glass.
Reduced Transparency or Increased Contrast uses an opaque fallback without overwriting the saved preference.
Keyboard and accessibility actions remain available when the visual row removal control is hidden.

## Real processing state

Collection counts are last-known processing snapshots, not a scan started by opening the host window.
Snapshots are scoped by root, credential revision, and directory authorization version. Reauthorizing a root
cannot display a previous grant’s cached result. Tooltips expose the snapshot date when available.

Unknown, unavailable, or incompletely classified legacy state displays an em dash instead of invented zeros.
Preserved foreign icons and manually suppressed folders contribute to Total but not the three result columns,
so the three outcome columns need not add up to Total. Counts update when Finder processes the collection.

The shared activity journal retains up to 500 application processing events. It begins recording with this
implementation; it does not import historical Console logs. Clearing the journal does not clear matches,
processing snapshots, poster data, or folder icons. Shared notifications refresh the open windows without polling.
Status publication is best effort and cannot turn a successful icon assignment into a processing failure.

## Verification

- Configuration: 24 Swift Testing tests passed, including migration defaults and independent theme persistence.
- UI: 23 Swift Testing tests passed, including refresh coalescing, log clear races, theme transitions,
  viewport-aligned columns, compact Settings geometry, preview clipping, and credential indicator state.
- Processing: 48 tests passed, including status classification, authorization isolation, and journal bounds.
- Signed Debug app, embedded Finder extension, and Xcode test targets compiled successfully.
- The signed app launched; Main, Settings, and Activity Log were inspected through native accessibility and screenshots.
- System, Light, Dark, G0, and G3 controls were exercised. Live inspection found and fixed a content remount collapse
  and a default table-spacing overflow. The saved appearance was restored to System / G3.
- Independent review passed, including the remount correction.

Native glass appearance still requires the user’s visual review on their desktop. Window-only captures do not
reliably reproduce the desktop backdrop under transparent surfaces. New processing snapshots and real journal
entries were verified with isolated fixtures; existing collection icons were not deliberately refreshed or replaced
for this UI check. Release distribution, notarization, and full end-to-end Finder reprocessing were not repeated.

## Review gate

The signed Debug build is open for review. Build again using Xcode’s MovieFolderPosters scheme on My Mac,
or run `MOVIE_POSTERS_DERIVED_DATA=/tmp/MovieFolderPosters-SimpleUI ./script/build_and_run.sh --verify`.
Keep all changes uncommitted until the user completes the UI review and authorizes the next action.

## Visual acceptance reference

Use the approved Main, Log, and S1 Settings mockups as the reference, not the first implementation.
Functional test passes do not establish visual fidelity.

- G3 must have a continuous frosted surface across native title bar and content, consistent across all three windows.
- Main and Log tables have rounded thin-stroke containers surrounding header, populated rows, and remaining space.
- No alternating empty-row stripes or default bezel border; populated rows have restrained separators.
- Blue selection has rounded corners; numeric headers and values share centered column positions.
- Main reserves a separate trailing action slot for the hover-only minus so Total stays centered.
- Poster choices and theme choices use image tiles with blue selected outlines.
- TMDb uses a full-width token field with Save/Remove underneath; glass theme previews use a 2x2 layout.
- System / Light / Dark remains independent of G0-G3, with visual examples retained.
- Compare actual running windows with the references before reporting completion. Do not paint a wallpaper
  into production views to imitate a mockup backdrop.

Approved visual references are preserved in the repository:
[Main G3](images/simple-ui-reference/main-g3.png), [Log G3](images/simple-ui-reference/log-g3.png),
and [Settings S1 G3](images/simple-ui-reference/settings-s1-g3.png).
The Settings reference predates the separately approved System / Light / Dark controls and their visual examples.

## G3 correction verification

The visual correction replaces the first implementation’s separate titlebar, square selection, loose collection
header, and striped/bezel Log table. Main and Log now share rounded table containers, thin separators, centered
window titles, and matching glass coverage. Main reserves a trailing remove-action slot and uses responsive
column proportions matching the reference. Collection labels show parent / folder to distinguish identical leaves.
Settings uses outlined selected tiles, a full-width token field, and a two-by-two material preview grid.

The focused UI suite passed 23 tests, including a single legacy-scroller Main window resized
680 → 1000 → 680 and Log header/column coordinate checks at minimum and default sizes. The Log header
uses a flexible Text region and explicit fill distribution; required initial header widths must not dictate the
window’s minimum size. Both header and rows use the same clip viewport geometry.

Settings is 680 × 540 points, with a 540-point native pane selector, portrait sunset previews, a compact
System / Light / Dark selector with examples, and a two-by-two G0–G3 grid. Compact previews retain their
selected rows within bounds. The TMDb status dot is neutral when no token is configured and green when configured.
The Log defaults to 820 × 310 points to match the reference’s proportions, and event times include seconds.
Populated rows draw separators independently of native table grid settings; empty areas remain unstriped.

The persistent independent reviewer passed the backdrop, compact Settings, native pane sizing, credential
indicator, preview bounds, shared glass container, row separators, preview sample cells, and Log refinements.
Color examples use opaque miniatures to distinguish explicit Light and Dark reliably; G0–G3 examples separately
show material coverage. The final signed build and 23-test focused suite passed, and all Settings panes plus
Main and Log were inspected natively. The real journal was empty during this inspection.

Window-only screenshots flatten the desktop backdrop under native glass. Use the running windows on the actual
desktop to assess the material; the application does not embed the mockup wallpaper. Visual acceptance remains
with the user; automated test passes are not a substitute for that review.

Final native check: Main, Log, and all Settings panes opened in the signed build; centered titles were visible.
Light and Dark were exercised, then System / G3 restored. The app was left on Main for the user’s review.

## Apple guidance applied

The [adoption guide](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass),
[Materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials), and
[AppKit glass API](https://developer.apple.com/documentation/appkit/nsglasseffectview) distinguish Liquid Glass
controls/navigation from standard translucent content backgrounds. Keep the approved layout and frosting while
respecting that distinction. Do not apply Liquid Glass to the collection or journal table itself, or add overlapping
glass layers to imitate a static concept image. AppKit supports the required native APIs; SwiftUI is not required.

Exact optical fidelity to the generated mockups remains unconfirmed. Window-only native captures flatten the
behind-window material, so source checks, build success, and geometry comparisons cannot establish desktop
refraction fidelity. If an actual desktop comparison still differs materially, reassess the visual design with the
user rather than continuing speculative material changes or migrating UI frameworks without evidence.
