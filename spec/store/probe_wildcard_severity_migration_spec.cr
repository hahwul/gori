require "../spec_helper"

private def build_v52_probe_db(path : String) : Nil
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  begin
    Gori::Store::Schema::MIGRATIONS[0...52].each do |statements|
      statements.each { |sql| db.exec(sql) }
    end
    db.exec("PRAGMA user_version = 52")
    db.exec("INSERT INTO probe_issues (code, category, host, title, severity, first_seen, last_seen) " \
            "VALUES (?, 'headers', ?, 'CORS', ?, 1, 1)", "cors_wildcard", "medium.test", Gori::Store::Severity::Medium.value)
    db.exec("INSERT INTO probe_issues (code, category, host, title, severity, first_seen, last_seen) " \
            "VALUES (?, 'headers', ?, 'CORS', ?, 1, 1)", "cors_wildcard", "info.test", Gori::Store::Severity::Info.value)
    db.exec("INSERT INTO probe_issues (code, category, host, title, severity, first_seen, last_seen) " \
            "VALUES (?, 'headers', ?, 'CORS', ?, 1, 1)", "cors_null_origin", "other.test", Gori::Store::Severity::Medium.value)
  ensure
    db.close
  end
end

describe "wildcard CORS severity schema V53" do
  it "downgrades stored wildcard findings without changing other severities" do
    path = File.tempname("gori-cors-wildcard-v53", ".db")
    build_v52_probe_db(path)

    store = Gori::Store.open(path)
    begin
      store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
      issues = store.probe_issues
      issues.find! { |issue| issue.code == "cors_wildcard" && issue.host == "medium.test" }.severity
        .should eq(Gori::Store::Severity::Info)
      issues.find! { |issue| issue.code == "cors_wildcard" && issue.host == "info.test" }.severity
        .should eq(Gori::Store::Severity::Info)
      issues.find! { |issue| issue.code == "cors_null_origin" }.severity.should eq(Gori::Store::Severity::Medium)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
