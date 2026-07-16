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
        return unless matches?(text)
        acc << Detection.new(code, Category::CUSTOM, ctx.host, ctx.url, title, severity,
          evidence: nil, flow_id: ctx.fid)
      end

      # The scrubbed text for this rule's side × region (nil when that region is absent, e.g. a
      # request with no body or a flow with no response head).
      private def region_text(ctx : Passive::Context) : String?
        if side == "request"
          case region
          when "header" then ctx.request_head_text
          when "body"   then ctx.request_body_text
          else               join(ctx.request_head_text, ctx.request_body_text)
          end
        else
          case region
          when "header" then ctx.response_head_text
          when "body"   then ctx.body_text
          else               join(ctx.response_head_text, ctx.body_text)
          end
        end
      end

      private def join(head : String?, body : String?) : String?
        return body if head.nil?
        return head if body.nil?
        "#{head}\r\n#{body}"
      end

      # Byte-safe match: text is pre-scrubbed; a bad user regex (compile raise) degrades to no
      # match rather than dropping the whole flow's detections.
      private def matches?(text : String) : Bool
        if kind == "regex"
          SafeRegexp.compile(pattern).matches?(text)
        else
          text.includes?(pattern)
        end
      rescue
        false
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
