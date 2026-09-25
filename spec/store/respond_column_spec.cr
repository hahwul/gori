require "../spec_helper"

# The short-circuit sub-kind's columns (#1237, schema V33). A row written before them was an
# inline stub or, when it named a `body_file`, a file stub — and the migration says so, so a
# listing's `respond` is truthful for every rule a project already holds.
describe "Store::Schema V33" do
  # Built at V32 — the version main shipped before these columns — so a project a current build
  # already opened gains them on its next open.
  it "adds the columns to a V32 database and marks a stub with a body file as a file stub" do
    path = File.tempname("gori-v33", ".db")
    begin
      DB.open("sqlite3:#{path}") do |db|
        db.using_connection do |c|
          Gori::Store::Schema::MIGRATIONS[0...32].each { |stmts| stmts.each { |sql| c.exec(sql) } }
          c.exec("PRAGMA user_version = 32")
          {
            {"short_circuit", "/tmp/logo.png"}, # 1: a file stub
            {"short_circuit", ""},              # 2: an inline stub
            {"replace", "/tmp/ignored"},        # 3: not a stub at all
          }.each do |(op, body_file)|
            c.exec("INSERT INTO match_rules (enabled, target, pattern, replacement, position, op, body_file) " \
                   "VALUES (1, 'request', '/x', '200 OK', 0, ?, ?)", op, body_file)
          end
        end
      end
      store = Gori::Store.open(path)
      begin
        store.match_rules.map { |r| {r.id, r.respond_label, r.respond_args} }.should eq([
          {1_i64, "file", ""}, {2_i64, "inline", ""}, {3_i64, "inline", ""},
        ])
      ensure
        store.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
