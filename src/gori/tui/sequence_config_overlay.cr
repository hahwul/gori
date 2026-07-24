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

    KIND_ROW     = 0
    SELECTOR_ROW = 1
    GOAL_ROW     = 2
    CONC_ROW     = 3
    NOTIFY_ROW   = 4
    START_ROW    = 5
    ROW_COUNT    = 6

    getter seed : SequenceSeed

    def initialize(@seed : SequenceSeed)
      loc = @seed.suggested_loc
      @kind_idx = loc ? (KINDS.index(loc.kind) || 0) : 0
      init = loc ? (loc.kind.position? ? "#{loc.pos_start}:#{loc.pos_end}" : loc.selector) : ""
      @selector = TextField.new(init)
      @goal_idx = GOAL_CHOICES.index(500) || 2
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
    def key : Symbol
      :sequence_config
    end

    def title : String
      "SEQUENCER"
    end

    def hint : String
      "↑/↓ field · type to edit selector · ←/→ cycle · ↵ start · esc cancel"
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
      when CONC_ROW   then @conc_idx = (@conc_idx + d) % CONC_CHOICES.size
      when NOTIFY_ROW then @notify_idx = (@notify_idx + d) % NOTIFY_CHOICES.size
      end
    end

    # Space/Enter on a cycler advances it; on the kind row it also re-prefills.
    def toggle_or_advance : Nil
      adjust(1) if @selected == KIND_ROW || @selected == GOAL_ROW || @selected == CONC_ROW || @selected == NOTIFY_ROW
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

    def valid? : Bool
      return true if kind.position? && !@selector.blank?
      !@selector.blank?
    end

    def build_config : Sequencer::Config
      c = Sequencer::Config.new
      c.mode = @seed.mode
      sel = @selector.value.strip
      c.token_loc = if kind.position?
                      a, _, b = sel.partition(':')
                      Sequencer::TokenLoc.new(kind, "", a.to_i? || 0, b.to_i? || 0)
                    else
                      Sequencer::TokenLoc.new(kind, sel)
                    end
      c.goal = GOAL_CHOICES[@goal_idx]
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
        screen.text(x, py, "token type:", Theme.muted, bg)
        screen.text(vx, py, "#{kind.label}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      when SELECTOR_ROW
        screen.text(x, py, selector_label, Theme.muted, bg)
        @selector.render(screen, vx, py, vw, sel, sel ? Theme.text_bright : Theme.text, bg)
      when GOAL_ROW
        screen.text(x, py, "samples:", Theme.muted, bg)
        screen.text(vx, py, "#{GOAL_CHOICES[@goal_idx]}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      when CONC_ROW
        screen.text(x, py, "concurrency:", Theme.muted, bg)
        screen.text(vx, py, "#{CONC_CHOICES[@conc_idx]}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      when NOTIFY_ROW
        screen.text(x, py, "notify:", Theme.muted, bg)
        screen.text(vx, py, "#{NOTIFY_CHOICES[@notify_idx].label}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      else
        label = valid? ? "[ Start collecting ]" : "[ set a token location ]"
        screen.text(x, py, label, valid? ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 3)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
