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

      # Short uppercase tag for the History PROTO column (WS/GRPC/SSE); the Http
      # member has no tag of its own — the column falls back to the scheme
      # (HTTP/HTTPS) so the plaintext-vs-TLS signal is preserved for normal flows.
      def label : String
        case self
        in Http then "HTTP"
        in Ws   then "WS"
        in Grpc then "GRPC"
        in Sse  then "SSE"
        end
      end

      # Parse a QL `proto:` value. `websocket` is accepted as an alias for `ws`.
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

    # gRPC content types: application/grpc, application/grpc+proto, and the
    # browser-facing application/grpc-web[+proto] — all share the prefix.
    def self.grpc?(content_type : String?) : Bool
      !!content_type.try { |ct| ct.lstrip.downcase.starts_with?("application/grpc") }
    end

    # Classify a flow from its response status + Content-Type. The 101 handshake
    # wins first (a WebSocket upgrade carries no content type); otherwise gRPC and
    # SSE are read off the Content-Type; everything else — including a still-pending
    # flow with no status/type yet — is plain HTTP. Mirrors QL.proto_cond.
    def self.classify(status : Int32?, content_type : String?) : Kind
      return Kind::Ws if status == 101
      return Kind::Grpc if grpc?(content_type)
      return Kind::Sse if Sse.sse?(content_type)
      Kind::Http
    end
  end
end
