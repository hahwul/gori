require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

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

private def render_decode_lens(token : String) : MemoryBackend
  b = MemoryBackend.new(W, H)
  JwtView.new.render_decode(Screen.new(b), Rect.new(0, 0, W, H),
    input: TextArea.new(token), input_mode: InputMode::Read,
    input_read: TextReadState.new, decoded: "", attacks: [] of Gori::Jwt::Attack,
    pane: :input, focused: true, lens_chord: "^T")
  b
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

    render_decode_lens(jwe).contains?("encrypted JWE").should be_true
    render_decode_lens(jwe).contains?("paste a JWT into INPUT").should be_false
    # An ordinary token with no payloads yet (an empty INPUT, a half-typed one) keeps the
    # instruction it always had — the JWE line must not swallow that case.
    render_decode_lens("").contains?("paste a JWT into INPUT").should be_true
    render_decode_lens(jws).contains?("paste a JWT into INPUT").should be_true
  end
end
