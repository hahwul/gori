require "./types"
require "../flow_mapper"
require "../env"
require "../flow_source"
require "../proxy/codec/http1"

module Gori
  module Fuzz
    # Records a fuzz RESULT as a History flow — the opt-in evidence half of `record_history`
    # (`none | matched | all`). Shared engine logic so `gori run fuzz --record-history` and MCP
    # `fuzz_start.record_history` project the same request/response the same way.
    #
    # A `Fuzz::Result` only carries its rendered `request` / `body` bytes when the matcher was
    # built with `keep_bodies` other than `:none` (retention is the axis) — a caller that wants
    # to record MUST build the engine with the matching policy, or `request` is nil here and
    # nothing is written.
    module HistoryRecord
      extend self

      # Cap on flows written per run, so `record_history: all` on a huge sweep cannot grow the
      # DB without bound. THE cap — `MCP::Tools::FUZZ_HISTORY_MAX` is an alias of this constant,
      # not a second copy, so the two surfaces cannot drift to different ceilings.
      MAX = 5_000

      # The one sentence every surface uses to refuse recording a WebSocket sweep, so the CLI
      # and MCP cannot word it differently — the same job `CLI::Run.ws_notice_dropped_note` does
      # for the seed side.
      WS_UNSUPPORTED = "--record-history is HTTP-only: a WebSocket sweep is a framed exchange, " \
                       "not a request/response flow"

      # Record `r`'s rendered request + response as one flow and return the new id, or nil when
      # there is nothing to record (no retained request bytes) or the write did not commit.
      #
      # Never raises: recording must not break a sweep — a failure yields nil. But it must not be
      # SILENT either, or a locked/read-only DB reports as a clean "recorded 0 flows" with no
      # reason (#749 review). The caller supplies the reporting, because the two surfaces rate-
      # limit differently: MCP counts against its per-job drain budget, the CLI says it once.
      # `source` is a PARAMETER and not a hardcoded `Fuzzer`, because `Fuzz::Sender` is not the
      # Fuzzer's sender — the Miner, the Sequencer, Authorize, Minimize and Probe's active rules
      # all sweep through it (`Fuzz::Engine`). Hardcoding would make the first of those to learn
      # recording label its flows `fuzzer`, which is the drift these columns exist to stop.
      # `surface` names which of gori's three faces asked for the sweep.
      # `websocket` says the RUN took the framed WebSocket path, and it is the whole of the
      # WebSocket test here. A variation of such a run is not a flow: recording one would write
      # a request head declaring `Upgrade: websocket` — so `Store::FlowDetail#websocket?` answers
      # TRUE — with a 101 response carrying a SYNTHESIZED body no 101 ever has, and ZERO
      # `ws_messages` rows beside it. That is a manufactured flow: it renders in History as a
      # WebSocket with an empty transcript, and re-seeding a repeater from it yields a session
      # with no frames. `gori run repeater send` refuses the same thing for the same reason.
      #
      # DELIBERATELY NOT a byte test on the request head. `Proxy::WS.upgrade_request?(request)`
      # is the obvious spelling and it is WRONG here, because the bytes do not say which engine
      # ran: `--ws-http-only` / `ws_http_only:true` sweeps that exact handshake as an ORDINARY
      # HTTP request, and the flow it produces is an ordinary request/response exchange with
      # nothing manufactured about it. Sniffing the bytes silently recorded nothing for that
      # run — while both surfaces' refusal messages point the operator AT `--ws-http-only` as
      # the way to get recording back.
      #
      # The honest version for a real WS run — the handshake as a flow PLUS the transcript
      # through `Store#insert_ws_messages` — needs `Fuzz::Result` to retain the transcript under
      # `keep_bodies`, which is a retention-budget change of its own. Refused, not faked.
      #
      # Every surface also refuses `record_history` + WebSocket up front, before the sweep
      # dials: "swept 10,000 sessions, recorded 0" is a refusal that arrives after the traffic.
      # This is the backstop.
      def record(store : Store, r : Result, *, scheme : String, host : String, port : Int32,
                 http2 : Bool, source : FlowSource::Kind, surface : FlowSource::Surface,
                 source_ref : String? = nil, websocket : Bool = false,
                 &on_error : Exception -> _) : Int64?
        # `wire` FIRST: `request` is the rendered template, and the send seam rewrote it — the
        # `$NAME` pass and the active session slot's header overlay both run below the matcher
        # (`Fuzz::Sender#send`). Recording the template wrote flows without the identity the
        # sweep actually sent under, which is the same defect `Repeater::Sender#wire` names for
        # the Repeater half. Falls back to `request` for a backend that reports no wire (a spec
        # double, a run where nothing rewrote the bytes).
        return nil if websocket
        request = r.wire || r.request
        return nil unless request
        head, body = split_head_body(request)
        method, target, version = Proxy::Codec::Http1.authored_start_line(head)
        fid = store.insert_flow(Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: scheme, host: host, port: port,
          method: method, target: target,
          http_version: http2 ? "HTTP/2" : version,
          head: head, body: body, body_size: body.try(&.size.to_i64),
          source: source, source_surface: surface, source_ref: source_ref))
        # A store that ROLLED BACK reports 0, it does not raise — the commonest failure here
        # (busy/locked/closed) and, until this was reported, the silent one: every result
        # yielded nil and the run printed "recorded 0 flows" with no reason anywhere.
        if fid <= 0
          on_error.call(Gori::Error.new("the flow insert did not commit (project busy or read-only)"))
          return nil
        end
        write_response(store, fid, r)
        fid
      rescue ex
        on_error.call(ex)
        nil
      end

      # The response half of `record`: the parsed head when there is one, else the error row.
      # Split out so `record` stays inside the complexity limit once the WebSocket guard above
      # is counted — it is a self-contained step, not a branch of the recording decision.
      private def write_response(store : Store, fid : Int64, r : Result) : Nil
        rhead = r.head
        if rhead && !rhead.empty? && (resp = (Proxy::Codec::Http1.parse_response_head(rhead) rescue nil))
          store.update_response(FlowMapper.response(resp, flow_id: fid, body: r.body,
            duration_us: r.duration_us,
            state: r.error ? Store::FlowState::Error : Store::FlowState::Complete,
            error: r.error, body_size: r.body.try(&.size.to_i64)))
        else
          store.update_response(FlowMapper.error_response(fid, r.error || "no response recorded"))
        end
      end

      # Whether `policy` (:none | :matched | :all) records this result. `all` records every sent
      # request; `matched` only the ones the matcher kept; `none` records nothing.
      def records?(policy : Symbol, r : Result, websocket : Bool = false) : Bool
        return false if policy == :none
        # Same guard as `record`, so the COUNT a surface reports matches what was written. A
        # `records?` that said yes to a row `record` then dropped would report "recorded 40
        # flows" over an empty table.
        return false if websocket
        policy == :all || r.matched?
      end

      private def split_head_body(bytes : Bytes) : {Bytes, Bytes?}
        boundary = Env.head_body_boundary(bytes)
        head = bytes[0, boundary]
        body_size = bytes.size - boundary
        {head, body_size > 0 ? bytes[boundary, body_size] : nil}
      end
    end
  end
end
