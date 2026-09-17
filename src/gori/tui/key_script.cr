require "termisu"

module Gori::Tui
  # A keystroke script: the text form of "and then press these", for a driver that feeds a
  # Runner instead of a terminal doing it.
  #
  # The grammar is tmux's `send-keys`, because that is the one an operator already knows and
  # already has muscle memory for — whitespace-separated tokens, named keys spelled out
  # (`Enter`, `PgDn`, `F7`), modifiers as `C-`/`M-`/`S-` prefixes, and a `"quoted run"` typed
  # verbatim. The one addition is `SLEEP<seconds>`, which has no tmux equivalent because tmux
  # has a shell to put a `sleep` in.
  #
  # PARSING HAPPENS BEFORE ANYTHING OPENS. Every rejection here is a `Gori::Error` naming the
  # token, raised while the caller still has nothing to tear down — a script with a typo in its
  # last key must not first open a project, bind a layer of process globals and draw a frame.
  module KeyScript
    # One token's worth of input. A plain key is one event; a quoted run is one event per
    # character (so "type this" stays one step and one intent); a `SLEEP` is no events and a
    # pause. Kept as a step rather than flattened to events because the pause has to sit
    # BETWEEN two runs, and a flat event list has nowhere to put it.
    record Step, events : Array(Termisu::Event::Key), pause : Time::Span? = nil

    # The keys a terminal delivers as themselves rather than as a character. Looked up
    # case-insensitively: `PgDn`, `pgdn` and `PGDN` are the same key, and no named key is one
    # character long, so this can never shadow a bare printable token.
    NAMED = begin
      t = {
        "enter"  => Termisu::Input::Key::Enter,
        "tab"    => Termisu::Input::Key::Tab,
        "escape" => Termisu::Input::Key::Escape,
        "up"     => Termisu::Input::Key::Up,
        "down"   => Termisu::Input::Key::Down,
        "left"   => Termisu::Input::Key::Left,
        "right"  => Termisu::Input::Key::Right,
        "home"   => Termisu::Input::Key::Home,
        "end"    => Termisu::Input::Key::End,
        "pgup"   => Termisu::Input::Key::PageUp,
        "pgdn"   => Termisu::Input::Key::PageDown,
        "bspace" => Termisu::Input::Key::Backspace,
        "space"  => Termisu::Input::Key::Space,
        "delete" => Termisu::Input::Key::Delete,
        "insert" => Termisu::Input::Key::Insert,
      } of String => Termisu::Input::Key
      12.times { |i| t["f#{i + 1}"] = Termisu::Input::Key.parse("F#{i + 1}") }
      t
    end

    # The longest single `SLEEP`, and the longest a whole script may spend paused.
    #
    # A pause is the one token that costs WALL TIME, and it is unbounded input: `SLEEP99999` on
    # the MCP tool parks that server's worker fiber — which dispatches one request at a time —
    # for a day, and on `gori run screenshot` it hangs a script nobody can tell from a deadlock.
    # Both caps, because one long pause and sixty short ones are the same outcome.
    #
    # 5s is far past what a render waits for anyway: the only thing a pause settles here is the
    # scheduler (see `Headless.render`), and nothing arriving from outside is awaited at all.
    MAX_SLEEP       = 5.seconds
    MAX_TOTAL_PAUSE = 30.seconds

    def self.parse(script : String) : Array(Step)
      steps = [] of Step
      total = Time::Span.zero
      each_token(script) do |token, quoted|
        step = quoted ? typed_run(token) : key_step(token)
        if pause = step.pause
          total += pause
          if total > MAX_TOTAL_PAUSE
            raise Gori::Error.new(
              "key script: the pauses add up to #{total.total_seconds.round(2)}s, past the " \
              "#{MAX_TOTAL_PAUSE.total_seconds.to_i}s a script may spend waiting — a render " \
              "only yields to the scheduler, it does not await anything arriving from outside")
          end
        end
        steps << step
      end
      steps
    end

    # Split on whitespace, except inside `"…"`. `\"` and `\\` escape themselves, so a run
    # containing a quote is expressible rather than silently truncated. An unterminated quote
    # is an error and not "to end of script": the intent was a bounded run, and guessing where
    # it ends would type the rest of the script into a text field.
    private def self.each_token(script : String, & : String, Bool ->) : Nil
      chars = script.chars
      i = 0
      while i < chars.size
        if chars[i].whitespace?
          i += 1
        elsif chars[i] == '"'
          text, i = scan_quoted(chars, i + 1)
          yield text, true
        else
          start = i
          while i < chars.size && !chars[i].whitespace?
            i += 1
          end
          yield chars[start...i].join, false
        end
      end
    end

    # The body of a `"…"` run plus the index just past its closing quote.
    private def self.scan_quoted(chars : Array(Char), i : Int32) : {String, Int32}
      buf = String::Builder.new
      while i < chars.size
        ch = chars[i]
        if ch == '\\' && i + 1 < chars.size && (chars[i + 1] == '"' || chars[i + 1] == '\\')
          buf << chars[i + 1]
          i += 2
        elsif ch == '"'
          return {buf.to_s, i + 1}
        else
          buf << ch
          i += 1
        end
      end
      raise Gori::Error.new("key script: unterminated quoted run — add the closing \"")
    end

    # A quoted run: typed verbatim, one event per character, all in one step.
    private def self.typed_run(text : String) : Step
      Step.new(text.chars.map { |c| printable(c) })
    end

    private def self.key_step(token : String) : Step
      if pause = sleep_span?(token)
        # No events: the driver's only job here is to let the scheduler run. What that does and
        # does not settle is documented on `Headless.render`.
        return Step.new([] of Termisu::Event::Key, pause)
      end
      Step.new([key_event(token)])
    end

    private def self.sleep_span?(token : String) : Time::Span?
      return nil unless token.size > 5 && token[0, 5].compare("SLEEP", case_insensitive: true) == 0
      raw = token[5..]
      secs = raw.to_f64?
      raise Gori::Error.new("key script: #{token.inspect} — SLEEP takes seconds, e.g. SLEEP0.5") if secs.nil? || secs < 0
      if secs > MAX_SLEEP.total_seconds
        raise Gori::Error.new(
          "key script: #{token.inspect} — one SLEEP may pause at most " \
          "#{MAX_SLEEP.total_seconds.to_i}s. A render yields to the scheduler and awaits " \
          "nothing arriving from outside, so a longer wait photographs the same frame")
      end
      (secs * 1000).round.to_i64.milliseconds
    end

    # Strip the `C-`/`M-`/`S-` prefixes off `token`, in any order and at most one of each
    # (`C-M-x` is Ctrl+Alt+x), and return what they said plus what is left to name a key.
    # Shift comes back separately from `mods` because a shifted letter is NOT delivered with a
    # Shift flag — see `printable`.
    private def self.split_modifiers(token : String) : {Termisu::Input::Modifier, Bool, String}
      mods = Termisu::Input::Modifier::None
      shift = false
      rest = token
      while rest.size > 2 && rest[1] == '-'
        case rest[0]
        when 'C', 'c'
          raise Gori::Error.new("key script: #{token.inspect} repeats C-") if mods.ctrl?
          mods |= Termisu::Input::Modifier::Ctrl
        when 'M', 'm'
          raise Gori::Error.new("key script: #{token.inspect} repeats M-") if mods.alt?
          mods |= Termisu::Input::Modifier::Alt
        when 'S', 's'
          raise Gori::Error.new("key script: #{token.inspect} repeats S-") if shift
          shift = true
        else
          break
        end
        rest = rest[2..]
      end
      {mods, shift, rest}
    end

    private def self.key_event(token : String) : Termisu::Event::Key
      mods, shift, rest = split_modifiers(token)

      if named = NAMED[rest.downcase]?
        # A shifted named key is not a thing a terminal sends as "that key plus Shift". ⇧Tab in
        # particular arrives as its OWN key (BackTab), which `Keybind.from_event` maps to no
        # chord at all — so a script spelling one would press nothing and report success.
        raise Gori::Error.new(shift_named_refusal(token, rest)) if shift
        return Termisu::Event::Key.new(named, mods, nil)
      end

      if rest.compare("BTab", case_insensitive: true) == 0
        raise Gori::Error.new(
          "key script: #{token.inspect} — BTab (⇧Tab) arrives as its own key and `Keybind.from_event` " \
          "maps it to no chord, so it would drive nothing. Use Tab.")
      end

      unless rest.size == 1
        raise Gori::Error.new(
          "key script: #{token.inspect} is not a key — expected one character, a named key " \
          "(#{NAMED.keys.join(", ")}), or SLEEP<seconds>")
      end

      c = rest[0]
      unless c.ascii? && !c.ascii_control?
        raise Gori::Error.new("key script: #{token.inspect} — only printable ASCII is typeable; use a named key")
      end

      if shift
        # A shifted LETTER is the capital with no Shift flag — the shape the event path actually
        # produces, which `Keybind.from_event` then re-derives shift from. A shifted symbol or
        # digit is the shifted CHARACTER itself (`?`, `!`), so there is nothing for `S-` to mean.
        unless c.ascii_letter?
          raise Gori::Error.new(
            "key script: #{token.inspect} — a terminal sends ⇧#{c} as the shifted character itself; " \
            "spell that character instead")
        end
        raise Gori::Error.new("key script: #{token.inspect} — S- does not combine with C-/M-") unless mods.none?
        return printable(c.upcase)
      end

      # Ctrl carries NO character: the parser branch that produces a control chord reports the
      # key alone, and attaching one here would make `ev.char` truthy in every editor that
      # checks it before the keymap does.
      return Termisu::Event::Key.new(Termisu::Input::Key.from_char(c.downcase), mods, nil) if mods.ctrl?
      Termisu::Event::Key.new(Termisu::Input::Key.from_char(c.downcase), mods, c)
    end

    private def self.shift_named_refusal(token : String, rest : String) : String
      if rest.compare("Tab", case_insensitive: true) == 0
        "key script: #{token.inspect} — ⇧Tab arrives as BackTab, which `Keybind.from_event` maps " \
        "to no chord, so it would drive nothing. Use Tab."
      else
        "key script: #{token.inspect} — a named key carries no Shift; drop the S-"
      end
    end

    # The event a terminal delivers for a typed character: the LOWERCASE key plus the character
    # as typed. A capital is exactly that — `Key::LowerF` with `char: 'F'` — and not
    # `Key::UpperF` with a Shift flag, which is what a hand-built event usually gets wrong (see
    # `spec/spec_helper.cr`'s `typed_key_event`, which builds the same shape for the same
    # reason).
    private def self.printable(c : Char) : Termisu::Event::Key
      Termisu::Event::Key.new(Termisu::Input::Key.from_char(c.downcase),
        Termisu::Input::Modifier::None, c)
    end
  end
end
