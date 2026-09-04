require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../sequencer"

module Gori::Tui
  # Everything needed to start a live-replay sequencing session, captured from
  # History/Repeater when the user picks "Send to Sequencer". `suggested_loc` +
  # `candidate_cookies`/`candidate_headers` come from Sequencer::Extract over the flow's
  # captured response, so the overlay lands pre-filled with the likely token location.
  record SequenceSeed,
    target : String,
    request : Bytes,
    http2 : Bool,
    sni : String?,
    flow_id : Int64?,
    summary : String,
    mode : Sequencer::Mode,
    suggested_loc : Sequencer::TokenLoc?,
    candidate_cookies : Array(String),
    candidate_headers : Array(String)

  # The config popup shown before a live collection: a token-descriptor kind cycler + an
  # editable selector field, then goal / concurrency / notification cyclers and a Start
  # row. The selector is the one text field (a mistyped cookie name is the #1 failure
  # mode); everything else cycles with ←/→. On Start the commit closure reads build_config
  # + seed.
  #
  # Migrated onto the polymorphic Overlay seam (see overlay.cr). It opens from TWO sites
  # with different apply semantics — a NEW session (open_sequence_config) and a
  # RECONFIGURE of the current one (reconfigure_sequence). Each site injects its own
  # `on_commit` closure, so the old `@sequence_reconfigure` shell flag is gone: the
  # overlay only reports :commit and the closure decides what "Start" means.
  class SequenceConfigOverlay < Overlay
    KINDS          = Sequencer::ExtractKind.values
    GOAL_CHOICES   = [100, 250, 500, 1000, 2000, 5000]
    CONC_CHOICES   = [1, 2, 5, 10]
    NOTIFY_CHOICES = Sequencer::NotifyMode.values

    # Hard ceiling on REQUESTS the run may put on the target (retries and redirect hops
    # each charge it — `Fuzz::CappedBackend`, the same counter `--max-requests` and MCP's
    # `max_requests` are enforced against). nil = uncapped, which is what every TUI run
    # used to be: there was no way to cap one from the primary surface at all, while
    # `gori run` and MCP both had the knob. A cycler, not a text field, because this
    # overlay deliberately has none (no IME plumbing).
    MAX_REQ_CHOICES = [nil, 100, 250, 500, 1000, 2500, 5000, 10000] of Int32?

    KIND_ROW     = 0
    SELECTOR_ROW = 1
    GOAL_ROW     = 2
    MAXREQ_ROW   = 3
    CONC_ROW     = 4
    NOTIFY_ROW   = 5
    START_ROW    = 6
    ROW_COUNT    = 7

    getter seed : SequenceSeed

    def initialize(@seed : SequenceSeed)
      loc = @seed.suggested_loc
      @kind_idx = loc ? (KINDS.index(loc.kind) || 0) : 0
      init = loc ? (loc.kind.position? ? "#{loc.pos_start}:#{loc.pos_end}" : loc.selector) : ""
      @selector = TextField.new(init)
      @goal_idx = GOAL_CHOICES.index(500) || 2
      @maxreq_idx = 0
      @conc_idx = 0
      @notify_idx = NOTIFY_CHOICES.index(Sequencer::NotifyMode::WhenDone) || 0
      @selected = SELECTOR_ROW
    end

    def kind : Sequencer::ExtractKind
      KINDS[@kind_idx]
    end

    def on_start_row? : Bool
      @selected == START_ROW
    end

    def editing_selector? : Bool
      @selected == SELECTOR_ROW
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, ROW_COUNT - 1)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, ROW_COUNT - 1)
    end

    def handle_text_key(ev : Termisu::Event::Key) : Bool
      @selector.handle_edit_key(ev)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::SequenceConfig
    end

    def title : String
      "SEQUENCER"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      [@selector]
    end

    def hint : String
      "↑/↓ field · type to edit selector · ←/→ options · ↵ start · esc cancel"
    end

    # Own key handling (formerly Runner#handle_sequence_config_key). ↑/↓ move fields; the
    # selector row eats printable/caret/backspace (incl. ←/→ as caret motion) before the
    # cyclers see them; ↵ on Start commits, elsewhere advances the cycler; esc cancels.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.up?
        move(-1)
        return :stay
      end
      if key.down?
        move(1)
        return :stay
      end
      if key.enter?
        return :commit if on_start_row?
        toggle_or_advance
        return :stay
      end
      return :stay if editing_selector? && handle_text_key(ev)
      if key.left?
        adjust(-1)
      elsif key.right?
        adjust(1)
      elsif key.space?
        toggle_or_advance
      end
      :stay
    end

    # Click a row to select it; a click on Start commits; a click outside the card cancels.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_start_row?
      end
      # …then the caret, if the press landed inside a drawn field. The row pick above is
      # what focuses; this is what puts the caret where the operator pointed instead of
      # leaving it wherever the last keystroke did (Overlay#click_text_field).
      click_text_field(mx, my)
      :stay
    end

    # Live IME composition for the selector text field (only meaningful on that row) — a
    # mistyped cookie/header name is the #1 failure mode, so show composition as it builds.
    def set_preedit(text : String) : Nil
      @selector.set_preedit(text) if editing_selector?
    end

    def adjust(d : Int32) : Nil
      case @selected
      when KIND_ROW
        @kind_idx = (@kind_idx + d) % KINDS.size
        prefill_for_kind
      when GOAL_ROW   then @goal_idx = (@goal_idx + d) % GOAL_CHOICES.size
      when MAXREQ_ROW then @maxreq_idx = (@maxreq_idx + d) % MAX_REQ_CHOICES.size
      when CONC_ROW   then @conc_idx = (@conc_idx + d) % CONC_CHOICES.size
      when NOTIFY_ROW then @notify_idx = (@notify_idx + d) % NOTIFY_CHOICES.size
      end
    end

    # Space/Enter on a cycler advances it; on the kind row it also re-prefills.
    def toggle_or_advance : Nil
      adjust(1) if @selected == KIND_ROW || @selected == GOAL_ROW || @selected == MAXREQ_ROW ||
                   @selected == CONC_ROW || @selected == NOTIFY_ROW
    end

    # When the kind flips to Cookie/Header and the field is blank, offer the first
    # detected candidate so the common case needs no typing.
    private def prefill_for_kind : Nil
      return unless @selector.blank?
      case kind
      when .cookie? then @seed.candidate_cookies.first?.try { |c| @selector.set(c) }
      when .header? then @seed.candidate_headers.first?.try { |h| @selector.set(h) }
      end
    end

    # The Position kind's `A:B` byte range, or nil when the field does not spell one.
    #
    # `a.to_i? || 0` silently turned every unparseable entry into the range `0:0`, and
    # `TokenExtract.position` answers nil whenever `hi <= lo` — so a forgotten `:B` (`100`),
    # a reversed pair, or a typo started a REAL collection in which every one of the samples
    # missed, and the report read "0 usable · CRITICAL (no usable tokens)": a verdict about
    # the origin's entropy, produced by a descriptor that never looked at a byte of it.
    # `gori run sequence --position` and MCP's `position` both refuse the same string; the
    # Sequencer tab was the surface that ran it.
    private def position_range : {Int32, Int32}?
      a, sep, b = @selector.value.strip.partition(':')
      return nil if sep.empty?
      lo = a.strip.to_i?
      hi = b.strip.to_i?
      return nil unless lo && hi && hi > lo
      {lo, hi}
    end

    def valid? : Bool
      return !position_range.nil? if kind.position?
      !@selector.blank?
    end

    # What Start refuses on, in the current kind's own words — a Position range typo is not a
    # missing token location, and being told it is sends the operator to the wrong row.
    # `commit_sequence` toasts this; the Start row draws the short form (`start_label`).
    def invalid_hint : String
      kind.position? ? "set a byte range as A:B (B greater than A)" : "set a token location first"
    end

    # The Start row's own text. Short on purpose: this card is as narrow as 34 columns
    # (`overlay_box`), and the row is drawn from `box.x + 3`.
    private def start_label : String
      return "[ Start collecting ]" if valid?
      kind.position? ? "[ set a byte range A:B ]" : "[ set a token location ]"
    end

    def build_config : Sequencer::Config
      c = Sequencer::Config.new
      c.mode = @seed.mode
      sel = @selector.value.strip
      c.token_loc = if kind.position?
                      # `commit_sequence` gates on `valid?`, so the fallback is unreachable
                      # from Start; it keeps this method total for any other caller.
                      lo, hi = position_range || {0, 0}
                      Sequencer::TokenLoc.new(kind, "", lo, hi)
                    else
                      Sequencer::TokenLoc.new(kind, sel)
                    end
      c.goal = GOAL_CHOICES[@goal_idx]
      c.max_requests = MAX_REQ_CHOICES[@maxreq_idx].try(&.to_i64)
      c.concurrency = CONC_CHOICES[@conc_idx]
      c.notify = NOTIFY_CHOICES[@notify_idx]
      c
    end

    private def selector_label : String
      case kind
      when .cookie?   then "cookie name:"
      when .header?   then "header:"
      when .regex?    then "regex (g1):"
      when .position? then "range a:b:"
      else                 "json path:"
      end
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 58}.min
      h = {area.h - 2, ROW_COUNT + 5}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "config needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "SEND TO SEQUENCER", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, @seed.summary, Theme.text_bright, Theme.panel, Attribute::Bold, width: box.w - 4)
      first = box.y + 3
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom
        draw_row(screen, box, i, py)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      vx = x + 15
      vw = {box.right - 2 - vx, 4}.max
      case i
      when KIND_ROW
        Frame.option_cycle(screen, x, py, box.right - 2, bg,
          "token type:", KINDS.map(&.label), @kind_idx, sel, value_x: vx)
      when SELECTOR_ROW
        screen.text(x, py, selector_label, Theme.muted, bg)
        @selector.render(screen, vx, py, vw, sel, sel ? Theme.text_bright : Theme.text, bg)
      when START_ROW
        # `width:` because a label drawn past `box.right` paints over the frame's hairline
        # and nothing repaints it — the floor-without-a-ceiling shape #912 closed in three
        # lists. Every other row on this card already measures the room it has.
        screen.text(x, py, start_label, valid? ? Theme.accent : Theme.muted, bg,
          Attribute::Bold, width: box.right - 2 - x)
      else
        draw_cycler(screen, x, vx, py, box.right - 2, bg, sel, i)
      end
    end

    # The four ←/→-cycled rows, split out of draw_row so adding a knob does not keep
    # growing one branch chain. `value_x` keeps them on this form's shared value column, which
    # the selector row above them also uses; the strip-or-lit-value decision belongs to
    # `Frame.option_cycle` and is made by measuring the room left to `right`.
    private def draw_cycler(screen : Screen, x : Int32, vx : Int32, py : Int32, right : Int32,
                            bg : Color, sel : Bool, i : Int32) : Nil
      label, options, idx =
        case i
        when GOAL_ROW   then {"samples:", GOAL_CHOICES.map(&.to_s), @goal_idx}
        when MAXREQ_ROW then {"max requests:", MAX_REQ_CHOICES.map { |c| c.try(&.to_s) || "uncapped" }, @maxreq_idx}
        when CONC_ROW   then {"concurrency:", CONC_CHOICES.map(&.to_s), @conc_idx}
        else                 {"notify:", NOTIFY_CHOICES.map(&.label), @notify_idx}
        end
      Frame.option_cycle(screen, x, py, right, bg, label, options, idx, sel, value_x: vx)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 3)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
