require "json"

module Gori
  # Authorization / access-control testing (Burp Autorize / Auth Analyzer shape): replay a
  # captured request under several IDENTITIES — an admin session, a low-privilege user, an
  # anonymous client — and read the responses against a baseline to spot broken access
  # control (a resource that answers a low-priv identity the same as the baseline).
  #
  # gori has no multi-session primitive of its own: Env is one value per key and Bindings is a
  # single process-global namespace. So an identity here is a small STATIC header overlay —
  # the 90% case. The send path, the diff and the verdict all reuse existing engines
  # (`Fuzz::Sender`, `Repeater::ExchangeMeta`, `Discover::Fingerprint`); the identities
  # themselves persist per project (see `serialize` / `parse_json` below).
  module Authorize
    # One identity worth of auth state, applied as a header overlay onto a captured request
    # before it is replayed. `set_headers` upsert (replace any existing header of that name,
    # case-insensitively; append when absent); `remove_headers` strip. An "anonymous"
    # identity is one that removes Cookie/Authorization; an "admin" one that sets them.
    #
    # Exactly one identity in a run is the BASELINE — usually the request as-captured (its own
    # session), which the others are judged against. The overlay is header-only, so
    # Content-Length never moves.
    struct Identity
      getter name : String
      getter set_headers : Array({String, String})
      getter remove_headers : Array(String)
      getter? baseline : Bool

      def initialize(@name : String,
                     @set_headers : Array({String, String}) = [] of {String, String},
                     @remove_headers : Array(String) = [] of String,
                     @baseline : Bool = false)
      end

      # The as-captured identity: no overlay at all, so the request goes out exactly as it was
      # captured (with its original session). The natural baseline for a run seeded from
      # History — every other identity is a lens over this same request.
      def self.as_captured(name : String = "as-captured", baseline : Bool = true) : Identity
        new(name, baseline: baseline)
      end

      # True when this identity changes nothing — the request is sent verbatim.
      def passthrough? : Bool
        @set_headers.empty? && @remove_headers.empty?
      end

      # Identity by NAME, which is the field the list keeps unique. Used to tell the baseline
      # apart from the rest without comparing whole structs (the baseline flag differs).
      def same?(other : Identity) : Bool
        @name == other.name
      end

      # The same identity with a different baseline flag — the list editor's `b` key, which is
      # the ONLY place the flag moves, so two identities can never both claim it.
      def with_baseline(flag : Bool) : Identity
        Identity.new(@name, @set_headers, @remove_headers, flag)
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
    end

    # --- persistence ------------------------------------------------------------
    # Hand-built JSON, mirroring `Env.serialize_vars` / `Env.parse_vars_json` rather than
    # `JSON::Serializable`: this is the shape every persisted blob in the project's `settings`
    # table already uses, and the tolerant reader below is the half that matters.

    def self.serialize(identities : Array(Identity)) : String
      JSON.build do |j|
        j.array do
          identities.each do |id|
            j.object do
              j.field "name", id.name
              j.field "baseline", id.baseline?
              j.field "set" do
                j.array do
                  id.set_headers.each do |(name, value)|
                    j.object do
                      j.field "name", name
                      j.field "value", value
                    end
                  end
                end
              end
              j.field "remove" do
                j.array { id.remove_headers.each { |name| j.string(name) } }
              end
            end
          end
        end
      end
    end

    # A malformed blob degrades to "no identities" and a malformed ENTRY is skipped — never a
    # raise. The `rescue JSON::ParseException` is load-bearing rather than defensive: this is
    # read on the project-open path, and letting a bad parse escape would fail the whole
    # project open over a settings row (the exact reasoning `Env.parse_vars_json` records).
    def self.parse_json(raw : String?) : Array(Identity)
      list = [] of Identity
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
        list << Identity.new(name, parse_set(o["set"]?), parse_remove(o["remove"]?),
          o["baseline"]?.try(&.as_bool?) || false)
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

    private def self.parse_remove(node : JSON::Any?) : Array(String)
      names = [] of String
      return names unless arr = node.try(&.as_a?)
      arr.each do |e|
        name = e.as_s?
        names << name if name && !name.empty?
      end
      names
    end

    # Apply an identity's header overlay to a captured request and return the wire bytes to
    # send (overlaid head + original body). The body is opaque and untouched; only the head's
    # header lines change. `head` is the byte-exact request head including its terminating
    # blank line, exactly as `Store::FlowDetail#request_head` holds it.
    def self.overlay_request(head : Bytes, body : Bytes?, id : Identity) : Bytes
      overlaid = overlay_head(head, id)
      return overlaid if body.nil? || body.empty?
      buf = Bytes.new(overlaid.size + body.size)
      overlaid.copy_to(buf)
      body.copy_to(buf + overlaid.size)
      buf
    end

    # Apply an identity's overlay to a WIRE-FORM request (head + blank line + body in one
    # buffer) — what `Repeater::FlowRequest.build` produces for a captured flow, with its
    # absolute-form request line already rewritten to origin-form.
    #
    # The head is everything up to and including the first blank line; the body is opaque and
    # travels byte-exact. A buffer with no blank-line terminator is all head (a header-only
    # request still overlays), matching how the Rewriter splits a message.
    def self.overlay_wire(wire : Bytes, id : Identity) : Bytes
      return wire if id.passthrough?
      head_len = head_length(wire)
      head = wire[0, head_len]
      body = head_len < wire.size ? wire[head_len..] : nil
      overlay_request(head, body, id)
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

    # The head alone, with the overlay applied. Removes run before sets so an identity that
    # both drops and sets a header ends with the set value. Values go out VERBATIM — an
    # operator-authored overlay is the operator's own bytes (the same provenance rule the
    # Rewriter's header ops follow), so a CR/LF is not refused here.
    def self.overlay_head(head : Bytes, id : Identity) : Bytes
      return head if id.passthrough?
      text = String.new(head)
      id.remove_headers.each { |name| text = head_remove_header(text, name) }
      id.set_headers.each { |(name, value)| text = head_set_header(text, name, value) }
      text.to_slice
    end

    # --- head header ops --------------------------------------------------------
    # Mirrors the Rewriter's `head_set_header` / `head_remove_header` / `head_add_header`
    # (rules.cr) so an operator who learned the dialect there reads the same behaviour here;
    # kept as its own small copy rather than reaching into the Rewriter's hot proxy path.

    # CRLF for real HTTP, LF as a fallback so a hand-authored / test head round-trips.
    private def self.eol_of(text : String) : String
      text.includes?("\r\n") ? "\r\n" : "\n"
    end

    # Append `Name: value` as the last header, before the terminating blank line.
    private def self.head_add_header(head : String, name : String, value : String) : String
      eol = eol_of(head)
      line = "#{name}: #{value}"
      term = eol + eol
      if idx = head.rindex(term)
        "#{head[0, idx]}#{eol}#{line}#{head[idx..]}"
      elsif head.ends_with?(eol)
        "#{head}#{line}#{eol}"
      else
        "#{head}#{eol}#{line}"
      end
    end

    # Replace the value of every header named `name` (case-insensitive, original casing kept);
    # append it when absent (upsert). The start line and blank line are left untouched.
    private def self.head_set_header(head : String, name : String, value : String) : String
      eol = eol_of(head)
      target = name.downcase
      found = false
      out = head.split(eol).map_with_index do |ln, i|
        next ln if i == 0 || ln.empty?
        if (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          found = true
          "#{ln[0, ci]}: #{value}"
        else
          ln
        end
      end
      found ? out.join(eol) : head_add_header(head, name, value)
    end

    # Drop every header line named `name` (case-insensitive). The start line and blank lines
    # are always kept, so the head stays well-formed.
    private def self.head_remove_header(head : String, name : String) : String
      eol = eol_of(head)
      target = name.downcase
      kept = [] of String
      head.split(eol).each_with_index do |ln, i|
        if i == 0 || ln.empty?
          kept << ln
        elsif (ci = ln.index(':')) && ln[0, ci].strip.downcase == target
          # drop this header
        else
          kept << ln
        end
      end
      kept.join(eol)
    end
  end
end
