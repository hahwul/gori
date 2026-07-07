# FTS strategy A/B/C benchmark: quantifies the two axes of the FTS decision for
# gori — index build cost and on-disk size — across the realistic tokenizer /
# content choices, and confirms each still answers a MATCH.
#
#   A = trigram + content stored   (= gori today: substring search, biggest cost)
#   B = trigram + contentless      (same substring semantics, drops the redundant
#                                    body-text copy we already keep in `flows`)
#   C = unicode61 (word) + content (cheap + small, but WORD/prefix match — a
#                                    `body:tok` no longer finds "mytokenvalue")
#   D = trigram + content, 16KB cap (vs A's 64KB — only bites bodies > cap)
#
# Build: crystal build bench/fts_bench.cr -o bin/fts_bench --release
# Run:   BENCH_N=50000 BENCH_BODY=4096 bin/fts_bench
require "db"
require "sqlite3"

N     = (ENV["BENCH_N"]? || "50000").to_i
BODY  = (ENV["BENCH_BODY"]? || "4096").to_i
CAP_D = 16 * 1024

def body_text(n : Int32, seed : Int32) : String
  base = %({"id":#{seed},"token":"tok_#{seed}abcdef","name":"user#{seed}","note":"hello world "})
  String.build do |io|
    while io.bytesize < n
      io << base
    end
  end[0, n]
end

def fts_bytes(db_path : String) : Float64
  # all shadow tables live in the same file; checkpoint so the -wal is folded in.
  File.size(db_path) / 1024.0 / 1024
end

configs = [
  {"A trigram + content (today) ", "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='trigram')", 64*1024},
  {"B trigram + contentless     ", "CREATE VIRTUAL TABLE fts USING fts5(body, content='', contentless_delete=1, tokenize='trigram')", 64*1024},
  {"C unicode61 word + content  ", "CREATE VIRTUAL TABLE fts USING fts5(body)", 64*1024},
  {"D trigram + content, 16KBcap", "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='trigram')", CAP_D},
]

puts "fts bench: N=#{N} body=#{BODY}B\n"
configs.each do |(label, ddl, cap)|
  path = File.tempname("gori-fts", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&synchronous=normal")
  db.exec ddl

  t0 = Time.instant
  db.transaction do |tx|
    c = tx.connection
    (0...N).each do |i|
      txt = body_text(BODY, i)
      txt = txt[0, cap] if txt.bytesize > cap
      c.exec "INSERT INTO fts(rowid, body) VALUES (?, ?)", i, txt
    end
  end
  build_s = (Time.instant - t0).total_seconds

  # a real substring/word query + a delete (exercise contentless_delete on B)
  hits = db.scalar("SELECT count(*) FROM fts WHERE fts MATCH ?", %("tok_100")).as(Int64)
  del_ok = begin
    db.exec("DELETE FROM fts WHERE rowid = ?", 100); "ok"
  rescue ex
    "FAIL: #{ex.message}"
  end

  db.exec("PRAGMA wal_checkpoint(TRUNCATE)") rescue nil
  db.close
  size = fts_bytes(path)
  printf("  %s  build %6.2fs (%7.0f/s)   size %7.1f MB   MATCH 'tok_100' -> %d hits   delete: %s\n",
    label, build_s, N / build_s, size, hits, del_ok)
  File.delete(path) rescue nil; File.delete("#{path}-wal") rescue nil; File.delete("#{path}-shm") rescue nil
end
puts "\n(A vs B: same semantics, B drops the content copy. A vs C: C is cheap but WORD-match only.)"
