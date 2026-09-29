require "socket"

# The origin and the project a request-time macro reads (#1350), shared by the Fuzzer's and the
# Miner's specs. A real socket, because the property under test is what reaches the WIRE: a form
# token that is invalidated the moment it is redeemed.

# `GET /form` mints `T<n>` in an `X-CSRF` header; `GET /submit` answers 200 when its `X-Token` is
# a minted token with uses left and 403 otherwise. `max_uses` is how many times one token works.
class MacroTokenOrigin
  getter port : Int32
  getter forms = 0
  # {token the request carried, status answered}, in arrival order.
  getter submits = [] of {String, Int32}
  # Every request path, in arrival order — the macro's and the candidates'.
  getter paths = [] of String
  # The head of every /form request, verbatim — what a macro step actually carried.
  getter form_heads = [] of String
  # The most candidate requests (anything but /form) the origin had open at once.
  getter peak = 0
  property form_status = 200
  property? omit_token = false
  property max_uses = 1
  # How long a candidate (anything but /form) is held before it is answered.
  property submit_delay : Time::Span = Time::Span.zero
  # 1-based numbers of the /form requests that answer 500 whatever `form_status` says.
  property fail_forms = Set(Int32).new

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @uses = Hash(String, Int32).new(0)
    @minted = Set(String).new
    @form_requests = 0
    @open = 0
    spawn do
      while conn = @server.accept?
        serve_async(conn)
      end
    end
  end

  # Mint a token out of band — the "captured before the run" value a run without a macro carries.
  def mint : String
    @forms += 1
    tok = "T#{@forms}"
    @minted << tok
    tok
  end

  def close : Nil
    @server.close rescue nil
  end

  private def serve_async(conn : TCPSocket) : Nil
    spawn { serve(conn) }
  end

  private def serve(conn : TCPSocket) : Nil
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn)
    return unless head
    text = String.new(head)
    path = text.split(' ', 3)[1]? || "/"
    @paths << path
    conn << (path.starts_with?("/form") ? answer_form(text) : answer_submit(text))
    conn.flush
  rescue
  ensure
    conn.close rescue nil
  end

  private def answer_form(text : String) : String
    @form_heads << text
    @form_requests += 1
    failing = @fail_forms.includes?(@form_requests)
    return response(failing ? 500 : @form_status) if failing || @form_status >= 400
    response(200, omit_token? ? "" : "X-CSRF: #{mint}\r\n")
  end

  private def answer_submit(text : String) : String
    @open += 1
    @peak = Math.max(@peak, @open)
    Fiber.yield # a candidate that overlaps another is seen overlapping, not serialised by luck
    sleep @submit_delay if @submit_delay > Time::Span.zero
    tok = text.lines.find(&.downcase.starts_with?("x-token:")).try(&.split(':', 2).[1].strip) || ""
    ok = @minted.includes?(tok) && @uses[tok] < @max_uses
    @uses[tok] += 1 if ok
    @submits << {tok, ok ? 200 : 403}
    @open -= 1
    response(ok ? 200 : 403)
  end

  private def response(status : Int32, extra : String = "") : String
    "HTTP/1.1 #{status} #{status == 200 ? "OK" : "X"}\r\n#{extra}Content-Length: 0\r\nConnection: close\r\n\r\n"
  end
end

# The project a macro reads: a Repeater session fetching the form, an extract rule that reads
# the token out of the response, and the binding table wired the way `Session.open` wires it.
def with_macro_project(origin : MacroTokenOrigin, &)
  with_store_env do |store|
    target = "http://127.0.0.1:#{origin.port}"
    csrf = store.insert_repeater(target, "GET /form HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      false, true, nil, 0)
    store.set_repeater_name(csrf, "csrf-fetch")
    slots = Gori::SessionSlots.load(store)
    bindings = Gori::Bindings.load(store, slots)
    bindings.add("CSRF", "", Gori::ExtractKind::Header, "x-csrf").should be_nil
    Gori::Env.layer = bindings
    yield store, bindings, csrf
  end
end
