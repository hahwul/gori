require "json"
require "./session_slot"
require "./bindings"
require "./store"
require "./proxy/codec/http1"
require "./proxy/codec/content_decode"
require "./raw_json"

module Gori
  # One captured login flow → one session slot's header overlay.
  #
  # Carrying a session into `gori run` was a three-step playbook: write an extract rule for
  # the token, write a Match & Replace that splices `$SESSION` into the outgoing request, and
  # remember `--bind-from FLOW` on every sweep — because a binding VALUE is memory-only and
  # dies with the process. That is the right machinery for a token that ROTATES, and it stays
  # exactly where it was.
  #
  # It is not what the common case needs. The common case is a login response that sets a
  # cookie or hands back a bearer token which then stays valid for the afternoon, and for that
  # the honest primitive is the one gori already has: a `SessionSlot` whose `set_headers` are
  # LITERAL bytes, saved with the project, applied by `--slot NAME` on every later send.
  # This module is the reader that turns the one into the other, so an operator types one
  # command instead of three.
  #
  # ## What it reads, and in what order
  #
  # The RESPONSE is the authority — it is the message that minted the session:
  #
  #   1. every `Set-Cookie` `name=value` (attributes dropped) folded into one `Cookie:` line,
  #      in wire order, last value winning for a repeated name;
  #   2. the response's own `Authorization`, if it carries one;
  #   3. else a `access_token` / `token` / `id_token` STRING at the TOP LEVEL of a JSON body,
  #      as `Authorization: Bearer <value>`. Three key names and a `JSON.parse` — deliberately
  #      not a JSONPath expression, because the moment this grows a path language it is a
  #      worse `create_extract_rule` rather than a shortcut. An operator whose token lives
  #      somewhere else writes the extract rule, which is the surface for it.
  #
  # Only when the response offers none of those three does the REQUEST's own `Authorization`
  # come across — the credential that was already in play (a Basic exchange, an API key). It
  # is last on purpose: a refresh flow whose request carries the STALE bearer and whose
  # response body carries the fresh one must copy the fresh one.
  #
  # ## Provenance
  #
  # Every value here is the ORIGIN'S bytes, not the operator's. `SessionSlot.overlay_head`
  # writes a set-header value VERBATIM and says why: an overlay an operator typed is the
  # operator's own bytes. That reasoning does not reach this path, so a CR/LF/NUL is REFUSED
  # here rather than spliced into every request the slot later overlays — the same guard, and
  # the same predicate (`Bindings.boundary_forging?`), that a bound value passes at the send
  # seam. See `Bindings.boundary_forging?`.
  module SessionFromFlow
    extend self

    # Top-level JSON body keys read as a bearer token, in precedence order. `access_token`
    # leads: when a body carries more than one of these it is an OAuth response, where
    # `access_token` is the credential that authenticates the next call and `id_token` never
    # is (it is an identity assertion for the client itself).
    TOKEN_KEYS = %w[access_token token id_token]

    # A body larger than this is not read for a token. A login response is a few hundred bytes
    # of JSON; anything at this scale is a page, and decoding it to look for `access_token`
    # buys nothing.
    MAX_TOKEN_BODY = 1 << 20

    # What the flow yielded: the header overlay, plus one human-readable line per source so a
    # surface can tell the operator WHERE each header came from. `sources` names provenance
    # and never a value — a session cookie is a credential and this line goes to scrollback.
    record Draft,
      set_headers : Array({String, String}),
      sources : Array(String) do
      def literal_headers : Array(String)
        set_headers.map(&.[0])
      end

      def slot(name : String, baseline : Bool = false) : SessionSlot
        SessionSlot.new(name, set_headers, [] of String, baseline, [] of String, literal_headers)
      end
    end

    # A refusal with a stable `code`, so MCP can key on it while the CLI prints the sentence.
    # Deterministic and un-retryable, both of them: a caller that retries either one loops.
    record Refusal, code : String, message : String

    # No credential anywhere in the flow — the flow is real but it is not a login.
    NO_CREDENTIAL = "NO_CREDENTIAL"
    # A credential IS there and carries a byte that would forge a header boundary. Refused
    # loudly: a slot built from it would splice attacker-chosen headers into every request it
    # overlays, and dropping it silently would produce an unauthenticated `--slot` run that
    # reports "found nothing".
    UNSAFE_VALUE = "UNSAFE_VALUE"

    # Refusals for the explicit request-header reader. These are deliberately separate from
    # `NO_CREDENTIAL`: a caller supplied the credential names, so an empty selection, malformed
    # name, or absent field is an argument/data error rather than a login-flow diagnosis.
    EMPTY_HEADER_NAMES  = "EMPTY_HEADER_NAMES"
    INVALID_HEADER_NAME = "INVALID_HEADER_NAME"
    MISSING_HEADER      = "MISSING_HEADER"
    # A named header that frames or routes the message rather than identifying its sender.
    REFRAMING_HEADER = "REFRAMING_HEADER"

    # Headers a slot may never carry, because a slot is applied to a DIFFERENT message than
    # the one it was copied from. `SessionSlot` states the invariant — the overlay is
    # header-only, so Content-Length never moves and the body stays byte-exact — and an
    # upsert of a copied `Content-Length` breaks exactly that: every later send under this
    # slot would declare a length its own body does not have. `Transfer-Encoding` is the same
    # hazard spelled the other way, and `Host` re-points every send at the vhost that
    # happened to be captured. None of the three is a credential, so refusing them costs the
    # feature nothing. Refused rather than dropped: a caller that named one asked for it, and
    # a silent drop is how a slot ends up not being the overlay its author read back.
    REFRAMING_HEADERS = %w[content-length transfer-encoding host]

    # Build the overlay for `detail`, or say why not.
    def draft(detail : Store::FlowDetail) : Draft | Refusal
      resp_head = detail.response_head
      resp = resp_head ? Proxy::Codec::Http1.parse_response_head(resp_head) : nil

      headers = [] of {String, String}
      sources = [] of String

      if resp && (cookie = cookie_header(resp))
        value, count = cookie
        headers << {"Cookie", value}
        sources << "Cookie ← #{count} Set-Cookie header#{count == 1 ? "" : "s"} on the response"
      end

      if pair = authorization(detail, resp)
        headers << {"Authorization", pair[0]}
        sources << "Authorization ← #{pair[1]}"
      end

      return no_credential(detail, resp) if headers.empty?

      # The provenance guard. Refused as a whole rather than per header: a response that
      # smuggles a CR into its `Set-Cookie` is not a flow to build half a session from.
      headers.each do |(name, value)|
        unless value.valid_encoding?
          return Refusal.new(UNSAFE_VALUE,
            "the captured #{name} value is not valid UTF-8 and cannot be persisted as a " \
            "literal session value. Nothing was saved")
        end
        next unless Bindings.boundary_forging?(value)
        return Refusal.new(UNSAFE_VALUE,
          "the captured #{name} value carries #{Bindings.boundary_bytes(value).join("/")}, which " \
          "would forge a header boundary in every request this slot overlays. Nothing was saved — " \
          "if that byte is the finding, keep it as evidence on the flow rather than in a slot")
      end

      Draft.new(headers, sources)
    end

    # Build an overlay from explicitly named headers on the captured REQUEST. The caller chooses
    # the credential fields rather than gori guessing whether a Cookie jar or a custom header is
    # meaningful. The request is the operator's captured evidence, but its values are still
    # origin-chosen bytes: the same boundary-forging guard used by the response reader applies
    # before those bytes can be persisted into a slot.
    #
    # Names are deduplicated case-insensitively in the order requested. For each name the last
    # wire field wins, matching `HeaderList#get?` and `SessionSlot`'s case-insensitive upsert;
    # the selected field's original casing is retained in the resulting overlay. The operation
    # is atomic: a missing name or unsafe value returns a refusal and never a partial Draft.
    def draft_request(detail : Store::FlowDetail, header_names : Array(String)) : Draft | Refusal
      return Refusal.new(EMPTY_HEADER_NAMES,
        "at least one request header name is required to build a session slot") if header_names.empty?

      names = [] of String
      header_names.each do |name|
        unless Proxy::Codec::Http1.header_name_safe?(name)
          return Refusal.new(INVALID_HEADER_NAME,
            "request header name #{name.inspect} is not an RFC 7230 token")
        end
        if REFRAMING_HEADERS.includes?(name.downcase)
          return Refusal.new(REFRAMING_HEADER,
            "#{name.inspect} frames or routes the request rather than identifying its sender, " \
            "and a slot is applied to messages with a different body and target. Copying it " \
            "would make every later send under this slot misframe or misroute itself. Nothing " \
            "was saved — copy the credential headers and leave framing to the message")
        end
        names << name unless names.any? { |seen| seen.compare(name, case_insensitive: true) == 0 }
      end

      request = Proxy::Codec::Http1.parse_request_head(detail.request_head)
      headers = [] of {String, String}
      sources = [] of String
      names.each do |name|
        captured = request.headers.entries.reverse_each.find do |header|
          header.name.compare(name, case_insensitive: true) == 0
        end
        unless selected = captured
          return Refusal.new(MISSING_HEADER,
            "the captured request has no header named #{name.inspect}; nothing was saved")
        end

        unless selected.value.valid_encoding?
          return Refusal.new(UNSAFE_VALUE,
            "the captured request header #{selected.name.inspect} is not valid UTF-8 and " \
            "cannot be persisted as a literal session value. Nothing was saved")
        end
        if Bindings.boundary_forging?(selected.value)
          return Refusal.new(UNSAFE_VALUE,
            "the captured request header #{selected.name.inspect} carries " \
            "#{Bindings.boundary_bytes(selected.value).join("/")}, which would forge a header " \
            "boundary in every request this slot overlays. Nothing was saved")
        end
        headers << {selected.name, selected.value}
        sources << "#{selected.name} ← the captured request header"
      end

      Draft.new(headers, sources)
    end

    # `name=value; name=value` from every `Set-Cookie` on the response, plus how many went in,
    # or nil when the response sets none worth carrying.
    #
    # Attributes are dropped (everything from the first `;`) — a `Cookie:` request header is
    # pairs and nothing else, per RFC 6265 §5.4. A cookie whose VALUE is empty is skipped: an
    # empty value paired with `Max-Age=0`/an expiry in the past is how a server DELETES a
    # cookie, and carrying the deletion forward would send the tombstone as a session.
    private def cookie_header(resp : Proxy::Codec::RawResponse) : {String, Int32}?
      names = [] of String
      values = {} of String => String
      resp.headers.get_all("set-cookie").each do |sc|
        pair = sc.split(';', 2)[0]
        eq = pair.index('=')
        next unless eq
        name = pair[0...eq].strip
        value = pair[(eq + 1)..].strip
        next if name.empty? || value.empty?
        # Last value wins for a repeated name — the later `Set-Cookie` is the one a client
        # would hold — but the FIRST appearance keeps its place, so the line reads in the
        # order the origin wrote it.
        names << name unless values.has_key?(name)
        values[name] = value
      end
      return nil if names.empty?
      {names.map { |n| "#{n}=#{values[n]}" }.join("; "), names.size}
    end

    # The `Authorization` value to carry, and where it came from. See the module comment for
    # why the response's own body outranks the request's header.
    private def authorization(detail : Store::FlowDetail,
                              resp : Proxy::Codec::RawResponse?) : {String, String}?
      if resp && (v = resp.headers.get?("authorization")) && !v.empty?
        return {v, "the response header"}
      end
      if resp && (found = json_token(detail))
        value, key = found
        # A body that already spells the scheme out (`"token": "Bearer eyJ…"`) must not get a
        # second one. Only `Bearer` is recognised — any other scheme in the value is the
        # operator's to keep verbatim.
        bearer = value.lstrip.downcase.starts_with?("bearer ") ? value : "Bearer #{value}"
        return {bearer, "the response body's #{key.inspect} (as a Bearer token)"}
      end
      req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
      if (v = req.headers.get?("authorization")) && !v.empty?
        return {v, "the request header (the response minted nothing)"}
      end
      nil
    end

    # A top-level `access_token`/`token`/`id_token` STRING in a JSON response body, with the
    # key that held it. Decoded through `Proxy::Codec::ContentDecode` — the same seam
    # `TokenExtract` reads a body through, so a gzipped login response is not a silent miss.
    #
    # The leaf must be a STRING: `{"token": {"value": …}}` is an envelope, not a token, and
    # stringifying it would put a JSON object in an `Authorization` header. Content-Type is
    # not consulted — a parse succeeding IS the test, and an API that mislabels its
    # login response should not cost the operator the feature.
    private def json_token(detail : Store::FlowDetail) : {String, String}?
      body = detail.response_body
      return nil if body.nil? || body.empty? || body.size > MAX_TOKEN_BODY
      decoded, _ = Proxy::Codec::ContentDecode.decode(detail.response_head, body)
      text = String.new(decoded || body)
      # Never repair origin bytes into a different credential. An invalid body simply is not
      # a JSON token source; credentials carried by response headers remain usable.
      return nil unless text.valid_encoding?
      # `RawJson.member`, so an oversized number beside the token no longer hides it (#1200) —
      # and one AT a token key stays a number (nil), not the String `RawJson.parse` would carry.
      TOKEN_KEYS.each do |key|
        v = RawJson.member(text, key).try(&.as_s?)
        return {v, key} if v && !v.empty?
      end
      nil
    end

    # Why this flow yielded nothing, said in terms of what was actually there. A refusal that
    # only says "nothing found" leaves the operator guessing whether gori looked at the right
    # message; naming the missing half is what tells them to point at the login response
    # rather than the page that followed it.
    private def no_credential(detail : Store::FlowDetail,
                              resp : Proxy::Codec::RawResponse?) : Refusal
      why = if resp.nil?
              detail.error ? "that flow has no response (#{detail.error})" : "that flow has no captured response"
            else
              "its #{resp.status} response sets no cookie and carries no Authorization, and its " \
              "body holds no top-level #{TOKEN_KEYS.join("/")} string"
            end
      Refusal.new(NO_CREDENTIAL,
        "#{why}. A session slot is built from what a LOGIN response hands back — point at that " \
        "flow, or write the overlay by hand. A token that ROTATES belongs on the extract-rule " \
        "path instead (`gori run rewriter extract` + `--bind-from`), which re-mints it per run")
    end
  end
end
