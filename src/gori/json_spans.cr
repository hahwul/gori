require "json"

module Gori
  # WHERE things are in a JSON document, as byte offsets into the bytes it arrived as — so a
  # caller can splice into those bytes instead of re-serializing them.
  #
  # `JSON.parse(..).to_json` is not a no-op on a captured body, and for an injector that has to
  # keep "everything else byte-exact" every difference is a different request (#1183):
  #
  #   - a duplicated member (`{"dup":"first","dup":"second"}`, the parser-differential probe) is
  #     folded to its last value, so a first-wins target stops seeing the value it was sent;
  #   - numbers are converted (`1.0e2` → `100.0`), and one past Int64/Float64 raises outright;
  #   - string escapes (`\u00e9`, `\/`) and all whitespace are re-spelled.
  #
  # `RawJson` keeps members and numbers too, but through the pull parser, which reports
  # values and not their offsets — so it can re-emit a document, not edit one in place.
  #
  # Validity is decided by the stdlib lexer (`JSON::PullParser#skip`, which checks syntax
  # without converting numbers), so this accepts exactly what `JSON.parse` does minus the
  # number-range failures; the walk after it only has to find structure in bytes already known
  # to be one JSON value. Byte-wise throughout: a string value may carry bytes that are not
  # valid UTF-8, and they are never touched.
  module JsonSpans
    extend self

    # One member of an object: its decoded key, and the byte span of its value (a string's
    # span includes its quotes).
    record Member, key : String, value_start : Int32, value_end : Int32 do
      def string?(bytes : Bytes) : Bool
        bytes[value_start] == '"'.ord
      end
    end

    # One object or array. `tail` is where a new member/element appends: just past the last
    # one's value, or just past the opening bracket when the container is empty — so an insert
    # there leaves the document's own whitespace where it was.
    class Container
      getter open : Int32
      getter children = [] of Container
      getter members = [] of Member
      property tail : Int32
      property close : Int32 = -1
      # The key a member is still waiting for its value under, and where that value started.
      property pending_key : String? = nil
      property pending_start : Int32 = -1

      def initialize(@open : Int32, @object : Bool)
        @tail = @open + 1
      end

      def object? : Bool
        @object
      end

      def empty? : Bool
        @tail == @open + 1
      end

      # A nested container opens as this one's next value.
      def adopt(child : Container) : Nil
        @children << child
        @pending_start = child.open
      end
    end

    # The root OBJECT, or nil when `bytes` is not exactly one JSON value or its root is not an
    # object.
    def root_object(bytes : Bytes) : Container?
      return nil unless valid?(bytes)
      walk(bytes).try { |r| r if r.object? }
    end

    # Object nodes reachable from the root, breadth-first (shallow-first) in document order,
    # capped at `cap` — the order `JSON::Any` hashes would be walked in, duplicates included.
    # nil when `bytes` is not exactly one JSON value; empty when it is one that holds no object.
    def objects(bytes : Bytes, cap : Int32) : Array(Container)?
      return nil unless valid?(bytes)
      acc = [] of Container
      return acc unless r = walk(bytes)
      queue = Deque(Container){r}
      until queue.empty? || acc.size >= cap
        node = queue.shift
        acc << node if node.object?
        node.children.each { |c| queue << c }
      end
      acc
    end

    # `bytes` with `fragment` (member text, e.g. `"k":"v"`) appended to each of `nodes`, every
    # other byte copied through. Comma-joined onto a non-empty object; bare into an empty one.
    def append_members(bytes : Bytes, nodes : Array(Container), fragment : String) : Bytes
      io = IO::Memory.new(bytes.size + nodes.size * (fragment.bytesize + 1))
      pos = 0
      nodes.sort_by(&.tail).each do |n|
        io.write(bytes[pos, n.tail - pos])
        io << ',' unless n.empty?
        io << fragment
        pos = n.tail
      end
      io.write(bytes[pos, bytes.size - pos])
      io.to_slice
    end

    # Is `bytes` exactly one JSON value? The stdlib lexer's answer, without its number
    # conversion: `skip` reads a number as the text it is.
    def valid?(bytes : Bytes) : Bool
      return false if bytes.empty?
      pull = JSON::PullParser.new(String.new(bytes))
      pull.skip
      pull.kind.eof?
    rescue JSON::ParseException
      false
    end

    # The structural walk over bytes `valid?` accepted. Iterative, so nesting depth costs heap
    # rather than stack (the lexer above already caps it).
    private def walk(bytes : Bytes) : Container?
      stack = [] of Container
      root = nil.as(Container?)
      i = 0
      while i < bytes.size
        b = bytes[i]
        if b == '{'.ord || b == '['.ord
          c = Container.new(i, b == '{'.ord)
          stack.last?.try(&.adopt(c))
          root ||= c
          stack << c
          i += 1
        elsif b == '}'.ord || b == ']'.ord
          stack.pop.close = i
          i += 1
          stack.last?.try { |top| value_done(top, i) }
        elsif b == '"'.ord
          i = read_string(bytes, i, stack.last?)
        elsif b == ','.ord || b == ':'.ord || whitespace?(b)
          i += 1
        else # a number, true, false or null
          j = scalar_end(bytes, i)
          stack.last?.try { |top| value_at(top, i, j) }
          i = j
        end
      end
      root
    end

    # A string at `from`: the key a member opens with when `top` is an object waiting for one,
    # otherwise a value. Returns the index just past it.
    private def read_string(bytes : Bytes, from : Int32, top : Container?) : Int32
      j = string_end(bytes, from)
      return j unless top
      if top.object? && top.pending_key.nil?
        top.pending_key = String.from_json(String.new(bytes[from, j - from]))
      else
        value_at(top, from, j)
      end
      j
    end

    # A scalar value occupies `start...stop` inside `c`.
    private def value_at(c : Container, start : Int32, stop : Int32) : Nil
      c.pending_start = start
      value_done(c, stop)
    end

    # A member's (or element's) value ended at `stop`.
    private def value_done(c : Container, stop : Int32) : Nil
      c.tail = stop
      return unless c.object?
      if key = c.pending_key
        c.members << Member.new(key, c.pending_start, stop)
      end
      c.pending_key = nil
    end

    # Index just past the closing quote of the string opening at `from`.
    private def string_end(bytes : Bytes, from : Int32) : Int32
      i = from + 1
      while i < bytes.size
        case bytes[i]
        when '\\'.ord then i += 2
        when '"'.ord  then return i + 1
        else               i += 1
        end
      end
      bytes.size
    end

    # Index just past the number/literal starting at `from`.
    private def scalar_end(bytes : Bytes, from : Int32) : Int32
      j = from
      while j < bytes.size
        b = bytes[j]
        break if b == ','.ord || b == '}'.ord || b == ']'.ord || whitespace?(b)
        j += 1
      end
      j
    end

    private def whitespace?(b : UInt8) : Bool
      b == ' '.ord || b == '\t'.ord || b == '\n'.ord || b == '\r'.ord
    end
  end
end
