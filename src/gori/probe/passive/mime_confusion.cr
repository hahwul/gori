require "json"
require "./rule"

module Gori
  module Probe
    module Passive
      # MIME type confusion (category "headers"): the BODY the server sent and the Content-Type
      # it declared disagree, in one of the two shapes a browser can be talked into rendering as
      # HTML. Zero-request and response-gated — everything below is read off the captured flow.
      #
      # Case 1 — `mime_sniff_html`: the body plainly IS an HTML/script document, but it is served
      # under a type browsers content-sniff, with no `X-Content-Type-Options: nosniff`. All three
      # conditions are load-bearing and the rule fires only when every one holds:
      #
      #   * the body sniffs as HTML — a leading `<!doctype html` / `<html` / `<head` / `<body` /
      #     `<script` / `<svg`, or a `<script` inside the sniffed prefix. Anything vaguer (a lone
      #     `<` , a `<p>` in prose) is not markup a sniffer commits on, and would be noise;
      #   * the DECLARED type is one browsers actually sniff. That set is small: a missing
      #     Content-Type, `text/plain`, and `application/octet-stream`. `application/json` and the
      #     other `application/*` types are deliberately EXCLUDED — modern browsers do not
      #     upgrade those to HTML, so an HTML-looking JSON body is a mislabelling curiosity, not
      #     an XSS. `text/html` is excluded too: an HTML body under `text/html` is simply correct;
      #   * `nosniff` is ABSENT. `X-Content-Type-Options: nosniff` is precisely the switch that
      #     tells the browser to honour the declared type and never sniff — with it present the
      #     body is rendered as text/downloaded and there is no path to execution, so firing
      #     would be a pure false positive. (SecurityHeaders separately flags the header's absence
      #     as a hardening gap; this rule only cares that its absence turns a sniffable body into
      #     a live one.)
      #
      #   Together they describe the classic MIME-sniffing XSS: an upload/echo endpoint that
      #   stores attacker markup and serves it back as `text/plain`, which IE/legacy sniffers —
      #   and, for `application/octet-stream` downloads opened in-page, still today's — will
      #   happily execute in the site's origin.
      #
      # Case 2 — `mime_json_as_html`: the body is real JSON but the response claims `text/html`.
      # The browser then parses an API payload as a document: any value echoing user input that
      # contains markup is rendered, not escaped, which is a stored/reflected XSS with no need
      # for sniffing at all. The label is wrong regardless, which is why this is reported even
      # when nosniff IS present — nosniff enforces the declared type, and here the declared type
      # is the dangerous one.
      #
      #   The FP guard is that the body must ACTUALLY PARSE as JSON, not merely open with a brace.
      #   A genuine HTML page can start with `{` (a templating artefact, a stray `{{ }}` mustache,
      #   a CSS-ish preamble), and a prefix test alone flagged those. Requiring `JSON.parse` to
      #   succeed makes the check exact: only a document that a JSON consumer would accept counts.
      #   The parse runs inside a rescue (malformed input IS the payload here), and it is reached
      #   only for the small slice of traffic that both declares text/html and opens with `{`/`[`,
      #   so the tree build is not on the general passive path. Note the body text is capped
      #   (Context::BODY_CAP), so a JSON document larger than the cap parses as truncated and does
      #   NOT fire — a deliberate miss rather than a guess.
      #
      # Byte-safety: `ctx.body_text` arrives already content-decoded, capped and `.scrub`bed, so
      # every test here is a plain String operation — no PCRE over raw bytes.
      class MimeConfusion < Rule
        def info : RuleInfo
          RuleInfo.new("mime_confusion", "MIME type confusion",
            "Flags responses whose body type disagrees with the Content-Type in a way that enables MIME-sniffing XSS (HTML body under a sniffable type without nosniff; JSON served as text/html).",
            Category::HEADERS)
        end

        # How much of the (whitespace/BOM-trimmed) body is examined for the HTML sniff. Browsers
        # decide on a short leading window; a `<script` further in than this is a page's content,
        # not its shape.
        SNIFF_PREFIX = 512

        # Leading markers that make a body unambiguously an HTML/script document. Kept tight and
        # HTML-specific on purpose — this list IS the false-positive budget for case 1.
        HTML_STARTS = ["<!doctype html", "<html", "<head", "<body", "<script", "<svg"]

        # The declared media types a browser will content-sniff into HTML. Deliberately excludes
        # every `application/*` type except octet-stream, and excludes text/html itself.
        SNIFFABLE_TYPES = ["text/plain", "application/octet-stream"]

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          # Render-context gate, mirroring SecurityHeaders#rendered_document?: a 3xx redirect body
          # is discarded (the UA follows the Location) and a 204 carries none, so a mis-served body
          # on those statuses is never rendered — there is no sniffing/execution path, and firing
          # would be a false positive. A 4xx/5xx error page IS rendered, so it keeps the checks.
          return unless rendered_document?(resp.status)
          body = ctx.body_text
          return if body.nil? || body.empty?

          # One trimmed view shared by both cases: leading whitespace and a UTF-8 BOM removed, so
          # a body that merely starts with a newline or a BOM is judged on its first real byte.
          trimmed = body.lstrip { |c| c.whitespace? || c == '\uFEFF' }
          return if trimmed.empty?
          head_low = trimmed[0, {trimmed.size, SNIFF_PREFIX}.min].downcase

          ct = ctx.ct_low

          # --- case 2: JSON body under text/html -------------------------------------------
          if ct && ct.includes?("text/html") && json_body?(trimmed)
            acc << det(ctx, "mime_json_as_html", "JSON body served as text/html",
              Store::Severity::Low, "declared #{ct}")
          end

          # --- case 1: sniffable HTML body -------------------------------------------------
          # The two cases are mutually exclusive by construction (case 2 needs text/html, which
          # sniffable_type? rejects), but each is applied independently so neither depends on
          # the other's gate staying as it is.
          if html_body?(head_low) && sniffable_type?(ct) && !nosniff?(resp)
            evidence = ct.nil? ? "no Content-Type; body is HTML" : "declared #{ct}; body is HTML"
            acc << det(ctx, "mime_sniff_html", "Sniffable content served under a non-HTML type",
              Store::Severity::Low, evidence)
          end
        end

        # A 3xx redirect is never rendered (the UA follows it) and a 204 carries no body, so their
        # bodies cannot be sniffed or rendered — same render-context gate SecurityHeaders uses for
        # its document headers. A 4xx/5xx error page IS a rendered document and keeps the checks.
        private def rendered_document?(status : Int32) : Bool
          !((300..399).includes?(status) || status == 204)
        end

        # The body looks like a document a sniffer would commit to HTML: an HTML/script/SVG
        # opening tag, or a `<script` anywhere in the sniffed prefix.
        private def html_body?(head_low : String) : Bool
          return true if HTML_STARTS.any? { |m| head_low.starts_with?(m) }
          head_low.includes?("<script")
        end

        # Real JSON, not just a leading brace. The cheap prefix test comes first so the parse is
        # attempted only for a body that could plausibly be JSON; the parse itself is the actual
        # decision. A parse failure means "not JSON" — never an error for the caller.
        private def json_body?(trimmed : String) : Bool
          return false unless trimmed.starts_with?('{') || trimmed.starts_with?('[')
          begin
            JSON.parse(trimmed)
            true
          rescue
            false
          end
        end

        # A missing Content-Type, or a declared media type (parameters stripped) browsers sniff.
        private def sniffable_type?(ct : String?) : Bool
          return true if ct.nil?
          semi = ct.index(';')
          media = (semi ? ct[0...semi] : ct).strip
          SNIFFABLE_TYPES.includes?(media)
        end

        # `X-Content-Type-Options: nosniff` present ⇒ the browser honours the declared type and
        # never sniffs, so case 1 has no path to execution.
        private def nosniff?(resp : Proxy::Codec::RawResponse) : Bool
          resp.headers.get?("X-Content-Type-Options").try(&.downcase.strip) == "nosniff"
        end

        private def det(ctx : Context, code : String, title : String, sev : Store::Severity,
                        evidence : String? = nil) : Detection
          Detection.new(code, Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
