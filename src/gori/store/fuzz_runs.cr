require "db"

module Gori
  class Store
    def insert_fuzz_run(session_id : Int64?, target : String, mode : String, total : Int64?) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO fuzz_runs (session_id, created_at, target, mode, total, sent, matched, errors, status) VALUES (?,?,?,?,?,0,0,0,'running')",
          session_id, now_us, target, mode, total)
        nil
      }
    end

    def update_fuzz_run(id : Int64, sent : Int64, matched : Int64, errors : Int64,
                        status : String, finished_at : Int64? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_runs SET sent=?, matched=?, errors=?, status=?, finished_at=? WHERE id=?",
          sent, matched, errors, status, finished_at, id)
        nil
      }
    end

    def fuzz_runs(session_id : Int64? = nil) : Array(FuzzRunRecord)
      list = [] of FuzzRunRecord
      cols = "id, session_id, created_at, finished_at, target, mode, total, sent, matched, errors, status"
      if session_id
        @db.query("SELECT #{cols} FROM fuzz_runs WHERE session_id = ? ORDER BY id DESC", session_id) { |rs| rs.each { list << read_fuzz_run(rs) } }
      else
        @db.query("SELECT #{cols} FROM fuzz_runs ORDER BY id DESC") { |rs| rs.each { list << read_fuzz_run(rs) } }
      end
      list
    end

    def insert_fuzz_result(run_id : Int64, idx : Int64, payloads : String, status : Int32?,
                           length : Int64, words : Int32, lines : Int32, duration_us : Int64,
                           error : String?, matched : Bool, extracted : String?,
                           request : Bytes? = nil, response_head : Bytes? = nil, response_body : Bytes? = nil) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO fuzz_results (run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, extracted, request, response_head, response_body) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
          run_id, idx, payloads, status, length, words, lines, duration_us, error, matched ? 1 : 0, extracted, request, response_head, response_body)
        nil
      }
    end

    def fuzz_results(run_id : Int64, limit : Int32 = 200, offset : Int32 = 0) : Array(FuzzResultRecord)
      list = [] of FuzzResultRecord
      @db.query("SELECT id, run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, extracted, request, response_head, response_body FROM fuzz_results WHERE run_id = ? ORDER BY idx LIMIT ? OFFSET ?", run_id, limit, offset) do |rs|
        rs.each { list << read_fuzz_result(rs) }
      end
      list
    end

    private def read_fuzz_run(rs : DB::ResultSet) : FuzzRunRecord
      FuzzRunRecord.new(
        rs.read(Int64), rs.read(Int64?), rs.read(Int64), rs.read(Int64?), rs.read(String),
        rs.read(String), rs.read(Int64?), rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String))
    end

    private def read_fuzz_result(rs : DB::ResultSet) : FuzzResultRecord
      FuzzResultRecord.new(
        rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(Int32?),
        rs.read(Int64), rs.read(Int32), rs.read(Int32), rs.read(Int64), rs.read(String?),
        rs.read(Int32) != 0, rs.read(String?), rs.read(Bytes?), rs.read(Bytes?), rs.read(Bytes?))
    end
  end
end
