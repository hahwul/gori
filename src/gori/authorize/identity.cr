module Gori
  # Authorization / access-control testing (Burp Autorize / Auth Analyzer shape): replay a
  # captured request under several IDENTITIES — an admin session, a low-privilege user, an
  # anonymous client — and read the responses against a baseline to spot broken access
  # control (a resource that answers a low-priv identity the same as the baseline).
  #
  # gori has no multi-session primitive of its own: Env is one value per key and Bindings is a
  # single process-global namespace. So an identity here is a small STATIC header overlay —
  # the 90% case — carried in memory only. The send path, the diff and the verdict all reuse
  # existing engines (`Fuzz::Sender`, `Repeater::ExchangeMeta`, `Discover::Fingerprint`).
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
