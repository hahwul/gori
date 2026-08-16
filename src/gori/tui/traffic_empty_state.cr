require "./screen"
require "./theme"
require "./frame"
require "./empty_art"
require "../bind_address"
require "../settings"

module Gori::Tui
  # Rich onboarding panels for tabs with nothing to show yet. Each variant has its
  # own visual voice; the title rides the top edge, the variant's figure (see EmptyArt)
  # rides above the card, and the two centre as one block below the title.
  # Degrades gracefully on narrow/short panes (figure+card → card → plain lines →
  # two-line hint): the figure is the first thing dropped, the card the last.
  module TrafficEmptyState
    extend self

    # No FULL_MIN_H: a full card runs 6..13 rows depending on variant and flags, so a single
    # shared height floor cannot decide whether one fits. `full_rows` does, per variant.
    FULL_MIN_W = 42
    MED_MIN_H  =  5
    MED_MIN_W  = 30
    # Blank row between a variant's figure and its card, so the two read as one block
    # rather than as art sitting on the card's roof.
    ART_GAP = 1

    # Set once per frame by the Runner (render_body), true while a body-centred modal is
    # open. These cards are box art, and a dialog SHORTER than the card only covers part
    # of it — the NEW ISSUE form (6 rows) over the Issues card (9) left the card's divider
    # and bottom border orphaned below the dialog, reading as a corrupted frame. Gating
    # the whole module here fixes every card/dialog pairing at one point instead of
    # teaching every call site about overlays, and is the right UX regardless: the card is
    # a "how to start" hint, and a dialog means the user already has.
    class_property? suppressed : Bool = false

    # `listen` is the live bind as (host, port), NOT a pre-joined string: the card renders
    # the address at full width but the medium/minimal fallbacks inline it into a longer
    # hint, so this has to pick the verbose or terse form per branch — which needs the
    # parts. Nil falls back to the configured bind.
    def render(screen : Screen, rect : Rect, *,
               variant : Symbol,
               listen : {String, Int32}? = nil,
               capturing : Bool = true,
               catch_on : Bool = false,
               running : Bool = false,
               scan_on : Bool = true,
               has_provider : Bool = true,
               title : String? = nil) : Nil
      return if suppressed?
      return if rect.empty?

      host, port = listen || {Settings.effective_bind_host, Settings.effective_bind_port}
      headline = title || default_title(variant, running: running, scan_on: scan_on)
      # The card has to FIT, not merely clear a shared floor. The old test (7 rows, or 5 for
      # fuzzer_results) admitted `render_full` for cards up to 13 rows tall, and NOTHING clips
      # the interior: each renderer walks `y` downward unguarded, so the card drew straight out
      # of its pane — through the outer frame's bottom border and, at some heights, below the
      # status bar onto the last terminal row. Degrading to medium/minimal is what this module
      # already promises for short panes.
      full_h = full_rows(variant, capturing: capturing, catch_on: catch_on,
        running: running, scan_on: scan_on)

      # This card is the onboarding surface — the address on it is the one the user is
      # meant to TYPE into a client, so a wildcard bind must not render as "0.0.0.0:8070".
      # Only the FULL card has room for the "(all interfaces)" note; the narrower fallbacks
      # inline the address into a longer hint line and take the terse form. Same address
      # either way, so a resize can never appear to move the proxy.
      if rect.h >= full_h && rect.w >= FULL_MIN_W
        addr = BindAddress.display(host, port)
        render_full(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on, has_provider)
      elsif rect.h >= MED_MIN_H && rect.w >= MED_MIN_W
        addr = BindAddress.display(host, port, terse: true)
        render_medium(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on, has_provider)
      else
        addr = BindAddress.display(host, port, terse: true)
        render_minimal(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on, has_provider)
      end
    end

    # Interior row count of each FULL card — ONE source of truth, read by the gate in `render`
    # and by the renderers below, so the two can never drift apart. Defaults let a variant whose
    # height ignores a flag omit it at the call site.
    private def full_inner_h(variant : Symbol, *, capturing : Bool = true, catch_on : Bool = false,
                             running : Bool = false, scan_on : Bool = true) : Int32
      case variant
      when :history   then 5 + (capturing ? 0 : 1) + 3
      when :sitemap   then 5 + (capturing ? 0 : 1) + 3
      when :intercept then 5 + (catch_on ? 0 : 1) + 3 + (capturing ? 0 : 1)
      when :repeater  then 5 + 2
      when :fuzzer    then 5 + 2
        # The three results-pane variants share one budget: the rows they draw, plus one blank so
        # the card is not flush against its own bottom border. In flight that is a single sentence
        # and the chord line is gone, so the card shrinks with it — at the old 3 an in-flight card
        # carried two empty rows under one line of text and read as a box that failed to fill.
      when :fuzzer_results                                  then running ? 2 : 4
      when :probe                                           then scan_on ? 5 + (capturing ? 0 : 1) + 2 : 4
      when :issues                                          then 5 + 2
      when :discover                                        then 5 + 2
      when :comparer                                        then 5 + 2
      when :authorize                                       then 5 + 3 # three chords — see render_authorize_full
      when :miner                                           then 5 + 2
      when :miner_results                                   then running ? 2 : 4
      when :sequencer                                       then 5 + 2
      when :sequencer_samples                               then running ? 2 : 5
      when :oast                                            then 5 + 1 # six, and flat — see render_oast_full
      when :notes                                           then 5 + 1
      when :project_desc                                    then 5 + 1
      when :project_scope, :project_overrides, :project_env then 5 + 1
      else                                                       0 # unknown variant — render_full draws nothing, as before
      end
    end

    # Variants whose card centres in the WHOLE rect, with no headline row riding above it.
    # All are panes reached by a sub-tab that already names them on its chip (and the three
    # Project list panes sit inside an outer card that names them AGAIN on its border), so a
    # headline would repeat the label the operator just clicked.
    CENTERED = {:notes, :project_desc, :project_scope, :project_overrides, :project_env}

    # Rows the full card needs inside `rect`: its interior plus two borders, plus the headline
    # row that rides above it for every variant except the CENTERED ones.
    private def full_rows(variant : Symbol, *, capturing : Bool, catch_on : Bool,
                          running : Bool, scan_on : Bool) : Int32
      full_inner_h(variant, capturing: capturing, catch_on: catch_on,
        running: running, scan_on: scan_on) + 2 + (CENTERED.includes?(variant) ? 0 : 1)
    end

    # `:discover` says "no runs", the phrase that pane has used for this state all along, so a
    # resize between the card and the one-line fallback does not appear to change what happened.
    private def default_title(variant : Symbol, *, running : Bool, scan_on : Bool) : String
      case variant
      when :history           then "waiting for traffic…"
      when :sitemap           then "no traffic captured yet"
      when :intercept         then "no held messages"
      when :repeater          then "no repeater open"
      when :fuzzer            then "no fuzz session open"
      when :fuzzer_results    then running ? "running…" : "no results yet"
      when :probe             then scan_on ? "no issues yet" : "scanning is OFF"
      when :issues            then "no issues yet"
      when :discover          then "no runs yet"
      when :comparer          then "nothing to compare"
      when :authorize         then "no requests queued"
      when :miner             then "no mining session"
      when :miner_results     then running ? "mining…" : "no run yet"
      when :sequencer         then "no sequencer session"
      when :sequencer_samples then running ? "collecting…" : "no samples yet"
      when :oast              then "no callbacks yet"
      when :notes             then "empty note"
      when :project_desc      then "no description yet"
      when :project_scope     then "no scope rules yet"
      when :project_overrides then "no host overrides yet"
      when :project_env       then "no env variables yet"
      else                         "nothing here yet"
      end
    end

    private def render_full(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                            addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                            scan_on : Bool, has_provider : Bool) : Nil
      case variant
      when :history           then render_history_full(screen, rect, headline, addr, capturing)
      when :sitemap           then render_sitemap_full(screen, rect, headline, addr, capturing)
      when :intercept         then render_intercept_full(screen, rect, headline, addr, capturing, catch_on)
      when :repeater          then render_repeater_full(screen, rect, headline)
      when :fuzzer            then render_fuzzer_full(screen, rect, headline)
      when :fuzzer_results    then render_fuzzer_results_full(screen, rect, headline, running)
      when :probe             then render_probe_full(screen, rect, headline, addr, capturing, scan_on)
      when :issues            then render_issues_full(screen, rect, headline)
      when :discover          then render_discover_full(screen, rect, headline)
      when :comparer          then render_comparer_full(screen, rect, headline)
      when :authorize         then render_authorize_full(screen, rect, headline)
      when :miner             then render_miner_full(screen, rect, headline)
      when :miner_results     then render_miner_results_full(screen, rect, headline, running)
      when :sequencer         then render_sequencer_full(screen, rect, headline)
      when :sequencer_samples then render_sequencer_samples_full(screen, rect, headline, running)
      when :oast              then render_oast_full(screen, rect, headline, has_provider)
      when :notes             then render_notes_full(screen, rect)
      when :project_desc      then render_project_desc_full(screen, rect)
      when :project_scope     then render_project_scope_full(screen, rect)
      when :project_overrides then render_project_overrides_full(screen, rect)
      when :project_env       then render_project_env_full(screen, rect)
      end
    end

    private def render_medium(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                              addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                              scan_on : Bool, has_provider : Bool) : Nil
      lines = case variant
              when :history
                medium_history(headline, addr, capturing)
              when :sitemap
                medium_sitemap(headline, addr, capturing)
              when :intercept
                medium_intercept(headline, catch_on)
              when :repeater
                medium_repeater(headline)
              when :fuzzer
                medium_fuzzer(headline)
              when :fuzzer_results
                medium_fuzzer_results(headline, running)
              when :probe
                medium_probe(headline, scan_on)
              when :issues
                medium_issues(headline)
              when :discover
                medium_discover(headline)
              when :comparer
                medium_comparer(headline)
              when :authorize
                medium_authorize(headline)
              when :miner
                medium_miner(headline)
              when :miner_results
                medium_miner_results(headline, running)
              when :sequencer
                medium_sequencer(headline)
              when :sequencer_samples
                medium_sequencer_samples(headline, running)
              when :oast
                medium_oast(headline, has_provider)
              when :notes
                medium_notes(headline)
              when :project_desc
                medium_project_desc(headline)
              when :project_scope
                medium_project_scope(headline)
              when :project_overrides
                medium_project_overrides(headline)
              when :project_env
                medium_project_env(headline)
              else
                [headline]
              end
      draw_medium_lines(screen, rect, lines)
    end

    private def render_minimal(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                               addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                               scan_on : Bool, has_provider : Bool) : Nil
      hint = case variant
             when :history
               "──► #{addr} ──► ^P Open browser#{capturing ? "" : " · press c"}"
             when :sitemap
               "◆ proxy #{addr} · ^P Open browser#{capturing ? "" : " · press c"}"
             when :intercept
               catch_on ? "⏸ queue empty · i catch · / filter" : "press i to enable catch"
             when :repeater
               "^N new · History ^R repeater"
             when :fuzzer
               "^N new · ⇧I from History"
             when :fuzzer_results
               running ? "sampling…" : "^R run · ^O sets"
             when :probe
               scan_on ? "traffic ──► scan · press m" : "press m to enable scanning"
             when :issues
               "⇧F from History · n create"
             when :discover
               "space → Discover here · ^R run"
             when :comparer
               "a pick A · b pick B"
             when :authorize
               "space → Send to Authorize · i identities"
             when :miner
               "space → Mine parameters · ^R run"
             when :miner_results
               running ? "mining…" : "^R mine this request"
             when :sequencer
               "space → Send to Sequencer · ^R"
             when :sequencer_samples
               running ? "collecting…" : "c configure · ^R collect"
             when :oast
               has_provider ? "g payload · ^R listen" : "^2 Providers — add one first"
             when :notes
               "^N new note · start typing"
             when :project_desc
               "i/↵ describe this engagement · ^E $EDITOR"
             when :project_scope
               "a add rule · space menu"
             when :project_overrides
               "a map host→IP · space menu"
             when :project_env
               "a add $KEY · space prefix"
             else
               headline
             end
      screen.text(rect.x + 1, rect.y, headline, Theme.muted, width: {rect.w - 2, 0}.max)
      screen.text(rect.x + 1, rect.y + 2, Hotkeys.retag(hint), Theme.muted, width: {rect.w - 2, 0}.max) if rect.h > 2
    end

    # The variant's figure, a gap, and the card — centred in `body` as ONE block, so the pair
    # can never drift apart. Returns the card's rect.
    #
    # The fits decision is made HERE and nowhere else: every caller receives the card rect
    # this produced rather than re-deriving "did the art show?" next to its own draw, which is
    # how a layout decision computed twice starts disagreeing with itself.
    #
    # The figure is OPPORTUNISTIC. `render`'s height gate promises room for the card ALONE
    # (`full_rows`), and art is deliberately absent from `full_inner_h` — so a figure is added
    # inside an already-granted full tier or not at all, and can never be the thing that
    # overflows the pane. A short pane keeps the card and loses the art, in that order.
    private def place_art_and_card(screen : Screen, body : Rect, variant : Symbol,
                                   card_w : Int32, card_h : Int32) : Rect
      art = EmptyArt.for(variant)
      art = nil if art.nil? || body.h < art.h + ART_GAP + card_h || body.w < art.min_w + 4
      block_h = art ? art.h + ART_GAP + card_h : card_h
      y = body.y + {(body.h - block_h) // 2, 0}.max
      if art
        EmptyArt.draw(screen, art, EmptyArt.origin_x(art, body.x, body.w), y)
        y += art.h + ART_GAP
      end
      Rect.new(body.x + {(body.w - card_w) // 2, 0}.max, y, card_w, card_h)
    end

    private def draw_headline(screen : Screen, rect : Rect, y0 : Int32, headline : String) : Nil
      screen.text(rect.x + 1, y0, headline, Theme.muted, width: {rect.w - 2, 0}.max)
    end

    # Shared by `begin_card`/`begin_centered_card`. `min_w` is the caller's longest
    # description line, in DISPLAY columns (not `.size` — `Screen.display_width` is what
    # every sibling box-sizing call site in this codebase measures with, and it is the only
    # one that stays correct once a caption line picks up a wide/CJK glyph) — `floor` is a
    # floor for short-caption variants, not a ceiling for long ones. Without this, prose
    # that runs past 46 usable columns (most of it: several description sentences are
    # 55-70 chars) clipped with an ellipsis on every terminal, wide or not.
    private def card_width(rect : Rect, min_w : Int32, floor : Int32) : Int32
      {rect.w - 4, {min_w + 4, floor}.max}.min.clamp(FULL_MIN_W, rect.w)
    end

    # The headline rides `rect`'s top edge; the figure and the card share every row below it.
    # `variant` is threaded through purely so the art lookup happens at this ONE site instead
    # of in each of the ten renderers below.
    private def begin_card(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                           card_title : String, inner_h : Int32, min_w : Int32 = 0) : {Rect, Int32, Int32}
      card_w = card_width(rect, min_w, 50)
      draw_headline(screen, rect, rect.y, headline)
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      card = place_art_and_card(screen, body, variant, card_w, inner_h + 2)
      Frame.card(screen, card, card_title, bg: Theme.bg, border: Theme.border)
      inner = card.inset(1, 1)
      {inner, inner.x + 1, {inner.w - 2, 1}.max}
    end

    private def render_history_full(screen : Screen, rect : Rect, headline : String,
                                    addr : String, capturing : Bool) : Nil
      # +3 (not +2): the intro/addr/diagram block spans through relative row 3, the
      # divider + palette hint reach row 6, and the final "or set your client's proxy"
      # line lands on row 7 — which the old budget pushed onto the card's bottom border.
      inner_h = full_inner_h(:history, capturing: capturing)
      desc = "Requests stream in here as they pass through the proxy."
      inner, ix, iw = begin_card(screen, rect, :history, headline, "FLOW LOG", inner_h, Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix + 2, y, addr, Theme.accent, Theme.bg, Attribute::Bold, width: iw)
      y += 1
      screen.text(ix, y, fit_history_flow(addr, iw), Theme.muted, Theme.bg, width: iw)
      y += 2
      unless capturing
        screen.text(ix, y, "capture is OFF — press c to start", Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_palette_hint(screen, ix, y, iw, bullet: "▸ ")
      screen.text(ix, y, "or set your client's HTTP+HTTPS proxy", Theme.muted, Theme.bg, width: iw)
    end

    private def render_sitemap_full(screen : Screen, rect : Rect, headline : String,
                                    addr : String, capturing : Bool) : Nil
      # 5 + 3, not 6 + 3. The Target tab spends two rows on a sub-tab strip that History does
      # not, and this card was one row TALLER than History's on top of that — so on an 80x24
      # the tree pane had 11 rows against a 12-row card and the whole thing fell through to the
      # three-line medium form. Sitemap is the default sub-tab and Discover, one chip over, was
      # drawing figure AND card in the same pane: the sharpest possible version of a resize
      # deciding how much a tab explains itself. The row came from the blank that used to sit
      # between the address and the palette hint, which is the one place a gap bought nothing —
      # address, "^P Open browser" and "or set your client's proxy" are one instruction.
      inner_h = full_inner_h(:sitemap, capturing: capturing)
      desc = "Browsing builds a host → path tree from captured traffic."
      inner, ix, iw = begin_card(screen, rect, :sitemap, headline, "SITE MAP", inner_h, Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "◆ hosts group traffic", Theme.muted, Theme.bg, width: iw)
      y += 1
      screen.text(ix, y, "  └ paths nest under each host", Theme.muted, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "proxy ", Theme.muted, Theme.bg)
      px = ix + "proxy ".size
      screen.text(px, y, addr, Theme.accent, Theme.bg, Attribute::Bold, width: {ix + iw - px, 0}.max)
      y += 1
      unless capturing
        screen.text(ix, y, "capture is OFF — press c to start", Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      y = draw_palette_hint(screen, ix, y, iw, bullet: "◆ ")
      screen.text(ix, y, "or set your client's HTTP+HTTPS proxy", Theme.muted, Theme.bg, width: iw)
    end

    private def render_intercept_full(screen : Screen, rect : Rect, headline : String,
                                      addr : String, capturing : Bool, catch_on : Bool) : Nil
      inner_h = full_inner_h(:intercept, capturing: capturing, catch_on: catch_on)
      msg = catch_on ? "Matching traffic pauses here for review before it continues." : "Catch is OFF — press i to hold matching requests/responses."
      inner, ix, iw = begin_card(screen, rect, :intercept, headline, "INTERCEPT", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      y += 2
      screen.text(ix, y, "traffic ──► ⏸ hold ──► f forward · d drop", Theme.muted, Theme.bg, width: iw)
      y += 2
      unless catch_on
        screen.text(ix, y, "catch is OFF — press i to enable", Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      unless capturing
        screen.text(ix, y, "capture is OFF — press c to start", Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      y = draw_chord_hint(screen, ix, y, iw, " i:CATCH ", "toggle catch", bullet: "⏸ ")
      y = draw_chord_hint(screen, ix, y, iw, " c:ALL ", "cycle REQ/RES/ALL", bullet: "▸ ")
      screen.text(ix, y, "▸ / condition — filter what gets held", Theme.muted, Theme.bg, width: iw)
      y += 1
      draw_palette_hint(screen, ix, y, iw, bullet: "▸ ")
    end

    private def render_repeater_full(screen : Screen, rect : Rect, headline : String) : Nil
      inner_h = full_inner_h(:repeater)
      desc = "Edit a captured request and resend it — compare the response."
      inner, ix, iw = begin_card(screen, rect, :repeater, headline, "REPEATER", inner_h, Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "flow ──► edit ──► send ──► response", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " ^R ", "repeater from History", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^N ", "new blank repeater tab", bullet: "▸ ")
    end

    private def render_fuzzer_full(screen : Screen, rect : Rect, headline : String) : Nil
      inner_h = full_inner_h(:fuzzer)
      desc = "Probe endpoints by swapping §markers§ in a template."
      inner, ix, iw = begin_card(screen, rect, :fuzzer, headline, "FUZZER", inner_h, Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "template ──► §payloads§ ──► probe", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " ^N ", "new fuzz session", bullet: "§ ")
      draw_chord_hint(screen, ix, y, iw, " ⇧I ", "send from History/Repeater", bullet: "▸ ")
    end

    # "FUZZ RUN", not "RESULTS": this card draws INSIDE the pane the Fuzzer titles RESULTS, and a
    # card wearing its container's name reads as a rendering fault rather than as a nested hint.
    # Every other card already avoided the collision by accident (FLOW LOG in an untitled list,
    # SITE MAP under a HOST / PATH header); the two results-pane variants below take the same
    # verb-shaped name for the same reason.
    private def render_fuzzer_results_full(screen : Screen, rect : Rect, headline : String, running : Bool) : Nil
      inner_h = full_inner_h(:fuzzer_results, running: running)
      msg = running ? "Probes are in flight — hits and status codes land here." : "Add payload sets (^O), then press ^R to start a fuzz run."
      inner, ix, iw = begin_card(screen, rect, :fuzzer_results, headline, "FUZZ RUN", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      y += 2
      draw_chord_hint(screen, ix, y, iw, " ^R ", running ? "running…" : "run fuzzer", bullet: "▸ ") unless running
    end

    private def render_probe_full(screen : Screen, rect : Rect, headline : String,
                                  addr : String, capturing : Bool, scan_on : Bool) : Nil
      inner_h = full_inner_h(:probe, capturing: capturing, scan_on: scan_on)
      desc = scan_on ? "Passive scanning flags issues as traffic flows through the proxy." : "Probe is not analyzing traffic while scanning is OFF."
      hint2 = "enable PASSIVE (safe) or ACTIVE to detect issues"
      min_w = scan_on ? Screen.display_width(desc) : {Screen.display_width(desc), Screen.display_width(hint2)}.max
      inner, ix, iw = begin_card(screen, rect, :probe, headline, "PROBE", inner_h, min_w)
      y = inner.y

      if scan_on
        draw_wrapped_message(screen, ix, y, iw, desc)
        y += 2
        screen.text(ix, y, "traffic ──► scan ──► issues", Theme.muted, Theme.bg, width: iw)
        # One row, not two — the same 80x24 arithmetic as SITE MAP above. Probe's Findings pane
        # loses rows to a sub-tab strip, a mode row, a filter bar AND a column header, leaving 10
        # against an 11-row card. The address belongs against the diagram anyway: both name the
        # pipe the scanner reads from.
        y += 1
        screen.text(ix + 2, y, addr, Theme.accent, Theme.bg, Attribute::Bold, width: iw)
        y += 2
        unless capturing
          screen.text(ix, y, "capture is OFF — press c to start", Theme.yellow, Theme.bg, width: iw)
          y += 1
        end
        y = draw_chord_hint(screen, ix, y, iw, " m:MODE ", "cycle scan mode", bullet: "◇ ")
        draw_palette_hint(screen, ix, y, iw, bullet: "▸ ")
      else
        draw_wrapped_message(screen, ix, y, iw, desc)
        y += 2
        screen.text(ix, y, hint2, Theme.muted, Theme.bg, width: iw)
        y += 2
        draw_chord_hint(screen, ix, y, iw, " m:MODE ", "turn scanning on", bullet: "◇ ")
      end
    end

    private def render_issues_full(screen : Screen, rect : Rect, headline : String) : Nil
      inner_h = full_inner_h(:issues)
      desc = "Track confirmed vulnerabilities you triage by hand."
      inner, ix, iw = begin_card(screen, rect, :issues, headline, "ISSUES", inner_h, Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "flow ──► issue ──► triage ──► resolve", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " ⇧F ", "issue from History flow", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " n ", "create an issue here", bullet: "▸ ")
    end

    # Discover, Comparer, Miner and Sequencer all reach here from a container-level "nothing
    # open yet" branch, the same place Repeater and Fuzzer do — so they share that shape:
    # prose, a diagram, a divider, and the two chords that open the tab. Each spends exactly
    # `5 + 2` interior rows, which is what `full_inner_h` claims for them.

    private def render_discover_full(screen : Screen, rect : Rect, headline : String) : Nil
      desc = "Crawl a target for endpoints nothing linked."
      inner, ix, iw = begin_card(screen, rect, :discover, headline, "DISCOVER", full_inner_h(:discover), Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "target ──► crawl ──► endpoints", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " space ", "\"Discover here\" on a host", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^R ", "run the selected crawl", bullet: "▸ ")
    end

    private def render_comparer_full(screen : Screen, rect : Rect, headline : String) : Nil
      desc = "Diff two flows side by side — req or res."
      inner, ix, iw = begin_card(screen, rect, :comparer, headline, "COMPARER", full_inner_h(:comparer), Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "A ──► diff ◄── B", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " a ", "pick flow A", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " b ", "pick flow B", bullet: "▸ ")
    end

    # THREE chord lines, where the sibling cards take two (hence `5 + 3` in `full_inner_h`).
    # Getting a request into the queue and running it are steps the rest of the app implies;
    # choosing who to replay as is the one this tab invented, and a card that omitted it would
    # leave an operator on the two built-in identities with no sign there was a third thing to
    # press.
    private def render_authorize_full(screen : Screen, rect : Rect, headline : String) : Nil
      desc = "Replay one request as several identities and diff the answers."
      inner, ix, iw = begin_card(screen, rect, :authorize, headline, "AUTHORIZE", full_inner_h(:authorize), Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "one request ──► many identities", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " space ", "\"Send to Authorize\" on a flow", bullet: "▸ ")
      y = draw_chord_hint(screen, ix, y, iw, " i ", "who to replay as", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^R ", "replay what has not run", bullet: "▸ ")
    end

    private def render_miner_full(screen : Screen, rect : Rect, headline : String) : Nil
      desc = "Find undocumented parameters a target takes."
      inner, ix, iw = begin_card(screen, rect, :miner, headline, "MINER", full_inner_h(:miner), Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "wordlist ──► probe ──► params", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " space ", "\"Mine parameters\" on a flow", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^R ", "start mining", bullet: "▸ ")
    end

    private def render_sequencer_full(screen : Screen, rect : Rect, headline : String) : Nil
      desc = "Collect tokens and measure their randomness."
      inner, ix, iw = begin_card(screen, rect, :sequencer, headline, "SEQUENCER", full_inner_h(:sequencer), Screen.display_width(desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "collect ──► samples ──► entropy", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " space ", "\"Send to Sequencer\" on a flow", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^R ", "collect samples", bullet: "▸ ")
    end

    # The three RESULTS-pane variants below (fuzz above, mine and sample here) all draw inside a
    # pane that is itself a card, so they take the compact `fuzzer_results` shape — a sentence,
    # a gap, the chord — rather than the prose/diagram/divider block their container-level
    # siblings use. Only the never-run and in-flight states reach them: a pane reporting on a
    # run that finished empty has something specific to say and keeps its own line.

    private def render_miner_results_full(screen : Screen, rect : Rect, headline : String, running : Bool) : Nil
      inner_h = full_inner_h(:miner_results, running: running)
      msg = running ? "Probing the wordlist — names the target answers to land here." : "A run sends the wordlist and keeps the names that change the response."
      inner, ix, iw = begin_card(screen, rect, :miner_results, headline, "MINE RUN", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      y += 2
      draw_chord_hint(screen, ix, y, iw, " ^R ", "start mining", bullet: "▸ ") unless running
    end

    private def render_sequencer_samples_full(screen : Screen, rect : Rect, headline : String, running : Bool) : Nil
      inner_h = full_inner_h(:sequencer_samples, running: running)
      msg = running ? "Collecting — one token per send lands here." : "A run re-sends this request and keeps one token from each response."
      inner, ix, iw = begin_card(screen, rect, :sequencer_samples, headline, "TOKEN RUN", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      return if running
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " c ", "where the token lives", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^R ", "collect samples", bullet: "▸ ")
    end

    # OAST is the one workbench tab that had no card at all: an empty CALLBACKS pane is the
    # tallest void in the app, and it is also the tab whose loop is hardest to guess — the thing
    # you are waiting for arrives on a channel you never opened. With no provider configured the
    # card leads with that instead, because `g` refuses without one and "get a payload URL" as
    # step one would be a dead end.
    #
    # SIX interior rows, one under its container-level siblings, because the OAST tab spends
    # three rows above this pane that they do not (a two-row payload bar and a filter bar) and an
    # 80x24 leaves the CALLBACKS card nine. The row comes off the divider, which `:notes` and
    # `:fuzzer_results` already do without. And the count is FLAT across both branches — the
    # warning takes the blank row rather than pushing one in — so the provider state can never be
    # what decides whether the card appears: the state without a provider is the first thing a
    # new operator sees and the one that most needs explaining.
    private def render_oast_full(screen : Screen, rect : Rect, headline : String, has_provider : Bool) : Nil
      desc = "Payloads you plant call back here — DNS, HTTP and SMTP hits."
      warning = "no provider yet — one has to hand out the payloads"
      min_w = has_provider ? Screen.display_width(desc) : {Screen.display_width(desc), Screen.display_width(warning)}.max
      inner, ix, iw = begin_card(screen, rect, :oast, headline, "OAST", full_inner_h(:oast), min_w)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, "payload ──► target ──► callback", Theme.muted, Theme.bg, width: iw)
      y += 1
      unless has_provider
        screen.text(ix, y, warning, Theme.yellow, Theme.bg, width: iw)
      end
      y += 1
      if has_provider
        y = draw_chord_hint(screen, ix, y, iw, " g ", "get a payload URL (copied)", bullet: "▸ ")
        draw_chord_hint(screen, ix, y, iw, " ^R ", "start listening", bullet: "▸ ")
      else
        y = draw_chord_hint(screen, ix, y, iw, " ^2 ", "Providers — interactsh is prefilled", bullet: "▸ ")
        draw_chord_hint(screen, ix, y, iw, " g ", "get a payload URL, once one is on", bullet: "▸ ")
      end
    end

    # A CENTERED variant, so the whole rect goes to `place_art_and_card` — there is no
    # headline row to carve off first (see CENTERED).
    private def render_notes_full(screen : Screen, rect : Rect) : Nil
      desc = "Your project scratchpad — observations, hypotheses, write-ups."
      hint = "notes stack as sub-tabs · first line becomes the title"
      inner, ix, iw = begin_centered_card(screen, rect, :notes, "NOTES", full_inner_h(:notes), {Screen.display_width(desc), Screen.display_width(hint)}.max)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, hint, Theme.muted, Theme.bg, width: iw)
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " ^N ", "new note tab", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^W ", "close current note", bullet: "▸ ")
    end

    # The Project tab's DESCRIPTION sub-tab with nothing written yet. Sibling cards on that
    # tab all name their own emptiness ("no scope rules — press a to add"); this one used to
    # render as pure void, which is why it exists.
    private def render_project_desc_full(screen : Screen, rect : Rect) : Nil
      desc = "Target, scope, credentials, rules."
      hint = "the first thing you read on re-entry"
      inner, ix, iw = begin_centered_card(screen, rect, :project_desc, "PROJECT",
        full_inner_h(:project_desc), {Screen.display_width(desc), Screen.display_width(hint)}.max)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, hint, Theme.muted, Theme.bg, width: iw)
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " i/↵ ", "start writing", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^E ", "open in $EDITOR", bullet: "▸ ")
    end

    # The Project tab's SCOPE card with no rules. Titled TARGETS, not SCOPE — the outer card
    # already says SCOPE on its border, and the rules are the list of targets.
    private def render_project_scope_full(screen : Screen, rect : Rect) : Nil
      desc = "Scope rules mark which hosts you're testing."
      hint = "incl keeps a host in · excl passes it through"
      inner, ix, iw = begin_centered_card(screen, rect, :project_scope, "TARGETS",
        full_inner_h(:project_scope), {Screen.display_width(desc), Screen.display_width(hint)}.max)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, hint, Theme.muted, Theme.bg, width: iw)
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " a ", "add an include or exclude rule", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " space ", "rule actions", bullet: "▸ ")
    end

    # The Project tab's HOST OVERRIDES card with no entries. DNS MAP because that is what an
    # entry does — resolve past DNS — where "overrides" only repeats the border.
    private def render_project_overrides_full(screen : Screen, rect : Rect) : Nil
      desc = "Pin a hostname to a chosen IP for this project."
      hint = "requests resolve there before real DNS"
      inner, ix, iw = begin_centered_card(screen, rect, :project_overrides, "DNS MAP",
        full_inner_h(:project_overrides), {Screen.display_width(desc), Screen.display_width(hint)}.max)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, hint, Theme.muted, Theme.bg, width: iw)
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " a ", "map a host to an IP", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " space ", "override actions", bullet: "▸ ")
    end

    # The Project tab's ENVIRONMENT card with no vars. The copy hardcodes the default `$`
    # sigil: an empty pane means a fresh project, and the live prefix rides the outer border.
    private def render_project_env_full(screen : Screen, rect : Rect) : Nil
      desc = "Store $KEY values to reuse across requests."
      hint = "$KEY in a request expands when you send"
      inner, ix, iw = begin_centered_card(screen, rect, :project_env, "VARIABLES",
        full_inner_h(:project_env), {Screen.display_width(desc), Screen.display_width(hint)}.max)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, hint, Theme.muted, Theme.bg, width: iw)
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " a ", "add a $KEY variable", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " space ", "vars & prefix", bullet: "▸ ")
    end

    # `begin_card` for a CENTERED variant: the same figure-and-card block, but centred in the
    # whole rect because these draw no headline. Narrower floor than `begin_card`'s 50 —
    # all sit inside a pane that is otherwise empty, where a wide card reads as chrome.
    private def begin_centered_card(screen : Screen, rect : Rect, variant : Symbol,
                                    card_title : String, inner_h : Int32, min_w : Int32 = 0) : {Rect, Int32, Int32}
      card_w = card_width(rect, min_w, 46)
      card = place_art_and_card(screen, rect, variant, card_w, inner_h + 2)
      Frame.card(screen, card, card_title, bg: Theme.bg, border: Theme.border)
      inner = card.inset(1, 1)
      {inner, inner.x + 1, {inner.w - 2, 1}.max}
    end

    private def medium_history(headline, addr, capturing) : Array(String)
      lines = [headline, "──► proxy #{addr} ──► flows"]
      lines << "capture is OFF — press c to start" unless capturing
      lines << "^P → Open browser · or set HTTP+HTTPS proxy"
      lines
    end

    private def medium_sitemap(headline, addr, capturing) : Array(String)
      lines = [headline, "◆ proxy #{addr} → host tree"]
      lines << "capture is OFF — press c to start" unless capturing
      lines << "^P → Open browser · or set HTTP+HTTPS proxy"
      lines
    end

    private def medium_intercept(headline, catch_on) : Array(String)
      lines = [headline]
      lines << (catch_on ? "⏸ queue empty · matching traffic pauses here" : "press i to enable catch")
      lines << "f forward · d drop · / condition"
      lines
    end

    private def medium_repeater(headline) : Array(String)
      [headline, "flow ──► edit ──► send", "^N new tab · History ^R repeater"]
    end

    private def medium_fuzzer(headline) : Array(String)
      [headline, "§ template ──► payloads ──► probe", "^N new session · ⇧I from History"]
    end

    private def medium_fuzzer_results(headline, running) : Array(String)
      running ? [headline, "sampling probes…"] : [headline, "^O payload sets · ^R run"]
    end

    private def medium_probe(headline, scan_on) : Array(String)
      if scan_on
        [headline, "traffic ──► scan ──► issues", "m:MODE · capture in-scope traffic"]
      else
        [headline, "press m to enable scanning", "m:MODE cycle OFF/PASSIVE/ACTIVE"]
      end
    end

    private def medium_issues(headline) : Array(String)
      [headline, "flow ──► issue ──► triage", "⇧F from History · n create"]
    end

    private def medium_discover(headline) : Array(String)
      [headline, "target ──► crawl ──► endpoints", "space → Discover here · ^R run"]
    end

    private def medium_comparer(headline) : Array(String)
      [headline, "A ──► diff ◄── B", "a pick flow A · b pick flow B"]
    end

    private def medium_authorize(headline) : Array(String)
      [headline, "one request ──► many identities", "space → Send to Authorize · i identities"]
    end

    private def medium_miner(headline) : Array(String)
      [headline, "wordlist ──► probe ──► params", "space → Mine parameters · ^R run"]
    end

    private def medium_sequencer(headline) : Array(String)
      [headline, "collect ──► samples ──► entropy", "space → Send to Sequencer · ^R"]
    end

    private def medium_miner_results(headline, running) : Array(String)
      running ? [headline, "probing the wordlist…"] : [headline, "^R mines this request"]
    end

    private def medium_sequencer_samples(headline, running) : Array(String)
      running ? [headline, "collecting tokens…"] : [headline, "c token location · ^R collect"]
    end

    private def medium_oast(headline, has_provider) : Array(String)
      if has_provider
        [headline, "payload ──► target ──► callback", "g payload URL · ^R listen"]
      else
        [headline, "no provider yet — ^2 Providers", "then g for a payload URL"]
      end
    end

    private def medium_notes(headline) : Array(String)
      [headline, "scratchpad for this project", "^N new note · ^W close"]
    end

    private def medium_project_desc(headline) : Array(String)
      [headline, "target · scope · credentials · rules", "i/↵ edit · ^E $EDITOR"]
    end

    private def medium_project_scope(headline) : Array(String)
      [headline, "incl / excl ──► scope lens", "a add rule · space menu"]
    end

    private def medium_project_overrides(headline) : Array(String)
      [headline, "host ──► your IP", "a add · e edit · d delete"]
    end

    private def medium_project_env(headline) : Array(String)
      [headline, "$KEY ──► value on send", "a add var · space prefix"]
    end

    private def draw_medium_lines(screen : Screen, rect : Rect, lines : Array(String)) : Nil
      y0 = rect.y
      lines.each_with_index do |line, i|
        y = y0 + i
        break if y >= rect.bottom
        col = i == 0 ? Theme.muted : (i == 1 ? Theme.accent : Theme.muted)
        attr = i == 1 ? Attribute::Bold : Attribute::None
        # The medium_* builders write "^N"/"^P" literals; retag here so the card advertises
        # whichever modifier is configured (a no-op on the default).
        screen.text(rect.x + 1, y, Hotkeys.retag(line), col, attr: attr, width: {rect.w - 2, 0}.max)
      end
    end

    private def draw_palette_hint(screen : Screen, ix : Int32, y : Int32, iw : Int32, *, bullet : String) : Int32
      draw_chord_hint(screen, ix, y, iw, " ^P ", "Open browser", bullet: bullet)
    end

    private def draw_chord_hint(screen : Screen, ix : Int32, y : Int32, iw : Int32,
                                chord : String, label : String, *, bullet : String) : Int32
      bg = Theme.bg
      screen.text(ix, y, bullet, Theme.muted, bg)
      bx = ix + bullet.size
      # Claimed-family chips (^N/^W/^P) follow the configured modifier; ^R and the
      # "i:CATCH"-style chips are untouched (retag's token set is closed).
      x = Frame.chip(screen, bx, y, Hotkeys.retag(chord), true) + 1
      screen.text(x, y, " #{label}", Theme.text, bg, width: {ix + iw - x, 0}.max)
      y + 1
    end

    private def fit_history_flow(listen : String, max_w : Int32) : String
      full = "client ──► #{listen} ──► flows"
      return full if full.size <= max_w
      short = "──► proxy ──► flows"
      short.size <= max_w ? short : "──► #{listen} ──►"
    end

    # The RESULTS/SAMPLES-pane variants (fuzz/mine/token run) draw inside a pane nested a
    # frame deeper than the container-level cards above — its own "RESULTS"/"FINDINGS" card
    # eats another 2 columns of border before `TrafficEmptyState` ever sees a rect, so on a
    # stock 80x24 terminal `card_width`'s floor still can't always buy back the room a 55-70
    # char idle message needs. Word-wrapping onto the blank row these three variants already
    # reserve between the message and the chord hint (`full_inner_h`'s `+2`/`+4`/`+5` never
    # changes) fits a wrap with zero risk to the row-budget tier gate `render` decides with
    # BEFORE any of this width math runs — the alternative, growing `inner_h` here, would
    # reopen the exact overflow bug the row-budget rewrite (PR #693) fixed.
    private def draw_wrapped_message(screen : Screen, ix : Int32, y : Int32, iw : Int32, msg : String) : Nil
      if Screen.display_width(msg) <= iw
        screen.text(ix, y, msg, Theme.text, Theme.bg, width: iw)
        return
      end
      line1, line2 = wrap_two_lines(msg, iw)
      screen.text(ix, y, line1, Theme.text, Theme.bg, width: iw)
      screen.text(ix, y + 1, line2, Theme.text, Theme.bg, width: iw)
    end

    # Greedily fills `line1` with whole words up to `max_w` display columns (always at
    # least one word, even if that word alone overflows) and returns the rest as `line2` —
    # `screen.text`'s own width-aware ellipsis still guards `line2` if it is somehow still
    # too long for a second line.
    private def wrap_two_lines(msg : String, max_w : Int32) : {String, String}
      words = msg.split(' ')
      line1 = [] of String
      i = 0
      while i < words.size
        trial = (line1 + [words[i]]).join(" ")
        break if !line1.empty? && Screen.display_width(trial) > max_w
        line1 << words[i]
        i += 1
      end
      {line1.join(" "), words[i..].join(" ")}
    end
  end
end
