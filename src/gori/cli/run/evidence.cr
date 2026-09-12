# `gori run evidence` — FROZEN evidence (#1038/#1039): the immutable copy of one exchange,
# taken from a captured Flow or a Repeater tab at the moment it proved the finding. `links`
# is the pointer; this is the bytes. A script that confirms a finding and then retests the
# fix freezes twice and the issue holds both.
#
# Issue membership is many-to-many and mutable (`link`/`unlink`) while the bytes are not, so
# `list` without `--issue` is the headless twin of the TUI's Evidence tab: the project-wide
# archive, orphans included. Anything narrower could not name a snapshot whose last Issue
# link is gone, which is exactly the copy that needs finding.
require "../../evidence"
require "../../mcp/serialize"

module Gori
  module CLI
    module Run
      @[Subcommand("evidence", help: [
        {"evidence", "Freeze/list/show/link/unlink/delete frozen request+response copies"},
      ])]
      private def self.cmd_evidence(args : Array(String)) : Nil
        case sub = args.first?
        when "freeze"       then cmd_evidence_freeze(args[1..])
        when "list"         then cmd_evidence_list(args[1..])
        when "show"         then cmd_evidence_show(args[1..])
        when "link"         then cmd_evidence_membership(args[1..], link: true)
        when "unlink"       then cmd_evidence_membership(args[1..], link: false)
        when "delete", "rm" then cmd_evidence_delete(args[1..])
        else
          # See `verb_token?` — a bare word here is a mistyped verb, not a query.
          if verb_token?(sub)
            abort "gori run evidence: unknown subcommand '#{sub}' (freeze, list, show, link, unlink, delete/rm)"
          end
          cmd_evidence_list(args)
        end
      end

      private def self.cmd_evidence_freeze(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        ref_s : String? = nil
        ref_id : Int64? = nil
        link = true
        allow_drift = false
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run evidence freeze --issue=N --ref=flow|repeater --ref-id=M [--no-link]\n\n" \
                     "Copy a flow's or a Repeater tab's CURRENT exchange into immutable evidence on\n" \
                     "issue N: request, response, status, timing, protocol, error and truncation\n" \
                     "state, with a SHA-256 of each. The Repeater's next send and History retention\n" \
                     "cannot reach the copy. Freeze again after a retest to keep both.\n" \
                     "A Repeater tab that has never been sent is refused: there is no exchange,\n" \
                     "and so is one whose request was edited after its stored response arrived —\n" \
                     "that pair never happened. Send it again, or --allow-drift to keep it anyway."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--issue=N", "Issue id that owns the copy (required)") { |v| issue_id = parse_evidence_id(v, "--issue") }
          p.on("--ref=KIND", "Source kind: flow | repeater (required)") { |v| ref_s = v.strip.downcase }
          p.on("--ref-id=M", "Source id (required)") { |v| ref_id = parse_evidence_id(v, "--ref-id") }
          p.on("--no-link", "Only copy — do not also file the live link `links add` would") { link = false }
          p.on("--allow-drift", "Freeze a Repeater tab whose request was edited after its stored response") { allow_drift = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run evidence freeze: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run evidence freeze: missing value for #{f}" }
        end
        parser.parse(args)
        # Deferred past `parse` for the reason `cmd_links_mutate` gives: the unknown-args
        # callback runs before the flag sweep, so aborting inside it misdiagnoses a typo'd flag.
        unless leftover.empty?
          abort "gori run evidence freeze: unexpected argument#{leftover.size == 1 ? "" : "s"} " \
                "#{leftover.join(" ").inspect} — every end is named by a flag (--issue, --ref, --ref-id)"
        end
        iid, kind, rid = resolve_freeze_ends(issue_id, ref_s, ref_id)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          abort "gori run evidence freeze: no issue with id #{iid}" unless store.get_issue(iid)
          snap = Evidence.snapshot_for(store, kind, rid)
          abort "gori run evidence freeze: #{snap}" if snap.is_a?(String)
          # REFUSED by default, where the TUI asks: this command is what a script calls, and a
          # script cannot look at the tab. `--allow-drift` is the operator saying they already
          # know — the copy is still written, still labelled evidence, and the sentence names
          # the flag so nobody has to find it.
          if drift = Evidence.drift_refusal(snap, allow_drift, "--allow-drift")
            abort "gori run evidence freeze: #{drift}"
          end
          id, status = store.freeze_evidence(iid, snap, link: link)
          case status
          in .issue_gone? then abort "gori run evidence freeze: issue ##{iid} was deleted before the copy was written"
          in .quota?
            abort "gori run evidence freeze: evidence quota reached (#{store.evidence_bytes} of #{Evidence::QUOTA_BYTES} bytes used) — delete a frozen copy first"
          in .busy? then abort "gori run evidence freeze: nothing frozen (project busy or unwritable)"
          in .ok?   then nil
          end
          meta = store.get_evidence_meta(id) || abort("gori run evidence freeze: frozen evidence ##{id} vanished before it could be read back")
          if format == :json
            puts(JSON.build { |j| j.object { MCP::Serialize.evidence_meta(j, meta); j.field "linked", link } })
          else
            puts "Frozen evidence ##{id} on issue ##{iid} from #{meta.source_label}#{link ? " (linked)" : ""}: " \
                 "#{Evidence.label(meta)} → #{meta.status || (meta.error ? "error" : "no response")}, #{meta.bytes} bytes"
            puts "  sha256 req #{meta.request_sha256}"
            puts "  sha256 res #{meta.response_sha256 || "— (no response)"}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_evidence_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run evidence [list] [--issue=N]\n\n" \
                     "List frozen evidence: source, when the copy was taken, status, size, the\n" \
                     "Issues it is linked to and the SHA-256 of the stored request and response.\n" \
                     "Never the bytes — those are `gori run evidence show ID`.\n\n" \
                     "Without --issue this is the whole project archive, newest first, INCLUDING\n" \
                     "orphans (a snapshot whose last Issue link was removed, or whose Issue was\n" \
                     "deleted) — the copies no per-issue listing can reach.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run evidence freeze --issue=N --ref=flow|repeater --ref-id=M [--no-link]\n" \
                     "  gori run evidence show ID [--include-sensitive] [--format=json]\n" \
                     "  gori run evidence link ID --issue=N\n" \
                     "  gori run evidence unlink ID --issue=N\n" \
                     "  gori run evidence delete ID   (`rm` is accepted)"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--issue=N", "Issue id (omit for the whole project archive)") { |v| issue_id = parse_evidence_id(v, "--issue") }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run evidence: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run evidence: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "evidence", "freeze, list, show, link, unlink, delete/rm")
        iid = issue_id

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        metas = begin
          if iid
            abort "gori run evidence: no issue with id #{iid}" unless store.get_issue(iid)
            store.issue_evidence(iid)
          else
            store.evidence
          end
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build { |j| j.array { metas.each { |m| j.object { MCP::Serialize.evidence_meta(j, m) } } } })
        elsif metas.empty?
          puts iid ? "no frozen evidence on issue ##{iid}" : "no frozen evidence in this project"
        else
          metas.each { |m| puts evidence_line(m) }
        end
      end

      private def self.cmd_evidence_show(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        include_sensitive = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run evidence show ID [--include-sensitive] [--format=text|json]\n\n" \
                     "Print one frozen copy: its provenance, then the request and the response as\n" \
                     "they were stored. Authorization / Cookie / Set-Cookie / API-key values read\n" \
                     "[REDACTED] unless --include-sensitive; the SHA-256s cover the stored wire\n" \
                     "bytes, so verifying them needs the raw head. Bodies are decoded and capped\n" \
                     "at #{Issues::Export::EVIDENCE_CAP} bytes on the text form."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--include-sensitive", "Emit credential header values verbatim instead of [REDACTED]") { include_sensitive = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run evidence show: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run evidence show: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run evidence show: too many arguments (expected one <id>, got: #{positional.join(" ")})" if positional.size > 1
        id_s = positional.first? || abort("gori run evidence show: <id> is required")
        id = parse_evidence_id(id_s, "<id>")

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        ev = begin
          store.get_evidence(id) || abort("gori run evidence show: no frozen evidence with id #{id}")
        ensure
          store.close
        end

        if format == :json
          puts MCP::Serialize.evidence_json(ev, include_sensitive)
        else
          puts evidence_text(ev, include_sensitive)
        end
      end

      # Issue membership is mutable; the snapshot and its hashes are not. Link and unlink
      # therefore name the frozen copy positionally and the Issue explicitly, rather than
      # reusing the live entity-link command whose target is a source object.
      private def self.cmd_evidence_membership(args : Array(String), *, link : Bool) : Nil
        verb = link ? "link" : "unlink"
        db_path : String? = nil
        project_name : String? = nil
        issue_id : Int64? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run evidence #{verb} ID --issue=N\n\n" \
                     "#{link ? "Attach" : "Detach"} an Issue without changing the frozen bytes, hashes, or provenance. " \
                     "Removing the last Issue leaves an orphan; it does not delete the snapshot."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--issue=N", "Issue id (required)") { |v| issue_id = parse_evidence_id(v, "--issue") }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run evidence #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run evidence #{verb}: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run evidence #{verb}: too many arguments (expected one <id>, got: #{positional.join(" ")})" if positional.size > 1
        id_s = positional.first? || abort("gori run evidence #{verb}: <id> is required")
        id = parse_evidence_id(id_s, "<id>")
        iid_opt = issue_id
        abort "gori run evidence #{verb}: --issue is required" if iid_opt.nil?
        iid = iid_opt

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          meta = store.get_evidence_meta(id) || abort("gori run evidence #{verb}: no frozen evidence with id #{id}")
          abort "gori run evidence #{verb}: no issue with id #{iid}" unless store.get_issue(iid)
          if link
            evidence_link_one(store, meta, iid)
          else
            evidence_unlink_one(store, meta, iid)
          end
        ensure
          store.close
        end
      end

      # An already-linked pair is reported, not refused: `link` states an end state, and a
      # script that runs twice has not failed. `unlink` DOES refuse a pair that is not
      # linked — there the end state is reached by doing nothing, but naming a link that
      # was never there is a typo'd id far more often than it is idempotence.
      private def self.evidence_link_one(store : Store, meta : Store::IssueEvidenceMeta, iid : Int64) : Nil
        if meta.issue_ids.includes?(iid)
          puts "Frozen evidence ##{meta.id} was already linked to issue ##{iid}."
          return
        end
        abort "gori run evidence link: NOT linked (project busy or either row disappeared)" unless store.link_evidence(meta.id, iid)
        puts "Linked frozen evidence ##{meta.id} to issue ##{iid}."
      end

      private def self.evidence_unlink_one(store : Store, meta : Store::IssueEvidenceMeta, iid : Int64) : Nil
        unless meta.issue_ids.includes?(iid)
          abort "gori run evidence unlink: frozen evidence ##{meta.id} is not linked to issue ##{iid}"
        end
        abort "gori run evidence unlink: NOT unlinked (project busy or link disappeared)" unless store.unlink_evidence(meta.id, iid)
        orphaned = store.get_evidence_meta(meta.id).try(&.orphaned?) || false
        puts "Unlinked frozen evidence ##{meta.id} from issue ##{iid}.#{orphaned ? " The snapshot is now orphaned." : ""}"
      end

      private def self.cmd_evidence_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run evidence delete ID\n\n" \
                     "Delete one frozen copy. Its bytes cannot be recovered from the source — that is\n" \
                     "why they were frozen — so prefer freezing a newer copy beside it."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run evidence delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run evidence delete: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run evidence delete: too many arguments (expected one <id>, got: #{positional.join(" ")})" if positional.size > 1
        id_s = positional.first? || abort("gori run evidence delete: <id> is required")
        id = parse_evidence_id(id_s, "<id>")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          meta = store.get_evidence_meta(id) || abort("gori run evidence delete: no frozen evidence with id #{id}")
          abort "gori run evidence delete: NOT deleted (project busy or unwritable) — the copy is unchanged" unless store.delete_evidence(id)
          linked = meta.issue_ids.empty? ? " (orphaned)" : " linked to #{meta.issue_ids.map { |iid| "issue ##{iid}" }.join(", ")}"
          puts "Frozen evidence ##{id}#{linked} deleted."
        ensure
          store.close
        end
      end

      # The required {issue id, source kind, source id} triple — split out for the reason
      # `resolve_link_ends` is: the values are assigned inside OptionParser blocks, so Crystal
      # keeps them nilable in place.
      private def self.resolve_freeze_ends(issue_id : Int64?, ref_s : String?,
                                           ref_id : Int64?) : {Int64, Store::LinkRefKind, Int64}
        abort "gori run evidence freeze: --issue is required" if issue_id.nil?
        abort "gori run evidence freeze: --ref is required (flow|repeater)" if ref_s.nil?
        abort "gori run evidence freeze: --ref-id is required" if ref_id.nil?
        kind = Store::LinkRefKind.parse(ref_s)
        unless kind && Evidence.freezable?(kind)
          abort "gori run evidence freeze: invalid --ref '#{ref_s}' (flow|repeater — a fuzz or miner session has no single exchange to freeze)"
        end
        {issue_id, kind, ref_id}
      end

      private def self.parse_evidence_id(v : String, flag : String) : Int64
        v.to_i64? || abort("gori run evidence: invalid #{flag} #{v.inspect} (expected an integer)")
      end

      # `#12  hist #3  2026-09-11T05:02:33Z  POST acme.test/login → 200  34567 bytes  sha256 req a1b2… res c3d4…`
      # — one row per copy, the provenance the RELATED card shows plus the hash prefixes.
      private def self.evidence_line(m : Store::IssueEvidenceMeta) : String
        outcome = m.status.try(&.to_s) || (m.error ? "error" : "no response")
        notes = [] of String
        notes << "request truncated" if m.request_truncated?
        notes << "response truncated" if m.response_truncated?
        tail = notes.empty? ? "" : "  (#{notes.join(", ")} at capture)"
        linked = m.issue_ids.empty? ? "orphaned" : m.issue_ids.map { |id| "##{id}" }.join(",")
        "##{m.id}  #{m.source_label}  #{MCP::Serialize.unix_micros_iso(m.created_at)}  " \
        "#{Issues::Export.one_line(Evidence.label(m))} → #{outcome}  #{m.bytes} bytes  " \
        "sha256 req #{m.request_sha256[0, 12]}… res #{m.response_sha256.try { |h| "#{h[0, 12]}…" } || "—"}  " \
        "issues #{linked}#{tail}"
      end

      # The text form of one copy: provenance lines, then the two messages. Heads through the
      # same redaction MCP's `get_flow` applies; bodies decoded and capped like the Markdown
      # report's evidence fences, and dropped with a note when they are not text.
      private def self.evidence_text(ev : Store::IssueEvidence, include_sensitive : Bool) : String
        m = ev.meta
        String.build do |io|
          io << "frozen evidence #" << m.id << "\n"
          io << "issues:   "
          if m.issue_ids.empty?
            io << "— (orphaned)\n"
          else
            io << m.issue_ids.map { |id| "##{id}" }.join(", ") << "\n"
          end
          io << "source:   " << m.source_label << "\n"
          io << "frozen:   " << MCP::Serialize.unix_micros_iso(m.created_at) << "\n"
          io << "exchange: " << Issues::Export.one_line(Evidence.label(m)) << " → "
          if st = m.status
            io << st
          elsif e = m.error
            io << "error: " << Issues::Export.one_line(e)
          else
            io << "no response"
          end
          io << " · " << (m.protocol.try { |p| Issues::Export.one_line(p) } || "?")
          m.duration_us.try { |d| io << " · " << d << "µs" }
          io << " · " << m.bytes << " bytes\n"
          io << "sha256:   req " << m.request_sha256 << "\n"
          io << "          res " << (m.response_sha256 || "— (no response)") << "\n"
          io << "note:     request body truncated at capture\n" if m.request_truncated?
          io << "note:     response body truncated at capture\n" if m.response_truncated?
          io << "note:     credential header values read [REDACTED]; --include-sensitive prints them (the hashes cover the raw bytes)\n" unless include_sensitive
          append_message(io, "request", ev.request_head, ev.request_body, include_sensitive)
          if head = ev.response_head
            append_message(io, "response", head, ev.response_body, include_sensitive)
          else
            io << "\n--- response ---\n(none)\n"
          end
        end
      end

      private def self.append_message(io : String::Builder, name : String, head : Bytes, body : Bytes?,
                                      include_sensitive : Bool) : Nil
        io << "\n--- " << name << " ---\n"
        head_text = MCP::Serialize.redact_head(Issues::Export.scrub_controls(String.new(head)), include_sensitive)
        io << head_text
        io << "\n" unless head_text.ends_with?("\n")
        shown = Entity.bytes(head, body)
        return if shown.nil? || shown.empty?
        decoded_size = shown.size
        cut = decoded_size > Issues::Export::EVIDENCE_CAP
        # Back the cut off to a codepoint boundary first — the Markdown report's own rule —
        # or a multibyte character split at exactly the cap reads the whole page as binary.
        shown = Issues::Export.trim_to_codepoint_boundary(shown[0, Issues::Export::EVIDENCE_CAP]) if cut
        text = String.new(shown)
        if text.valid_encoding?
          io << Issues::Export.scrub_controls(text) << "\n"
        else
          io << "[binary body omitted, " << decoded_size << " decoded bytes]\n"
        end
        io << "[… body display cut at " << Issues::Export::EVIDENCE_CAP << " bytes; the stored copy is complete]\n" if cut
      end
    end
  end
end
