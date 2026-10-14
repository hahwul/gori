require "../../spec_helper"

# JsScan is pure (no Store/Scope), so this needs no flow harness — it drives the lexers and
# the source↔sink correlator directly. Everything here is deterministic: the two properties
# being pinned are "does not crash" and "offsets stay aligned", never a timing.

private alias JsScan = Gori::Probe::Passive::JsScan

# Nesting deeper than MAX_INTERP_DEPTH, UNTERMINATED so no closing delimiters are needed —
# the recursion happens on the way in, which is what made 3 bytes per level enough to blow
# an 8 MiB fiber stack from a single 256 KiB response body.
private def deep_unterminated(levels : Int32) : String
  "x=" + ("`${" * levels)
end

private def deep_terminated(levels : Int32) : String
  "x=" + ("`${" * levels) + "1" + ("}`" * levels) + ";"
end

describe Gori::Probe::Passive::JsScan do
  describe "template-literal nesting depth guard" do
    # Regression: `x=` + "`${" * 87381 (what CLIENT_BODY_CAP / 3 allows) recursed one frame per
    # level and killed the PROCESS — a Crystal stack overflow is a fatal signal, so the
    # Analyzer's per-flow `rescue` could not contain it. Well past both the cap and the old
    # ~87k-frame limit here, so it fails loudly if the guard is ever removed.
    it "survives nesting far deeper than a response body could carry" do
      src = deep_unterminated(200_000)
      JsScan.strip(src).should_not be_empty
      JsScan.strip_comments(src).should_not be_empty
    end

    it "survives deep TERMINATED nesting too (the copy_/emit_ interpolation pair)" do
      src = deep_terminated(100_000)
      JsScan.strip(src).should_not be_empty
      JsScan.strip_comments(src).should_not be_empty
    end

    # The guard blanks the rest of the fragment rather than declining to descend in place, so
    # the one-char-in-one-char-out invariant the whole file rests on must still hold. This is
    # what keeps source_in_window's window arithmetic meaningful.
    it "preserves offsets when the guard trips" do
      {deep_unterminated(200_000), deep_terminated(100_000)}.each do |src|
        JsScan.strip(src).size.should eq(src.size)
        JsScan.strip_comments(src).size.should eq(src.size)
      end
    end

    # Nesting a real bundle actually uses must keep working — the guard must not blank code
    # that sits under the cap.
    it "still correlates a source through ordinary shallow interpolation" do
      code = JsScan.strip(%(o.innerHTML = `hello ${location.hash} there`;))
      JsScan.source_sink_pairs(code).should eq([{"location.hash", "innerHTML"}])
    end

    it "still correlates a source nested a few interpolations deep" do
      code = JsScan.strip(%(o.innerHTML = `a${`b${location.hash}c`}d`;))
      JsScan.source_sink_pairs(code).should eq([{"location.hash", "innerHTML"}])
    end
  end

  # `strip` and `strip_comments` are two VIEWS of one walk (`strip_both`): the lexer consumes a
  # script exactly once and emits the strings-blanked projection into one builder and the
  # comments-only projection into the other. So the property to pin is that the fused walk still
  # produces what two separate walks produced — a token consumed on one side but not the other
  # would desync the two views' offsets, and DOM-XSS's window arithmetic is measured against
  # those offsets.
  describe ".strip_both" do
    # Every token kind in one fragment: a line comment, a block comment, an escaped quote, a URL
    # literal whose `//` must NOT read as a comment, and a template with a nested interpolation.
    fragment = %(a = "x//y"; /* c */ b = 'it\\'s'; t = `p ${loc + "q"} s`; // tail\nz = 1;)

    it "blanks string contents on one side and keeps them on the other" do
      code, kept = JsScan.strip_both(fragment)
      # The strings-blanked view: delimiters kept, contents gone, `${…}` still readable as code.
      code.includes?("x//y").should be_false
      code.includes?("loc + ").should be_true
      # The comments-only view: string contents survive, comments do not.
      kept.includes?("x//y").should be_true
      kept.includes?("/* c */").should be_false
      kept.includes?("// tail").should be_false
      # Both are offset-preserving, which is the whole contract.
      code.size.should eq(fragment.size)
      kept.size.should eq(fragment.size)
    end

    it "returns exactly what the two separate entry points return" do
      JsScan.strip_both(fragment).should eq({JsScan.strip(fragment), JsScan.strip_comments(fragment)})
    end

    it "agrees with the separate entry points over randomised token soup" do
      # Bare delimiters, escapes and interpolation openers in every order — the shapes that
      # expose a desync, which hand-written samples reliably miss.
      alphabet = ['a', '/', '*', '\'', '"', '`', '$', '{', '}', '\\', '\n', ';', 'é']
      rng = Random.new(20_260_912)
      2_000.times do
        src = String.build { |io| (rng.rand(1..40)).times { io << alphabet[rng.rand(alphabet.size)] } }
        JsScan.strip_both(src).should eq({JsScan.strip(src), JsScan.strip_comments(src)})
      end
    end

    it "handles an empty script without lexing it" do
      JsScan.strip_both("").should eq({"", ""})
    end
  end

  # A regex literal's `\/\/` or `"` used to open a comment or a string and blank the rest of a
  # one-line minified bundle (axios' isAbsoluteURL, lodash's escape table).
  describe "regex literals" do
    it "keeps a regex verbatim and does not let it open a comment or a string" do
      src = %(function i(e){return/^([a-z][a-z\\d+\\-.]*:)?\\/\\//i.test(e)};el.innerHTML=location.hash)
      JsScan.strip(src).should eq(src)
      JsScan.source_sink_pairs(JsScan.strip(src)).should eq([{"location.hash", "innerHTML"}])
      src = %(var E=/[&<>"']/g;fetch("/a/"+location.hash.slice(1)))
      JsScan.request_source_pairs(JsScan.strip(src)).should eq([{"location.hash", "fetch"}])
      # A `/` inside a class does not close it; an escaped one does not either.
      JsScan.strip(%(x=/[/"]\\/"/;y="z")).should eq(%(x=/[/"]\\/"/;y=" "))
    end

    it "leaves division as code" do
      JsScan.strip(%(x=a/b/c;y="//s")).should eq(%(x=a/b/c;y="   "))
      JsScan.strip(%(x=(a)/2/"q";)).should eq(%(x=(a)/2/" ";))
      JsScan.strip(%(x=i++/2/"q";)).should eq(%(x=i++/2/" ";))
      JsScan.strip(%(x=/r/g/"q";)).should eq(%(x=/r/g/" ";))
    end

    it "reads a raw JSX closing tag as markup, not a regex" do
      src = "return <div>{x}</div>; // it's fine\nel.innerHTML = location.hash;"
      JsScan.source_sink_pairs(JsScan.strip(src)).should eq([{"location.hash", "innerHTML"}])
    end

    it "stops an unterminated regex at the end of its line" do
      JsScan.strip(%(x=/abc\ny="q")).should eq(%(x=/abc\ny=" "))
    end
  end

  # source_in_window works on BYTE offsets: char-index slicing was O(1) only while the script
  # stayed all-ASCII, and one non-ASCII byte turned every window slice into a walk from the
  # start of the string (measured 9ms -> 1765ms per flow). The pairs must be identical either
  # way — that equivalence is what the byte-offset rewrite had to preserve, and it is the part
  # a spec can pin. The COST is guarded by bench/probe_passive_bench.cr's JS fixture.
  describe "source↔sink correlation is independent of encoding" do
    it "finds the same pair with and without a non-ASCII regex literal in scope" do
      ascii = JsScan.strip(%(var r=/[abc]/g; o.innerHTML=location.hash;))
      utf8 = JsScan.strip(%(var r=/[éèê]/g; o.innerHTML=location.hash;))
      utf8.ascii_only?.should be_false # the literal survives `strip` by design
      utf8_pairs = JsScan.source_sink_pairs(utf8)
      utf8_pairs.should eq(JsScan.source_sink_pairs(ascii))
      utf8_pairs.should eq([{"location.hash", "innerHTML"}])
    end

    it "keeps the statement boundary exact when a multi-byte char sits in the window" do
      # The `;` before the sink ends the previous statement, so the source on its far side must
      # NOT be picked up — a byte scan that mis-handled a multi-byte char would over-reach.
      code = JsScan.strip(%(var s=location.hash; var t=/[가-힣]/; o.innerHTML=safe;))
      JsScan.source_sink_pairs(code).should be_empty
    end

    it "correlates across a multi-byte char inside the same statement" do
      code = JsScan.strip(%(o.innerHTML=/[가-힣]/.test(x)?location.hash:y;))
      JsScan.source_sink_pairs(code).should eq([{"location.hash", "innerHTML"}])
    end
  end

  describe ".request_source_pairs" do
    pairs = ->(src : String) { JsScan.request_source_pairs(JsScan.strip(src)) }

    it "pairs a taint source in a request URL argument" do
      pairs.call(%(fetch("/api/user/" + location.hash.slice(1));)).should eq([{"location.hash", "fetch"}])
      pairs.call(%(fetch(`/api/note/${new URLSearchParams(location.search).get("id")}`);))
        .should eq([{"location.search", "fetch"}])
      pairs.call(%(axios.post(`/api/items/${useParams().id}`, data);)).should eq([{"useParams()", "axios"}])
      pairs.call(%(const x = new XMLHttpRequest(); xhr.open("GET", "/a/" + location.hash.slice(1));))
        .should eq([{"location.hash", "XMLHttpRequest.open"}])
      pairs.call(%($.ajax("/a/" + this.$route.params.id);)).should eq([{"route.params", "jQuery.ajax"}])
      pairs.call(%(jQuery.getJSON("/a/" + location.hash.slice(1));)).should eq([{"location.hash", "jQuery.ajax"}])
      pairs.call(%(new Request(url.searchParams.get("p"));)).should eq([{"searchParams.get()", "Request"}])
    end

    it "does not pair an encodeURIComponent-wrapped source, but does pair encodeURI" do
      pairs.call(%(fetch("/api/user/" + encodeURIComponent(location.hash));)).should be_empty
      pairs.call(%(fetch("/api/user/" + encodeURIComponent\t(location.hash));)).should be_empty
      pairs.call(%(fetch(`/api/${encodeURIComponent(router.query.id)}`);)).should be_empty
      # encodeURI leaves `/` and `.` alone, so `../` survives it.
      pairs.call(%(fetch("/api/user/" + encodeURI(location.hash.substr(1)));)).should eq([{"location.hash", "fetch"}])
      # Only the wrapped occurrence is safe; a second, bare one still pairs.
      pairs.call(%(fetch("/a/" + encodeURIComponent(location.hash) + "/" + location.hash.slice(1));))
        .should eq([{"location.hash", "fetch"}])
    end

    it "reads only the url: key of a config object" do
      pairs.call(%($.ajax({url: "/a/" + location.hash.slice(1), data: x});)).should eq([{"location.hash", "jQuery.ajax"}])
      pairs.call(%($.ajax({url:"/track",type:"POST",data:{ref:document.referrer}});)).should be_empty
      pairs.call(%(axios({method:"post",url:"/x",data:{q:location.search}});)).should be_empty
      pairs.call(%(coll.fetch({data:{q:location.search}});)).should be_empty
    end

    it "does not pair a bare re-request of the current URL" do
      pairs.call(%(fetch(window.location.href, {headers: h});)).should be_empty
      pairs.call(%(fetch(document.URL);)).should be_empty
      pairs.call(%(fetch(location.pathname + "/data");)).should eq([{"location.href", "fetch"}])
    end

    it "does not pair a whole location.search or .hash, which can only land in the query or fragment" do
      pairs.call(%(fetch("/api/" + location.hash);)).should be_empty
      pairs.call(%(fetch("/api/items" + location.search);)).should be_empty
      pairs.call(%(fetch(`/api/items${location.search}`);)).should be_empty
      pairs.call(%(fetch("/api/items/" + location.search.slice(1));)).should eq([{"location.search", "fetch"}])
      pairs.call(%(fetch("/a/" + location.search [1]);)).should eq([{"location.search", "fetch"}])
    end

    it "reports each source → sink once, and walks nested calls once" do
      pairs.call(%(fetch("/a/"+location.hash[1]);fetch("/b/"+location.hash[1]);fetch("/c/"+location.hash[1]);))
        .should eq([{"location.hash", "fetch"}])
      pairs.call("fetch(location.hash[1]+" * 11_397).should eq([{"location.hash", "fetch"}])
      # A config with no `url:` moves nothing past; the hit cap bounds the walk instead.
      hostile = "location.hash;" + "fetch({" * 37_449
      started = Time.instant
      pairs.call(hostile).should be_empty
      (Time.instant - started).should be < 100.milliseconds # ~230 ms uncapped
      # A nested call's own source is still read, as part of the outer argument.
      pairs.call(%(fetch("/a/" + fetch("/b/" + location.hash.slice(1)));)).should eq([{"location.hash", "fetch"}])
      # A call outside the config's URL is its own request, not a nested URL.
      pairs.call(%($.ajax({url: "/x", success: function(){ $.ajax("/a/" + location.hash.slice(1)) }});))
        .should eq([{"location.hash", "jQuery.ajax"}])
    end

    it "does not pair a source a URL cannot set" do
      pairs.call(%(fetch("/a/" + localStorage.getItem("id"));)).should be_empty
      pairs.call(%(fetch("/a/" + document.cookie);)).should be_empty
      pairs.call(%(fetch("/a/" + document.referrer);)).should eq([{"document.referrer", "fetch"}])
    end

    it "reads only the URL argument" do
      pairs.call(%(fetch("/api/x", {body: location.search});)).should be_empty
      pairs.call(%(fetch(build(a, b), {body: location.search});)).should be_empty
      pairs.call(%(xhr.open(location.hash, "/fixed"); new XMLHttpRequest();)).should be_empty
    end

    it "ignores open() without XMLHttpRequest, window.open, and text in strings or comments" do
      pairs.call(%(dialog.open("/a/" + location.hash);)).should be_empty
      pairs.call(%(new XMLHttpRequest(); window.open("/a/" + location.hash);)).should be_empty
      pairs.call(%(// fetch("/a/" + location.hash)\nlog("fetch(location.hash)");)).should be_empty
    end
  end
end
