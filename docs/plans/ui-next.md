# @hxmc/ui: where it stands, what is next

A handoff for whoever picks up `@hxmc/ui`, `@hxmc/theme`'s drawn side and
the single-source widgets (as of Oct 18). The designs behind them:
[ui.md](ui.md), [theme.md](theme.md),
[native-or-drawn.md](native-or-drawn.md), [view.md](view.md).

## Next, by priority

1. **Touch drags** (with `@hxmc/os`). A touch drag reaches the app as
   Scroll events (`Mods.TOUCH`) on both the browser and native, so a
   slider's thumb, a sortable item or a text selection cannot be dragged
   by touch. The proposal: at a gesture's start, os asks the app, as it
   asks `scrollsAt`, whether the node under the finger takes a pointer
   drag (`Ui.dragsAt(x, y)`). If it does, os delivers pointer events
   (with `TOUCH`); otherwise the touch scrolls. My view: this fits ui
   better than each widget interpreting `TOUCH` scrolls, because the
   decision is made in one place, before the gesture commits, as a
   browser's is. ui should answer from the style, the way CSS does:
   `touch-action: none` (shadcn's `touch-none`, already on its slider's
   classes) as a `Style.touchAction` the rules set. `dragsAt` is true
   when the hit node or an ancestor has it, or when the node is an
   editable text field (its selection). Sortable's items and Split's
   handle get `touch-none` in extras.json. Pages need nothing, since
   their CSS already says `touch-action`.
2. **Single-source widgets, the rest** (native-or-drawn.md, "Where it
   stands"). 82 widgets and parts are one definition for both renderers
   (`@:neutral` in ui's Widgets). These still have a DOM
   copy in `packages/web/src/hxmc/web/widgets/Widgets.hx`:
   - overlays, which wait on the DOM's Layer, focus and scroll (main's):
     DropdownMenu, Menubar, ContextMenu, Select, PopoverButton, Tooltip,
     HoverCard, Dialog(+Footer), AlertDialog, Sheet(+Footer),
     Drawer(+Footer), Combobox, Command, DatePicker, Toaster,
     NavigationMenu;
   - InputGroup(+Addon, Text) (main's: click-to-focus);
   - structurally different in the two renderers: Table and Tree (ui's
     are virtualised by VirtualList, the DOM's are not), Sortable (ui's
     pointer drag against HTML drag and drop), Split, Carousel, the
     charts (drawn against SVG), NativeSelect (a native `<select>`),
     SidebarProvider and Sidebar;
   - ColorPicker: nearly the same in both, and the next easy one. An
     attempt (not committed) made it `@:neutral`: `background` (a colour
     or a gradient string) and `dir` added to NeutralMacro, the press
     through `partRect` and `capture` as Slider's. It built (gallery.js
     +1.5 KB), but in the page a press in the square changed nothing in
     widgets.mjs. Look at how the area's pointerdown reaches `area(e)`
     (the ref, the rect) before converting it again.
3. **Opaque Part calls** (debt). In a page, a neutral widget calls Part's
   methods (`focus`, `rtl`, `rect`, `focusables`, `tabStop`,
   `holdsFocus`, `editable`, `select`) and reads an event's `current`
   through `js.Syntax.code`: Widgets' `mirroredKey`, `focusPart`,
   `partRect` and the like. The reason is that the JS generator's DCE
   (upstream's) keeps every implementation of an interface method called
   through the interface, and would link Node (~30 KB) into every page.
   ElementPart's methods are kept by `@:ifFeature`, Node's opaque ones by
   `@:ifFeature("hxmc.ui.Node.markDirty")`. A design needing no such call
   (the renderer reading a part's direction, say) or a DCE that drops
   unreachable implementations would retire both.
4. **Fast refresh** ([dev-loop.md](dev-loop.md)): `For`'s rows keyed by a
   `key` (so a swap keeps each row's state), and the engine's own state
   (focus, scroll positions, text selection) carried across a swap.
5. **Canvas made document-ready** (task 91, [document.md](document.md)):
   the host apart from the Canvas, before more code builds on today's.
6. **The static-init segfault with `Tw.rules`**: on main's list of open
   items; I have no notes on it beyond the name. Start from a minimal
   native program that builds `Tw.rules` in a static initialiser.
7. **Layout against Chromium** (`make ui-layout-fuzz FEATURES=more`,
   seeds 1, 2, 5, 17, 23): 92 of 1000 trees differ (150 at the start of
   Oct 18, every step checked to break none). `make ui-layout-reduce
   CASE='fuzz N-M'` reduces one to a few boxes. Probe a rule in Chromium
   before porting it: most of the fixes were rules Chromium applies that
   the spec reads differently. What is left:
   - explicit `align-items: stretch` against CSS's `normal` on aspect-ratio
     grid items (they differ; ui's default Stretch is CSS's `normal`, and
     ui has no separate Normal);
   - percentage rows resolved after an auto grid height;
   - an absolutely positioned box with both sizes and an aspect ratio
     widened to its content;
   - an aspect-ratio box that is not stretched and has no definite size,
     whose width Chromium derives from its content's height.
   The default features (seeds 5, 17, 23, 41, 99) all match.
8. **Drawn fidelity against shadcn** (`make theme-fidelity-check`, 252
   cases, all within the bar): 627095 pixels differ in all, 17323 of them
   strongly. The worst cases (strong pixels): alert-dialog-open 598,
   alert-dialog-open-dark 585, input-group-addons
   416 (dark 410, rtl 383), empty-default 344 (dark 341), input-value 331,
   command-default 308. Known causes:
   - **Text baselines, 1px**: dialog and empty titles at 18 and 28 px,
     toasts. Blink rounds ascent and descent, halves the leading in 64ths,
     and on Linux borrows a pixel of ascent when the descent rounds down.
     No combination tried fits every reference (Inter 12/16 and 14/19.25
     resist). The best saves 776 strong pixels but breaks BoxTest's text
     shadow.
   - **tabs-line's underline**: an `after:` pseudo-element. It could be a
     child rule on a `view:after` node in ui, but ThemeTest (line 150)
     asserts `after:absolute` yields nothing; the user's call.
   - Children's rules (`*:`) are read now, as the children's rules
     (`*:data-[slot=x]:` a child of that slot): alert-destructive 425 strong
     pixels to 0. `*:[span]:` and `*:[svg]:` stay dropped with the other
     element-type selectors.
9. **Perf**: a stress update (1000 rows, `StressTest`) is 213M
   instructions, a fifth of it the collector's minor collections
   (`Gc_drainMinor`: the new tree's survivors, which is runtime work). An
   incremental layout is 5.1M (in-place relayout). Small ones left in ui:
   dynamic equality in `Layout.flex` (`Dyn_dynEq`, 0.4%), and int boxing
   in `FontFile.kerning` and `StyleFields.getAt` (0.5%). Relayout
   boundaries and a measure cache keyed without allocation are the bigger
   ones. Vector.blit is fast now (main's blit-land): Layout's measure
   cache can go back to it from its loop.
10. **DOM mode for the site's examples**: the theme's CSS can now be
    scoped (`Css.sheet(path, null, ".hxmc")`; the preflight, the tokens and
    the page's colours kept to the scope, popups and modals included;
    web-widgets checks it). What is left is building the ui examples that
    are all neutral widgets to JavaScript on the site, with the scoped
    sheet, beside or instead of their canvases.

## From building an app on Windows (Oct 19)

Found building a small widget app against main (69d3f39) under
`Shadcn.sheet` and running it with `hxmc dev` on Windows. native-or-drawn.md,
theme.md and this file stand; these are gaps, in the report's order, one PR
each (the report's other items: the dev loop's cold first edit is in
[dev-loop.md](dev-loop.md#windows-the-first-edit-is-a-cold-build-found-oct-19),
the GUI subsystem in [targets.md](targets.md#windows), the drawn fields'
input bridge in
[native-or-drawn.md](native-or-drawn.md#drawn-text-fields-on-desktop-an-input-bridge-then-drawn-by-default)):

1. **Native text fields ignore scrolling.** Inside a `<scroll>`, a native
   field's control stays where it was laid out while the content scrolls:
   `EditableText.syncNative` places the editor at `absX`/`absY`, which are
   unscrolled, and `clippedOut` tests against unscrolled scroller bounds.
   Subtract the ancestors' scroll offsets in both, as `Ui.scrolled` does
   for hit testing. Test: a field scrolled partly and fully out of view, on
   every `PlatformViews` backend.
2. **Unknown markup attributes at compile time.** `<view overflow="scroll">`
   compiles and throws "has no attribute" only when mounted. Unknown
   attributes on intrinsic elements become a compile error with a
   close-match suggestion, and enum literals (`fit`, `role`, `direction`,
   `host`) are checked at compile time too. `NodeRenderer.elements`
   registrations get a way to declare their attributes. Add `overflow` to
   `StyleAttrs`, keeping `<scroll>`. `@:neutral` widgets stay valid for
   both renderers.
3. **Widget sizing under the theme.**
   - Text fields shrink to nothing: a `Textarea` in a column taller than the
     window is squashed. Fields get a minimum height, preferably as
     `shrink-0` in the theme's input and textarea rules so the DOM renderer
     gets it too; check native and drawn hosts.
   - `width` on Slider and Progress: under `Shadcn.sheet`,
     `<Slider width={300}/>` collapses to a few pixels, and
     `style={_ -> {width: 300}}` does not override the theme's `w-full`
     either (the slider takes the whole column); only a fixed-width wrapper
     works. The `width` prop and an instance style must both win over the
     rule, as theme.md and the theme README promise.
4. **Drawn text on Windows looks thin and soft.** At 100-125% scale drawn
   text reads lighter and blurrier than DirectWrite, which shows in every
   form where native fields sit beside drawn labels.
   1. First a harness comparing hxmc, DirectWrite grayscale and Chromium at
      a few sizes and scales, a mixed form included; numbers before any
      change.
   2. Then, measuring after each: DirectWrite-like gamma and contrast on
      coverage; vertical-only grid fitting of baseline, x-height and cap
      height at small sizes; stem darkening. Advances and line breaks must
      not change.
   3. If still off, a glyph-source seam in `GlyphAtlas` so Windows can
      rasterise through DirectWrite behind a define; the pure rasteriser
      stays for wasm and the golden tests.

   Also check that Segoe UI Variable's `opsz` axis follows the size, and
   that glyphs are sampled nearest at exact device sizes.
5. **The widgets mobile apps reach for first.** The set follows shadcn:
   it covers web and desktop apps, but lacks what mobile apps use first
   (compared with Flutter's built-ins). Each one is neutral, with
   behaviour, slots and states, and gets shadcn-style rules in
   `@hxmc/theme`; native-or-drawn and the DOM renderer apply as for the
   rest. Each is proved on Android by a small example app, added to the
   gallery and to `make theme-fidelity-check` where shadcn has a
   reference. In order:
   1. Navigation: a route stack (push, pop, replace), page transitions,
      back handling (Android back, browser history, Escape), deep links
      mapped to routes.
   2. Gestures: swipe to dismiss, pull to refresh, long press, pinch zoom
      and pan (an interactive viewer), on the touch-drag proposal (Next,
      1).
   3. Lists: `VirtualList` with variable item heights, sticky section
      headers, nested scrolling, a collapsing app bar.
   4. App scaffolding: app bar, bottom navigation bar, navigation rail,
      floating action button.
   5. Motion: enter and exit animations for `For` rows, a cross-fade
      switcher, shared-element transitions between routes.
   6. Smaller pieces: TimePicker, Stepper, Chips (filter, choice, input),
      form validation tying `Field` errors to rules, selection across text
      nodes, blur and path clipping in the canvas.
6. **Shaping leftovers** (packages/text's README limits): cursive
    attachment, Indic and other complex scripts, mark reordering, `ccmp`
    and `locl`, bidi embeddings, CFF2. Pick a HarfBuzz-style port or the
    platforms' shapers behind one interface, with the choice justified;
    `TextLayout` keeps line breaking, bidi and carets.

## Also open

- Android native editors: ui renders into NativeActivity's surface, and
  needs a SurfaceView and a view hierarchy in `@hxmc/os`.
- Linux native views (there is no toolkit to host).
- The module cache: twice a warm `~/.cache/hxmc` failed a lane after a
  merge (main fixed the causes found); `rm -rf ~/.cache/hxmc` and `rm
  bin/hxmc/std/.stamp` are the first things to try on a strange build
  error.

## How to check a change

`make ui-check` (UiTest with the layout cases against Chromium, the
incremental layout, restyle and editing fuzzes; MarkupTest, GuideTest,
WidgetExamplesTest), `theme-check`, `theme-fidelity-check`,
`ui-draw-check` (goldens), `ui-web-check`, `web-check`, `web-widgets`
(the gallery driven in Chromium, the scoped CSS, sizes), `theme-dom-check`,
`site`. New layout cases go in `packages/ui/test/layout-cases.mjs`, then
`node packages/ui/test/layout-ref.mjs`.
