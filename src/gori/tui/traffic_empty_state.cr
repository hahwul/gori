require "./screen"
require "./theme"
require "./frame"
require "./empty_art"
require "../bind_address"
require "../settings"
require "../proxy/conn/self_page"

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

    # The registry the cards resolve their chord chips through — set once by the Runner
    # beside `suppressed`. Nil (a registry-less render: the view specs) leaves every chip at
    # the literal spelled at its call site, which is also what the chip falls back to for an
    # unbound verb. See #key.
    class_property registry : Verb::Registry? = nil

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
               body_focused : Bool = true,
               catch_direction : String = "REQ",
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
      full_h = full_rows(variant, capturing: capturing, running: running, scan_on: scan_on)

      # This card is the onboarding surface — the address on it is the one the user is
      # meant to TYPE into a client, so a wildcard bind must not render as "0.0.0.0:8070".
      # Only the FULL card has room for the "(all interfaces)" note; the narrower fallbacks
      # inline the address into a longer hint line and take the terse form. Same address
      # either way, so a resize can never appear to move the proxy.
      if rect.h >= full_h && rect.w >= FULL_MIN_W
        addr = BindAddress.display(host, port)
        render_full(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on,
          has_provider, body_focused, catch_direction)
      elsif rect.h >= MED_MIN_H && rect.w >= MED_MIN_W
        addr = BindAddress.display(host, port, terse: true)
        render_medium(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on,
          has_provider, body_focused)
      else
        addr = BindAddress.display(host, port, terse: true)
        render_minimal(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on,
          has_provider, body_focused)
      end
    end

    # Interior row count of each FULL card — ONE source of truth, read by the gate in `render`
    # and by the renderers below, so the two can never drift apart. Defaults let a variant whose
    # height ignores a flag omit it at the call site.
    private def full_inner_h(variant : Symbol, *, capturing : Bool = true,
                             running : Bool = false, scan_on : Bool = true) : Int32
      case variant
      when :history, :sitemap, :intercept                                        then 5 + (capturing ? 0 : 1) + 3
      when :repeater, :fuzzer, :issues, :discover, :comparer, :miner, :sequencer then 5 + 2
        # The three results-pane variants share one budget: the rows they draw, plus one blank so
        # the card is not flush against its own bottom border. In flight that is a single sentence
        # and the chord line is gone, so the card shrinks with it — at the old 3 an in-flight card
        # carried two empty rows under one line of text and read as a box that failed to fill.
      when :fuzzer_results    then running ? 2 : 4
      when :probe             then scan_on ? 5 + (capturing ? 0 : 1) + 2 : 4
      when :authorize         then 5 + 3 # three chords — see standard_card
      when :miner_results     then running ? 2 : 4
      when :sequencer_samples then running ? 2 : 5
      when :oast              then 5 + 1 # six, and flat — see render_oast_full
      when :notes, :project_desc, :project_scope, :project_overrides, :project_env, :project_activity
        5 + 1
      else 0 # unknown variant — render_full draws nothing, as before
      end
    end

    # Variants whose card centres in the WHOLE rect, with no headline row riding above it.
    # All are panes reached by a sub-tab that already names them on its chip (and the three
    # Project list panes sit inside an outer card that names them AGAIN on its border), so a
    # headline would repeat the label the operator just clicked.
    CENTERED = {:notes, :project_desc, :project_scope, :project_overrides, :project_env,
                :project_activity}

    # Rows the full card needs inside `rect`: its interior plus two borders, plus the headline
    # row that rides above it for every variant except the CENTERED ones.
    private def full_rows(variant : Symbol, *, capturing : Bool,
                          running : Bool, scan_on : Bool) : Int32
      full_inner_h(variant, capturing: capturing, running: running, scan_on: scan_on) + 2 + (CENTERED.includes?(variant) ? 0 : 1)
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
      when :project_activity  then "no activity recorded yet"
      else                         "nothing here yet"
      end
    end

    private def render_full(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                            addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                            scan_on : Bool, has_provider : Bool, body_focused : Bool,
                            catch_direction : String) : Nil
      if card = standard_card(variant)
        render_standard_full(screen, rect, variant, headline, card)
      elsif card = centered_card(variant)
        render_centered_full(screen, rect, variant, card)
      else
        case variant
        when :history           then render_history_full(screen, rect, headline, addr, capturing)
        when :sitemap           then render_sitemap_full(screen, rect, headline, addr, capturing)
        when :intercept         then render_intercept_full(screen, rect, headline, addr, capturing, catch_on, body_focused, catch_direction)
        when :fuzzer_results    then render_fuzzer_results_full(screen, rect, headline, running)
        when :probe             then render_probe_full(screen, rect, headline, addr, capturing, scan_on)
        when :miner_results     then render_miner_results_full(screen, rect, headline, running)
        when :sequencer_samples then render_sequencer_samples_full(screen, rect, headline, running)
        when :oast              then render_oast_full(screen, rect, headline, has_provider)
        end
      end
    end

    private def render_medium(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                              addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                              scan_on : Bool, has_provider : Bool, body_focused : Bool) : Nil
      lines = case variant
              when :history
                [headline, "──► proxy #{addr} ──► flows",
                 capturing ? "HTTPS: trust the CA at #{Proxy::SelfPage::MAGIC_URL}" : capture_off_hint,
                 "#{palette_route("browser.open", "Open browser")} · proxied, CA trusted"]
              when :sitemap
                [headline, "◆ proxy #{addr} → host tree", (capture_off_hint unless capturing),
                 "#{palette_route("browser.open", "Open browser")} · or set HTTP+HTTPS proxy"].compact
              when :intercept
                [headline,
                 catch_on ? "⏸ queue empty · matching traffic pauses here" : "#{body_focused ? "press" : "focus body, then press"} #{key("i", "intercept.toggle")} to enable catch",
                 medium_intercept_action_hint(body_focused)]
              when :repeater
                [headline, "flow ──► edit ──► send", "^N new tab · History #{key("^R", "history.repeater")} repeater"]
              when :fuzzer
                [headline, "§ template ──► payloads ──► probe", "^N new session · #{key("⇧I", "history.fuzz")} from History"]
              when :fuzzer_results
                running ? [headline, "sampling probes…"] : [headline, "^O payload sets · #{key("^R", "fuzz.run")} run"]
              when :probe
                if scan_on
                  [headline, "traffic ──► scan ──► issues", "#{key("m", "probe.mode")}:MODE · capture in-scope traffic"]
                else
                  [headline, "press #{key("m", "probe.mode")} to enable scanning", "#{key("m", "probe.mode")}:MODE cycle OFF/PASSIVE/ACTIVE"]
                end
              when :issues
                [headline, "flow ──► issue ──► triage", "#{key("⇧F", "issue.create")} from History · #{key("n", "issues.new")} create"]
              when :discover
                [headline, "target ──► crawl ──► endpoints", "Discover here (#{menu("sitemap.discover")}) · #{key("^R", "discover.run")} run"]
              when :comparer
                [headline, "A ──► diff ◄── B", "#{key("a", "comparer.pick-a")} pick flow A · #{key("b", "comparer.pick-b")} pick flow B"]
              when :authorize
                [headline, "one request ──► many identities", "Send to Authorize (#{menu("history.authorize")}) · #{key("i", "authorize.identities")} identities"]
              when :miner
                [headline, "wordlist ──► probe ──► params", "From History/Repeater: #{menu("history.mine")} Mine parameters"]
              when :miner_results
                running ? [headline, "probing the wordlist…"] : [headline, "#{key("^R", "mine.run")} mines this request"]
              when :sequencer
                [headline, "collect ──► samples ──► entropy", "Send to Sequencer (#{menu("history.sequence")}) · #{key("^R", "sequence.run")}"]
              when :sequencer_samples
                running ? [headline, "collecting tokens…"] : [headline, "#{key("c", "sequence.configure")} token location · #{key("^R", "sequence.run")} collect"]
              when :oast
                if has_provider
                  [headline, "payload ──► target ──► callback", "#{key("g", "oast.generate")} payload URL · #{key("^R", "oast.listen")} listen"]
                else
                  [headline, "no provider yet — ^2 Providers", "then #{key("g", "oast.generate")} for a payload URL"]
                end
              when :notes
                [headline, "scratchpad for this project", "^N new note · ^W close"]
              when :project_desc
                [headline, "target · scope · credentials · rules", "i/↵ edit · ^E $EDITOR"]
              when :project_scope
                [headline, "incl / excl ──► scope lens", "#{key("a", "scope.add-rule")} add rule · space menu"]
              when :project_overrides
                [headline, "host ──► your IP", "#{key("a", "hostoverride.add-entry")} add · #{key("e", "hostoverride.edit-entry")} edit · #{key("d", "hostoverride.delete-entry")} delete"]
              when :project_env
                [headline, "#{Env.spell("KEY", Env::Namespace::Env)} ──► value on send", "#{key("a", "env.add-var")} add var · space menu"]
              when :project_activity
                [headline, "agents & jobs ──► one log", "#{key("s", "activity.filter-source")} source · #{key("l", "activity.filter-level")} level · ↵ open"]
              else
                [headline]
              end
      draw_medium_lines(screen, rect, lines)
    end

    private def render_minimal(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                               addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                               scan_on : Bool, has_provider : Bool, body_focused : Bool) : Nil
      hint = case variant
             when :history
               "──► #{addr} · #{palette_route("browser.open", "Open browser")}#{capturing ? "" : " · tabs: #{key("c", "capture.toggle")}"}"
             when :sitemap
               "◆ proxy #{addr} · #{palette_route("browser.open", "Open browser")}#{capturing ? "" : " · tabs: #{key("c", "capture.toggle")}"}"
             when :intercept
               minimal_intercept_hint(catch_on, body_focused)
             when :repeater
               "^N new · History #{key("^R", "history.repeater")} repeater"
             when :fuzzer
               "^N new · #{key("⇧I", "history.fuzz")} from History"
             when :fuzzer_results
               running ? "sampling…" : "#{key("^R", "fuzz.run")} run · ^O sets"
             when :probe
               scan_on ? "traffic ──► scan · press #{key("m", "probe.mode")}" : "press #{key("m", "probe.mode")} to enable scanning"
             when :issues
               "#{key("⇧F", "issue.create")} from History · #{key("n", "issues.new")} create"
             when :discover
               "Discover here (#{menu("sitemap.discover")}) · #{key("^R", "discover.run")} run"
             when :comparer
               "#{key("a", "comparer.pick-a")} pick A · #{key("b", "comparer.pick-b")} pick B"
             when :authorize
               "Send to Authorize (#{menu("history.authorize")}) · #{key("i", "authorize.identities")} identities"
             when :miner
               "Mine from History/Repeater"
             when :miner_results
               running ? "mining…" : "#{key("^R", "mine.run")} mine this request"
             when :sequencer
               "Send to Sequencer (#{menu("history.sequence")}) · #{key("^R", "sequence.run")}"
             when :sequencer_samples
               running ? "collecting…" : "#{key("c", "sequence.configure")} configure · #{key("^R", "sequence.run")} collect"
             when :oast
               has_provider ? "#{key("g", "oast.generate")} payload · #{key("^R", "oast.listen")} listen" : "^2 Providers — add one first"
             when :notes
               "^N new note · start typing"
             when :project_desc
               "i/↵ describe this engagement · ^E $EDITOR"
             when :project_scope
               "#{key("a", "scope.add-rule")} add rule · space menu"
             when :project_overrides
               "#{key("a", "hostoverride.add-entry")} map host→IP · space menu"
             when :project_env
               "#{key("a", "env.add-var")} add a variable · space menu"
             when :project_activity
               "agent calls & job results land here"
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

    # Three steps, because the first thing a beginner misses is not the proxy but HTTPS: a
    # client pointed at gori with its CA untrusted shows TLS errors and this list stays empty.
    # The address appears once (step 1), and every row is sized into `min_w` so none clips.
    private def render_history_full(screen : Screen, rect : Rect, headline : String,
                                    addr : String, capturing : Bool) : Nil
      inner_h = full_inner_h(:history, capturing: capturing)
      desc = "Requests stream in here as they pass through the proxy."
      steps = ["1 once: set your client's HTTP+HTTPS proxy to",
               "2 HTTPS: trust gori's CA — browse #{Proxy::SelfPage::MAGIC_URL}",
               Hotkeys.retag("  through the proxy, or #{palette_route("ca.export", "Copy CA certificate path")}")]
      browser = "→ #{verb_title("browser.open", "Open browser")}: proxied, CA trusted"
      min_w = (steps + [desc, "    #{addr}", "▸  ^P   #{browser}"]).max_of { |l| Screen.display_width(l) }
      inner, ix, iw = begin_card(screen, rect, :history, headline, "FLOW LOG", inner_h, min_w)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, desc)
      y += 2
      screen.text(ix, y, steps[0], Theme.muted, Theme.bg, width: iw)
      screen.text(ix + 4, y + 1, addr, Theme.accent, Theme.bg, Attribute::Bold, width: {iw - 4, 0}.max)
      screen.text(ix, y + 2, steps[1], Theme.muted, Theme.bg, width: iw)
      screen.text(ix, y + 3, steps[2], Theme.muted, Theme.bg, width: iw)
      y += 4
      unless capturing
        screen.text(ix, y, capture_off_hint, Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      draw_palette_hint(screen, ix, y + 1, iw, bullet: "▸ ", label: browser)
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
        screen.text(ix, y, capture_off_hint, Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      y = draw_palette_hint(screen, ix, y, iw, bullet: "◆ ")
      screen.text(ix, y, "or set your client's HTTP+HTTPS proxy", Theme.muted, Theme.bg, width: iw)
    end

    private def render_intercept_full(screen : Screen, rect : Rect, headline : String,
                                      addr : String, capturing : Bool, catch_on : Bool,
                                      body_focused : Bool, catch_direction : String) : Nil
      inner_h = full_inner_h(:intercept, capturing: capturing)
      catch_key = key("i", "intercept.toggle")
      msg = catch_on ? "Matching traffic pauses here for review before it continues." : "Catch is OFF — #{body_focused ? "press" : "focus body, then press"} #{catch_key} to hold matching requests/responses."
      inner, ix, iw = begin_card(screen, rect, :intercept, headline, "INTERCEPT", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      y += 2
      screen.text(ix, y, "traffic ──► ⏸ hold ──► #{intercept_action_hint(body_focused)}", Theme.muted, Theme.bg, width: iw)
      y += 2
      unless capturing
        screen.text(ix, y, capture_off_hint, Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      direction_chip = body_focused ? " #{key("c", "intercept.direction")}:#{catch_direction} " : " DIR:#{catch_direction} "
      direction_hint = body_focused ? "cycle direction (#{catch_direction})" : "focus body to change direction (#{catch_direction})"
      y = draw_chord_hint(screen, ix, y, iw, direction_chip, direction_hint, bullet: "▸ ",
        verb: body_focused ? "intercept.direction" : nil)
      screen.text(ix, y, intercept_filter_hint(body_focused), Theme.muted, Theme.bg, width: iw)
      y += 1
      draw_palette_hint(screen, ix, y, iw, bullet: "▸ ")
    end

    # "FUZZ RUN", not "RESULTS": this card draws INSIDE the pane the Fuzzer titles RESULTS, and a
    # card wearing its container's name reads as a rendering fault rather than as a nested hint.
    # Every other card already avoided the collision by accident (FLOW LOG in an untitled list,
    # SITE MAP under a HOST / PATH header); the two results-pane variants below take the same
    # verb-shaped name for the same reason.
    private def render_fuzzer_results_full(screen : Screen, rect : Rect, headline : String, running : Bool) : Nil
      inner_h = full_inner_h(:fuzzer_results, running: running)
      msg = running ? "Probes are in flight — hits and status codes land here." : "Add payload sets (^O), then press #{key("^R", "fuzz.run")} to start a fuzz run."
      inner, ix, iw = begin_card(screen, rect, :fuzzer_results, headline, "FUZZ RUN", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      y += 2
      draw_chord_hint(screen, ix, y, iw, " ^R ", running ? "running…" : "run fuzzer", bullet: "▸ ", verb: "fuzz.run") unless running
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
          screen.text(ix, y, capture_off_hint, Theme.yellow, Theme.bg, width: iw)
          y += 1
        end
        y = draw_chord_hint(screen, ix, y, iw, " m:MODE ", "cycle scan mode", bullet: "◇ ", verb: "probe.mode")
        draw_palette_hint(screen, ix, y, iw, bullet: "▸ ")
      else
        draw_wrapped_message(screen, ix, y, iw, desc)
        y += 2
        screen.text(ix, y, hint2, Theme.muted, Theme.bg, width: iw)
        y += 2
        draw_chord_hint(screen, ix, y, iw, " m:MODE ", "turn scanning on", bullet: "◇ ", verb: "probe.mode")
      end
    end

    # One chord line of a card: the ` CHORD ` chip, then the label. A nil `chord` draws the label
    # as a plain indented line instead (the Miner card's closing note).
    record ChordLine, chord : String?, label : String, verb : String? = nil, bullet : String = "▸ "

    # The body two card shapes share: prose, one muted line under it, then the chord lines.
    record CardSpec, title : String, desc : String, line : String, chords : Array(ChordLine)

    # Repeater, Fuzzer, Issues, Discover, Comparer, Authorize, Miner and Sequencer all reach here
    # from a container-level "nothing open yet" branch, so they share that shape: prose, a
    # diagram, a divider, and the chords that open the tab. Each spends exactly `5 + 2` interior
    # rows (Authorize `5 + 3`), which is what `full_inner_h` claims for them. Built per render,
    # not frozen, because the chips resolve through the live registry.
    private def standard_card(variant : Symbol) : CardSpec?
      case variant
      when :repeater
        CardSpec.new("REPEATER", "Edit a captured request and resend it — compare the response.",
          "flow ──► edit ──► send ──► response",
          [ChordLine.new(" ^R ", "repeater from History", "history.repeater"),
           ChordLine.new(" ^N ", "new blank repeater tab")])
      when :fuzzer
        CardSpec.new("FUZZER", "Probe endpoints by swapping §markers§ in a template.",
          "template ──► §payloads§ ──► probe",
          [ChordLine.new(" ^N ", "new fuzz session", bullet: "§ "),
           ChordLine.new(" ⇧I ", "send from History/Repeater", "history.fuzz")])
      when :issues
        CardSpec.new("ISSUES", "Track confirmed vulnerabilities you triage by hand.",
          "flow ──► issue ──► triage ──► resolve",
          [ChordLine.new(" ⇧F ", "issue from History flow", "issue.create"),
           ChordLine.new(" n ", "create an issue here", "issues.new")])
      when :discover
        CardSpec.new("DISCOVER", "Crawl a target for endpoints nothing linked.",
          "target ──► crawl ──► endpoints",
          [ChordLine.new(menu_chip("sitemap.discover"), "\"Discover here\" on a host"),
           ChordLine.new(" ^R ", "run the selected crawl", "discover.run")])
      when :comparer
        CardSpec.new("COMPARER", "Diff two flows side by side — req or res.",
          "A ──► diff ◄── B",
          [ChordLine.new(" a ", "pick flow A", "comparer.pick-a"),
           ChordLine.new(" b ", "pick flow B", "comparer.pick-b")])
      when :authorize
        # THREE chord lines, where the sibling cards take two. Getting a request into the queue
        # and running it are steps the rest of the app implies; choosing who to replay as is the
        # one this tab invented, and a card that omitted it would leave an operator on the two
        # built-in identities with no sign there was a third thing to press.
        CardSpec.new("AUTHORIZE", "Replay one request as several identities and diff the answers.",
          "one request ──► many identities",
          [ChordLine.new(" space ", "\"Send to Authorize\" on a flow"),
           ChordLine.new(" i ", "who to replay as", "authorize.identities"),
           ChordLine.new(" ^R ", "replay what has not run", "authorize.run")])
      when :miner
        CardSpec.new("MINER", "Find undocumented parameters a target takes.",
          "wordlist ──► probe ──► params",
          [ChordLine.new(" space ", "\"Mine parameters\" on a flow"),
           ChordLine.new(nil, "start from History or Repeater")])
      when :sequencer
        CardSpec.new("SEQUENCER", "Collect tokens and measure their randomness.",
          "collect ──► samples ──► entropy",
          [ChordLine.new(" space ", "\"Send to Sequencer\" on a flow"),
           ChordLine.new(" ^R ", "collect samples", "sequence.run")])
      end
    end

    private def render_standard_full(screen : Screen, rect : Rect, variant : Symbol,
                                     headline : String, card : CardSpec) : Nil
      inner, ix, iw = begin_card(screen, rect, variant, headline, card.title, full_inner_h(variant), Screen.display_width(card.desc))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, card.desc)
      y += 2
      screen.text(ix, y, card.line, Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      draw_chord_lines(screen, ix, y, iw, card.chords)
    end

    private def draw_chord_lines(screen : Screen, ix : Int32, y : Int32, iw : Int32, chords : Array(ChordLine)) : Nil
      chords.each do |c|
        if chord = c.chord
          y = draw_chord_hint(screen, ix, y, iw, chord, c.label, bullet: c.bullet, verb: c.verb)
        else
          screen.text(ix + 2, y, c.label, Theme.muted, Theme.bg, width: iw)
        end
      end
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
      draw_chord_hint(screen, ix, y, iw, " ^R ", "start mining", bullet: "▸ ", verb: "mine.run") unless running
    end

    private def render_sequencer_samples_full(screen : Screen, rect : Rect, headline : String, running : Bool) : Nil
      inner_h = full_inner_h(:sequencer_samples, running: running)
      msg = running ? "Collecting — one token per send lands here." : "A run re-sends this request and keeps one token from each response."
      inner, ix, iw = begin_card(screen, rect, :sequencer_samples, headline, "TOKEN RUN", inner_h, Screen.display_width(msg))
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, msg)
      return if running
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " c ", "where the token lives", bullet: "▸ ", verb: "sequence.configure")
      draw_chord_hint(screen, ix, y, iw, " ^R ", "collect samples", bullet: "▸ ", verb: "sequence.run")
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
        y = draw_chord_hint(screen, ix, y, iw, " g ", "get a payload URL (copied)", bullet: "▸ ", verb: "oast.generate")
        draw_chord_hint(screen, ix, y, iw, " ^R ", "start listening", bullet: "▸ ", verb: "oast.listen")
      else
        y = draw_chord_hint(screen, ix, y, iw, " ^2 ", "Providers — interactsh is prefilled", bullet: "▸ ")
        draw_chord_hint(screen, ix, y, iw, " g ", "get a payload URL, once one is on", bullet: "▸ ", verb: "oast.generate")
      end
    end

    # The CENTERED variants: the whole rect goes to `place_art_and_card` — there is no headline
    # row to carve off first (see CENTERED) — and the muted line is a hint, not a diagram.
    private def centered_card(variant : Symbol) : CardSpec?
      case variant
      when :notes
        CardSpec.new("NOTES", "Your project scratchpad — observations, hypotheses, write-ups.",
          "notes stack as sub-tabs · first line becomes the title",
          [ChordLine.new(" ^N ", "new note tab"), ChordLine.new(" ^W ", "close current note")])
      when :project_desc
        # The Project tab's DESCRIPTION sub-tab with nothing written yet. Sibling cards on that
        # tab all name their own emptiness ("no scope rules — press a to add"); this one used to
        # render as pure void, which is why it exists.
        CardSpec.new("PROJECT", "Target, scope, credentials, rules.", "the first thing you read on re-entry",
          [ChordLine.new(" i/↵ ", "start writing"), ChordLine.new(" ^E ", "open in $EDITOR")])
      when :project_scope
        # Titled TARGETS, not SCOPE — the outer card already says SCOPE on its border, and the
        # rules are the list of targets.
        CardSpec.new("TARGETS", "Scope rules mark which hosts you're testing.",
          "incl keeps a host in · excl passes it through",
          [ChordLine.new(" a ", "add an include or exclude rule", "scope.add-rule"),
           ChordLine.new(" space ", "rule actions")])
      when :project_overrides
        # DNS MAP because that is what an entry does — resolve past DNS — where "overrides" only
        # repeats the border.
        CardSpec.new("DNS MAP", "Pin a hostname to a chosen IP for this project.",
          "requests resolve there before real DNS",
          [ChordLine.new(" a ", "map a host to an IP", "hostoverride.add-entry"),
           ChordLine.new(" space ", "override actions")])
      when :project_env
        # The line that names a TOKEN is built at render time (`Env.spell`), not frozen into the
        # source: this card is the first thing an operator reads about the feature, and under
        # the namespaced grammar a `$KEY` here would teach the one spelling that does not
        # resolve. The prefix is a once-a-session setting, so its row is palette-only (#1282):
        # the space menu offers only Add here, and the last bullet names the palette search that
        # finds it, the way `Hotkeys.route` spells any palette-only verb (#1433).
        title = verb_title("env.edit-prefix", "Change prefix")
        CardSpec.new("VARIABLES", "Store values to reuse across requests.",
          "#{Env.spell("KEY", Env::Namespace::Env)} in a request expands when you send",
          [ChordLine.new(" a ", "add a variable", "env.add-var"),
           ChordLine.new(" ^P ", "→ #{title}", "app.palette")])
      when :project_activity
        # Unlike its four neighbours this card asks for nothing: the pane REPORTS. So the
        # bullets name what makes rows appear rather than a key that would create one, and the
        # sentence names the half an operator does not expect to be here — the failures that
        # were recorded without ever raising a notification.
        CardSpec.new("ACTIVITY", "What agents and background jobs did to this project.",
          "including hooks and bindings that failed quietly",
          [ChordLine.new(" s ", "filter by source", "activity.filter-source"),
           ChordLine.new(" space ", "all commands")])
      end
    end

    private def render_centered_full(screen : Screen, rect : Rect, variant : Symbol, card : CardSpec) : Nil
      inner, ix, iw = begin_centered_card(screen, rect, variant, card.title, full_inner_h(variant),
        {Screen.display_width(card.desc), Screen.display_width(card.line)}.max)
      y = inner.y

      draw_wrapped_message(screen, ix, y, iw, card.desc)
      y += 2
      screen.text(ix, y, card.line, Theme.muted, Theme.bg, width: iw)
      y += 2
      draw_chord_lines(screen, ix, y, iw, card.chords)
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

    private def intercept_action_hint(body_focused : Bool) : String
      return "focus body for actions" unless body_focused
      "#{key("f", "intercept.forward")} forward · #{key("d", "intercept.drop")} drop"
    end

    private def intercept_filter_hint(body_focused : Bool) : String
      body_focused ? "▸ #{key("/", "intercept.filter")} condition — filter what gets held" : "▸ focus body to filter what gets held"
    end

    private def medium_intercept_action_hint(body_focused : Bool) : String
      return "focus body to forward, drop or filter held traffic" unless body_focused
      "#{key("f", "intercept.forward")} forward · #{key("d", "intercept.drop")} drop · #{key("/", "intercept.filter")} condition"
    end

    private def minimal_intercept_hint(catch_on : Bool, body_focused : Bool) : String
      if body_focused
        catch_on ? "⏸ queue empty · #{key("i", "intercept.toggle")} catch · #{key("/", "intercept.filter")} filter" : "press #{key("i", "intercept.toggle")} to enable catch"
      elsif catch_on
        "⏸ queue empty · focus body to catch or filter"
      else
        "focus body, then press #{key("i", "intercept.toggle")} to enable catch"
      end
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

    # A palette row reads as the route it is — ` ^P ` → Open browser — never as a ` ^P ` chip
    # that looks like the verb's own chord.
    private def draw_palette_hint(screen : Screen, ix : Int32, y : Int32, iw : Int32, *, bullet : String,
                                  label : String = "→ #{verb_title("browser.open", "Open browser")}") : Int32
      draw_chord_hint(screen, ix, y, iw, " ^P ", label, bullet: bullet, verb: "app.palette")
    end

    # How to reach `verb` (`Tutorial.reach`: its own chord, a menu path, or `^P → <title>`);
    # without a registry, the palette route spelled from `literal`.
    private def palette_route(verb : String, literal : String) : String
      return "^P → #{literal}" unless reg = registry
      Tutorial.reach(reg, verb)
    end

    private def verb_title(verb : String, literal : String) : String
      registry.try(&.[]?(verb)).try(&.title) || literal
    end

    # `literal` as written unless a registry is set and `verb` resolves — then the verb's
    # EFFECTIVE chord, so the card advertises the key the operator rebound. Same fallback
    # rule as Help's verb-id rows (`Hotkeys.binding_label`): unknown/unbound → the literal.
    private def key(literal : String, verb : String) : String
      return literal unless reg = registry
      Hotkeys.binding_label(reg, verb, literal)
    end

    private def capture_off_hint : String
      "capture is OFF — tab bar: press #{key("c", "capture.toggle")} to start"
    end

    # The space-menu path to a menu-only verb (`space → > D`), or "the space menu" without a
    # registry to read it from (`Hotkeys.expand_menu_paths`).
    private def menu(verb : String) : String
      Hotkeys.expand_menu_paths(registry, "{space:#{verb}}")
    end

    # …and the same path as a chip: ` space > D `, or a bare ` space ` without a registry.
    private def menu_chip(verb : String) : String
      keys = registry.try(&.menu_keys(verb))
      keys ? " space #{keys.join(' ')} " : " space "
    end

    # A ` KEY ` or ` KEY:WORD ` chip; with `verb`, KEY is resolved through #key and the
    # `:WORD` half (CATCH/ALL/MODE — a state, not a key) is kept.
    private def chip_text(chord : String, verb : String?) : String
      return chord unless verb
      inner = chord.strip
      k, sep, word = inner.partition(':')
      " #{key(k, verb)}#{sep}#{word} "
    end

    private def draw_chord_hint(screen : Screen, ix : Int32, y : Int32, iw : Int32,
                                chord : String, label : String, *, bullet : String,
                                verb : String? = nil) : Int32
      bg = Theme.bg
      screen.text(ix, y, bullet, Theme.muted, bg)
      bx = ix + bullet.size
      # Claimed-family chips (^N/^W/^P) follow the configured modifier; ^R and the
      # "i:CATCH"-style chips are untouched (retag's token set is closed) — those follow a
      # REBIND instead, through `verb`.
      x = Frame.chip(screen, bx, y, Hotkeys.retag(chip_text(chord, verb)), true) + 1
      screen.text(x, y, " #{label}", Theme.text, bg, width: {ix + iw - x, 0}.max)
      y + 1
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
