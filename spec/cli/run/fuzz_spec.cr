require "../../spec_helper"

module Gori::CLI::Run
  def self.stdin_wordlist_for_spec(io : IO) : Fuzz::PayloadSource
    stdin_wordlist(false, io)
  end
end

# `fuzz -w -` looked for a file named `-` ("wordlist not found: -"), while `import --har -`,
# `wordlist save --from -` and `sequence --tokens -` all read stdin. One line per payload, the
# line ending dropped as a wordlist file's `LineIterator` drops it.
describe "gori run fuzz -w -" do
  it "reads the payload list from stdin" do
    src = Gori::CLI::Run.stdin_wordlist_for_spec(IO::Memory.new("a\nadmin\r\nmissing\n"))
    it = src.open_iterator
    got = [] of String
    while v = it.next_value
      got << v
    end
    got.should eq(["a", "admin", "missing"])
  end
end
