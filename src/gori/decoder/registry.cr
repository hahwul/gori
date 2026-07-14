module Gori::Decoder
  # An ordered, case-insensitive registry of converters — modelled on
  # Gori::Verb::Registry (a `@by_*` hash + an `@order` array; register dedups;
  # Enumerable). Keyed by canonical name AND every alias (normalized), so "url",
  # "url-encode", "url_encode" and "URL ENCODE" all resolve to the same converter.
  class Registry
    include Enumerable(Converter)

    def initialize
      @by_key = {} of String => Converter # normalized name AND every alias
      @order = [] of Converter            # canonical registration order (browsable / autocomplete)
    end

    def register(c : Converter) : Nil
      c.keys.each do |k|
        nk = Registry.normalize(k)
        # Dedup across the whole keyspace catches catalog typos (an alias colliding
        # with another converter's name). Mirrors verb/registry.cr.
        raise Gori::Error.new("duplicate converter key: #{k}") if @by_key.has_key?(nk)
        @by_key[nk] = c
      end
      @order << c
    end

    def []?(name : String) : Converter?
      @by_key[Registry.normalize(name)]?
    end

    def [](name : String) : Converter
      self[name]? || raise KeyError.new("no converter: #{name}")
    end

    def each(& : Converter ->)
      @order.each { |c| yield c }
    end

    def size : Int32
      @order.size
    end

    # Canonical names in registration order (the autocomplete browse list when the
    # query is empty).
    def names : Array(String)
      @order.map(&.name)
    end

    # Autocomplete feed, ranked in three tiers (registration order within each):
    #   1. the canonical NAME prefix-matches  (typing "ur" → url-encode first)
    #   2. only an ALIAS prefix-matches       (base64url-encode via "urlsafe-base64")
    #   3. name or alias merely contains the query
    # Matches against every key but the caller shows/inserts the canonical `name`.
    def match(query : String) : Array(Converter)
      q = Registry.normalize(query)
      return @order.dup if q.empty?
      name_pre = [] of Converter
      alias_pre = [] of Converter
      substr = [] of Converter
      @order.each do |c|
        if Registry.normalize(c.name).starts_with?(q)
          name_pre << c
        elsif c.aliases.any? { |a| Registry.normalize(a).starts_with?(q) }
          alias_pre << c
        elsif c.keys.any? { |k| Registry.normalize(k).includes?(q) }
          substr << c
        end
      end
      name_pre + alias_pre + substr
    end

    # downcase + strip; fold whitespace/underscore runs to '-' (the canonical
    # separator) so spacing/underscore variants all resolve.
    def self.normalize(s : String) : String
      s.strip.downcase.gsub(/[\s_]+/, "-")
    end
  end
end
