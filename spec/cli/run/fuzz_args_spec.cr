require "../../spec_helper"

# `src/gori/cli/run/fuzz_args.cr` — the payload/processor flag parsers shared by
# `gori run fuzz` and `gori run discover`.
#
# These decide what bytes leave the machine. Each of them has already been wrong in a way
# that produced a QUIETLY different payload set rather than an error: `--numbers -10--5`
# split on the first hyphen and lost its lower bound, `--regex-replace /foo//bar/` dropped
# everything past the second delimiter, `--brute` split its charset on the wrong colon.
# A parser that mis-reads a flag and still runs is the failure mode worth pinning, because
# the run looks successful either way.
#
# The `abort` branches call `exit`, so only the success paths run here — the same limit
# spec/cli/run/links_spec.cr works under. The parsers return payload SOURCES with no getters,
# so each is checked through what it actually produces.

# Private CLI glue — reopen the module for bare-call wrappers.
module Gori::CLI::Run
  def self.parse_numbers_for_spec(v : String) : Fuzz::NumberRange
    parse_numbers(v)
  end

  def self.parse_preset_for_spec(v : String) : Fuzz::PresetSource
    parse_preset(v)
  end

  def self.parse_brute_for_spec(v : String) : Fuzz::BruteForce
    parse_brute(v)
  end

  def self.parse_encode_for_spec(v : String) : Symbol
    parse_encode(v)
  end

  def self.parse_case_for_spec(v : String) : Symbol
    parse_case(v)
  end

  def self.parse_hash_for_spec(v : String) : Symbol
    parse_hash(v)
  end

  def self.parse_regex_for_spec(v : String) : Regex
    parse_regex(v)
  end

  def self.parse_rate_for_spec(v : String) : Float64?
    parse_rate(v)
  end

  def self.parse_nonneg_for_spec(v : String, flag : String? = nil) : Int32
    parse_nonneg(v, flag)
  end

  def self.parse_regex_replace_for_spec(v : String) : Fuzz::RegexReplace
    parse_regex_replace(v)
  end
end

private def payloads(src : Gori::Fuzz::PayloadSource) : Array(String)
  out = [] of String
  src.each { |v| out << v }
  out
end

describe "gori run fuzz --numbers" do
  it "generates FROM-TO inclusive" do
    payloads(Gori::CLI::Run.parse_numbers_for_spec("1-4")).should eq(%w[1 2 3 4])
  end

  it "takes an explicit :STEP" do
    payloads(Gori::CLI::Run.parse_numbers_for_spec("0-10:5")).should eq(%w[0 5 10])
  end

  # A plain `partition('-')` splits on the FIRST hyphen, which left a negative FROM with an
  # empty lower bound — offset and ID fuzzing both walk negative ranges routinely.
  it "reads a negative FROM and a negative TO" do
    payloads(Gori::CLI::Run.parse_numbers_for_spec("-2-2")).should eq(%w[-2 -1 0 1 2])
    payloads(Gori::CLI::Run.parse_numbers_for_spec("-10--8")).should eq(%w[-10 -9 -8])
  end

  it "walks backwards on a negative step" do
    payloads(Gori::CLI::Run.parse_numbers_for_spec("3-1:-1")).should eq(%w[3 2 1])
  end

  it "counts without iterating" do
    Gori::CLI::Run.parse_numbers_for_spec("1-100").size.should eq(100_i64)
    Gori::CLI::Run.parse_numbers_for_spec("0-10:5").size.should eq(3_i64)
  end
end

describe "gori run fuzz --brute" do
  # `rpartition`, not `partition`: the charset may itself contain a ':' (it is an arbitrary
  # alphabet), and only the LAST one separates it from the lengths.
  it "walks every string of length MIN..MAX over the charset" do
    payloads(Gori::CLI::Run.parse_brute_for_spec("ab:1-2"))
      .should eq(%w[a b aa ab ba bb])
  end

  it "reads a bare length as MIN == MAX" do
    payloads(Gori::CLI::Run.parse_brute_for_spec("ab:2")).should eq(%w[aa ab ba bb])
  end

  it "keeps a ':' that belongs to the charset" do
    payloads(Gori::CLI::Run.parse_brute_for_spec("a::1")).should eq(["a", ":"])
  end

  it "counts without walking" do
    Gori::CLI::Run.parse_brute_for_spec("abc:1-3").size.should eq(3_i64 + 9 + 27)
  end
end

describe "gori run fuzz --preset" do
  it "resolves a built-in preset by name" do
    name = Gori::Fuzz::Presets.names.first
    src = Gori::CLI::Run.parse_preset_for_spec(name)
    src.name.should eq(name)
    src.user_path.should be_nil
    src.size.not_nil!.should be > 0
  end

  # Split on the FIRST ':' — preset names carry none, and a unix path after it (`/tmp/a:b`)
  # has to survive intact.
  it "splits NAME:FILE on the first colon, keeping the rest as the path" do
    name = Gori::Fuzz::Presets.names.first
    src = Gori::CLI::Run.parse_preset_for_spec("#{name}:/tmp/extra:1.txt")
    src.name.should eq(name)
    src.user_path.should eq("/tmp/extra:1.txt")
  end

  it "leaves user_path nil when no colon is given, rather than empty" do
    Gori::CLI::Run.parse_preset_for_spec(Gori::Fuzz::Presets.names.first).user_path.should be_nil
  end
end

describe "gori run fuzz — processor flags" do
  it "maps every --encode spelling, case-folded" do
    Gori::CLI::Run.parse_encode_for_spec("url").should eq(:url)
    Gori::CLI::Run.parse_encode_for_spec("urlall").should eq(:url_all)
    Gori::CLI::Run.parse_encode_for_spec("base64").should eq(:base64)
    Gori::CLI::Run.parse_encode_for_spec("HEX").should eq(:hex)
  end

  it "maps --case and --hash, case-folded" do
    Gori::CLI::Run.parse_case_for_spec("upper").should eq(:upper)
    Gori::CLI::Run.parse_case_for_spec("LOWER").should eq(:lower)
    Gori::CLI::Run.parse_hash_for_spec("md5").should eq(:md5)
    Gori::CLI::Run.parse_hash_for_spec("sha1").should eq(:sha1)
    Gori::CLI::Run.parse_hash_for_spec("SHA256").should eq(:sha256)
  end

  it "compiles a regex flag" do
    Gori::CLI::Run.parse_regex_for_spec("^a(b)c$").should eq(/^a(b)c$/)
  end

  # 0 means "unthrottled", and it has to arrive as nil rather than a 0.0 rate that the
  # pacer would read as "zero requests per second".
  it "reads --rate, turning 0 into 'no limit'" do
    Gori::CLI::Run.parse_rate_for_spec("2.5").should eq(2.5)
    Gori::CLI::Run.parse_rate_for_spec("0").should be_nil
    Gori::CLI::Run.parse_rate_for_spec("0.0").should be_nil
  end

  # Unlike parse_count, zero is ALLOWED here — these flags spell "no delay", "no retries".
  it "accepts zero as a non-negative count" do
    Gori::CLI::Run.parse_nonneg_for_spec("0").should eq(0)
    Gori::CLI::Run.parse_nonneg_for_spec("7", "--delay").should eq(7)
  end
end

describe "gori run fuzz --regex-replace" do
  it "applies /pattern/replacement/ as a gsub" do
    Gori::CLI::Run.parse_regex_replace_for_spec("/foo/bar/").apply("foo-foo").should eq("bar-bar")
  end

  # Splitting on EVERY delimiter dropped any part of the replacement past a second one, so
  # `/foo//bar/` silently replaced with "" instead of "/bar".
  it "keeps a delimiter that appears inside the replacement" do
    Gori::CLI::Run.parse_regex_replace_for_spec("/foo//bar/").apply("foo").should eq("/bar")
  end

  it "takes the first character as the delimiter, so a path pattern needs no escaping" do
    Gori::CLI::Run.parse_regex_replace_for_spec("#/api/v1#/api/v2#").apply("GET /api/v1/x")
      .should eq("GET /api/v2/x")
  end

  it "strips exactly one trailing delimiter, and tolerates its absence" do
    Gori::CLI::Run.parse_regex_replace_for_spec("/a/b").apply("a").should eq("b")
    Gori::CLI::Run.parse_regex_replace_for_spec("/a/b//").apply("a").should eq("b/")
  end

  it "carries capture groups into the replacement" do
    Gori::CLI::Run.parse_regex_replace_for_spec("/id=(\\d+)/id=\\1\\1/").apply("id=7")
      .should eq("id=77")
  end
end
