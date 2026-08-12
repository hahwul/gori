module Gori
  # Application-protocol classification of a captured flow, derived from the
  # response status (WS = the 101 upgrade handshake) and the response
  # Content-Type (gRPC / SSE). This is the single source of truth the History
  # PROTO column and the QL `proto:` field both defer to, so the label you see
  # and the value you filter on can never drift. gRPC/SSE have no dedicated
  # store column — they are inferred here from bytes gori already keeps.
  module Proto
    enum Kind
      Http
      Ws
      Grpc
      Sse

      # Short uppercase tag for the History PROTO column, TRANSPORT INCLUDED.
      #
      # The column has always distinguished HTTP from HTTPS, and this used to return a bare
      # WS/GRPC/SSE tag that REPLACED the scheme — so for exactly the three protocols where
      # gori has something extra to say, it dropped the one fact the Http member's fallback
      # existed to preserve. A `ws://` row and a `wss://` row were pixel-identical: same
      # METHOD, same PROTO, same HOST (the column carries no port), and "the app opened a
      # CLEARTEXT WebSocket and put a session token in the first frame" is a finding the
      # triage list could not express, while the store had the answer and the QL already
      # filtered on it.
      #
      # `S` means TLS here for the same reason it does in HTTPS. Every string this can
      # return is a value the `proto:` filter accepts (`Proto.split_transport` + `parse?`),
      # which is the module's own claim: the label you see and the value you filter on
      # cannot drift.
      def label(scheme : String) : String
        secure = Proto.secure?(scheme)
        case self
        in Http then secure ? "HTTPS" : "HTTP"
        in Ws   then secure ? "WSS" : "WS"
        in Grpc then secure ? "GRPCS" : "GRPC"
        in Sse  then secure ? "SSES" : "SSE"
        end
      end

      # Parse a QL `proto:` value's APPLICATION-protocol half. `websocket` is accepted as an
      # alias for `ws`.
      #
      # Deliberately NOT an alias table that folds `wss` in here. This is also what the
      # intercept catch condition canonicalizes through (`InterceptFilter.fold`), which has
      # one field per leaf and so cannot carry a transport term — folding `wss` to `ws` there
      # would silently WIDEN an operator's condition to cleartext sockets. The transport is
      # split off first, by `Proto.split_transport`, and re-applied by the caller that can
      # express it.
      def self.parse?(value : String) : Kind?
        case value.downcase
        when "http"            then Http
        when "ws", "websocket" then Ws
        when "grpc"            then Grpc
        when "sse"             then Sse
        else                        nil
        end
      end
    end

    # Is a flow's stored scheme a TLS one? The store keeps the HTTP scheme (`http`/`https`)
    # even for a WebSocket — a `wss://` URL is a 101 handshake inside a CONNECT tunnel — so
    # the `wss` spelling is accepted alongside for any caller that has a URL rather than a
    # flow row. One place decides it, for the PROTO column and the QL alike.
    def self.secure?(scheme : String) : Bool
      scheme == "https" || scheme == "wss"
    end

    # Split a `proto:` value into its application-protocol spelling and the transport the
    # operator NAMED, if any. `{value, nil}` when they named none — "either transport".
    #
    # The PROTO column prints the TLS spellings (`HTTPS`/`WSS`/`GRPCS`/`SSES`), so they have
    # to be typeable; and they have to MEAN the transport they name rather than widening to
    # the base protocol, which is why this returns a pair instead of aliasing inside
    # `Kind.parse?`. `QL.proto_cond` turns the `true` half into a `scheme` term.
    def self.split_transport(value : String) : {String, Bool?}
      case value.downcase
      when "https" then {"http", true}
      when "wss"   then {"ws", true}
      when "grpcs" then {"grpc", true}
      when "sses"  then {"sse", true}
      else              {value, nil}
      end
    end

    # gRPC content types: application/grpc, application/grpc+proto, and the
    # browser-facing application/grpc-web[+proto] — all share the prefix.
    def self.grpc?(content_type : String?) : Bool
      !!content_type.try { |ct| ct.lstrip.downcase.starts_with?("application/grpc") }
    end

    # Classify a flow from its status and the content types of BOTH sides. The 101 handshake
    # wins first (a WebSocket upgrade carries no content type); otherwise gRPC and SSE are read
    # off the content type; everything else — including a still-pending flow with no status or
    # type yet — is plain HTTP. Mirrors QL.proto_cond.
    #
    # ## Why the REQUEST type is read, and only for gRPC
    #
    # gRPC is a content type BOTH sides send, and this used to look only at the response's — so
    # a gRPC call was classified as gRPC exactly when it SUCCEEDED. A still-Pending one has no
    # response at all; an aborted one never got a type; one answered by a proxy's `text/html`
    # 502 has the wrong one. All three read as plain HTTP in the PROTO column and were missed
    # by `proto:grpc`, and all three are calls an operator is specifically looking for. The
    # request said `application/grpc` — the call IS gRPC, whatever came back.
    #
    # SSE deliberately stays response-only: `text/event-stream` on a request would be an
    # `Accept`, not a Content-Type, and a request cannot declare that its RESPONSE is a stream.
    #
    # `request_content_type` is a REQUIRED parameter, not an optional one with a nil default:
    # a caller that has a `FlowRow` has this field, and a default would let a surface silently
    # keep answering the old way — which is the drift this module exists to prevent. NULL is
    # still allowed and means "not recorded" (a row captured before the V14 column existed), in
    # which case the answer is exactly what it was before.
    def self.classify(status : Int32?, content_type : String?, request_content_type : String?) : Kind
      return Kind::Ws if status == 101
      return Kind::Grpc if grpc?(content_type) || grpc?(request_content_type)
      return Kind::Sse if Sse.sse?(content_type)
      Kind::Http
    end
  end
end
