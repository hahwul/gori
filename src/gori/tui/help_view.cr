require "./screen"
require "./theme"
require "./brand"
require "../hotkeys"
require "../ql"
require "./viewport"

module Gori::Tui
  # The Help tab: a scrollable keyboard + mouse cheat-sheet, a QL reference, and an About page.
  # Read-only — ↑/↓ (or the wheel) scroll; there's nothing to select. When constructed with a
  # registry, rebindable rows resolve their key column through Hotkeys (same path
  # as the command palette) so a rebind is reflected here.
  class HelpView
    # One rendered line: a section :head, a key/desc :item, or a blank :gap.
    record Row, kind : Symbol, a : String, b : String

    # Left key column width + gap before the description. Long enough for labels like
    # "palette / settings" / "Settings: Hotkeys" so they don't run into the desc text.
    KEY_W   = 20
    KEY_GAP =  2

    # `verb_id` non-nil ⇒ the WHOLE key column is that verb's effective chord. A row naming
    # more than one chord — `^R · ^X` run/stop, a tab's summary line — spells each as a
    # `{verb.id}` token instead, in either column; `shortcut_rows` expands them through the
    # same keymap (Hotkeys.expand). The `verb_id` form is kept for the single-chord rows
    # because it also carries the fallback the registry-less render prints.
    record Item, key : String, desc : String, verb_id : String? = nil

    # {section title, items} — the source of the rendered rows.
    SECTIONS = [
      {"GLOBAL", [
        Item.new("^P", "command palette", "app.palette"),
        Item.new("space", "focus-area action menu"),
        Item.new("c", "toggle capture", "capture.toggle"),
        Item.new("i", "toggle intercept", "intercept.toggle"),
        Item.new("s", "toggle scope lens (or click scope:N)", "scope.toggle-lens"),
        Item.new("^P", "Match & Replace → Rewriter tab (palette)", "rules.edit"),
        Item.new("badge / ^P", "notification center (palette; rebindable)", "app.notifications"),
        Item.new("^, / ⚙", "preferences — every setting (also ^P → Settings)", "settings.open"),
        Item.new("^B", "reveal whitespace (·→␍␊)", "view.reveal-ws"),
        Item.new("^D / ^C ×2", "quit gori"),
        Item.new("q", "back to projects (on the tab bar)"),
        Item.new("?", "open this Help tab", "tab.help"),
        # The same two pages as a popup over whatever you were doing, so looking a key up
        # does not cost the pane you were in. Both are palette-only; `binding_label` prints
        # the literal `^P` here for want of a chord, and follows one if either ever gains it.
        Item.new("^P", "this page as a popup — 'Keyboard shortcuts'", "help.hotkeys"),
        Item.new("^P", "the Query page as a popup — also `?` on an empty filter bar", "help.query"),
        Item.new("^P", "the guided tour on a mock UI, then back here — also `gori tutorial`", "help.tour"),
        Item.new("Settings: Hotkeys", "rebind any shortcut below (^P → Settings: Hotkeys)"),
        Item.new("gori wizard", "re-run the first-run setup (bind · theme · Miss Ring) from a shell"),
      ]},
      {"TABS & FOCUS", [
        Item.new("←/→", "switch tab (on the tab bar)"),
        Item.new("↹ / ⇧↹", "focus ring: tab bar ↔ panes"),
        Item.new("↵ / ↓", "enter the tab body"),
        Item.new("1-9", "jump to the Nth visible tab"),
        # Seventeen surfaces bind j/k and no hint anywhere named them, so a whole navigation
        # layer was reachable only by guessing. It belongs HERE rather than in each tab's
        # hint: it is a global convention like ^P or ^D, the hints are already at the width
        # the status strip gives them, and spending six cells per tab to repeat one rule
        # would push a tab-specific key off the end.
        Item.new("j / k", "move down / up — anywhere ↑/↓ moves (h/l where ←/→ do)"),
        # The answer to "I have thirty Repeater sessions and the one I want has scrolled off".
        # It earns a line here for the same reason j/k does — the key is real on eight tabs and
        # named on none of them until the operator is already standing on the strip.
        Item.new("f", "sub-tab strip: list + search every sub-tab (⌕, from any chip)"),
        Item.new("Settings: Tabs", "show/hide + reorder tabs"),
        Item.new("esc", "pop back to the tab bar"),
      ]},
      {"MOUSE", [
        Item.new("click tab", "switch to it"),
        Item.new("click row", "select · click again opens"),
        Item.new("click pane", "focus · in an editor, place the caret"),
        Item.new("sub-tab chip", "switch · ⌕ at the left lists them all · right-click renames"),
        Item.new("wheel", "scroll / move the selection"),
        Item.new("click outside", "close a popup"),
      ]},
      {"HISTORY", [
        Item.new("↑/↓ · ↵", "move · open the flow"),
        Item.new("^R", "send the flow to Repeater", "history.repeater"),
        Item.new("⇧I", "send the flow to the Fuzzer", "history.fuzz"),
        Item.new("⇧F", "create an issue", "issue.create"),
        Item.new("f", "follow newest", "history.toggle-follow"),
        Item.new("/", "filter (query language — see the Query page)", "history.query"),
        Item.new("y", "copy flow", "history.copy"),
        Item.new("space → Y", "copy as… — urls · hosts · cURL · raw · req+res pair"),
        Item.new("d", "delete selected/marked flows (asks first)", "history.delete"),
        Item.new("⇧X", "clear all History flows (asks first)", "history.clear"),
        Item.new("i", "toggle intercept hold-mode", "intercept.toggle"),
        Item.new("detail", "↑/↓ move · {detail.select-line} line · ⇧arrows select · {detail.copy} copy · space cmds"),
        Item.new("{detail.toggle-hex} · {detail.toggle-ws} · {detail.toggle-pretty}", "in detail: hex · whitespace · pretty bodies"),
      ]},
      {"REPEATER", [
        Item.new("^R", "send the request", "repeater.send"),
        Item.new("^N / ^W", "new / close a sub-tab"),
        Item.new("r", "rename the sub-tab (on the strip)"),
        Item.new("/", "filter sub-tabs (tag: name: host: method:)", "repeater.filter-subtabs"),
        Item.new("↹", "complete filter field/value while filtering"),
        Item.new("t", "tag the active sub-tab (on the strip)", "repeater.tag-subtab"),
        Item.new("i / ↵", "enter INS (edit) on request/target · esc back to READ"),
        Item.new("space", "command menu (READ mode on request/target/response)"),
        # Copy is the one READ verb that also works while TYPING: in INS a bare `y` is a
        # literal character (and typing it over a selection REPLACES it), so INS gets the
        # ctrl form. The key column resolves `y` from the verb id; `^Y` is its second chord.
        Item.new("y · ^Y", "copy selection/line — `y` in READ, ^Y in INS too", "repeater.copy"),
        Item.new("x · ⇧arrows", "select the current line · extend selection"),
        # The §…§ marker trio, same keys and same order as the FUZZER section below — the
        # Repeater grew `^K`/`^T` to match and Help documented neither.
        Item.new("{repeater.auto-mark} · {repeater.mark-word} · {repeater.toggle-decoded}", "auto-mark params · mark word · mark point (manual §)"),
        Item.new("space → c", "clear every § marker", "repeater.clear-marks"),
        # ^Q, not ^Y — ^Y is Copy in every text box now (see the `y · ^Y` row above). The key
        # column resolves from the verb id, so it follows a rebind either way.
        Item.new("^Q", "edit the decoder chain on the marker at the cursor", "repeater.attach-chain"),
        Item.new("^X", "hex-edit the request", "repeater.toggle-hex"),
        Item.new("^S", "SNI override (on the target)", "repeater.toggle-sni"),
        Item.new("^L", "toggle auto Content-Length", "repeater.toggle-auto-content-length"),
        Item.new("space → F", "gRPC: reframe the message on send (on by default; off sends the captured 5-byte length prefix)", "repeater.toggle-grpc-reframe"),
        Item.new("space → E", "gRPC: edit the request message field by field through the loaded .proto (unary calls)", "repeater.toggle-grpc-fields"),
        Item.new("^V", "transport: HTTP/1.1 ↔ HTTP/2 · on a WebSocket tab, WS → h1 → h2 (send the handshake as plain HTTP)", "repeater.toggle-http2"),
        Item.new("space → g", "send group: %%%-split requests on one connection"),
        Item.new("↹", "cycle target → request → response"),
        Item.new("d", "response: toggle diff", "repeater.toggle-diff"),
        Item.new("p", "response: pretty bodies", "repeater.toggle-pretty"),
        Item.new("^X", "response: hex dump (pane-local)"),
        Item.new("⇧←/→", "response: scroll a long line sideways"),
      ]},
      {"FUZZER", [
        Item.new("⇧I", "send a flow/repeater here (History/Repeater)"),
        Item.new("^N / ^W", "new / close a sub-tab"),
        Item.new("i / ↵", "enter INS (edit) on target/template · esc back to READ"),
        Item.new("space", "command menu (READ mode on target/template/results/detail)"),
        # NOT `y · O`. The `*.copy-all` verbs are gone — `Runner#read_copy` folds it into one
        # key: `y` copies the selection if there is one, else the whole pane. The row was
        # advertising an `O` that stopped existing when they merged.
        #
        # `y · ^Y`: the template editor grows a ⇧arrow band in INSERT too, where a bare `y`
        # types a `y` over it. The READ letter resolves from the verb; `^Y` is the PINNED half
        # (`Verb::Keymap.pinned_chords`), so it is spelled out and never moves.
        Item.new("{fuzzer.copy} · ^Y", "copy selection/pane — `y` in READ, ^Y in INS too"),
        Item.new("⇧arrows", "select text (line or char)"),
        Item.new("{fuzz.automark} · {fuzz.mark-word} · {fuzz.insert-marker}", "auto-mark params · mark word · mark point (manual §)"),
        # NOT `^U clear §` — that was wrong twice over: ^U is fuzz.pretty-template (the tab's
        # own ` ^U:PRETTY ` badge says so), and clear-marks has no chord at all. The advertised
        # key silently reflowed the template you had just finished marking by hand.
        Item.new("^U", "pretty-print the template body (space → c clears §)", "fuzz.pretty-template"),
        Item.new("^V", "toggle transport HTTP/1.1 ↔ HTTP/2", "fuzz.toggle-http2"),
        Item.new("^S", "SNI override (on the target)", "fuzz.toggle-sni"),
        Item.new("^O", "focus the config pane (payload sets · Mode · Advanced · Run)"),
        Item.new("config", "↑/↓ rows · ↵ edit a set / Add / Advanced / Run · ←/→ Mode · Del remove a set"),
        Item.new("^L", "add a List payload set (one value per line, paste splits)", "fuzz.list-paste"),
        Item.new("set editor", "↹/↑↓ fields · List = multi-line · wordlist path auto-completes · esc applies"),
        Item.new("{fuzz.run} · {fuzz.stop}", "run · stop"),
        Item.new("↑/↓ · ↵", "results: select · open detail"),
        Item.new("o · m", "sort · matched-only"),
        Item.new("r", "rename the sub-tab (on the strip)"),
        Item.new("⇧←/→", "detail: scroll a long line sideways"),
      ]},
      # Miner, OAST and JWT had NO section at all, while Sequencer — also a default-hidden
      # tab — has a full one, so "it's hidden" was never the rule being applied. Three tabs
      # whose entire keyboard surface was undiscoverable from the one screen that exists to
      # answer "what can I press here".
      {"MINER", [
        Item.new("Mine parameters", "from History/Repeater (space menu) — finds params the app accepts but never shows"),
        Item.new("{mine.run} · {mine.stop}", "mine · stop"),
        Item.new("↹", "summary ⟷ findings"),
        Item.new("↑/↓ · ↵", "findings: select · open detail"),
        Item.new("space → R", "send the selected finding to Repeater (param injected)", "mine.repeater"),
        Item.new("^N / ^W", "new / close a sub-tab"),
      ]},
      {"JWT", [
        Item.new("^T", "switch decode ⟷ encode", "jwt.toggle-mode"),
        Item.new("^A", "cycle the signing alg (alg=none included)", "jwt.cycle-alg"),
        Item.new("^L", "clear the session", "jwt.clear"),
        Item.new("↹", "cycle INPUT → DECODED → ATTACKS (decode) / HEADER → PAYLOAD → SECRET → OUTPUT (encode)"),
        Item.new("i / ↵", "enter INS on an editable pane · esc back to READ"),
        # The tab had no copy row at all, and it is the one tab where the ctrl form is not a
        # convenience: HEADER/PAYLOAD/SECRET always capture keys, so `^Y` is their ONLY copy.
        #
        # A `{jwt.copy}` token beside a literal `^Y`, not a verb id on the row: `build_rows`
        # would REPLACE the key column with `binding_label`, which answers the PRIMARY chord —
        # a bare `y` next to a description whose whole point is that `y` types a `y` on three
        # of these panes. The token resolves the READ letter (the pair is rebindable since
        # #932: a rebind moves the letter, `^Y` stays pinned) and the pin is spelled out.
        Item.new("{jwt.copy} · ^Y", "copy selection/pane — `y` in READ, ^Y while typing (ENCODE panes: ^Y only)"),
        Item.new("⇧arrows", "select text in INPUT / HEADER / PAYLOAD (not SECRET — single-line field)"),
        Item.new("↑/↓ · ↵", "attacks: select · copy the selected payload"),
        Item.new("^N / ^W", "new / close a sub-tab"),
      ]},
      {"COOKIE", [
        Item.new("^T", "switch decode ⟷ forge", "cookie.toggle-mode"),
        Item.new("^A", "cycle the format (auto / flask / rack / django)", "cookie.cycle-format"),
        # No verb id: cookie.cycle-algorithm has no chord (^G is the shell's go-to-line key), so
        # the OPTIONS `algo` badge is click-only, plus `Space → g` and the palette. A verb id here
        # would make build_rows print a key that does not fire.
        Item.new("algo badge / Space g", "cycle the Django HMAC algorithm (sha256 / sha1)"),
        Item.new("^L", "clear the session", "cookie.clear"),
        Item.new("↹", "cycle INPUT → DECODED → OPTIONS → SECRET (decode) / PAYLOAD → OPTIONS → SECRET → OUTPUT (forge)"),
        Item.new("c", "crack the secret over the SECRET field (a wordlist path or comma list)", "cookie.crack"),
        Item.new("l", "seed the FORGE payload from the decoded cookie (space menu)", "cookie.load-decoded"),
        # Same shape as the JWT row above: the letter follows a rebind, the `^Y` pin does not.
        Item.new("{cookie.copy} · ^Y", "copy selection/pane — `y` in READ, ^Y while typing an editable pane"),
        Item.new("^N / ^W", "new / close a sub-tab"),
      ]},
      {"OAST", [
        Item.new("{oast.listen} · {oast.stop}", "start listening · stop"),
        Item.new("↑/↓ · ↵", "callbacks: select · open detail"),
        Item.new("space → p", "promote a callback to an Issue", "oast.promote"),
        Item.new("space → a", "add a provider · e edit · x enable/disable"),
        Item.new("payload", "insert an OAST payload into the focused editor (space → O)", "oast.insert-payload"),
      ]},
      {"SEQUENCER", [
        Item.new("Send to Sequencer", "from History/Repeater/Sitemap (space menu) — replay + analyze a token"),
        Item.new("Send selection to → Sequencer", "selected text becomes manual token sample(s)"),
        Item.new("c", "configure the token location (cookie/header/regex/position/jsonpath) + goal", "sequence.configure"),
        Item.new("{sequence.run} · {sequence.stop}", "run collection · stop"),
        Item.new("↹", "cycle config → samples → analysis"),
        Item.new("↑/↓ · ↵", "samples: select · open detail"),
        Item.new("^W · r", "close · rename the sub-tab (on the strip)"),
      ]},
      {"COMPARER", [
        Item.new("{comparer.pick-a} · {comparer.pick-b}", "pick flow A · flow B"),
        Item.new("←/→", "compare requests ⟷ responses"),
        Item.new("⇧←/→", "h-scroll both columns (long lines)"),
        Item.new("s", "swap A ⇄ B", "comparer.swap"),
        Item.new("^N / ^W · r", "new / close / rename comparison sub-tab"),
        Item.new("Send to Comparer", "from History (space menu) — fills the active sub-tab"),
      ]},
      {"EDITORS", [
        Item.new("^G · ^F", "go to line · find (↵/↑↓ step)"),
        Item.new("  where", "Repeater · History detail · Intercept · Notes · Project · Decoder · Fuzzer"),
        Item.new("^F then tab", "find & replace — ↵ swaps every match (one undo step); editable panes only"),
        Item.new("^E", "open the field in $EDITOR"),
        Item.new("^B", "reveal whitespace"),
      ]},
      {"OTHER TABS", [
        Item.new("Sitemap", "↑/↓ · {sitemap.query} filter · ↵/→ expand · {sitemap.mark-toggle} mark · {sitemap.toggle-grouping} fold · {sitemap.scope-toggle} scope · space → T tag"),
        # `⇧X clear` sits in the LIST half, where the chord fires — and it is on this row at all
        # for the reason the Probe and Authorize rows carry theirs: a wipe has to be named where
        # it can be read before it is pressed. Marks make that sharper here than anywhere else,
        # since `d` acts on the marked set and this one does not.
        Item.new("Issues", "list: {issues.mark-toggle} mark · {issues.mark-all} all · ⇧arrows range · {issues.clear} clear · notes: i/↵ edit · {issue.select-line} line · {issue.copy} copy · space cmds"),
        Item.new("Probe", "↑/↓ ↵ open · {probe.mode} mode · {probe.dismiss-selected} dismiss · {probe.toggle-closed} all · {probe.filter} filter · {probe.scope-toggle} scope · {probe.clear} clear issues · space cmds"),
        # Authorize had no row at all while `TAB_SECTION` pointed its Shortcuts popup here — so
        # the one tab whose keys are `^R`/`⇧R`/`^X` and nothing an operator can guess opened on
        # a section that never named it.
        Item.new("Authorize", "↑/↓ request · ⇥ identity · {authorize.run} run · {authorize.run-all} all · {authorize.identities} identities · {authorize.clear} clear queue"),
        Item.new("Notes", "i/↵ edit · {notes.select-line} line · ⇧arrows select · {notes.copy} copy · space cmds (Copy selected when highlighted)"),
        # No pane inventory: the chip strip names all six on screen, no sibling row lists sub-panes,
        # and the parenthetical was what pushed this row past `HelpPopupOverlay::MAX_W` when the
        # sixth pane arrived — it would have broken again at the seventh. Keys only, like the rest.
        # `x line · y copy` stay LITERAL here, unlike the sibling rows above: the description
        # pane dispatches both raw (`ProjectController#handle_desc_read`), and the matching
        # verbs carry no bare chord to read — `project.select-line` has none at all and
        # `project.copy` is `^Y` only — so a token would resolve to the wrong key or to none.
        Item.new("Project", "←/→ sub-tab · ↓/↵ enter · desc: i/↵ edit · x line · y copy · space cmds"),
        # ACTIVITY is a Project sub-tab, so its keys hang off the row above rather than earning
        # a section — but `⇧X` there deletes the durable audit trail, which is the one key on
        # this tab that must be named somewhere the operator can read before pressing it.
        Item.new("  activity", "{activity.filter-source} source · {activity.filter-level} level · {activity.filter-actor} actor · {activity.find} filter · ↵ open · {activity.clear} clear the feed"),
        Item.new("Intercept", "↵/e edit · {intercept.forward} fwd · {intercept.drop} drop · {intercept.forward-all} all · {intercept.direction} catch · {intercept.filter} condition · {intercept.toggle} on/off"),
      ]},
      {"DECODER", [
        Item.new("i / ↵", "enter INS on INPUT · esc back to READ"),
        Item.new("INPUT READ", "⇧arrows select · {decoder.copy} copy · space cmds"),
        Item.new("INPUT INS", "⇧arrows select · ^Y copy (bare y types a `y`)"),
        Item.new("chain", "always editable — base64 > url-encode > sha256 ( > | , )"),
        Item.new("↹ / ↵", "complete the suggested converter (popup)"),
        Item.new("OUTPUT", "↑/↓ move · ⇧arrows select · {decoder.copy} copy"),
        Item.new("^X", "cycle text/hex/base64", "decoder.mode"),
        Item.new("{decoder.save} · {decoder.load}", "save the chain under a name · pick from the saved chains"),
        Item.new("chain library", "shared by every project · picker: type to filter · ^X deletes an entry"),
        Item.new("^N · ^W", "new · close conversion sub-tab"),
        Item.new("^1-9 · r", "switch sub-tab · rename (on the strip)"),
        Item.new("space", "command menu from the strip, tab bar, INPUT READ or OUTPUT (a literal space while typing)"),
      ]},
      {"REWRITER", [
        Item.new("{rewriter.add} · ↵/e", "add a Match & Replace rule · edit the selected one"),
        Item.new("x · {rewriter.delete}", "enable/disable in this project · delete the selected rule"),
        Item.new("{rewriter.scope} · {rewriter.toggle-default}", "move the rule global ⇄ project · flip a global rule's default everywhere"),
        Item.new("G / P column", "global (every project) or project · G* = this project overrides its default"),
        Item.new("{rewriter.move-down} / {rewriter.move-up}", "reorder within a scope — globals apply first, then project rules"),
        Item.new("[ / ]", "switch sub-tab: rules · extract · bindings"),
        Item.new("↓ past the list", "the editable preview sample, and the same message after the rules run"),
        # NOT "y copies the OUTPUT · ^Y copies the INPUT": `rewriter.copy` is ONE verb with two
        # chords, and `rewriter_copy` branches on the FOCUSED PANE, not on which chord fired —
        # `^Y` on OUTPUT copies the OUTPUT. The real split is mode, not pane: the INPUT sample
        # is always typing, so there `y` is a literal character and `^Y` is the only copy.
        Item.new("preview", "⇧arrows select · {rewriter.copy} copy (OUTPUT) · ^Y copy while typing (INPUT sample)"),
      ]},
      {"COLORMARKER", [
        Item.new("{colormarker.add} · ↵/e", "add a History row-colour rule · edit the selected one"),
        Item.new("{colormarker.toggle} · {colormarker.delete}", "enable/disable in this project · delete the selected rule"),
        Item.new("{colormarker.scope} · {colormarker.toggle-default}", "move the rule global ⇄ project · flip a global rule's default everywhere"),
        Item.new("{colormarker.move-down} / {colormarker.move-up}", "reorder — the FIRST enabled match paints the row, the rest are skipped"),
        Item.new("style", "full = tint the whole row · strip = one colour cell ahead of TIME"),
        Item.new("when:", "host: path: method: scheme: status: proto: — ↹ completes · no header:/size:/dur:"),
        Item.new("↹ · ↓ past list", "CUSTOM COLORS pane — a add · ↵/e edit · d delete (name + #hex)"),
        Item.new("custom colour", "a global name the picker offers everywhere; its hex is absolute, not theme-relative"),
        Item.new("hidden by default", "settings:tabs shows it, next to Rewriter"),
      ]},
      {"OVERLAYS", [
        Item.new("palette / settings", "↑/↓ · ↵ · esc"),
        Item.new("confirm", "←/→ choose · y / n · ↵"),
        Item.new("Settings: Mouse", "toggle mouse support, and what releasing a drag does"),
        # No row for the save/load library modal here: the DECODER section already states it,
        # and the key column truncates at ~20 cols anyway ("save / load a libra…"), so a
        # second copy would be both redundant and unreadable.
      ]},
    ]

    # Which SECTIONS entry a tab's shortcuts live under. Read by the palette's Shortcuts
    # popup, which opens scrolled to the section for the tab you were on — the popup exists
    # for the "I'm here, what can I press" moment, and landing on GLOBAL every time would
    # make the operator scroll for the answer they came with.
    #
    # The tabs with no section of their own share OTHER TABS, one row each — plus a second,
    # indented row under Project for its ACTIVITY sub-tab, which is where the one destructive
    # key on that tab lives. :target is the one entry here with no row of its own yet; :help is
    # absent from this table entirely so opening from Help lands at the top (the whole sheet is
    # already what that tab shows). A spec pins every Chrome::TABS symbol either here or
    # deliberately out, and pins every title named here against SECTIONS — a typo'd title would
    # otherwise silently degrade to "open at the top".
    TAB_SECTION = {
      :history     => "HISTORY",
      :repeater    => "REPEATER",
      :fuzzer      => "FUZZER",
      :miner       => "MINER",
      :oast        => "OAST",
      :sequencer   => "SEQUENCER",
      :decoder     => "DECODER",
      :jwt         => "JWT",
      :cookie      => "COOKIE",
      :comparer    => "COMPARER",
      :rewriter    => "REWRITER",
      :colormarker => "COLORMARKER",
      :target      => "OTHER TABS",
      :sitemap     => "OTHER TABS",
      :issues      => "OTHER TABS",
      :probe       => "OTHER TABS",
      :authorize   => "OTHER TABS",
      :notes       => "OTHER TABS",
      :project     => "OTHER TABS",
      :intercept   => "OTHER TABS",
    }

    @rows : Array(Row)
    @scroll : Int32 = 0
    @search_page : Symbol? = nil
    @search_query = ""
    @search_preedit = ""
    @search_origin_scroll : Int32 = 0

    getter search_query : String

    def initialize(registry : Verb::Registry? = nil)
      @rows = HelpView.shortcut_rows(registry)
    end

    # Rebuild from the live registry (call after a hotkeys save so Help stays honest).
    def reload(registry : Verb::Registry) : Nil
      cancel_search
      @rows = HelpView.shortcut_rows(registry)
      @scroll = 0
    end

    # A class method, not an instance one, because the palette's Shortcuts popup renders the
    # SAME rows without owning a HelpView. Going through here rather than reading SECTIONS is
    # what keeps the popup honest: the key column is resolved from the live keymap below, so a
    # rebind (or the ⌥ alias) reaches both surfaces or neither.
    def self.shortcut_rows(registry : Verb::Registry?) : Array(Row)
      rows = [] of Row
      SECTIONS.each_with_index do |(title, items), si|
        rows << Row.new(:gap, "", "") if si > 0
        rows << Row.new(:head, title, "")
        items.each do |item|
          key = item.key
          desc = item.desc
          if registry
            if id = item.verb_id
              key = Hotkeys.binding_label(registry, id, item.key)
            end
            key = Hotkeys.expand(registry, key)
            desc = Hotkeys.expand(registry, desc)
          end
          # Retag both columns: a verb-id row and the `{verb.id}` tokens already resolve
          # through the keymap, but the keyless rows (^N/^W, ^G/^F, ^1-9) and the claimed
          # chords named inside descriptions are hand-written literals.
          rows << Row.new(:item, Hotkeys.retag(key), Hotkeys.retag(desc))
        end
      end
      rows
    end

    # Filter a grouped reference list while retaining the heading for every surviving item.
    # The Help tab and its popup use the same projection so `/` cannot disagree between the
    # two surfaces about what a query matches or leave empty headings behind.
    def self.search_rows(rows : Array(Row), query : String) : Array(Row)
      return rows if query.empty?
      needle = query.downcase
      out = [] of Row
      head = nil.as(Row?)
      rows.each do |row|
        case row.kind
        when :head
          head = row
        when :item
          next unless "#{row.a} #{row.b}".downcase.includes?(needle)
          if h = head
            out << h
            head = nil
          end
          out << row
        end
      end
      out
    end

    def searching? : Bool
      !@search_page.nil?
    end

    def cancel_search : Nil
      if page = @search_page
        restore_search_scroll(page)
      end
      @search_page = nil
      @search_query = ""
      @search_preedit = ""
    end

    # Active search claims text and its own escape/navigation vocabulary before the Help
    # controller's h/l page switching. Modified chords still fall through to the global
    # keymap (^P, ^B, …), and Tab remains the shell's focus-ring key.
    def handle_search_key(ev : Termisu::Event::Key, current_page : Symbol? = nil) : Bool
      return start_search_key(ev, current_page) unless page = @search_page
      handle_active_search_key(ev, page)
    end

    private def start_search_key(ev : Termisu::Event::Key, page : Symbol?) : Bool
      char = ev.char || ev.key.to_char
      return false unless (page == :shortcuts || page == :query) && char == '/' && !ev.ctrl? && !ev.alt?

      # Search belongs to the reference page that was visible when `/` was pressed. The
      # controller cancels it before switching pages, so the query never silently follows the
      # operator from Shortcuts to the unrelated Query/About page.
      @search_page = page
      @search_origin_scroll = page == :query ? @query_scroll : @scroll
      @search_query = ""
      @search_preedit = ""
      true
    end

    private def handle_active_search_key(ev : Termisu::Event::Key, page : Symbol) : Bool
      key = ev.key
      case
      when key.escape?    then cancel_search
      when key.up?        then search_move(page, -1)
      when key.down?      then search_move(page, 1)
      when key.home?      then search_home(page)
      when key.end?       then search_move(page, 10_000)
      when key.backspace? then search_backspace(page)
      when key.enter?, key.left?, key.right? # inert while the search field owns the pane
      else
        return insert_search_key(ev, page)
      end
      true
    end

    private def insert_search_key(ev : Termisu::Event::Key, page : Symbol) : Bool
      char = ev.char || ev.key.to_char
      return false unless char && !ev.ctrl? && !ev.alt?
      return true if char.control?
      @search_preedit = ""
      @search_query += char
      search_home(page)
      true
    end

    def set_search_preedit(text : String) : Bool
      return false unless searching?
      @search_preedit = text
      true
    end

    private def search_backspace(page : Symbol) : Nil
      return if @search_query.empty?
      @search_preedit = ""
      @search_query = @search_query[0, @search_query.size - 1]
      @search_query.empty? ? restore_search_scroll(page) : search_home(page)
    end

    private def restore_search_scroll(page : Symbol) : Nil
      if page == :query
        @query_scroll = @search_origin_scroll
      else
        @scroll = @search_origin_scroll
      end
    end

    private def search_home(page : Symbol) : Nil
      if page == :query
        @query_scroll = 0
      else
        @scroll = 0
      end
    end

    private def search_move(page : Symbol, delta : Int32) : Nil
      page == :query ? query_move(delta) : move(delta)
    end

    # Scroll by `delta` lines (the wheel + ↑/↓). render clamps the floor; the top
    # clamp lands in clamp_scroll so a tall pane never scrolls past the last line.
    def move(delta : Int32) : Nil
      @scroll = {@scroll + delta, 0}.max
    end

    # The Runner pops focus to the tab bar when ↑ is pressed at the top (like the lists).
    def at_top? : Bool
      @scroll == 0
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      list = render_search_bar(screen, rect, :shortcuts, focused)
      rows = visible_rows(:shortcuts, @rows)
      clamp_scroll(list.h, rows.size)
      if rows.empty?
        screen.text(list.x + 1, list.y, "no help rows match", Theme.muted, Theme.bg, width: {list.w - 2, 1}.max)
        return
      end
      (0...list.h).each do |i|
        li = @scroll + i
        break if li >= rows.size
        HelpView.draw_row(screen, list, list.y + i, rows[li])
      end
    end

    # `key_w` is a parameter rather than the constant because the Query page's left column holds
    # QL EXPRESSIONS, not key chords: `NOT (host:cdn OR host:img)` is 26 columns where the widest
    # chord label is 20, and truncating an example query to `NOT (host:cdn OR ho…` would teach the
    # syntax wrong. Same two-column row, one page's worth of extra room.
    #
    # A class method for the same reason `shortcut_rows` is: the palette's Shortcuts/Query popup
    # paints the same two-column row into its card, and one painter is what stops the two
    # surfaces disagreeing about where the description column starts. It reads no instance state.
    def self.draw_row(screen : Screen, rect : Rect, y : Int32, row : Row,
                      key_w : Int32 = KEY_W) : Nil
      case row.kind
      when :head
        screen.text(rect.x + 1, y, row.a, Theme.accent, attr: Attribute::Bold, width: {rect.w - 2, 1}.max)
      when :item
        kw = {key_w, {rect.w - 3 - KEY_GAP, 1}.max}.min
        screen.text(rect.x + 2, y, row.a, Theme.text_bright, width: kw)
        dx = rect.x + 2 + key_w + KEY_GAP
        screen.text(dx, y, row.b, Theme.muted, width: {rect.right - dx - 1, 1}.max) if dx < rect.right - 1
        # :gap → blank line
      end
    end

    # The tail half of the shared list-viewport arithmetic, alone: this page has no selection
    # to track (↑/↓ and the wheel move `@scroll` itself, and `move` applies the floor), so only
    # the "never scroll past the last full page" clamp applies. `@rows` is the built page the
    # draw loop walks — it is rebuilt whole when the sub-tab changes, which is when a stale
    # offset from a longer page would otherwise strand the new one.
    private def clamp_scroll(h : Int32, size : Int32 = @rows.size) : Nil
      @scroll = Viewport.clamp_scroll(@scroll, h, size)
    end

    # --- the "Query" sub-tab page ---------------------------------------------
    # The QL reference, in the tab an operator is already in. It exists because the language had
    # nowhere to be READ: a filter bar teaches one row at a time, `ql_reference` is an MCP tool
    # for models, and the docs site is not open while you are looking at traffic. Help's own entry
    # for `/` said "filter (query language)" and stopped there.
    #
    # Every row is BUILT from the parser's tables — `QL::SYNTAX_HELP`, `QL::FIELDS` +
    # `QL::FIELD_HELP`, `QL::CAVEATS` — and none is written here. That is the whole point: a
    # hand-authored copy of the field list is what `FILTER_HINT` and `QUERY_HINT` were, and they
    # disagreed with `FIELDS` and with each other for long enough that an operator could not find
    # `-term` on the two surfaces most likely to be asked for it.
    QUERY_KEY_W = 28

    # The default field-help lookup. A constant proc rather than an inline closure because
    # `query_rows`'s default argument would otherwise allocate one per call — the same reason
    # `InterceptFilter::FIELD_HELP_PROC` exists.
    QL_FIELD_HELP = ->(f : String) { QL.field_help(f) }

    # Its own offset, not `@scroll`: the two pages have different lengths, and sharing one would
    # carry the cheat-sheet's position onto this page — where `at_top?` then answers about the
    # wrong page and ↑ pops focus to the strip in the middle of a scroll.
    @query_scroll : Int32 = 0

    def query_move(delta : Int32) : Nil
      @query_scroll = {@query_scroll + delta, 0}.max
    end

    def query_at_top? : Bool
      @query_scroll == 0
    end

    def render_query(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      list = render_search_bar(screen, rect, :query, focused)
      rows = visible_rows(:query, query_rows)
      @query_scroll = @query_scroll.clamp(0, {rows.size - list.h, 0}.max)
      if rows.empty?
        screen.text(list.x + 1, list.y, "no help rows match", Theme.muted, Theme.bg, width: {list.w - 2, 1}.max)
        return
      end
      (0...list.h).each do |i|
        li = @query_scroll + i
        break if li >= rows.size
        HelpView.draw_row(screen, list, list.y + i, rows[li], QUERY_KEY_W)
      end
    end

    private def visible_rows(page : Symbol, rows : Array(Row)) : Array(Row)
      @search_page == page ? HelpView.search_rows(rows, @search_query) : rows
    end

    # The full Help pane keeps the search affordance visible on both reference pages. Unlike
    # the popup it is already inside a framed body, so one compact row is enough; the list
    # begins immediately below it.
    #
    # Only a FOCUSED search field claims the hardware caret. Tab is the shell's focus-ring key
    # and is consumed by the runner before `handle_body_key`, so an active search survives a
    # step out to the strip or tab bar; without this gate the pane would keep stamping
    # `desired_cursor` (and anchoring the terminal's IME composition) inside an unfocused body.
    private def render_search_bar(screen : Screen, rect : Rect, page : Symbol, focused : Bool) : Rect
      screen.fill(Rect.new(rect.x, rect.y, rect.w, 1), Theme.bg)
      if @search_page == page
        px = screen.text(rect.x + 1, rect.y, "search: ", Theme.accent, Theme.bg)
        w = {rect.right - px - 1, 1}.max
        if focused
          screen.input_line(px, rect.y, @search_query, @search_query.size, @search_preedit,
            Theme.text_bright, Theme.bg, width: w)
        else
          screen.text(px, rect.y, @search_query, Theme.text_bright, Theme.bg, width: w)
        end
      else
        screen.text(rect.x + 1, rect.y, "/ search", Theme.muted, Theme.bg, width: {rect.w - 2, 1}.max)
      end
      rect.h > 1 ? Rect.new(rect.x, rect.y + 1, rect.w, rect.h - 1) : Rect.new(rect.x, rect.y, rect.w, 0)
    end

    # Memoised per instance: the tables are constants, so this is the same list every time, and
    # `render_query` runs on the draw path.
    private def query_rows : Array(Row)
      @query_rows ||= HelpView.query_rows
    end

    @query_rows : Array(Row)? = nil

    # Built fresh per call, and deliberately NOT memoised on the class: the callers each hold
    # their own copy for the lifetime they need it (this view above, the palette popup at open
    # time), and neither is on a draw path that would notice. A class-level `||=` would be
    # shared mutable state bought for nothing.
    #
    # `fields`/`help` are parameters because the FIELD LIST is per-surface even though the
    # GRAMMAR is not. Every bar parses through `FilterAst`, so SYNTAX and WORTH KNOWING are the
    # same everywhere — but the Intercept condition accepts nine of QL's eighteen fields and
    # deliberately redefines four of them (`InterceptFilter::FIELD_HELP`: `status:` "scopes to
    # RESPONSES only", `header:` "this leg only", …), and Sitemap adds a `tag:` that never
    # reaches the parser at all.
    #
    # Handing this page QL's tables on those surfaces is precisely the drift `FIELD_HELP`'s own
    # comment says it was merged-not-copied to prevent — a reference stating the opposite of what
    # the bar under it will do. Aliases are filtered to targets that survive `fields` for the
    # same reason: `res.header:` is not "also accepted" where `resp.header:` does not exist.
    def self.query_rows(fields : Array(String) = QL::FIELDS,
                        help : Proc(String, String?) = QL_FIELD_HELP,
                        aliases : Hash(String, String) = QL::FIELD_ALIASES) : Array(Row)
      rows = [] of Row
      rows << Row.new(:head, "SYNTAX", "")
      QL::SYNTAX_HELP.each { |(example, meaning)| rows << Row.new(:item, example, meaning) }

      # Fields in `FIELDS` order — the order completion offers them, so the page and the Tab key
      # agree about what comes first.
      rows << Row.new(:gap, "", "")
      rows << Row.new(:head, "FIELDS  (: matches, ~ is regex)", "")
      fields.each do |name|
        rows << Row.new(:item, "#{name}:", help.call(name) || "")
      end

      live = aliases.select { |_, to| fields.includes?(to) }
      unless live.empty?
        rows << Row.new(:gap, "", "")
        rows << Row.new(:head, "ALSO ACCEPTED", "")
        live.each do |from, to|
          rows << Row.new(:item, "#{from}:", "= #{to}:")
        end
      end

      rows << Row.new(:gap, "", "")
      rows << Row.new(:head, "WORTH KNOWING", "")
      QL::CAVEATS.each { |(what, why)| rows << Row.new(:item, what, why) }
      rows
    end

    # --- the "About" sub-tab page ---------------------------------------------
    # Static centered brand block: same art as the project picker, plus version,
    # author credit, and the repository URL (Links page removed — everything lives here).
    ART_GAP = 1 # blank row between the art and the wordmark (mirrors ProjectPicker)

    def render_about(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      # Text stack under the art: wordmark · version · blank · byline · github
      text_h = 5
      show_art = rect.h >= Brand::ART_H + ART_GAP + text_h + 1 && rect.w >= Brand::ART_MIN_W + 6
      block_h = show_art ? Brand::ART_H + ART_GAP + text_h : text_h
      top = rect.y + {(rect.h - block_h) // 2, 0}.max

      if show_art
        Brand.draw_art(screen, Brand.art_origin_x(rect.x, rect.w), top)
        top += Brand::ART_H + ART_GAP
      end

      centered(screen, rect, top, "gori", Theme.focus_gold, attr: Attribute::Bold)
      centered(screen, rect, top + 1, "v#{Gori::VERSION}", Theme.text_bright)
      centered(screen, rect, top + 3, Brand::BYLINE, Theme.muted) if top + 3 < rect.bottom
      centered(screen, rect, top + 4, Gori::REPOSITORY_URL, Theme.muted) if top + 4 < rect.bottom
    end

    # Horizontally center `text` on row `y` within `rect` (mirrors ProjectPicker).
    private def centered(screen : Screen, rect : Rect, y : Int32, text : String, fg : Color,
                         attr : Attribute = Attribute::None) : Nil
      x = rect.x + {(rect.w - Screen.draw_width(text)) // 2, 0}.max
      screen.text(x, y, text, fg, Theme.bg, attr: attr)
    end
  end
end
