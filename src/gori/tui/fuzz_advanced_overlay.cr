require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_field"
require "./viewport"

module Gori::Tui
  # A flat snapshot of the Fuzzer's advanced knobs, moved between FuzzerView (which
  # keeps them as @s_* string buffers + @config/@matcher) and FuzzAdvancedOverlay
  # (which edits them). Text fields carry "" for blank; regexes are kept as source
  # strings (compiled by the view's commit_buffers at build/persist time, unchanged).
  record AdvancedSnapshot,
    conc : String, rate : String, timeout : String, retries : String,
    max_requests : String, race : String,
    follow : Bool, calibrate : Bool, keep_alive : Bool, update_cl : Bool,
    reframe_grpc : Bool,
    m_status : String, m_size : String, m_words : String, m_regex : String,
    f_status : String, f_size : String, f_words : String, f_regex : String,
    # Comma-separated schema-known gRPC field specs (`Fuzz::PlanOptions#grpc_fields`).
    # DEFAULTED, so every construction site that predates it keeps compiling — and, more to the
    # point, so a caller that does not know about gRPC cannot accidentally clear it.
    grpc_fields : String = "",
    # The run's TLS fingerprint override (#844) — a `Settings::TLS_PRESETS` name, "" for none.
    # DEFAULTED for the same reason `grpc_fields` is: every construction site that predates it
    # keeps compiling, and a caller that does not know about it cannot silently clear it.
    tls_preset : String = "",
    # Round-trip time in ms (`Fuzz::Matcher#match_time`). DEFAULTED for the reason the two
    # above it are: every construction site that predates it keeps compiling, and a caller
    # that does not know about it cannot silently clear it.
    m_time : String = "",
    f_time : String = ""

  # The full-area popup for the Fuzzer's advanced run settings. Every engine / match
  # / filter knob gets its OWN labeled row (no more horizontal fields walked by ↑/↓,
  # no more ←/→-cycle-vs-caret overload): ↑/↓/⇥ move rows, ←/→ moves the caret on a
  # text row or flips a toggle row, esc applies + closes. Modeled on the same row
  # idiom as MineConfigOverlay/FuzzSetOverlay, and like them it rides the polymorphic
  # Overlay seam (see overlay.cr) — where "apply" IS :commit, so there is no cancel:
  # esc and click-away both write the snapshot back through the injected closure.
  class FuzzAdvancedOverlay < Overlay
    # {field key, label, kind(:text|:toggle)} in display order.
    ROWS = [
      {:conc, "Concurrency", :text},
      {:rate, "Rate (rps)", :text},
      {:timeout, "Timeout (s)", :text},
      {:retries, "Retries", :text},
      # The TRUE wire count is what this caps (retries + redirect hops each charge it) —
      # `Fuzz::CappedBackend`, the same counter `--max-requests` and MCP's `max_requests`
      # are enforced against. Blank = no cap, which is what every TUI run used to be.
      {:max_requests, "Max requests", :text},
      {:follow, "Follow redirects", :toggle},
      {:calibrate, "Auto-calibrate", :toggle},
      {:keep_alive, "Keep-alive", :toggle},
      # The Repeater's ^L / `--verbatim` and Intercept's `update_content_length:false` by
      # the same name and for the same reason: a CL / CL-TE desync template IS the payload,
      # and recomputing its Content-Length sweeps a different request than the one written.
      # ON is the old (and right) default for an ordinary sweep whose payload changed the
      # body length; OFF sends the header exactly as the template declares it.
      #
      # ON also ADDS the header to a body that declares none, which is what makes this the
      # Repeater's ^L rather than half of it (`Fuzz::Config#add_content_length_when_missing`).
      # OFF therefore leaves such a body UNFRAMED, and an origin reads it as zero-length —
      # `Plan#unframed_body?` is what says so on the run-start line instead of letting it go
      # quiet.
      {:update_cl, "Auto Content-Length", :toggle},
      # The SECOND length declaration a gRPC request carries — the 5-byte prefix in front of
      # the message — and deliberately the OPPOSITE default to the row above it (DESIGN.md §7,
      # the gRPC reframe entry): Content-Length is recomputed unless told not to, the gRPC
      # prefix is left as the payload left it unless told to. ON recomputes it per request, so
      # a sweep whose payload changed the message length is not rejected at the framing layer.
      # `Fuzz::Config#reframe_grpc?` — the same knob `gori run fuzz --reframe-grpc` and MCP
      # `reframe_grpc:` set, and the same engine (`Generator#emit`) applies it.
      #
      # (unary) is in the LABEL because the refusals are not visible anywhere else on this
      # card: `GrpcVerdict.reframable_template?` declines a non-gRPC template, a seed whose
      # framing is ALREADY broken (that mis-framing is the operator's own test), and
      # grpc-web-text; `Grpc.reframe` then declines a client-streaming body and a body that
      # frames end-to-end. ON over any of those is a no-op, not a rewrite.
      {:reframe_grpc, "gRPC reframe (unary)", :toggle},
      {:m_status, "Match status", :text},
      {:m_size, "Match size", :text},
      {:m_words, "Match words", :text},
      {:m_regex, "Match regex", :text},
      {:f_status, "Filter status", :text},
      {:f_size, "Filter size", :text},
      {:f_words, "Filter words", :text},
      {:f_regex, "Filter regex", :text},
      # Appended LAST, deliberately: the rows above are referenced by hardcoded index in
      # spec/tui/fuzz_advanced_overlay_spec.cr, and this is the one position that shifts none
      # of them. (`gRPC reframe` DID shift them — it belongs beside the other length-declaration
      # toggle, not at the bottom next to a connection count — so that spec moved with it.)
      # Race condition (last-byte-sync): N dedicated connections holding back
      # the final byte, released together — bypasses Mode/payload sets entirely (see
      # Fuzz::Config#race_count). Blank = off. A warm-up request is CLI/MCP-only for this phase.
      {:race, "Race (N conns)", :text},
      # Schema-known gRPC field positions (`gori run fuzz --field`, MCP `fields`). A NAME, not
      # a marker: the wire encoding of a value is not something `§…§` can usefully wrap. Blank
      # = none, which is every sweep that came before. Appended after Race for the same reason
      # Race was appended after the matchers: it renumbers no row a spec reaches by index. Two
      # examples still moved with it — the ones pinning WHICH row is last and the arithmetic of
      # a click on a scrolled list — because those are facts about the table's end, not about a
      # row's number. The field NAMES for a flow are the ones the Repeater's ␣E:FIELDS form and
      # the History protobuf tree already show for it, so this row is typed, not browsed.
      {:grpc_fields, "gRPC field(s)", :text},
      # The run's TLS fingerprint (#844) — the same knob `gori run fuzz --tls-preset` and MCP
      # `fuzz_start{tls_preset}` set. Blank = none, i.e. the destination's own outbound_tls
      # policy, which is what every sweep did before. A NAME (chrome / firefox / safari /
      # curl), typed rather than cycled because this row is a text row like its neighbours; an
      # unknown one is refused by `Fuzz::Plan.build` when the run starts, and the tab reports
      # it — never applied-as-nothing, which would sweep with gori's bare hello under a
      # heading naming a browser.
      #
      # RUN-level, not per request: keep-alive parks a socket whose handshake is already done.
      # Appended LAST for the reason the two rows above it were — it renumbers no row a spec
      # reaches by index.
      {:tls_preset, "TLS fingerprint", :text},
      # The TIME dimension — `gori run fuzz --mt/--ft`, MCP `match:{time:…}`. Milliseconds,
      # because that is what an operator types for a `SLEEP(5)` sweep (`>=4500`), and because
      # a time-based blind payload is the one class whose entire signal is this row: status,
      # size and body come back identical whether the sleep fired or not.
      #
      # Appended LAST for the reason Race, gRPC field(s) and TLS fingerprint were: the rows
      # above are reached by hardcoded index in spec/tui/fuzz_advanced_overlay_spec.cr, and
      # this is the one position that renumbers none of them.
      {:m_time, "Match time (ms)", :text},
      {:f_time, "Filter time (ms)", :text},
    ]
    LABEL_W = 22 # value column offset (widest label "gRPC reframe (unary)" + padding)

    def initialize(snap : AdvancedSnapshot)
      @sel = 0
      @scroll = 0
      @follow = snap.follow
      @calibrate = snap.calibrate
      @keep_alive = snap.keep_alive
      @update_cl = snap.update_cl
      @reframe_grpc = snap.reframe_grpc
      @fields = {
        :conc         => TextField.new(snap.conc),
        :rate         => TextField.new(snap.rate),
        :timeout      => TextField.new(snap.timeout),
        :retries      => TextField.new(snap.retries),
        :max_requests => TextField.new(snap.max_requests),
        :race         => TextField.new(snap.race),
        :m_status     => TextField.new(snap.m_status),
        :m_size       => TextField.new(snap.m_size),
        :m_words      => TextField.new(snap.m_words),
        :m_regex      => TextField.new(snap.m_regex),
        :f_status     => TextField.new(snap.f_status),
        :f_size       => TextField.new(snap.f_size),
        :f_words      => TextField.new(snap.f_words),
        :f_regex      => TextField.new(snap.f_regex),
        :grpc_fields  => TextField.new(snap.grpc_fields),
        :tls_preset   => TextField.new(snap.tls_preset),
        :m_time       => TextField.new(snap.m_time),
        :f_time       => TextField.new(snap.f_time),
      }
    end

    private def current : {Symbol, String, Symbol}
      ROWS[@sel]
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::FuzzAdvanced
    end

    def title : String
      "ADVANCED"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      @fields.values.to_a # NamedTuple on some cards, Hash on others — one shape out
    end

    def hint : String
      "↑/↓/⇥ field · ←/→ edit · ␣ toggle · ↵ next · esc applies & closes"
    end

    # --- input --------------------------------------------------------------
    # PRE-EXISTING (kept as-is by the Overlay migration, which is behaviour-preserving):
    # the `case` value is discarded, so handle_text's commit-on-the-last-row never reaches
    # the shell — ↵ there is a no-op, not an apply. Only esc and a click-away apply. The
    # rendered hint already says "esc applies" and does not promise ↵, so this is a lost
    # convenience rather than a broken advertised key; fixing it is a behaviour change and
    # belongs in its own patch.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :commit if key.escape?
      case
      when key.tab?, key.down?    then @sel = (@sel + 1).clamp(0, ROWS.size - 1)
      when key.back_tab?, key.up? then @sel = (@sel - 1).clamp(0, ROWS.size - 1)
      else
        current[2] == :toggle ? handle_toggle(key) : handle_text(ev)
      end
      :stay
    end

    private def handle_toggle(key : Termisu::Input::Key) : Symbol
      case
      when key.left?, key.right?, key.enter?, key.space? then toggle_current
      end
      :stay
    end

    private def handle_text(ev : Termisu::Event::Key) : Symbol
      if ev.key.enter?
        # handle_key drops this :commit (see the note there), but the early return is still
        # load-bearing: without it @sel would step past the last row and `current` would
        # index ROWS out of range.
        return :commit if @sel == ROWS.size - 1
        @sel += 1
      else
        @fields[current[0]].handle_edit_key(ev)
      end
      :stay
    end

    private def toggle_current : Nil
      case current[0]
      when :follow       then @follow = !@follow
      when :calibrate    then @calibrate = !@calibrate
      when :keep_alive   then @keep_alive = !@keep_alive
      when :update_cl    then @update_cl = !@update_cl
      when :reframe_grpc then @reframe_grpc = !@reframe_grpc
      end
    end

    def set_preedit(text : String) : Nil
      row = current
      @fields[row[0]]?.try(&.set_preedit(text)) if row[2] == :text
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROWS.size - 1)
    end

    # --- result -------------------------------------------------------------
    def snapshot : AdvancedSnapshot
      AdvancedSnapshot.new(
        conc: @fields[:conc].value, rate: @fields[:rate].value,
        timeout: @fields[:timeout].value, retries: @fields[:retries].value,
        max_requests: @fields[:max_requests].value, race: @fields[:race].value,
        follow: @follow, calibrate: @calibrate, keep_alive: @keep_alive,
        update_cl: @update_cl, reframe_grpc: @reframe_grpc,
        m_status: @fields[:m_status].value, m_size: @fields[:m_size].value,
        m_words: @fields[:m_words].value, m_regex: @fields[:m_regex].value,
        f_status: @fields[:f_status].value, f_size: @fields[:f_size].value,
        f_words: @fields[:f_words].value, f_regex: @fields[:f_regex].value,
        grpc_fields: @fields[:grpc_fields].value,
        tls_preset: @fields[:tls_preset].value,
        m_time: @fields[:m_time].value, f_time: @fields[:f_time].value)
    end

    # --- rendering ----------------------------------------------------------
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 60}.min
      h = {area.h - 2, ROWS.size + 4}.min
      return nil if w < 30 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # Rows the card can actually draw. The last two interior lines are spoken for — the hint
    # on box.bottom-2, the border on box.bottom-1 — so the list ends at box.bottom-3. ONE
    # definition, read by both render and handle_click, which is the shape every sibling
    # form uses (NotificationsOverlay, HotkeysOverlay, TabsOverlay …): a hit-test that does
    # not invert its own render selects rows the cursor was never over.
    private def list_capacity(box : Rect) : Int32
      {(box.bottom - 2) - (box.y + 1), 1}.max
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "advanced editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "ADVANCED", bg: Theme.bg, border: Theme.border_focus)
      top = box.y + 1
      visible = list_capacity(box)
      # `ROWS` is the form's fixed row table — the same one the loop below breaks against.
      @scroll = Viewport.scroll_to_show(@sel, @scroll, visible, ROWS.size)
      vx = box.x + 2 + LABEL_W
      (0...visible).each do |i|
        ri = @scroll + i
        break if ri >= ROWS.size
        render_row(screen, box, ri, top + i, vx)
      end
      # No key hint on the card — the shell draws `hint` in the status strip for the open
      # modal (Runner#key_hints). This copy had drifted furthest of the nine: it spelled the
      # same three keys differently (`⇥/↑↓` for `↑/↓/⇥`, `space` for `␣`) and omitted `↵ next`
      # entirely, so the two lines on screen disagreed about what the form could do.
    end

    private def render_row(screen : Screen, box : Rect, ri : Int32, y : Int32, vx : Int32) : Nil
      key, label, kind = ROWS[ri]
      foc = ri == @sel
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if foc
      screen.text(box.x + 2, y, label, foc ? Theme.text_bright : Theme.muted, bg)
      if kind == :toggle
        on = case key
             when :follow       then @follow
             when :keep_alive   then @keep_alive
             when :update_cl    then @update_cl
             when :reframe_grpc then @reframe_grpc
             else                    @calibrate
             end
        screen.text(vx, y, on ? "‹ on ›" : "‹ off ›", foc ? Theme.text_bright : Theme.text, bg)
      else
        vw = {box.right - 2 - vx, 1}.max
        @fields[key].render(screen, vx, y, vw, foc, foc ? Theme.text_bright : Theme.text, bg)
      end
    end

    # Focus the row under a click; a click outside the card APPLIES (esc semantics), the
    # same dismissal the shell used to run through apply_close_fuzz_advanced.
    #
    # The `i < list_capacity` bound is the half that was missing: without it a click on the
    # hint row or the bottom border — both INSIDE the box, neither a drawn row — resolved to
    # @scroll + visible (+1) and focused a field the cursor was nowhere near, after which
    # render scrolled the list to follow. Reachable only when the card clips (production's
    # `layout.body` draws 11 of the 17 rows), which is why the 80x24 specs never saw it.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :commit if box.nil? || !box.contains?(mx, my)
      i = my - (box.y + 1)
      return :stay if i < 0 || i >= list_capacity(box)
      ri = @scroll + i
      @sel = ri if ri < ROWS.size
      # …then the caret, if the press landed inside a drawn field. The row pick above is
      # what focuses; this is what puts the caret where the operator pointed instead of
      # leaving it wherever the last keystroke did (Overlay#click_text_field).
      click_text_field(mx, my)
      :stay
    end
  end
end
