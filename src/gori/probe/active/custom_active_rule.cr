require "uri"
require "./types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"
require "../../store/safe_regexp"

module Gori
  module Probe
    module Active
      # A USER-DEFINED active rule: it sends a payload into one region of a captured request and
      # decides a finding by comparing the probe's response to a CONTROL — the same request sent
      # unchanged. Unlike the passive `Probe::CustomRule` (a match against captured bytes, no
      # request), this one PROBES: the operator supplies a payload to inject and a pattern that
      # confirms it landed.
      #
      # The confirmation is DIFFERENTIAL by construction, and that is the whole point. A rule that
      # only asked "does the response match the pattern?" would fire on every page that already
      # contained the pattern's text — the same false-positive class that #478 removed from the
      # built-in bypass rules. So the adapter always sends two requests, probe and control, and
      # reports only when the pattern is present in the probe AND absent from the control: the
      # payload, not the page, produced the match.
      #
      # This is a pure data record; `to_rule` wraps it in an `Active::Rule` the existing pipeline
      # drives with no special-casing. Persistence (global settings + per-project DB) and the
      # CRUD surfaces are layered on separately — this file is only the model and the adapter.
      record CustomActiveRule,
        id : String, # "<hex>" (global) or the DB row id as text (project); unique per scope
        title : String,
        description : String,
        inject : String,        # WHERE the payload goes: "query" | "header" | "body"
        header_name : String,   # the header to set when inject == "header" (ignored otherwise)
        payload : String,       # the bytes injected at that location
        match_kind : String,    # how `match_pattern` is read: "string" | "regex"
        match_pattern : String, # confirms the payload landed: present in the probe, absent in the control
        match_region : String,  # WHICH part of the response the pattern is tested against: "whole" | "header" | "body"
        severity : Store::Severity,
        scope : String, # "global" | "project"
        enabled : Bool do
        INJECTS = %w[query header body]
        KINDS   = %w[string regex]
        REGIONS = %w[whole header body]

        # Stable finding code so (code, host) groups per rule per host, and a global rule cannot
        # collide with a project rule that happens to share an id. Mirrors CustomRule#code, with a
        # distinct prefix so a passive and an active custom rule never share a group.
        def code : String
          "customactive_#{scope[0]}_#{id}"
        end

        def global? : Bool
          scope == "global"
        end

        # A rule is usable when its injection target is known, its confirming pattern is present
        # and (for a regex) compilable, and a header-injecting rule names a header. All three write
        # paths validate through here before persisting, exactly like CustomRule.valid_pattern? —
        # a rule the match engine can never fire on must not be saveable while every surface
        # reports it saved fine.
        def self.valid?(inject : String, header_name : String, payload : String,
                        match_kind : String, match_pattern : String) : Bool
          return false unless INJECTS.includes?(inject)
          return false if payload.empty?
          return false if inject == "header" && header_name.strip.empty?
          return false if match_pattern.empty?
          return true unless match_kind == "regex"
          SafeRegexp.compile(match_pattern)
          true
        rescue
          false
        end

        def valid? : Bool
          self.class.valid?(inject, header_name, payload, match_kind, match_pattern)
        end

        # The Active::Rule the analyzer drives. Built once per scan from the persisted record, so
        # the adapter closes over immutable data and stays a pure function of (flow, opts).
        def to_rule : Rule
          Adapter.new(self)
        end

        # Adapts one CustomActiveRule to the Active::Rule contract: build a probe (payload injected)
        # plus a control (request verbatim), then confirm on the probe-present / control-absent
        # differential. Gated to SAFE_METHODS unless the operator opted into unsafe — a user payload
        # can be anything, so re-sending it on a POST/PUT/DELETE must stay an explicit choice.
        class Adapter < Rule
          def initialize(@rule : CustomActiveRule)
          end

          def info : RuleInfo
            RuleInfo.new(@rule.code, @rule.title,
              @rule.description.empty? ? "User-defined active rule." : @rule.description,
              Category::CUSTOM)
          end

          # Body injection changes the body, so it must be re-sent with the original method and can
          # never be a plain GET replay of a safe request; still SAFE_METHODS-gated by default like
          # the rest, and query/header injection is a re-send of the same method too. The gate is
          # uniform: only the opt-in widens it.
          def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
            method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
            return nil if malformed
            method_up = method.upcase
            return nil unless method_allowed?(method_up, opts)
            return nil unless injectable?(detail, method_up)
            key_string(detail, method_up, Active.origin_form(target))
          end

          def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
            method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
            return nil if malformed
            method_up = method.upcase
            return nil unless method_allowed?(method_up, opts)
            return nil unless injectable?(detail, method_up)
            probe = build_probe(detail) || return nil
            # The control is the SAME request, only normalized to origin-form (probes go direct to
            # the origin, like every other active rule) — so probe and control differ in exactly
            # one thing: the injected payload.
            control = rebuild(detail.request_head, detail.request_body, Active.origin_form(target))
            Plan.new(probe, [] of Param, key_string(detail, method_up, Active.origin_form(target)), [control])
          end

          # results = [probe, control]. Fire only when the confirming pattern is present in the
          # probe response and ABSENT from the control — the payload produced the match, not the
          # page. A control that failed to send is no attribution, so refuse rather than guess.
          def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
            probe = results[0]?
            control = results[1]?
            return [] of Detection unless probe && probe.ok?
            return [] of Detection unless control && control.ok?
            return [] of Detection unless matches?(probe)
            return [] of Detection if matches?(control)
            [Detection.new(@rule.code, Category::CUSTOM, detail.row.host, detail.row.url,
              @rule.title, @rule.severity,
              "custom active rule matched the probe response only (payload confirmed)", detail.row.id)]
          rescue
            [] of Detection
          end

          def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
            detections_all(plan, [result], detail)
          end

          def requests_per_flow : Range(Int32, Int32)
            2..2 # probe + control
          end

          # There must be somewhere for the payload to go: query injection needs a query param,
          # body injection needs a body, header injection always applies.
          private def injectable?(detail : Store::FlowDetail, method_up : String) : Bool
            case @rule.inject
            when "query"
              _, query = split_target(Active.origin_form(request_target(detail)))
              !query.empty?
            when "body"
              (b = detail.request_body) ? !b.empty? : false
            else # "header"
              true
            end
          end

          # Build the probe request with the payload injected at the rule's location, or nil when
          # the location is not present (guarded by injectable?, but re-checked so plan is total).
          private def build_probe(detail : Store::FlowDetail) : Bytes?
            target = request_target(detail)
            path, query = split_target(Active.origin_form(target))
            case @rule.inject
            when "query"
              return nil if query.empty?
              nq = inject_query(query)
              rebuild(detail.request_head, detail.request_body, nq.empty? ? path : "#{path}?#{nq}")
            when "body"
              body = detail.request_body
              return nil if body.nil? || body.empty?
              rebuild_body(detail.request_head, inject_body(body), Active.origin_form(target))
            else # "header"
              rebuild_header(detail.request_head, detail.request_body, Active.origin_form(target))
            end
          end

          # Append the payload (URL-encoded) to EVERY query param value: a single request that
          # exercises each parameter, matching how the built-in reflected/crlf probes fan a payload
          # across the query. Bare flags / empty segments pass through untouched.
          private def inject_query(query : String) : String
            enc = URI.encode_www_form(@rule.payload, space_to_plus: false)
            query.split('&').map do |pair|
              next pair if pair.empty?
              eq = pair.index('=')
              next pair unless eq
              "#{pair[0...eq]}=#{pair[(eq + 1)..]}#{enc}"
            end.join('&')
          end

          # Append the raw payload to the request body. A user body payload is sent verbatim (the
          # operator typed it), and Content-Length is resynced by rebuild_body.
          private def inject_body(body : Bytes) : Bytes
            io = IO::Memory.new(body.size + @rule.payload.bytesize)
            io.write(body)
            io << @rule.payload
            io.to_slice
          end

          # --- response matching --------------------------------------------------------------

          # Does the confirming pattern match the chosen region of `result`'s response? Byte-safe:
          # heads/bodies are scrubbed before the regex (mirrors the passive CustomRule), and a bad
          # user regex degrades to no-match rather than dropping the whole probe.
          private def matches?(result : Repeater::Result) : Bool
            text = region_text(result)
            return false if text.nil? || text.empty?
            if @rule.match_kind == "regex"
              SafeRegexp.compile(@rule.match_pattern).matches?(text)
            else
              text.includes?(@rule.match_pattern)
            end
          rescue
            false
          end

          private def region_text(result : Repeater::Result) : String?
            head = String.new(result.head).scrub
            case @rule.match_region
            when "header"
              head
            when "body"
              body_text(result)
            else # "whole"
              b = body_text(result)
              b ? "#{head}\r\n#{b}" : head
            end
          end

          private def body_text(result : Repeater::Result) : String?
            decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
            bytes = decoded || result.body
            return nil if bytes.nil? || bytes.empty?
            String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
          end

          # --- request rebuilding -------------------------------------------------------------

          private def key_string(detail : Store::FlowDetail, method_upcase : String, origin_target : String) : String
            "#{@rule.code}|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path_only(origin_target)}"
          end

          private def request_target(detail : Store::FlowDetail) : String
            _, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
            target
          end

          private def split_target(target : String) : {String, String}
            qi = target.index('?')
            return {target, ""} unless qi
            {target[0...qi], target[(qi + 1)..]}
          end

          private def path_only(origin_target : String) : String
            qi = origin_target.index('?')
            qi ? origin_target[0...qi] : origin_target
          end

          # Rebuild with a new request-line target (query/control path change); body and headers
          # untouched, Content-Length resynced in case the caller changed nothing (no-op then).
          private def rebuild(orig_head : Bytes, body : Bytes?, new_target : String) : Bytes
            head, _, eol = Miner::Inject.split(orig_head)
            lines = String.new(head).split(eol)
            unless lines.empty?
              parts = lines[0].split(' ')
              lines[0] = "#{parts[0]} #{new_target} #{parts[2]}" if parts.size == 3
            end
            io = IO::Memory.new
            io << lines.join(eol) << eol << eol
            b = body || Bytes.empty
            io.write(b) unless b.empty?
            Fuzz::ContentLength.sync(io.to_slice, false)
          end

          # Rebuild with a new body (payload appended) + origin-form request line; Content-Length
          # resynced to the new body.
          private def rebuild_body(orig_head : Bytes, new_body : Bytes, origin_target : String) : Bytes
            head, _, eol = Miner::Inject.split(orig_head)
            lines = String.new(head).split(eol)
            unless lines.empty?
              parts = lines[0].split(' ')
              lines[0] = "#{parts[0]} #{origin_target} #{parts[2]}" if parts.size == 3
            end
            io = IO::Memory.new
            io << lines.join(eol) << eol << eol
            io.write(new_body)
            # add_when_missing: the body grew, so a Content-Length must exist even if the captured
            # request framed the body some other way — otherwise the origin can't find the payload.
            Fuzz::ContentLength.sync(io.to_slice, true)
          end

          # Rebuild with the rule's header set to the payload: drop any copy the browser sent, then
          # insert one authoritative line after the request line (origin-form). Body untouched.
          #
          # The payload (and header name) are written VERBATIM — a CR/LF the operator typed is NOT
          # stripped. That is deliberate and follows the project's provenance rule: bytes the
          # operator supplied go out byte-exact, because a header-injection rule whose payload is
          # `foo\r\nX-Injected: 1` is the operator deliberately testing header/CRLF injection, not a
          # mistake to sanitize. (The refuse-malformed rule applies to bytes the TARGET supplied —
          # a crawled href, a redirect Location — never to an operator's own probe.)
          private def rebuild_header(orig_head : Bytes, body : Bytes?, origin_target : String) : Bytes
            combined = if body && !body.empty?
                         io = IO::Memory.new(orig_head.size + body.size)
                         io.write(orig_head)
                         io.write(body)
                         io.to_slice
                       else
                         orig_head
                       end
            hbytes, bbytes, eol = Miner::Inject.split(combined)
            lines = String.new(hbytes).split(eol)
            name_low = @rule.header_name.strip.downcase
            kept = [] of String
            lines.each_with_index do |l, i|
              next if i > 0 && header_named?(l, name_low)
              kept << l
            end
            unless kept.empty?
              rl = kept[0].split(' ')
              kept[0] = "#{rl[0]} #{origin_target} #{rl[2]}" if rl.size == 3
              kept.insert(1, "#{@rule.header_name.strip}: #{@rule.payload}")
            end
            io = IO::Memory.new
            io << kept.join(eol) << eol << eol
            io.write(bbytes) unless bbytes.empty?
            Fuzz::ContentLength.sync(io.to_slice, false)
          end

          private def header_named?(line : String, name_low : String) : Bool
            (c = line.index(':')) ? line[0...c].strip.downcase == name_low : false
          end
        end
      end
    end
  end
end
