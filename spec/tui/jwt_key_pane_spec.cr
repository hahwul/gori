require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_host"
require "file_utils"

include Gori::Tui

# `cur` and `set_alg` are private controller glue; reopen for bare-call wrappers rather than
# widen the real API (the shape `spec/cli/run/jwt_spec.cr` uses for `jwt_token_input`).
module Gori::Tui
  class JwtController
    def cur_for_spec : JwtSession
      cur
    end

    def set_alg_for_spec(s : JwtSession, alg : String) : Nil
      set_alg(s, alg)
    end
  end
end

# The two places the JWT tab has to say something different now that a token can be signed
# asymmetrically or arrive encrypted:
#
#   * the SECRET card is a KEY card for RS/PS/ES/EdDSA. Its field is one line, and a PEM is
#     many, so the placeholder has to name the PATH form or the pane is a dead end.
#   * ATTACKS is empty for a JWE, and "(paste a JWT into INPUT…)" would be wrong twice —
#     the operator did paste one, and there is nothing to generate from it.
private W = 100
private H =  34

private def render_encode_lens(alg : String, secret : String = "") : MemoryBackend
  b = MemoryBackend.new(W, H)
  JwtView.new.render_encode(Screen.new(b), Rect.new(0, 0, W, H),
    header: TextArea.new(%({"typ":"JWT"})), payload: TextArea.new("{}"),
    secret: secret, secret_cx: 0, secret_pre: "", alg: alg,
    output: "", output_ok: true, pane: :header, focused: true, lens_chord: "^T")
  b
end

private def render_decode_lens(token : String, input_jwe : Bool = false) : MemoryBackend
  b = MemoryBackend.new(W, H)
  JwtView.new.render_decode(Screen.new(b), Rect.new(0, 0, W, H),
    input: TextArea.new(token), input_mode: InputMode::Read,
    input_read: TextReadState.new, decoded: "", attacks: [] of Gori::Jwt::Attack,
    input_jwe: input_jwe, pane: :input, focused: true, lens_chord: "^T")
  b
end

private KEY_PANE_CA = File.tempname("gori-jwt-keypane-ca")

private def with_jwt_key_controller(&)
  root = File.tempname("gori-jwt-keypane")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("jwtkeypane")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(KEY_PANE_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield JwtController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "JWT tab: the KEY card and the ATTACKS empty state" do
  it "titles the card SECRET for an HMAC alg and KEY for an asymmetric one" do
    render_encode_lens("HS256").contains?("SECRET").should be_true
    %w[RS256 PS384 ES512 EdDSA].each do |alg|
      b = render_encode_lens(alg)
      b.contains?("KEY").should be_true
      b.contains?("SECRET").should be_false
    end
  end

  it "names the PEM path form when the KEY card is empty" do
    # A PEM is multi-line and this field is one line, so an operator who is told nothing here
    # has no way to discover that the path form is what the engine wants.
    render_encode_lens("ES256").contains?("(path to a PEM private key)").should be_true
    render_encode_lens("HS256").contains?("(empty key)").should be_true
  end

  it "keeps alg=none's own hint, which outranks both" do
    b = render_encode_lens("none")
    b.contains?("alg=none is unsigned").should be_true
    b.contains?("(path to a PEM private key)").should be_false
  end

  it "shows the typed value rather than a placeholder once the card is filled" do
    render_encode_lens("ES256", "/keys/id.pem").contains?("/keys/id.pem").should be_true
  end

  it "explains an empty ATTACKS list differently for an encrypted token" do
    jws = Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k")
    jwe = "#{Gori::Jwt.b64url(%({"alg":"RSA-OAEP","enc":"A256GCM"}))}.d3JhcA.aXY.Y2lwaGVy.dGFn"

    render_decode_lens(jwe, input_jwe: true).contains?("encrypted JWE").should be_true
    render_decode_lens(jwe, input_jwe: true).contains?("paste a JWT into INPUT").should be_false
    # An ordinary token with no payloads yet (an empty INPUT, a half-typed one) keeps the
    # instruction it always had — the JWE line must not swallow that case.
    render_decode_lens("").contains?("paste a JWT into INPUT").should be_true
    render_decode_lens(jws).contains?("paste a JWT into INPUT").should be_true
  end

  it "decides the hint from cached state, not by parsing the token on the render path" do
    # The view is a painter: `input_jwe` is recomputed on EDIT beside `attacks`. If the view
    # re-derived it from `input`, this call — a real JWE with the flag off — would still say
    # "encrypted JWE", and the pane would be parsing a token on every frame while one is
    # being typed, which is exactly when the ATTACKS list is empty.
    jwe = "#{Gori::Jwt.b64url(%({"alg":"dir","enc":"A256GCM"}))}.d3JhcA.aXY.Y2lwaGVy.dGFn"
    Gori::Jwt::Jwe.jwe?(jwe).should be_true
    render_decode_lens(jwe, input_jwe: false).contains?("paste a JWT into INPUT").should be_true
  end
end

# The KEY/SECRET card is ONE field whose meaning comes from the alg, so an alg change is the
# moment its content stops being meaningful. Carried across in silence, a typed PEM path
# became a fourteen-byte HMAC secret and OUTPUT showed a token signed with a filename.
describe "JWT tab: an alg change across the HMAC/asymmetric boundary" do
  it "drops the key field, and keeps it when the change stays on one side" do
    with_jwt_key_controller do |c, _|
      s = c.cur_for_spec
      s.alg = "RS256"
      s.secret = "/keys/id.pem"
      s.secret_cx = 12
      c.set_alg_for_spec(s, "HS256")
      s.secret.should eq("") # a PEM path is not an HMAC secret
      s.secret_cx.should eq(0)

      s.secret = "hunter2"
      c.set_alg_for_spec(s, "HS512") # HS -> HS: same meaning, same value
      s.secret.should eq("hunter2")

      c.set_alg_for_spec(s, "ES256") # HS -> asymmetric: crosses
      s.secret.should eq("")

      s.secret = "/keys/id.pem"
      c.set_alg_for_spec(s, "EdDSA") # asymmetric -> asymmetric: stays
      s.secret.should eq("/keys/id.pem")
    end
  end

  it "says so, rather than clearing the field in silence" do
    with_jwt_key_controller do |c, host|
      s = c.cur_for_spec
      s.alg = "HS512"
      s.secret = "hunter2"
      c.cycle_alg # HS512 -> RS256, crosses
      host.statuses.last.should contain("key cleared")

      c.cycle_alg # RS256 -> RS384, does not cross
      host.statuses.last.should_not contain("key cleared")
    end
  end

  it "load_decoded adopts a token's alg through the same guard" do
    # Here the operator pressed no key for the alg change at all — a token they merely loaded
    # would otherwise reinterpret a key they had typed.
    with_jwt_key_controller do |c, _|
      s = c.cur_for_spec
      s.alg = "ES256"
      s.secret = "/keys/id.pem"
      s.input.set_text(Gori::Jwt.encode("{}", %({"s":1}), "HS256", "k"))
      c.load_decoded
      s.alg.should eq("HS256")
      s.secret.should eq("")
    end
  end
end
