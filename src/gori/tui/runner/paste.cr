# Bracketed paste in bulk, and the watchdog for a paste whose end marker never came —
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays,
# and rendering). Split out of runner.cr unchanged: `handle` still owns the two `pasting?`
# transitions that drive everything here.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- bracketed paste, in bulk -------------------------------------------
  #
  # A paste used to arrive as N ordinary keystrokes, and every one of them paid a full edit
  # cycle: an undo snapshot, a highlight invalidation, the Repeater's Content-Length
  # reflection over the whole buffer, a frame. Measured on this build: 8 KB took 3.2s and a
  # 244 KB request several MINUTES, slowing as it went — quadratic in the paste, on the
  # single commonest way a request gets into the tool. Buffered here and inserted once, the
  # cost is proportional to the paste.
  #
  # Only the BODY editor of a tab that says it can take one is eligible: everything else
  # (bottom prompts, pickers, overlays, single-line fields, hex edit) keeps the old
  # per-keystroke path, which is exactly what those surfaces already handle correctly.
  private def begin_bulk_paste? : Bool
    return false unless @focus == :body && @overlay.none? && !modal_overlay?
    return false if @space_menu_open || copy_as_shown? || send_to_shown?
    return false if @goto_open || @search_open || @rename_open || @tag_edit_open
    @tabs[@active_tab]?.try(&.accepts_bulk_paste?) || false
  end

  # Shown when a paste is refused. It names the recovery, because a paste that vanishes
  # without a word is its own bug report.
  PASTE_REFUSED = "paste ignored — nothing focused takes text (i edits the pane, ↵ its fields)"

  # --- a paste whose END MARKER never came ---------------------------------
  #
  # Everything above keys off the two `pasting?` transitions, so a paste that never ends
  # never resolves — and mid-paste BOTH branches eat the keyboard: `@paste_buf` swallows
  # each keystroke into a bulk insert that is never flushed, and `@paste_dropped` discards
  # them outright. The render loop is untouched, so the clock keeps ticking and the badge
  # keeps saying EDITOR while nothing typed has any effect. It reads as a hung app, and it
  # is not recoverable by any key, because keys are what is being swallowed.
  #
  # A terminal can genuinely fail to send `\e[201~` (killed mid-transfer, a dropped ssh
  # session, DEC 2004 switched off under us), and a parser can lose it: termisu did, on
  # every paste, because its end-marker probe skipped the fd whenever the poll budget was
  # spent and the budget is 0 on the very drain its own input source uses (fixed upstream —
  # `read_paste_end_tail`). One dependency bug in the input layer should not be able to
  # present as a dead keyboard, so the state is bounded here regardless of the cause.
  #
  # WHEN to give up is `PasteStall`'s decision, and it lives in its own object rather than
  # inline here because it is the delicate part and `run` needs a tty. Read its comments
  # before touching the re-arm rule — the first version aborted pastes on their opening tick.

  # Shown when the watchdog closed a paste and text really did land. A paste cut short may be
  # incomplete, so (unlike one that simply worked) the operator has reason to look at it.
  PASTE_UNTERMINATED = "paste ended without its end marker — inserted what arrived"

  # Shown when the watchdog closed a paste that was being REFUSED. Nothing was inserted, so
  # "inserted what arrived" would send the operator hunting for text that was deliberately
  # discarded; this names the same recovery `PASTE_REFUSED` does.
  PASTE_UNTERMINATED_REFUSED = "paste ended without its end marker — nothing focused took it"

  # Shown when the paste's marker was the only thing that ever arrived. Distinct from the two
  # above on purpose: at an editor that WOULD have taken the text, "nothing focused took it" is
  # a false accusation, and "inserted what arrived" is a false promise.
  PASTE_UNTERMINATED_EMPTY = "paste ended without its end marker — no content arrived"

  # THE one place a paste's state is torn down, called by BOTH exits: the end marker (in
  # `handle`) and the watchdog. They must not drift — any future close obligation added to one
  # and not the other yields a paste that closes correctly by marker and wrongly by timeout.
  #
  # Returns what became of the clipboard, which is what the watchdog's toast must not get wrong:
  # `:inserted` text landed · `:refused` the focus takes no text · `:empty` only the marker ever
  # came · `:typed` it was being delivered keystroke by keystroke and has already landed.
  private def close_paste : Symbol
    @paste_newline.end_paste
    @paste_stall.closed
    if @paste_dropped
      @paste_dropped = false
      return :refused # a refused paste inserted nothing, by definition
    end
    return :typed unless @paste_buf # no bulk buffer: it went in live, nothing was withheld
    flush_bulk_paste ? :inserted : :empty
  end

  # Close a paste the terminal never closed, and say which kind it was.
  #
  # Clearing `pasting?` matters beyond this paste: left set, the NEXT paste would see no start
  # transition and so would never be offered to `begin_bulk_paste?` or refused by
  # `paste_runs_as_commands?` — a paste at the tab bar running as commands again.
  #
  # THE PARSER'S OWN paste mode has to go with it, and gori's flag is not the only latch. A
  # paste truncated with no trailing ESC leaves `Termisu::Input::Parser` in paste mode with
  # nothing to time out on, and while it is there every later ESC — an arrow key, a mouse
  # report, Escape itself — is probed as a possible end marker for a full second and then
  # delivered as a bare Escape with its bytes spilling out as text keys. Resetting only gori's
  # half left the operator a keyboard that answered a second late, and wrongly.
  private def end_stalled_paste : Bool
    outcome = close_paste
    @term.leave_paste!
    case outcome
    when :inserted then @toast = PASTE_UNTERMINATED
    when :refused  then @toast = PASTE_UNTERMINATED_REFUSED
    when :empty    then @toast = PASTE_UNTERMINATED_EMPTY
      # `:typed` says nothing: the text already went in as it arrived, so there is no loss to
      # report and a toast would only accuse a paste that worked.
    end
    true
  end

  # Whether a bracketed paste arriving NOW would be dispatched as COMMANDS rather than typed
  # into text — the state in which the clipboard's own bytes are hotkeys.
  #
  # THIS IS THE ONE THING A PASTE MUST NEVER DO, and it was the default. `begin_bulk_paste?`
  # only buffers for an editor that is in INSERT; everything else fell through to the
  # per-keystroke path, which is correct for a text field and catastrophic for a keymap.
  # Pasting a request into the Repeater's REQUEST pane in READ mode ran `POST /log` as
  # commands until the `i` of "/login" flipped the pane to INSERT, then typed the rest into
  # the middle of the old request (Content-Length silently re-derived over the wreckage).
  # Pasting the same thing at the tab bar ran the global breath keys: `i` turned INTERCEPT
  # ON, so every subsequent request through the proxy was held, with nothing on screen
  # connecting that to a paste. `c` toggles capture and `q` leaves the project from there.
  #
  # The test is deliberately NARROW, and errs toward delivering the paste: everything modal
  # owns its own keymap and a stray paste inside it is contained, so only the surfaces that
  # reach the SHELL's keymap answer true — the tab bar, the sub-tab strip, and a body that
  # is not currently an editor. `:detail` is in that set for the same reason
  # `drag_press_target?` puts it there: it is a History body drill-in, not a capturing modal,
  # so its keystrokes are the tab's.
  #
  # `body_badge == :editor` is the controllers' own answer to "does this pane capture text",
  # which is exactly the question (see `TabController#body_badge`) — so every field the
  # per-keystroke path serves today keeps serving it: the Repeater TARGET/SNI rows and hex
  # edit, the Decoder INPUT and CHAIN, Notes, the Project description, the Issues notes, the
  # JWT input, the Fuzzer target. The sub-tab filter row reports through its own predicate.
  private def paste_runs_as_commands? : Bool
    return false unless @overlay.none? || @overlay.detail?
    return false if modal_overlay? # palette / ⋯ menu / any migrated modal
    return false if @space_menu_open || copy_as_shown? || send_to_shown?
    return false if @goto_open || @search_open || @rename_open || @tag_edit_open
    return false if @tabs[@active_tab]?.try(&.subtab_filter_editing?)
    return false if @focus == :body && @tabs[@active_tab]?.try(&.body_badge) == :editor
    true
  end

  # Accumulate one pasted keystroke, or false when this event is not part of a bulk paste
  # (the caller then delivers it normally).
  #
  # TEXT only — printable characters, the Enter the CRLF filter left behind, and Tab, which
  # is a legal byte in a header value and which the request editors type literally anyway.
  # An arrow or a function key inside a paste is a terminal handing us bytes the clipboard
  # never had as text; the per-keystroke path would have MOVED THE CARET mid-paste and
  # scattered the rest of the clipboard around the buffer, so dropping it is both cheaper
  # and closer to what the operator asked for.
  private def buffer_bulk_paste(ev : Termisu::Event::Key) : Bool
    buf = @paste_buf
    return false unless buf
    key = ev.key
    if key.enter?
      buf << '\n'
    elsif key.tab?
      buf << '\t'
    elsif (c = ev.char) && !ev.ctrl? && !ev.alt? && !c.control?
      buf << c
    end
    true
  end

  # Hand the accumulated paste to the focused tab as ONE edit — or, if the tab refuses,
  # REPLAY it keystroke by keystroke exactly as it would have arrived without buffering.
  #
  # The replay is what makes the fast path safe to attempt: a tab can decline on something
  # only it can see (a `§` in the clipboard, whose per-character marker guard cannot be
  # expressed as one splice) and lose nothing but the speed-up. Without it, "the tab said
  # no" would mean "the paste vanished".
  # Returns whether any text actually reached the buffer — false when this paste was being
  # delivered keystroke by keystroke (nothing was accumulated) or when the marker arrived with
  # nothing between it and the start, which is what the watchdog's toast has to distinguish.
  private def flush_bulk_paste : Bool
    buf = @paste_buf
    @paste_buf = nil
    return false unless buf
    text = buf.to_s
    return false if text.empty?
    return true if @tabs[@active_tab]?.try(&.paste_text(text))
    replay_paste(text)
    true
  end

  # Deliver `text` through the ordinary key path, one synthesized keystroke per character —
  # the same events the terminal would have produced, so every guard, confirm and escape
  # the editors apply while typing applies here too.
  private def replay_paste(text : String) : Nil
    text.each_char do |c|
      ev = case c
           when '\n' then Termisu::Event::Key.new(Termisu::Input::Key::Enter, char: '\r')
           when '\t' then Termisu::Event::Key.new(Termisu::Input::Key::Tab)
           else           Termisu::Event::Key.new(Termisu::Input::Key::Unknown, char: c)
           end
      handle_key(ev)
    end
  end
end
