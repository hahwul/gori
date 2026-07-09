require "../src/gori/store"

def time_ms(reps : Int32, & : ->) : Float64
  2.times { yield }
  samples = Array(Float64).new(reps)
  reps.times do
    t0 = Time.instant
    yield
    samples << (Time.instant - t0).total_milliseconds
  end
  samples.sort!
  samples[samples.size // 2]
end

path = File.tempname("gori-preview-bench", ".db")
store = Gori::Store.open(path)
body = Bytes.new(1_500_000) { |i| ((i % 26) + 97).to_u8 }
id = store.insert_flow(Gori::Store::CapturedRequest.new(
  created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
  method: "GET", target: "/big", http_version: "HTTP/1.1",
  head: "GET /big HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
store.update_response(Gori::Store::CapturedResponse.new(
  flow_id: id, status: 200,
  head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
  body: body, content_type: "text/plain"))

full_ms = time_ms(9) { store.get_flow(id) }
cap = 64 * 1024 + 1
cap_ms = time_ms(9) { store.get_flow(id, body_max: cap) }
d_full = store.get_flow(id).not_nil!
d_cap = store.get_flow(id, body_max: cap).not_nil!
puts "fixture: response_body=#{body.size} bytes"
puts "median get_flow full:              #{full_ms.round(2)} ms  (body=#{d_full.response_body.try(&.size)} B)"
puts "median get_flow body_max=#{cap}:   #{cap_ms.round(2)} ms  (body=#{d_cap.response_body.try(&.size)} B)"
puts "preview load speedup:              #{(full_ms / {cap_ms, 0.001}.max).round(1)}x"
puts "OK"
store.close
File.delete?(path)
File.delete?("#{path}-wal")
File.delete?("#{path}-shm")
