require "db"

module Gori
  class Store
    # --- gRPC server-reflection cache (#827) ---------------------------------------------
    #
    # One row per reflected target, holding the FileDescriptorSet gori synthesized from what
    # the server returned. The point of persisting it is P4: reflection is an outbound request
    # the operator asked for, so the answer has to OUTLIVE the asking — every flow on that host
    # then renders through the schema without gori reaching out again, and reopening the
    # project does not silently re-arm a network call.
    #
    # No cap and no expiry. A descriptor set is bounded by `Reflection::MAX_BYTES` on the way
    # in, targets are added one deliberate action at a time, and a STALE schema is a lens the
    # operator chose — re-running reflection replaces the row, and `forget` deletes it. An
    # automatic refresh would be exactly the unasked-for outbound request this feature must
    # not make.

    # One cached fetch. `descriptor` is the byte-exact FileDescriptorSet (P7); everything
    # else is what the settings row and `gori run grpc schema` print about where it came from.
    record GrpcReflection,
      target : String,
      service : String,
      fetched_at : Int64,
      services : Int32,
      files : Int32,
      descriptor : Bytes

    # Every cached target, oldest fetch first — the order they merge into the project schema,
    # so a target reflected more recently wins a name collision with one reflected earlier.
    def grpc_reflections : Array(GrpcReflection)
      list = [] of GrpcReflection
      @db.query("SELECT target, service, fetched_at, services, files, descriptor FROM grpc_reflection ORDER BY fetched_at, target") do |rs|
        rs.each do
          list << GrpcReflection.new(rs.read(String), rs.read(String), rs.read(Int64),
            rs.read(Int64).to_i32, rs.read(Int64).to_i32, rs.read(Bytes))
        end
      end
      list
    rescue
      # A project opened against an older schema, or a read that lost its connection, must
      # not stop the project from opening — it degrades to "no reflected schema", which is
      # exactly the state every project starts in.
      [] of GrpcReflection
    end

    # Insert or REPLACE this target's descriptors. Replace, not merge: a second fetch is the
    # operator asking the server again, and the answer supersedes — merging would leave a
    # message the server has since deleted in the lens forever.
    # Returns whether the write committed.
    def put_grpc_reflection(target : String, service : String, services : Int32, files : Int32,
                            descriptor : Bytes, fetched_at : Int64 = Time.utc.to_unix_ms * 1000_i64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("INSERT INTO grpc_reflection (target, service, fetched_at, services, files, descriptor) " \
               "VALUES (?, ?, ?, ?, ?, ?) " \
               "ON CONFLICT(target) DO UPDATE SET service = excluded.service, " \
               "fetched_at = excluded.fetched_at, services = excluded.services, " \
               "files = excluded.files, descriptor = excluded.descriptor",
          target, service, fetched_at, services.to_i64, files.to_i64, descriptor)
        nil
      }
    end

    # Drop one target's cache. No-op on an unknown target; returns whether the write committed.
    def delete_grpc_reflection(target : String) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM grpc_reflection WHERE target = ?", target)
        nil
      }
    end

    # Drop every cached target.
    def clear_grpc_reflections : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM grpc_reflection")
        nil
      }
    end
  end
end
