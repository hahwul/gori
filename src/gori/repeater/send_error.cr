module Gori
  module Repeater
    # How a failed one-shot send failed, as the three fields a caller's retry policy branches
    # on: `error_kind` (the coarse category), `error_code` and `retryable`. It was MCP's alone
    # (`send_request`'s structured-error contract) until `gori run send --format json` needed
    # the same answer (#1384): a script had to string-match the error sentence to tell a
    # timeout from a refused connection. One classifier, so the two surfaces cannot disagree
    # about which failure is worth retrying.
    #
    # It reads gori's OWN error sentences (the engines' and the dialer's), which is why it lives
    # beside the engines that write them rather than in either surface.
    module SendError
      # Substrings that identify a DETERMINISTIC protocol refusal in gori's own error text —
      # a message gori (or the origin) will produce identically on every retry.
      #
      # The list used to stop at malformed/framing/interim/chunk, which left the sharpest
      # finding a tester can get filed as an "other" transient error: two conflicting
      # `Content-Length` headers — a response-splitting/desync condition — came back as
      # `error_kind:"other", error_code:"NETWORK_ERROR", retryable:true`, so an agent LOOPS on
      # it instead of reporting it. Every phrase here is raised by gori's own framing guards
      # (`Codec::Body`, `Codec::Http1`, the h2 assembler/engine), never by a socket.
      PROTOCOL_ERROR_PHRASES = {
        "malformed", "framing", "interim", "chunk",
        "conflicting content-length", "ambiguous framing", "obfuscated",
        "transfer-encoding", "content-length", "invalid header", "invalid status",
        "http/2", "h2 ", "hpack", "response head", "status line",
      }

      # h2/RFC 9113 §7 conditions that are TRANSIENT even though the sentence naming them
      # trips PROTOCOL_ERROR_PHRASES (every one of them says "h2 "). Keyed on the SPEC
      # ERROR-CODE NAMES, not on gori's sentence: the names are fixed by the RFC and the
      # engine renders them straight out of `H2Engine::GOAWAY_ERRORS`, so matching
      # `refused_stream` survives any rewording of the sentence carrying it — which is the
      # failure mode a whole-sentence literal would have.
      #
      # §8.7 makes REFUSED_STREAM an explicit RETRY instruction ("the request was not
      # processed") and ENHANCE_YOUR_CALM is a rate signal, not a malformed message. Coding
      # either as a non-retryable PROTOCOL_ERROR tells an agent to stop and file a finding
      # where the correct action is to send the request again on a fresh connection.
      RETRYABLE_H2_PHRASES = {"refused_stream", "enhance_your_calm"}

      # "gori got no response frame at all" — the category `no_response` exists for. These
      # also say "h2 ", so PROTOCOL_ERROR_PHRASES used to claim them and report an origin
      # that simply closed the connection as a non-retryable framing refusal. A protocol
      # verdict means gori can PROVE the message malformed; silence is not that.
      NO_RESPONSE_PHRASES = {"no h2 response", "no response"}

      # RFC 9113 §8.1 lets an origin answer while the request body is still going out — a 413
      # after N bytes is exactly what an upload / body-size probe is looking for. The send has
      # a REAL response (status, head, body); what it does not have is the whole request. That
      # is neither a network fault nor gori proving the message malformed:
      #   * retrying re-sends the entire body to a server that already rejected it, which for a
      #     body-size probe is the wrong move and, at scale, is the probe becoming the attack;
      #   * `PROTOCOL_ERROR` would blame someone for behaviour the RFC explicitly permits.
      # So it gets its own kind and its own non-retryable code.
      #
      # Keyed on "truncated at" and NOT on "NOT fully sent", deliberately: the flow-control
      # stall sentence (`H2Engine.flow_stalled`) ALREADY ends with "The request was NOT fully
      # sent." and is a genuine stall that must stay `protocol`. The two conditions differ in
      # whether a response arrived, and only the truncation sentence counts bytes with
      # "truncated at".
      TRUNCATED_REQUEST_PHRASE = "truncated at"

      # The one `flow_stalled` variant that is a DEADLINE, not origin misbehaviour: gori's own
      # budget for the whole exchange expired while the origin was still granting window in
      # increments too small to finish the body. Its siblings — "the origin closed the
      # connection before granting window", "the origin never granted flow-control window" —
      # are the origin refusing to make progress, and `protocol` / non-retryable is right for
      # those: retrying reproduces them and the refusal IS the finding.
      #
      # This one is different in the one way that matters to an agent: nothing about the
      # target changed, only the clock ran out, and the correct next move is to raise
      # `timeout_ms` — which `retryable: false` tells a caller not to attempt. It is the same
      # shape as gori's ordinary idle timeout, which is already `timeout` / NETWORK_ERROR, so
      # it is folded into that kind rather than given a fourth code: a deadline is a deadline.
      #
      # Keyed on this PHRASE and not on the whole sentence, and not on "NOT fully sent" —
      # which every flow_stalled variant ends with, so matching that would sweep the siblings
      # in with it. The phrase must stay in step with `H2Engine.flow_stalled`; the spec pins
      # both it and a sibling sentence as DATA so a reword there cannot silently flip a
      # verdict here.
      EXCHANGE_BUDGET_PHRASE = "budget for the whole exchange"

      # Coarse category for a send's network error, from the engine's error text
      # (gori's own controlled strings). "connect" (the TCP layer: refused, unreachable,
      # a connect timeout, or a name that did not resolve — the dialer now separates a
      # certificate rejection, a refused handshake and an origin that accepts and then goes
      # silent into their own sentences, which land on "other"/"timeout" as they should),
      # "timeout" (idle read/write, and a TLS handshake that never got an answer), "protocol" (a deterministic
      # framing/protocol refusal — see PROTOCOL_ERROR_PHRASES), "no_response", else "other".
      #
      # A pure function of the engine's sentence, so it is `self.` and directly testable: the
      # retry policy an agent applies hangs off it, and the sentences it reads are written in
      # another module. Pinning them in a spec is what keeps a reword there from silently
      # flipping a retryable condition into "stop and report a finding".
      def self.kind(message : String?) : String?
        return nil unless message
        m = message.downcase
        return "connect" if m.starts_with?("connect failed")
        return "timeout" if m.includes?("timed out") || m.includes?("timeout")
        # Ahead of PROTOCOL_ERROR_PHRASES (the sentence says "h2 ") — see the constant.
        return "timeout" if m.includes?(EXCHANGE_BUDGET_PHRASE)
        # Both ahead of PROTOCOL_ERROR_PHRASES on purpose — see their own comments.
        return "other" if RETRYABLE_H2_PHRASES.any? { |p| m.includes?(p) }
        return "no_response" if NO_RESPONSE_PHRASES.any? { |p| m.includes?(p) }
        return "protocol" if PROTOCOL_ERROR_PHRASES.any? { |p| m.includes?(p) }
        # AFTER the three lists above, on purpose. A GOAWAY/RST_STREAM reason APPENDS the
        # truncation clause rather than replacing it, so those sentences must keep the verdict
        # their error code already earns them (REFUSED_STREAM stays retryable, CANCEL stays
        # protocol) — every one of them says "h2 " and is matched strictly earlier.
        return "truncated_request" if m.includes?(TRUNCATED_REQUEST_PHRASE)
        return "no_response" if m.includes?("closed")
        "other"
      end

      # Split out and `self.` for the same reason `kind` is: the retry policy an
      # agent applies hangs off this mapping, and pinning it in a spec is what stops a new kind
      # from silently landing in the retryable bucket by falling through the `else`.
      def self.code(kind : String?) : String
        case kind
        when "protocol"          then "PROTOCOL_ERROR"
        when "truncated_request" then "REQUEST_TRUNCATED"
        else                          "NETWORK_ERROR"
        end
      end

      # `self.` and separate from `code` for the same reason: this is the field an
      # agent branches on, so a spec pins the PAIR rather than the code mapping alone.
      def self.retryable?(code : String, delivered : Bool) : Bool
        code == "NETWORK_ERROR" && !delivered
      end
    end
  end
end
