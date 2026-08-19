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

    def initialize(@name : String,
                   @set_headers : Array({String, String}) = [] of {String, String},
                   @remove_headers : Array(String) = [] of String,
                   @baseline : Bool = false,
                   @rules : Array(String) = [] of String)
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
      SessionSlot.new(@name, @set_headers, @remove_headers, flag, @rules)
    end

    # The same slot claiming a different rule set. Membership is edited on the SLOT and not on
    # the rule so that a project with no slots has no membership state at all to migrate.
    def with_rules(names : Array(String)) : SessionSlot
      SessionSlot.new(@name, @set_headers, @remove_headers, @baseline, names)
    end

    # The same slot with every `set_headers` VALUE run through `resolve`. Used at the send seam
    # to expand a `$NAME` an operator wrote into a slot header (`Authorization: Bearer $SESSION`)
    # against that slot's own binding table — the whole reason a slot has a binding half.
    # Header NAMES are untouched: a header name is not a place a reference belongs, and scanning
    # one would make `$` in a name a silent rewrite rather than a visible byte.
    def resolve_values(& : String -> String) : SessionSlot
      return self if @set_headers.empty?
      SessionSlot.new(@name, @set_headers.map { |(n, v)| {n, yield v} }, @remove_headers,
        @baseline, @rules)
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
          o["baseline"]?.try(&.as_bool?) || false, parse_strings(o["rules"]?))
      end
      list
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
    private def self.head_length(wire : Bytes) : Int32
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
    # UTF-8, so this cannot go through String.
    private def self.index_of(hay : Bytes, needle : Bytes) : Int32?
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
    private def self.split_head_lines(head : String) : Array({String, String})
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

    # Replace the value of every header named `name` (case-insensitive, original casing kept);
    # append it when absent (upsert). The start line and blank line are left untouched.
    private def self.head_set_header(head : String, name : String, value : String) : String
      target = name.downcase
      found = false
      rewritten = split_head_lines(head).map_with_index do |(ln, term), i|
        next({ln, term}) if i == 0 || ln.empty?
        if (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          found = true
          {"#{ln[0, ci]}: #{value}", term}
        else
          {ln, term}
        end
      end
      found ? join_head_lines(rewritten) : head_add_header(head, name, value)
    end

    # Drop every header line named `name` (case-insensitive). The start line and blank lines
    # are always kept, so the head stays well-formed.
    private def self.head_remove_header(head : String, name : String) : String
      target = name.downcase
      kept = [] of {String, String}
      split_head_lines(head).each_with_index do |(ln, term), i|
        if i == 0 || ln.empty?
          kept << {ln, term}
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          # drop this header, its own terminator with it
        else
          kept << {ln, term}
        end
      end
      join_head_lines(kept)
    end
  end
end
