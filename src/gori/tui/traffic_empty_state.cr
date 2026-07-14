require "./screen"
require "./theme"
require "./frame"
require "../settings"

module Gori::Tui
  # Rich onboarding panels for tabs with nothing to show yet. Each variant has its
  # own visual voice; the title rides the top edge and the card is centred below it.
  # Degrades gracefully on narrow/short panes (card → plain lines → two-line hint).
  module TrafficEmptyState
    extend self

    FULL_MIN_H =  7
    FULL_MIN_W = 42
    MED_MIN_H  =  5
    MED_MIN_W  = 30

    def render(screen : Screen, rect : Rect, *,
               variant : Symbol,
               listen : String? = nil,
               capturing : Bool = true,
               catch_on : Bool = false,
               running : Bool = false,
               scan_on : Bool = true,
               title : String? = nil) : Nil
      return if rect.empty?

      addr = listen || "#{Settings.effective_bind_host}:#{Settings.effective_bind_port}"
      headline = title || default_title(variant, running: running, scan_on: scan_on)
      min_h = variant == :fuzzer_results ? 5 : FULL_MIN_H

      if rect.h >= min_h && rect.w >= FULL_MIN_W
        render_full(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on)
      elsif rect.h >= MED_MIN_H && rect.w >= MED_MIN_W
        render_medium(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on)
      else
        render_minimal(screen, rect, variant, headline, addr, capturing, catch_on, running, scan_on)
      end
    end

    private def default_title(variant : Symbol, *, running : Bool, scan_on : Bool) : String
      case variant
      when :history        then "waiting for traffic…"
      when :sitemap        then "no traffic captured yet"
      when :intercept      then "no held messages"
      when :repeater         then "no repeater open"
      when :fuzzer         then "no fuzz session open"
      when :fuzzer_results then running ? "running…" : "no results yet"
      when :probe          then scan_on ? "no issues yet" : "scanning is OFF"
      when :issues       then "no issues yet"
      when :notes          then "empty note"
      else                      "nothing here yet"
      end
    end

    private def render_full(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                            addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                            scan_on : Bool) : Nil
      case variant
      when :history        then render_history_full(screen, rect, headline, addr, capturing)
      when :sitemap        then render_sitemap_full(screen, rect, headline, addr, capturing)
      when :intercept      then render_intercept_full(screen, rect, headline, addr, capturing, catch_on)
      when :repeater         then render_repeater_full(screen, rect, headline)
      when :fuzzer         then render_fuzzer_full(screen, rect, headline)
      when :fuzzer_results then render_fuzzer_results_full(screen, rect, headline, running)
      when :probe          then render_probe_full(screen, rect, headline, addr, capturing, scan_on)
      when :issues       then render_issues_full(screen, rect, headline)
      when :notes          then render_notes_full(screen, rect)
      end
    end

    private def render_medium(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                              addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                              scan_on : Bool) : Nil
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
              when :notes
                medium_notes(headline)
              else
                [headline]
              end
      draw_medium_lines(screen, rect, lines)
    end

    private def render_minimal(screen : Screen, rect : Rect, variant : Symbol, headline : String,
                               addr : String, capturing : Bool, catch_on : Bool, running : Bool,
                               scan_on : Bool) : Nil
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
             when :notes
               "^N new note · start typing"
             else
               headline
             end
      screen.text(rect.x + 1, rect.y, headline, Theme.muted, width: {rect.w - 2, 0}.max)
      screen.text(rect.x + 1, rect.y + 2, hint, Theme.muted, width: {rect.w - 2, 0}.max) if rect.h > 2
    end

    # Title rides the top edge; the card is centred in the space below it.
    private def place_centered_card(rect : Rect, card_w : Int32, card_h : Int32) : {Int32, Rect}
      y0 = rect.y
      body = Rect.new(rect.x, y0 + 1, rect.w, {rect.h - 1, 0}.max)
      {y0, place_centered_card_in(body, card_w, card_h)}
    end

    # Card centred in the full rect (no headline row above — used by Notes).
    private def place_centered_card_in(rect : Rect, card_w : Int32, card_h : Int32) : Rect
      card_x = rect.x + {(rect.w - card_w) // 2, 0}.max
      card_y = rect.y + {(rect.h - card_h) // 2, 0}.max
      Rect.new(card_x, card_y, card_w, card_h)
    end

    private def draw_headline(screen : Screen, rect : Rect, y0 : Int32, headline : String) : Nil
      screen.text(rect.x + 1, y0, headline, Theme.muted, width: {rect.w - 2, 0}.max)
    end

    private def begin_card(screen : Screen, rect : Rect, headline : String, card_title : String,
                           inner_h : Int32) : {Int32, Rect, Int32, Int32}
      card_h = inner_h + 2
      card_w = {rect.w - 4, 50}.min.clamp(FULL_MIN_W, rect.w)
      y0, card = place_centered_card(rect, card_w, card_h)
      draw_headline(screen, rect, y0, headline)
      Frame.card(screen, card, card_title, bg: Theme.bg, border: Theme.border)
      inner = card.inset(1, 1)
      ix = inner.x + 1
      iw = {inner.w - 2, 1}.max
      {y0, inner, ix, iw}
    end

    private def render_history_full(screen : Screen, rect : Rect, headline : String,
                                    addr : String, capturing : Bool) : Nil
      # +3 (not +2): the intro/addr/diagram block spans through relative row 3, the
      # divider + palette hint reach row 6, and the final "or set your client's proxy"
      # line lands on row 7 — which the old budget pushed onto the card's bottom border.
      inner_h = 5 + (capturing ? 0 : 1) + 3
      _, inner, ix, iw = begin_card(screen, rect, headline, "FLOW LOG", inner_h)
      y = inner.y

      screen.text(ix, y, "Requests stream in here as they pass through the proxy.", Theme.text, Theme.bg, width: iw)
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
      # +3 (not +2): the final "or set your client's proxy" line lands one row below
      # the palette hint, which the old budget pushed onto the card's bottom border.
      inner_h = 6 + (capturing ? 0 : 1) + 3
      _, inner, ix, iw = begin_card(screen, rect, headline, "SITE MAP", inner_h)
      y = inner.y

      screen.text(ix, y, "Browsing builds a host → path tree from captured traffic.", Theme.text, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "◆ hosts group traffic", Theme.muted, Theme.bg, width: iw)
      y += 1
      screen.text(ix, y, "  └ paths nest under each host", Theme.muted, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "proxy ", Theme.muted, Theme.bg)
      px = ix + "proxy ".size
      screen.text(px, y, addr, Theme.accent, Theme.bg, Attribute::Bold, width: {ix + iw - px, 0}.max)
      y += 2
      unless capturing
        screen.text(ix, y, "capture is OFF — press c to start", Theme.yellow, Theme.bg, width: iw)
        y += 1
      end
      y = draw_palette_hint(screen, ix, y, iw, bullet: "◆ ")
      screen.text(ix, y, "or set your client's HTTP+HTTPS proxy", Theme.muted, Theme.bg, width: iw)
    end

    private def render_intercept_full(screen : Screen, rect : Rect, headline : String,
                                      addr : String, capturing : Bool, catch_on : Bool) : Nil
      inner_h = 5 + (catch_on ? 0 : 1) + 3 + (capturing ? 0 : 1)
      _, inner, ix, iw = begin_card(screen, rect, headline, "INTERCEPT", inner_h)
      y = inner.y

      msg = catch_on ? "Matching traffic pauses here for review before it continues." : "Catch is OFF — press i to hold matching requests/responses."
      screen.text(ix, y, msg, Theme.text, Theme.bg, width: iw)
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
      inner_h = 5 + 2
      _, inner, ix, iw = begin_card(screen, rect, headline, "REPEATER", inner_h)
      y = inner.y

      screen.text(ix, y, "Edit a captured request and resend it — compare the response.", Theme.text, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "flow ──► edit ──► send ──► response", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " ^R ", "repeater from History", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^N ", "new blank repeater tab", bullet: "▸ ")
    end

    private def render_fuzzer_full(screen : Screen, rect : Rect, headline : String) : Nil
      inner_h = 5 + 2
      _, inner, ix, iw = begin_card(screen, rect, headline, "FUZZER", inner_h)
      y = inner.y

      screen.text(ix, y, "Probe endpoints by swapping §markers§ in a template.", Theme.text, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "template ──► §payloads§ ──► probe", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " ^N ", "new fuzz session", bullet: "§ ")
      draw_chord_hint(screen, ix, y, iw, " ⇧I ", "send from History/Repeater", bullet: "▸ ")
    end

    private def render_fuzzer_results_full(screen : Screen, rect : Rect, headline : String, running : Bool) : Nil
      inner_h = running ? 3 : 4
      _, inner, ix, iw = begin_card(screen, rect, headline, "RESULTS", inner_h)
      y = inner.y

      msg = running ? "Probes are in flight — hits and status codes land here." : "Add payload sets (^O), then press ^R to start a fuzz run."
      screen.text(ix, y, msg, Theme.text, Theme.bg, width: iw)
      y += 2
      draw_chord_hint(screen, ix, y, iw, " ^R ", running ? "running…" : "run fuzzer", bullet: "▸ ") unless running
    end

    private def render_probe_full(screen : Screen, rect : Rect, headline : String,
                                  addr : String, capturing : Bool, scan_on : Bool) : Nil
      inner_h = scan_on ? 6 + (capturing ? 0 : 1) + 2 : 4
      _, inner, ix, iw = begin_card(screen, rect, headline, "PROBE", inner_h)
      y = inner.y

      if scan_on
        screen.text(ix, y, "Passive scanning flags issues as traffic flows through the proxy.", Theme.text, Theme.bg, width: iw)
        y += 2
        screen.text(ix, y, "traffic ──► scan ──► issues", Theme.muted, Theme.bg, width: iw)
        y += 2
        screen.text(ix + 2, y, addr, Theme.accent, Theme.bg, Attribute::Bold, width: iw)
        y += 2
        unless capturing
          screen.text(ix, y, "capture is OFF — press c to start", Theme.yellow, Theme.bg, width: iw)
          y += 1
        end
        y = draw_chord_hint(screen, ix, y, iw, " m:MODE ", "cycle scan mode", bullet: "◇ ")
        draw_palette_hint(screen, ix, y, iw, bullet: "▸ ")
      else
        screen.text(ix, y, "Probe is not analyzing traffic while scanning is OFF.", Theme.text, Theme.bg, width: iw)
        y += 2
        screen.text(ix, y, "enable PASSIVE (safe) or ACTIVE to detect issues", Theme.muted, Theme.bg, width: iw)
        y += 2
        draw_chord_hint(screen, ix, y, iw, " m:MODE ", "turn scanning on", bullet: "◇ ")
      end
    end

    private def render_issues_full(screen : Screen, rect : Rect, headline : String) : Nil
      inner_h = 5 + 2
      _, inner, ix, iw = begin_card(screen, rect, headline, "ISSUES", inner_h)
      y = inner.y

      screen.text(ix, y, "Track confirmed vulnerabilities you triage by hand.", Theme.text, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "flow ──► issue ──► triage ──► resolve", Theme.muted, Theme.bg, width: iw)
      y += 2
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Theme.border)
      y += 1
      y = draw_chord_hint(screen, ix, y, iw, " ⇧F ", "issue from History flow", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " n ", "create an issue here", bullet: "▸ ")
    end

    private def render_notes_full(screen : Screen, rect : Rect) : Nil
      inner_h = 5 + 1
      card_h = inner_h + 2
      card_w = {rect.w - 4, 46}.min.clamp(FULL_MIN_W, rect.w)
      card = place_centered_card_in(rect, card_w, card_h)
      Frame.card(screen, card, "NOTES", bg: Theme.bg, border: Theme.border)
      inner = card.inset(1, 1)
      ix = inner.x + 1
      iw = {inner.w - 2, 1}.max
      y = inner.y

      screen.text(ix, y, "Your project scratchpad — observations, hypotheses, write-ups.", Theme.text, Theme.bg, width: iw)
      y += 2
      screen.text(ix, y, "notes stack as sub-tabs · first line becomes the title", Theme.muted, Theme.bg, width: iw)
      y += 2
      y = draw_chord_hint(screen, ix, y, iw, " ^N ", "new note tab", bullet: "▸ ")
      draw_chord_hint(screen, ix, y, iw, " ^W ", "close current note", bullet: "▸ ")
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

    private def medium_notes(headline) : Array(String)
      [headline, "scratchpad for this project", "^N new note · ^W close"]
    end

    private def draw_medium_lines(screen : Screen, rect : Rect, lines : Array(String)) : Nil
      y0 = rect.y
      lines.each_with_index do |line, i|
        y = y0 + i
        break if y >= rect.bottom
        col = i == 0 ? Theme.muted : (i == 1 ? Theme.accent : Theme.muted)
        attr = i == 1 ? Attribute::Bold : Attribute::None
        screen.text(rect.x + 1, y, line, col, attr: attr, width: {rect.w - 2, 0}.max)
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
      x = Frame.chip(screen, bx, y, chord, true) + 1
      screen.text(x, y, " #{label}", Theme.text, bg, width: {ix + iw - x, 0}.max)
      y + 1
    end

    private def fit_history_flow(listen : String, max_w : Int32) : String
      full = "client ──► #{listen} ──► flows"
      return full if full.size <= max_w
      short = "──► proxy ──► flows"
      short.size <= max_w ? short : "──► #{listen} ──►"
    end
  end
end
