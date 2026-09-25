require "json"

module Gori
  # A named SESSION SLOT: one identity's worth of auth state, as a static header overlay
  # plus the extract rules whose bindings belong to it.
  #
  # gori had no multi-session primitive: `Env` is one value per key and `Bindings` was a
  # single process-global namespace, so `Authorize` shipped its own tiny "identity" — a
  # header overlay it applied to a captured request before replaying it. That type and a
  # session slot are the SAME THING under two names, and keeping them apart would have made
  # "the admin session" mean one thing in the Authorize tab and another at a Repeater send.
  # So they are one struct, persisted once (`SessionSlot.serialize`, under
  # `Store::SESSION_SLOTS_KEY`, which is still the `authorize_identities` row an existing
  # project already has). `Authorize::Identity` is an alias of this.
  #
  # Three fields and no more:
  #
  #   * `set_headers` upsert (replace any existing header of that name, case-insensitively;
  #     append when absent) and `remove_headers` strip. An "anonymous" slot removes
  #     Cookie/Authorization; an "admin" slot sets them. The overlay is HEADER-ONLY, so
  #     Content-Length never moves — that invariant is what lets a slot be applied to bytes
  #     the operator never intended to reframe.
  #   * `rules` names the extract rules (by binding NAME — `extract_rules.name` is UNIQUE, so
  #     a name IS a rule) whose observed values land in THIS slot's binding table rather than
  #     the one global table. A rule no slot names stays unscoped and keeps writing the global
  #     table, which is what makes every playbook written before slots existed keep working.
  #
  # There is deliberately NO cookie jar here. A slot is a static overlay plus a namespace for
  # values gori already observes; RFC 6265 storage, path/domain matching and expiry are a
  # different feature with a different failure mode, and the 90% case an operator actually
  # asks for is "send these headers as this identity".
  #
  # Exactly one slot in an Authorize run is the BASELINE — usually the request as-captured
  # (its own session), which the others are judged against.
  struct SessionSlot
    getter name : String
    getter set_headers : Array({String, String})
    getter remove_headers : Array(String)
    getter? baseline : Bool
    # Extract-rule membership, by binding name. Empty on every slot an operator wrote before
    # slots had a binding half, and empty is the compatible answer: a slot that names no rule
    # is a pure header overlay, exactly what an Authorize identity always was.
    getter rules : Array(String)
    # Header names whose values came from a captured flow and must stay byte-literal at send
    # time. Names are compared case-insensitively; an empty list is the compatible default for
    # slots written before captured-flow provenance existed.
    getter literal_headers : Array(String)
    # The Repeater sessions that RE-AUTHENTICATE this slot, in the order they run (#1233) —
    # `csrf-fetch → login`. Each step's response goes through the slot's own extract rules,
    # which is what rebinds it; see `SessionRefresh`. Ids, because a session's name is not
    # unique. A NEGATIVE id is a step whose session was deleted (`Store#delete_repeater`):
    # `repeaters.id` has no AUTOINCREMENT, so a positive id left behind would re-bind to the
    # next tab that takes it (#1160's encoding, for the same reason). It keeps its place in
    # the list and refuses to run until it is removed.
    getter refresh : Array(Int64)
    # WHEN the refresh runs on its own, before a send that goes out as this slot. `off` — the
    # default, and every slot written before #1233 — means only an explicit refresh does.
    getter refresh_before : RefreshBefore

    # The automatic-refresh policy. Three answers and no more:
    #
    #   * `off`      — never on its own.
    #   * `jwt-exp`  — when a JWT bound in this slot's table is within `SKEW` of its `exp`.
    #   * `ttl=10m`  — when the span has passed since the last successful refresh (before one,
    #                  since the slot's OLDEST binding — a CSRF every page rebinds must not
    #                  keep a stale session token looking fresh).
    #
    # Deliberately a question about the VALUE gori holds and never about a response: acting
    # before a send is what keeps a refresh from ever reinterpreting an answer (#1233's "not C").
    struct RefreshBefore
      enum Kind
        Off
        JwtExp
        Ttl
      end

      # How early `jwt-exp` refreshes. A token that expires between the check and the origin
      # reading it is a 401 the policy was meant to prevent, and a request can sit behind a
      # slow login for a while.
      SKEW = 30.seconds

      getter kind : Kind
      getter ttl : Time::Span

      def initialize(@kind : Kind = Kind::Off, @ttl : Time::Span = Time::Span.zero)
      end

      def self.off : RefreshBefore
        new
      end

      def off? : Bool
        @kind.off?
      end

      # `off` | `jwt-exp` | `ttl=<n>[s|m|h]`, case-insensitively; nil for anything else. A
      # bare number is seconds, as `--for` reads one. A zero TTL is refused: it would refresh
      # before every send, which is a login flood with a policy's name on it.
      def self.parse?(raw : String) : RefreshBefore?
        v = raw.strip.downcase
        return off if v == "off" || v.empty?
        return new(Kind::JwtExp) if v == "jwt-exp" || v == "jwt_exp"
        return nil unless m = v.match(/\Attl[=:](\d{1,7})(s|m|h)?\z/)
        n = m[1].to_i64
        return nil if n <= 0
        span = case m[2]?
               when "m" then n.minutes
               when "h" then n.hours
               else          n.seconds
               end
        new(Kind::Ttl, span)
      end

      # The spelling `parse?` reads back, and the one every surface prints.
      def to_s(io : IO) : Nil
        case @kind
        in Kind::Off    then io << "off"
        in Kind::JwtExp then io << "jwt-exp"
        in Kind::Ttl    then io << "ttl=" << RefreshBefore.span_label(@ttl)
        end
      end

      def ==(other : RefreshBefore) : Bool
        @kind == other.kind && (@kind.ttl? ? @ttl == other.ttl : true)
      end

      # `90s` → `90s`, `600s` → `10m`, `7200s` → `2h`: the largest unit that divides evenly.
      def self.span_label(span : Time::Span) : String
        s = span.total_seconds.to_i64
        return "#{s // 3600}h" if s > 0 && s % 3600 == 0
        return "#{s // 60}m" if s > 0 && s % 60 == 0
        "#{s}s"
      end
    end

    def initialize(@name : String,
                   @set_headers : Array({String, String}) = [] of {String, String},
                   @remove_headers : Array(String) = [] of String,
                   @baseline : Bool = false,
                   @rules : Array(String) = [] of String,
                   @literal_headers : Array(String) = [] of String,
                   @refresh : Array(Int64) = [] of Int64,
                   @refresh_before : RefreshBefore = RefreshBefore.off)
    end

    # The same slot with some fields replaced. EVERY rebuild of an existing slot goes through
    # here: a positional `SessionSlot.new(…)` that forgets a trailing field compiles cleanly and
    # silently resets it to its default, which is how a baseline move would erase a slot's
    # refresh steps.
    def copy_with(*, name : String = @name,
                  set_headers : Array({String, String}) = @set_headers,
                  remove_headers : Array(String) = @remove_headers,
                  baseline : Bool = @baseline,
                  rules : Array(String) = @rules,
                  literal_headers : Array(String) = @literal_headers,
                  refresh : Array(Int64) = @refresh,
                  refresh_before : RefreshBefore = @refresh_before) : SessionSlot
      SessionSlot.new(name, set_headers, remove_headers, baseline, rules, literal_headers,
        refresh, refresh_before)
    end

    # Does this slot have a way to re-authenticate at all? A negative (detached) step still
    # counts: the slot HAS a refresh, and running it reports the deleted step rather than
    # pretending the list is empty.
    def refreshable? : Bool
      !@refresh.empty?
    end

    # Should a send going out as this slot consider refreshing it first? The cheap half of the
    # before-send question — a policy and something to run. Whether it is DUE is the engine's.
    def auto_refresh? : Bool
      refreshable? && !@refresh_before.off?
    end

    # The identity half of a slot: everything that decides WHICH credential a send carries,
    # and nothing about how it is refreshed or which slot is the baseline. Two lists whose
    # identities agree are the same set of identities, so a peer's edit to a refresh list (or
    # a deleted step's detach) is not a reason to discard anything bound under them — see
    # `SessionSlots#reload`.
    def same_identity?(other : SessionSlot) : Bool
      @name == other.name && @set_headers == other.set_headers &&
        @remove_headers == other.remove_headers && @rules == other.rules &&
        @literal_headers == other.literal_headers
    end

    # The as-captured slot: no overlay at all, so the request goes out exactly as it was
    # captured (with its original session). The natural baseline for an Authorize run seeded
    # from History — every other identity is a lens over this same request — and the NO-OVERLAY
    # baseline for a send seam: activating it changes no byte, which is what makes it the thing
    # to select when the answer to "which session?" is "the one already in these bytes".
    def self.as_captured(name : String = "as-captured", baseline : Bool = true) : SessionSlot
      new(name, baseline: baseline)
    end

    # True when this slot changes nothing — the request is sent verbatim.
    def passthrough? : Bool
      @set_headers.empty? && @remove_headers.empty?
    end

    # Does this slot claim the extract rule named `rule_name`? Case-sensitive: a binding name
    # is an `Env` key and `$Session` and `$SESSION` are two keys everywhere else.
    def claims?(rule_name : String) : Bool
      @rules.includes?(rule_name)
    end

    # Slot by NAME, which is the field the list keeps unique. Used to tell the baseline apart
    # from the rest without comparing whole structs (the baseline flag differs).
    def same?(other : SessionSlot) : Bool
      @name == other.name
    end

    # The same slot with a different baseline flag — the list editor's `b` key, which is the
    # ONLY place the flag moves, so two slots can never both claim it.
    def with_baseline(flag : Bool) : SessionSlot
      copy_with(baseline: flag)
    end

    # The same slot claiming a different rule set. Membership is edited on the SLOT and not on
    # the rule so that a project with no slots has no membership state at all to migrate.
    def with_rules(names : Array(String)) : SessionSlot
      copy_with(rules: names)
    end

    def literal_header?(name : String) : Bool
      @literal_headers.any? { |literal| literal.compare(name, case_insensitive: true) == 0 }
    end

    # The same slot with every `set_headers` VALUE run through `resolve`. Used at the send seam
    # to expand a `$NAME` an operator wrote into a slot header (`Authorization: Bearer $SESSION`)
    # against that slot's own binding table — the whole reason a slot has a binding half.
    # Header NAMES are untouched: a header name is not a place a reference belongs, and scanning
    # one would make `$` in a name a silent rewrite rather than a visible byte.
    def resolve_values(& : String -> String) : SessionSlot
      return self if @set_headers.empty?
      values = @set_headers.map do |(name, value)|
        literal_header?(name) ? {name, value} : {name, yield(value)}
      end
      copy_with(set_headers: values)
    end

    # A one-line summary of what this overlay does, header NAMES only. The identities list
    # renders this rather than the values: a session cookie is a credential, and a list that
    # paints it on screen leaks it to anyone glancing at the terminal. The form shows the
    # value, because that is what editing means.
    def summary : String
      return "as captured" if passthrough?
      parts = [] of String
      parts << "sets #{@set_headers.map(&.[0]).join(", ")}" unless @set_headers.empty?
      parts << "drops #{@remove_headers.join(", ")}" unless @remove_headers.empty?
      parts.join(" · ")
    end

    # --- persistence ------------------------------------------------------------
    # Hand-built JSON, mirroring `Env.serialize_vars` / `Env.parse_vars_json` rather than
    # `JSON::Serializable`: this is the shape every persisted blob in the project's `settings`
    # table already uses, and the tolerant reader below is the half that matters.
    #
    # `rules` is written only when non-empty, so a project whose slots are pure header
    # overlays round-trips byte-identically to what pre-slot gori wrote — an old build reading
    # a new blob sees the identities it always saw, and a new build reading an old one sees
    # slots that claim no rule.

    def self.serialize(slots : Array(SessionSlot)) : String
      JSON.build do |j|
        j.array do
          slots.each do |slot|
            j.object do
              j.field "name", slot.name
              j.field "baseline", slot.baseline?
              j.field "set" do
                j.array do
                  slot.set_headers.each do |(name, value)|
                    j.object do
                      j.field "name", name
                      j.field "value", value
                    end
                  end
                end
              end
              j.field "remove" do
                j.array { slot.remove_headers.each { |name| j.string(name) } }
              end
              unless slot.rules.empty?
                j.field "rules" do
                  j.array { slot.rules.each { |name| j.string(name) } }
                end
              end
              unless slot.literal_headers.empty?
                j.field "literal" do
                  j.array { slot.literal_headers.each { |name| j.string(name) } }
                end
              end
              # Both refresh keys are written only when set, for the reason `rules` is: a
              # project that never configured a refresh round-trips byte-identically to what a
              # pre-#1233 gori wrote, and an older build reading a newer blob ignores the keys.
              unless slot.refresh.empty?
                j.field "refresh" do
                  j.array { slot.refresh.each { |id| j.number(id) } }
                end
              end
              j.field "refresh_before", slot.refresh_before.to_s unless slot.refresh_before.off?
            end
          end
        end
      end
    end

    # A malformed blob degrades to "no slots" and a malformed ENTRY is skipped — never a
    # raise. The `rescue JSON::ParseException` is load-bearing rather than defensive: this is
    # read on the project-open path, and letting a bad parse escape would fail the whole
    # project open over a settings row (the exact reasoning `Env.parse_vars_json` records).
    def self.parse_json(raw : String?) : Array(SessionSlot)
      list = [] of SessionSlot
      return list if raw.nil? || raw.strip.empty?
      arr = begin
        JSON.parse(raw).as_a?
      rescue JSON::ParseException
        nil
      end
      return list unless arr
      arr.each do |e|
        next unless o = e.as_h?
        name = o["name"]?.try(&.as_s?)
        next if name.nil? || name.empty?
        list << SessionSlot.new(name, parse_set(o["set"]?), parse_strings(o["remove"]?),
          o["baseline"]?.try(&.as_bool?) || false, parse_strings(o["rules"]?),
          parse_strings(o["literal"]?), parse_ids(o["refresh"]?),
          o["refresh_before"]?.try(&.as_s?).try { |v| RefreshBefore.parse?(v) } || RefreshBefore.off)
      end
      list
    end

    # The persisted blob with Repeater session `id` DETACHED from every slot's refresh list
    # (negated in place), or nil when no slot names it — the common case, which writes nothing.
    # Called by `Store#delete_repeater` inside its transaction.
    #
    # Edited at the JSON level rather than through `parse_json` + `serialize`: those two are
    # lossy for an entry this build does not understand (a newer build's key, a hand-written
    # blob), and a tab close must not rewrite anything but the one number it is about. Never
    # raises — it runs on the store's writer fiber, and a malformed row is "nothing to detach".
    def self.detach_refresh(raw : String?, id : Int64) : String?
      return nil if raw.nil? || id <= 0
      arr = JSON.parse(raw).as_a?
      return nil unless arr
      touched = false
      fresh = arr.map do |entry|
        o = entry.as_h?
        refs = o.try(&.["refresh"]?).try(&.as_a?)
        next entry unless o && refs && refs.any? { |r| r.as_i64? == id }
        touched = true
        copy = o.dup
        copy["refresh"] = JSON::Any.new(refs.map { |r| r.as_i64? == id ? JSON::Any.new(-id) : r })
        JSON::Any.new(copy)
      end
      touched ? fresh.to_json : nil
    rescue JSON::ParseException
      nil
    end

    # A step id of zero, or anything that is not an integer, is skipped: neither can name a
    # Repeater session. A negative id is KEPT — it is a detached step (see `refresh`).
    private def self.parse_ids(node : JSON::Any?) : Array(Int64)
      ids = [] of Int64
      return ids unless arr = node.try(&.as_a?)
      arr.each do |e|
        id = e.as_i64?
        ids << id if id && id != 0
      end
      ids
    end

    private def self.parse_set(node : JSON::Any?) : Array({String, String})
      pairs = [] of {String, String}
      return pairs unless arr = node.try(&.as_a?)
      arr.each do |e|
        next unless o = e.as_h?
        name = o["name"]?.try(&.as_s?)
        value = o["value"]?.try(&.as_s?)
        next if name.nil? || name.empty? || value.nil?
        pairs << {name, value}
      end
      pairs
    end

    private def self.parse_strings(node : JSON::Any?) : Array(String)
      names = [] of String
      return names unless arr = node.try(&.as_a?)
      arr.each do |e|
        name = e.as_s?
        names << name if name && !name.empty?
      end
      names
    end

    # --- the overlay ------------------------------------------------------------

    # Apply a slot's header overlay to a captured request and return the wire bytes to send
    # (overlaid head + original body). The body is opaque and untouched; only the head's
    # header lines change. `head` is the byte-exact request head including its terminating
    # blank line, exactly as `Store::FlowDetail#request_head` holds it.
    def self.overlay_request(head : Bytes, body : Bytes?, slot : SessionSlot) : Bytes
      overlaid = overlay_head(head, slot)
      return overlaid if body.nil? || body.empty?
      buf = Bytes.new(overlaid.size + body.size)
      overlaid.copy_to(buf)
      body.copy_to(buf + overlaid.size)
      buf
    end

    # Apply a slot's overlay to a WIRE-FORM request (head + blank line + body in one buffer) —
    # what `Repeater::FlowRequest.build` produces for a captured flow, with its absolute-form
    # request line already rewritten to origin-form, and what every send seam holds.
    #
    # The head is everything up to and including the first blank line; the body is opaque and
    # travels byte-exact. A buffer with no blank-line terminator is all head (a header-only
    # request still overlays), matching how the Rewriter splits a message.
    def self.overlay_wire(wire : Bytes, slot : SessionSlot) : Bytes
      return wire if slot.passthrough?
      head_len = head_length(wire)
      head = wire[0, head_len]
      body = head_len < wire.size ? wire[head_len..] : nil
      overlay_request(head, body, slot)
    end

    # Bytes up to and including the head's terminating blank line: CRLFCRLF or LFLF, whichever
    # comes FIRST (a body carrying a CRLFCRLF must not move the boundary — the same rule
    # `Rules#split_message` states). The whole buffer when there is no blank line at all.
    # Public for `ClientHints.apply`, the other header-only writer on the send seam.
    def self.head_length(wire : Bytes) : Int32
      crlf = index_of(wire, "\r\n\r\n".to_slice)
      lf = index_of(wire, "\n\n".to_slice)
      if crlf && (lf.nil? || crlf < lf)
        crlf + 4
      elsif lf
        lf + 2
      else
        wire.size
      end
    end

    # First index of `needle` in `hay`, or nil. Byte-level: a request body need not be valid
    # UTF-8, so this cannot go through String. Public for `ClientHints.apply`.
    def self.index_of(hay : Bytes, needle : Bytes) : Int32?
      return nil if needle.empty? || hay.size < needle.size
      limit = hay.size - needle.size
      i = 0
      while i <= limit
        if hay[i] == needle[0]
          j = 1
          while j < needle.size && hay[i + j] == needle[j]
            j += 1
          end
          return i if j == needle.size
        end
        i += 1
      end
      nil
    end

    # The head alone, with the overlay applied. Removes run before sets so a slot that both
    # drops and sets a header ends with the set value. Values go out VERBATIM — an
    # operator-authored overlay is the operator's own bytes (the same provenance rule the
    # Rewriter's header ops follow), so a CR/LF is not refused here.
    #
    # A value that came from a BINDING is a different provenance and IS guarded, one layer up:
    # `SessionSlots#overlay` resolves `$NAME` through `Env.expand_bindings(guard_boundary: true)`
    # before the resolved slot reaches this function. See `Bindings.boundary_forging?`.
    def self.overlay_head(head : Bytes, slot : SessionSlot) : Bytes
      return head if slot.passthrough?
      text = String.new(head)
      slot.remove_headers.each { |name| text = head_remove_header(text, name) }
      slot.set_headers.each { |(name, value)| text = head_set_header(text, name, value) }
      text.to_slice
    end

    # --- head header ops --------------------------------------------------------
    # Mirrors the Rewriter's `head_set_header` / `head_remove_header` / `head_add_header`
    # (rules.cr) so an operator who learned the dialect there reads the same behaviour here;
    # kept as its own small copy rather than reaching into the Rewriter's hot proxy path.

    # CRLF for real HTTP, LF as a fallback so a hand-authored / test head round-trips. Only a
    # head with NO line terminator at all still needs this guess; every other decision is made
    # from the terminator the line itself carries (see `split_head_lines`).
    private def self.eol_of(text : String) : String
      text.includes?("\r\n") ? "\r\n" : "\n"
    end

    # The head as {content, own terminator} pairs — concatenating them is byte-identical to
    # the input. Per-line rather than one `split(eol)` for the whole head, because a send seam
    # takes the operator's bytes verbatim (MCP `send_request(verbatim: true)`, a replayed
    # import) and those may mix CRLF and bare LF: picking ONE terminator folds a bare-LF
    # header into its predecessor, so the overlay reads the wrong name and silently applies to
    # nothing. Malformed framing is the payload here (DESIGN.md P7) — the operator's own
    # overlay instruction must still land on it. Byte-level, since a head need not be valid
    # UTF-8 for the same reason `index_of` is.
    # Public for `ClientHints.apply`, for the same reason as `head_length`.
    def self.split_head_lines(head : String) : Array({String, String})
      out = [] of {String, String}
      bytes = head.to_slice
      start = 0
      i = 0
      while i < bytes.size
        if bytes[i] == 0x0a_u8
          if i > start && bytes[i - 1] == 0x0d_u8
            out << {String.new(bytes[start, i - 1 - start]), "\r\n"}
          else
            out << {String.new(bytes[start, i - start]), "\n"}
          end
          start = i + 1
        end
        i += 1
      end
      out << {String.new(bytes[start, bytes.size - start]), ""} if start < bytes.size
      out
    end

    private def self.join_head_lines(pairs : Array({String, String})) : String
      String.build { |io| pairs.each { |(content, term)| io << content << term } }
    end

    # Append `Name: value` as the last header, before the terminating blank line.
    private def self.head_add_header(head : String, name : String, value : String) : String
      line = "#{name}: #{value}"
      pairs = split_head_lines(head)
      return line if pairs.empty?
      # The LAST blank line at index >= 1 is the head's terminator — the same one the old
      # `rindex(eol + eol)` found, but recognised whatever terminator it carries.
      idx = pairs.rindex { |(content, _)| content.empty? }
      idx = nil if idx == 0 # index 0 is the start line, never the terminator
      if idx
        pairs.insert(idx, {line, pairs[idx][1]})
      else
        last = pairs[-1]
        if last[1].empty?
          pairs[-1] = {last[0], eol_of(head)}
          pairs << {line, ""}
        else
          pairs << {line, last[1]}
        end
      end
      join_head_lines(pairs)
    end

    # Whether a `split_head_lines` entry is an obs-fold CONTINUATION — a line whose first byte
    # is SP or HTAB. RFC 9112 §5.2 makes it part of the PREVIOUS field's value, never a header
    # of its own, and that is the second line view one head carries: `split_head_lines` sees N
    # lines where the field parser sees fewer fields. Kept in step with `Rules#fold_line?`,
    # which the two ops below mirror — an overlay applied to a folded head used to
    #
    #   * SET a header into a continuation: ` X-Inner: folded` answered the name test
    #     (`ln[0, ci].strip` erases the leading SP), so the slot's own header never reached the
    #     wire and the field ABOVE it silently took the value instead;
    #   * REMOVE a field and leave its continuation behind as the first header line — an
    #     "anonymous" slot dropping a folded `Cookie` left half the credential on the wire, in
    #     a head gori itself manufactured as malformed.
    #
    # First BYTE, not `starts_with?(' ')`: a captured header line can be invalid UTF-8 (obs-text
    # in the value it continues), where char iteration answers about U+FFFD.
    private def self.fold_line?(line : String) : Bool
      return false if line.empty?
      b = line.to_slice[0]
      b == 0x20_u8 || b == 0x09_u8
    end

    # Replace the value of every header named `name` (case-insensitive, original casing kept);
    # append it when absent (upsert). The start line and blank line are left untouched.
    #
    # An obs-fold continuation of the field being set is part of the VALUE being replaced, so it
    # goes with it. One of any other field is carried through untouched, and is never tested for
    # the name.
    private def self.head_set_header(head : String, name : String, value : String) : String
      target = name.downcase
      found = false
      in_target = false
      rewritten = [] of {String, String}
      split_head_lines(head).each_with_index do |(ln, term), i|
        if i == 0 || ln.empty?
          in_target = false
          rewritten << {ln, term}
        elsif fold_line?(ln)
          rewritten << {ln, term} unless in_target
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          found = true
          in_target = true
          rewritten << {"#{ln[0, ci]}: #{value}", term}
        else
          in_target = false
          rewritten << {ln, term}
        end
      end
      found ? join_head_lines(rewritten) : head_add_header(head, name, value)
    end

    # Drop every header line named `name` (case-insensitive), and with it every obs-fold
    # continuation of that field. The start line and blank lines are always kept, so the head
    # stays well-formed.
    private def self.head_remove_header(head : String, name : String) : String
      target = name.downcase
      kept = [] of {String, String}
      dropping = false
      split_head_lines(head).each_with_index do |(ln, term), i|
        if i == 0 || ln.empty?
          dropping = false
          kept << {ln, term}
        elsif fold_line?(ln)
          kept << {ln, term} unless dropping # continues the field above, so it shares its fate
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          dropping = true # drop this header, its own terminator with it
        else
          dropping = false
          kept << {ln, term}
        end
      end
      join_head_lines(kept)
    end
  end
end
