require "./issue"
require "./passive/context"
require "../store"
require "../store/safe_regexp"
require "../settings"

module Gori
  module Probe
    # A user-defined passive match rule: a string or regex tested against one region of a
    # captured flow (request/response × header/body/whole). Unlike a built-in Passive::Rule it
    # carries its own metadata + match spec as data (no Crystal subclass) and is persisted either
    # GLOBALLY (Settings.scan_rules, reusable across projects) or per-PROJECT (probe_custom_rules).
    # `Probe.custom_rules(store)` merges both into the runtime list the analyzer feeds to
    # Passive.analyze. A match emits a Category::CUSTOM Detection grouped by (code, host) like any
    # built-in finding.
    #
    # SAFETY: user patterns run PCRE over captured bytes. Every region text Context hands us is
    # already `.scrub`bed, and #matches? rescues a bad-pattern raise → false, so a hostile regex
    # or a non-UTF-8 body can never crash the scanner (mirrors the built-in rules' scrub+rescue).
    record CustomRule,
      id : String, # "<hex>" (global) or the DB row id as text (project) — unique per scope
      title : String,
      description : String,
      side : String,   # "request" | "response"
      region : String, # "whole" | "header" | "body"
      kind : String,   # "string" | "regex"
      pattern : String,
      severity : Store::Severity,
      scope : String, # "global" | "project"
      enabled : Bool do
      SIDES   = %w[request response]
      REGIONS = %w[whole header body]
      KINDS   = %w[string regex]

      # Whether a would-be rule's pattern is usable. A regex PCRE rejects would match nothing
      # forever while every surface reported the rule saved fine (#matches? rescues to false),
      # so all three write paths validate through here before persisting. SafeRegexp.compile
      # RAISES on a bad pattern rather than returning nil.
      def self.valid_pattern?(pattern : String, kind : String) : Bool
        return false if pattern.empty?
        return true unless kind == "regex"
        SafeRegexp.compile(pattern)
        true
      rescue
        false
      end

      # Stable finding code so (code, host) groups per rule per host. scope[0] ('g'/'p') keeps
      # a global and a project rule that happen to share an id from colliding.
      def code : String
        "custom_#{scope[0]}_#{id}"
      end

      def global? : Bool
        scope == "global"
      end

      def check(ctx : Passive::Context, acc : Array(Detection)) : Nil
        return unless enabled
        return if pattern.empty?
        text = region_text(ctx)
        return if text.nil? || text.empty?
        hit, evidence = match_evidence(text)
        return unless hit
        acc << Detection.new(code, Category::CUSTOM, ctx.host, ctx.url, title, severity,
          evidence: evidence, flow_id: ctx.fid)
      end

      # The scrubbed text for this rule's side × region (nil when that region is absent, e.g. a
      # request with no body or a flow with no response head).
      private def region_text(ctx : Passive::Context) : String?
        if side == "request"
          case region
          when "header" then ctx.request_head_text
          when "body"   then ctx.request_body_text
          else               ctx.request_whole_text
          end
        else
          case region
          when "header" then ctx.response_head_text
          when "body"   then ctx.body_text
          else               ctx.response_whole_text
          end
        end
      end

      # Byte-safe match returning {matched?, evidence}. Text is pre-scrubbed; a bad user regex
      # (compile raise) degrades to no match rather than dropping the whole flow's detections.
      #
      # A regex rule now REPORTS WHAT IT MATCHED. Every custom finding used to store
      # `evidence: nil`, so the Probe detail pane, `gori run probe`, and the MCP tools could all
      # say a rule fired on a host but not what tripped it — the operator had to re-run the
      # pattern by hand against the sample flow to find out. Capture group 1 wins when the
      # pattern defines one (that is how you say "report THIS part" — the id out of a URL, the
      # version out of a banner); otherwise the whole match is reported.
      #
      # A STRING rule reports nothing, deliberately: its match is byte-identical to its own
      # `pattern`, which every surface already shows next to the rule, so the field would be
      # pure duplication.
      private def match_evidence(text : String) : {Bool, String?}
        # `SafeRegexp.compile` is a cache lookup, and precompiling the pattern at rule-LOAD time
        # was measured and REJECTED: 0.98-1.16x over 2/16/112 KiB bodies with the shared cache
        # being actively evicted (bench/probe_custom_rule_bench.cr). The cache is shared with the
        # SQL `REGEXP` callback and clears wholesale at CACHE_MAX, so filter-box keystrokes really
        # do evict operator patterns — but a PCRE2 compile is an order of magnitude cheaper than
        # matching a body, so removing it buys nothing worth a field on this record.
        if kind == "regex"
          m = SafeRegexp.compile(pattern).match(text)
          return {false, nil} unless m
          {true, safe_evidence(m[1]? || m[0])}
        else
          {text.includes?(pattern), nil}
        end
      rescue
        {false, nil}
      end

      # The captured text is CONTENT — server bytes, or the operator's own traffic — landing in
      # a stored row and in the TUI, so it gets the same treatment every other rule gives
      # content-derived evidence (cf. Passive::Sri#safe_host, SourceMap#safe_ref): printable
      # ASCII only, and capped. The cap also keeps a greedy user pattern (`.*`) from writing a
      # whole 64 KiB body into the issue row.
      EVIDENCE_CAP = 120

      private def safe_evidence(raw : String) : String?
        cleaned = raw.scrub.gsub(/[^\x20-\x7e]/, " ").strip
        return nil if cleaned.empty?
        cleaned.size > EVIDENCE_CAP ? "#{cleaned[0, EVIDENCE_CAP]}…" : cleaned
      end
    end

    # Merge the global rule library (Settings.scan_rules) with this project's rules
    # (store.probe_custom_rules) into the runtime match list. Global first, then project — order
    # only affects detection emission order (findings group by code, so it doesn't matter).
    # Modeled on Env.effective_vars (global base + project layer).
    def self.custom_rules(store : Store) : Array(CustomRule)
      out = [] of CustomRule
      Settings.scan_rules.each do |r|
        out << CustomRule.new(r.id, r.title, r.description, r.side, r.region, r.kind,
          r.pattern, Store::Severity.parse?(r.severity) || Store::Severity::Info, "global", r.enabled)
      end
      store.probe_custom_rules.each do |r|
        out << CustomRule.new(r.id.to_s, r.title, r.description, r.side, r.region, r.kind,
          r.pattern, r.severity, "project", r.enabled?)
      end
      out
    end
  end
end
