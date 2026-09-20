require "../../spec_helper"
require "../../support/probe_harness"

private def sid_dets(store, target : String)
  probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", target: target)
end

describe Gori::Probe::Passive::SessionIdInUrl do
  it "flags known framework session identifiers in the query" do
    with_store do |store|
      ["/app?JSESSIONID=0A1B2C3D", "/x?PHPSESSID=deadbeef", "/y?ASP.NET_SessionId=zz",
       "/z?ASPSESSIONIDSCASBQTC=qq", "/w?laravel_session=abc", "/p?CFID=9&CFTOKEN=8"].each do |t|
        probe_codes_of(sid_dets(store, t)).should contain("session_id_in_url")
      end
    end
  end

  it "records only the parameter name, never the value" do
    with_store do |store|
      det = sid_dets(store, "/app?JSESSIONID=SECRETVALUE123").find(&.code.==("session_id_in_url")).not_nil!
      det.evidence.should eq("jsessionid")
      det.evidence.not_nil!.should_not contain("SECRETVALUE123")
      det.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "leaves generic session names to secret_in_url (disjoint sets)" do
    with_store do |store|
      # `session`/`sessionid`/`sid` are secret_in_url's; this rule must not also fire on them.
      ["/x?session=1", "/x?sessionid=1", "/x?sid=1"].each do |t|
        probe_codes_of(sid_dets(store, t)).should_not contain("session_id_in_url")
      end
    end
  end

  it "does not flag ordinary parameters or a query-less URL" do
    with_store do |store|
      probe_codes_of(sid_dets(store, "/x?foo=bar&page=2")).should_not contain("session_id_in_url")
      probe_codes_of(sid_dets(store, "/x")).should_not contain("session_id_in_url")
    end
  end
end
