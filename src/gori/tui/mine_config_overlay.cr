require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../miner"
require "../request_macro/spec"
require "../settings"

module Gori::Tui
  # Everything needed to start a mining session, captured from History/Repeater when the
  # user picks "Mine parameters". `applicable`/`default` come from Miner::Detect so the
  # config overlay only offers locations that make sense for THIS request.
  record MineSeed,
    target : String,
    request : Bytes,
    http2 : Bool,
    sni : String?,
    flow_id : Int64?,
    summary : String,
    applicable : Array(Miner::Location),
    default : Array(Miner::Location),
    # Names tested FIRST (`Miner::Config#seed_names`) — the parameter inventory's neighbour
    # names (#1231), from the Params sub-tab's scan or, for a History mine, one run for the
    # popup (`land_seed_names`). Not free text, so the no-text-field rule below still holds.
    names : Array(String) = [] of String

  # The small config popup shown before a mine starts: adaptive location checkboxes,
  # concurrency + notification cyclers, and a Start row. No text field (so no IME
  # plumbing). Restores the last confirmed overlay choices from Settings when present.
  # On Start the injected commit closure reads build_config + seed and hands them to the
  # MinerController. Migrated onto the polymorphic Overlay seam (see overlay.cr).
  class MineConfigOverlay < Overlay
    CONC_CHOICES   = [5, 10, 20, 40]
    NOTIFY_CHOICES = Miner::NotifyMode.values

    # Hard ceiling on REQUESTS the run may put on the target (retries and redirect hops
    # each charge it — `Fuzz::CappedBackend`, the same counter `--max-requests` and MCP's
    # `max_requests` are enforced against). nil = uncapped, which is what every TUI run
    # used to be: there was no way to cap one from the primary surface at all, while
    # `gori run` and MCP both had the knob. A cycler, not a text field, because this
    # overlay deliberately has none (no IME plumbing).
    MAX_REQ_CHOICES = [nil, 100, 250, 500, 1000, 2500, 5000, 10000] of Int32?

    # The request-time macro's cadence (#1350), in requests, as `RequestMacro::Cadence` reads it:
    # `request` is a fresh value before EVERY request. A cycler, not the text field the Fuzzer's
    # ADVANCED card uses — this overlay has none — so it offers the numbers worth choosing; any
    # other, and multi-step macros, are `gori run mine --macro-every` / MCP `macro_every`.
    MACRO_EVERY_CHOICES = ["request", "2", "5", "10", "25"]
    MACRO_FAIL_CHOICES  = Gori::RequestMacro::OnFailure.values

    getter seed : MineSeed
    # Additional flows this one config starts a session for — History's multi-select (#442).
    # The CHECKBOXES come from `seed` (the first target), because locations are per-request;
    # the Runner narrows the committed config to each extra seed's own `applicable` set so a
    # body location checked on a POST is simply not mined on a GET.
    getter extra_seeds : Array(MineSeed)

    # True while a History mine's inventory scan is still running: its names land after the
    # popup opens (`land_seed_names`), because the scan reads flows and must not freeze the
    # frame. Start does not wait for it; the Runner says so when it did not finish.
    getter? seeding = false
    @seed_failed = false

    # `macro_sessions` are the project's saved Repeater sessions, `{id, label}` — the choices of
    # the macro step cycler (#1350). The overlay has no text field, so a macro is picked FROM the
    # project rather than typed: one session, by id, so a rename cannot re-point it. Empty for a
    # caller with no project (a spec), and the row then says so.
    def initialize(@seed : MineSeed, @extra_seeds : Array(MineSeed) = [] of MineSeed,
                   @macro_sessions : Array({Int64, String}) = [] of {Int64, String})
      @macro_idx = 0 # 0 = no macro; n = @macro_sessions[n - 1]
      @macro_every_idx = 0
      @macro_fail_idx = 0
      @checked = Hash(Miner::Location, Bool).new
      @seed.applicable.each { |l| @checked[l] = @seed.default.includes?(l) }
      @conc_idx = CONC_CHOICES.index(10) || 1
      @notify_idx = NOTIFY_CHOICES.index(Miner::NotifyMode::WhenFound) || 0
      @maxreq_idx = 0
      @keep_alive = true
      @selected = 0
      restore_saved_prefs
    end

    def begin_seeding : Nil
      @seeding = true
    end

    # Land the inventory scan: each seed's neighbour names, by flow id. nil = the scan failed,
    # and every seed keeps what it had.
    def land_seed_names(by_flow : Hash(Int64, Array(String))?) : Nil
      @seeding = false
      @seed_failed = by_flow.nil?
      return unless by_flow
      @seed = with_names(@seed, by_flow)
      @extra_seeds = @extra_seeds.map { |s| with_names(s, by_flow).as(MineSeed) }
    end

    private def with_names(s : MineSeed, by_flow : Hash(Int64, Array(String))) : MineSeed
      (id = s.flow_id) && (names = by_flow[id]?) ? s.copy_with(names: names) : s
    end

    # Remember the last confirmed overlay for the next History/Repeater mine.
    def save_prefs : Bool
      locs = @seed.applicable.select { |l| @checked[l]? }.map(&.label)
      notify = NOTIFY_CHOICES[@notify_idx].token
      Settings.save_mine_prefs(locs, CONC_CHOICES[@conc_idx], notify, @keep_alive)
    end

    private def restore_saved_prefs : Nil
      return unless Settings.mine_prefs_saved?
      saved = Settings.mine_locations.to_set
      @seed.applicable.each do |loc|
        @checked[loc] = saved.includes?(loc.label)
      end
      if idx = CONC_CHOICES.index(Settings.mine_concurrency)
        @conc_idx = idx
      end
      if mode = Miner::NotifyMode.parse?(Settings.mine_notify)
        @notify_idx = NOTIFY_CHOICES.index(mode) || @notify_idx
      end
      @keep_alive = Settings.mine_keep_alive?
    end

    # Rows: one per applicable location, then max-requests + concurrency + notification
    # cyclers, then the keep-alive checkbox, then the three macro cyclers (#1350), then Start.
    private def row_count : Int32
      @seed.applicable.size + 8
    end

    private def maxreq_row : Int32
      @seed.applicable.size
    end

    private def conc_row : Int32
      @seed.applicable.size + 1
    end

    private def notify_row : Int32
      @seed.applicable.size + 2
    end

    # Reuse one connection across the run's probes — a checkbox rather than a cycler
    # because it is a plain on/off, matching the Discover overlay's own keep-alive row.
    private def keepalive_row : Int32
      @seed.applicable.size + 3
    end

    # The request-time macro's three rows (#1350): which saved Repeater session to replay before
    # each request, how often, and what a failure does. The second and third are inert while no
    # step is picked, and draw as such rather than as knobs that would do nothing.
    private def macro_row : Int32
      @seed.applicable.size + 4
    end

    private def macro_every_row : Int32
      @seed.applicable.size + 5
    end

    private def macro_fail_row : Int32
      @seed.applicable.size + 6
    end

    private def start_row : Int32
      @seed.applicable.size + 7
    end

    # Is a macro step picked? The other two macro rows mean nothing without one.
    private def macro_on? : Bool
      @macro_idx > 0 && !@macro_sessions[@macro_idx - 1]?.nil?
    end

    def on_start_row? : Bool
      @selected == start_row
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::MineConfig
    end

    def title : String
      "MINE PARAMS"
    end

    def hint : String
      "↑/↓ field · ←/→ options · ␣ toggle · ↵ start · esc cancel"
    end

    # Own key handling (formerly Runner#handle_mine_config_key): ↑/↓ move, ←/→ adjust
    # cyclers, ␣/↵ toggle a checkbox or commit on the Start row, esc cancels.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.up?
        move(-1)
      elsif key.down?
        move(1)
      elsif key.left?
        adjust(-1)
      elsif key.right?
        adjust(1)
      elsif key.enter?
        # ↵ starts from any row, as the hint says; it used to share ␣'s arm, so ↵ on a location
        # unchecked it instead of starting (#1373).
        return :commit
      elsif key.space?
        return :commit if on_start_row?
        toggle
      end
      :stay
    end

    # Click a row to select it; a click on Start commits; a click on any other row toggles
    # it (checkbox flip / cycler advance); a click outside the card cancels. Mirrors the
    # prior Runner#click_mine_config exactly.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_start_row?
        toggle
      end
      :stay
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, row_count - 1)
    end

    def adjust(d : Int32) : Nil
      case @selected
      when maxreq_row    then @maxreq_idx = (@maxreq_idx + d) % MAX_REQ_CHOICES.size
      when conc_row      then @conc_idx = (@conc_idx + d) % CONC_CHOICES.size
      when notify_row    then @notify_idx = (@notify_idx + d) % NOTIFY_CHOICES.size
      when keepalive_row then @keep_alive = !@keep_alive
      when macro_row
        @macro_idx = (@macro_idx + d) % (@macro_sessions.size + 1) unless @macro_sessions.empty?
      when macro_every_row then @macro_every_idx = (@macro_every_idx + d) % MACRO_EVERY_CHOICES.size if macro_on?
      when macro_fail_row  then @macro_fail_idx = (@macro_fail_idx + d) % MACRO_FAIL_CHOICES.size if macro_on?
      end
    end

    # Space on a location row flips its checkbox; cyclers advance on space.
    def toggle : Nil
      if @selected < @seed.applicable.size
        loc = @seed.applicable[@selected]
        @checked[loc] = !(@checked[loc]? || false)
      elsif @selected == keepalive_row
        @keep_alive = !@keep_alive
      elsif @selected == maxreq_row || @selected == conc_row || @selected == notify_row ||
            @selected == macro_row || @selected == macro_every_row || @selected == macro_fail_row
        adjust(1)
      end
    end

    def build_config : Miner::Config
      c = Miner::Config.new
      c.locations = @seed.applicable.select { |l| @checked[l]? }
      c.concurrency = CONC_CHOICES[@conc_idx]
      c.notify = NOTIFY_CHOICES[@notify_idx]
      c.max_requests = MAX_REQ_CHOICES[@maxreq_idx].try(&.to_i64)
      c.keep_alive = @keep_alive
      c.seed_names = @seed.names
      c.request_macro = macro_spec
      # `user_wordlist` and `hook` (#846) are NOT set here, on purpose and for the same reason:
      # both are free-text (a filesystem path, an argv command line), and this overlay is
      # deliberately field-free — cyclers and checkboxes only, no text input and no IME
      # plumbing (see the class comment). They are the `gori run mine --wordlist/--hook` and MCP
      # `wordlist`/`hook` knobs, a known and accepted CLI/MCP-only parity gap for the two knobs
      # that cannot be a cycler; a mine started from the TUI leaves both at their defaults.
      c
    end

    # The macro the three rows describe, or nil when no step is picked (every mine that came
    # before). One step, by id: the session a rename cannot re-point. Multiple steps and the
    # `expect` list need the text the field-free overlay cannot take — `gori run mine --macro`.
    private def macro_spec : Gori::RequestMacro::Spec?
      return nil unless macro_on?
      id = @macro_sessions[@macro_idx - 1][0]
      cadence = Gori::RequestMacro::Cadence.parse?(MACRO_EVERY_CHOICES[@macro_every_idx]) || Gori::RequestMacro::Cadence.request
      Gori::RequestMacro::Spec.new([id.to_s], cadence, MACRO_FAIL_CHOICES[@macro_fail_idx])
    end

    def any_checked? : Bool
      @checked.values.includes?(true)
    end

    # How many flows Start will kick off a session for (1 unless batching, #442).
    def target_count : Int32
      1 + @extra_seeds.size
    end

    # The bold line under the title: the seeded request normally, or the flow count when this
    # popup is configuring a marked SET — N individual summaries wouldn't fit, and the count is
    # the thing worth confirming before N background sessions start.
    #
    # It spells out that concurrency is PER SESSION, because this popup is the only gate on the
    # batch (P4 — the human decides, so what they're deciding has to be legible): N sessions at
    # the cycler's value means N × that many requests in flight, and a reader who takes the "10"
    # below as a batch-wide ceiling would be off by a factor of N.
    private def header_summary : String
      return @seed.summary if @extra_seeds.empty?
      "#{target_count} flows · one session each · concurrency is per session"
    end

    # The line under the summary: where the names tested FIRST stand — the inventory scan
    # still running, failed, or what it seeded (per flow, for a batch). nil when nothing was
    # seeded and nothing is pending: a plain wordlist mine.
    def seed_status : String?
      return "seeding names from the parameter inventory…" if seeding?
      return "name seeding failed — the wordlist alone is tested" if @seed_failed
      seeds = [@seed] + @extra_seeds
      if @extra_seeds.empty?
        n = @seed.names.size
        return n.zero? ? nil : "+#{n} seeded name#{n == 1 ? "" : "s"}, tested first"
      end
      k = seeds.count { |s| !s.names.empty? }
      k.zero? ? nil : "seeded names tested first on #{k} of #{seeds.size} flows"
    end

    def overlay_box(area : Rect) : Rect?
      area.card?(54, row_count + 5, 30, 6) # h: title + summary + gap + rows + border
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "config needs a larger window")
        return
      end
      Frame.card(screen, box, "MINE PARAMETERS", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, header_summary, Theme.text_bright, Theme.panel, Attribute::Bold, width: box.w - 4)
      if line = seed_status
        screen.text(box.x + 2, box.y + 2, line, Theme.muted, Theme.panel, width: box.w - 4)
      end
      first = box.y + 3
      row_count.times do |i|
        py = first + i
        break if py >= box.bottom
        draw_row(screen, box, i, py)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @selected
      bg = Frame.row_band(screen, box, py, sel)
      x = box.x + 3
      if i < @seed.applicable.size
        loc = @seed.applicable[i]
        draw_check(screen, x, py, bg, sel, @checked[loc]? || false, "#{loc.label} mining")
      elsif i == keepalive_row
        draw_check(screen, x, py, bg, sel, @keep_alive, "reuse connections (keep-alive)")
      elsif i == start_row
        label = any_checked? ? "[ Start mining ]" : "[ select a location ]"
        screen.text(x, py, label, any_checked? ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      elsif inert_macro_row?(i)
        screen.text(x, py, inert_macro_text(i), Theme.muted, bg, width: box.right - 2 - x)
      else
        draw_cycler(screen, x, py, box.right - 2, bg, sel, i)
      end
    end

    # A macro row that would do nothing right now, and says so: no saved Repeater session to
    # pick from, or no step picked for the cadence / failure rows to modify.
    private def inert_macro_row?(i : Int32) : Bool
      (i == macro_row && @macro_sessions.empty?) ||
        ((i == macro_every_row || i == macro_fail_row) && !macro_on?)
    end

    private def inert_macro_text(i : Int32) : String
      if i == macro_row
        "macro step: no Repeater session in this project"
      elsif i == macro_every_row
        "macro cadence: — (pick a macro step)"
      else
        "macro on failure: — (pick a macro step)"
      end
    end

    # One ␣-toggled checkbox row — the location rows and the keep-alive row are the same
    # widget, so they draw through the same three lines rather than two copies of them.
    private def draw_check(screen : Screen, x : Int32, py : Int32, bg : Color,
                           sel : Bool, on : Bool, label : String) : Nil
      screen.text(x, py, on ? "[x]" : "[ ]", on ? Theme.green : Theme.muted, bg)
      screen.text(x + 4, py, label, sel ? Theme.text_bright : Theme.text, bg)
    end

    # The three ←/→-cycled rows, split out of draw_row so adding a knob does not keep
    # growing one branch chain.
    #
    # Through `Frame.option_cycle` like every other cycler in gori: the choices are drawn as a
    # strip when the card is wide enough to hold one, and fall back to the lit value when it is
    # not. That fallback is why this row used to be hand-rolled — `MAX_REQ_CHOICES` is eight
    # numbers plus `uncapped` and does not always fit — but the helper decides that by
    # measuring rather than by which file it lives in.
    private def draw_cycler(screen : Screen, x : Int32, py : Int32, right : Int32, bg : Color,
                            sel : Bool, i : Int32) : Nil
      label, options, idx =
        if i == maxreq_row
          {"max requests:", MAX_REQ_CHOICES.map { |c| c.try(&.to_s) || "uncapped" }, @maxreq_idx}
        elsif i == conc_row
          {"concurrency:", CONC_CHOICES.map(&.to_s), @conc_idx}
        elsif i == macro_row
          {"macro step:", ["off"] + @macro_sessions.map(&.[1]), @macro_idx}
        elsif i == macro_every_row
          {"macro cadence:", MACRO_EVERY_CHOICES, @macro_every_idx}
        elsif i == macro_fail_row
          {"macro on failure:", MACRO_FAIL_CHOICES.map(&.token), @macro_fail_idx}
        else
          {"notification:", NOTIFY_CHOICES.map(&.label), @notify_idx}
        end
      Frame.option_cycle(screen, x, py, right, bg, label, options, idx, sel)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 3)
      (0 <= i < row_count) ? i : nil
    end
  end
end
