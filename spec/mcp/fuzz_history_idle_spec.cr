require "../spec_helper"
require "socket"

# `fuzz_start{record_history}` buffers recorded rows into a History chunk that commits once due.
# Checked only on the next result, a matched row stayed out of `fuzz_results` (while `fuzz_status`
# already counted it) for as long as the next request took. The drain's idle hook commits it.

private def slow_tail_origin(stall : Time::Span) : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = origin.accept?
      c = conn
      spawn do
        head = String.new(Gori::Proxy::Codec::Http1.read_head(c) || Bytes.empty)
        sleep stall if head.includes?("q=slow")
        c << "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nMATCHME"
        c.flush
        c.close rescue nil
      end
    end
  end
  origin
end

private def fuzz_call(tools, name, args) : JSON::Any
  r = tools.call(name, JSON.parse(args.to_json))
  fail "#{name}: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

describe "MCP fuzz_start with record_history" do
  [nil, "matched"].each do |policy|
    it "shows a finished matched row while a later request is still in flight (record_history=#{policy.inspect})" do
      origin = slow_tail_origin(1.5.seconds)
      begin
        with_store do |store|
          tools = tools_for(store)
          args = {
            "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            "url"            => "http://127.0.0.1:#{origin.local_address.port}",
            "payloads"       => %([{"list":["fast","slow"]}]),
            "match"          => {"regex" => "MATCHME"},
            "concurrency"    => 1,
            "allow_unscoped" => true,
          } of String => Hash(String, String) | Int32 | Bool | String
          args["record_history"] = policy if policy
          job = fuzz_call(tools, "fuzz_start", args)["job_id"].as_s
          sleep 600.milliseconds
          fuzz_call(tools, "fuzz_status", {"job_id" => job})["status"].as_s.should eq("running")
          fuzz_call(tools, "fuzz_results", {"job_id" => job})["results"].as_a.size.should eq(1)
          # Let the slow request land before the store closes under the job.
          deadline = Time.instant + 5.seconds
          while fuzz_call(tools, "fuzz_status", {"job_id" => job})["status"].as_s == "running" && Time.instant < deadline
            sleep 50.milliseconds
          end
        end
      ensure
        origin.close
      end
    end
  end
end
