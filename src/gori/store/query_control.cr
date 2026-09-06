require "sqlite3"

lib LibSQLite3
  fun progress_handler = sqlite3_progress_handler(db : SQLite3, steps : Int32,
                                                  callback : Void* -> Int32, data : Void*) : Void
end

module Gori
  class Store
    class QueryCancelled < Exception
    end

    # Opt-in cooperative reads (P6). Only the query's exclusively checked-out
    # connection gets a handler; the writer and other readers never inherit it.
    class QueryControl
      STEPS = 1000
      SLICE = 4.milliseconds

      getter? cancelled = false
      @last_yield = Time.instant

      def cancel : Nil
        @cancelled = true
      end

      def check! : Nil
        raise QueryCancelled.new("query cancelled") if @cancelled
      end

      def progress : Int32
        return 1 if @cancelled
        if Time.instant - @last_yield >= SLICE
          Fiber.yield
          @last_yield = Time.instant
        end
        @cancelled ? 1 : 0
      end

      CALLBACK = ->(data : Void*) { Box(QueryControl).unbox(data).progress }
    end

    # Count operations, not just tokens: callers may share a cancellation token
    # across reads. Finishing one must not hide the others from Store#close.
    @controlled_reads = Hash(QueryControl, Int32).new(0)

    private def controlled_query(sql : String, args : Array(DB::Any), control : QueryControl?,
                                 & : DB::ResultSet ->) : Nil
      if control
        raise QueryCancelled.new("store closed") if @closed
        control.check!
        @controlled_reads[control] += 1
      end
      begin
        @db.using_connection do |conn|
          control.try(&.check!)
          sqlite = conn.as(SQLite3::Connection)
          begin
            sqlite.gori_query_control(control) if control
            conn.query(sql, args: args) { |rs| yield rs }
            control.try(&.check!)
          ensure
            # ResultSet#close resets interrupted statements before this handler is
            # removed, so cached statements remain reusable and safe to finalize.
            sqlite.gori_query_control(nil) if control
          end
        end
      rescue ex
        control.try(&.check!)
        raise ex
      ensure
        if control
          remaining = @controlled_reads[control] - 1
          if remaining == 0
            @controlled_reads.delete(control)
          else
            @controlled_reads[control] = remaining
          end
        end
      end
    end
  end
end

class SQLite3::Connection
  # Keep the boxed callback context rooted until SQLite no longer holds its pointer.
  @gori_query_context : Pointer(Void) = Pointer(Void).null

  def gori_query_control(control : Gori::Store::QueryControl?) : Nil
    if control
      @gori_query_context = Box.box(control)
      LibSQLite3.progress_handler(@db, Gori::Store::QueryControl::STEPS,
        Gori::Store::QueryControl::CALLBACK, @gori_query_context)
    else
      LibSQLite3.progress_handler(@db, 0, Gori::Store::QueryControl::CALLBACK, Pointer(Void).null)
      @gori_query_context = Pointer(Void).null
    end
  end
end
