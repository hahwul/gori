require "../spec_helper"

private alias R = Gori::Repeater

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# `Settings` env vars are a process-wide singleton — set, yield, always restore.
private def with_env_vars(pairs : Array({String, String}), &)
  saved_global = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = pairs
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  yield
ensure
  Gori::Settings.env_vars = saved_global || [] of {String, String}
  Gori::Settings.project_env_vars = saved_project || [] of {String, String}
  Gori::Settings.env_prefix = saved_prefix || "$"
end

private def wire_of(options : R::PlanOptions) : String
  String.new(R::Plan.build(options, ungated).bytes)
end

# PROVENANCE — `PlanOptions#evidence?`.
#
# The axis behind most of this round's replay defects: draft-time policies (the
# unresolved-`$KEY` refusal, the head's CRLF normalization) exist for a request the operator
# is AUTHORING in a line-buffer editor, and running them on stored evidence changes bytes
# nobody typed. One signal rather than several, because both were off for the same reason and
# the surfaces had already drifted on which of them they remembered to turn off.
describe "Gori::Repeater::PlanOptions#evidence?" do
  describe "the unresolved-$KEY refusal" do
    # OData (`$filter`/`$top`), MongoDB (`$where`), JSONPath, `$IFS` shell probes and
    # `$user.name` SSTI payloads all live in ordinary captured heads. Refusing them made every
    # such capture unreplayable, and the refusal's own remedy ("set the variable") would have
    # SUBSTITUTED a value — i.e. sent a different request than the one captured.
    it "does not fire on evidence" do
      raw = "GET /api?$filter=name%20eq%20x&$top=10 HTTP/1.1\r\nHost: h\r\n" \
            "X-Cmd: ;cat$IFS/etc/passwd\r\nCookie: tmpl=$user.name\r\n\r\n"
      with_env_vars([] of {String, String}) do
        out = wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true))
        out.should eq(raw)
      end
    end

    # INVERTED for the owner's round-7 policy: the refusal used to fire on a DRAFT and this
    # pinned it. A `$NAME` with no value is a literal string on the wire now, whatever its
    # provenance — so a draft ships `$filter` exactly as an evidence replay does. What
    # `evidence?` still decides is EXPANSION, which the example above and the CRLF block
    # below both pin.
    it "does not fire on a DRAFT either — the token ships literally" do
      raw = "GET /api?$filter=x HTTP/1.1\r\nHost: h\r\n\r\n"
      with_env_vars([] of {String, String}) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h")).should eq(raw)
      end
    end

    # …and the COMPLEMENT that keeps the two apart: with a VALUE, a draft expands and an
    # evidence replay still does not.
    it "expands a draft but never evidence when the token HAS a value" do
      raw = "GET /api?$filter=x HTTP/1.1\r\nHost: h\r\n\r\n"
      with_env_vars([{"filter", "PWNED"}]) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h"))
          .should eq("GET /api?PWNED=x HTTP/1.1\r\nHost: h\r\n\r\n")
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true)).should eq(raw)
      end
    end
  end

  describe "the head's CRLF normalization" do
    # A bare-LF header terminator is a front-end/back-end desync primitive gori can already
    # PRODUCE (MCP `verbatim`) and stores byte-exact. Promoting it to CRLF on the way out
    # silently destroys the primitive while still reporting a clean send.
    it "leaves a captured bare-LF head exactly as captured" do
      raw = "POST /lf HTTP/1.1\nHost: h\nContent-Length: 5\n\nhello"
      with_env_vars([] of {String, String}) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true)).should eq(raw)
      end
    end

    it "still promotes a DRAFT's bare LFs, which come from the editor's line buffer" do
      raw = "POST /lf HTTP/1.1\nHost: h\nContent-Length: 5\n\nhello"
      with_env_vars([] of {String, String}) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false)).should eq("POST /lf HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")
      end
    end
  end

  # The third draft-time policy, and the one round 2 left running: `$KEY` SUBSTITUTION.
  #
  # This block used to assert the opposite ("still expands a resolvable $KEY in evidence
  # bytes"), on the theory that a surface might have merged operator-typed overrides into
  # these bytes and those still had to expand. The theory was right and the seam was wrong:
  # by the time the builder sees one merged wire, nothing can tell the operator's bytes from
  # the capture's — so the expansion also ran over the CAPTURE, and a project that happened
  # to define an ordinary name (`filter`, `top`, `where`, `token`, `user`) rewrote the stored
  # request and re-framed its Content-Length to match, silently. Meanwhile MCP's flow path
  # reached the intended end state by a DIFFERENT mechanism (`expand_request: false`) and did
  # not, so the two headless surfaces sent different requests from the same flow id.
  #
  # A surface that merges overrides now expands them at ITS OWN merge seam, where it still
  # knows whose bytes are whose — see `spec/cli/run/repeater_headers_spec.cr`.
  describe "$KEY substitution" do
    it "does not substitute a project value into evidence, even when the name resolves" do
      raw = "GET /api?$filter=name%20eq%20x&$top=10 HTTP/1.1\r\nHost: h\r\n\r\n"
      with_env_vars([{"filter", "PWNED"}, {"top", "9"}]) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true)).should eq(raw)
      end
    end

    it "does not re-frame a captured Content-Length over a body it did not change" do
      raw = "POST /bk HTTP/1.1\r\nHost: h\r\nContent-Length: 22\r\n\r\n{\"q\":\"$where 1==1 ab\"}\n"
      with_env_vars([{"where", "XX"}]) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, resync_cl_after_expansion: true, evidence: true)).should eq(raw)
      end
    end

    it "still substitutes in a DRAFT, which is the whole point of the syntax there" do
      raw = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $TOK\r\n\r\n"
      with_env_vars([{"TOK", "s3cr3t"}]) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false))
          .should eq("GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer s3cr3t\r\n\r\n")
      end
    end

    # `expand_request?` is still consulted for the version-line downgrade, which is NOT a
    # draft policy — a captured h2 flow replayed down an h1 socket must not put `HTTP/2` on
    # the request line whatever its provenance, and `evidence?` must not silently disable it.
    it "still downgrades an h2 version line on evidence bytes" do
      raw = "GET /a HTTP/2\r\nHost: h\r\n\r\n"
      with_env_vars([] of {String, String}) do
        wire_of(R::PlanOptions.new([raw.to_slice], target: "http://h",
          auto_content_length: false, evidence: true))
          .should eq("GET /a HTTP/1.1\r\nHost: h\r\n\r\n")
      end
    end
  end
end
