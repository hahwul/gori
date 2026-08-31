require "file_utils"
require "random/secure"
require "../paths"
require "../open_lock"
require "./persistence"

module Gori
  module Fuzz
    # Private, controller-owned temporary result database. One lazily-opened Store serves every
    # run handle in this Spool; run ids keep their rows isolated while avoiding one SQLite writer
    # fiber and database per tab. Closing the spool closes SQLite before removing the whole tree.
    class Spool
      DIR_PREFIX  = "fuzz-"
      DB_NAME     = "results.db"
      STALE_AFTER = 24.hours

      getter directory : String?

      def initialize(@root : String = File.join(Paths.home_dir, "spool"))
        @directory = nil.as(String?)
        @store = nil.as(Store?)
        @runs = [] of Run
        @cleanup_workers = 0
        @cleanup_cancelled = false
        @closed = false
      end

      # Starts one isolated temporary run. Session ids are intentionally stripped: a spool DB
      # has no corresponding fuzz_sessions row and must never claim a durable project relation.
      def start(meta : SavedRunMeta, initial_status : String = "running") : Run
        raise Gori::Error.new("fuzz spool is closed") if @closed
        persistence = Persistence.new(store, temporary_meta(meta), initial_status: initial_status)
        run = Run.new(store, persistence)
        @runs << run
        run
      end

      # Remove one replaced/saved run without tearing down the controller's shared temp Store.
      # Detach immediately, then reap bounded child batches on a fiber. The shared writer can
      # interleave another tab's live batches between those commits instead of being monopolized
      # by one unbounded DELETE transaction.
      def delete(run : Run) : Bool
        return true unless @runs.includes?(run)
        run.close
        @runs.delete(run)
        start_cleanup(run.run_id) if @store
        true
      rescue ex
        ::Log.warn { "could not schedule fuzz spool cleanup: #{ex.message}" }
        false
      end

      # Idempotent teardown. Abort first so each Persistence worker leaves its queue and no
      # waiter can outlive the Store; then close SQLite so WAL/SHM and the open lock are released
      # before deleting their directory.
      def close : Nil
        return if @closed
        @closed = true
        @cleanup_cancelled = true
        @runs.each(&.close)
        while @cleanup_workers > 0
          sleep 1.millisecond
        end
        @store.try(&.close)
      ensure
        if directory = @directory
          FileUtils.rm_rf(directory)
        end
        @store = nil
        @directory = nil
      end

      class Run
        getter persistence : Persistence
        getter accepted_bytes = 0_i64
        getter accepted_rows = 0_i64

        protected def initialize(@store : Store, @persistence : Persistence)
        end

        def run_id : Int64
          @persistence.run_id
        end

        def error : String?
          @persistence.error
        end

        def written : Int64
          @persistence.written
        end

        def failed? : Bool
          @persistence.failed?
        end

        def finished? : Bool
          @persistence.terminal?
        end

        def append(result : Result) : Bool
          return false if failed? || finished?
          row = Persistence.write_row(result)
          return false unless @persistence.try_append(row)
          @accepted_rows += 1
          @accepted_bytes += Persistence.row_bytes(row)
          true
        end

        def flush : Bool
          @persistence.flush
        end

        def finish(sent : Int64, matched : Int64, errors : Int64, status : String,
                   finished_at : Int64 = Time.utc.to_unix_ms * 1000_i64) : Bool
          @persistence.finish(sent, matched, errors, status, finished_at)
        end

        def abort(sent : Int64 = @persistence.written, matched : Int64 = 0_i64,
                  errors : Int64 = 0_i64,
                  finished_at : Int64 = Time.utc.to_unix_ms * 1000_i64,
                  reason : String = "fuzz spool run aborted") : Bool
          @persistence.abort(sent, matched, errors, finished_at, reason)
        end

        def close : Nil
          @persistence.close
        end

        # Full-content keyset stream in stable idx/id order. Yield Store records rather than
        # rebuilding Fuzz::Result so a later permanent append copies every byte exactly.
        def each_result(batch_size : Int32 = 1000,
                        &block : Store::FuzzResultRecord ->) : Nil
          raise Gori::Error.new("finish the fuzz spool run before reading it") unless finished?
          @store.each_fuzz_result(run_id, batch_size, &block)
        end
      end

      private def start_cleanup(run_id : Int64) : Nil
        store = @store || return
        @cleanup_workers += 1
        spawn(name: "gori-fuzz-spool-cleanup") do
          loop do
            break if @cleanup_cancelled
            batch = store.cleanup_fuzz_run_batch(run_id, allow_active: true)
            unless batch.ok
              ::Log.warn { "fuzz spool run ##{run_id} cleanup stopped; directory teardown will remove it" }
              break
            end
            break if batch.done
            Fiber.yield
          end
        rescue ex
          ::Log.warn { "fuzz spool run ##{run_id} cleanup failed: #{ex.message}" }
        ensure
          @cleanup_workers -= 1
        end
      end

      private def store : Store
        if opened_store = @store
          return opened_store
        end

        Paths.ensure_dir(@root)
        reap_stale_directories
        directory = claim_directory
        db_path = File.join(directory, DB_NAME)
        begin
          opened = Store.open(db_path, retention_flows: Store::RETENTION_UNLIMITED,
            background_index: false)
          @directory = directory
          @store = opened
        rescue ex
          FileUtils.rm_rf(directory)
          raise ex
        end
      end

      # Crash leftovers contain captured secrets. Reap only old directories whose Store open
      # lock can be taken exclusively; a live controller keeps the shared lock for its whole
      # lifetime, so concurrent gori processes are never removed.
      private def reap_stale_directories : Nil
        Dir.each_child(@root) do |name|
          next unless name.starts_with?(DIR_PREFIX)
          path = File.join(@root, name)
          info = File.info?(path)
          next unless info && info.directory?
          next if Time.utc - info.modification_time < STALE_AFTER
          db_path = File.join(path, DB_NAME)
          lock = OpenLock.try_exclusive(db_path)
          next unless lock
          begin
            FileUtils.rm_rf(path)
          ensure
            lock.close
          end
        end
      rescue
        # Cleanup is best-effort; inability to inspect an old path must not disable a new run.
      end

      private def claim_directory : String
        loop do
          path = File.join(@root, "#{DIR_PREFIX}#{Process.pid}-#{Random::Secure.hex(12)}")
          begin
            Dir.mkdir(path, Paths::DIR_MODE)
            File.chmod(path, Paths::DIR_MODE)
            return path
          rescue File::AlreadyExistsError
            # Secure random collision or another controller won this candidate; retry atomically.
          end
        end
      end

      private def temporary_meta(meta : SavedRunMeta) : SavedRunMeta
        SavedRunMeta.new(nil, meta.target, meta.mode, meta.total,
          created_at: meta.created_at, http2: meta.http2, sni: meta.sni,
          tls_preset: meta.tls_preset, websocket: meta.websocket, surface: meta.surface,
          source_ref: meta.source_ref)
      end
    end
  end
end
