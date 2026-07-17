module Gori
  class Store
    # Lifecycle of a captured flow. Stored as the enum value (INTEGER).
    enum FlowState
      Pending  # request captured, response not yet received
      Complete # response captured
      Error    # upstream/parse/tls failure (captured anyway, P7)
      Aborted  # connection died mid-flow
    end

    # Persist-time DTO produced by a proxy fiber for the request side.
    # `head`/`body` are the byte-exact wire octets (truth, P7); the rest are
    # projections the History list/QL need. Built only by `Gori::FlowMapper`.
    struct CapturedRequest
      getter created_at : Int64 # unix micros
      getter scheme : String
      getter host : String
      getter port : Int32
      getter method : String
      getter target : String
      getter http_version : String
      getter sni : String?
      getter alpn : String?
      getter tls_version : String?
      getter head : Bytes
      getter body : Bytes? # captured body, possibly truncated to the capture cap
      getter? body_truncated : Bool
      getter body_size : Int64? # TRUE wire body size (nil → derive from `body`); ≥ body.size when truncated
      # When this flow is a decoded HTTP/2 stream, links back to its raw frame log.
      getter h2_conn_id : Int64?
      getter h2_stream_id : Int64?

      def initialize(@created_at, @scheme, @host, @port, @method, @target,
                     @http_version, @head, @body = nil,
                     @sni = nil, @alpn = nil, @tls_version = nil,
                     @body_truncated = false, @body_size = nil,
                     @h2_conn_id = nil, @h2_stream_id = nil)
      end
    end

    # Persist-time DTO for the response side, keyed to an existing flow id.
    struct CapturedResponse
      getter flow_id : Int64
      getter status : Int32
      getter reason : String?
      getter content_type : String?
      # Content-Encoding header value (nil = none/identity). Extracted once by the proxy
      # where the response headers are already parsed, so the store writer can decide FTS
      # skipping without re-parsing the raw head per flow.
      getter content_encoding : String?
      getter head : Bytes
      getter body : Bytes? # captured body, possibly truncated to the capture cap
      getter? body_truncated : Bool
      getter body_size : Int64? # TRUE wire body size (nil → derive from `body`)
      getter ttfb_us : Int64?
      getter duration_us : Int64?
      getter state : FlowState
      getter error : String?

      def initialize(@flow_id, @status, @head, @body = nil, @reason = nil,
                     @content_type = nil, @ttfb_us = nil, @duration_us = nil,
                     @state = FlowState::Complete, @error = nil,
                     @body_truncated = false, @body_size = nil, @content_encoding = nil)
      end
    end

    # Read model for the History list — projections only, NO blobs (rows stay
    # light for fast scrolling). `status` is nil while Pending.
    struct FlowRow
      getter id : Int64
      getter created_at : Int64
      getter scheme : String
      getter method : String
      getter host : String
      getter port : Int32
      getter target : String
      getter status : Int32?
      getter size : Int64 # total bytes (request + response) — used by the clipboard copy
      getter state : FlowState
      getter response_size : Int64? # response bytes alone (nil until the response lands)
      getter duration_us : Int64?   # request→response latency in µs (nil until complete)
      getter content_type : String? # response Content-Type header (nil until the response lands)

      def initialize(@id, @created_at, @scheme, @method, @host, @port, @target,
                     @status, @size, @state, @response_size = nil, @duration_us = nil,
                     @content_type = nil)
      end

      # The full absolute URL of the request. Plaintext forward-proxy requests are captured
      # ABSOLUTE-form (`http://host:port/path` — the wire truth, P7), so `target` already
      # carries the scheme+authority; return it verbatim. Origin-form targets (the HTTPS /
      # CONNECT case — a bare "/path") get scheme+host[:port] prefixed, keeping a non-default
      # port and bracketing an IPv6 literal (mirrors FlowRequest.build_target). Prevents the
      # doubled "http://hosthttp://host/path" a naive "#{scheme}://#{host}#{target}" produced.
      def url : String
        return target if target.starts_with?("http://") || target.starts_with?("https://")
        h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        default = scheme == "https" ? 443 : 80
        port == default ? "#{scheme}://#{h}#{target}" : "#{scheme}://#{h}:#{port}#{target}"
      end
    end

    # Full detail incl. truth bytes — loaded lazily when a row is selected.
    struct FlowDetail
      getter row : FlowRow
      getter http_version : String
      getter request_head : Bytes
      getter request_body : Bytes?
      getter response_head : Bytes?
      getter response_body : Bytes?
      getter? request_body_truncated : Bool
      getter? response_body_truncated : Bool
      getter h2_conn_id : Int64?
      getter h2_stream_id : Int64?
      getter error : String? # upstream/parse/tls failure message for Error/Aborted flows (response side is empty)
      getter sni : String?

      def initialize(@row, @http_version, @request_head, @request_body,
                     @response_head, @response_body, @h2_conn_id = nil, @h2_stream_id = nil,
                     @request_body_truncated = false, @response_body_truncated = false, @error = nil, @sni = nil)
      end
    end

    # A captured WebSocket message belonging to a (101) flow. `direction` is
    # "out" (client→server) or "in" (server→client); opcode 1=text, 2=binary.
    struct WsMessage
      getter id : Int64
      getter flow_id : Int64
      getter repeater_id : Int64?
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes

      def initialize(@id, @flow_id, @repeater_id, @created_at, @direction, @opcode, @payload)
      end

      def text? : Bool
        @opcode == 1
      end
    end

    # Severity of an issue (stored as the enum value).
    enum Severity
      Info
      Low
      Medium
      High
      Critical

      def label : String
        to_s.downcase
      end
    end

    # Triage state of an issue, independent of severity (stored as the enum
    # value; V12). Open is the default for a freshly captured issue.
    enum Status
      Open
      Confirmed
      FalsePositive
      Resolved

      def label : String
        case self
        in .open?           then "open"
        in .confirmed?      then "confirmed"
        in .false_positive? then "false-positive"
        in .resolved?       then "resolved"
        end
      end
    end

    # Owner of a row in `entity_links`.
    enum LinkOwnerKind
      Issue
      Note

      def label : String
        to_s.downcase
      end

      def self.parse(s : String) : LinkOwnerKind?
        case s
        when "issue" then Issue
        when "note"    then Note
        else                nil
        end
      end
    end

    # Target workbench entity referenced by an `entity_links` row.
    enum LinkRefKind
      Flow
      Repeater
      Fuzz
      Miner

      def label : String
        to_s.downcase
      end

      def self.parse(s : String) : LinkRefKind?
        case s
        when "flow"   then Flow
        when "repeater" then Repeater
        when "fuzz"   then Fuzz
        when "miner"  then Miner
        else               nil
        end
      end

      # Short tag for the TUI list (e.g. "[hist]").
      def tag : String
        return "hist" if flow?
        return "repeater" if repeater?
        return "fuzz" if fuzz?
        "miner"
      end
    end

    # A link from an Issue or Note to a workbench entity (flow/repeater/fuzz/miner).
    struct EntityLink
      getter id : Int64
      getter owner_kind : LinkOwnerKind
      getter owner_id : Int64
      getter ref_kind : LinkRefKind
      getter ref_id : Int64
      getter created_at : Int64

      def initialize(@id, @owner_kind, @owner_id, @ref_kind, @ref_id, @created_at)
      end
    end

    # A human-confirmed issue (DESIGN.md: the final output). Optionally linked
    # to a captured flow. One per project DB.
    struct Issue
      getter id : Int64
      getter created_at : Int64
      getter updated_at : Int64
      getter title : String
      getter severity : Severity
      getter host : String?
      getter flow_id : Int64?
      getter notes : String
      getter status : Status

      def initialize(@id, @created_at, @updated_at, @title, @severity, @host, @flow_id, @notes,
                     @status = Status::Open)
      end
    end

    # A grouped Probe scan issue (V20): one row per distinct (code, host). Machine-found
    # (by the passive/active analyzer), as opposed to the human-confirmed `Issue`. The
    # affected URLs accumulate in `affected` (capped) while `hit_count` counts every
    # observation; `severity` rises to the max seen. Reuses the shared Severity/Status
    # enums; `status` lets a group be triaged (confirmed / false-positive / resolved) or
    # promoted to an Issue. `category` drives the filter lens and the project tech summary.
    struct ProbeIssue
      getter id : Int64
      getter code : String
      getter category : String
      getter host : String
      getter title : String
      getter severity : Severity
      getter status : Status
      getter hit_count : Int64
      getter affected : Array(String) # distinct affected URLs (parsed from JSON, capped)
      getter sample_flow_id : Int64?  # a representative source flow (may be pruned → nil)
      getter evidence : String?       # short snippet/header value/param name — NEVER a secret value
      getter first_seen : Int64       # unix micros
      getter last_seen : Int64
      getter sample_repeater_id : Int64? # representative Repeater tab when the hit came from Repeater

      def initialize(@id, @code, @category, @host, @title, @severity, @status, @hit_count,
                     @affected, @sample_flow_id, @evidence, @first_seen, @last_seen,
                     @sample_repeater_id = nil)
      end
    end

    # Which side of a flow a Match&Replace rule rewrites. Stored as the lowercase
    # member name ("request"/"response").
    enum RuleTarget
      Request
      Response

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : RuleTarget
        parse(s)
      end
    end

    # Which PART of a message a Match&Replace rule rewrites: the HEAD (request/
    # status line + headers) or the BODY (the entity — de-chunked, but not
    # decompressed). Stored as the lowercase member name ("head"/"body"); pre-body
    # rules migrate to `head` (V30 default), so old rows keep their exact meaning.
    enum RulePart
      Head
      Body

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : RulePart
        parse(s)
      end
    end

    # What a Match&Replace rule DOES. `Replace` is the classic find/replace over the
    # selected PART (head or body). The three header ops act on the HEAD by header NAME
    # (case-insensitive), so a user never has to hand-craft a substring that spans the
    # exact header text: `AddHeader` appends a `Name: value` line, `SetHeader` replaces
    # an existing header's value (or appends when absent), `RemoveHeader` drops every
    # matching header line. Header ops carry the header NAME in `pattern` and the value
    # in `replacement` (empty for `RemoveHeader`). Stored lowercase; default `replace`
    # so every pre-op rule keeps its exact meaning.
    enum RuleOp
      Replace
      AddHeader
      SetHeader
      RemoveHeader

      def label : String
        case self
        in RuleOp::Replace      then "replace"
        in RuleOp::AddHeader    then "add_header"
        in RuleOp::SetHeader    then "set_header"
        in RuleOp::RemoveHeader then "remove_header"
        end
      end

      def self.from_label(s : String) : RuleOp
        case s
        when "add_header"    then AddHeader
        when "set_header"    then SetHeader
        when "remove_header" then RemoveHeader
        else                      Replace
        end
      end

      # A header-name-keyed op (mutates the HEAD by name, not a substring gsub). Header
      # ops are head-only regardless of a rule's `part`.
      def header? : Bool
        !replace?
      end
    end

    # How a `Replace` rule matches: a `Literal` substring or a `Regex` (with $1/\1
    # capture-group interpolation in the replacement). Stored lowercase; default
    # `literal` so pre-regex rules keep their exact meaning. Ignored by header ops.
    enum MatchKind
      Literal
      Regex

      def label : String
        to_s.downcase
      end

      def self.from_label(s : String) : MatchKind
        s == "regex" ? Regex : Literal
      end
    end

    # A Match&Replace rule (the "Rewriter" tab): rewrites a request/response HEAD
    # (request line + headers) or BODY (the entity body) in flight. Human-authored (P4),
    # persisted per project. `op` selects the action (replace / add-set-remove header);
    # for `Replace`, `match_kind` picks literal vs regex and `part` picks head vs body.
    # `replacement` may be empty (delete `pattern` / remove header). `name` is an optional
    # label; `host` is an optional glob that scopes the rule to matching hosts ("" = all).
    # A body rule buffers + re-frames the message in flight (Content-Length synced); a
    # head rule streams the body untouched (P6). See `Rules` / `ClientConn`.
    struct MatchRule
      getter id : Int64
      getter? enabled : Bool
      getter target : RuleTarget
      getter part : RulePart
      getter pattern : String
      getter replacement : String
      getter op : RuleOp
      getter match_kind : MatchKind
      getter name : String
      getter host : String

      def initialize(@id, @enabled, @target, @part, @pattern, @replacement,
                     @op = RuleOp::Replace, @match_kind = MatchKind::Literal,
                     @name = "", @host = "")
      end
    end

    # A per-project user-defined Probe match rule (probe_custom_rules, V38). String/regex match
    # over one region of a captured flow (side × region); `severity` stamps the emitted finding.
    # The global-scope counterpart lives in settings.json (Settings::ScanRule); both fold into the
    # runtime Probe::CustomRule via Probe.custom_rules.
    struct ProbeCustomRule
      getter id : Int64
      getter title : String
      getter description : String
      getter side : String   # "request" | "response"
      getter region : String # "whole" | "header" | "body"
      getter kind : String   # "string" | "regex"
      getter pattern : String
      getter severity : Severity
      getter? enabled : Bool

      def initialize(@id, @title, @description, @side, @region, @kind, @pattern, @severity, @enabled)
      end
    end

    # A persisted Repeater workbench tab: the editable request plus the LAST send
    # response (V11 — head/body/error/duration; all nil until the first send).
    # Shared across sessions on the same project — the TUI reconciles local tabs
    # against these rows by `id` on the data_version poll.
    struct RepeaterRecord
      getter id : Int64
      getter target : String
      getter request : String
      getter? http2 : Bool
      getter? auto_content_length : Bool
      getter flow_id : Int64?
      getter position : Int32
      getter response_head : Bytes?
      getter response_body : Bytes?
      getter response_error : String?
      getter response_duration_us : Int64?
      getter name : String?         # custom sub-tab label (nil = derive from the request)
      getter sni : String?          # custom TLS SNI host (nil = present the target host)
      getter tags : String?         # V31: space-joined flat tags (nil = untagged)

      def initialize(@id, @target, @request, @http2, @auto_content_length, @flow_id, @position,
                     @response_head = nil, @response_body = nil, @response_error = nil,
                     @response_duration_us = nil, @name = nil, @sni = nil,
                     @tags = nil)
      end
    end

    # A persisted Fuzzer/Intruder session: the marked template (with §…§ positions)
    # plus an opaque `config` JSON the TUI owns (mode / payload sets / matchers /
    # engine opts). Mirrors RepeaterRecord — survives reopen and syncs across sessions.
    struct FuzzSessionRecord
      getter id : Int64
      getter target : String
      getter template : String
      getter? http2 : Bool
      getter sni : String?
      getter config : String # opaque JSON managed by the frontend
      getter flow_id : Int64?
      getter position : Int32
      getter name : String? # custom sub-tab label (nil = derive from the request line)

      def initialize(@id, @target, @template, @http2, @sni, @config, @flow_id, @position, @name = nil)
      end
    end

    # One persisted parameter-mining session (a sub-tab under the Miner tab). Stores the
    # byte-exact `request` to re-run, plus opaque `config` JSON (locations, bucket sizes,
    # concurrency) managed by the frontend. Results are NOT persisted (in-memory per
    # session, like Repeater responses before V11).
    struct MinerSessionRecord
      getter id : Int64
      getter target : String
      getter request : Bytes
      getter? http2 : Bool
      getter sni : String?
      getter config : String # opaque JSON managed by the frontend
      getter flow_id : Int64?
      getter position : Int32
      getter name : String? # custom sub-tab label (nil = derive from the request line)

      def initialize(@id, @target, @request, @http2, @sni, @config, @flow_id, @position, @name = nil)
      end
    end

    # A configured OAST provider (the Providers sub-tab). `kind` is the ProviderKind label.
    struct OastProviderRecord
      getter id : Int64
      getter name : String
      getter kind : String
      getter host : String
      getter token : String?
      getter? enabled : Bool
      getter position : Int32

      def initialize(@id, @name, @kind, @host, @token, @enabled, @position)
      end
    end

    # A listening session: the secrets to poll + decrypt. `private_key_pem` is the
    # interactsh RSA private key (nil for other providers).
    struct OastSessionRecord
      getter id : Int64
      getter provider_id : Int64?
      getter kind : String
      getter server_url : String
      getter correlation_id : String
      getter secret : String
      getter private_key_pem : String?
      getter token : String?
      getter last_poll_at : Int64?

      def initialize(@id, @provider_id, @kind, @server_url, @correlation_id, @secret,
                     @private_key_pem, @token, @last_poll_at)
      end
    end

    # One received callback (immutable). `provider_uid` is the dedup key.
    struct OastCallbackRecord
      getter id : Int64
      getter session_id : Int64
      getter created_at : Int64
      getter provider_uid : String
      getter protocol : String
      getter method : String?
      getter source_ip : String?
      getter full_id : String
      getter raw_request : Bytes
      getter raw_response : Bytes?

      def initialize(@id, @session_id, @created_at, @provider_uid, @protocol, @method,
                     @source_ip, @full_id, @raw_request, @raw_response)
      end
    end

    # One persisted token-randomness session (a sub-tab under the Sequencer tab). Stores
    # the byte-exact `request` to re-collect, plus opaque `config` JSON (mode, token
    # location, goal, pacing) managed by the frontend. Collected tokens are NEVER
    # persisted (live secrets, in-memory per session).
    struct SequencerSessionRecord
      getter id : Int64
      getter target : String
      getter request : Bytes
      getter? http2 : Bool
      getter sni : String?
      getter config : String # opaque JSON managed by the frontend
      getter flow_id : Int64?
      getter position : Int32
      getter name : String? # custom sub-tab label (nil = derive from the request line)

      def initialize(@id, @target, @request, @http2, @sni, @config, @flow_id, @position, @name = nil)
      end
    end

    # One fuzz sweep's metadata. Live counters are updated as the run streams; `status`
    # is running | done | stopped | error.
    struct FuzzRunRecord
      getter id : Int64
      getter session_id : Int64?
      getter created_at : Int64
      getter finished_at : Int64?
      getter target : String
      getter mode : String
      getter total : Int64?
      getter sent : Int64
      getter matched : Int64
      getter errors : Int64
      getter status : String

      def initialize(@id, @session_id, @created_at, @finished_at, @target, @mode,
                     @total, @sent, @matched, @errors, @status)
      end
    end

    # One persisted fuzz result row. `payloads` is a JSON array; the captured bytes are
    # present only for the matched/kept results (per keep_bodies).
    struct FuzzResultRecord
      getter id : Int64
      getter run_id : Int64
      getter idx : Int64
      getter payloads : String
      getter status : Int32?
      getter length : Int64
      getter words : Int32
      getter lines : Int32
      getter duration_us : Int64
      getter error : String?
      getter? matched : Bool
      getter extracted : String?
      getter request : Bytes?
      getter response_head : Bytes?
      getter response_body : Bytes?

      def initialize(@id, @run_id, @idx, @payloads, @status, @length, @words, @lines,
                     @duration_us, @error, @matched, @extracted,
                     @request = nil, @response_head = nil, @response_body = nil)
      end
    end

    # An intercepted HTTP/2 connection (one per CONNECT→TLS h2 session). Its raw
    # frames are the truth (P7); decoded streams project into `flows` separately.
    struct H2Connection
      getter id : Int64
      getter created_at : Int64
      getter host : String
      getter port : Int32
      getter alpn : String

      def initialize(@id, @created_at, @host, @port, @alpn)
      end
    end

    # One raw HTTP/2 frame as it crossed the wire. `direction` is "out"
    # (client→server) or "in" (server→client); `payload` excludes the 9-octet
    # frame header (kept byte-exact).
    struct H2Frame
      getter id : Int64
      getter conn_id : Int64
      getter created_at : Int64
      getter direction : String
      getter stream_id : Int64
      getter type : Int32
      getter flags : Int32
      getter length : Int32
      getter payload : Bytes

      def initialize(@id, @conn_id, @created_at, @direction, @stream_id, @type, @flags, @length, @payload)
      end
    end

    # Best-effort notification that a flow row changed. Published AFTER commit.
    record FlowEvent, id : Int64, kind : Symbol # :inserted | :updated

    # One row of the #124 append-only event feed (the AI firehose the MCP process tails).
    # `id` is the forward cursor key (monotonic AUTOINCREMENT); `created_at` is unix micros
    # for display. `goto_tab`/`goto_session_id` mirror Jobs::Goto so a promoted event can
    # jump to its result; `flow_id` is an optional cross-ref to a captured flow.
    struct EventRow
      getter id : Int64
      getter created_at : Int64
      getter source : String
      getter kind : String
      getter level : String
      getter message : String
      getter goto_tab : String?
      getter goto_session_id : Int64?
      getter flow_id : Int64?
      getter payload : String?

      def initialize(@id, @created_at, @source, @kind, @level, @message,
                     @goto_tab = nil, @goto_session_id = nil, @flow_id = nil, @payload = nil)
      end
    end

    # One currently-held intercept item, MIRRORED into intercept_held by the capturing
    # process so the MCP process can list/get it (#123). `item_id` is the Interceptor's
    # per-session id; `held_at_ms` is a WALL-CLOCK stamp captured once at hold time (the
    # in-memory Item.held_at is a monotonic Instant, meaningless across processes).
    struct HeldRow
      getter session_token : String
      getter item_id : Int64
      getter kind : String
      getter method : String
      getter host : String
      getter port : Int32
      getter scheme : String
      getter target : String
      getter flow_id : Int64?
      getter raw : Bytes
      getter held_at_ms : Int64
      getter edited : Bool
      # Wall-clock of the last MCP intercept_list/get that returned this item — the agent's
      # "I'm still watching" signal for the auto-forward reaper (0 = never viewed by an agent).
      getter viewed_ms : Int64

      def initialize(@session_token, @item_id, @kind, @method, @host, @port, @scheme,
                     @target, @raw, @held_at_ms, @flow_id = nil, @edited = false, @viewed_ms = 0_i64)
      end
    end

    # One row of the intercept_commands queue (MCP -> TUI). Drained forward-cursored and
    # applied by the lock-holding TUI (#123).
    struct CommandRow
      getter id : Int64
      getter session_token : String?
      getter verb : String
      getter item_id : Int64?
      getter bytes : Bytes?
      getter arg : String?

      def initialize(@id, @session_token, @verb, @item_id = nil, @bytes = nil, @arg = nil)
      end
    end
  end
end
