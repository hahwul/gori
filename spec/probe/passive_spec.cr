require "../spec_helper"

# Crystal initializes every constant at program start, and a regex in one is compiled and
# JIT'd right there. The passive rule tables held ~400 of them, so `gori --version`,
# `gori run history` and every `gori mcp` spawn paid ~5 ms of CPU and ~1.9 MB for rules none
# of them runs. A table is a lazy `class_getter` instead, built on the first scan. This walks
# every constant of every passive rule at compile time and fails on one that holds a regex.
private macro eager_regex_constants
  [
    {% for name in Gori::Probe::Passive.constants %}
      {% t = Gori::Probe::Passive.constant(name) %}
      {% if t.is_a?(TypeNode) %}
        {% for c in t.constants %}
          {% v = t.constant(c) %}
          {% unless v.is_a?(TypeNode) %}
            {% s = v.stringify %}
            {% if s.includes?("Utf8.tolerant") || s.includes?("Regex.new") || s =~ /(\A|[\s(\[{,])\// %}
              {{ "#{t}::#{c}" }},
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
  ] of String
end

describe Gori::Probe::Passive do
  it "compiles no rule regex at program start" do
    eager_regex_constants.should be_empty
  end
end
