require "../fuzz"

module Gori::Tui
  # Memory-bounded projection of a complete fuzz run. The controller spools every original
  # result before handing it here; this window owns only what the pane may render. Both limits
  # matter: millions of metric-only rows exhaust the heap just as surely as a handful of 8 MiB
  # bodies. A single over-byte-limit row remains visible as a bounded metrics-only projection
  # while its exact bytes and scalar text stay in the temporary/permanent archive.
  class FuzzerResultWindow
    ROW_CAP              = 5_000
    BYTE_CAP             = 64_i64 * 1024 * 1024
    SCALAR_PREVIEW_BYTES = 64_i64 * 1024
    OMITTED_MARKER       = "… [display truncated]"

    getter rows = Deque(Fuzz::Result).new
    getter bytes = 0_i64

    def initialize(@row_cap : Int32 = ROW_CAP, @byte_cap : Int64 = BYTE_CAP)
      raise ArgumentError.new("row cap must be positive") if @row_cap <= 0
      raise ArgumentError.new("byte cap must be positive") if @byte_cap <= 0
      @charges = Deque(Int64).new
      @projected_indices = Set(Int64).new
    end

    # Returns how many leading rows were evicted so the view can preserve raw-index selection.
    def append(result : Fuzz::Result) : Int32
      charge = self.class.result_bytes(result)
      projected = false
      if charge > @byte_cap
        # Projected from HERE on, not only past the second cap: `metrics_only` already dropped
        # the request/head/body this row holds in the archive, and a row it sufficed for was
        # left unmarked — so the detail panes said "not retained" about bytes the spool has.
        projected = true
        result = self.class.metrics_only(result)
        charge = self.class.result_bytes(result)
        if charge > @byte_cap
          result = self.class.bounded_metrics(result,
            {@byte_cap - Fuzz::Persistence::ROW_METADATA_BYTES, SCALAR_PREVIEW_BYTES}.min)
          charge = self.class.result_bytes(result)
        end
      end
      @rows << result
      @charges << charge
      @projected_indices.add(result.index) if projected
      @bytes += charge

      evicted = 0
      while @rows.size > @row_cap || @bytes > @byte_cap
        removed = @rows.shift
        @bytes -= @charges.shift
        unless @rows.any? { |row| row.index == removed.index }
          @projected_indices.delete(removed.index)
        end
        evicted += 1
      end
      evicted
    end

    def projected?(index : Int64) : Bool
      @projected_indices.includes?(index)
    end

    # Take over another window's contents, PROJECTION MARKS INCLUDED.
    #
    # The saved-run restore builds its window on a background fiber and hands the result to
    # the view. Re-`append`ing those rows into the view's own window loses `projected?`: a row
    # that was projected is now small, so nothing re-marks it — and `projected?` is the bit
    # that tells the detail panes the bytes are in the ARCHIVE rather than absent, and that
    # keeps `Send to Repeater` from seeding the 64 KiB preview (`… [display truncated]` and
    # all) as if it were the request. Mutates in place rather than swapping the object,
    # because `FuzzerView` aliases `rows` at construction.
    def adopt(other : FuzzerResultWindow) : Nil
      return if other.same?(self) # `clear` first would otherwise wipe what it is copying
      clear
      other.rows.each { |row| @rows << row }
      other.charges.each { |charge| @charges << charge }
      other.projected_indices.each { |index| @projected_indices.add(index) }
      @bytes = other.bytes
    end

    def clear : Nil
      @rows.clear
      @charges.clear
      @projected_indices.clear
      @bytes = 0_i64
    end

    # For `adopt` alone — the parallel bookkeeping `rows` needs to survive the handover.
    protected def charges : Deque(Int64)
      @charges
    end

    protected def projected_indices : Set(Int64)
      @projected_indices
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
      copy_metrics(result, result.payloads, result.error, result.extracted,
        result.chain_error, result.grpc_message)
    end

    # Bound every variable-width scalar as one budget. Payload prefixes have priority because
    # they identify the row; remaining error/extraction/protocol text follows in display order.
    def self.bounded_metrics(result : Fuzz::Result, budget : Int64) : Fuzz::Result
      remaining = {budget, 0_i64}.max
      payloads = [] of String
      result.payloads.each do |payload|
        text, remaining, cut = take_text(payload, remaining)
        payloads << text unless text.empty?
        break if cut
      end
      if payloads.size < result.payloads.size && remaining > 0
        marker, remaining, _ = take_text(OMITTED_MARKER, remaining)
        payloads << marker unless marker.empty?
      end

      error, remaining = take_optional(result.error, remaining)
      extracted, remaining = take_optional(result.extracted, remaining)
      chain_error, remaining = take_optional(result.chain_error, remaining)
      grpc_message, _ = take_optional(result.grpc_message, remaining)
      copy_metrics(result, payloads, error, extracted, chain_error, grpc_message)
    end

    private def self.take_optional(value : String?, remaining : Int64) : {String?, Int64}
      return {nil, remaining} unless value
      text, left, _ = take_text(value, remaining)
      {text, left}
    end

    private def self.take_text(value : String, remaining : Int64) : {String, Int64, Bool}
      return {"", remaining, !value.empty?} if remaining <= 0
      if value.bytesize.to_i64 <= remaining
        return {value, remaining - value.bytesize, false}
      end
      marker_size = {OMITTED_MARKER.bytesize.to_i64, remaining}.min.to_i
      value_size = {remaining.to_i - marker_size, 0}.max
      text = String.new(value.to_slice[0, value_size])
      text += String.new(OMITTED_MARKER.to_slice[0, marker_size])
      {text, 0_i64, true}
    end

    private def self.copy_metrics(result : Fuzz::Result, payloads : Array(String),
                                  error : String?, extracted : String?, chain_error : String?,
                                  grpc_message : String?) : Fuzz::Result
      Fuzz::Result.new(result.index, payloads, result.position, result.status,
        result.length, result.words, result.lines, result.duration_us, error,
        result.matched?, result.incomplete?, extracted, nil, nil, nil,
        result.retried?, chain_error, result.grpc_status, grpc_message,
        result.timed_out?, result.resent_count, nil,
        ws_close_code: result.ws_close_code, ws_frames_in: result.ws_frames_in)
    end
  end
end
