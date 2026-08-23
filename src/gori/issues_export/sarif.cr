require "digest/sha256"
require "json"
require "sarif"
require "../store"
require "../links"
require "../proxy/codec/http1"

module Gori
  module Issues
    # SARIF 2.1.0 for the Issues report — the format CI security dashboards ingest (GitHub
    # code scanning, DefectDojo, Azure DevOps), so an engagement's confirmed issues can be
    # UPLOADED rather than pasted. Third sibling of `Export.markdown` / `Export.json` and
    # built the same way: pure, takes the issues + the store (to resolve linked flow
    # evidence) + the project name, returns a String.
    #
    # A separate file rather than more of `issues_export.cr` for the reason `export/har.cr`
    # is one: a format with a schema of its own carries enough mapping decisions — five
    # severities into four levels, a triage status into suppressions, a free-text title into
    # a rule — that they want their own place to be argued in.
    module Export
      # gori is a WEB proxy, so a finding's location is a URL, not a source file, and its
      # evidence is an HTTP exchange. SARIF models both: `artifactLocation.uri` takes any
      # URI, and `webRequest`/`webResponse` exist precisely for tools like this one.
      module Sarif
        # The tool's identity in every log it writes.
        DRIVER_NAME = "gori"

        # Rule ids are namespaced so they can't collide with another tool's in an aggregated
        # dashboard, and so a `gori/issue/` prefix is greppable in a rules list.
        RULE_PREFIX = "gori/issue/"

        # Prefix for the rule a title slugs to when it has no letters or digits at all (an
        # issue titled "???" or "———"); a digest of the title is appended so two such titles
        # do not silently share one rule.
        FALLBACK_SLUG = "untitled"

        # Cap on the slug, so a 400-character pasted title doesn't become a 400-character
        # rule id in someone's dashboard.
        SLUG_CAP = 60

        # SARIF has four levels; gori has five severities. Both halves of the collapse are
        # recorded so it stays reversible: `rank` (0–100, SARIF's own ordering axis) and the
        # rule's `security-severity` property, which is what GitHub code scanning reads to
        # draw a severity badge. Without them a Critical and a High arrive indistinguishable.
        def self.level(severity : Store::Severity) : ::Sarif::Level
          case severity
          in .critical?, .high? then ::Sarif::Level::Error
          in .medium?           then ::Sarif::Level::Warning
          in .low?, .info?      then ::Sarif::Level::Note
          end
        end

        def self.rank(severity : Store::Severity) : Float64
          case severity
          in .critical? then 100.0
          in .high?     then 75.0
          in .medium?   then 50.0
          in .low?      then 25.0
          in .info?     then 0.0
          end
        end

        # GitHub's `security-severity` is a CVSS-shaped number carried as a STRING (that is
        # what the consumer expects — not a JSON number), and its bands are
        # critical ≥ 9.0, high ≥ 7.0, medium ≥ 4.0, low ≥ 0.1.
        def self.security_severity(severity : Store::Severity) : String
          case severity
          in .critical? then "9.0"
          in .high?     then "7.0"
          in .medium?   then "5.0"
          in .low?      then "3.0"
          in .info?     then "0.0"
          end
        end

        # A stable rule id from the issue's free-text title, so a consumer groups repeats of
        # the same finding. Two near-identical titles ("XSS!" and "XSS?") can slug to one id;
        # that is benign — they share a rule, which is what grouping means — and the exact
        # title survives on the rule's shortDescription and each result's message.
        #
        # `\p{L}\p{N}`, NOT `a-z0-9`: an ASCII-only class DELETES a Korean or Japanese title
        # outright, so every finding in a non-Latin engagement collapsed into one meaningless
        # `untitled` rule wearing whichever title happened to land first — and this project
        # ships Korean docs. SARIF puts no charset constraint on `reportingDescriptor.id`, so
        # "취약점-발견" is both legal and the more useful id.
        #
        # Truncation is by CHARACTER (Crystal's String#[] is char-indexed), so the cap can't
        # cut a multi-byte codepoint in half.
        def self.rule_id(title : String) : String
          normalized = Export.one_line(title)
          slug = normalized.downcase.gsub(/[^\p{L}\p{N}]+/, "-").strip('-')
          # A title with no letters or digits AT ALL ("???", "———"). A shared bucket would
          # group findings that have nothing to do with each other, so key the fallback on the
          # title itself — distinct nonsense titles still get distinct rules.
          slug = "#{FALLBACK_SLUG}-#{Digest::SHA256.hexdigest(normalized)[0, 8]}" if slug.empty?
          slug = slug[0, SLUG_CAP].rstrip('-') if slug.size > SLUG_CAP
          "#{RULE_PREFIX}#{slug}"
        end
      end

      def self.sarif(issues : Array(Store::Issue), store : Store, project_name : String) : String
        # One rule per DISTINCT title, in first-seen order, so `find_rule_index` links each
        # result to its rule and a repeated finding collapses to one entry in a rules list.
        rules = {} of String => String # rule id => the title that first claimed it
        issues.each do |f|
          title = one_line(f.title)
          rules[Sarif.rule_id(title)] ||= title
        end

        # ONE store read per issue for each of the two things every pass below wants. The flow
        # was previously fetched three times (location, markdown message, webRequest/Response)
        # and its body inflated twice; the links were resolved twice. That ran synchronously on
        # the TUI's UI fiber, so a large issue list stalled the interface.
        flows = issues.map { |f| f.flow_id.try { |fid| store.get_flow(fid) } }
        links = issues.map { |f| Export.resolve_issue_links(f, store) }

        log = ::Sarif::Builder.build do |b|
          b.run(Sarif::DRIVER_NAME, Gori::VERSION) do |r|
            r.information_uri(Gori::REPOSITORY_URL)
            rules.each { |id, title| r.rule(id, short_description: title) }
            issues.each_with_index { |f, i| sarif_result(r, f, flows[i], links[i]) }
          end
        end

        run = log.runs[0]
        # `Builder` drops an empty results array to `nil`. An explicit `[]` is the friendlier
        # document: "this tool ran and found nothing" rather than "this tool may not have run".
        run.results ||= [] of ::Sarif::Result
        # Results FIRST: a rule's `security-severity` is the worst severity among the results
        # that cite it, and it reads those off the property bags this pass writes.
        annotate_results(run, issues, flows, links, project_name)
        annotate_rules(run)
        log.to_pretty_json
      end

      # The parts of a result the fluent `ResultBuilder` has no hook for — `rank`, the
      # property bag, and webRequest/webResponse. Done as a post-pass over the built run
      # rather than by hand-constructing `Sarif::Result`s, so rule-index linking, message
      # and suppression wiring stay the library's job. Results come back in `issues` order,
      # which is what makes the zip below sound.
      private def self.annotate_results(run : ::Sarif::Run, issues : Array(Store::Issue),
                                        flows : Array(Store::FlowDetail?),
                                        links : Array(Array(Links::Resolved)),
                                        project_name : String) : Nil
        results = run.results
        return unless results
        results.each_with_index do |res, i|
          f = issues[i]
          res.rank = Sarif.rank(f.severity)
          bag = ::Sarif::PropertyBag.new
          bag["gori/project"] = JSON::Any.new(one_line(project_name))
          bag["gori/issueId"] = JSON::Any.new(f.id)
          bag["gori/severity"] = JSON::Any.new(f.severity.label) # the UNcollapsed five-way value
          bag["gori/status"] = JSON::Any.new(f.status.label)
          bag["gori/createdAt"] = JSON::Any.new(rfc3339(f.created_at))
          bag["gori/updatedAt"] = JSON::Any.new(rfc3339(f.updated_at))
          f.host.try { |h| bag["gori/host"] = JSON::Any.new(one_line(h)) }
          f.flow_id.try { |fid| bag["gori/flowId"] = JSON::Any.new(fid) }
          link_json = sarif_links(links[i])
          bag["gori/links"] = JSON::Any.new(link_json) unless link_json.empty?
          res.properties = bag

          if flow = flows[i]
            res.web_request = sarif_web_request(flow)
            res.web_response = sarif_web_response(flow)
          end
        end
      end

      # `tags: ["security"]` is the convention that marks a rule as a security finding, and
      # `security-severity` is what renders its badge. Both belong on the RULE, not the
      # result — that is where every consumer looks for them.
      private def self.annotate_rules(run : ::Sarif::Run) : Nil
        descriptors = run.tool.driver.rules
        return unless descriptors
        # Keyed off each descriptor's own id rather than its position: the rules were
        # registered in insertion order, but a positional zip would silently mislabel every
        # severity if that ever stopped holding.
        descriptors.each do |d|
          bag = ::Sarif::PropertyBag.new(tags: ["security", "gori"])
          bag["security-severity"] = JSON::Any.new(rule_security_severity(run, d.id))
          d.properties = bag
        end
      end

      # The severity a rule's badge should show: the worst severity among the results that
      # cite it AND are still live. A rule shared by a Critical and a Low is a Critical in a
      # dashboard's list, which is the reading an operator triaging from that list needs.
      #
      # SUPPRESSED results are excluded, because GitHub applies this badge PER ALERT, not just
      # in the rules list: a Critical the operator triaged to false-positive was otherwise
      # stamping 9.0 onto the one remaining open Info alert that happened to share its title.
      # When every result for a rule is suppressed there is no live severity to show, so fall
      # back to the worst of them rather than silently badging the rule Info.
      private def self.rule_security_severity(run : ::Sarif::Run, rule_id : String) : String
        live = nil.as(Store::Severity?)
        any = nil.as(Store::Severity?)
        run.results.try &.each do |res|
          next unless res.rule_id == rule_id
          sev = res.properties.try(&.get_string("gori/severity")).try { |l| Store::Severity.parse?(l) }
          next unless sev
          any = sev if any.nil? || sev.value > any.not_nil!.value
          next if res.suppressions.try { |sup| !sup.empty? }
          live = sev if live.nil? || sev.value > live.not_nil!.value
        end
        Sarif.security_severity(live || any || Store::Severity::Info)
      end

      private def self.sarif_result(r : ::Sarif::RunBuilder, f : Store::Issue,
                                    flow : Store::FlowDetail?, links : Array(Links::Resolved)) : Nil
        title = one_line(f.title)
        r.result do |rb|
          # text is the one-line summary a list renders; markdown is the same per-issue block
          # the Markdown report writes MINUS the evidence fences — the request and response are
          # already on this result as webRequest/webResponse, and carrying them twice doubled
          # the document for no reader's benefit.
          rb.message(sarif_message_text(f, title),
            markdown: String.build { |io| append_issue(io, f, flow, links, evidence: false) })
          rb.rule_id(Sarif.rule_id(title))
          rb.level(Sarif.level(f.severity))
          sarif_location(rb, f, flow)
          sarif_suppression(rb, f)
          # `gori/issueId` addresses THIS project DB; `gori/finding` survives a re-created one,
          # which is what lets a dashboard recognise the same finding across engagements.
          rb.partial_fingerprint("gori/issueId", f.id.to_s)
          rb.partial_fingerprint("gori/finding",
            Digest::SHA256.hexdigest("#{title}\n#{f.host}\n#{f.severity.label}"))
        end
      end

      private def self.sarif_message_text(f : Store::Issue, title : String) : String
        notes = scrub_only(f.notes).strip
        notes.empty? ? title : "#{title}\n\n#{notes}"
      end

      # A web finding's location is a URL. Prefer the linked flow's — `FlowRow#url` is the one
      # place the scheme/host/port/target composition lives, default ports and IPv6 brackets
      # included — then fall back to the issue's bare host, then to no location at all rather
      # than inventing one.
      private def self.sarif_location(rb : ::Sarif::ResultBuilder, f : Store::Issue,
                                      flow : Store::FlowDetail?) : Nil
        if flow
          rb.location(uri: one_line(flow.row.url))
          return
        end
        host = f.host.try { |h| one_line(h) }
        rb.location(uri: "https://#{host}/") if host && !host.empty?
      end

      # A false-positive that arrives at a dashboard as an open finding is worse than not
      # exporting it: `suppressions` is how SARIF says "triaged away". `External` because the
      # judgement lives in gori's project DB, not in an annotation in the scanned artifact.
      # The raw label always also rides in `gori/status`, so nothing is lost either way.
      private def self.sarif_suppression(rb : ::Sarif::ResultBuilder, f : Store::Issue) : Nil
        justification =
          case f.status
          when .false_positive? then "marked false-positive in gori"
          when .resolved?       then "resolved in gori"
          else                       return
          end
        rb.suppression(::Sarif::SuppressionKind::External,
          justification: justification,
          status: ::Sarif::SuppressionStatus::Accepted)
      end

      private def self.sarif_web_request(flow : Store::FlowDetail) : ::Sarif::WebRequest
        req = Proxy::Codec::Http1.parse_request_head(flow.request_head)
        row = flow.row
        ::Sarif::WebRequest.new(
          protocol: one_line(row.scheme),
          version: sarif_http_version(req.version.presence || flow.http_version),
          target: one_line(row.url),
          # The start-line is the truth (P7): a lowercase or non-standard method is the
          # operator's, and `row.method` is the upcased projection of it. Same rule the HAR
          # writer follows.
          method: one_line(req.method.presence || row.method),
          headers: sarif_headers(req.headers),
          body: sarif_body(flow.request_head, flow.request_body),
        )
      end

      private def self.sarif_web_response(flow : Store::FlowDetail) : ::Sarif::WebResponse?
        head = flow.response_head
        # An Error/Aborted flow never got one. SARIF says so explicitly rather than emitting
        # a webResponse full of nils.
        return ::Sarif::WebResponse.new(no_response_received: true) if head.nil? || head.empty?
        resp = Proxy::Codec::Http1.parse_response_head(head)
        row = flow.row
        ::Sarif::WebResponse.new(
          protocol: one_line(row.scheme),
          # The RESPONSE's own version, not the request's — 1.0 vs 1.1 is semantically
          # load-bearing (no default keep-alive), and `http_version` is the request column.
          version: sarif_http_version(resp.version.presence || flow.http_version),
          status_code: row.status || resp.status,
          # `.presence`: HTTP/2 has no reason phrase by design (HeadCodec.synth_response stops
          # at the code) and an h1 status line may omit it, and `"reasonPhrase": ""` is noise —
          # every other optional field in this record omits itself the same way.
          reason_phrase: one_line(resp.reason).presence,
          headers: sarif_headers(resp.headers),
          body: sarif_body(head, flow.response_body),
        )
      end

      # SARIF's `version` is the protocol version alone ("1.1"), while gori stores and parses
      # the full token ("HTTP/1.1"). Strip the name so the field means what the schema says.
      private def self.sarif_http_version(version : String) : String?
        v = one_line(version)
        v = v[5..] if v.size > 5 && v[0, 5].compare("HTTP/", case_insensitive: true) == 0
        v.presence
      end

      # SARIF's `headers` is a JSON object, but HTTP allows repeats (Set-Cookie above all), so
      # fold duplicates by joining with ", " — the standard collapse, and the same one a
      # combined field-value would have used on the wire. Names and values are `one_line`d
      # because header BYTES are attacker-controlled and can be invalid UTF-8 (an obs-text or
      # an h2 pseudo-header carrying a raw 0x80): unscrubbed, one of them makes the whole
      # document fail `valid_encoding?` and breaks it for a strict consumer.
      private def self.sarif_headers(list : Proxy::Codec::HeaderList) : Hash(String, String)?
        out = {} of String => String
        seen = {} of String => String # downcased name => the casing first seen on the wire
        list.each do |h|
          name = one_line(h.name)
          next if name.empty?
          value = one_line(h.value)
          # Fold on the DOWNCASED name — field names are case-insensitive (RFC 9110 §5.1), so a
          # head carrying both `set-cookie` and `Set-Cookie` is one field with two values, and
          # keying on the raw name emitted it as two JSON keys instead of one folded value.
          # The first casing seen is what's displayed, so the output still looks like the wire.
          key = seen[name.downcase] ||= name
          if prev = out[key]?
            out[key] = "#{prev}, #{value}"
          else
            out[key] = value
          end
        end
        out.empty? ? nil : out
      end

      # The body as `artifactContent.text`, through the SAME evidence rules the Markdown
      # report uses (`Export.body_evidence`): decoded, capped at EVIDENCE_CAP, cut on a
      # codepoint boundary, binary dropped. A truncated body says so inline — a consumer
      # reading 64 KiB of a 5 MiB response must not think it has the whole thing.
      private def self.sarif_body(head : Bytes, body : Bytes?) : ::Sarif::ArtifactContent?
        ev = body_evidence(head, body)
        text = ev.text
        return nil unless text
        text += "\n\n[… body truncated, #{ev.size} bytes total …]" if ev.truncated?
        ::Sarif::ArtifactContent.new(text: text)
      end

      # The issue's related workbench entities, as the same {kind, url, label, stale} shape
      # `Export.json` emits — one vocabulary across both machine formats. Pure: the resolve
      # itself happened once, up in `sarif`.
      private def self.sarif_links(resolved : Array(Links::Resolved)) : Array(JSON::Any)
        resolved.map do |res|
          JSON::Any.new({
            "kind"   => JSON::Any.new(res.link.ref_kind.label),
            "ref_id" => JSON::Any.new(res.link.ref_id),
            "url"    => JSON::Any.new(one_line(res.url)),
            "label"  => JSON::Any.new(one_line(res.label)),
            "stale"  => JSON::Any.new(res.stale?),
          })
        end
      end

      # gori stores timestamps as unix MICROseconds; SARIF property values are free-form, so
      # emit RFC 3339 UTC rather than a raw integer a human can't read in a dashboard.
      private def self.rfc3339(micros : Int64) : String
        Time.unix_ms(micros // 1000).to_utc.to_rfc3339
      end
    end
  end
end
