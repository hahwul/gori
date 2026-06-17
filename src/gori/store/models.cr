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
      getter body : Bytes?
      # When this flow is a decoded HTTP/2 stream, links back to its raw frame log.
      getter h2_conn_id : Int64?
      getter h2_stream_id : Int64?

      def initialize(@created_at, @scheme, @host, @port, @method, @target,
                     @http_version, @head, @body = nil,
                     @sni = nil, @alpn = nil, @tls_version = nil,
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
      getter body : Bytes?
      getter ttfb_us : Int64?
      getter duration_us : Int64?
      getter state : FlowState
      getter error : String?

      def initialize(@flow_id, @status, @head, @body = nil, @reason = nil,
                     @content_type = nil, @ttfb_us = nil, @duration_us = nil,
                     @state = FlowState::Complete, @error = nil)
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
      getter size : Int64
      getter state : FlowState

      def initialize(@id, @created_at, @scheme, @method, @host, @port, @target,
                     @status, @size, @state)
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
      getter h2_conn_id : Int64?
      getter h2_stream_id : Int64?

      def initialize(@row, @http_version, @request_head, @request_body,
                     @response_head, @response_body, @h2_conn_id = nil, @h2_stream_id = nil)
      end
    end

    # A captured WebSocket message belonging to a (101) flow. `direction` is
    # "out" (client→server) or "in" (server→client); opcode 1=text, 2=binary.
    struct WsMessage
      getter id : Int64
      getter flow_id : Int64
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes

      def initialize(@id, @flow_id, @created_at, @direction, @opcode, @payload)
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

      def initialize(@id, @created_at, @updated_at, @title, @severity, @host, @flow_id, @notes)
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

    # A Match&Replace rule: a literal substring rewrite of a request/response
    # HEAD (request line + headers; bodies are never touched, P6). Human-authored
    # (P4), persisted per project. `replacement` may be empty (delete `pattern`).
    struct MatchRule
      getter id : Int64
      getter? enabled : Bool
      getter target : RuleTarget
      getter pattern : String
      getter replacement : String

      def initialize(@id, @enabled, @target, @pattern, @replacement)
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
