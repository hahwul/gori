require "json"
require "base64"
require "log"
require "../store"
require "../ql"
require "../scope"
require "../paths"
require "../project_registry"
require "../capture_lock"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/flow_request"
require "../flow_mapper"
require "../proxy/codec/http1"
require "../fuzz"
require "../decoder"
require "../jwt"
require "../env"
require "../miner"
require "../discover"
require "../discover/adapters"
require "../import/builder"
require "../notes"
require "../probe"
require "./serialize"
require "./request_builder"
require "./tools/context"
require "./tools/decode"
require "./tools/discover"
require "./tools/flows"
require "./tools/fuzz"
require "./tools/intercept"
require "./tools/issues"
require "./tools/jobs"
require "./tools/mine"
require "./tools/notes"
require "./tools/projects"
require "./tools/ql"
require "./tools/repeater"
require "./tools/rules"
require "./tools/send"
require "./tools/sequence"
require "./tools/sitemap"

module Gori
  module MCP
    # Maps MCP tool calls to gori's store reads, the repeater engines, and (gated)
    # store writes. Read tools are always exposed; network action tools
    # (`send_request`/`send_websocket`) and write tools
    # (`create_issue`/`update_issue`) are gated behind
    # `allow_actions` — off when the user runs `gori mcp --read-only`. A gated tool
    # is omitted from `tools/list` AND rejected by `call`.
    class Tools
      Log = ::Log.for("mcp.tools")

      # One tool outcome. `is_error` maps to the MCP `isError` flag — a tool-level
      # failure the model is meant to see and recover from, distinct from a
      # JSON-RPC protocol error. Error results also carry a stable machine
      # `error_code` (+ optional `field`, `retryable`, `details`) so a caller can
      # apply policy / auto-recovery without parsing the human `text`. The `Server`
      # surfaces these in `structuredContent`; see `err` and `classify`.
      record Result, text : String, is_error : Bool = false,
        error_code : String? = nil, field : String? = nil,
        retryable : Bool = false, details : JSON::Any? = nil
      record BodyChunkOptions, flow_id : Int64?, repeater_id : Int64?, offset : Int64,
        limit : Int32, raw : Bool

      # Outcome of the active-tool scope gate. `decision` is "in_scope",
      # "out_of_scope", or "unscoped" (no scope rules configured). `blocked` is
      # true only for an out-of-scope target that the caller did not override with
      # allow_unscoped — an UNCONFIGURED scope never blocks (preserves the
      # historical send-anywhere behavior; the send is merely flagged unscoped).
      record ScopeCheck, decision : String, host : String, rule_id : Int64?, blocked : Bool

      EMPTY_HASH = {} of String => JSON::Any

      # #124 — MCP tools whose SUCCESSFUL (or failed) execution is a real mutation or
      # outbound send worth recording in the event feed as a visible "agent action", so the
      # human can see (via list_events, and later the notification ring) what the AI did.
      # Deliberately EXCLUDES gated READ tools (fuzz_status/results, mine_status/results,
      # list_jobs, get_job, preview_rule) and project-management tools (switch_project reopens
      # @store, so a post-hoc append would land in the wrong DB) — only in-project side effects.
      AGENT_ACTION_TOOLS = Set{
        "send_request", "send_websocket",
        "fuzz_start", "fuzz_stop", "mine_start", "mine_stop", "sequence_start", "sequence_stop", "discover_start", "discover_stop", "stop_job",
        "create_issue", "update_issue",
        "create_rule", "update_rule", "delete_rule", "set_rule_enabled",
        "create_note", "update_note", "delete_note",
        "create_repeater", "update_repeater", "delete_repeater",
        "oast_start", "oast_stop",
      }

      # A live OAST listening session held server-side across tool calls (oast_start →
      # oast_poll/oast_payload → oast_stop). Ephemeral to this MCP process.
      private class OastMcpSession
        getter provider : Oast::Provider
        getter session : Oast::Session
        getter http : Oast::Http
        getter kind_label : String
        getter seen = Set(String).new

        def initialize(@provider, @session, @http, @kind_label)
        end
      end

      # Fuzz-run safety rails (a single tool call must never launch an unbounded
      # flood, and the in-memory result buffer can't grow without bound).
      FUZZ_MAX_REQUESTS    = 100_000_i64
      FUZZ_MAX_CONCURRENCY =         100
      FUZZ_MAX_STORED      =      10_000
      # Ceiling on History flows recorded per run (record_history), so `all` on a
      # huge run can't unboundedly grow the project database.
      FUZZ_HISTORY_MAX = 5_000

      # Param-miner safety rails (same intent as the fuzz caps).
      MINE_MAX_REQUESTS    = 100_000_i64
      MINE_MAX_CONCURRENCY =         100
      MINE_MAX_STORED      =      10_000

      # Sequencer (token randomness) safety rails.
      SEQUENCE_MAX_REQUESTS    = 100_000_i64
      SEQUENCE_MAX_GOAL        =      20_000
      SEQUENCE_MAX_CONCURRENCY =          20
      SEQUENCE_MAX_STORED      =      20_000 # tokens kept in memory for the analysis

      # Discover (spider + brute) safety rails.
      DISCOVER_MAX_REQUESTS    = 100_000_i64
      DISCOVER_MAX_CONCURRENCY =         100
      DISCOVER_MAX_STORED      =      20_000
      DISCOVER_MAX_DEPTH       =          12

      MCP_REPEATER_REQUEST_MAX = 16 * 1024

      # Default inlined-body cap for body_mode:preview (full uses Serialize::MAX_TEXT).
      BODY_PREVIEW_BYTES = 2048

      # Ceiling on the `decoder` tool's returned output string. A Decoder step can
      # produce up to 32 MiB (Decoder::MAX_OUT); returning that inline would swamp
      # the JSON-RPC channel, so truncate the display string and flag it.
      DECODER_MAX_OUTPUT = 256 * 1024

      def initialize(@store : Store, @allow_actions : Bool, @verify_upstream : Bool,
                     @project_name : String? = nil, @project_slug : String? = nil,
                     @db_path : String? = nil, @selection_source : String? = nil,
                     @workspace_root : String? = nil, @project_id : String? = nil)
        Env.load_project(@store)
        @jobs = {} of String => FuzzJob
        @mine_jobs = {} of String => MineJob
        @sequence_jobs = {} of String => SequenceJob
        @discover_jobs = {} of String => DiscoverJob
        @oast_mcp = {} of String => OastMcpSession
        @job_seq = 0
        # switch_project reopens @store; @owns_store tracks whether WE opened the
        # current one (and must close it on the next switch). The initial store is
        # owned by the caller (the `gori mcp` command), so it starts false.
        @owns_store = false
        # Short-lived confirmation tokens issued by delete_project(dry_run) →
        # {db_path, issued_at_ms}. A real delete must present a matching, unexpired one.
        @delete_tokens = {} of String => {String, Int64}
      end

      # Ceiling (seconds) a delete_project dry-run confirmation token stays valid.
      DELETE_TOKEN_TTL = 300

      getter? allow_actions : Bool

      # Raised by the fuzz arg-builders; converted to an is_error Result with a clean
      # message instead of a generic "tool error".
      class FuzzArgError < Exception
      end

      # Immutable audit metadata for a fuzz/mine run — the target and the pacing/
      # budget knobs plus start time, so a result set is self-describing evidence.
      record JobAudit,
        target : String,
        rate : Float64?,
        concurrency : Int32,
        max_requests : Int64?,
        started_at_ms : Int64

      # A background fuzz run, polled by fuzz_status / fuzz_results. The runner fiber
      # only mutates these fields (single-threaded scheduler → no lock needed); the
      # stored results are matched-only and capped at FUZZ_MAX_STORED.
      class FuzzJob
        getter id : String
        getter total : Int64?
        # :running | :done | :budget_exhausted | :stopped | :error. :budget_exhausted
        # is a DISTINCT terminal state from :done so a run that hit the request budget
        # before checking every candidate is not read as an exhaustive "0 matches".
        property status : Symbol = :running
        property sent = 0_i64
        property matched = 0_i64
        property errors = 0_i64
        property error_msg : String? = nil
        getter results = [] of Fuzz::Result
        # History flow ids for the stored (matched) results, index-aligned with
        # `results`; nil when record_history was off or the record failed.
        getter result_flow_ids = [] of Int64?
        property? truncated = false
        property? history_truncated = false
        property recorded_flows = 0
        property ended_at_ms : Int64? = nil
        property stop_requested_at_ms : Int64? = nil
        getter record_history : Symbol
        getter origin : Fuzz::Origin
        getter? http2 : Bool
        getter audit : JobAudit

        def initialize(@id : String, @total : Int64?, @engine : Fuzz::Engine,
                       @record_history : Symbol, @origin : Fuzz::Origin, @http2 : Bool,
                       @audit : JobAudit)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @engine.stop
        end
      end

      # A background param-mining run, polled by mine_status / mine_results. Like FuzzJob,
      # only the runner fiber mutates these (single-threaded → no lock). `total` is the
      # name count (the stable denominator); issues are capped at MINE_MAX_STORED.
      class MineJob
        getter id : String
        getter total : Int64
        # :running | :done | :budget_exhausted | :stopped | :error (see FuzzJob).
        property status : Symbol = :running
        property names_done = 0_i64
        property sent = 0_i64
        property found = 0
        property errors = 0_i64
        property? baseline_stable = true
        property error_msg : String? = nil
        getter results = [] of Miner::Finding
        property? truncated = false
        property ended_at_ms : Int64? = nil
        property stop_requested_at_ms : Int64? = nil
        getter audit : JobAudit

        def initialize(@id : String, @total : Int64, @engine : Miner::Engine, @audit : JobAudit)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @engine.stop
        end
      end

      # An async token-collection run tracked for the sequence_* tools. Collected tokens
      # are kept in-memory ONLY to compute the randomness report — they are secrets and are
      # never returned over the wire (sequence_results exposes the report, not the tokens).
      class SequenceJob
        getter id : String
        getter goal : Int32
        property status : Symbol = :running # :running | :done | :stopped | :error
        property collected = 0
        property sent = 0
        property errors = 0
        property error_msg : String? = nil
        getter tokens = [] of String
        property? truncated = false
        property ended_at_ms : Int64? = nil
        property stop_requested_at_ms : Int64? = nil
        getter audit : JobAudit

        def initialize(@id : String, @goal : Int32, @engine : Sequencer::Engine, @audit : JobAudit)
        end

        def report : Sequencer::Stats::Report
          Sequencer::Stats.analyze(@tokens)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @engine.stop
        end
      end

      # An async discover (spider + directory brute-force) run tracked for the discover_* tools.
      class DiscoverJob
        getter id : String
        property status : Symbol = :running # :running | :done | :stopped | :error
        property found = 0
        property sent = 0_i64
        property errors = 0_i64
        property queued = 0
        property stats : Discover::RunStats? = nil
        property error_msg : String? = nil
        getter results = [] of Discover::Finding
        property? truncated = false
        property ended_at_ms : Int64? = nil
        property stop_requested_at_ms : Int64? = nil
        getter audit : JobAudit

        def initialize(@id : String, @engine : Discover::Engine, @audit : JobAudit)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @engine.stop
        end
      end

      # Emits the tools/list array, honouring the action gate.
      def list(j : JSON::Builder) : Nil
        j.array do
          tool j, "list_history",
            "List captured HTTP flows, newest first. Optional gori QL `query` " \
            "filters (e.g. 'host:example.com status:>=500 size:>10000 dur:>500', " \
            "'header:set-cookie', 'body~secret\\d+' — `~` is regex, dur is ms); " \
            "empty query returns the most recent. Returns light rows (no bodies); " \
            "use get_flow for full detail. Paginate by passing the oldest id seen as " \
            "`before_id` (rows are newest-first); a page shorter than `limit` means no older rows. " \
            "To TAIL new flows instead, pass `since` (the largest id you've seen): rows come back " \
            "OLDEST-first; tail by passing the last id as the next `since`; an empty page means no " \
            "new flows (keep your cursor). `since` and `before_id` are mutually exclusive. " \
            "Call ql_reference for full QL syntax." do |s|
            s.field "query", strprop("gori QL filter; empty = most recent")
            s.field "limit", intprop("max rows (default 50, max 500)")
            s.field "before_id", intprop("cursor: page OLDER — only flows with id < this (newest-first; works with query too)")
            s.field "since", intprop("forward cursor: tail NEWER — only flows with id > this, oldest-first (mutually exclusive with before_id)")
            s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false; use ql_explain to see which terms would drop)")
          end

          tool j, "list_events",
            "Tail the AI event feed: an append-only log of job lifecycle (miner/fuzzer/probe) and " \
            "agent actions, forward-cursored so you never see the same event twice. This is the " \
            "AI-facing firehose complement to list_history (which tails captured flows). Pass " \
            "`since` = the last cursor you saw (0 or omitted starts from the oldest); the response " \
            "carries `next_cursor` — pass it as the next `since`. `next_cursor` never moves backward " \
            "and echoes your input on an empty page, so a poll that returns no events keeps your place. " \
            "Optional `source`/`kind` filters do NOT affect `next_cursor` (it is the max SCANNED id)." do |s|
            s.field "since", intprop("forward cursor: only events with id > this (default 0 = from oldest). Pass back the response's next_cursor to tail.")
            s.field "limit", intprop("max events scanned (default 100, max 500)")
            s.field "source", strprop("filter to one source: miner | fuzzer | probe | agent")
            s.field "kind", strprop("filter to one kind (e.g. job_done, agent_action)")
          end

          tool j, "intercept_list",
            "List HTTP messages currently HELD by the live intercept queue of the capturing " \
            "gori instance, plus intercept state (enabled/direction/filter) and a liveness " \
            "heartbeat. This is how an agent 'sits in the loop' alongside the human — inspect " \
            "held requests/responses, then forward/drop/edit them (see intercept_forward etc). " \
            "available:false when no bridge has ever been published; capturing:false (with a " \
            "growing heartbeat_age_seconds) when the last capturing instance is no longer live, " \
            "in which case mutating verbs refuse. Header values redacted unless " \
            "include_sensitive:true." do |s|
            s.field "include_sensitive", boolprop("show Authorization/Cookie/etc header values instead of [REDACTED] (default false)")
          end

          tool j, "intercept_get",
            "Full detail for ONE held intercept item (redacted head + body size). Pass " \
            "include_sensitive:true to ALSO get the full raw message base64 (unredacted, for " \
            "byte-exact editing with intercept_forward_edit) — otherwise raw is withheld " \
            "(raw_redacted:true) since base64 is not redaction. NOT_FOUND if the item was " \
            "already forwarded/dropped or never held. Header values redacted unless " \
            "include_sensitive:true." do |s|
            s.field "item_id", intprop("held item id from intercept_list"), required: true
            s.field "include_sensitive", boolprop("show sensitive header values instead of [REDACTED] (default false)")
          end

          tool j, "ql_reference",
            "Return the gori QL (query language) syntax reference for filtering flows " \
            "(list_history, list_sitemap). Call this before writing complex queries." { }

          tool j, "ql_explain",
            "Diagnose a gori QL query WITHOUT running it: which terms were applied, which " \
            "were silently dropped (broadening results), which regex terms are invalid " \
            "(match nothing), the compiled SQL, and warnings. Use to debug a query that " \
            "returns too many or zero rows." do |s|
            s.field "query", strprop("the gori QL query to analyze"), required: true
          end

          tool j, "get_flow",
            "Full request+response for one flow id (heads + decoded bodies). " \
            "Bodies are de-chunked/decompressed and summarised: inline text when " \
            "UTF-8 (capped 64KB), else a base64 sample. Use get_response_body_chunk " \
            "with the same flow id to retrieve exact continuation bytes. " \
            "Authorization/Cookie/Set-Cookie/API-key header values are [REDACTED] " \
            "unless include_sensitive=true." do |s|
            s.field "id", intprop("flow id from list_history"), required: true
            s.field "include_sensitive", boolprop("return Authorization/Cookie/Set-Cookie/API-key header values instead of [REDACTED] (default false)")
            s.field "body_mode", strprop("none | preview | full (default full) — none returns body shape only (encoding/size, omitted:true); preview inlines a small head; page more with get_response_body_chunk")
            s.field "max_body_bytes", intprop("cap inlined body bytes (clamped to 65536; page the rest with get_response_body_chunk)")
          end

          tool j, "get_response_body_chunk",
            "Read a byte range from a response body when get_flow/send_request reports truncation. " \
            "Pass exactly one of flow_id or repeater_id. Content encoding is decoded by default so " \
            "offsets continue the inline view; raw=true pages stored wire bytes. Returns UTF-8 text " \
            "or base64 plus next_offset/complete. An offset past the body end is clamped and flagged " \
            "(requested_offset, offset_out_of_range, warning) rather than silently returning empty." do |s|
            s.field "flow_id", intprop("History flow id")
            s.field "repeater_id", intprop("Repeater workbench database id")
            s.field "offset", intprop("zero-based byte offset (default 0)")
            s.field "limit", intprop("bytes to return (default 65536, max 262144)")
            s.field "raw", boolprop("page stored response bytes without content decoding (default false)")
          end

          tool j, "list_sitemap",
            "Distinct endpoints discovered in capture, keyed by TRANSPORT " \
            "(scheme, host, port, http_version, method, target) so the same path over " \
            "http vs https vs HTTP/2 stays separate — each with its observed status set, " \
            "success/error counts, and first/last-seen. Pass collapse_transport:true for " \
            "the legacy host/method/target-only view. Optional QL `query` filter." do |s|
            s.field "query", strprop("gori QL filter")
            s.field "limit", intprop("max entries (default 200, max 5000)")
            s.field "collapse_transport", boolprop("collapse to distinct host/method/target only (legacy shape), dropping scheme/port/version + counts (default false)")
            s.field "strict", boolprop("reject the query if any term is unrecognized/invalid instead of silently dropping it (default false)")
          end

          tool j, "list_issues",
            "List triage issues (severity + status), newest/most-severe first. " \
            "Returns an object {issues, returned, offset, total} — not a bare array." do |s|
            s.field "limit", intprop("max rows (default 100, max 500)")
            s.field "offset", intprop("start row (default 0)")
          end

          tool j, "get_issue", "Get one issue by id." do |s|
            s.field "id", intprop("issue id"), required: true
          end

          tool j, "list_scope", "List the project's scope include/exclude rules." { }

          tool j, "project_info",
            "Project totals: flow count, issue count, captured bytes, earliest capture time, " \
            "plus which project/db is being served and how it was selected. Always verify this " \
            "before reading or mutating security-test data." { }

          tool j, "get_current_context",
            "What the user is currently viewing in the gori TUI: active tab, focused pane, the " \
            "History-selected flow id (only when on the History tab), and sub-tab index — so you " \
            "can act on \"what I'm looking at right now\" without the user pasting ids. Reflects an " \
            "open (or last-open) gori TUI for THIS project. `age_seconds` shows how long since the " \
            "TUI last recorded focus (there is no live-TUI heartbeat) — use it to judge freshness; " \
            "`available:false` means the TUI never ran against this project." { }

          tool j, "get_repeater_context",
            "The Repeater workbench state. Defaults to metadata only so request headers, WebSocket " \
            "payloads, response headers, and the live TUI editor snapshot are not copied into the " \
            "model context. Set include_content=true only when those bytes are necessary. Supports " \
            "single-id lookup, pagination, and query filtering." do |s|
            s.field "id", intprop("return one repeater database id")
            s.field "limit", intprop("max rows to return (default 50, max 500)")
            s.field "offset", intprop("start row (default 0)")
            s.field "query", strprop("filter repeaters by name or target URL (case-insensitive substring match)")
            s.field "include_content", boolprop("include request text, WebSocket payloads, response head, and live TUI repeater snapshot (default false; may expose secrets)")
            s.field "include_sensitive", boolprop("with include_content, return Authorization/Cookie/Set-Cookie/API-key header values instead of [REDACTED] (default false)")
          end

          tool j, "list_notes", "List all project notes (markdown/text documents) with metadata like title and line count." { }

          tool j, "get_note", "Get the full text and metadata of a specific note by its database ID." do |s|
            s.field "id", intprop("database note ID"), required: true
          end

          tool j, "decode",
            "Run a gori Decoder chain (encode/decode/hash/compress) over `input` and return the " \
            "result — the same engine as the TUI Decoder tab. Pure transform: no network, no state. " \
            "`spec` is converter tokens separated by '>', '|' or ',' applied left-to-right, e.g. " \
            "'base64-decode > gunzip', 'url-encode', 'sha256'. Common converters: base64, " \
            "base64-decode, url-encode, url-encode-all, url-decode, hex, hex-decode, gzip, gunzip, " \
            "deflate, inflate, raw-deflate, raw-inflate, jwt-decode, html-encode, md5, sha256, crc32, " \
            "decimal, binary, rot47. An unknown token returns the full list." do |s|
            s.field "input", strprop("the value to transform (UTF-8 text unless input_base64 is set)"), required: true
            s.field "spec", strprop("converter chain, e.g. 'base64-decode > gunzip'"), required: true
            s.field "input_base64", boolprop("treat `input` as base64 and decode it to raw bytes first (for binary input)")
          end

          tool j, "jwt_decode",
            "Decode a JWT into its header + payload JSON and signature — the same engine as the " \
            "TUI JWT tab. Pure transform: no network, no state, no signature verification. Returns " \
            "{alg, header, payload, signature, signed}." do |s|
            s.field "token", strprop("the JWT (header.payload[.signature])"), required: true
          end

          tool j, "jwt_encode",
            "Re-sign a JWT with a chosen algorithm + secret — the classic testing move (swap alg to " \
            "none, or re-sign with a guessed HS secret). Takes the header + payload from `token` " \
            "(or the explicit `header`/`payload` JSON overrides), FORCES `alg` into the header, and " \
            "HMAC-signs with `secret` (HS256/384/512) or leaves it unsigned (none). Returns {token, alg}." do |s|
            s.field "token", strprop("a JWT to take the header + payload from (optional if header+payload are given)")
            s.field "header", strprop("header JSON object (overrides the token's header)")
            s.field "payload", strprop("payload JSON (overrides the token's payload)")
            s.field "alg", strprop("HS256 (default) | HS384 | HS512 | none")
            s.field "secret", strprop("HMAC secret for an HS algorithm")
          end

          tool j, "jwt_attacks",
            "Generate testing payloads from a JWT: alg:none variants + signature strip, weak-secret " \
            "HS256 re-signs, and header-parameter injection (kid path-traversal/SQLi, jku/x5u/jwk). " \
            "Pure transform: no network. Returns an array of {name, category, note, token}." do |s|
            s.field "token", strprop("the JWT to derive testing payloads from"), required: true
          end

          tool j, "sequence_analyze",
            "Analyze the randomness/predictability of a set of security tokens (session IDs, " \
            "CSRF tokens, reset tokens, API keys) — the same math as Burp/Caido Sequencer. " \
            "Pure compute, no network: pass a `tokens` array (collect them yourself, or use " \
            "sequence_start to replay a request). Returns a report with an overall rating " \
            "(SECURE/MODERATE/WEAK/CRITICAL), effective + Shannon entropy, character-set, " \
            "uniqueness/duplicate + sequential detection, and FIPS-style bit tests." do |s|
            s.field "tokens", strarrprop("the tokens to analyze (one per array element; ≥20 recommended)"), required: true
          end

          tool j, "list_rules",
            "List the project's Match & Replace rules (the Rewriter tab — literal/regex replace or " \
            "add/set/remove header, applied to in-flight request/response HEAD or BODY), in apply order." { }

          tool j, "list_projects",
            "List gori projects on this host (name, slug, db_path, db_size, last_modified, " \
            "workspace binding) and which one this server is currently serving (current:true). " \
            "Use switch_project to change the active project." { }

          tool j, "oast_presets",
            "List built-in public OAST providers (interactsh servers, BOAST, webhook.site, postbin)." { }

          tool j, "oast_poll",
            "Poll an OAST session (from oast_start) for new out-of-band callbacks. Returns only " \
            "interactions not already seen on this session; each has protocol/method/source/" \
            "destination/raw_request. Use to confirm blind SSRF/XXE/RCE etc." do |s|
            s.field "session_id", strprop("session id returned by oast_start"), required: true
          end

          tool j, "oast_payload",
            "Generate a fresh OAST payload URL for an existing session (local, no network). All " \
            "payloads in a session share the correlation id oast_poll watches." do |s|
            s.field "session_id", strprop("session id returned by oast_start"), required: true
          end

          if @allow_actions
            tool j, "oast_start",
              "Register an OAST listener and return {session_id, payload_url}. Default provider is " \
              "interactsh on a public server. Put payload_url in a target, then oast_poll for hits." do |s|
              s.field "provider", strprop("interactsh (default) | custom-http | webhook.site | BOAST | postbin")
              s.field "server", strprop("provider server/base URL (default: the provider's public preset)")
              s.field "token", strprop("optional provider auth token")
            end

            tool j, "oast_stop",
              "Deregister and stop an OAST session (frees the server-side registration)." do |s|
              s.field "session_id", strprop("session id returned by oast_start"), required: true
            end
            tool j, "intercept_forward",
              "Forward a currently-held intercept item (from intercept_list) byte-exact, letting " \
              "the request/response continue. The action is applied by the capturing gori instance " \
              "and surfaced as a visible notification to the human operator. Returns the outcome " \
              "(forwarded | no_such_item if it was already released | not_confirmed to retry)." do |s|
              s.field "item_id", intprop("held item id from intercept_list"), required: true
            end

            tool j, "intercept_drop",
              "Drop a currently-held intercept item: the proxy answers the client a canned 502 and " \
              "the message never reaches its destination. Applied by the capturing instance and " \
              "surfaced to the human. Returns dropped | no_such_item | not_confirmed." do |s|
              s.field "item_id", intprop("held item id from intercept_list"), required: true
            end

            tool j, "intercept_forward_edit",
              "Forward a held intercept item with EDITED bytes. Supply the full replacement wire " \
              "message in `raw` (fetch the current bytes from intercept_get with " \
              "include_sensitive:true → raw_base64, edit, send back). Content-Length is recomputed " \
              "to match the body; otherwise the bytes are " \
              "forwarded byte-exact (NO variable expansion — a security tool forwards exactly what " \
              "you send). Applied by the capturing instance + surfaced to the human. Returns " \
              "forwarded (edited:true) | no_such_item | not_confirmed." do |s|
              s.field "item_id", intprop("held item id from intercept_list"), required: true
              s.field "raw", strprop("the full edited HTTP wire message (request/status line + headers + body)"), required: true
            end

            tool j, "intercept_toggle",
              "Enable or disable the live intercept catch (desired state — idempotent). NOTE: " \
              "enabling only affects NEW connections; an already-established HTTP/2 connection " \
              "stays un-held. Applied by the capturing instance. Returns toggled | busy." do |s|
              s.field "enable", boolprop("true = start holding matching traffic; false = stop (auto-forwards anything currently held)"), required: true
            end

            tool j, "intercept_set_filter",
              "Set the conditional-intercept filter — a gori-QL-like query that NARROWS which " \
              "in-flight messages are held (e.g. 'host:api.example.com method:POST'). Empty " \
              "clears it (hold everything in scope). Applied by the capturing instance." do |s|
              s.field "query", strprop("filter query; empty string clears the filter"), required: true
            end

            tool j, "intercept_set_direction",
              "Set which leg(s) intercept holds: both | request | response. Applied by the " \
              "capturing instance." do |s|
              s.field "direction", strprop("both | request | response"), required: true
            end

            tool j, "create_rule",
              "Add a Match & Replace rule (the Rewriter tab) applied to in-flight traffic. " \
              "Persisted to the project. Note: a gori TUI already running applies it only after its " \
              "rules reload (reopen the Rewriter tab or restart); `gori run` and newly opened TUIs " \
              "pick it up immediately." do |s|
              s.field "pattern", strprop("for replace: the substring/regex to match; for a header op: the HEADER NAME"), required: true
              s.field "replacement", strprop("for replace: the replacement (empty = delete; supports $1 capture refs when match=regex); for add/set header: the header VALUE (default empty)")
              s.field "target", strprop("request|response (default request)")
              s.field "part", strprop("head|body — head = request/status line + headers, body = entity body (default head; ignored by header ops, which are head-only)")
              s.field "op", strprop("replace | add_header | set_header | remove_header (default replace)")
              s.field "match", strprop("for replace: literal | regex (default literal). Regex supports $1/\\1 capture groups")
              s.field "name", strprop("optional label for the rule")
              s.field "host", strprop("optional host glob scoping the rule (e.g. 'example.com' substring, '*.example.com' wildcard; empty = all hosts)")
              s.field "enabled", boolprop("create the rule already enabled (default true); pass false for an atomic disabled creation (no live window before you can preview/adjust it)")
            end

            tool j, "update_rule",
              "Update an existing Match & Replace rule by id. Omitted fields are left unchanged." do |s|
              s.field "id", intprop("rule id from list_rules"), required: true
              s.field "pattern", strprop("new match substring/regex, or header name")
              s.field "replacement", strprop("new replacement / header value")
              s.field "target", strprop("request|response")
              s.field "part", strprop("head|body")
              s.field "op", strprop("replace | add_header | set_header | remove_header")
              s.field "match", strprop("literal | regex")
              s.field "name", strprop("rule label")
              s.field "host", strprop("host glob ('' = all hosts)")
              s.field "enabled", boolprop("enable/disable the rule")
            end

            tool j, "preview_rule",
              "Estimate how many captured flows a rule WOULD affect (by replaying the same transform " \
              "over recent flows) WITHOUT creating it. Use before create_rule to size a rule. " \
              "Approximate: response bodies are scanned as stored wire bytes." do |s|
              s.field "pattern", strprop("the substring/regex to match, or header name"), required: true
              s.field "replacement", strprop("replacement / header value (matters for header ops, which change the head regardless of match)")
              s.field "target", strprop("request|response (default request)")
              s.field "part", strprop("head|body (default head)")
              s.field "op", strprop("replace | add_header | set_header | remove_header (default replace)")
              s.field "match", strprop("literal | regex (default literal)")
              s.field "host", strprop("host glob ('' = all hosts)")
            end

            tool j, "set_rule_enabled", "Enable or disable a Match & Replace rule by id." do |s|
              s.field "id", intprop("rule id from list_rules"), required: true
              s.field "enabled", boolprop("true to enable, false to disable"), required: true
            end

            tool j, "delete_rule", "Delete a Match & Replace rule by id." do |s|
              s.field "id", intprop("rule id from list_rules"), required: true
            end

            tool j, "create_project",
              "Create a new gori project (or reopen an existing one with the same name). " \
              "Does NOT switch to it — call switch_project to make it active." do |s|
              s.field "name", strprop("project display name (slugified for its directory)"), required: true
              s.field "description", strprop("optional description stored in the project settings")
            end

            tool j, "switch_project",
              "Point this server at a different project for all subsequent tools. Refused " \
              "while a fuzz/mine job is running. Verify with project_info afterwards." do |s|
              s.field "project", strprop("target project display name or directory slug"), required: true
            end

            tool j, "delete_project",
              "Delete a project's data from disk. TWO-STEP + destructive: first call with " \
              "dry_run:true (default) to get object counts, disk size, capture-lock status, and a " \
              "short-lived confirmation_token; then call again with dry_run:false and that token. " \
              "Refuses the currently-served project (switch away first) and any project locked by a " \
              "live capture." do |s|
              s.field "project", strprop("target project display name or directory slug"), required: true
              s.field "dry_run", boolprop("true (default) previews and issues a confirmation_token; false performs the delete")
              s.field "confirmation_token", strprop("the token from a dry_run:true call (required when dry_run:false)")
            end

            tool j, "create_note", "Create a new note with optional text content." do |s|
              s.field "text", strprop("initial text content for the new note")
            end

            tool j, "update_note", "Update the text content of an existing note by its database ID." do |s|
              s.field "id", intprop("database note ID to update"), required: true
              s.field "text", strprop("new text content for the note"), required: true
            end

            tool j, "delete_note", "Delete a note by its database ID." do |s|
              s.field "id", intprop("database note ID to delete"), required: true
            end

            tool j, "send_request",
              "Send/resend an HTTP request to its origin and return the response. " \
              "ACTIVE: makes a real outbound request from this host. Either pass " \
              "`flow_id` to resend a captured flow byte-exact, `repeater_id` to execute " \
              "a saved HTTP repeater (use send_websocket for WS repeaters), OR give an " \
              "absolute `url` with optional method/headers/body, or a verbatim `raw` request. " \
              "When `flow_id` or `repeater_id` is set, url/method/headers/body/raw are ignored (and " \
              "reported in `ignored_fields` with a precedence_warning). The result " \
              "always includes `effective_request` (the scheme/host/port/method/target/" \
              "http_version actually sent). " \
              "Host + Content-Length are auto-added when omitted on the url path." do |s|
              s.field "flow_id", intprop("resend a captured flow by id (no url needed; like the TUI Repeater)")
              s.field "repeater_id", intprop("execute a saved HTTP repeater by id (no url needed; respects its target/http2/sni/auto-Content-Length)")
              s.field "url", strprop("absolute URL incl. scheme+host, e.g. https://api.example.com/v1/x (required unless flow_id/repeater_id is given)")
              s.field "method", strprop("HTTP method (default GET)")
              s.field "headers", objprop("header name->value map")
              s.field "body", strprop("request body, sent as-is")
              s.field "raw", strprop("verbatim raw HTTP/1.1 request; overrides method/headers/body (scheme/host/port still come from url)")
              s.field "http2", boolprop("use real HTTP/2; defaults to the flow's version when flow_id is set)")
              s.field "timeout_ms", intprop("per-operation connect + idle (read/write) timeout in milliseconds; a timeout surfaces as a network-error result with error_kind (1-600000)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "record_history", boolprop("record the outbound request and response in History for audit/evidence (default true)")
              s.field "save_as_repeater", boolprop("save this request and its response to the Repeater workbench (default false)")
              s.field "include_sensitive_headers", boolprop("return Cookie/Set-Cookie/Authorization/API-key response values instead of [REDACTED] (default false)")
              s.field "body_mode", strprop("none | preview | full (default full) — control how much response body is inlined")
              s.field "max_body_bytes", intprop("cap inlined response-body bytes (clamped to 65536)")
              s.field "allow_unscoped", boolprop("send even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
              s.field "name", strprop("optional custom name for the saved repeater tab (only when save_as_repeater=true)")
              s.field "issue_id", intprop("optional issue to link to the saved repeater; requires save_as_repeater=true")
            end

            tool j, "send_websocket",
              "Execute a persisted WebSocket repeater: perform a fresh RFC 6455 handshake, send the " \
              "repeater's outbound messages (or a supplied override), and return inbound frames. " \
              "ACTIVE: makes a real outbound connection. The handshake response is persisted on " \
              "the repeater, while the outbound message template is left unchanged." do |s|
              s.field "repeater_id", intprop("WebSocket repeater database id"), required: true
              s.field "messages", strarrprop("optional outbound text-message override; stored repeater messages are used when absent")
              s.field "idle_ms", intprop("server-silence timeout after the first inbound frame (100-60000 ms; default 3000)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "allow_unscoped", boolprop("connect even when the target host is outside (or without) a configured scope (default false)")
              s.field "issue_id", intprop("optional issue to link to this repeater before sending")
            end

            tool j, "create_repeater", "Create a new repeater tab/session in the database. Provide either ('target' and 'request') OR ('flow_id') OR ('issue_id')." do |s|
              s.field "target", strprop("absolute target URL (scheme+host+optional port), e.g. https://api.example.com")
              s.field "request", strprop("verbatim raw HTTP request bytes/text")
              s.field "http2", boolprop("use HTTP/2 (default false)")
              s.field "auto_content_length", boolprop("auto-calculate Content-Length header (default true)")
              s.field "flow_id", intprop("optional original flow id this repeater stems from")
              s.field "issue_id", intprop("optional issue id to populate target/request/messages from")
              s.field "position", intprop("tab position order index (optional, defaults to appending at end)")
              s.field "sni", strprop("optional TLS Server Name Indication override")
              s.field "name", strprop("optional custom name for the repeater tab")
              s.field "ws_out_messages", arr_or_str_prop("optional array of strings (or a newline-separated string) representing outbound WebSocket messages")
            end

            tool j, "update_repeater", "Update an existing repeater tab's properties by database id." do |s|
              s.field "id", intprop("repeater database id"), required: true
              s.field "target", strprop("absolute target URL")
              s.field "request", strprop("verbatim raw HTTP request")
              s.field "http2", boolprop("use HTTP/2")
              s.field "auto_content_length", boolprop("auto-calculate Content-Length")
              s.field "sni", strprop("TLS SNI override")
              s.field "name", strprop("custom name for the repeater tab")
              s.field "ws_out_messages", arr_or_str_prop("optional array of strings (or a newline-separated string) representing outbound WebSocket messages")
            end

            tool j, "delete_repeater", "Delete a repeater tab by database id." do |s|
              s.field "id", intprop("repeater database id"), required: true
            end

            tool j, "create_issue", "Record a new issue in the project." do |s|
              s.field "title", strprop("issue title"), required: true
              s.field "severity", strprop("info|low|medium|high|critical (default info)")
              s.field "host", strprop("optional host the issue concerns")
              s.field "flow_id", intprop("optional flow id this issue links to")
              s.field "repeater_id", intprop("optional repeater id this issue links to")
            end

            tool j, "update_issue", "Update an existing issue's fields." do |s|
              s.field "id", intprop("issue id"), required: true
              s.field "title", strprop("new title")
              s.field "severity", strprop("info|low|medium|high|critical")
              s.field "notes", strprop("free-form notes (replaces existing)")
              s.field "status", strprop("open|confirmed|false-positive|resolved")
              s.field "repeater_id", intprop("optional repeater id to link to the issue")
            end

            tool j, "fuzz_start",
              "Start a fuzz/intruder run against an origin and return a job_id " \
              "immediately (poll with fuzz_status / fuzz_results; end with fuzz_stop). " \
              "ACTIVE: sends many real outbound requests from this host. Mark payload " \
              "positions with §…§ in `template`, via `marks` (literal token wrap, like " \
              "CLI --mark), or pass `flow_id` + auto:true, then provide payload sets via " \
              "`payloads`. Capped " \
              "at #{FUZZ_MAX_REQUESTS} requests / #{FUZZ_MAX_CONCURRENCY} concurrency." do |s|
              s.field "template", strprop("raw HTTP request with §…§ position markers")
              s.field "flow_id", intprop("seed the template from a captured flow id (instead of template)")
              s.field "url", strprop("absolute target URL (scheme+host); required unless flow_id carries one")
              s.field "auto", boolprop("auto-mark every query/cookie/body param when the template has no § markers")
              s.field "marks", strarrprop("literal tokens to mark as §…§ positions (each occurrence, mirrors CLI --mark); alternative to embedding §…§ in template")
              s.field "mode", strprop("sniper (default) | batteringram | pitchfork | clusterbomb")
              s.field "payloads", arrprop(%(array of payload sets, e.g. [{"list":["a","b"]},{"numbers":"1-100"},{"wordlist":"/p.txt"},{"null":5},{"brute":"abc:1-3"}] — JSON array, NOT a string. numbers/brute also accept a structured object: {"numbers":{"from":1,"to":100,"step":2}}, {"brute":{"charset":"abc","min":1,"max":3}}))
              s.field "match", jsonprop(%(keep only responses matching, e.g. {"status":"200,500-599","size":">1000","regex":"err"} — object or JSON string))
              s.field "filter", jsonprop(%(drop responses matching, same shape as match — object or JSON string))
              s.field "extract", strprop("regex; grep a value (capture group 1) from each response")
              s.field "concurrency", intprop("parallel requests (default 20, max #{FUZZ_MAX_CONCURRENCY})")
              s.field "rate", intprop("requests/sec cap (0 = unlimited)")
              s.field "timeout_ms", intprop("per-request connect + idle (read/write) timeout in milliseconds")
              s.field "retries", intprop("retries per request on a network error")
              s.field "http2", boolprop("use real HTTP/2 (default false)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "max_requests", intprop("caller cap on total requests")
              s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
              s.field "record_history", strprop("none (default) | matched | all — record each sent request+response as a History flow for audit/evidence; matched results carry the flow_id in fuzz_results (fetch full detail with get_flow). 'all' is capped at #{FUZZ_HISTORY_MAX} flows.")
            end

            tool j, "fuzz_status", "Counts + state of a fuzz job (running|done|budget_exhausted|stopped|error). " \
                                   "budget_exhausted means max_requests halted the run before every candidate was checked — " \
                                   "a partial result, NOT an exhaustive one; see incomplete_reason and candidates_remaining." do |s|
              s.field "job_id", strprop("id from fuzz_start"), required: true
            end

            tool j, "fuzz_results",
              "Paged matched results for a fuzz job (status/length/words/lines/duration/" \
              "extracted, plus a per-result flow_id when the run used record_history). No raw " \
              "bodies are inlined: fetch a hit's full request+response with get_flow(flow_id), " \
              "or re-issue it with send_request by substituting the payload into your template." do |s|
              s.field "job_id", strprop("id from fuzz_start"), required: true
              s.field "offset", intprop("start row (default 0)")
              s.field "limit", intprop("max rows (default 100, max 1000)")
              s.field "matched_only", boolprop("no-op: fuzz results are stored matched-only, so this never changes the page")
            end

            tool j, "fuzz_stop", "Stop a running fuzz job (in-flight requests finish)." do |s|
              s.field "job_id", strprop("id from fuzz_start"), required: true
            end

            tool j, "mine_start",
              "Discover hidden/unlinked parameters a server accepts (Burp \"Param Miner\"). " \
              "Stuffs a built-in wordlist of names into the request and bisects to isolate " \
              "the ones that change the response. Returns a job_id immediately (poll with " \
              "mine_status / mine_results; end with mine_stop). ACTIVE: sends many real " \
              "outbound requests. Capped at #{MINE_MAX_REQUESTS} requests / #{MINE_MAX_CONCURRENCY} concurrency." do |s|
              s.field "template", strprop("raw HTTP request to mine")
              s.field "flow_id", intprop("seed the request from a captured flow id (instead of template)")
              s.field "url", strprop("absolute target URL (scheme+host); required unless flow_id carries one")
              s.field "locations", strprop("comma list of where to mine: query,form,multipart,json,headers,cookies (default: auto-detect; multipart is applicable but off by default — pass it explicitly)")
              s.field "wordlist", strprop("path to an extra param-name wordlist (merged with the built-in list)")
              s.field "bucket", intprop("names stuffed per request before bisection (per location)")
              s.field "concurrency", intprop("parallel requests (default 10, max #{MINE_MAX_CONCURRENCY})")
              s.field "rate", intprop("requests/sec cap (0 = unlimited)")
              s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds")
              s.field "retries", intprop("retries per request on a network error")
              s.field "http2", boolprop("use real HTTP/2 (default false)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "max_requests", intprop("caller cap on total requests")
              s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
            end

            tool j, "mine_status", "Counts + state of a mine job (running|done|budget_exhausted|stopped|error). " \
                                   "budget_exhausted means max_requests halted the run before every name was tried; see incomplete_reason." do |s|
              s.field "job_id", strprop("id from mine_start"), required: true
            end

            tool j, "mine_results",
              "Paged discovered parameters for a mine job (name, location, evidence, confidence, canary, status, delta)." do |s|
              s.field "job_id", strprop("id from mine_start"), required: true
              s.field "offset", intprop("start row (default 0)")
              s.field "limit", intprop("max rows (default 100, max 1000)")
            end

            tool j, "mine_stop", "Stop a running mine job (in-flight requests finish)." do |s|
              s.field "job_id", strprop("id from mine_start"), required: true
            end

            tool j, "sequence_start",
              "Collect security tokens by replaying ONE request many times, then analyze their " \
              "randomness (Burp/Caido \"Sequencer\"). Each response's token is extracted via the " \
              "chosen location (cookie/header/regex/position/jsonpath). Returns a job_id immediately " \
              "(poll with sequence_status; get the report with sequence_results; end with " \
              "sequence_stop). To analyze tokens you already have, use sequence_analyze instead. " \
              "ACTIVE: sends many real requests. Capped at #{SEQUENCE_MAX_REQUESTS} requests / " \
              "#{SEQUENCE_MAX_CONCURRENCY} concurrency. Provide exactly ONE token location." do |s|
              s.field "template", strprop("raw HTTP request to replay")
              s.field "flow_id", intprop("seed the request from a captured flow id (instead of template)")
              s.field "url", strprop("absolute target URL (scheme+host); required unless flow_id carries one")
              s.field "cookie", strprop("token location: a Set-Cookie value by name")
              s.field "header", strprop("token location: a response header value by name")
              s.field "regex", strprop("token location: capture group 1 of this regex over the body")
              s.field "position", strprop("token location: a fixed body byte range 'A:B'")
              s.field "jsonpath", strprop("token location: a JSON body path ($.a.b[0])")
              s.field "count", intprop("target tokens to collect (default 500, max #{SEQUENCE_MAX_GOAL})")
              s.field "concurrency", intprop("parallel requests (default 1 — session tokens are often stateful; max #{SEQUENCE_MAX_CONCURRENCY})")
              s.field "rate", intprop("requests/sec cap (0 = unlimited)")
              s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds")
              s.field "retries", intprop("retries per request on a network error")
              s.field "http2", boolprop("use real HTTP/2 (default false)")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "max_requests", intprop("caller cap on total requests")
              s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
            end

            tool j, "sequence_status", "Counts + state of a sequence job (running|done|stopped|error): " \
                                       "goal, collected, sent, errors, tokens_stored." do |s|
              s.field "job_id", strprop("id from sequence_start"), required: true
            end

            tool j, "sequence_results",
              "The randomness REPORT over a sequence job's collected tokens (rating, effective + " \
              "Shannon entropy, character-set, uniqueness/sequential, per-test verdicts). The raw " \
              "tokens are never returned (they are secrets)." do |s|
              s.field "job_id", strprop("id from sequence_start"), required: true
            end

            tool j, "sequence_stop", "Stop a running sequence job (in-flight requests finish)." do |s|
              s.field "job_id", strprop("id from sequence_start"), required: true
            end

            tool j, "discover_start",
              "Spider a target and brute-force unlinked directories/paths (like Burp's crawl + " \
              "content discovery / ZAP's spider + forced browse). Follows links AND probes a " \
              "built-in path wordlist, with per-directory soft-404 calibration to keep false " \
              "positives down. Discovered endpoints are written into the project so list_sitemap / " \
              "get_flow see them. Returns a job_id immediately (poll with discover_status / " \
              "discover_results; end with discover_stop). ACTIVE: sends many real outbound requests. " \
              "Capped at #{DISCOVER_MAX_REQUESTS} requests / #{DISCOVER_MAX_CONCURRENCY} concurrency." do |s|
              s.field "url", strprop("seed URL (scheme+host, optionally a path subtree to confine to)"), required: true
              s.field "spider", boolprop("follow links (default true)")
              s.field "bruteforce", boolprop("brute-force directory/path names (default true)")
              s.field "max_depth", intprop("spider depth from the seed (default 4, max #{DISCOVER_MAX_DEPTH})")
              s.field "wordlist", strprop("path to an extra path wordlist (merged with the built-in list)")
              s.field "extensions", strprop("comma list of extensions to also probe (e.g. php,json,bak)")
              s.field "headers", objprop("custom request-header name->value map added to every probe (e.g. Authorization/Cookie); overrides Accept/User-Agent, Host/Connection are ignored")
              s.field "containment", strprop("boundary: same-origin | scope-aware (default) | host+subdomains")
              s.field "concurrency", intprop("parallel requests (default 20, max #{DISCOVER_MAX_CONCURRENCY})")
              s.field "rate", intprop("requests/sec cap (0 = unlimited)")
              s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds")
              s.field "retries", intprop("retries per request on a network error")
              s.field "insecure", boolprop("skip upstream TLS verification (default false)")
              s.field "max_requests", intprop("caller cap on total requests")
              s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED for an out-of-scope target, or when no scope is configured")
            end

            tool j, "discover_status", "Counts + state of a discover job (running|done|stopped|error), " \
                                       "including the FP/FN figures (calibrated_out / *_suppressed)." do |s|
              s.field "job_id", strprop("id from discover_start"), required: true
            end

            tool j, "discover_results",
              "Paged discovered endpoints for a discover job (url, method, status, length, content_type, source, depth, confidence)." do |s|
              s.field "job_id", strprop("id from discover_start"), required: true
              s.field "offset", intprop("start row (default 0)")
              s.field "limit", intprop("max rows (default 100, max 1000)")
            end

            tool j, "discover_stop", "Stop a running discover job (in-flight requests finish)." do |s|
              s.field "job_id", strprop("id from discover_start"), required: true
            end

            tool j, "list_jobs",
              "List all fuzz and mine jobs this session started (job_id, kind, status, " \
              "counts, target) — one call to see everything in flight." { }

            tool j, "get_job",
              "Full status of a fuzz OR mine job by id (dispatches by the id prefix), " \
              "so you can poll any job with one tool." do |s|
              s.field "job_id", strprop("a fuzz (fz_*) or mine (mn_*) job id"), required: true
            end

            tool j, "stop_job",
              "Stop a fuzz OR mine job. With wait:true, block until it reaches a terminal " \
              "state (or wait_timeout_ms elapses) and report the final status + stopped_at, " \
              "so stop-and-confirm is one call. Without wait, returns immediately (stop is async)." do |s|
              s.field "job_id", strprop("a fuzz (fz_*) or mine (mn_*) job id"), required: true
              s.field "wait", boolprop("block until the job actually stops (default false)")
              s.field "wait_timeout_ms", intprop("max ms to wait when wait:true (default 10000, max 60000)")
            end
          end
        end
      end

      # Dispatches a tools/call by name. Any store/repeater exception is converted to
      # an is_error Result so one bad call never tears down the server loop.
      def call(name : String, args : JSON::Any) : Result
        h = args.as_h? || EMPTY_HASH
        result = read_tool(name, h) || action_tool(name, h) ||
                 err("unknown tool: #{name}", "UNKNOWN_TOOL")
        result = classify(result)
        log_agent_action(name, result) if @allow_actions && AGENT_ACTION_TOOLS.includes?(name)
        result
      rescue ex
        Log.warn(exception: ex) { "tool #{name} failed" }
        err("tool error: #{ex.message}", "INTERNAL")
      end

      # #124 — record a completed agent mutation/send into the store event feed so the AI's
      # activity is visible to the human (and tailable via list_events). A failure is logged
      # too (warn) — a scope-blocked or errored send is exactly what an operator wants to see.
      # A read-only-disabled attempt (TOOL_DISABLED) executed nothing, so it is not logged.
      # Best-effort: feed logging never breaks the tool call it describes.
      private def log_agent_action(name : String, result : Result) : Nil
        return if result.error_code == "TOOL_DISABLED"
        level = result.is_error ? "warn" : "info"
        outcome = result.is_error ? "failed (#{result.error_code || "error"})" : "ok"
        @store.insert_event("agent", "agent_action", level, "#{name} #{outcome}", payload: name)
      rescue ex
        Log.warn(exception: ex) { "event feed: failed to log agent action #{name}" }
      end

      # Guarantees every error Result carries a stable `error_code`. Explicitly
      # coded errors (and all success results) pass through untouched; an uncoded
      # plain-message error defaults to INVALID_ARGUMENT — the residual bucket is
      # argument validation ("missing required 'x'", "invalid 'x'", …). A JSON
      # object payload (send_request / send_websocket carry their own `error` /
      # `error_kind`) is left uncoded so its envelope is surfaced verbatim.
      private def classify(r : Result) : Result
        return r unless r.is_error && r.error_code.nil?
        return r if r.text.starts_with?('{')
        r.copy_with(error_code: "INVALID_ARGUMENT")
      end

      # Read-only tools (always exposed). nil when `name` isn't one of them.
      # --- OAST (out-of-band) tools ------------------------------------------
      private def oast_presets_tool : Result
        presets = Oast::Presets.all.map { |p| {type: p.kind.label, name: p.name, host: p.host} }
        Result.new(presets.to_json)
      end

      private def oast_start(h) : Result
        provider = str(h, "provider") || "interactsh"
        kind = Oast::ProviderKind.parse?(provider)
        return Result.new("unknown provider '#{provider}'", is_error: true) unless kind
        host = str(h, "server") || Oast::Presets.all.find { |p| p.kind == kind }.try(&.host)
        return Result.new("'server' is required for #{kind.label}", is_error: true) unless host
        prov = Oast::Provider.build(kind, host, str(h, "token"))
        http = Oast::HttpClient.new(@verify_upstream)
        session = prov.register(http)
        # Unpredictable session id: a sequential "oast-N" is trivially guessable, so
        # a co-tenant sharing this process could poll another agent's out-of-band
        # callbacks. Secure-random hex removes the guessing surface (mirrors the
        # delete_project confirmation tokens).
        sid = "oast_#{Random::Secure.hex(8)}"
        @oast_mcp[sid] = OastMcpSession.new(prov, session, http, kind.label)
        payload = prov.generate_payload(session)
        Result.new({session_id: sid, provider: kind.label, payload_url: payload}.to_json)
      rescue ex
        Result.new("OAST register failed: #{ex.message}", is_error: true)
      end

      private def oast_payload(h) : Result
        sid = str(h, "session_id")
        s = sid ? @oast_mcp[sid]? : nil
        return Result.new("unknown or expired session_id", is_error: true) unless s
        Result.new({session_id: sid, payload_url: s.provider.generate_payload(s.session)}.to_json)
      end

      private def oast_poll(h) : Result
        sid = str(h, "session_id")
        s = sid ? @oast_mcp[sid]? : nil
        return Result.new("unknown or expired session_id", is_error: true) unless s
        fresh = s.provider.poll(s.http, s.session).reject { |i| s.seen.includes?(i.unique_id) }
        fresh.each { |i| s.seen << i.unique_id }
        callbacks = fresh.map { |i| Oast::Present.interaction(i, s.kind_label) }
        Result.new({session_id: sid, count: fresh.size, callbacks: callbacks}.to_json)
      rescue ex
        Result.new("OAST poll failed: #{ex.message}", is_error: true)
      end

      private def oast_stop(h) : Result
        sid = str(h, "session_id")
        s = sid ? @oast_mcp.delete(sid) : nil
        return Result.new("unknown or expired session_id", is_error: true) unless s
        s.provider.deregister(s.http, s.session) rescue nil
        Result.new({stopped: sid}.to_json)
      end

      private def read_tool(name : String, h) : Result?
        case name
        when "list_history"            then list_history(h)
        when "list_events"             then list_events(h)
        when "intercept_list"          then intercept_list(h)
        when "intercept_get"           then intercept_get(h)
        when "get_flow"                then get_flow(h)
        when "get_response_body_chunk" then get_response_body_chunk(h)
        when "list_sitemap"            then list_sitemap(h)
        when "list_issues"             then list_issues(h)
        when "get_issue"               then get_issue(h)
        when "list_scope"              then list_scope
        when "project_info"            then project_info
        when "get_current_context"     then get_current_context
        when "get_repeater_context"    then get_repeater_context(h)
        when "ql_reference"            then ql_reference
        when "list_notes"              then list_notes
        when "get_note"                then get_note(h)
        when "decode"                  then decoder(h)
        when "oast_presets"            then oast_presets_tool
        when "oast_poll"               then oast_poll(h)
        when "oast_payload"            then oast_payload(h)
        when "jwt_decode"              then jwt_decode_tool(h)
        when "jwt_encode"              then jwt_encode_tool(h)
        when "jwt_attacks"             then jwt_attacks_tool(h)
        when "sequence_analyze"        then sequence_analyze(h)
        when "list_rules"              then list_rules
        when "list_projects"           then list_projects
        when "ql_explain"              then ql_explain(h)
        end
      end

      # Action + write tools, each gated behind allow_actions. nil when `name`
      # isn't one of them.
      private def action_tool(name : String, h) : Result?
        case name
        when "send_request"            then gated { send_request(h) }
        when "send_websocket"          then gated { send_websocket(h) }
        when "oast_start"              then gated { oast_start(h) }
        when "oast_stop"               then gated { oast_stop(h) }
        when "intercept_forward"       then gated { intercept_forward(h) }
        when "intercept_drop"          then gated { intercept_drop(h) }
        when "intercept_forward_edit"  then gated { intercept_forward_edit(h) }
        when "intercept_toggle"        then gated { intercept_toggle(h) }
        when "intercept_set_filter"    then gated { intercept_set_filter(h) }
        when "intercept_set_direction" then gated { intercept_set_direction(h) }
        when "create_repeater"         then gated { create_repeater(h) }
        when "update_repeater"         then gated { update_repeater(h) }
        when "delete_repeater"         then gated { delete_repeater(h) }
        when "create_issue"            then gated { create_issue(h) }
        when "update_issue"            then gated { update_issue(h) }
        when "fuzz_start"              then gated { fuzz_start(h) }
        when "fuzz_status"             then gated { fuzz_status(h) }
        when "fuzz_results"            then gated { fuzz_results(h) }
        when "fuzz_stop"               then gated { fuzz_stop(h) }
        when "mine_start"              then gated { mine_start(h) }
        when "mine_status"             then gated { mine_status(h) }
        when "mine_results"            then gated { mine_results(h) }
        when "mine_stop"               then gated { mine_stop(h) }
        when "sequence_start"          then gated { sequence_start(h) }
        when "sequence_status"         then gated { sequence_status(h) }
        when "sequence_results"        then gated { sequence_results(h) }
        when "sequence_stop"           then gated { sequence_stop(h) }
        when "discover_start"          then gated { discover_start(h) }
        when "discover_status"         then gated { discover_status(h) }
        when "discover_results"        then gated { discover_results(h) }
        when "discover_stop"           then gated { discover_stop(h) }
        when "list_jobs"               then gated { list_jobs }
        when "get_job"                 then gated { get_job(h) }
        when "stop_job"                then gated { stop_job(h) }
        when "create_note"             then gated { create_note(h) }
        when "update_note"             then gated { update_note(h) }
        when "delete_note"             then gated { delete_note(h) }
        when "create_rule"             then gated { create_rule(h) }
        when "update_rule"             then gated { update_rule(h) }
        when "preview_rule"            then gated { preview_rule(h) }
        when "set_rule_enabled"        then gated { set_rule_enabled(h) }
        when "delete_rule"             then gated { delete_rule(h) }
        when "create_project"          then gated { create_project(h) }
        when "switch_project"          then gated { switch_project(h) }
        when "delete_project"          then gated { delete_project(h) }
        end
      end

      # Resolve body_mode (none|preview|full) + max_body_bytes into an inlined-body
      # {cap_bytes, omit} pair. none → metadata only; preview → small cap; full
      # (default) → the full MAX_TEXT cap. max_body_bytes tunes the cap (clamped to
      # MAX_TEXT — larger bodies are paged with get_response_body_chunk).
      private def body_return_opts(h) : {Int32, Bool}
        # Only a POSITIVE max_body_bytes overrides the cap; 0/negative falls back to
        # the mode default (Crystal treats 0 as truthy, so `max || default` alone
        # wouldn't). Use body_mode:none for a zero-byte, shape-only body.
        raw = int(h, "max_body_bytes").try(&.clamp(0_i64, Serialize::MAX_TEXT.to_i64).to_i)
        max = (raw && raw > 0) ? raw : nil
        case str(h, "body_mode").try(&.strip.downcase)
        when "none"    then {0, true}
        when "preview" then {max || BODY_PREVIEW_BYTES, false}
        else                {max || Serialize::MAX_TEXT, false}
        end
      end

      # Surface a silently-clamped pagination value: echo the requested offset/limit
      # only when it differed from the effective one, with a warning — so a caller
      # sees that e.g. limit:0 or a negative offset was coerced, not honored. Shared
      # by the object-returning list tools for a consistent pagination contract.
      private def emit_clamp(j : JSON::Builder, req_off : Int64?, offset : Int32,
                             req_lim : Int64?, limit : Int32) : Nil
        off_clamped = !req_off.nil? && req_off != offset.to_i64
        lim_clamped = !req_lim.nil? && req_lim != limit.to_i64
        j.field "requested_offset", req_off if off_clamped
        j.field "requested_limit", req_lim if lim_clamped
        if off_clamped || lim_clamped
          j.field "pagination_warning", "requested pagination was out of range and clamped to valid bounds"
        end
      end

      private def split_wire_request(bytes : Bytes) : {Bytes, Bytes?}
        boundary = nil.as(Int32?)
        i = 0
        while i + 3 < bytes.size
          if bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8 &&
             bytes[i + 2] == 0x0d_u8 && bytes[i + 3] == 0x0a_u8
            boundary = i + 4
            break
          end
          i += 1
        end
        raise Gori::Error.new("request has no CRLF header terminator; cannot record it in History") unless boundary
        head = bytes[0, boundary]
        body_size = bytes.size - boundary
        body = body_size > 0 ? bytes[boundary, body_size] : nil
        {head, body}
      end

      # A background job's fiber must never exit with the job still :running — that
      # hangs every poller and permanently trips jobs_running?. Land it terminal.
      private def finalize_job(job : FuzzJob | MineJob | SequenceJob) : Nil
        if job.status == :running
          job.status = :error
          job.error_msg ||= "job ended without a terminal event"
        end
        job.ended_at_ms ||= Time.utc.to_unix_ms
      end

      # Terminal status for a finished fuzz/mine job. A non-stopped Done whose
      # processed count fell short of the known candidate `total` means the request
      # budget (max_requests) halted the run early — reported as :budget_exhausted
      # so a partial "0 found" is not read as an exhaustive result. A prior :error
      # is preserved (a generation ErrorEvent then a Done must stay failed).
      private def terminal_status(current : Symbol, stopped : Bool, done_count : Int64, total : Int64?) : Symbol
        return :error if current == :error
        return :stopped if stopped
        (total && done_count < total) ? :budget_exhausted : :done
      end

      # Machine reason a terminal job is not a clean :done, else nil.
      private def incomplete_reason(status : Symbol) : String?
        case status
        when :budget_exhausted then "budget_exhausted"
        when :stopped          then "stopped"
        when :error            then "failed"
        else                        nil
        end
      end

      # The run's immutable audit metadata (target + pacing/budget + start/end times)
      # so a fuzz/mine result set is self-describing evidence.
      private def emit_audit(j : JSON::Builder, a : JobAudit, ended_at_ms : Int64?) : Nil
        j.field "audit" do
          j.object do
            j.field "target", a.target
            j.field "rate", a.rate
            j.field "concurrency", a.concurrency
            j.field "max_requests", a.max_requests
            j.field "started_at", a.started_at_ms
            j.field "started_at_iso", Serialize.unix_micros_iso(a.started_at_ms * 1000)
            j.field "ended_at", ended_at_ms
            if e = ended_at_ms
              j.field "ended_at_iso", Serialize.unix_micros_iso(e * 1000)
              j.field "elapsed_ms", e - a.started_at_ms
            end
          end
        end
      end

      private def fuzz_origin(h, default_target : String?) : Fuzz::Origin
        url_raw = str(h, "url").presence || default_target
        raise FuzzArgError.new("provide a 'url' target (scheme://host) or a flow_id that carries one") unless url_raw
        url = Env.expand(url_raw)
        scheme, host, port = Repeater::FlowRequest.parse_target(url)
        raise FuzzArgError.new("could not parse a host from '#{url}'") if host.empty?
        Fuzz::Origin.new(scheme, host, port)
      end

      private def fuzz_timeout(h) : Time::Span?
        int(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds)
      end

      private def clamp_nonneg(n : Int64?) : Int32
        return 0 unless n
        n.clamp(0_i64, Int32::MAX.to_i64).to_i
      end

      # An error Result when `s` is a present, non-blank, UNRECOGNISED severity;
      # nil when it's absent/blank (caller's default) or a valid label. Shared by
      # create + update so both reject the same typos.
      private def bad_severity(s : String?) : Result?
        return nil if s.nil? || s.strip.empty?
        return nil if severity_from(s)
        Result.new("invalid severity: #{s} (info|low|medium|high|critical)", is_error: true)
      end

      private def bad_status(s : String?) : Result?
        return nil if s.nil? || s.strip.empty?
        return nil if status_from(s)
        Result.new("invalid status: #{s} (open|confirmed|false-positive|resolved)", is_error: true)
      end

      # --- helpers ------------------------------------------------------------

      private def gated(& : -> Result) : Result
        return err("tool disabled (gori mcp --read-only)", "TOOL_DISABLED") unless @allow_actions
        yield
      end

      # Build a coded error Result (the structured-error contract). `code` is a
      # stable machine token (NOT_FOUND, INVALID_ARGUMENT, QUERY_SYNTAX,
      # NETWORK_ERROR, BUDGET_EXHAUSTED, PROJECT_BUSY, …); `retryable` tells a
      # caller whether the same call may succeed later; `field` names the offending
      # argument; `details` carries extra machine data. Human text stays in `text`.
      private def err(message : String, code : String, *, field : String? = nil,
                      retryable : Bool = false, details : JSON::Any? = nil) : Result
        Result.new(message, is_error: true, error_code: code, field: field,
          retryable: retryable, details: details)
      end

      # A resource-not-found error (bad flow/repeater/issue/note/rule/job id).
      private def not_found(message : String) : Result
        err(message, "NOT_FOUND")
      end

      # A store write that couldn't be persisted (cross-process SQLite lock held by
      # a capturing TUI, or an unwritable disk) — transient, so retryable.
      private def busy(message : String) : Result
        err(message, "PROJECT_BUSY", retryable: true)
      end

      # Emits scope_decision / matched scope_rule_id / effective_host onto an
      # active tool's result object so the send's scope evidence is self-contained.
      private def emit_scope(j : JSON::Builder, sc : ScopeCheck) : Nil
        j.field "scope_decision", sc.decision
        j.field "scope_rule_id", sc.rule_id if sc.rule_id
        j.field "effective_host", sc.host
      end

      private def str(h, key : String) : String?
        h[key]?.try(&.as_s?)
      end

      # Whether `key` is present with a non-null value (a JSON null reads as
      # "absent" for our purposes). Lets a caller tell a missing arg from one that
      # was supplied but couldn't be coerced.
      private def present?(h, key : String) : Bool
        v = h[key]?
        return false unless v
        !v.raw.nil?
      end

      # Error text for a REQUIRED integer id that didn't coerce: distinguishes a
      # genuinely absent arg from one that was supplied but isn't an integer (e.g.
      # 1.9 or "oops"), so the caller isn't told "missing" for a value it did send.
      private def id_error(h, key : String) : String
        present?(h, key) ? "invalid '#{key}' (expected an integer)" : "missing required '#{key}'"
      end

      # Coerce a JSON arg to Int64. Accepts a JSON integer, an INTEGRAL float
      # (100.0 → 100; many encoders emit ints as floats), and a numeric STRING
      # ("5" → 5) — clients/LLMs often serialize tool args as strings and the
      # schema's "integer" type is advisory, not enforced. A fractional float
      # (5.9) is rejected rather than silently truncated, so the number and
      # string encodings of the same value agree; an out-of-Int64-range float
      # returns nil rather than raising OverflowError — for a limit that falls
      # back to the default, for an id it reads as no-such-id, never a crash.
      private def int(h, key : String) : Int64?
        v = h[key]?
        return nil unless v
        if i = v.as_i64?
          return i
        end
        if f = v.as_f?
          return nil unless f.finite? && f == f.trunc
          return f.to_i64
        end
        v.as_s?.try(&.to_i64?)
      rescue OverflowError
        nil
      end

      private def optional_int_arg(h, key : String) : Int64?
        value = int(h, key)
        if present?(h, key) && value.nil?
          raise Gori::Error.new("invalid '#{key}' (expected an integer)")
        end
        value
      end

      private def bounded_int_arg(h, key : String, default : Int64, *, min : Int64,
                                  max : Int64 = Int64::MAX) : Int64
        value = optional_int_arg(h, key) || default
        if value < min
          raise Gori::Error.new("invalid '#{key}' (expected an integer >= #{min})")
        end
        value.clamp(min, max)
      end

      private def bool(h, key : String) : Bool?
        v = h[key]?
        return nil unless v
        return v.as_bool? unless v.as_bool?.nil?
        # Clients/LLMs often serialize tool args as strings (the schema's "boolean" is
        # advisory, not enforced) — accept "true"/"false" so a stringified flag isn't
        # silently coerced to false, mirroring int()'s leniency.
        case v.as_s?.try(&.downcase)
        when "true"  then true
        when "false" then false
        else              nil
        end
      end

      private def bool_arg(h, key : String, default : Bool) : Bool
        value = bool(h, key)
        if present?(h, key) && value.nil?
          raise Gori::Error.new("invalid '#{key}' (expected true or false)")
        end
        value.nil? ? default : value
      end

      private def clamp(n : Int64?, default : Int32, max : Int32) : Int32
        return default unless n
        n.clamp(1_i64, max.to_i64).to_i
      end

      private def severity_from(s : String?) : Store::Severity?
        return nil unless s
        Store::Severity.parse?(s.strip)
      end

      private def status_from(s : String?) : Store::Status?
        return nil unless s
        case s.strip.downcase
        when "open"                                              then Store::Status::Open
        when "confirmed"                                         then Store::Status::Confirmed
        when "false-positive", "false_positive", "falsepositive" then Store::Status::FalsePositive
        when "resolved"                                          then Store::Status::Resolved
        else                                                          nil
        end
      end

      # --- tools/list schema builders -----------------------------------------

      # Emits one {name, description, inputSchema} object. The block declares
      # properties on a builder; `required` names are tracked and emitted.
      private def tool(j : JSON::Builder, name : String, description : String, & : SchemaBuilder ->) : Nil
        sb = SchemaBuilder.new
        yield sb
        j.object do
          j.field "name", name
          j.field "description", description
          j.field "inputSchema" do
            j.object do
              j.field "type", "object"
              j.field "properties" do
                j.object { sb.properties.each { |pname, schema| j.field(pname) { schema.to_json(j) } } }
              end
              j.field "required" do
                j.array { sb.required.each { |r| j.string r } }
              end
            end
          end
        end
      end

      private def strprop(desc : String) : JSON::Any
        prop("string", desc)
      end

      private def intprop(desc : String) : JSON::Any
        prop("integer", desc)
      end

      private def boolprop(desc : String) : JSON::Any
        prop("boolean", desc)
      end

      private def objprop(desc : String) : JSON::Any
        JSON.parse(%({"type":"object","description":#{desc.to_json},"additionalProperties":{"type":"string"}}))
      end

      private def arrprop(desc : String) : JSON::Any
        JSON.parse(%({"type":"array","description":#{desc.to_json},"items":{"type":"object"}}))
      end

      private def strarrprop(desc : String) : JSON::Any
        JSON.parse(%({"type":"array","description":#{desc.to_json},"items":{"type":"string"}}))
      end

      # Accepts a JSON array directly or a JSON-encoded string, or a string.
      private def arr_or_str_prop(desc : String) : JSON::Any
        JSON.parse(%({"description":#{desc.to_json},"oneOf":[{"type":"array","items":{"type":"string"}},{"type":"string"}]}))
      end

      # Accepts a JSON object directly or a JSON-encoded string (LLM clients vary).
      private def jsonprop(desc : String) : JSON::Any
        JSON.parse(%({"description":#{desc.to_json},"oneOf":[{"type":"object"},{"type":"string"}]}))
      end

      private def prop(type : String, desc : String) : JSON::Any
        JSON.parse(%({"type":#{type.to_json},"description":#{desc.to_json}}))
      end

      # Collects a tool's input-schema properties + required list.
      class SchemaBuilder
        getter properties = [] of {String, JSON::Any}
        getter required = [] of String

        def field(name : String, schema : JSON::Any, required : Bool = false) : Nil
          @properties << {name, schema}
          @required << name if required
        end
      end
    end
  end
end
