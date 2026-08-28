require "./issue"
require "./passive/context"
require "../process_hook"
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
    #
    # `kind: "exec"` (#818) is the third kind and the one that leaves Crystal: `pattern` holds an
    # ARGV, the region is fed to that command on stdin, and its EXIT CODE is the verdict — 0
    # raises the finding, anything else does not. stdout becomes the evidence line, which is what
    # makes an exec rule worth having over a regex: a real detector can say *what* it found. It
    # runs with the operator's own privileges and is not sandboxed; see `Gori::ProcessHook`.
    record CustomRule,
      id : String, # "<hex>" (global) or the DB row id as text (project) — unique per scope
      title : String,
      description : String,
      side : String,   # "request" | "response"
      region : String, # "whole" | "header" | "body"
      kind : String,   # "string" | "regex" | "exec"
      pattern : String,
      severity : Store::Severity,
      scope : String, # "global" | "project"
      enabled : Bool,
      on_failure : Proc(CustomRule, String, Nil)? = nil do
      SIDES   = %w[request response]
      REGIONS = %w[whole header body]
      KINDS   = %w[string regex exec]

      # Whether a would-be rule's pattern is usable. A regex PCRE rejects would match nothing
      # forever while every surface reported the rule saved fine (#matches? rescues to false),
      # so all three write paths validate through here before persisting. SafeRegexp.compile
      # RAISES on a bad pattern rather than returning nil.
      def self.valid_pattern?(pattern : String, kind : String) : Bool
        return false if pattern.empty?
        # An `exec` rule's pattern is an argv, so "usable" means it tokenizes — the same
        # question `Rules.pipe_argv_error` asks of a `pipe` rule's command, and asked for the
        # same reason: a rule that can never run must not persist looking healthy. Whether the
        # command EXISTS is deliberately not asked (it may be installed later, or resolved
        # through PATH at exec time); that failure surfaces at run time instead.
        return ProcessHook.valid_argv?(pattern) if kind == "exec"
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
        hit, evidence = kind == "exec" ? exec_evidence(text, ctx) : match_evidence(text)
        return unless hit
        acc << Detection.new(code, Category::CUSTOM, ctx.host, ctx.url, title, severity,
          evidence: evidence, flow_id: ctx.fid)
      end

      # Run the rule's command over the region and read the EXIT CODE as the verdict: 0 = the
      # detector fired, anything else = it did not. stdout's first line becomes the evidence,
      # through the same `safe_evidence` scrub-and-cap every other custom finding's evidence
      # goes through — it is a detector's own text landing in a stored row and in the TUI.
      #
      # A hook that cannot RUN — no such command, timed out, wrote past
      # `ProcessHook::MAX_OUTPUT` — is NOT a match, and is reported through `report_failure`.
      # Both halves matter. Treating a spawn failure as a hit would fill the Issues list from a
      # typo; treating it as a clean no-match and saying nothing is the shape my notes call
      # "absence of finding reads as clean" — the operator cannot tell "the detector looked and
      # found nothing" from "the detector never ran". A non-zero exit is neither: it is the
      # rule's own answer and is silent by design.
      #
      # WHAT THE HOOK SEES is the region text `Passive::Context` hands every custom rule —
      # content-decoded, capped at `Context::BODY_CAP`, and `.scrub`bed. That is a real
      # departure from P7's raw octets and it is deliberate: a rule table where `exec` and
      # `regex` looked at different bytes for the same {side, region} would make two rules over
      # one flow mean two different things. A hook that needs the exact wire bytes has the flow
      # id in `GORI_FLOW_ID` and the whole store behind it.
      private def exec_evidence(text : String, ctx : Passive::Context) : {Bool, String?}
        argv = ProcessHook.argv?(pattern)
        return {false, nil} if argv.nil?
        res = ProcessHook.run(argv, text.to_slice, Settings.hook_timeout_secs.seconds,
          exec_env(ctx))
        if reason = res.spawn_error
          report_failure("#{ProcessHook.command_label(argv)}: #{reason}")
          return {false, nil}
        end
        if res.timed_out || res.truncated
          report_failure(res.failure || "hook failed")
          return {false, nil}
        end
        return {false, nil} unless res.status == 0
        line = String.new(res.stdout).scrub.each_line.first?.try(&.strip)
        {true, line.presence.try { |l| safe_evidence(l) }}
      end

      # Context for the hook, on top of the operator's inherited environment. Everything here is
      # metadata the rule already selects on — no captured bytes ride in the environment, which
      # is visible in a process listing; the bytes go on stdin, where they are not.
      private def exec_env(ctx : Passive::Context) : Hash(String, String)
        {
          "GORI_HOOK"         => "probe",
          "GORI_RULE_ID"      => id,
          "GORI_RULE_SCOPE"   => scope,
          "GORI_SIDE"         => side,
          "GORI_REGION"       => region,
          "GORI_HOST"         => ctx.host,
          "GORI_URL"          => ctx.url,
          "GORI_FLOW_ID"      => ctx.fid.try(&.to_s) || "",
          "GORI_STATUS"       => ctx.row.status.to_s,
          "GORI_CONTENT_TYPE" => ctx.content_type || "",
        }
      end

      # Say that this rule's hook could not run. `on_failure` is injected by
      # `Probe.custom_rules`, which is the layer that has a Store to write an event with; a rule
      # built without one (a spec, a preview) is silent. It is not part of the rule's identity —
      # two rules differing only in which closure they carry are the same rule — but `record`
      # compares every field, so it sits LAST with a nil default and every existing positional
      # construction keeps working.
      private def report_failure(reason : String) : Nil
        on_failure.try &.call(self, reason)
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
      report = hook_failure_reporter(store)
      Settings.scan_rules.each do |r|
        out << CustomRule.new(r.id, r.title, r.description, r.side, r.region, r.kind,
          r.pattern, Store::Severity.parse?(r.severity) || Store::Severity::Info, "global", r.enabled,
          on_failure: report)
      end
      store.probe_custom_rules.each do |r|
        out << CustomRule.new(r.id.to_s, r.title, r.description, r.side, r.region, r.kind,
          r.pattern, r.severity, "project", r.enabled?, on_failure: report)
      end
      out
    end

    # Where an `exec` rule's hook failure goes: one warn row in the project event feed, so a
    # detector that never ran is distinguishable from one that ran and found nothing (see
    # `CustomRule#exec_evidence`).
    #
    # De-duplicated per {rule, sentence} for the LIFE OF THIS RULE LIST, which is exactly the
    # right window: the list is rebuilt whenever the rules change, so an edited rule is news
    # again, and a scan over ten thousand flows with a mistyped command writes ONE row instead
    # of ten thousand. The closure is shared by every rule in the list, so the set is too — one
    # broken command reported once even when three rules name it.
    private def self.hook_failure_reporter(store : Store) : Proc(CustomRule, String, Nil)
      seen = Set(String).new
      lock = Mutex.new
      ->(rule : CustomRule, reason : String) do
        line = "probe rule #{rule.title.inspect} (#{rule.scope}) could not run its hook: #{reason}"
        fresh = lock.synchronize { seen.add?(line) }
        store.insert_event("probe", "hook_failed", "warn", line) if fresh
        nil
      end
    end
  end
end
