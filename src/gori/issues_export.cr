require "json"
require "./store"
require "./links"
require "./proxy/codec/content_decode"
require "./issues_export/sarif" # Export.sarif — the SARIF 2.1.0 sibling of .markdown/.json

module Gori
  module Issues
    # Serialises issues to a Markdown report or JSON. Extracted from the TUI's
    # IssuesController so the in-app export verb and `gori run issues` share one
    # source of truth. Pure: takes the issues + the store (to resolve linked flow
    # evidence) + the project name; returns a String.
    module Export
      # Per-side cap on evidence bytes embedded in the Markdown report.
      EVIDENCE_CAP = 64 * 1024

      def self.markdown(issues : Array(Store::Issue), store : Store, project_name : String) : String
        String.build do |io|
          io << "# Issues — " << project_name << "\n\n"
          io << "_" << issues.size << " issues · exported " << Time.local.to_s("%Y-%m-%d %H:%M") << "_\n"
          issues.each do |f|
            append_issue(io, f, f.flow_id.try { |fid| store.get_flow(fid) }, resolve_issue_links(f, store))
          end
        end
      end

      # The Markdown for ONE issue, heading included — the body of `markdown`'s loop, split out
      # because the SARIF exporter puts this same block in each result's `message.markdown`, so a
      # dashboard renders exactly what the operator already reads in the TUI's report. The leading
      # "\n" separates the blocks, exactly as it did inside the loop.
      #
      # `flow` and `resolved_links` arrive PRE-FETCHED rather than being read here, so a caller
      # that needs them for something else too (the SARIF exporter needs the flow for
      # webRequest/webResponse and the links for a property bag) pays for one store read per
      # issue instead of three.
      #
      # `evidence: false` omits the fenced request/response blocks. The SARIF exporter passes it
      # because those same bytes already ride structurally in `webRequest`/`webResponse`, and
      # embedding them twice roughly DOUBLED the document — enough to push an engagement past
      # the size limit on a `gh api .../code-scanning/sarifs` upload.
      private def self.append_issue(io : String::Builder, f : Store::Issue, flow : Store::FlowDetail?,
                                    resolved_links : Array(Links::Resolved), evidence : Bool = true) : Nil
        io << "\n## [" << f.severity.label << "] " << one_line(f.title) << "\n\n"
        io << "- **Severity:** " << f.severity.label << "\n"
        if cvss = f.cvss
          score = f.cvss_score
          io << "- **CVSS:** " << (score ? sprintf("%.1f", score) : one_line(cvss))
          io << " (" << one_line(cvss) << ")" if f.cvss_vector? && score
          io << "\n"
        end
        io << "- **Status:** " << f.status.label << "\n"
        io << "- **Host:** " << (f.host.try { |h| one_line(h) } || "—") << "\n"
        if fid = f.flow_id
          io << "- **Flow:** "
          if flow
            # method/target/host are captured (attacker/server-controlled) data — an embedded
            # newline (reachable via an h2 :path/:method pseudo-header) would break the one-line
            # structure, so sanitize them like f.title/f.host above.
            # `Url.absolute_form?`, not `starts_with?("http")`: the loose test calls
            # `httpbin.org/x` absolute and drops the host, and misses `HTTP://` (schemes
            # are case-insensitive, RFC 3986 3.1) so an uppercase target came out doubled
            # as `a.testHTTP://a.test/x`. Composed by hand rather than via `Url.location`
            # only because each part has to be `one_line`d first.
            loc = Url.absolute_form?(flow.row.target) ? one_line(flow.row.target) : "#{one_line(flow.row.host)}#{one_line(flow.row.target)}"
            io << one_line(flow.row.method) << " " << loc << " → " << (flow.row.status || "-") << " (#" << fid << ")\n"
          else
            io << "#" << fid << " (no longer captured)\n"
          end
        end
        append_related_links(io, resolved_links)
        # notes is multi-line by design (free text) — scrub_controls fixes invalid UTF-8
        # AND strips terminal escape sequences (ESC/BEL/OSC/CSI) so a notes value carrying
        # an OSC "set window title" can't drive a TTY when the report is printed/`cat`d,
        # yet keeps its newlines (unlike one_line, which would flatten title/host to a line).
        io << "\n" << scrub_controls(f.notes) << "\n" unless f.notes.strip.empty?
        if flow && evidence
          append_evidence(io, "Request", flow.request_head, flow.request_body)
          append_evidence(io, "Response", flow.response_head, flow.response_body)
        end
      end

      # An issue's related workbench entities, resolved for display. One place, because both
      # Markdown (`append_related_links`) and SARIF (a `gori/links` property bag) need the same
      # list and reading it twice per issue is two round-trips for one answer.
      protected def self.resolve_issue_links(f : Store::Issue, store : Store) : Array(Links::Resolved)
        Links.resolve_all(store,
          Links.dedupe_issue_flow(store.list_links(Store::LinkOwnerKind::Issue, f.id), f.flow_id))
      end

      def self.json(issues : Array(Store::Issue), store : Store? = nil) : String
        JSON.build do |j|
          j.array do
            issues.each do |f|
              j.object do
                j.field "id", f.id
                # title/host: normalise with one_line (scrub + collapse control chars) — they're
                # semantically single-line fields, so a raw newline is worth collapsing even though
                # JSON itself would tolerate it verbatim (an MCP tool response IS this same JSON
                # shape, and a client rendering "title" inline shouldn't see it split mid-string).
                j.field "title", one_line(f.title)
                j.field "severity", f.severity.label
                j.field "status", f.status.label
                j.field "cvss", f.cvss.try { |c| one_line(c) }
                j.field "cvss_score", f.cvss_score
                j.field "host", f.host.try { |h| one_line(h) }
                j.field "flow_id", f.flow_id
                j.field "created_at", f.created_at
                j.field "updated_at", f.updated_at
                # notes is multi-line BY DESIGN (free-text) — only the encoding-safety half of
                # one_line applies; collapsing its newlines would mangle a legitimate multi-line note.
                j.field "notes", scrub_only(f.notes)
                j.field "links" do
                  j.array { append_links_json(j, f, store) }
                end
              end
            end
          end
        end
      end

      # Fix invalid-UTF-8 bytes only, leaving control characters (incl. newlines) intact —
      # the encoding-safety half of `one_line`, split out for a field that is multi-line BY
      # DESIGN (e.g. an issue's free-text `notes`) and must not have its line breaks collapsed,
      # but still needs the same guarantee `one_line` exists for: a captured value can carry a
      # raw invalid byte (e.g. an h2 :path pseudo-header), and unscrubbed output either breaks
      # the exporter's encoding contract (JSON/Markdown must stay valid UTF-8) or crashes a
      # later PCRE gsub over it.
      def self.scrub_only(s : String) : String
        s.scrub
      end

      # Terminal-safety sibling of `one_line`: neutralize the control characters a TTY would
      # interpret as escape sequences — ESC (0x1B), BEL (0x07), the CSI/OSC introducers, and
      # every other C0/C1 control — while PRESERVING newlines and tabs so a multi-line value
      # (an issue's free-text `notes`, a note body) keeps its structure. Stripping the control
      # BYTES defangs OSC/CSI sequences without modelling the full grammar: an OSC "set window
      # title" or OSC 52 clipboard-write can no longer reach the terminal. Use this for text
      # printed to STDOUT/a TTY — unlike one_line it does NOT collapse to a single line, and
      # unlike scrub_only it does NOT leave ESC/BEL intact. (scrub first: a captured value can
      # be invalid UTF-8, which would make the following per-char walk operate on U+FFFD safely.)
      def self.scrub_controls(s : String) : String
        scrub_only(s).gsub { |ch| ch.control? && ch != '\n' && ch != '\t' ? "" : ch }
      end

      # Collapse control characters (CR/LF/tab/…) to a single space so a value with
      # embedded newlines can't break the single-line structure it sits in — a
      # Markdown heading here, a one-row line in the text export. Shared with
      # `gori run issues --format text`.
      def self.one_line(s : String) : String
        # scrub: captured values (target/host/method/title, e.g. an h2 :path with a raw byte) can
        # be invalid UTF-8, which would make the PCRE gsub raise and crash the markdown/text export.
        scrub_only(s).gsub(/[[:cntrl:]]+/, " ").strip
      end

      private def self.append_related_links(io : String::Builder, resolved : Array(Links::Resolved)) : Nil
        return if resolved.empty?
        io << "\n### Related\n\n"
        resolved.each do |res|
          io << "- **" << res.tag << "** " << one_line(res.url)
          io << " — " << one_line(res.label)
          io << " (stale)" if res.stale?
          io << "\n"
        end
      end

      def self.append_links_json(j : JSON::Builder, f : Store::Issue, store : Store?) : Nil
        return unless store
        links = Links.dedupe_issue_flow(
          store.list_links(Store::LinkOwnerKind::Issue, f.id), f.flow_id)
        Links.resolve_all(store, links).each do |res|
          j.object do
            j.field "kind", res.link.ref_kind.label
            j.field "ref_id", res.link.ref_id
            # `one_line`, exactly like the title/host fields of the object this array sits in —
            # and like `append_related_links`, the Markdown sibling twenty lines up, which has
            # always one_line'd this same pair. Both values are built from CAPTURED bytes
            # (`Links.resolve_flow` composes them from the flow's method/host/target, which
            # `Codec::Http1.parse_request_head` builds with a plain `String.new` over the wire),
            # so an h2 `:path` carrying a raw 0x80 landed here verbatim: `Export.json` returned a
            # string whose `valid_encoding?` was FALSE, and `Serialize.issue` — which delegates
            # this array — put that byte on a JSON-RPC line, breaking the WHOLE response for a
            # strict client. That is the very gap `Serialize.issue`'s own comment claims to close
            # for title/host/notes one field earlier, and `Serialize.text`'s contract ("every
            # string that ORIGINATED OUTSIDE gori must pass through here before it reaches
            # JSON::Builder") names as mandatory.
            j.field "url", one_line(res.url)
            j.field "label", one_line(res.label)
            j.field "stale", res.stale?
          end
        end
      end

      # The displayable view of ONE captured body, and the single place the evidence rules live:
      # de-chunk + inflate Content-Encoding, cap at EVIDENCE_CAP, cut on a codepoint boundary,
      # and DROP a body whose readable prefix isn't valid UTF-8 rather than emit mojibake. Shared
      # by the Markdown report (which fences `text` and prints a note for `binary?`) and the SARIF
      # exporter (which puts `text` in the result's webRequest/webResponse body), so the two can
      # never disagree about what a body says or how much of it survived.
      #
      # `size` is the DECODED byte count — what the note reports — not the stored wire size.
      record BodyEvidence, text : String?, size : Int32, truncated : Bool do
        # A body that was there but could not be shown, as opposed to no body at all. The two
        # differ in the report: one prints "[binary body omitted, N bytes]", the other nothing.
        def binary? : Bool
          text.nil? && size > 0
        end

        def truncated? : Bool
          truncated
        end
      end

      private def self.body_evidence(head : Bytes, body : Bytes?) : BodyEvidence
        return BodyEvidence.new(nil, 0, false) if body.nil? || body.empty?
        # De-chunk + inflate Content-Encoding for display, mirroring `gori run show` and the
        # TUI detail view — otherwise a chunked body embeds its wire-format chunk framing
        # verbatim, and a gzip/br/deflate body (the common case for real HTTPS traffic) fails
        # the valid-UTF-8 check below and gets dropped as "binary", silently discarding the
        # evidence a shared report exists to preserve.
        decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
        display_body = decoded || body
        truncated = display_body.size > EVIDENCE_CAP
        # Decide text-vs-binary on the readable PREFIX (≤ cap), not the whole body: a body
        # that is valid text up to the cap but has a stray byte deeper still shows its
        # readable prefix. But back the cut off to a UTF-8 codepoint boundary first, so a
        # multi-byte char split at exactly `cap` isn't misread as binary.
        slice = truncated ? trim_to_codepoint_boundary(display_body[0, EVIDENCE_CAP]) : display_body
        text = String.new(slice)
        BodyEvidence.new(text.valid_encoding? ? text : nil, display_body.size, truncated)
      end

      private def self.append_evidence(io : String::Builder, label : String, head : Bytes?, body : Bytes?) : Nil
        return if head.nil? || head.empty?
        cap = EVIDENCE_CAP
        # Build the embedded request/response text first, THEN pick a fence longer
        # than any backtick run inside it. Bodies are fully attacker-controlled
        # (proxied traffic), so a bare ``` line in a body would otherwise close the
        # ```http fence early and inject live Markdown/HTML into the shared report.
        content = String.build do |c|
          # HEAD: headers are text but can carry stray non-UTF-8 (obs-text) bytes —
          # scrub them so the report stays valid UTF-8; cap it like the body. rstrip
          # the header block's trailing CRLF CRLF so a single blank line (added
          # below) sits between headers and body instead of a stack of empty lines.
          hslice = head.size > cap ? head[0, cap] : head
          c << String.new(hslice).scrub.rstrip
          c << "\n\n[… headers truncated, #{head.size} bytes total …]" if head.size > cap
          ev = body_evidence(head, body)
          if text = ev.text
            c << "\n\n" << text
            c << "\n\n[… body truncated, #{ev.size} bytes total …]" if ev.truncated?
          elsif ev.binary?
            c << "\n\n[binary body omitted, #{ev.size} bytes]"
          end
        end
        fence = "`" * fence_len(content)
        io << "\n### " << label << "\n\n" << fence << "http\n"
        io << content << "\n" << fence << "\n"
      end

      # Drop a UTF-8 sequence the `cap` cut left incomplete: walk back over trailing
      # continuation bytes (10xxxxxx), then over the lead byte (11xxxxxx) they belonged to.
      # Leaves the slice ending on a whole codepoint so a split char isn't read as binary.
      private def self.trim_to_codepoint_boundary(slice : Bytes) : Bytes
        n = slice.size
        while n > 0 && (slice[n - 1] & 0xC0) == 0x80 # continuation byte
          n -= 1
        end
        n -= 1 if n > 0 && (slice[n - 1] & 0xC0) == 0xC0 # the lead byte whose tail was cut
        slice[0, n]
      end

      # A CommonMark fenced block is closed only by a line of >= as many backticks
      # as the opener, so use one more than the longest backtick run in the content
      # (minimum 3) — guaranteeing no embedded line can terminate it.
      private def self.fence_len(content : String) : Int32
        longest = 0
        run = 0
        content.each_char do |ch|
          if ch == '`'
            run += 1
            longest = run if run > longest
          else
            run = 0
          end
        end
        {3, longest + 1}.max
      end
    end
  end
end
