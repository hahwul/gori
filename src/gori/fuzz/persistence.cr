require "json"
require "base64"
require "../store"
require "./types"

module Gori
  module Fuzz
    # Frozen context for one saved sweep. Session ids are present for TUI-owned runs and nil
    # for CLI/MCP runs, which remain project-level records.
    record SavedRunMeta,
      session_id : Int64?,
      target : String,
      mode : String,
      total : Int64?,
      created_at : Int64 = Time.utc.to_unix_ms * 1000_i64,
      http2 : Bool = false,
      sni : String? = nil,
      tls_preset : String? = nil,
      websocket : Bool = false,
      surface : String? = nil,
      source_ref : String? = nil

    # Bounded asynchronous writer shared by permanent saves and the temporary result spool.
    # Live Result appends only serialize and offer a batch to this four-slot queue; they never
    # wait for SQLite or for queue space. A rejected append is reported immediately and makes
    # the run save_failed rather than silently dropping a result (P6/P7).
    class Persistence
      BATCH_SIZE         = 128
      BATCH_BYTES        = 8_i64 * 1024 * 1024
      MAX_QUEUED_BATCHES = 4

      # Fixed scalar values, nullable-field presence bits and variable-field length slots. The
      # variable payload below is counted byte-for-byte; this conservative fixed allowance keeps
      # the transaction bound deterministic without pretending to reproduce SQLite's varints.
      ROW_METADATA_BYTES = 128_i64

      private record Batch, rows : Array(Store::FuzzResultWrite), bytes : Int64
      private record Barrier, reply : Channel(Bool)
      private record Terminal,
        sent : Int64,
        matched : Int64,
        errors : Int64,
        status : String,
        finished_at : Int64,
        reply : Channel(Bool)
      private alias Command = Batch | Barrier | Terminal

      getter run_id : Int64
      getter error : String?
      getter written : Int64

      def initialize(@store : Store, meta : SavedRunMeta, initial_status : String = "running",
                     @batch_size : Int32 = BATCH_SIZE,
                     @batch_bytes : Int64 = BATCH_BYTES)
        raise ArgumentError.new("batch_size must be positive") if @batch_size <= 0
        raise ArgumentError.new("batch_bytes must be positive") if @batch_bytes <= 0

        @pending = [] of Store::FuzzResultWrite
        @pending_bytes = 0_i64
        @written = 0_i64
        @error = nil.as(String?)
        @run_id = 0_i64
        @commands = Channel(Command).new(MAX_QUEUED_BATCHES)
        @worker_done = Channel(Nil).new(1)
        @worker_started = false
        @worker_stopped = true
        @terminal_requested = false
        @terminal_committed = nil.as(Bool?)

        begin
          @run_id = @store.insert_fuzz_run(meta.session_id, meta.target, meta.mode, meta.total,
            created_at: meta.created_at, status: initial_status, http2: meta.http2,
            sni: meta.sni, tls_preset: meta.tls_preset, websocket: meta.websocket,
            surface: meta.surface, source_ref: meta.source_ref)
          if @run_id > 0
            @worker_started = true
            @worker_stopped = false
            spawn { worker_loop }
          else
            fail_save("the fuzz run insert did not commit (project busy or read-only)")
          end
        rescue ex
          @run_id = 0_i64
          fail_save(ex.message || "could not create the saved fuzz run")
        end
      end

      def failed? : Bool
        !@error.nil?
      end

      def terminal? : Bool
        @terminal_requested
      end

      # Teardown barrier for an owner such as Spool. An unfinished stream is aborted; a finish
      # already in flight is allowed to settle before its Store can be closed underneath it.
      def close : Nil
        abort unless terminal?
        return unless @worker_started && !@worker_stopped
        @worker_done.receive
      rescue Channel::ClosedError
      end

      # Live-engine path. It never waits for the Store writer or for this Persistence queue.
      def append(result : Result) : Bool
        return false unless accepting?
        append_live(self.class.write_row(result))
      rescue ex
        fail_save(ex.message || "could not serialize a fuzz result")
        false
      end

      # Post-run copy path (spool -> permanent Store). It may apply backpressure because no
      # network/data-path fiber is waiting on it, and therefore never rejects merely because
      # four earlier batches are still committing.
      def append(row : Store::FuzzResultWrite) : Bool
        return false unless accepting?
        append_wait(row)
      rescue ex
        fail_save(ex.message || "could not queue a fuzz result")
        false
      end

      # Exact Store-record copy: no JSON parse/rebuild and no BLOB/text normalization.
      def append(record : Store::FuzzResultRecord) : Bool
        append(self.class.write_row(record))
      end

      # Explicitly drain every accepted row. Unlike live append, flush is a caller-requested
      # barrier and may wait; a buffered reply keeps a cancelled waiter from stalling the worker.
      def flush : Bool
        return terminal_success if terminal?
        return false unless @worker_started
        queued = enqueue_pending_wait
        drained = queued && barrier
        drained && !failed?
      rescue ex
        fail_save(ex.message || "could not flush fuzz results")
        false
      end

      # FIFO terminal barrier: pending rows are queued behind all accepted batches, then the
      # checked run update executes on the same worker. Repeated finishes return the first
      # outcome and never issue a second terminal update.
      def finish(sent : Int64, matched : Int64, errors : Int64, status : String,
                 finished_at : Int64 = Time.utc.to_unix_ms * 1000_i64) : Bool
        finish_once(sent, matched, errors, status, finished_at)
        terminal_success
      end

      # Stop an unfinished persistence stream while preserving its accepted prefix. The
      # terminal row is save_failed even when no earlier batch failed. True means that checked
      # terminal update committed; it does not claim the snapshot is complete.
      def abort(sent : Int64 = @written, matched : Int64 = 0_i64, errors : Int64 = 0_i64,
                finished_at : Int64 = Time.utc.to_unix_ms * 1000_i64,
                reason : String = "fuzz result persistence aborted") : Bool
        return @terminal_committed || false if terminal?
        fail_save(reason)
        finish_once(sent, matched, errors, "save_failed", finished_at)
        @terminal_committed || false
      end

      def self.write_row(result : Result) : Store::FuzzResultWrite
        payloads = JSON.build do |json|
          json.array do
            result.payloads.each do |payload|
              if payload.valid_encoding?
                json.string(payload)
              else
                # Payloads may be raw decoder/wordlist bytes. Keep the TEXT column JSON-safe
                # without replacing malformed octets (P7); legacy valid strings stay strings.
                json.object do
                  json.field "base64", Base64.strict_encode(payload.to_slice)
                  json.field "encoding", "base64"
                end
              end
            end
          end
        end
        Store::FuzzResultWrite.new(
          result.index, payloads, result.position, result.status, result.length,
          result.words, result.lines, result.duration_us, result.error, result.matched?,
          result.incomplete?, result.extracted, result.request, result.head, result.body,
          result.retried?, result.chain_error, result.grpc_status, result.grpc_message,
          result.timed_out?, result.resent_count, result.wire, result.ws_close_code,
          result.ws_frames_in)
      end

      # Record -> write is deliberately field-for-field. This is the spool copy seam: parsing
      # payload JSON or rebuilding byte slices here would make a post-run save lossy.
      def self.write_row(record : Store::FuzzResultRecord) : Store::FuzzResultWrite
        Store::FuzzResultWrite.new(
          record.idx, record.payloads, record.position, record.status, record.length,
          record.words, record.lines, record.duration_us, record.error, record.matched?,
          record.incomplete?, record.extracted, record.request, record.response_head,
          record.response_body, record.retried?, record.chain_error, record.grpc_status,
          record.grpc_message, record.timed_out?, record.resent_count, record.wire,
          record.ws_close_code, record.ws_frames_in)
      end

      # Deterministic transaction budget: every variable-width field plus a fixed allowance for
      # the row's scalar/null/length metadata. bytesize (not character count) is required for
      # malformed and multibyte payloads.
      def self.row_bytes(row : Store::FuzzResultWrite) : Int64
        bytes = ROW_METADATA_BYTES + row.payloads.bytesize
        bytes += row.error.try(&.bytesize) || 0
        bytes += row.extracted.try(&.bytesize) || 0
        bytes += row.request.try(&.size) || 0
        bytes += row.response_head.try(&.size) || 0
        bytes += row.response_body.try(&.size) || 0
        bytes += row.chain_error.try(&.bytesize) || 0
        bytes += row.grpc_message.try(&.bytesize) || 0
        bytes += row.wire.try(&.size) || 0
        bytes.to_i64
      end

      # Store record -> the exact engine row the existing TUI/CLI serializers consume.
      def self.result(record : Store::FuzzResultRecord) : Result
        payloads = begin
          JSON.parse(record.payloads).as_a.map do |item|
            if text = item.as_s?
              text
            elsif (obj = item.as_h?) && obj["encoding"]?.try(&.as_s?) == "base64" &&
                  (encoded = obj["base64"]?.try(&.as_s?))
              String.new(Base64.decode(encoded))
            else
              item.to_json
            end
          end
        rescue
          [record.payloads]
        end
        Result.new(record.idx, payloads, record.position, record.status, record.length,
          record.words, record.lines, record.duration_us, record.error, record.matched?,
          record.incomplete?, record.extracted, record.response_head, record.response_body,
          record.request, record.retried?, record.chain_error, record.grpc_status,
          record.grpc_message, record.timed_out?, record.resent_count, record.wire,
          ws_close_code: record.ws_close_code, ws_frames_in: record.ws_frames_in)
      end

      private def accepting? : Bool
        @worker_started && !failed? && !terminal?
      end

      private def append_live(row : Store::FuzzResultWrite) : Bool
        bytes = self.class.row_bytes(row)
        if must_split_before?(bytes)
          return saturated unless enqueue_pending_live
        end

        # A row over the byte ceiling is legal only as its own transaction.
        if bytes > @batch_bytes
          return true if offer_live(Batch.new([row], bytes))
          return saturated
        end

        @pending << row
        @pending_bytes += bytes
        if @pending.size >= @batch_size || @pending_bytes >= @batch_bytes
          unless enqueue_pending_live
            @pending.pop
            @pending_bytes -= bytes
            return saturated
          end
        end
        true
      end

      private def append_wait(row : Store::FuzzResultWrite) : Bool
        bytes = self.class.row_bytes(row)
        return false if must_split_before?(bytes) && !enqueue_pending_wait

        if bytes > @batch_bytes
          send_command(Batch.new([row], bytes))
        else
          @pending << row
          @pending_bytes += bytes
          if @pending.size >= @batch_size || @pending_bytes >= @batch_bytes
            enqueue_pending_wait
          else
            true
          end
        end
      end

      private def must_split_before?(next_bytes : Int64) : Bool
        !@pending.empty? &&
          (@pending.size >= @batch_size || @pending_bytes + next_bytes > @batch_bytes)
      end

      private def enqueue_pending_live : Bool
        return true if @pending.empty?
        rows = @pending
        bytes = @pending_bytes
        if offer_live(Batch.new(rows, bytes))
          clear_pending
          true
        else
          false
        end
      end

      private def enqueue_pending_wait : Bool
        return true if @pending.empty?
        rows = @pending
        bytes = @pending_bytes
        if send_command(Batch.new(rows, bytes))
          clear_pending
          true
        else
          false
        end
      end

      private def clear_pending : Nil
        @pending = [] of Store::FuzzResultWrite
        @pending_bytes = 0_i64
      end

      private def offer_live(command : Command) : Bool
        select
        when @commands.send(command)
          true
        else
          false
        end
      rescue Channel::ClosedError
        false
      end

      private def send_command(command : Command) : Bool
        @commands.send(command)
        true
      rescue Channel::ClosedError
        fail_save("the fuzz persistence worker stopped before accepting all results")
        false
      end

      private def saturated : Bool
        fail_save("fuzz persistence queue saturated (#{MAX_QUEUED_BATCHES} batches); live result was not accepted")
        false
      end

      private def barrier : Bool
        reply = Channel(Bool).new(1)
        return false unless send_command(Barrier.new(reply))
        reply.receive
      rescue Channel::ClosedError
        fail_save("the fuzz persistence worker stopped before the flush barrier")
        false
      end

      private def finish_once(sent : Int64, matched : Int64, errors : Int64, status : String,
                              finished_at : Int64) : Nil
        return if terminal?
        @terminal_requested = true
        unless @worker_started && enqueue_pending_wait
          @terminal_committed = false
          return
        end
        reply = Channel(Bool).new(1)
        unless send_command(Terminal.new(sent, matched, errors, status, finished_at, reply))
          @terminal_committed = false
          return
        end
        @terminal_committed = reply.receive
      rescue ex
        fail_save(ex.message || "could not finish the saved fuzz run")
        @terminal_committed = false
      end

      private def terminal_success : Bool
        (@terminal_committed || false) && !failed?
      end

      private def worker_loop : Nil
        while command = @commands.receive?
          begin
            break if process(command)
          rescue ex
            fail_save(ex.message || "the fuzz persistence worker stopped")
            answer_failed(command)
            break
          end
        end
      ensure
        @commands.close rescue nil
        # A worker failure must answer every buffered barrier/finish. Batch commands have no
        # waiter; dropping them is already represented by @error/save_failed.
        while command = (@commands.receive? rescue nil)
          answer_failed(command)
        end
        @worker_stopped = true
        @worker_done.send(nil) rescue nil
      end

      private def process(command : Command) : Bool
        case command
        when Batch
          if @store.insert_fuzz_results(@run_id, command.rows)
            @written += command.rows.size
          else
            fail_save("a fuzz result batch did not commit (project busy, full, or read-only)")
          end
          false
        when Barrier
          command.reply.send(!failed?)
          false
        when Terminal
          terminal = failed? ? "save_failed" : command.status
          committed = @store.finish_fuzz_run(@run_id, command.sent, command.matched,
            command.errors, terminal, command.finished_at)
          fail_save("the fuzz run summary did not commit") unless committed
          command.reply.send(committed)
          true
        else
          false
        end
      end

      private def answer_failed(command : Command?) : Nil
        case command
        when Barrier  then command.reply.send(false) rescue nil
        when Terminal then command.reply.send(false) rescue nil
        end
      end

      private def fail_save(message : String) : Nil
        @error ||= message
      end
    end
  end
end
