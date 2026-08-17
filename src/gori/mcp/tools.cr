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
require "./tools/authorize"
require "./tools/compare"
require "./tools/context"
require "./tools/decode"
require "./tools/cookie"
require "./tools/discover"
require "./tools/env"
require "./tools/flows"
require "./tools/fuzz"
require "./tools/host_overrides"
require "./tools/session_slots"
require "./tools/import"
require "./tools/intercept"
require "./tools/issues"
require "./tools/jobs"
require "./tools/links"
require "./tools/mine"
require "./tools/minimize"
require "./tools/notes"
require "./tools/oast_providers"
require "./tools/oast_sessions"
require "./tools/probe"
require "./tools/projects"
require "./tools/ql"
require "./tools/repeater"
require "./tools/rules"
require "./tools/color_rules"
require "./tools/scope"
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
      # `part` is "response" (the default, and everything this tool ever served) or "request".
      # The request cursor exists because `get_repeater_context` is the ONLY read-back of a
      # repeater's request and it caps at MCP_REPEATER_REQUEST_MAX — so bytes past the cap
      # were unreachable from MCP entirely.
      record BodyChunkOptions, flow_id : Int64?, repeater_id : Int64?, offset : Int64,
        limit : Int32, raw : Bool, part : String = "response" do
        def request? : Bool
          part == "request"
        end
      end

      # Outcome of the active-tool scope gate, produced by the shared `Gori::Outbound` seam
      # (src/gori/outbound.cr) rather than a per-surface check. `decision` is "in_scope",
      # "out_of_scope", or "unscoped" (no scope rules configured); on MCP all three block
      # unless the caller passed allow_unscoped:true.
      alias ScopeCheck = Gori::Outbound::Verdict

      EMPTY_HASH = {} of String => JSON::Any

      # #124 — MCP tools whose SUCCESSFUL (or failed) execution is a real mutation or
      # outbound send worth recording in the event feed as a visible "agent action", so the
      # human can see (via list_events, and later the notification ring) what the AI did.
      # Deliberately EXCLUDES gated READ tools (fuzz_status/results, mine_status/results,
      # list_jobs, get_job, preview_rule) and project-management tools (switch_project reopens
      # @store, so a post-hoc append would land in the wrong DB) — only in-project side effects.
      AGENT_ACTION_TOOLS = Set{
        "send_request", "send_websocket",
        # The intercept write verbs act on LIVE traffic the human is holding — forwarding,
        # dropping, or rewriting bytes mid-flight is the single most consequential thing an
        # agent can do here, so it belongs in the feed more than any store mutation does.
        # toggle/set_filter/set_direction change what the proxy HOLDS next, which silently
        # reshapes the human's queue; they are recorded for the same reason.
        "intercept_forward", "intercept_drop", "intercept_forward_edit",
        "intercept_toggle", "intercept_set_filter", "intercept_set_direction",
        "fuzz_start", "fuzz_stop", "mine_start", "mine_stop", "sequence_start", "sequence_stop", "discover_start", "discover_stop",
        "authorize_start", "authorize_stop", "stop_job",
        "create_issue", "update_issue",
        "probe_dismiss", "probe_promote", "probe_delete",
        "set_probe_rule_enabled", "create_probe_rule", "update_probe_rule", "delete_probe_rule", "set_probe_mode",
        "delete_issue", "update_scope_rule", "set_sitemap_tag",
        "delete_flow", "clear_history",
        "add_link", "remove_link",
        "create_oast_provider", "update_oast_provider", "set_oast_provider_enabled", "delete_oast_provider",
        "minimize_repeater",
        "create_rule", "update_rule", "delete_rule", "set_rule_enabled",
        "create_color_rule", "update_color_rule", "delete_color_rule", "set_color_rule_enabled", "move_color_rule",
        "create_custom_color", "update_custom_color", "delete_custom_color",
        "create_extract_rule", "update_extract_rule", "delete_extract_rule", "set_extract_rule_enabled",
        "create_note", "update_note", "delete_note",
        "create_repeater", "update_repeater", "delete_repeater",
        "oast_start", "oast_stop", "oast_resume", "oast_release",
        "add_scope_rule", "delete_scope_rule", "set_scope_enabled", "set_sandbox",
        "set_env_var", "delete_env_var",
        "create_session_slot", "update_session_slot", "delete_session_slot", "set_active_session_slot",
        "add_host_override", "update_host_override", "delete_host_override",
        "import_flows",
      }

      # R2-3 — tools that READ or WRITE the per-project `$KEY` env vars. Env vars live in a
      # process-global (Settings.project_env_vars) loaded once at bind time (initialize /
      # switch_project's Env.load_project), so a mid-session CLI change (`gori run project
      # env set KEY val`) is otherwise invisible to an already-running MCP server. `call`
      # reloads from the store before dispatching any of these.
      #
      # Three populations, all of which need the fresh value:
      #   - active/outbound tools that EXPAND or MASK `$KEY` at call time;
      #   - `list_env`, which would otherwise REPORT a stale set as fact;
      #   - `set_env_var`/`delete_env_var`, which read-modify-WRITE the whole array
      #     (Env.save_project persists it wholesale) — on a stale copy that silently
      #     DELETES every var another process added since we bound.
      # Deliberately EXCLUDES other read tools and the async *_status / *_results /
      # *_stop pollers (a running job already captured its fully expanded template at
      # build time) — and `authorize_start`, which is the one active *_start that never
      # expands a `$KEY` at all: an authorize run sends the CAPTURED bytes under an
      # operator-authored header overlay, so its backend marks every buffer verbatim
      # (`Fuzz::Backend.all_verbatim`, see `Authorize::Engine#send_one`). A refresh there
      # would re-read the store for a value nothing on that path reads.
      ENV_REFRESH_TOOLS = Set{
        "send_request", "send_websocket",
        "fuzz_start", "mine_start", "sequence_start", "discover_start",
        "list_env", "set_env_var", "delete_env_var",
      }

      # A live OAST listening session held server-side across tool calls (oast_start →
      # oast_poll/oast_payload → oast_stop). Ephemeral to this MCP process.
      private class OastMcpSession
        getter provider : Oast::Provider
        getter session : Oast::Session
        getter http : Oast::Http
        getter kind_label : String
        getter seen = Set(String).new
        # The `oast_sessions` row this handle was RESUMED from (nil for an ad-hoc oast_start).
        # Set means the handle is a project listener: oast_poll persists what it catches and
        # stamps last_poll_at, and oast_stop keeps the registration instead of dropping it.
        getter store_session_id : Int64?

        def initialize(@provider, @session, @http, @kind_label, @store_session_id : Int64? = nil)
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
      # Ceiling on how many times ONE job may log from its per-event rescues. Those sit on
      # the per-result path, so a persistent failure logs once per request sent; a client
      # that does not drain stderr then fills the pipe and parks the job fiber, wedging the
      # job at `:running`. The count itself is never capped — only the writes.
      DRAIN_LOG_CAP = 20

      # Param-miner safety rails (same intent as the fuzz caps).
      MINE_MAX_REQUESTS    = 100_000_i64
      MINE_MAX_CONCURRENCY =         100
      MINE_MAX_STORED      =      10_000

      # Sequencer (token randomness) safety rails.
      SEQUENCE_MAX_REQUESTS    = 100_000_i64
      SEQUENCE_MAX_GOAL        =      20_000
      SEQUENCE_MAX_CONCURRENCY =          20
      SEQUENCE_MAX_STORED      =      20_000 # tokens kept in memory for the analysis

      # Authorize (access-control replay) safety rails. The run's size is `flows × identities`
      # and BOTH halves are caller-supplied, so the cap is on the product rather than on
      # either factor — a 500-row query under four identities is two thousand requests on a
      # target from one tool call.
      AUTHORIZE_MAX_SENDS  = 2_000
      AUTHORIZE_MAX_FLOWS  =   500 # rows a `query` may contribute
      AUTHORIZE_MAX_STORED =   500 # replayed requests kept in memory for authorize_results

      # Discover (spider + brute) safety rails.
      DISCOVER_MAX_REQUESTS    = 100_000_i64
      DISCOVER_MAX_CONCURRENCY =         100
      DISCOVER_MAX_STORED      =      20_000
      DISCOVER_MAX_DEPTH       =          12

      MCP_REPEATER_REQUEST_MAX = 16 * 1024

      # Ceiling on concurrently-live OAST listening sessions (each holds an Oast::Http
      # socket until oast_stop). Bounds the leak from an agent that starts sessions and
      # never stops them; well above any realistic out-of-band test.
      MAX_OAST_SESSIONS = 32

      # Ceiling on how many finished jobs each of the five async-job maps
      # (@jobs/@mine_jobs/@sequence_jobs/@discover_jobs/@authorize_jobs) retains. The server is
      # long-lived (it outlives a single call), and a completed job holds its whole
      # buffered result set (up to FUZZ_MAX_STORED etc.) for the process lifetime, so
      # a long session issuing many *_start calls would grow memory without bound.
      # A new *_start evicts the OLDEST terminal jobs down to this cap; :running jobs
      # are never evicted (their fibers still reference them and a poller may return).
      MAX_JOBS_RETAINED = 100

      # Default inlined-body cap for body_mode:preview (full uses Serialize::MAX_TEXT).
      BODY_PREVIEW_BYTES = 2048

      # Ceiling on the `decoder` tool's returned output string. A Decoder step can
      # produce up to 32 MiB (Decoder::MAX_OUT); returning that inline would swamp
      # the JSON-RPC channel, so truncate the display string and flag it.
      DECODER_MAX_OUTPUT = 256 * 1024

      # Tools may start *unbound* (`store` nil): project lifecycle + pure-compute tools
      # work immediately; traffic/action tools return NO_PROJECT until switch/create binds a DB.
      # `bind_error` is set when the process WANTED a project and could not open it (a
      # corrupt/absent db, an unreadable projects dir). It only ever accompanies an unbound
      # start, and it is cleared the moment a bind succeeds — see `bind_project`.
      def initialize(@store : Store?, @allow_actions : Bool, @verify_upstream : Bool,
                     @project_name : String? = nil, @project_slug : String? = nil,
                     @db_path : String? = nil, @selection_source : String? = nil,
                     @workspace_root : String? = nil, @project_id : String? = nil,
                     @bind_error : String? = nil)
        # The binding table (#501) is built ONCE per bound project and kept, not rebuilt per
        # call: an MCP server is long-lived and IS an extraction source — `send_request` goes
        # through `Repeater::Sender`, so a `$SESSION` bound by a login here has to still be
        # bound on the next tool call. Rebuilding it per call would silently make every
        # binding write-only.
        @bindings = nil.as(Gori::Bindings?)
        if s = @store
          bind_project_network(s)
          Env.load_project(s)
          bind_binding_layer(s)
        end
        @jobs = {} of String => FuzzJob
        @mine_jobs = {} of String => MineJob
        @sequence_jobs = {} of String => SequenceJob
        @discover_jobs = {} of String => DiscoverJob
        @authorize_jobs = {} of String => AuthorizeJob
        @oast_mcp = {} of String => OastMcpSession
        @job_seq = 0
        # switch_project reopens @store; @owns_store tracks whether WE opened the
        # current one (and must close it on the next switch). The initial store is
        # owned by the caller (the `gori mcp` command), so it starts false.
        # When started unbound, every store Tools opens is owned by Tools.
        @owns_store = false
        # Short-lived confirmation tokens issued by delete_project(dry_run) →
        # {db_path, issued_at_ms}. A real delete must present a matching, unexpired one.
        @delete_tokens = {} of String => {String, Int64}
      end

      # Bound-only helpers call this after the unbound gate; raises only on internal misuse.
      private def store : Store
        s = @store
        raise "internal: tool invoked without a bound project" unless s
        s
      end

      private def unbound? : Bool
        @store.nil?
      end

      # Re-read the per-project `$KEY` env vars from the store into the process
      # global (Settings.project_env_vars). Cheap: one settings-row read + a JSON
      # parse (Env.load_project). No-op when unbound. The parsed Array is assigned
      # synchronously within `call` (no fiber yield between read and assign), so an
      # in-flight async job fiber — which already expanded its template at build
      # time and does not re-read env during the run — never sees a torn value.
      private def refresh_project_env : Nil
        return unless s = @store
        Env.load_project(s)
        # RELOAD the existing table rather than replacing it: an extract rule may have been
        # added by the TUI or `gori run` since the last call, but the VALUES this process
        # observed are its own and must survive the refresh.
        @bindings.try(&.reload)
      end

      # Install this project's network overrides (#538) — the third caller of the loader the
      # TUI's `Session.open` and the CLI's `open_store` also use, so `send_request`, `fuzz_start`
      # and friends dial through a project's pinned upstream on its timeouts instead of the
      # global ones. `bind: false`: the MCP server never opens a listening socket (OAST polls a
      # remote collector, it does not listen), so the two bind keys do not apply here.
      #
      # Bind time only, like `bind_binding_layer` and unlike `refresh_project_env`. Env vars
      # need the per-call reload because MCP itself read-modify-WRITES them; nothing on this
      # surface writes a network override, so the only staleness window is a TUI edit made
      # after the server bound — one `switch_project` away from being picked up.
      private def bind_project_network(s : Store) : Nil
        Settings.load_project_network(s, bind: false)
      end

      # Publish this project's extract rules as `Env`'s send-time layer. Same per-project
      # global the TUI's `Session.open` and the CLI's `open_store` install, so `$SESSION`
      # means one thing on all three surfaces.
      private def bind_binding_layer(s : Store) : Nil
        b = Gori::Bindings.load(s, Gori::SessionSlots.load(s))
        @bindings = b
        Env.layer = b
      end

      # Tools that work with no project store open.
      UNBOUND_SAFE = Set{
        "list_projects", "create_project", "switch_project", "delete_project",
        "project_info",
        "decode", "jwt_decode", "jwt_encode", "jwt_attacks",
        "cookie_decode", "cookie_verify", "cookie_crack", "cookie_forge",
        "sequence_analyze", "ql_reference", "ql_explain",
        "oast_presets", "oast_start", "oast_poll", "oast_payload", "oast_stop",
      }

      # Unbound because the START-UP bind FAILED reads differently from unbound by design:
      # naming the failure here is the only place an agent (which never sees our stderr)
      # can learn that its configured project is broken rather than merely unselected —
      # and the recovery is the same one sentence either way.
      private def no_project : Result
        if reason = @bind_error
          return err("no project bound — the configured project could not be opened: #{reason}. " \
                     "Call list_projects, then switch_project (or create_project) to continue.",
            "NO_PROJECT")
        end
        err("no project bound; call list_projects, create_project, or switch_project first",
          "NO_PROJECT")
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
        # Refused before the socket — see `Fuzz::Backend#blocked`. Tracked separately from
        # `errors` because a caller cannot act on a number that mixes "the target timed out"
        # with "gori never sent this".
        property blocked = 0_i64
        property blocked_reason : String? = nil
        # Requests that left a STALE gRPC length prefix, out of those scanned (see
        # `Fuzz::Progress#grpc_stale`). Zero for every non-gRPC run, and fuzz_status omits the
        # fields entirely then.
        property grpc_stale = 0_i64
        property grpc_requests = 0_i64
        property grpc_stale_reason : String? = nil
        # Whether the run asked for `reframe_grpc` — read only to word `grpc_stale_prefix_reason`,
        # since the remedy an agent should act on differs by whether it already passed it.
        property? reframe_grpc = false
        property error_msg : String? = nil
        # How many times the drain / history-record rescues have fired for this job. Those
        # rescues log, and they sit on the per-EVENT path: a persistent failure (a broken
        # store, a full disk) fires once per result, so an unbounded log would write one
        # stderr line per request sent. An MCP client that does not drain stderr fills the
        # 64 KB pipe, `Log` then blocks the job fiber, every fuzz worker parks on
        # `@events.send`, and the job wedges at `:running` — which also blocks
        # `switch_project`/`delete_project` for the rest of the session. Callers still see
        # the true count in `error_msg`; only the LOGGING is capped (see LOG_CAP).
        property drain_errors = 0
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

        getter db_path : String?

        def initialize(@id : String, @total : Int64?, @engine : Fuzz::Engine,
                       @record_history : Symbol, @origin : Fuzz::Origin, @http2 : Bool,
                       @audit : JobAudit, @db_path : String? = nil)
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

        getter db_path : String?
        # The run's engine. Exposed for its two PURE reporting queries (`skipped_names` /
        # `candidate_names`), which are derived from the loaded wordlist and the config's
        # locations and so are safe to read from the status fiber while the run is live.
        getter engine

        def initialize(@id : String, @total : Int64, @engine : Miner::Engine, @audit : JobAudit,
                       @db_path : String? = nil)
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

        getter db_path : String?

        def initialize(@id : String, @goal : Int32, @engine : Sequencer::Engine, @audit : JobAudit,
                       @db_path : String? = nil)
        end

        def report : Sequencer::Stats::Report
          Sequencer::Stats.analyze(@tokens)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @engine.stop
        end
      end

      # An async access-control run tracked for the authorize_* tools.
      #
      # Unlike its four siblings this job holds a `Plan` rather than an engine: the Authorize
      # seam's `Plan#run` IS the send loop (it polls `stop` between requests and hands the same
      # proc to the engine so it is polled between identities too), so the fiber has nothing to
      # drive but the accumulation below. `stop` is therefore a FLAG this job owns rather than
      # a call into an engine — the plan is a struct and the loop reads the proc.
      class AuthorizeJob
        getter id : String
        getter plan : Authorize::Plan
        property status : Symbol = :running # :running | :done | :stopped | :error
        # Requests whose FULL identity set was replayed. A request the stop cut short mid-set
        # yields no Target at all (see `Authorize::Engine#run`), so it is never counted here —
        # claiming "enforced" from identities that were never sent is worse than a false
        # positive.
        property replayed = 0
        property sent = 0 # individual requests (one per identity per replayed request)
        property errors = 0
        # Sends the outbound gate refused before the socket (Sandbox / an EXCLUDE rule).
        property blocked = 0_i64
        property blocked_reason : String? = nil
        # Requests where NOTHING reached the origin. Tracked because a run that was entirely
        # refused otherwise reports as "no identity matched the baseline" — a clean bill of
        # health for traffic that never left.
        property fully_blocked = 0
        # Non-baseline identities served the same response as the baseline: the finding.
        property bypasses = 0
        property reviews = 0
        property error_msg : String? = nil
        getter results = [] of Authorize::Target
        property? truncated = false
        property ended_at_ms : Int64? = nil
        property stop_requested_at_ms : Int64? = nil
        property? stop_requested = false
        getter audit : JobAudit

        getter db_path : String?

        def initialize(@id : String, @plan : Authorize::Plan, @audit : JobAudit,
                       @db_path : String? = nil)
        end

        # The selection's size, snapshotted from the plan so a status read never walks it.
        def planned : Int32
          @plan.targets.size
        end

        def sends_planned : Int32
          @plan.total_sends
        end

        def skipped : Array(Authorize::Skipped)
          @plan.skipped
        end

        def identities : Array(String)
          @plan.identities.map(&.name)
        end

        def baseline_identity : String?
          @plan.identities.find(&.baseline?).try(&.name)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @stop_requested = true
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
        # Findings waiting to be written as flows. The TUI has always batched these
        # (`DiscoverController#queue_persist`); MCP wrote one transaction per finding, and
        # every one of those blocks the drain fiber on the store writer's reply — which
        # back-pressures the engine's 256-slot event channel and stalls every crawl worker.
        getter persist_buf = [] of {Store::CapturedRequest, Store::CapturedResponse?}
        property persist_at : Time::Instant = Time.instant # last flush; see DISCOVER_PERSIST_INTERVAL
        property? truncated = false
        property ended_at_ms : Int64? = nil
        property stop_requested_at_ms : Int64? = nil
        getter audit : JobAudit

        getter db_path : String?

        def initialize(@id : String, @engine : Discover::Engine, @audit : JobAudit,
                       @db_path : String? = nil)
        end

        def stop : Nil
          @stop_requested_at_ms ||= Time.utc.to_unix_ms
          @engine.stop
        end
      end

      # Argument names a call passed that the tool does not declare.
      #
      # Silently ignoring these was not neutral: a mistyped `verbatm:true` left `verbatim`
      # off, so gori promoted a bare LF to CRLF and answered `isError:false` — the caller
      # measured a target's handling of a request it never sent. `add_scope_rule{"match":…}`
      # stored the default `host` type and reported success. For an AI-driven surface, where
      # the caller cannot see the wire, a typo has to be an error.
      #
      # Keys starting with `_` are exempt: `_meta` is JSON-RPC's own envelope extension and
      # some clients attach it to every call.
      private def unknown_args(name : String, h) : Array(String)?
        allowed = declared_args[name]?
        return nil unless allowed
        h.keys.reject { |k| allowed.includes?(k) || k.starts_with?('_') }
      end

      # tool name → declared property names, harvested from `list` itself so the validator
      # cannot drift from the advertised schema (a hand-maintained second list would).
      # Built once per process, on the first call that needs it.
      private def declared_args : Hash(String, Set(String))
        @declared_args ||= begin
          map = {} of String => Set(String)
          JSON.parse(JSON.build { |j| list(j) }).as_a.each do |t|
            next unless tname = t["name"]?.try(&.as_s?)
            props = t.dig?("inputSchema", "properties").try(&.as_h?)
            map[tname] = (props ? props.keys.to_set : Set(String).new)
          end
          map
        end
      end

      @declared_args : Hash(String, Set(String))? = nil

      # Emits the tools/list array. Every schema lives in its own domain file next to the
      # handler it describes (`tools/*.cr`, one `list_*_tools` each) — this method is only
      # the running order. It used to hold all 131 declarations inline, at which point it
      # was a 1,300-line method and the single biggest merge-conflict surface in the tree.
      def list(j : JSON::Builder) : Nil
        j.array do
          list_flows_tools j
          list_intercept_tools j
          list_ql_tools j
          list_compare_tools j
          list_sitemap_tools j
          list_issues_tools j
          list_probe_tools j
          list_oast_providers_tools j
          list_oast_sessions_tools j
          list_links_tools j
          list_context_tools j
          list_env_tools j
          list_host_overrides_tools j
          list_session_slots_tools j
          list_notes_tools j
          list_decode_tools j
          list_cookie_tools j
          list_sequence_tools j
          list_rules_tools j
          list_color_rules_tools j
          list_projects_tools j
          list_scope_tools j
          list_import_tools j
          list_send_tools j
          list_repeater_tools j
          list_minimize_tools j
          list_fuzz_tools j
          list_mine_tools j
          list_discover_tools j
          list_authorize_tools j
          list_jobs_tools j
        end
      end

      # Dispatches a tools/call by name. Any store/repeater exception is converted to
      # an is_error Result so one bad call never tears down the server loop.
      def call(name : String, args : JSON::Any) : Result
        h = args.as_h? || EMPTY_HASH
        if unbound? && !UNBOUND_SAFE.includes?(name)
          return no_project
        end
        # R2-3: pick up a mid-session CLI env change before an active tool expands
        # `$KEY`. After the unbound gate (@store is bound for these tools) and before
        # dispatch; runs inside this method's rescue, so a store read error becomes an
        # INTERNAL result rather than crashing the loop.
        refresh_project_env if ENV_REFRESH_TOOLS.includes?(name)
        if (bad = unknown_args(name, h)) && !bad.empty?
          return err("unknown argument#{bad.size > 1 ? "s" : ""} for '#{name}': #{bad.join(", ")}. " \
                     "Accepted: #{declared_args[name].to_a.sort.join(", ")}",
            "INVALID_ARGUMENT", field: bad.first)
        end
        result = read_tool(name, h) || action_tool(name, h) ||
                 err("unknown tool: #{name}", "UNKNOWN_TOOL")
        result = classify(result)
        log_agent_action(name, result) if @allow_actions && agent_action?(name, h)
        result
      rescue ex : Gori::Error
        # `Gori::Error` is caller-facing by convention across this codebase — every argument
        # validator (`bool_arg`, `bounded_int_arg`, `base64_str`, the WS frame parser) raises
        # it with a sentence naming the field. Letting the blanket rescue below code it
        # INTERNAL told an agent's error policy "the server is broken, back off / escalate"
        # for a mistake in its own call, and buried the sentence under a `tool error:` prefix
        # that made it read like a crash. The identical class of mistake reported through the
        # typed path (`err(…, "INVALID_ARGUMENT")`) has always come back correctly.
        err(ex.message || "invalid arguments for '#{name}'", "INVALID_ARGUMENT")
      rescue ex
        Log.warn(exception: ex) { "tool #{name} failed" }
        err("tool error: #{ex.message}", "INTERNAL")
      end

      # Whether this CALL (not just this tool) is an agent action worth recording. Most are a
      # flat name lookup, but `probe_scan` is a READ tool whose active:true mode SENDS real
      # requests — the argument, not the name, decides. Logging every passive rescan would
      # bury the outbound ones it exists to surface.
      private def agent_action?(name : String, h) : Bool
        return true if AGENT_ACTION_TOOLS.includes?(name)
        name == "probe_scan" && bool_arg(h, "active", false)
      end

      # #124 — record a completed agent mutation/send into the store event feed so the AI's
      # activity is visible to the human (and tailable via list_events). A failure is logged
      # too (warn) — a scope-blocked or errored send is exactly what an operator wants to see.
      # A read-only-disabled attempt (TOOL_DISABLED) executed nothing, so it is not logged.
      # Best-effort: feed logging never breaks the tool call it describes.
      private def log_agent_action(name : String, result : Result) : Nil
        return if result.error_code == "TOOL_DISABLED"
        return unless s = @store
        level = result.is_error ? "warn" : "info"
        outcome = result.is_error ? "failed (#{result.error_code || "error"})" : "ok"
        s.insert_event("agent", "agent_action", level, "#{name} #{outcome}", payload: name)
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
        # Bound the number of live sessions: each holds an Oast::Http (socket) for the
        # process life until oast_stop, so an agent that never stops them would leak.
        if @oast_mcp.size >= MAX_OAST_SESSIONS
          return Result.new("too many active OAST sessions (#{@oast_mcp.size}/#{MAX_OAST_SESSIONS}); call oast_stop on one before starting another", is_error: true)
        end
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
        # A RESUMED handle is a project listener, so its hits are project evidence: persist
        # them and stamp the liveness signal, exactly as the TUI listener does. An ad-hoc
        # oast_start handle has no row to file them under and stays ephemeral.
        if row = s.store_session_id
          store.touch_oast_session(row)
          fresh.each { |i| Oast::Sessions.record_callback(store, row, i) }
        end
        callbacks = fresh.map { |i| Oast::Present.interaction(i, s.kind_label) }
        Result.new({session_id: sid, count: fresh.size, callbacks: callbacks}.to_json)
      rescue ex
        Result.new("OAST poll failed: #{ex.message}", is_error: true)
      end

      private def oast_stop(h) : Result
        sid = str(h, "session_id")
        s = sid ? @oast_mcp.delete(sid) : nil
        return Result.new("unknown or expired session_id", is_error: true) unless s
        # A RESUMED session is only stopped, never deregistered — the same split the TUI makes
        # between `^X` (stop polling, keep it resumable) and RELEASE. Its payloads are planted
        # out in the world right now, and dropping the server state here would kill them
        # because a poller was closed. `oast_release` is the deliberate teardown.
        if row = s.store_session_id
          return Result.new({stopped: sid, store_session_id: row, registration: "kept"}.to_json)
        end
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
        when "compare_flows"           then compare_flows(h)
        when "list_sitemap"            then list_sitemap(h)
        when "list_issues"             then list_issues(h)
        when "get_issue"               then get_issue(h)
        when "probe_scan"              then probe_scan(h)
        when "probe_issues"            then probe_issues(h)
        when "list_probe_rules"        then list_probe_rules(h)
        when "list_sitemap_tags"       then list_sitemap_tags(h)
        when "list_links"              then list_links(h)
        when "list_oast_providers"     then list_oast_providers(h)
        when "list_oast_sessions"      then list_oast_sessions(h)
        when "list_scope"              then list_scope
        when "list_env"                then list_env(h)
        when "list_host_overrides"     then list_host_overrides
        when "list_session_slots"      then list_session_slots(h)
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
        when "cookie_decode"           then cookie_decode_tool(h)
        when "cookie_verify"           then cookie_verify_tool(h)
        when "cookie_crack"            then cookie_crack_tool(h)
        when "cookie_forge"            then cookie_forge_tool(h)
        when "sequence_analyze"        then sequence_analyze(h)
        when "list_rules"              then list_rules(h)
        when "list_color_rules"        then list_color_rules(h)
        when "preview_color_rule"      then preview_color_rule(h)
        when "list_custom_colors"      then list_custom_colors
        when "list_extract_rules"      then list_extract_rules
        when "list_projects"           then list_projects
        when "ql_explain"              then ql_explain(h)
        end
      end

      # Action + write tools. Project selection (switch always; create when unbound
      # or when actions allowed) is not fully blocked by --read-only so install-and-use
      # works on a fresh machine. nil when `name` isn't one of them.
      private def action_tool(name : String, h) : Result?
        case name
        when "send_request"              then gated { send_request(h) }
        when "send_websocket"            then gated { send_websocket(h) }
        when "oast_start"                then gated { oast_start(h) }
        when "oast_stop"                 then gated { oast_stop(h) }
        when "oast_resume"               then gated { oast_resume(h) }
        when "oast_release"              then gated { oast_release(h) }
        when "intercept_forward"         then gated { intercept_forward(h) }
        when "intercept_drop"            then gated { intercept_drop(h) }
        when "intercept_forward_edit"    then gated { intercept_forward_edit(h) }
        when "intercept_toggle"          then gated { intercept_toggle(h) }
        when "intercept_set_filter"      then gated { intercept_set_filter(h) }
        when "intercept_set_direction"   then gated { intercept_set_direction(h) }
        when "add_scope_rule"            then gated { add_scope_rule(h) }
        when "delete_scope_rule"         then gated { delete_scope_rule(h) }
        when "set_scope_enabled"         then gated { set_scope_enabled(h) }
        when "set_sandbox"               then gated { set_sandbox(h) }
        when "set_env_var"               then gated { set_env_var(h) }
        when "delete_env_var"            then gated { delete_env_var(h) }
        when "create_session_slot"       then gated { create_session_slot(h) }
        when "update_session_slot"       then gated { update_session_slot(h) }
        when "delete_session_slot"       then gated { delete_session_slot(h) }
        when "set_active_session_slot"   then gated { set_active_session_slot(h) }
        when "add_host_override"         then gated { add_host_override(h) }
        when "update_host_override"      then gated { update_host_override(h) }
        when "delete_host_override"      then gated { delete_host_override(h) }
        when "import_flows"              then gated { import_flows(h) }
        when "create_repeater"           then gated { create_repeater(h) }
        when "update_repeater"           then gated { update_repeater(h) }
        when "delete_repeater"           then gated { delete_repeater(h) }
        when "create_issue"              then gated { create_issue(h) }
        when "update_issue"              then gated { update_issue(h) }
        when "probe_dismiss"             then gated { probe_dismiss(h) }
        when "probe_promote"             then gated { probe_promote(h) }
        when "probe_delete"              then gated { probe_delete(h) }
        when "set_probe_rule_enabled"    then gated { set_probe_rule_enabled(h) }
        when "create_probe_rule"         then gated { create_probe_rule(h) }
        when "update_probe_rule"         then gated { update_probe_rule(h) }
        when "delete_probe_rule"         then gated { delete_probe_rule(h) }
        when "set_probe_mode"            then gated { set_probe_mode(h) }
        when "delete_issue"              then gated { delete_issue(h) }
        when "update_scope_rule"         then gated { update_scope_rule(h) }
        when "set_sitemap_tag"           then gated { set_sitemap_tag(h) }
        when "delete_flow"               then gated { delete_flow(h) }
        when "clear_history"             then gated { clear_history(h) }
        when "add_link"                  then gated { add_entity_link(h) }
        when "remove_link"               then gated { remove_entity_link(h) }
        when "create_oast_provider"      then gated { create_oast_provider(h) }
        when "update_oast_provider"      then gated { update_oast_provider(h) }
        when "set_oast_provider_enabled" then gated { set_oast_provider_enabled(h) }
        when "delete_oast_provider"      then gated { delete_oast_provider(h) }
        when "minimize_repeater"         then gated { minimize_repeater(h) }
        when "fuzz_start"                then gated { fuzz_start(h) }
        when "fuzz_status"               then gated { fuzz_status(h) }
        when "fuzz_results"              then gated { fuzz_results(h) }
        when "fuzz_stop"                 then gated { fuzz_stop(h) }
        when "mine_start"                then gated { mine_start(h) }
        when "mine_status"               then gated { mine_status(h) }
        when "mine_results"              then gated { mine_results(h) }
        when "mine_stop"                 then gated { mine_stop(h) }
        when "sequence_start"            then gated { sequence_start(h) }
        when "sequence_status"           then gated { sequence_status(h) }
        when "sequence_results"          then gated { sequence_results(h) }
        when "sequence_stop"             then gated { sequence_stop(h) }
        when "discover_start"            then gated { discover_start(h) }
        when "discover_status"           then gated { discover_status(h) }
        when "discover_results"          then gated { discover_results(h) }
        when "discover_stop"             then gated { discover_stop(h) }
        when "authorize_start"           then gated { authorize_start(h) }
        when "authorize_status"          then gated { authorize_status(h) }
        when "authorize_results"         then gated { authorize_results(h) }
        when "authorize_stop"            then gated { authorize_stop(h) }
        when "list_jobs"                 then gated { list_jobs }
        when "get_job"                   then gated { get_job(h) }
        when "stop_job"                  then gated { stop_job(h) }
        when "create_note"               then gated { create_note(h) }
        when "update_note"               then gated { update_note(h) }
        when "delete_note"               then gated { delete_note(h) }
        when "create_rule"               then gated { create_rule(h) }
        when "update_rule"               then gated { update_rule(h) }
        when "preview_rule"              then gated { preview_rule(h) }
        when "set_rule_enabled"          then gated { set_rule_enabled(h) }
        when "create_extract_rule"       then gated { create_extract_rule(h) }
        when "update_extract_rule"       then gated { update_extract_rule(h) }
        when "delete_extract_rule"       then gated { delete_extract_rule(h) }
        when "set_extract_rule_enabled"  then gated { set_extract_rule_enabled(h) }
        when "delete_rule"               then gated { delete_rule(h) }
        when "create_color_rule"         then gated { create_color_rule(h) }
        when "update_color_rule"         then gated { update_color_rule(h) }
        when "set_color_rule_enabled"    then gated { set_color_rule_enabled(h) }
        when "move_color_rule"           then gated { move_color_rule(h) }
        when "delete_color_rule"         then gated { delete_color_rule(h) }
        when "create_custom_color"       then gated { create_custom_color(h) }
        when "update_custom_color"       then gated { update_custom_color(h) }
        when "delete_custom_color"       then gated { delete_custom_color(h) }
          # switch is always available (selecting a DB is not a data mutation).
        when "switch_project" then switch_project(h)
          # create when unbound even under --read-only; once bound, actions-gated.
        when "create_project" then create_project_entry(h)
        when "delete_project" then gated { delete_project(h) }
        end
      end

      private def create_project_entry(h) : Result
        return create_project(h) if unbound? || @allow_actions
        err("tool disabled (gori mcp --read-only)", "TOOL_DISABLED")
      end

      # Resolve body_mode (none|preview|full) + max_body_bytes into an inlined-body
      # {cap_bytes, omit} pair. none → metadata only; preview → small cap; full
      # (default) → the full MAX_TEXT cap. max_body_bytes tunes the cap (clamped to
      # MAX_TEXT — larger bodies are paged with get_response_body_chunk).
      private def body_return_opts(h) : {Int32, Bool}
        # Only a POSITIVE max_body_bytes overrides the cap; 0/negative falls back to
        # the mode default (Crystal treats 0 as truthy, so `max || default` alone
        # wouldn't). Use body_mode:none for a zero-byte, shape-only body.
        raw = optional_int_arg(h, "max_body_bytes").try(&.clamp(0_i64, Serialize::MAX_TEXT.to_i64).to_i)
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

      # Split a wire-form request into head + body for the History row.
      #
      # This used to scan for `\r\n\r\n` ONLY and RAISE when it found none — which made
      # `record_history` (default true) refuse the whole send, so a bare-LF-terminated
      # request never reached a socket at all. That is the canonical payload `verbatim:true`
      # exists to deliver, and the error named History while naming no way out. Recording is
      # bookkeeping; it must never decide whether a request is sendable.
      #
      # `Env.head_body_boundary` is the shared answer: first of `\n\n` or `\r\n\r\n`,
      # whichever comes earlier, and `bytes.size` when there is no terminator — in which
      # case the whole message is the head, rather than a split landing inside the body.
      private def split_wire_request(bytes : Bytes) : {Bytes, Bytes?}
        boundary = Env.head_body_boundary(bytes)
        head = bytes[0, boundary]
        body_size = bytes.size - boundary
        body = body_size > 0 ? bytes[boundary, body_size] : nil
        {head, body}
      end

      # Evict the OLDEST terminal (non-:running) jobs from `jobs` so it never grows past
      # MAX_JOBS_RETAINED across a long session. Insertion order (Hash preserves it) is
      # age order, so the first removable entries are the oldest. :running jobs are kept
      # (a fiber still writes them and a poller may still read them) even past the cap.
      # Called by each *_start just before it inserts the new job.
      private def evict_finished_jobs(jobs : Hash(String, T)) : Nil forall T
        return if jobs.size < MAX_JOBS_RETAINED
        overflow = jobs.size - MAX_JOBS_RETAINED + 1 # +1 to make room for the incoming job
        # Collect victims first, then delete — mutating a Hash mid-iteration is unsafe.
        victims = [] of String
        jobs.each do |key, job|
          break if victims.size >= overflow
          victims << key if job.status != :running
        end
        victims.each { |k| jobs.delete(k) }
      end

      # A job's buffered results — and above all the History `flow_id`s recorded alongside
      # them — only mean anything against the project it ran in. `jobs_running?` stops a
      # switch mid-run, but a FINISHED job outlives one, and after the rebind those ids
      # resolve to unrelated rows in the NEW database. Refuse the read instead of handing
      # back evidence pointers that silently changed meaning; the results are kept, so
      # switching back makes them readable again.
      private def job_project_mismatch(job : FuzzJob | MineJob | SequenceJob | DiscoverJob | AuthorizeJob) : Result?
        return nil if job.db_path == @db_path
        err("job #{job.id} ran against a different project (#{job.db_path || "unknown"}); " \
            "switch back to that project to read its results",
          "PROJECT_CHANGED", details: JSON.parse({"job_db_path" => job.db_path, "current_db_path" => @db_path}.to_json))
      end

      # A background job's fiber must never exit with the job still :running — that
      # hangs every poller and permanently trips jobs_running?. Land it terminal.
      private def finalize_job(job : FuzzJob | MineJob | SequenceJob | DiscoverJob | AuthorizeJob) : Nil
        if job.status == :running
          job.status = :error
          job.error_msg ||= "job ended without a terminal event"
        end
        job.ended_at_ms ||= Time.utc.to_unix_ms
      end

      # Terminal status for a finished fuzz/mine/discover job. A non-stopped Done whose
      # processed count fell short of the known candidate `total` means the request
      # budget (max_requests) halted the run early — reported as :budget_exhausted
      # so a partial "0 found" is not read as an exhaustive result. A prior :error
      # is preserved (a generation ErrorEvent then a Done must stay failed).
      #
      # `declared` is for an engine that says so ITSELF rather than letting a consumer derive
      # it. Discover is that engine: it has no stable candidate denominator (`est_total` is a
      # moving estimate of a live crawl), so `Discover::DoneEvent#budget_exhausted` is the
      # authority and MCP must not re-infer the answer. It used to infer `queued > 0`, which
      # misses the half the engine's own predicate exists for — a Calibrate task whose probes
      # were ALL refused consumes no frontier entry, so the frontier drains to empty with real
      # work skipped and the run came back `status:"done", job_complete:true, has_more:false`.
      private def terminal_status(current : Symbol, stopped : Bool, done_count : Int64, total : Int64?,
                                  declared : Bool = false) : Symbol
        return :error if current == :error
        return :stopped if stopped
        return :budget_exhausted if declared
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
            # `Serialize.text`, matching what all four `list_jobs` rows already do with this
            # exact value (`tools/jobs.cr`) — it was raw only here. For fuzz/mine/sequence the
            # target is `"#{scheme}://#{host}:#{port}"` built from the plan's origin, and a
            # flow-seeded job takes that host off a capture: `flows.host` round-trips a byte
            # above 0x7F (nothing rejects it — `Import::Builder::HOST_INVALID` covers only
            # `[\x00-\x20\x7f]`) and `FlowRequest.parse_target` passes it through, so
            # `fuzz_status` could put invalid UTF-8 on the wire while `list_jobs` for the same
            # job stayed clean. This surface is stdio JSON-RPC, where that is a transport-level
            # protocol violation rather than a display glitch (see `Serialize.issue`).
            j.field "target", Serialize.text(a.target)
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

      private def fuzz_timeout(h) : Time::Span?
        optional_int_arg(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds)
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
        j.field "effective_host", Serialize.text(sc.host)
      end

      # A string-shaped argument, held to the same "lenient, but never SILENT" contract every
      # other primitive on this surface already has.
      #
      # `h[key]?.try(&.as_s?)` alone answered nil for EVERY non-string shape, and each of the
      # ~180 callers reads a nil as "the caller did not pass it". So a mistyped argument was
      # accepted, checked against nothing, and discarded: `add_scope_rule{pattern: 8080}` came
      # back "missing required 'pattern'" for a value it had just been handed, and
      # `create_note{text: [1,2]}` stored an EMPTY note and reported success. The same nil
      # reaching a tool with a documented default silently ran the default instead — the
      # failure `bool_value` describes for `probe_scan{active: 1}`, spent on a string.
      #
      # A JSON scalar is COERCED, matching `header_pairs`' `v.as_s? || v.to_s` for header
      # values and `int`'s acceptance of a numeric string: an unquoted `8080` in a string slot
      # says one thing only. An array/object is REFUSED BY NAME — `JSON::Any#to_s` renders a
      # Hash in CRYSTAL syntax (`{"a" => 1}`, not JSON), so coercing one would put text the
      # caller never wrote into the store or onto the wire, which is worse than the drop. A
      # JSON null stays ABSENT, which is what `present?` already means everywhere else.
      #
      # Raising is safe at every call site: `call` rescues `Gori::Error` into a clean
      # INVALID_ARGUMENT. The one argument read BOTH ways — `ws_out_messages`, string or
      # array — tries its array branch first, so only the object shape reaches here, and
      # refusing that is the point (it used to store zero frames).
      private def str(h, key : String) : String?
        v = h[key]?
        return nil if v.nil? || v.raw.nil?
        if s = v.as_s?
          return s
        end
        if shape = container_shape(v)
          raise Gori::Error.new("invalid '#{key}' (expected a string, got #{shape})")
        end
        v.to_s
      end

      # A string argument that is NOT coerced: only a genuine JSON string will do. For the
      # `*_base64` arguments, whose whole contract is "these exact octets" — `base64_str`
      # answered nil for a non-string, so `base64_str(h, "request_base64") || str(h, "request")`
      # silently stored the NON-byte-exact request and reported success. Coercing would be
      # worse than the drop here: `1234` would `to_s` into a string that DECODES (3 octets),
      # so gori would send bytes the caller never named at all.
      #
      # `expected` words the refusal, because this reader also guards the arguments that ARE
      # the wire message (`body`, `raw`) rather than a base64 envelope for one — the same split
      # `RequestBuilder.wire_str` makes, and the reason it exists: a body handed over as an
      # object has no defensible serialization, so guessing at one invents a Content-Length
      # the caller never stated.
      private def strict_str(h, key : String, expected : String = "a base64 string") : String?
        v = h[key]?
        return nil if v.nil? || v.raw.nil?
        v.as_s? || raise Gori::Error.new("invalid '#{key}' (expected #{expected})")
      end

      # "an array" / "an object", or nil for a scalar — the shapes `str` must refuse.
      private def container_shape(v : JSON::Any) : String?
        return "an array" if v.as_a?
        return "an object" if v.as_h?
        nil
      end

      # One entry of a string LIST, under `str`'s rule: a scalar is coerced, a container is
      # refused by name. `arr.compact_map(&.as_s?)` silently DROPPED the entry instead, so
      # `cookie_crack{secrets:["nope",12345]}` tried 1 of the 2 candidates and answered
      # `found:false` — a false negative with `isError:false` — and `sequence_analyze` rated
      # the randomness of a sample two thirds the size of the one submitted. Same fix, same
      # reason as `ws_out_messages_arg`'s (its `compact_map` stored 2 of 4 frames and called
      # it a clean send).
      private def str_entry(v : JSON::Any, key : String) : String
        if s = v.as_s?
          return s
        end
        if (shape = container_shape(v)) || v.raw.nil?
          raise Gori::Error.new("invalid '#{key}' entry #{v.to_json} (expected a string, got #{shape || "null"})")
        end
        v.to_s
      end

      # A list-of-strings argument in any shape a client sends: a real array, a JSON-ENCODED
      # array (LLM clients stringify — `fuzz_marks` accepts the same two), or a BARE string as
      # a one-element list, which is what a caller with a single secret reaches for and which
      # used to become an empty list and an error naming the argument it had just supplied.
      # Anything else is refused rather than silently emptied.
      private def str_list(h, key : String) : Array(String)
        raw = h[key]?
        return [] of String if raw.nil? || raw.raw.nil?
        if s = raw.as_s?
          return [] of String if s.strip.empty?
          if s.lstrip.starts_with?('[') && (parsed = (JSON.parse(s) rescue nil)) && (arr = parsed.as_a?)
            return arr.map { |v| str_entry(v, key) }
          end
          return [s]
        end
        # A bare SCALAR is one candidate, exactly as a bare string is: `secrets: 12345` is a
        # single numeric secret, which is the same shape as the numeric ENTRY this reader was
        # fixed to stop dropping. Only a container in a list slot has no reading, and
        # `str_entry` is what says so — naming the shape actually sent, rather than telling a
        # caller who wrote a number that it passed an object.
        arr = raw.as_a? || return [str_entry(raw, key)]
        arr.map { |v| str_entry(v, key) }
      end

      # A `*_base64` argument decoded into the exact bytes it names, as a String (Crystal
      # Strings are byte buffers, so an invalid-UTF-8 payload survives to the store and the
      # wire — every path that has to RENDER it scrubs at the projection instead).
      #
      # JSON-RPC arguments are UTF-8 text, so a `request`/`body` string is put on the wire as
      # its UTF-8 ENCODING: `é` leaves as `\xc3\xa9`. That made latin-1 payloads, invalid-UTF-8
      # traversal bypasses and binary bodies inexpressible from MCP. Invalid base64 raises
      # rather than falling back: a caller reaching for this argument wants exact bytes, and
      # silently sending different ones is the failure it came here to avoid.
      private def base64_str(h, key : String) : String?
        s = strict_str(h, key)
        return nil if s.nil? || s.empty?
        begin
          String.new(Base64.decode(s))
        rescue
          raise Gori::Error.new("'#{key}' is not valid base64")
        end
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

      # One sentence for every MCP tool whose builder refused an env token that resolves to
      # nothing (#519). Shared rather than written per tool because, unlike the other plan
      # reasons, this one names no argument of the tool's own — the token is the whole fact
      # and the remedy is the same everywhere. Naming `set_env_var` matters more here than
      # on the other surfaces: an agent cannot see the token highlighted the way the TUI
      # operator can, so the message has to carry both the name and the way to fix it.
      # `detail` is the builder's prefixed, comma-joined token list (`$SESSION, $TOKEN`).
      private def env_unresolved_error(detail : String?) : String
        "unresolved env #{detail} — set it with the set_env_var tool, or remove the token"
      end

      # Coerce a JSON arg to Int64. Accepts a JSON integer, an INTEGRAL float
      # (100.0 → 100; many encoders emit ints as floats), and a numeric STRING
      # ("5" → 5) — clients/LLMs often serialize tool args as strings and the
      # schema's "integer" type is advisory, not enforced. A fractional float
      # (5.9) is rejected rather than silently truncated, so the number and
      # string encodings of the same value agree.
      #
      # A number OUTSIDE Int64 SATURATES to the nearest bound rather than answering nil.
      # `1e19` is the "no limit" value an LLM reaches for and its intent is unambiguous, so it
      # has to reach the caller's own `clamp` — answering nil fell back to a DEFAULT smaller
      # than any value the caller could have meant, and it made this reader's two halves
      # disagree, because `optional_int_arg` refuses a nil-while-present BY NAME and would
      # have turned a legal-but-huge number into an argument error. Saturating leaves nil
      # meaning exactly one thing: the value has no numeric reading at all.
      private def int(h, key : String) : Int64?
        v = h[key]?
        return nil unless v
        if i = v.as_i64?
          return i
        end
        if f = v.as_f?
          return nil unless f.finite? && f == f.trunc
          return Int64::MAX if f >= Int64::MAX.to_f64
          return Int64::MIN if f < Int64::MIN.to_f64
          return f.to_i64
        end
        s = v.as_s?
        return nil unless s
        s.to_i64? || saturated_digits(s)
      rescue OverflowError
        nil
      end

      # A digit run too large for Int64, saturated — the string encoding of the same
      # "as large as possible" the float branch above accepts. nil for anything that is not
      # a bare signed digit run, so `"fast"` / `"30s"` stay unreadable.
      private def saturated_digits(s : String) : Int64?
        t = s.strip
        negative = t.starts_with?('-')
        digits = t.lchop('-').lchop('+')
        return nil if digits.empty? || !digits.each_char.all?(&.ascii_number?)
        negative ? Int64::MIN : Int64::MAX
      end

      # The integer argument, or nil when absent — but a value that was SUPPLIED and has no
      # numeric reading (a container, `"fast"`, a fractional float) is refused BY NAME. Every
      # non-id integer argument on this surface used to read `int`'s nil as "not passed", so
      # `fuzz_start{rate:"fast", max_requests:{"n":1}}` answered `isError:false` and swept
      # with no rate limit and no request budget. Same contract `bool_arg` states for booleans
      # and `str` for strings: a lenient coercion is fine, a SILENT one is not.
      private def optional_int_arg(h, key : String) : Int64?
        value = int(h, key)
        if present?(h, key) && value.nil?
          raise Gori::Error.new("invalid '#{key}' (expected an integer)")
        end
        value
      end

      # A NUMBER-shaped argument: `rate` is the only one, and it is genuinely fractional.
      # `Config#rps` is a `Float64?` and `gori run fuzz --rate` parses it with `to_f?`, so half
      # a request per second — the pacing a fragile target needs — is expressible on the CLI and
      # in the engine. MCP read it through the integer reader, which first swallowed `0.5`
      # silently (rate unset ⇒ UNLIMITED, the opposite of what was asked) and then, once that
      # became a refusal, made it inexpressible from this surface at all.
      #
      # Same "supplied but unreadable is refused BY NAME" contract as `optional_int_arg`;
      # non-finite is refused too, since `Infinity` is not a rate.
      private def optional_float_arg(h, key : String) : Float64?
        v = h[key]?
        return nil if v.nil? || v.raw.nil?
        f = v.as_f? || v.as_s?.try(&.to_f?)
        raise Gori::Error.new("invalid '#{key}' (expected a number)") if f.nil? || !f.finite?
        f
      end

      private def bounded_int_arg(h, key : String, default : Int64, *, min : Int64,
                                  max : Int64 = Int64::MAX) : Int64
        value = optional_int_arg(h, key) || default
        if value < min
          raise Gori::Error.new("invalid '#{key}' (expected an integer >= #{min})")
        end
        value.clamp(min, max)
      end

      # Coerce ONE already-looked-up JSON value to a boolean, or nil when it is neither.
      #
      # This deliberately takes the VALUE and not `(h, key)`. The old `(h, key)` form invited
      # `bool(h, "x") || false`, which collapses "absent" and "unintelligible" into the same
      # answer — so `probe_scan{active: 1}` ran a PASSIVE scan and reported it as a clean
      # active one, `create_repeater{auto_content_length: 1}` stored the OPPOSITE of the
      # absent-default, and `discover_start{spider: 0}` crawled anyway while slipping past the
      # "at least one technique" guard `spider: false` correctly trips. That shape was fixed
      # twice on three flags and survived on fifteen others, so the shape itself is gone:
      # there is no longer any `(h, key)` boolean reader that can silently fall back.
      # `bool_arg` (absent → a stated default) and `optional_bool_arg` (absent → nil) are the
      # only two, and both NAME the argument when the value is unintelligible.
      private def bool_value(v : JSON::Any?) : Bool?
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

      # The boolean argument, or `default` when the caller did not pass it. Raises on a value
      # that is neither a JSON boolean nor "true"/"false" — a lenient coercion is fine, a
      # SILENT one is not, and the alternative is running a different test than the one asked
      # for. Mirrors `bounded_int_arg`'s contract for integers.
      private def bool_arg(h, key : String, default : Bool) : Bool
        value = optional_bool_arg(h, key)
        value.nil? ? default : value
      end

      # The boolean argument as a THREE-state answer: true / false / nil for absent, for the
      # tools where "not passed" is a distinct outcome (keep the stored value, refuse as a
      # missing required arg, inherit from the seed flow). Unintelligible still raises.
      private def optional_bool_arg(h, key : String) : Bool?
        value = bool_value(h[key]?)
        if present?(h, key) && value.nil?
          raise Gori::Error.new("invalid '#{key}' (expected true or false)")
        end
        value
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

      # For an argument that is genuinely fractional (`rate` — see `optional_float_arg`).
      # Declaring it `integer` while the engine takes a Float64 is how a half-request-per-second
      # pacing came to be inexpressible from this surface.
      private def numprop(desc : String) : JSON::Any
        prop("number", desc)
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

      # `ws_out_messages` / `send_websocket`'s `messages`. A plain string stays a plain TEXT
      # frame and always will: the moment a marker prefix meant something, a payload starting
      # with it would become unsendable, and being able to send the bytes you typed is P0 here.
      # Everything else is opt-in — the object form for a caller building JSON, and the same
      # `key=value` spec `gori run repeater send --message-frame` takes for a caller writing a
      # string. Both exist because opcode 1 / FIN=1 / RSV=0 / masked / honest-length was the
      # ONLY frame this argument could ever produce.
      private def ws_out_messages_prop(desc : String? = nil) : JSON::Any
        d = desc || "outbound WebSocket messages"
        d += ". A plain string (or an array of them, or a newline-separated string) is a " \
             "TEXT frame. For any other frame shape use either an object " \
             "{opcode, text|payload_base64|payload_hex, fin, rsv, mask, mask_key, declared_len} " \
             "or a spec string \"opcode=ping,text=hi\" (fields: opcode=text|bin|cont|close|" \
             "ping|pong|0-15, fin=0|1, rsv=0-7 (RSV1=4), mask=0|1, mask_key=<hex>, " \
             "len=<declared length>, and one of hex=|b64=|text=; text= runs to the end). " \
             "declared_len/len sets the LENGTH HEADER independently of the payload"
        JSON.parse(%({"description":#{d.to_json},"oneOf":) +
                   %([{"type":"array","items":{"oneOf":[{"type":"string"},{"type":"object"}]}},{"type":"string"}]}))
      end

      # The EXACT HPACK field list for a field-native h2 send (`send_request` h2_fields). An
      # array of `[name, value]` two-element string arrays; a leading colon marks a
      # pseudo-header, and NOTHING is normalized — the shapes h1 head text cannot carry (a
      # duplicate/out-of-order/unknown pseudo, a `:scheme` disagreeing with the connection,
      # `:protocol`, a leading-space value) are exactly what this expresses.
      private def h2fieldsprop : JSON::Any
        desc = "field-native HTTP/2: the exact ordered HPACK field list as [name, value] " \
               "pairs, e.g. [[\":method\",\"GET\"],[\":path\",\"/\"],[\":scheme\",\"https\"]," \
               "[\":authority\",\"host\"]]. Sent verbatim — pseudo-headers, duplicates, order, " \
               "case and leading spaces are all preserved. Forces http2; url still sets the " \
               "dial origin. Body via `body` (UTF-8) or `body_base64`."
        JSON.parse(%({"type":"array","description":#{desc.to_json},) +
                   %("items":{"type":"array","items":{"type":"string"},"minItems":2,"maxItems":2}}))
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
