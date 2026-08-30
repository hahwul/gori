require "../fuzz"

module Gori::Tui
  # Memory-bounded projection of a complete fuzz run. The controller spools every original
  # result before handing it here; this window owns only what the pane may render. Both limits
  # matter: millions of metric-only rows exhaust the heap just as surely as a handful of 8 MiB
  # bodies. A single over-byte-limit row remains visible as metrics-only while its exact bytes
  # stay in the temporary/permanent archive.
  class FuzzerResultWindow
    ROW_CAP  = 5_000
    BYTE_CAP = 64_i64 * 1024 * 1024

    getter rows = [] of Fuzz::Result
    getter bytes = 0_i64

    def initialize(@row_cap : Int32 = ROW_CAP, @byte_cap : Int64 = BYTE_CAP)
      raise ArgumentError.new("row cap must be positive") if @row_cap <= 0
      raise ArgumentError.new("byte cap must be positive") if @byte_cap <= 0
      @charges = [] of Int64
    end

    # Returns how many leading rows were evicted so the view can preserve raw-index selection.
    def append(result : Fuzz::Result) : Int32
      charge = self.class.result_bytes(result)
      if charge > @byte_cap
        result = self.class.metrics_only(result)
        charge = self.class.result_bytes(result)
      end
      @rows << result
      @charges << charge
      @bytes += charge

      evicted = 0
      while @rows.size > @row_cap || @bytes > @byte_cap
        @rows.shift
        @bytes -= @charges.shift
        evicted += 1
      end
      evicted
    end

    def clear : Nil
      @rows.clear
      @charges.clear
      @bytes = 0_i64
    end

    def self.result_bytes(result : Fuzz::Result) : Int64
      bytes = Fuzz::Persistence::ROW_METADATA_BYTES
      result.payloads.each { |payload| bytes += payload.bytesize }
      bytes += result.error.try(&.bytesize) || 0
      bytes += result.extracted.try(&.bytesize) || 0
      bytes += result.chain_error.try(&.bytesize) || 0
      bytes += result.grpc_message.try(&.bytesize) || 0
      bytes += result.request.try(&.size) || 0
      bytes += result.wire.try(&.size) || 0
      bytes += result.head.try(&.size) || 0
      bytes += result.body.try(&.size) || 0
      bytes.to_i64
    end

    def self.metrics_only(result : Fuzz::Result) : Fuzz::Result
      Fuzz::Result.new(result.index, result.payloads, result.position, result.status,
        result.length, result.words, result.lines, result.duration_us, result.error,
        result.matched?, result.incomplete?, result.extracted, nil, nil, nil,
        result.retried?, result.chain_error, result.grpc_status, result.grpc_message,
        result.timed_out?, result.resent_count, nil,
        ws_close_code: result.ws_close_code, ws_frames_in: result.ws_frames_in)
    end
  end
end
