require "json"
require "./workbench_controller"
require "../subtab_clone"
require "../cookie_view"
require "../../cookie"
require "../../fuzz/payload"

module Gori::Tui
  # One Cookie workbench session (a sub-tab). On top of the shared DECODE side and FORGE
  # PAYLOAD + SECRET (`WorkbenchSession`), the FORGE lens adds format/algorithm/salt, and the
  # decode caches the detected format and the live verify/crack verdict. Mutable class.
  class CookieSession < WorkbenchSession(CookieView)
    property salt : String = ""
    property salt_cx : Int32 = 0
    property salt_pre : String = ""
    property format : String = "auto"      # auto | flask | rack | django
    property algorithm : String = "sha256" # sha256 | sha1 (Django only)
    # False until the operator cycles the algorithm by hand. While false, a Django cookie's
    # algorithm is inferred from its signature length (sha1 = 20 bytes, sha256 = 32) — the
    # same "auto until you pin it" contract `format` has — so a real SHA-1 `sessionid` does
    # not read as ✗ bad key under the SHA-256 default. Cycling the algo pins the choice.
    property? algorithm_pinned : Bool = false
    # Cached results (recomputed on edit, never on the render hot path).
    property detected : String? = nil      # the auto-detected format, for the FORGE promotion
    property verify_state : Symbol = :none # :none | :ok | :bad
    property crack_note : String? = nil    # "cracked: …" set by a successful crack, cleared on edit
  end

  # The Cookie tab: a hidden workbench for decoding, verifying, cracking, and re-signing
  # framework signed session cookies (Flask/itsdangerous, Rack, Django). The shell is
  # `WorkbenchController`'s, shared with the JWT tab (^N new · ^W close · ^T lens); `^A`
  # cycles the format.
  class CookieController < WorkbenchController(CookieSession)
    DECODE_PANES = [:input, :decoded, :opts, :secret]
    FORGE_PANES  = [:payload, :opts, :secret, :output]
    # ^A cycles these. DECODE includes `auto` (it can detect from the punctuation); FORGE
    # cannot — minting needs a concrete scheme — so it steps the three real formats only.
    DECODE_FORMATS = ["auto", "flask", "rack", "django"]
    FORGE_FORMATS  = ["flask", "rack", "django"]
    ALGORITHMS     = ["sha256", "sha1"]

    def tab : Symbol
      :cookie
    end

    def command_scope : Verb::Scope
      Verb::Scope::Cookie
    end

    private def make_session(input_text : String, name : String?) : CookieSession
      s = CookieSession.new(input_text, name)
      s.view.set_registry(@host.session.registry)
      recompute_decode(s)
      recompute_output(s)
      s
    end

    private def tool_label : String
      "Cookie"
    end

    private def item_noun : String
      "cookie"
    end

    private def lens_verb : String
      "cookie.toggle-mode"
    end

    # The ⌕ picker searches the DECODED parts + the FORGE payload, not the opaque cookie the
    # summary carries — an operator remembers a cookie by something inside it (a username, a
    # flag), never by its base64. Both, so either direction is findable by what it says.
    def subtab_search_extras : Array(String)
      @sessions.map { |s| search_extra("#{s.decoded} #{s.payload.text}") }
    end

    # The chip label's fallback: the cookie's format (or "empty").
    private def session_summary(s : CookieSession) : String
      return "empty" if s.input.text.strip.empty?
      (f = s.detected) ? "cookie #{f}" : "cookie"
    end

    private def duplicate_at(idx : Int32) : Nil
      return unless src = @sessions[idx]?
      dup = make_session(src.input.text, SubtabClone.copy_name(src.view.name))
      dup.payload.set_text(src.payload.text)
      dup.secret = src.secret
      dup.salt = src.salt
      dup.format = src.format
      dup.algorithm = src.algorithm
      dup.algorithm_pinned = src.algorithm_pinned?
      recompute_decode(dup)
      recompute_output(dup)
      @sessions << dup
      @idx = @sessions.size - 1
    end

    # --- render ---
    # The shared shell (see `WorkbenchController#render_shell` for why it is not inherited).
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      render_shell(screen, rect, focus)
    end

    private def render_lens(screen : Screen, body : Rect, s : CookieSession, focused : Bool) : Nil
      if s.mode == :decode
        s.view.render_decode(screen, body,
          input: s.input, input_mode: s.input_mode, input_read: s.input_read,
          decoded: s.decoded, format: display_format(s), resolved_format: effective_format(s),
          algorithm: effective_algorithm(s), salt: s.salt, salt_cx: s.salt_cx, salt_pre: s.salt_pre,
          salt_preset: salt_preset_label(s),
          verify_state: s.verify_state, crack_note: s.crack_note,
          secret: s.secret, secret_cx: s.secret_cx, secret_pre: s.secret_pre,
          pane: s.pane, focused: focused, lens_chord: lens_chord)
      else
        s.view.render_forge(screen, body,
          payload: s.payload, format: display_format(s), resolved_format: effective_format(s),
          algorithm: effective_algorithm(s), salt: s.salt, salt_cx: s.salt_cx, salt_pre: s.salt_pre,
          salt_preset: salt_preset_label(s),
          secret: s.secret, secret_cx: s.secret_cx, secret_pre: s.secret_pre,
          output: s.output, output_ok: s.output_ok?,
          pane: s.pane, focused: focused, lens_chord: lens_chord)
      end
    end

    # --- key handling ---
    # DECODED / OUTPUT are read-only; INPUT is INS/READ; PAYLOAD, OPTS (salt) and SECRET type.
    private def readonly_pane?(pane : Symbol) : Bool
      {:decoded, :output}.includes?(pane)
    end

    private def lens_editor(s : CookieSession, pane : Symbol) : TextArea?
      s.payload if pane == :payload
    end

    private def route_pane(ev : Termisu::Event::Key, c : Char?) : Bool
      case cur.pane
      when :input   then edit_input(ev, c)
      when :payload then edit_lens_editor(ev, c, cur.payload); true
      when :opts    then edit_salt(ev, c); true
      when :secret  then edit_secret(ev, c); true
      when :decoded then handle_readonly(ev, :decoded)
      when :output  then handle_readonly(ev, :output)
      else               true
      end
    end

    # ---- SALT single-line field (OPTIONS pane) ----
    private def edit_salt(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      case ev.key
      when .up?   then cross_pane(s, -1)
      when .down? then cross_pane(s, 1)
      else
        text, cx, changed = line_field_key(ev, c, s.salt, s.salt_cx)
        s.salt = text
        s.salt_cx = cx
        if changed
          s.salt_pre = ""
          recompute_all(s)
        end
      end
    end

    # Editing the SECRET clears a stale crack note (the field no longer holds what cracked) and
    # re-runs the live verify + re-forge under the new key.
    private def on_secret_edit(s : CookieSession) : Nil
      s.crack_note = nil
      recompute_verify(s)
      recompute_output(s)
    end

    # --- focus ring ---
    private def panes(s : CookieSession) : Array(Symbol)
      s.mode == :decode ? DECODE_PANES : FORGE_PANES
    end

    # --- mouse (the editable TextArea only: INPUT in decode, PAYLOAD in forge) ---
    private def editor_at(rect : Rect, mx : Int32, my : Int32) : {TextArea, Rect, TextReadState?}?
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, _, _, _ = s.view.decode_layout(body)
        return nil unless input_c.contains?(mx, my) && my > input_c.y
        {s.input, input_c.inset(1, 1), s.input_mode == InputMode::Insert ? nil : s.input_read}
      else
        pay_c, _, _, _ = s.view.forge_layout(body)
        return nil unless pay_c.contains?(mx, my) && my > pay_c.y
        {s.payload, pay_c.inset(1, 1), nil}
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, dec_c, opts_c, sec_c = s.view.decode_layout(body)
        if input_c.contains?(mx, my)
          click_input_card(s, input_c, mx, my)
        elsif dec_c.contains?(mx, my)
          enter_pane(s, :decoded)
        elsif opts_c.contains?(mx, my)
          enter_pane(s, :opts)
          click_opts_badge(s, opts_c, mx, my)
        elsif sec_c.contains?(mx, my)
          enter_pane(s, :secret)
        end
      else
        pay_c, opts_c, sec_c, out_c = s.view.forge_layout(body)
        if pay_c.contains?(mx, my)
          enter_pane(s, :payload)
          if s.view.lens_chip_hit(pay_c, mx, my, :forge, lens_chord)
            toggle_mode
          else
            s.payload.click_to_cursor(pay_c.inset(1, 1), mx, my)
          end
        elsif opts_c.contains?(mx, my)
          enter_pane(s, :opts)
          click_opts_badge(s, opts_c, mx, my)
        elsif sec_c.contains?(mx, my)
          enter_pane(s, :secret)
        elsif out_c.contains?(mx, my)
          enter_pane(s, :output)
        end
      end
      true
    end

    private def click_opts_badge(s : CookieSession, opts_c : Rect, mx : Int32, my : Int32) : Nil
      case s.view.opts_badge_hit(opts_c, mx, my, display_format(s), effective_format(s),
        effective_algorithm(s), salt_preset_label(s))
      when :format    then cycle_format
      when :algorithm then cycle_algorithm
      when :salt      then cycle_salt_preset
      end
    end

    # Pointer-aware: the card under the cursor scrolls, keyboard focus stays put. The same
    # lens layouts `handle_click` hit-tests with.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      s = cur
      body = body_rect_below_filter(rect)
      pane =
        if s.mode == :decode
          input_c, dec_c, _, _ = s.view.decode_layout(body)
          case
          when input_c.contains?(mx, my) then :input
          when dec_c.contains?(mx, my)   then :decoded
          else                                s.pane
          end
        else
          pay_c, _, _, out_c = s.view.forge_layout(body)
          case
          when pay_c.contains?(mx, my) then :payload
          when out_c.contains?(mx, my) then :output
          else                              s.pane
          end
        end
      wheel_pane(s, pane, step)
      true
    end

    private def wheel_pane(s : CookieSession, pane : Symbol, step : Int32) : Nil
      case pane
      when :decoded then s.view.scroll_decoded(step)
      when :output  then s.view.scroll_output(step)
      when :input   then s.input.scroll_view(step)
      when :payload then s.payload.scroll_view(step)
      end
    end

    def set_preedit(text : String) : Bool
      s = cur
      case s.pane
      when :input   then s.input.set_preedit(text) if s.input_mode == InputMode::Insert
      when :payload then s.payload.set_preedit(text)
      when :opts    then s.salt_pre = text
      when :secret  then s.secret_pre = text
      end
      true
    end

    # --- verbs / actions ---
    def toggle_mode : Nil
      s = cur
      if s.mode == :decode
        s.mode = :forge
        s.pane = :payload
        recompute_output(s)
      else
        s.mode = :decode
        s.pane = :input
      end
      @host.status(s.mode == :forge ? "FORGE lens" : "DECODE lens")
    end

    def cycle_format : Nil
      s = cur
      list = s.mode == :forge ? FORGE_FORMATS : DECODE_FORMATS
      # Step from what the OPTIONS badge actually shows: in FORGE that is the resolved concrete
      # format (never `auto`), so `^A` advances from there rather than jumping to Flask. `auto`
      # is not in FORGE_FORMATS, so a first `^A` in FORGE lands on the next real format.
      i = list.index(display_format(s)) || -1
      s.format = list[(i + 1) % list.size]
      recompute_all(s)
      @host.status("format = #{s.format}")
    end

    def cycle_algorithm : Nil
      s = cur
      # Step from what is CURRENTLY in effect — the inferred algorithm when it was auto, so the
      # first cycle moves off the detected one rather than jumping back to the sha256 default —
      # and pin the choice so detection no longer overrides it.
      i = ALGORITHMS.index(effective_algorithm(s)) || 0
      s.algorithm = ALGORITHMS[(i + 1) % ALGORITHMS.size]
      s.algorithm_pinned = true
      recompute_all(s)
      @host.status(effective_format(s) == "django" ? "algorithm = #{s.algorithm}" : "algorithm = #{s.algorithm} (Django only)")
    end

    # Flip the Django salt field between the session-backend salt and the generic signing salt.
    # A Django `sessionid` cookie — the "crack the key, forge an admin session" target — signs
    # under SESSION_SALT, NOT the default `django.core.signing`, so a blank field silently
    # verifies/forges under the wrong salt and the correct secret reads as ✗ bad key. This writes
    # the CONCRETE salt string into the field so decode/verify/crack/forge all sign under the
    # salt the badge names. Django only (Flask's salt is fixed; Rack has none).
    def cycle_salt_preset : Nil
      s = cur
      unless effective_format(s) == "django"
        @host.status("salt presets are Django-only")
        return
      end
      s.salt = s.salt.strip == Cookie::Django::SESSION_SALT ? Cookie::Django::DEFAULT_SALT : Cookie::Django::SESSION_SALT
      s.salt_cx = s.salt.size
      s.salt_pre = ""
      recompute_all(s)
      @host.status("salt = #{salt_preset_label(s)} (#{s.salt})")
    end

    # The salt badge's label: which canonical Django salt is in effect. A blank field signs under
    # the signing default, so it reads "signing"; a hand-typed salt that is neither canonical one
    # reads "custom".
    def salt_preset_label(s : CookieSession) : String
      case s.salt.strip
      when Cookie::Django::SESSION_SALT     then "session"
      when "", Cookie::Django::DEFAULT_SALT then "signing"
      else                                       "custom"
      end
    end

    # Crack the signing secret over the SECRET field, read as a wordlist SOURCE: a path to an
    # existing file is a wordlist, anything else is a comma-separated inline candidate list (a
    # lone secret is a one-element list — the same verify, said as a crack). On success the
    # field is replaced with the winning secret and the verify state flips to ✓.
    def crack : Nil
      s = cur
      # Cracks the DECODE INPUT cookie, so it runs from the DECODE lens only — `c` reaches here
      # from the FORGE OUTPUT pane too (both are read panes), where cracking the hidden input and
      # swapping out the secret the OUTPUT is signed under would be an invisible side effect.
      unless s.mode == :decode
        @host.status("crack runs from the DECODE lens")
        return
      end
      token = s.input.text.strip
      if token.empty?
        @host.status("INPUT is empty — paste a cookie to crack")
        return
      end
      spec = s.secret.strip
      if spec.empty?
        @host.status("SECRET is empty — enter a wordlist path or a comma-separated candidate list")
        return
      end
      source = crack_source(spec)
      found = Cookie.crack(token, source, decode_format(s), salt: effective_salt(s), algorithm: effective_algorithm(s))
      if found
        s.secret = found
        s.secret_cx = found.size
        s.crack_note = "cracked: #{found.size > 24 ? found[0, 23] + "…" : found}"
        recompute_verify(s)
        recompute_output(s)
        @host.status("cracked the signing secret")
      else
        # No `source.size` here: for a WordlistFile that re-reads the whole file just to print a
        # count, doubling the I/O of the crack that already scanned it.
        s.crack_note = nil
        @host.status("no candidate verified")
      end
    rescue ex : Gori::Error
      @host.status("crack: #{ex.message}")
    end

    # A file path → a lazily-read wordlist; anything else → the comma-split inline list. A path
    # that does not exist is treated as a one/many-element inline candidate list, not an error:
    # a bare secret typed into the field must still crack (as itself).
    private def crack_source(spec : String) : Fuzz::PayloadSource
      return Fuzz::WordlistFile.new(spec) if File.file?(spec)
      Fuzz::InlineList.new(spec.split(',').map(&.strip).reject(&.empty?))
    end

    # Seed the FORGE payload editor from the DECODE input's parsed payload + switch to FORGE.
    def load_decoded : Nil
      s = cur
      token = s.input.text.strip
      if token.empty?
        @host.status("INPUT is empty — nothing to load")
        return
      end
      # `RawJson`, not `JSON.parse`: the decoded payload keeps a number past Int64 as its digits
      # (#1200), and the forge editor must be seeded with those digits, not a parse failure.
      json = (Cookie.decode_json(token, decode_format(s)) rescue nil)
      doc = json.try { |j| Gori::RawJson.claims(j) }
      unless json && doc
        @host.status("INPUT is not a decodable cookie")
        return
      end
      fmt = doc["format"]?.try(&.as_s?)
      s.format = fmt if fmt && FORGE_FORMATS.includes?(fmt)
      if effective_format(s) == "rack"
        s.payload.set_text(doc["value_base64"]?.try(&.as_s?) || "")
      elsif (pl = doc["payload"]?) && !pl.raw.nil?
        raw = Gori::RawJson.members(json).try(&.reverse_each.find { |(k, _)| k == "payload" }).try(&.[1])
        s.payload.set_text(raw ? Gori::RawJson.reformat(raw, "  ") : pl.to_pretty_json)
      else
        s.payload.set_text("")
      end
      s.mode = :forge
      s.pane = :payload
      recompute_output(s)
      @host.status("loaded decoded payload into FORGE")
    end

    # Clearing drops the cookie, the FORGE payload, the secret and the salt, and
    # `TextArea#set_text` empties each editor's undo stack with them — so it asks first, the
    # way `notes_clear` does. A session with nothing in it clears without the prompt.
    def clear_all : Nil
      s = cur
      return clear_session(s) if session_blank?(s)
      @host.confirm("CLEAR SESSION", "Clear this session's cookie, payload, secret and salt?\nThis can't be undone.",
        confirm_label: "clear", danger: true) { clear_session(s) }
    end

    private def session_blank?(s : CookieSession) : Bool
      s.input.text.empty? && s.payload.text.empty? && s.secret.empty? && s.salt.empty?
    end

    private def clear_session(s : CookieSession) : Nil
      s.input.set_text("")
      s.payload.set_text("")
      s.secret = ""
      s.secret_cx = 0
      s.salt = ""
      s.salt_cx = 0
      s.crack_note = nil
      recompute_decode(s)
      recompute_output(s)
      @host.status("cleared")
    end

    # The unified Copy verb's text (see `WorkbenchController#copy_pane`).
    def pane_copy_text : String
      s = cur
      case s.pane
      when :input   then input_copy_text(s)
      when :payload then band_or_all(s.payload)
      when :opts    then s.salt
      when :secret  then s.secret
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      else               ""
      end
    end

    def selection_text : String
      s = cur
      case s.pane
      when :input   then input_selection_text(s)
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      else               ""
      end
    end

    def body_hint(focus : Symbol) : String
      s = cur
      reg = @host.session.registry
      ov = Hotkeys.rebindable_overrides(reg)
      y = Hotkeys.binding_label(reg, "cookie.copy", "y", ov)
      lens = lens_chord(reg, ov)
      case s.pane
      when :input
        if s.input_mode == InputMode::Insert
          keys("type a cookie · ⇧arrows select · ^Y copy · esc read · ↓ decoded · #{lens} forge · {cookie.cycle-format} format · {cookie.clear} clear · ↑ sub-tabs")
        else
          keys("{editor.insert}/↵ edit · {cookie.crack} crack · #{y} copy · space cmds · ↓ decoded · #{lens} forge · {cookie.cycle-format} format · ^N new · esc sub-tabs")
        end
      when :decoded
        keys("↑/↓ scroll · {cookie.crack} crack · #{y} copy · space cmds · ↑-top input · ↓ options · #{lens} forge · esc sub-tabs")
      when :opts
        if effective_format(s) == "django"
          keys("type salt · salt:#{salt_preset_label(s)} (click/space) · {cookie.cycle-format} format · algo #{effective_algorithm(s)} · ↑/↓ cross · #{lens} forge · esc sub-tabs")
        else
          keys("type salt · {cookie.cycle-format} format · ↑/↓ cross · #{lens} forge · esc sub-tabs")
        end
      when :secret
        keys("type secret · ^Y copy · {cookie.cycle-format} format · ↑/↓ cross · #{lens} forge · esc sub-tabs")
      when :payload
        keys("type payload · ⇧arrows select · ^Y copy · ↑/↓ move+cross · {cookie.cycle-format} format · #{lens} decode · esc sub-tabs")
      when :output
        keys("↑/↓ scroll · #{y} copy cookie · space cmds · {cookie.cycle-format} format · #{lens} decode · esc sub-tabs")
      else
        ""
      end
    end

    # --- recompute ---
    # The format passed to the decode/verify/crack engine: nil (auto-detect) unless the operator
    # pinned one.
    private def decode_format(s : CookieSession) : String?
      s.format == "auto" ? nil : s.format
    end

    # The concrete format for FORGE, resolving `auto` through detection (Flask as the fallback).
    private def effective_format(s : CookieSession) : String
      s.format == "auto" ? (s.detected || "flask") : s.format
    end

    # The format the OPTIONS badge shows and a click/cycle acts on: the pinned one in DECODE
    # (which may be `auto`), the resolved concrete one in FORGE — since FORGE cannot mint under
    # `auto`. `s.format` itself stays `auto`, so toggling back to DECODE and pasting a different
    # framework's cookie still auto-detects rather than being decoded under a format FORGE pinned.
    private def display_format(s : CookieSession) : String
      s.mode == :forge ? effective_format(s) : s.format
    end

    private def effective_salt(s : CookieSession) : String?
      t = s.salt.strip
      t.empty? ? nil : t
    end

    # The Django HMAC algorithm the engine actually verifies/signs under: the operator's pinned
    # choice once they cycle it, otherwise inferred from the INPUT cookie's signature length
    # (sha1 = 20 raw bytes, sha256 = 32 — unambiguous). This closes the sibling of the salt trap
    # ([[cookie-tab-session-salt-trap]]): a genuine SHA-1 `sessionid` would otherwise read as
    # ✗ bad key under the SHA-256 default even with the correct secret. Non-Django and a pinned
    # choice both fall straight through to the stored value; an undetectable cookie keeps it too.
    private def effective_algorithm(s : CookieSession) : String
      return s.algorithm if s.algorithm_pinned? || effective_format(s) != "django"
      Cookie.detect_django_algo(s.input.text) || s.algorithm
    end

    private def recompute_all(s : CookieSession) : Nil
      recompute_decode(s)
      recompute_output(s)
    end

    private def recompute_decode(s : CookieSession) : Nil
      token = s.input.text.strip
      s.detected = token.empty? ? nil : Cookie.detect(token)
      s.decoded = decode_text(token, decode_format(s))
      recompute_verify(s)
      s.view.reset_decoded_scroll
    end

    private def decode_text(token : String, format : String?) : String
      return "" if token.empty?
      Cookie.decode(token, format)
    rescue ex
      "// #{ex.message}"
    end

    private def recompute_verify(s : CookieSession) : Nil
      token = s.input.text.strip
      if token.empty? || s.secret.empty?
        s.verify_state = :none
        s.crack_note = nil
        return
      end
      ok = Cookie.verify(token, s.secret, decode_format(s), salt: effective_salt(s), algorithm: effective_algorithm(s))
      s.verify_state = ok ? :ok : :bad
      # A green "cracked" verdict cannot outlive a failing verify: changing the INPUT cookie, the
      # salt, the format or the algorithm re-runs this, and if the cracked key no longer signs
      # the cookie the card must say "✗ bad key", not keep showing the stale crack result.
      s.crack_note = nil unless ok
    end

    private def recompute_output(s : CookieSession) : Nil
      body = s.payload.text
      if body.strip.empty?
        s.output = ""
        s.output_ok = true
        s.view.reset_output_scroll
        return
      end
      begin
        s.output = forge_cookie(s, body)
        s.output_ok = true
      rescue ex : Cookie::CookieError
        s.output = ex.message || "invalid input"
        s.output_ok = false
      rescue ex : JSON::ParseException
        s.output = "payload is not valid JSON"
        s.output_ok = false
      end
      s.view.reset_output_scroll
    end

    private def forge_cookie(s : CookieSession, body : String) : String
      ts = Time.utc.to_unix
      salt = effective_salt(s)
      case effective_format(s)
      when "rack"
        Cookie::Rack.forge(body.strip, s.secret)
      when "django"
        Cookie::Django.forge(body, s.secret, ts,
          salt: salt || Cookie::Django::DEFAULT_SALT, algorithm: effective_algorithm(s))
      else # flask
        Cookie::Flask.forge(body, s.secret, ts, salt: salt || Cookie::Flask::SALT)
      end
    end
  end
end
