require "./screen"
require "./theme"
require "./brand"
require "../hotkeys"
require "../ql"

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

    # `verb_id` non-nil ⇒ resolve the key label from the effective keymap at build time.
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
        Item.new("Settings: Hotkeys", "rebind any shortcut below (^P → Settings: Hotkeys)"),
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
        Item.new("i", "toggle intercept hold-mode", "intercept.toggle"),
        Item.new("detail", "↑/↓ move · x line · ⇧arrows select · y copy · space cmds"),
        Item.new("^X · b · p", "in detail: hex · whitespace · pretty bodies"),
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
        Item.new("^A · ^K · ^T", "auto-mark params · mark word · mark point (manual §)", "repeater.auto-mark"),
        Item.new("space → c", "clear every § marker", "repeater.clear-marks"),
        # ^Q, not ^Y — ^Y is Copy in every text box now (see the `y · ^Y` row above). The key
        # column resolves from the verb id, so it follows a rebind either way.
        Item.new("^Q", "edit the decoder chain on the marker at the cursor", "repeater.attach-chain"),
        Item.new("^X", "hex-edit the request", "repeater.toggle-hex"),
        Item.new("^S", "SNI override (on the target)", "repeater.toggle-sni"),
        Item.new("^L", "toggle auto Content-Length", "repeater.toggle-auto-content-length"),
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
        # types a `y` over it. No verb id — see the JWT row for why the key column would
        # otherwise drop the `^Y` this row exists to name.
        Item.new("y · ^Y", "copy selection/pane — `y` in READ, ^Y in INS too"),
        Item.new("⇧arrows", "select text (line or char)"),
        Item.new("^A · ^K · ^T", "auto-mark params · mark word · mark point (manual §)"),
        # NOT `^U clear §` — that was wrong twice over: ^U is fuzz.pretty-template (the tab's
        # own ` ^U:PRETTY ` badge says so), and clear-marks has no chord at all. The advertised
        # key silently reflowed the template you had just finished marking by hand.
        Item.new("^U", "pretty-print the template body (space → c clears §)"),
        Item.new("^V", "toggle transport HTTP/1.1 ↔ HTTP/2"),
        Item.new("^S", "SNI override (on the target)", "fuzz.toggle-sni"),
        Item.new("^O", "focus the config pane (payload sets · Mode · Advanced · Run)"),
        Item.new("config", "↑/↓ rows · ↵ edit a set / Add / Advanced / Run · ←/→ Mode · Del remove a set"),
        Item.new("^L", "add a List payload set (one value per line, paste splits)"),
        Item.new("set editor", "↹/↑↓ fields · List = multi-line · wordlist path auto-completes · esc applies"),
        Item.new("^R · ^X", "run · stop"),
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
        Item.new("^R · ^X", "mine · stop", "mine.run"),
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
        # NO verb id, unlike the Repeater's row and matching DECODER's `INPUT INS` below:
        # `build_rows` REPLACES the key column with `binding_label`, which answers the PRIMARY
        # chord — so passing `jwt.copy` would print a bare `y` next to a description whose whole
        # point is that `y` types a `y` on three of these panes. Nothing is lost by the literal:
        # a two-chord verb is not rebindable (`Hotkeys.rebindable?` is single-chord only), so
        # there is no override for the column to follow.
        Item.new("y · ^Y", "copy selection/pane — `y` in READ, ^Y while typing (ENCODE panes: ^Y only)"),
        Item.new("⇧arrows", "select text in INPUT / HEADER / PAYLOAD (not SECRET — single-line field)"),
        Item.new("↑/↓ · ↵", "attacks: select · copy the selected payload"),
        Item.new("^N / ^W", "new / close a sub-tab"),
      ]},
      {"OAST", [
        Item.new("^R · ^X", "start listening · stop", "oast.listen"),
        Item.new("↑/↓ · ↵", "callbacks: select · open detail"),
        Item.new("space → p", "promote a callback to an Issue", "oast.promote"),
        Item.new("space → a", "add a provider · e edit · x enable/disable"),
        Item.new("payload", "insert an OAST payload into the focused editor (space → O)", "oast.insert-payload"),
      ]},
      {"SEQUENCER", [
        Item.new("Send to Sequencer", "from History/Repeater/Sitemap (space menu) — replay + analyze a token"),
        Item.new("Send selection to → Sequencer", "selected text becomes manual token sample(s)"),
        Item.new("c", "configure the token location (cookie/header/regex/position/jsonpath) + goal", "sequence.configure"),
        Item.new("^R · ^X", "run collection · stop", "sequence.run"),
        Item.new("↹", "cycle config → samples → analysis"),
        Item.new("↑/↓ · ↵", "samples: select · open detail"),
        Item.new("^W · r", "close · rename the sub-tab (on the strip)"),
      ]},
      {"COMPARER", [
        Item.new("a · b", "pick flow A · flow B"),
        Item.new("←/→", "compare requests ⟷ responses"),
        Item.new("⇧←/→", "h-scroll both columns (long lines)"),
        Item.new("s", "swap A ⇄ B"),
        Item.new("^N / ^W · r", "new / close / rename comparison sub-tab"),
        Item.new("Send to Comparer", "from History (space menu) — fills the active sub-tab"),
      ]},
      {"EDITORS", [
        Item.new("^G · ^F", "go to line · find (↵/↑↓ step)"),
        Item.new("^F then tab", "find & replace — ↵ swaps every match (one undo step)"),
        Item.new("^E", "open the field in $EDITOR"),
        Item.new("^B", "reveal whitespace"),
      ]},
      {"OTHER TABS", [
        Item.new("Sitemap", "↑/↓ · / filter · ↵/→ expand · t mark · g fold · ⇧S scope · space → T tag"),
        Item.new("Issues", "list: t mark · ⇧T all · ⇧arrows range · notes: i/↵ edit · x line · y copy · space cmds"),
        Item.new("Probe", "↑/↓ ↵ open · m mode · c dismiss · a all · / filter · ⇧S scope · space cmds"),
        Item.new("Notes", "i/↵ edit · x line · ⇧arrows select · y copy · space cmds (Copy selected when highlighted)"),
        Item.new("Project", "←/→ sub-tab (desc · scope · hosts · env · network) · ↓/↵ enter · desc: i/↵ edit · x line · y copy"),
        Item.new("Intercept", "↵/e edit · f fwd · d drop · ⇧F all · c catch · / condition · i on/off"),
      ]},
      {"DECODER", [
        Item.new("i / ↵", "enter INS on INPUT · esc back to READ"),
        Item.new("INPUT READ", "⇧arrows select · y copy · space cmds"),
        Item.new("INPUT INS", "⇧arrows select · ^Y copy (bare y types a `y`)"),
        Item.new("chain", "always editable — base64 > url-encode > sha256 ( > | , )"),
        Item.new("↹ / ↵", "complete the suggested converter (popup)"),
        Item.new("OUTPUT", "↑/↓ move · ⇧arrows select · y copy"),
        Item.new("^X", "cycle text/hex/base64"),
        Item.new("^S · ^O", "save the chain under a name · pick from the saved chains"),
        Item.new("chain library", "shared by every project · picker: type to filter · ^X deletes an entry"),
        Item.new("^N · ^W", "new · close conversion sub-tab"),
        Item.new("^1-9 · r", "switch sub-tab · rename (on the strip)"),
        Item.new("space", "command menu (anywhere in the tab — Save/Load included)"),
      ]},
      {"REWRITER", [
        Item.new("a · ↵/e", "add a Match & Replace rule · edit the selected one"),
        Item.new("x · d", "enable/disable in this project · delete the selected rule"),
        Item.new("s · ⇧X", "move the rule global ⇄ project · flip a global rule's default everywhere"),
        Item.new("G / P column", "global (every project) or project · G* = this project overrides its default"),
        Item.new("⇧J / ⇧K", "reorder within a scope — globals apply first, then project rules"),
        Item.new("[ / ]", "switch sub-tab: rules · extract · bindings"),
        Item.new("↓ past the list", "the editable preview sample, and the same message after the rules run"),
        # NOT "y copies the OUTPUT · ^Y copies the INPUT": `rewriter.copy` is ONE verb with two
        # chords, and `rewriter_copy` branches on the FOCUSED PANE, not on which chord fired —
        # `^Y` on OUTPUT copies the OUTPUT. The real split is mode, not pane: the INPUT sample
        # is always typing, so there `y` is a literal character and `^Y` is the only copy.
        Item.new("preview", "⇧arrows select · y copy (OUTPUT) · ^Y copy while typing (INPUT sample)"),
      ]},
      {"COLORMARKER", [
        Item.new("a · ↵/e", "add a History row-colour rule · edit the selected one"),
        Item.new("x · d", "enable/disable in this project · delete the selected rule"),
        Item.new("s · ⇧X", "move the rule global ⇄ project · flip a global rule's default everywhere"),
        Item.new("⇧J / ⇧K", "reorder — the FIRST enabled match paints the row, the rest are skipped"),
        Item.new("style", "full = tint the whole row · strip = one colour cell ahead of TIME"),
        Item.new("when:", "host: path: method: scheme: status: proto: — ↹ completes · no header:/size:/dur:"),
        Item.new("↹ · ↓ past list", "CUSTOM COLORS pane — a add · ↵/e edit · d delete (name + #hex)"),
        Item.new("custom colour", "a global name the picker offers everywhere; its hex is absolute, not theme-relative"),
        Item.new("hidden by default", "settings:tabs shows it, next to Rewriter"),
      ]},
      {"OVERLAYS", [
        Item.new("palette / settings", "↑/↓ · ↵ · esc"),
        Item.new("confirm", "←/→ choose · y / n · ↵"),
        Item.new("Settings: Editor", "toggle mouse support (Mouse field)"),
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
    # The six tabs with no section of their own share OTHER TABS, which holds exactly one
    # row each; :help itself is absent so opening from Help lands at the top (the whole
    # sheet is already what that tab shows). A spec pins every Chrome::TABS symbol either
    # here or deliberately out, and pins every title named here against SECTIONS — a typo'd
    # title would otherwise silently degrade to "open at the top".
    TAB_SECTION = {
      :history     => "HISTORY",
      :repeater    => "REPEATER",
      :fuzzer      => "FUZZER",
      :miner       => "MINER",
      :oast        => "OAST",
      :sequencer   => "SEQUENCER",
      :decoder     => "DECODER",
      :jwt         => "JWT",
      :comparer    => "COMPARER",
      :rewriter    => "REWRITER",
      :colormarker => "COLORMARKER",
      :target      => "OTHER TABS",
      :sitemap     => "OTHER TABS",
      :issues      => "OTHER TABS",
      :probe       => "OTHER TABS",
      :notes       => "OTHER TABS",
      :project     => "OTHER TABS",
      :intercept   => "OTHER TABS",
    }

    @rows : Array(Row)
    @scroll : Int32 = 0

    def initialize(registry : Verb::Registry? = nil)
      @rows = HelpView.shortcut_rows(registry)
    end

    # Rebuild from the live registry (call after a hotkeys save so Help stays honest).
    def reload(registry : Verb::Registry) : Nil
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
          if (id = item.verb_id) && registry
            key = Hotkeys.binding_label(registry, id, item.key)
          end
          # Retag both columns: an item with a verb id already resolves through
          # binding_label, but the keyless rows (^N/^W, ^G/^F, ^1-9) and the chords named
          # inside descriptions are hand-written literals.
          rows << Row.new(:item, Hotkeys.retag(key), Hotkeys.retag(item.desc))
        end
      end
      rows
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
      clamp_scroll(rect.h)
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= @rows.size
        HelpView.draw_row(screen, rect, rect.y + i, @rows[li])
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

    private def clamp_scroll(h : Int32) : Nil
      max = {@rows.size - h, 0}.max
      @scroll = @scroll.clamp(0, max)
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

    def render_query(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      rows = query_rows
      @query_scroll = @query_scroll.clamp(0, {rows.size - rect.h, 0}.max)
      (0...rect.h).each do |i|
        li = @query_scroll + i
        break if li >= rows.size
        HelpView.draw_row(screen, rect, rect.y + i, rows[li], QUERY_KEY_W)
      end
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
      x = rect.x + {(rect.w - text.size) // 2, 0}.max
      screen.text(x, y, text, fg, Theme.bg, attr: attr)
    end
  end
end
