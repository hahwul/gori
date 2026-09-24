require "json"
require "../../discover/url"

module Gori
  module Export
    module OpenApi
      # A JSON Schema INFERRED from observed values, merged across samples — the body and
      # response half of the OpenAPI export (#1241). Nothing here existed before: the parameter
      # inventory (`Params`, #1231) reads names and values, not shapes.
      #
      # One accumulator per schema position. Every observation folds in, and `to_any` renders
      # what the samples PROVE, in OpenAPI 3.0.3's dialect:
      #
      #   * the types seen at the position, with `integer` widened to `number` when both were
      #     seen (every integer is a number, so the pair is one type, not a union);
      #   * a `oneOf` only when the types really differ (a string here, an object there);
      #   * `null` as `nullable: true`, 3.0.3's spelling — which the 3.0.3 text scopes to a
      #     schema that also names a `type`, so a union carries it on its FIRST branch (the
      #     branches are disjoint types, so null then matches exactly one of them);
      #   * object properties unioned, `required` = the members present in EVERY object seen at
      #     the position;
      #   * array items merged across every element of every array seen there.
      #
      # Bounded, because a body is attacker-shaped: `MAX_DEPTH` levels, `MAX_PROPERTIES` members
      # per object position (a map keyed by ids would otherwise mint one property per id), and
      # the caller's per-document leaf budget.
      class Schema
        MAX_DEPTH      =  32
        MAX_PROPERTIES = 200

        # Leaves one document may contribute. A million-element array is a million
        # observations of the same `items`; past this the rest of the document is skipped.
        MAX_LEAVES = 5000

        # The string formats worth stating. Each is a SHAPE every observed string matched; one
        # string that does not match drops the claim for the position.
        FORMATS   = {"uuid", "date", "date-time"}
        DATE_TIME = /\A\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})\z/

        @null = false
        @bool = false
        @int = false
        @num = false
        @string = false
        # nil before the first string; then the format every string so far matched, or "" once
        # one did not.
        @format : String? = nil
        # Members seen at an object position, and in how many of its objects each one was.
        @props = {} of String => Schema
        @prop_counts = {} of String => Int32
        @objects = 0
        @items : Schema? = nil
        @arrays = 0
        # A position deeper than MAX_DEPTH: something was there, and nothing is claimed about it.
        @opaque = false

        # Nothing observed at all.
        def empty? : Bool
          !(@null || @bool || @int || @num || @string || @objects > 0 || @arrays > 0 || @opaque)
        end

        # Fold one JSON document in. False when the bytes are not exactly one JSON value — the
        # caller then has a body that SAYS it is JSON and is not (truncated at the capture cap,
        # JSONP), and nothing here is touched: observations are staged and only merged once the
        # whole document parsed, so a bad body cannot leave half a shape behind.
        def observe_json(text : String) : Bool
          staged = Schema.new
          budget = [MAX_LEAVES]
          begin
            pull = JSON::PullParser.new(text)
            staged.walk(pull, 0, budget)
            # The parser raises on anything trailing the root value only when asked for more.
            return false unless pull.kind.eof?
          rescue JSON::ParseException
            return false
          end
          merge(staged)
          true
        end

        # A value that arrived as TEXT — a query, header, cookie, form or path value. Everything
        # on the wire is a string, so text is typed as narrowly as EVERY sample allows: all
        # integers → `integer`, all numbers → `number`, all `true`/`false` → `boolean`, and one
        # value that is none of those makes the whole position a string (never a `oneOf` —
        # `?page=2` and `?page=last` are one string parameter, not two types).
        def observe_text(value : String) : Nil
          if integer_text?(value)
            @int = true
          elsif number_text?(value)
            @num = true
          elsif value == "true" || value == "false"
            @bool = true
          else
            note_string(value)
          end
        end

        # A file part or other binary value: a string of format `binary`.
        def observe_binary : Nil
          @string = true
          @format = "binary" if @format.nil?
          @format = "" unless @format == "binary"
        end

        # The rendered schema (keys sorted, so the output is byte-stable).
        def to_any(text : Bool = false) : JSON::Any
          return JSON::Any.new({} of String => JSON::Any) if @opaque && !typed?
          return text_any if text
          branches = type_branches
          if branches.empty?
            h = {} of String => JSON::Any
            h["nullable"] = JSON::Any.new(true) if @null
            return JSON::Any.new(h)
          end
          branches[0]["nullable"] = JSON::Any.new(true) if @null
          return JSON::Any.new(sorted(branches[0])) if branches.size == 1
          JSON::Any.new({"oneOf" => JSON::Any.new(branches.map { |b| JSON::Any.new(sorted(b)) })})
        end

        # One single-type schema per type seen, in a fixed order.
        private def type_branches : Array(Hash(String, JSON::Any))
          branches = [] of Hash(String, JSON::Any)
          branches << object_schema if @objects > 0
          branches << array_schema if @arrays > 0
          branches << {"type" => JSON::Any.new("boolean")} if @bool
          branches << {"type" => JSON::Any.new(@num ? "number" : "integer")} if @num || @int
          branches << string_schema if @string
          branches
        end

        # Merge another accumulator (the staged observations of one document) into this one.
        def merge(other : Schema) : Nil
          @null ||= other.@null
          @bool ||= other.@bool
          @int ||= other.@int
          @num ||= other.@num
          @opaque ||= other.@opaque
          if other.@string
            @string = true
            merge_format(other.@format)
          end
          merge_object(other) if other.@objects > 0
          if other.@arrays > 0
            @arrays += other.@arrays
            if oi = other.@items
              (@items ||= Schema.new).merge(oi)
            end
          end
        end

        # Past MAX_PROPERTIES a new member is dropped; `additionalProperties` stays at its default
        # (allowed), so an inferred schema never claims the members it did not see are forbidden.
        private def merge_object(other : Schema) : Nil
          @objects += other.@objects
          other.@props.each do |k, v|
            if mine = @props[k]?
              mine.merge(v)
            elsif @props.size < MAX_PROPERTIES
              @props[k] = v
            else
              next
            end
            @prop_counts[k] = @prop_counts.fetch(k, 0) + other.@prop_counts.fetch(k, 0)
          end
        end

        # Recursive descent over one document, bounded by depth and the leaf budget. Public only
        # so a staged accumulator can be driven from `observe_json`; callers use that.
        protected def walk(pull : JSON::PullParser, depth : Int32, budget : Array(Int32)) : Nil
          if depth > MAX_DEPTH || budget[0] <= 0
            pull.skip
            @opaque = true
            return
          end
          case pull.kind
          when .begin_object?
            walk_object(pull, depth, budget)
          when .begin_array?
            @arrays += 1
            pull.read_begin_array
            until pull.kind.end_array?
              (@items ||= Schema.new).walk(pull, depth + 1, budget)
            end
            pull.read_end_array
          when .string?
            budget[0] -= 1
            note_string(pull.read_string)
          when .int?
            budget[0] -= 1
            @int = true
            pull.skip # read as a kind, never converted: a value past Int64 cannot raise
          when .float?
            budget[0] -= 1
            @num = true
            pull.skip
          when .bool?
            budget[0] -= 1
            @bool = true
            pull.read_bool
          else
            budget[0] -= 1
            @null = true
            pull.read_null
          end
        end

        private def walk_object(pull : JSON::PullParser, depth : Int32, budget : Array(Int32)) : Nil
          @objects += 1
          seen = Set(String).new # a duplicate member in ONE object is one presence, not two
          pull.read_begin_object
          until pull.kind.end_object?
            key = pull.read_object_key
            child = @props[key]?
            if child.nil? && @props.size >= MAX_PROPERTIES
              pull.skip
              next
            end
            child ||= (@props[key] = Schema.new)
            child.walk(pull, depth + 1, budget)
            @prop_counts[key] = @prop_counts.fetch(key, 0) + 1 if seen.add?(key)
          end
          pull.read_end_object
        end

        private def typed? : Bool
          @null || @bool || @int || @num || @string || @objects > 0 || @arrays > 0
        end

        private def note_string(value : String) : Nil
          @string = true
          merge_format(format_of(value))
        end

        # Fold one string's format (nil = it matched none) into the position's claim.
        private def merge_format(f : String?) : Nil
          current = @format
          if current.nil?
            @format = f || ""
          elsif current != (f || "")
            @format = ""
          end
        end

        # The format a single string proves, or nil. Size-gated before any regex, and ASCII-gated:
        # a captured value may be invalid UTF-8, and PCRE2 raises on that rather than failing.
        private def format_of(v : String) : String?
          return nil unless v.ascii_only?
          return "uuid" if v.size == 36 && Discover::Url::UUID.matches?(v)
          if v.size == 10 && Discover::Url::DATE.matches?(v)
            month = v[5, 2].to_i
            day = v[8, 2].to_i
            return "date" if 1 <= month <= 12 && 1 <= day <= 31
          end
          return "date-time" if v.size >= 19 && v.size <= 40 && DATE_TIME.matches?(v)
          nil
        end

        private def integer_text?(v : String) : Bool
          return false if v.empty? || v.size > 18 # past Int64's digits it is an id, not a count
          start = v.starts_with?('-') ? 1 : 0
          return false if start == v.size
          v.each_byte.skip(start).all? { |b| 0x30_u8 <= b <= 0x39_u8 }
        end

        private def number_text?(v : String) : Bool
          return false if v.empty? || v.size > 32
          int, dot, frac = v.partition('.')
          !dot.empty? && integer_text?(int) && !frac.empty? && frac.each_byte.all? { |b| 0x30_u8 <= b <= 0x39_u8 }
        end

        # A text-sourced position: one scalar type, never a union (see `observe_text`).
        private def text_any : JSON::Any
          type = text_type
          h = {"type" => JSON::Any.new(type)}
          # A format only when every value was a string of that format — `2026-07-19` beside a
          # `3` is not a date.
          if type == "string" && !(@bool || @int || @num) && (f = @format) && !f.empty?
            h["format"] = JSON::Any.new(f)
          end
          JSON::Any.new(sorted(h))
        end

        private def text_type : String
          return "string" if @string || (@bool && (@int || @num))
          return "boolean" if @bool
          return "number" if @num
          @int ? "integer" : "string"
        end

        private def string_schema : Hash(String, JSON::Any)
          h = {"type" => JSON::Any.new("string")}
          if (f = @format) && !f.empty?
            h["format"] = JSON::Any.new(f)
          end
          h
        end

        private def object_schema : Hash(String, JSON::Any)
          h = {"type" => JSON::Any.new("object")}
          return h if @props.empty?
          keys = @props.keys.sort!
          h["properties"] = JSON::Any.new(keys.to_h { |k| {k.scrub, @props[k].to_any} })
          # Scrubbed and de-duplicated: two raw member names that scrub to one would otherwise
          # repeat in `required`, which must hold unique items.
          required = keys.select { |k| @prop_counts.fetch(k, 0) == @objects }.map(&.scrub).uniq!
          h["required"] = JSON::Any.new(required.map { |k| JSON::Any.new(k) }) unless required.empty?
          h
        end

        private def array_schema : Hash(String, JSON::Any)
          items = @items
          {"type"  => JSON::Any.new("array"),
           "items" => items && !items.empty? ? items.to_any : JSON::Any.new({} of String => JSON::Any)}
        end

        # Schema keywords in one fixed, readable order (`type` first). Properties and statuses are
        # sorted by name; keywords are not names, so a stable order is the whole requirement.
        KEYWORD_ORDER = {"type", "format", "nullable", "items", "properties", "required", "oneOf"}

        private def sorted(h : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          h.keys.sort_by! { |k| KEYWORD_ORDER.index(k) || KEYWORD_ORDER.size }.to_h { |k| {k, h[k]} }
        end
      end
    end
  end
end
