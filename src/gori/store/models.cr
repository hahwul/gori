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
                     @body_truncated = false, @body_size = nil)
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
      getter replay_id : Int64?
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes

      def initialize(@id, @flow_id, @replay_id, @created_at, @direction, @opcode, @payload)
      end

      def text? : Bool
        @opcode == 1
      end
    end

    # Severity of a finding (stored as the enum value).
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

    # Triage state of a finding, independent of severity (stored as the enum
    # value; V12). Open is the default for a freshly captured finding.
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
      Finding
      Note

      def label : String
        to_s.downcase
      end

      def self.parse(s : String) : LinkOwnerKind?
        case s
        when "finding" then Finding
        when "note"    then Note
        else                nil
        end
      end
    end

    # Target workbench entity referenced by an `entity_links` row.
    enum LinkRefKind
      Flow
      Replay
      Fuzz
      Miner

      def label : String
        to_s.downcase
      end

      def self.parse(s : String) : LinkRefKind?
        case s
        when "flow"   then Flow
        when "replay" then Replay
        when "fuzz"   then Fuzz
        when "miner"  then Miner
        else               nil
        end
      end

      # Short tag for the TUI list (e.g. "[hist]").
      def tag : String
        return "hist" if flow?
        return "replay" if replay?
        return "fuzz" if fuzz?
        "miner"
      end
    end

    # A link from a Finding or Note to a workbench entity (flow/replay/fuzz/miner).
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

    # A human-confirmed finding (DESIGN.md: the final output). Optionally linked
    # to a captured flow. One per project DB.
    struct Finding
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

    # A grouped Prism scan issue (V20): one row per distinct (code, host). Machine-found
    # (by the passive/active analyzer), as opposed to the human-confirmed `Finding`. The
    # affected URLs accumulate in `affected` (capped) while `hit_count` counts every
    # observation; `severity` rises to the max seen. Reuses the shared Severity/Status
    # enums; `status` lets a group be triaged (confirmed / false-positive / resolved) or
    # promoted to a Finding. `category` drives the filter lens and the project tech summary.
    struct PrismIssue
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
      getter sample_replay_id : Int64? # representative Replay tab when the hit came from Replay

      def initialize(@id, @code, @category, @host, @title, @severity, @status, @hit_count,
                     @affected, @sample_flow_id, @evidence, @first_seen, @last_seen,
                     @sample_replay_id = nil)
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

    # A Match&Replace rule: a literal substring rewrite of a request/response HEAD
    # (request line + headers) or BODY (the entity body). Human-authored (P4),
    # persisted per project. `replacement` may be empty (delete `pattern`). A body
    # rule buffers + re-frames the message in flight (Content-Length synced); a head
    # rule streams the body untouched (P6). See `Rules` / `ClientConn`.
    struct MatchRule
      getter id : Int64
      getter? enabled : Bool
      getter target : RuleTarget
      getter part : RulePart
      getter pattern : String
      getter replacement : String

      def initialize(@id, @enabled, @target, @part, @pattern, @replacement)
      end
    end

    # A persisted Replay workbench tab: the editable request plus the LAST send
    # response (V11 — head/body/error/duration; all nil until the first send).
    # Shared across sessions on the same project — the TUI reconciles local tabs
    # against these rows by `id` on the data_version poll.
    struct ReplayRecord
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
      getter? mark_transform : Bool # V22: apply §…§ inline Convert chains on send

      def initialize(@id, @target, @request, @http2, @auto_content_length, @flow_id, @position,
                     @response_head = nil, @response_body = nil, @response_error = nil,
                     @response_duration_us = nil, @name = nil, @sni = nil, @mark_transform = false)
      end
    end

    # A persisted Fuzzer/Intruder session: the marked template (with §…§ positions)
    # plus an opaque `config` JSON the TUI owns (mode / payload sets / matchers /
    # engine opts). Mirrors ReplayRecord — survives reopen and syncs across sessions.
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
    # session, like Replay responses before V11).
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
  end
end
