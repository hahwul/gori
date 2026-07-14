require "base64"
require "compress/deflate"
require "uri"
require "./pretty"

module Gori
  # Decodes the SAML message a flow carries. SAML travels base64-encoded (and, for
  # the HTTP-Redirect binding, raw-DEFLATE-compressed) inside a `SAMLRequest` /
  # `SAMLResponse` parameter — so a captured assertion is an opaque blob in the
  # request body or URL. This is a DISPLAY-time projection (like `Gori::Sse`): no
  # table, parsed from the stored bytes on demand. It also re-encodes edited XML for
  # the Repeater SAML send-mode (the inverse path).
  #
  # Bindings (auto-detected from the decoded bytes, never trusted from the method):
  #   HTTP-POST     — `param = base64(xml)`            (a form POST, e.g. to the ACS)
  #   HTTP-Redirect — `param = base64(deflate(xml))`   (a GET query parameter)
  module Saml
    extend self

    # Ceiling on a decoded (and inflated) document we'll surface, so a deflate bomb or
    # a pathological assertion can't blow up the detail view. Far above any real SAML.
    MAX_XML = 4 * 1024 * 1024

    # A synthetic head so Pretty.format routes the decoded bytes through its XML
    # reflow (it keys on the Content-Type). Computed once.
    XML_HEAD = "Content-Type: application/xml\r\n\r\n".to_slice

    # A decoded SAML message located in a flow.
    record Doc,
      param : String,        # "SAMLResponse" | "SAMLRequest"
      binding : Symbol,      # :post (base64) | :redirect (deflate+base64)
      location : Symbol,     # :body | :query | :response
      relay_state : String?, # the RelayState param (url-decoded) carried alongside, if any
      xml : String           # decoded (+inflated) XML — raw, not yet pretty-printed

    # Detect + decode the SAML message a flow carries, or nil if none. Priority:
    # request body (HTTP-POST binding) → request query (HTTP-Redirect binding) →
    # response body (an IdP auto-POST HTML form returning the SAMLResponse to the SP).
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?,
                  resp_head : Bytes?, resp_body : Bytes?) : Doc?
      from_request(target, req_body) || from_response_html(resp_body)
    end

    # The request side: a form body (HTTP-POST) then the URL query (HTTP-Redirect).
    private def from_request(target : String, req_body : Bytes?) : Doc?
      if (b = req_body) && !b.empty?
        s = String.new(b)
        if has_param?(s) && (doc = from_pairs(s, :body))
          return doc
        end
      end
      if (q = query_of(target)) && has_param?(q)
        return from_pairs(q, :query)
      end
      nil
    end

    # The response side: an IdP auto-POST HTML form carrying the SAMLResponse back.
    private def from_response_html(resp_body : Bytes?) : Doc?
      return nil if resp_body.nil? || resp_body.empty? || resp_body.size > MAX_XML
      # scrub: String.new does NOT validate UTF-8, and Regex#match (below, in from_html_form)
      # raises on an invalid byte — a hostile/binary response body with "SAMLResponse" in it
      # would otherwise crash every surface that decodes SAML (TUI detail, `run show`, MCP).
      s = String.new(resp_body).scrub
      s.includes?("SAMLResponse") ? from_html_form(s) : nil
    end

    # A one-line summary of a Doc for a pane/CLI header.
    def summary(doc : Doc) : String
      bind = doc.binding == :redirect ? "HTTP-Redirect" : "HTTP-POST"
      loc = case doc.location
            when :query    then "URL query"
            when :response then "response form"
            else                "request body"
            end
      s = "#{doc.param} · #{bind} binding · #{loc}"
      rs = doc.relay_state
      rs ? "#{s} · RelayState: #{rs}" : s
    end

    # Pretty-print decoded XML via Pretty (display-only); falls back to the raw XML
    # when it's already tidy or doesn't balance (Pretty returns nil).
    def pretty_xml(xml : String) : String
      r = Pretty.format(XML_HEAD, xml.to_slice)
      r ? String.new(r.bytes) : xml
    end

    # Decode a single (already url-decoded) parameter value into {xml, binding},
    # auto-detecting the binding: a base64 payload that is itself XML is HTTP-POST;
    # one that raw-inflates to XML is HTTP-Redirect. nil when it's neither.
    def decode_value(value : String) : {String, Symbol}?
      raw = Base64.decode(value.gsub(/\s/, "")) rescue return nil
      return nil if raw.empty?
      if looks_like_xml?(raw)
        return raw.size <= MAX_XML ? {String.new(raw), :post} : nil
      end
      if (inflated = raw_inflate(raw)) && looks_like_xml?(inflated.to_slice)
        return {inflated, :redirect}
      end
      nil
    end

    # Re-encode edited XML back into a wire parameter value (url-encoded) for repeater —
    # the inverse of decode_value. HTTP-Redirect re-applies raw DEFLATE; HTTP-POST does
    # not. (XML is sent as UTF-8 bytes, matching how the SP/IdP produced it.)
    def encode_value(xml : String, binding : Symbol) : String
      payload = binding == :redirect ? raw_deflate(xml.to_slice) : xml.to_slice
      URI.encode_www_form(Base64.strict_encode(payload))
    end

    # Replace the (already-encoded) value of `param` in an `&`-joined form/query
    # string, leaving every other pair byte-for-byte (so RelayState, SigAlg, etc.
    # survive a re-encode untouched). Appends the pair if it was somehow absent.
    def replace_param(original : String, param : String, value : String) : String
      replaced = false
      parts = original.split('&').map do |pair|
        k, sep, _v = pair.partition('=')
        if !replaced && sep == "=" && k == param
          replaced = true
          "#{k}=#{value}"
        else
          pair
        end
      end
      return parts.join('&') if replaced
      original.empty? ? "#{param}=#{value}" : "#{original}&#{param}=#{value}"
    end

    # --- internals ----------------------------------------------------------

    private def has_param?(s : String) : Bool
      s.includes?("SAMLResponse=") || s.includes?("SAMLRequest=")
    end

    # Scan an `&`-joined form/query string for a SAML param (+ a RelayState sibling),
    # decoding the first one found.
    private def from_pairs(s : String, location : Symbol) : Doc?
      param = nil.as(String?)
      raw = nil.as(String?)
      relay = nil.as(String?)
      s.split('&').each do |pair|
        k, sep, v = pair.partition('=')
        next if sep.empty?
        case k
        when "SAMLResponse", "SAMLRequest"
          param, raw = k, v if param.nil?
        when "RelayState"
          relay = (URI.decode_www_form(v) rescue v) if relay.nil?
        end
      end
      return nil unless param && raw
      # plus_to_space: false — '+' is a standard base64 alphabet char here; treating it as a
      # space (then stripped by decode_value's whitespace gsub) would corrupt the payload.
      value = URI.decode_www_form(raw, plus_to_space: false) rescue raw
      dec = decode_value(value) || return nil
      Doc.new(param, dec[1], location, relay, dec[0])
    end

    # The IdP auto-POST form path: an HTML page with a hidden SAMLResponse input.
    SAMLRESP_AFTER  = /name=["']SAMLResponse["'][^>]*?value=["']([^"']*)["']/i
    SAMLRESP_BEFORE = /value=["']([^"']*)["'][^>]*?name=["']SAMLResponse["']/i

    private def from_html_form(html : String) : Doc?
      m = SAMLRESP_AFTER.match(html) || SAMLRESP_BEFORE.match(html) || return nil
      raw = m[1]? || return nil
      value = unescape_amp(raw)
      dec = decode_value(value) || return nil
      Doc.new("SAMLResponse", dec[1], :response, nil, dec[0])
    end

    # Minimal HTML-attribute unescape — enough for a base64 value placed in an
    # attribute (`&amp;` is the only base64-relevant entity; the rest is harmless).
    private def unescape_amp(s : String) : String
      s.gsub("&amp;", "&").gsub("&#43;", "+").gsub("&#x2b;", "+").gsub("&#x2B;", "+")
    end

    private def query_of(target : String) : String?
      idx = target.index('?') || return nil
      q = target[(idx + 1)..]
      q.empty? ? nil : q
    end

    # First non-whitespace byte (after an optional UTF-8 BOM) is `<` ⇒ looks like XML.
    private def looks_like_xml?(bytes : Bytes) : Bool
      i = 0
      i += 3 if bytes.size >= 3 && bytes[0] == 0xEF_u8 && bytes[1] == 0xBB_u8 && bytes[2] == 0xBF_u8
      while i < bytes.size && {0x20_u8, 0x09_u8, 0x0A_u8, 0x0D_u8}.includes?(bytes[i])
        i += 1
      end
      i < bytes.size && bytes[i] == 0x3C_u8 # '<'
    end

    # Raw DEFLATE (RFC 1951) inflate, bounded + tolerant: a mid-stream error keeps
    # whatever decoded so far (a truncated capture still shows its head). nil = nothing.
    private def raw_inflate(data : Bytes) : String?
      sink = IO::Memory.new
      buf = Bytes.new(64 * 1024)
      begin
        reader = Compress::Deflate::Reader.new(IO::Memory.new(data))
        loop do
          n = reader.read(buf)
          break if n == 0
          sink.write(buf[0, n])
          break if sink.bytesize > MAX_XML
        end
      rescue
        # tolerant: fall through with the partial output
      end
      sink.bytesize.zero? ? nil : String.new(sink.to_slice)
    end

    private def raw_deflate(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Deflate::Writer.open(io, &.write(data))
      io.to_slice
    end
  end
end
