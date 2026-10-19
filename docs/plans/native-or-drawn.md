# Native or drawn, per widget

Every widget can be **native** (the platform's control, in the browser a
DOM element), **drawn** (hxmc.ui's renderer) or **auto** (a per-platform
default). The same markup, signals, slots and theme serve both; an app
picks per widget, per subtree or app-wide. Auto picks native where the
platform's control does the job better than we can, drawn where looks and
consistency matter more.

## Defaults for `auto`

| Widget / case | Default | Why |
| --- | --- | --- |
| Input, Textarea, NumberField, password, search | native everywhere | IME, autofill and password managers, spellcheck, text services, selection handles and magnifier on touch, accessibility |
| Select | native on touch platforms (Android, iOS, mobile browsers), drawn on desktop | the system picker on phones; desktop natives look dated next to the theme |
| DatePicker, time | native on touch platforms, drawn on desktop | the system pickers on phones |
| ContextMenu | native on desktop | menus that behave like the system's: keyboard, accessibility, leaving the window |
| Menubar | native on macOS (the global menu) and Windows (the window's menu), drawn in the window elsewhere | macOS and Windows apps are expected to use the system menu bar |
| Scrolling | native in the DOM; drawn elsewhere with the platform's physics | momentum, overscroll and scroll chaining as the platform does them |
| Static text in a browser | DOM | selection, find in page, translation, indexing |
| Video, web content, maps | native (platform views) | not something to draw ourselves |
| Button, Checkbox, Switch, Slider, Tabs, Dialog, Popover, Tooltip, and the rest | drawn | the theme's look; native available on request |

Planned change: on desktop, Input and Textarea become drawn by default once
the drawn field has a full input bridge ([below](#drawn-text-fields-on-desktop-an-input-bridge-then-drawn-by-default)).

System services stay native and are not widgets: file and colour pickers,
share sheets, printing, alerts on request, the clipboard, drag and drop.

## How

- **A host per node.** `host: Auto | Native | Drawn` on widgets, inherited
  down a subtree; `Ui.policy` holds the defaults above and an app can
  change them.
- **A native control inside a drawn tree** (platform views): the native view
  is placed, sized and clipped by the layout, kept in step during scrolling
  and animation, in the tab order and accessibility tree where the node is.
  The theme draws the chrome (border, background, radius, ring) and a
  borderless native editor sits inside it with the theme's font, colour and
  padding, so a native field looks like the drawn one.
- **Layering.** A native view sits above the drawn surface. Popups and
  dialogs over native views become their own native layers (windows on
  desktop and Android, a layer above the canvas in the browser); where a
  platform cannot, the native view is swapped for a drawn snapshot while
  covered.
- **The browser** gets a DOM renderer for the widget set: a widget is a real
  element with shadcn's markup (`data-slot`, `data-state`, roles), and the
  theme compiles to CSS as well as rules. A web page can then be all DOM
  (small, no wasm needed for UI), all canvas (identical pixels everywhere),
  or mixed per mount point as `@hxmc/view` already allows.
- **Drawn stays the fallback** wherever there is no native counterpart, and
  on request.

## Who builds what

- **The UI session** (`packages/ui`): `host` and `Ui.policy`; platform views
  in a drawn tree on Linux, macOS, Windows and Android (placement, clipping,
  scroll sync, focus, accessibility, layering); native text editors first,
  then Select and DatePicker on Android, ContextMenu and the macOS menu bar.
- **Here**: the browser's DOM renderer for the widgets; the theme's split
  into chrome and editor, and its CSS output; iOS (UIKit) when it starts.

## Order

1. Native text fields by default (desktop, Android, browser).
2. The DOM renderer and CSS theme for the browser.
3. The rest of the defaults table.

## Drawn text fields on desktop: an input bridge, then drawn by default

Native hosting stays the mechanism, but its costs differ per platform. In
the browser (the DOM renderer) and on mobile, native editors are cheap or
irreplaceable: selection handles, the magnifier, autocorrect, autofill. On
desktop they bring airspace problems (scrolling, opacity, transforms,
popups over them) and GDI text beside drawn text, while a drawn field that
speaks the platform's input protocol gets nearly everything. (From
building a small app on Windows, Oct 19.)

1. **An editing protocol for the drawn field**, instead of
   `startTextInput`'s caret rectangle: text, selection and composition
   ranges, replace, and character bounds for the candidate window. TSF on
   Windows, `NSTextInputClient` on macOS, IBus or GTK's IM context on
   Linux, `EditContext` in canvas web builds with the hidden input as the
   fallback.
2. **A manual test matrix**: Japanese, Chinese and Korean IMEs, dead keys,
   the emoji panel, dictation, on `Input` and `Textarea`.
3. **When it passes**, `Ui.policy`'s desktop defaults for `text-field` and
   `text-area` become Drawn, and the defaults table above changes with
   it. Native stays the default on Android, iOS and the DOM renderer, and
   `host="native"` stays available everywhere.

## Single-source widgets (headless)

The DOM's widgets are a hand-written copy of ui's (2455 lines beside 4397):
the props, keys, slots and states kept equal by `WidgetParity` and the
fidelity suites, at the cost of every change made twice. A component is
already picked per renderer (`@:renderer`: ui's widgets, the DOM's in a
page's markup); the next step is one definition per widget, realised by
each renderer: its state and behaviour (`Behaviour`, signals) and a
renderer-neutral tree of **parts** (a slot, its states as `data-*`, a
role and name, an element type for the DOM), the drawn renderer making
Nodes of it, the DOM's elements, native controls a third realiser (a part
whose host is native: Select's menu, a text field, the context menu).

What ui's widgets use of Node and Ui today (Widgets.hx, by count), and the
part vocabulary that replaces it:

| Today (drawn only) | Uses | Part vocabulary | DOM realiser |
| --- | --- | --- | --- |
| `ref={n -> ...}` reaching the Node | 39 | a `Part` interface: `focus()`, `rect()`, `scrollIntoView()`, `capture()`, `contains()`, `attr()`; Node implements it, the DOM a small wrapper | Element calls |
| `ui.setFocus`, roving | 12 | `part.focus(visible)`; roving stays `Behaviour`'s | `focus({focusVisible})` |
| `width`, `height`, `absX` (sliders, charts, splitters, virtual rows) | 48 | `part.rect()` after layout, an `onResize` | `getBoundingClientRect`, ResizeObserver |
| `<Popover>` (menus, dialogs, tooltips, selects) | 12 | `<Layer anchor={part} placement modal>` | the top layer (`popover`, `<dialog>`), `Dom.popup` |
| pointer moves and drags | 56 | neutral pointer events with capture (`onPointer*`, `part.capture(id)`) | `setPointerCapture` |
| `onKeyDown` with `Key` codes | 57 | the same `Event` (key, mods, `stop`, `preventDefault`), converted once by the realiser | `Dom.key`, `Dom.mods` |
| text fields (Input, Textarea, TagInput, NumberField, InputOTP, Combobox) | 6 | a `<field>` part: value, onInput, `Part.select`, IME | `<input>`, `<textarea>` |
| icons (`<image svg>`) | 16 | an `<icon>` part | inline SVG |
| `<scroll>`, virtual lists | 14 | `<scroll>`; `VirtualList` over `part.rect()` | `overflow: auto`, rows by scroll offset |
| inline layout (`direction`, `width`, `position`...) | many | slot rules (`Rules.addBase` for the unstyled look), the rest StyleProps on parts | the same rules as CSS (`Css`), the rest inline style (the renderer's `setter`) |
| `States.apply` (the `style` prop) | 17 | StyleProps of states, as now | inline style |
| `ui.platform` menus, `hostOf` | 10 | a part's host: the native realiser | the DOM's own controls |
| `Clock`, `Ui.now` | 13 | a clock in hxmc.view | `requestAnimationFrame` |

Why an interface: a literal's holes (its attribute values, `ref`s and
handlers among them) are typed once for every renderer, so what they
reach must be renderer-neutral; the elements and their attributes stay
per renderer, compiled for each as now. Each realiser maps the intrinsic
parts (`view`, `text`, `scroll`, `field`, `icon`, a part's `as`) and
its attributes (`slot` as `data-slot`, `label` as `aria-label`,
`focusable` as `tabindex`, StyleProps as style) to its nodes.

The vocabulary, concretely (both renderers resolve it at compile time,
as NodeRenderer does its elements now: nothing per node at run time):

- **Elements**: `view` (the DOM's `div`), `view:button`, `view:label`,
  `view:a`, `view:nav`, `view:ul`, `view:li` (a view, the DOM's element of
  that name: its semantics and default behaviour), `text` and `text:p`,
  `text:h2`... (a text, the DOM's `span` or that element), `scroll`, `icon`
  (`name`: lucide's, `hxmc.ui.widgets.Icons`; an Svg, inline SVG), `field` and `field:textarea` (a text field; the
  DOM's `input`, `textarea`).
- **Attributes**: ui's names, mapped by the DOM renderer: `slot`,
  `variant`, `size` as `data-slot`, `data-variant`, `data-size`; `data-*`
  as they are; `role`; `label`, `checked`, `selected`, `expanded`,
  `disabled`, `hidden`, `value-now`, `pressed`, `live`... as `aria-*`;
  `focusable` as `tabindex` (a button's and a link's own); `tag`, `group`
  and `peer` ui's only, `id` the DOM's; StyleProps (`direction`, `width`...) as
  inline style.
- **Events**: ui's `Event` on both (`key` a `Key` code, `mods`, `x`,
  `y`, `stop`, `preventDefault`), the DOM renderer converting its events
  for these elements only (a page's own elements keep the DOM's).
- **Refs**: a `Part` (`focus`, `rect`, `scrollIntoView`, `rtl`, `capture` (a press's moves),
  `contains`, `attr`, `select` (a field's selection)), which Node implements and the DOM renderer wraps.
- **Layers**: `Layer` (a component: anchored, placed, modal or not), ui's
  overlay or the DOM's top layer.

Migration, both renderers green throughout (`theme-fidelity-check`,
`theme-dom-check`, `web-widgets`, the goldens, `WidgetParity`), no
widget's code growing, each DOM copy deleted as its widget becomes one
definition:

1. The vocabulary: `Part`, neutral events, `Layer`, `field`, `icon`;
   Node and a DOM wrapper implementing them; the DOM renderer's map of
   the intrinsic parts.
2. Static widgets: Button, Badge, Card, Label, Separator, Kbd, Skeleton,
   AspectRatio, Empty, Item.
3. Form controls: Toggle, ToggleGroup, Checkbox, Switch, RadioGroup,
   Slider, Input, Textarea, NumberField, Field, InputGroup, InputOTP.
4. Popups and menus: Tooltip, HoverCard, Popover, Dialog, AlertDialog,
   Sheet, Drawer, Select, Combobox, Command, the menus.
5. The rest: Table, Tree, Calendar, DatePicker, the charts, Carousel,
   Sidebar, NavigationMenu, ScrollArea; then `hxmc.web.widgets` is gone,
   and with it `WidgetParity`.

Split: packages/ui and the drawn realiser here; the DOM realiser
(packages/web) in parallel once the vocabulary is fixed.

Where it stands: steps 1 and 2 done, and 3: Toggle, ToggleGroup,
Checkbox, Switch, RadioGroup, Field and ButtonGroup (and their parts),
with Alert, Slider and RangeSlider (a drag on the track: Part's
capture), and the text fields (Input, Textarea, NumberField, InputOTP,
InputGroupInput: `field` and `field:textarea`, ui's TextField and
TextArea, native where `Ui.policy` says, the DOM's `<input>` and
`<textarea>`; `value` bound, `onInput` its text changed by its user
(Event.text), a node's own handlers (a field's editing) after the
markup's unless it prevented the default; `placeholder`, `type`, `rows`,
`readonly`, `maxlength`, `inputmode`, `autocomplete`; Part's `select`
for InputOTP's caret kept at the end; what a page's input has itself, ui's
in Widgets' fieldOwn: out of the tab order while disabled, the edit
menu), Progress (its slide on ui's Clock or a page's animation frames);
ahead of 4 and 5, Tabs, Listbox, Breadcrumb, Pagination, Collapsible,
Accordion, Calendar, Toolbar (its items a Part's `focusables`, roved by `tabStop`, the focused one by `holdsFocus`, a text field's keys its own by `editable`), TagInput (its field a `field`, its chips focusable buttons), Avatar (`image` an `<img>`), ScrollArea (`overflow-x`, `overflow-y`), Spinner (turned on ui's Clock, a page's by its theme's
animate-spin) and the Sidebar's parts (Trigger, Inset, Header, Content, Footer,
Separator, Group, GroupLabel, GroupContent, Menu, MenuItem, MenuButton):
82 widgets and parts one definition.

Debt: in a page a neutral widget calls a Part's methods (focus, rtl, rect, focusables, tabStop, holdsFocus, editable,
select) and reads an event's `current` opaquely (`js.Syntax.code`:
Widgets' mirroredKey, focusPart, selectPart and unseen), since the JS generator's DCE, upstream's,
keeps every implementation of an interface method called through it (a
Node's, and its nodes with it) and every field of a name read untyped;
ElementPart's methods are kept by `@:ifFeature` where a ref makes one.
A design that needs no such call (a part's direction read by the
renderer, say) would retire both.

## Built

### The browser's DOM renderer for the widgets, and the theme as CSS

- **The DOM's widgets** (`packages/web`, `hxmc.web.widgets.Widgets`):
  every widget of `hxmc.ui.widgets.Widgets`, with its props, as the DOM's
  elements with shadcn's markup (the element types shadcn and Radix use,
  `data-slot`, `data-state` and the rest, `aria-*`), its keys and focus
  as the drawn widget's, popups in the top layer (`popover`; modals as
  `<dialog>`). An app imports them in place of ui's; a page may still mix
  them with ui canvases per mount point.
- **Shared behaviour**: `hxmc.ui.widgets.Behaviour` (new, in
  packages/ui, pure: Key, Color and Days only): roving, mirroring, a
  slider's keys and steps, pagination's pages, a menu's entries, a tree's
  rows, a calendar's keys and months, HSV, a code field's characters,
  sortable moves, `TypeAhead`; `Shortcut`, `Days` and `Toasts` as they
  were. The DOM's widgets use it, and ui's widgets too (their menu items and
  tree rows are its MenuEntry and TreeLine).
- **The theme as CSS** (`hxmc.theme.Css`): the same shadcn.json and
  extras.json, each class as Tailwind writes it (checked class by class
  against Tailwind's own output), on `data-slot` selectors, light and dark
  by class or the system's, `@starting-style` for enter animations.
- **Fidelity**: `make theme-dom-check`, the DOM's widgets in Chromium
  against shadcn's references: all 252 cases within the bar, most
  identical (the third batch too: Field, ButtonGroup, InputGroup, Empty,
  Item, Carousel, NavigationMenu, Sidebar, BarChart and LineChart,
  AspectRatio, ScrollArea, NativeSelect, a calendar's range). **Behaviour**: `make web-widgets` drives the gallery by
  pointer and keys.
- **Size**: a counter is 44 KB of JavaScript (9.5 KB gzipped), the form 67
  KB (13 KB), the whole gallery 342 KB (62 KB), the CSS 186 KB (18 KB),
  against 1.8, 1.9 and 2.4 MB of wasm32-wasi (432, 459, 559 KB gzipped)
  for their canvas builds.

Left: the site's examples in DOM mode (the CSS scoped for it: `Css.sheet`'s
scope, the preflight and tokens kept to the widgets' elements); one definition per widget for both renderers (above).
