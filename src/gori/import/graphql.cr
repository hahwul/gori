require "json"
require "./builder"

module Gori::Import
  # A service description, not captured payload (DESIGN.md §7, 2026-08-23): names and
  # references are validated before they become generated GraphQL syntax. No I/O but the file.
  module Graphql
    MAX_BYTES       = 8 * 1024 * 1024
    MAX_TYPES       = 4096
    MAX_OPERATIONS  = 1000
    MAX_ARGS        =   64
    MAX_NAME        =  128
    MAX_REF_DEPTH   =   16
    MAX_DEPTH       =    3
    MAX_WIDTH       =    8
    MAX_NODES       =  256
    MAX_TOTAL_BYTES = 16 * 1024 * 1024

    def self.parse_file(path : String, endpoint : String?, prov : Provenance = Provenance.none) : ParseResult
      raise Gori::Error.new("GraphQL import requires an endpoint URL") unless endpoint && !endpoint.empty?
      # Read at most the ceiling plus one, even if the file grows after it was opened.
      raw = IO::Memory.new
      File.open(path) { |f| IO.copy(f, raw, MAX_BYTES + 1) }
      raise Gori::Error.new("GraphQL document exceeds #{MAX_BYTES} bytes") if raw.size > MAX_BYTES
      parser = JSON::Parser.new(raw.to_s.lchop('\u{FEFF}'))
      parser.max_nesting = 64
      doc = parser.parse
      schema = at(at(doc, "data"), "__schema")
      schema = at(doc, "__schema") unless schema.try(&.as_h?)
      raise Gori::Error.new("GraphQL document has no data.__schema or top-level __schema object") unless schema && schema.as_h?
      Generator.new(schema).build(endpoint, prov)
    rescue ex : JSON::ParseException
      raise Gori::Error.new("GraphQL document is not valid JSON: #{ex.message}")
    end

    def self.at(node : JSON::Any?, key : String) : JSON::Any?
      node.try(&.as_h?).try(&.[key]?)
    end

    private class Generator
      # Cache the fields or validation error. A recursive input can visit the
      # same type many times within one operation (P6).
      private record InputField, name : String, ref : JSON::Any?, nullable : Bool
      private record InputShape, fields : Array(InputField), one_of : Bool, error : String?

      # The outermost input object whose field may stop this expansion. A cycle
      # starts at the repeated type. The depth limit can be handled at any level.
      private class InputExpansionLimit < Gori::Error
        getter cut_from : Int32

        def initialize(name : String, @cut_from : Int32)
          super("GraphQL required input cycle/depth at #{name}")
        end
      end

      @types = {} of String => JSON::Any
      @inputs = {} of String => InputShape
      @left = MAX_NODES

      def initialize(@schema : JSON::Any)
        types = list(@schema, "types", MAX_TYPES)
        types.each_with_index do |type, i|
          n = name(type)
          raise Gori::Error.new("duplicate GraphQL type #{n}") if @types.has_key?(n)
          @types[n] = type
          Fiber.yield if i % 64 == 0
        end
      end

      def build(endpoint : String, prov : Provenance) : ParseResult
        Builder.endpoint(endpoint) # reject a bad endpoint even when the schema has no operations
        pairs = [] of Builder::FlowPair
        skips = Skips.new
        # Subscriptions are only counted, so a dangling or malformed subscriptionType is a note,
        # not a reason to lose every query and mutation beside it.
        subscriptions = begin
          root_fields("subscriptionType").size
        rescue ex : Gori::Error
          skips.note("ignored subscriptionType: #{ex.message}")
          0
        end
        note = "skipped #{subscriptions} subscription operation(s): only query/mutation HTTP templates are imported"
        skips.note(note) if subscriptions > 0
        now = Time.utc.to_unix * 1_000_000
        total = 0
        operations = 0
        { {"queryType", "query"}, {"mutationType", "mutation"} }.each do |(key, kind)|
          fields = root_fields(key)
          operations += fields.size
          raise Gori::Error.new("GraphQL schema exceeds #{MAX_OPERATIONS} operations") if operations > MAX_OPERATIONS
          fields.each_with_index do |field, i|
            begin
              @left = MAX_NODES
              body = operation(field, kind).to_json
              total += body.bytesize
              raise Gori::Error.new("GraphQL templates exceed #{MAX_TOTAL_BYTES} bytes") if total > MAX_TOTAL_BYTES
              headers = Builder::Headers{ {"Content-Type", "application/json"} }
              pairs << Builder.pending_request(now, endpoint, "POST", headers, body.to_slice,
                source_surface: prov.surface, source_ref: prov.ref)
            rescue ex : Gori::Error
              # The aggregate budget is fatal: repeatedly retrying it must not grow notes/work.
              raise ex if total > MAX_TOTAL_BYTES
              skips.add("#{kind} field #{field_label(field, i)}", ex)
            end
            Fiber.yield
          end
        end
        if pairs.empty? && skips.count == 0 && subscriptions > 0
          raise Gori::Error.new("no GraphQL query/mutation templates: #{note}")
        end
        skips.result(pairs)
      end

      private def root_fields(key : String) : Array(JSON::Any)
        root = Graphql.at(@schema, key)
        return [] of JSON::Any if root.nil? || root.raw.nil?
        type = definition(name(root), "OBJECT")
        list(type, "fields", MAX_OPERATIONS)
      end

      private def operation(field : JSON::Any, kind : String) : Hash(String, JSON::Any)
        n = name(field)
        variables = {} of String => JSON::Any
        declarations = [] of String
        args = list(field, "args", MAX_ARGS)
        arguments = args.map do |arg|
          a = name(arg)
          raise Gori::Error.new("duplicate GraphQL argument #{a}") if variables.has_key?(a)
          ref = Graphql.at(arg, "type")
          declarations << "$#{a}: #{type_ref(ref)}"
          input_type!(ref)
          variables[a] = sample(ref, a, [] of String)
          "#{a}: $#{a}"
        end
        params = arguments.empty? ? "" : "(#{arguments.join(", ")})"
        decl = declarations.empty? ? "" : "(#{declarations.join(", ")})"
        selection = selection(Graphql.at(field, "type"), [] of String, 0)
        query = "#{kind} #{n}#{decl} { #{n}#{params}#{selection} }"
        {"operationName" => JSON::Any.new(n), "query" => JSON::Any.new(query), "variables" => JSON::Any.new(variables)}
      end

      private def name(node : JSON::Any?) : String
        n = Graphql.at(node, "name").try(&.as_s?)
        unless n && valid_name?(n)
          raise Gori::Error.new("invalid GraphQL name (expected at most #{MAX_NAME} ASCII name bytes)")
        end
        n
      end

      private def valid_name?(n : String) : Bool
        n.bytesize <= MAX_NAME && n.ascii_only? && /\A[_A-Za-z][_0-9A-Za-z]*\z/.matches?(n)
      end

      # A skipped operation by its field name when that name is valid (it is the one the
      # operator searches the schema for), by its position otherwise.
      private def field_label(field : JSON::Any, i : Int32) : String
        n = Graphql.at(field, "name").try(&.as_s?)
        n && valid_name?(n) ? n : (i + 1).to_s
      end

      private def list(node : JSON::Any?, key : String, max : Int32) : Array(JSON::Any)
        values = Graphql.at(node, key).try(&.as_a?) || raise Gori::Error.new("GraphQL #{key} is not an array")
        raise Gori::Error.new("GraphQL #{key} exceeds #{max} entries") if values.size > max
        values
      end

      # The first `n` entries of a list the generator reads only the head of. An overlong list
      # here (a 300-value country enum, a 300-field result type) costs nothing to slice, so it
      # is not a reason to refuse the operation; every entry read is still validated.
      private def head(node : JSON::Any?, key : String, n : Int32) : Array(JSON::Any)
        values = Graphql.at(node, key).try(&.as_a?) || raise Gori::Error.new("GraphQL #{key} is not an array")
        values.first(n)
      end

      private def definition(n : String, kind : String) : JSON::Any
        type = @types[n]? || raise Gori::Error.new("unknown GraphQL type #{n}")
        raise Gori::Error.new("GraphQL type #{n} is not #{kind}") unless Graphql.at(type, "kind").try(&.as_s?) == kind
        type
      end

      # Validate the full wrapper chain, including illegal NON_NULL of NON_NULL.
      private def type_ref(ref : JSON::Any?, depth = 0, non_null = false) : String
        raise Gori::Error.new("GraphQL type reference exceeds #{MAX_REF_DEPTH} levels") if depth >= MAX_REF_DEPTH
        kind = Graphql.at(ref, "kind").try(&.as_s?) || raise Gori::Error.new("invalid GraphQL type reference")
        case kind
        when "NON_NULL"
          raise Gori::Error.new("GraphQL NON_NULL wraps NON_NULL") if non_null
          "#{type_ref(Graphql.at(ref, "ofType"), depth + 1, true)}!"
        when "LIST"
          "[#{type_ref(Graphql.at(ref, "ofType"), depth + 1)}]"
        when "SCALAR", "ENUM", "INPUT_OBJECT", "OBJECT", "INTERFACE", "UNION"
          n = name(ref)
          definition(n, kind)
          n
        else
          raise Gori::Error.new("invalid GraphQL type reference")
        end
      end

      private def named(ref : JSON::Any?) : JSON::Any
        type_ref(ref)
        while {"NON_NULL", "LIST"}.includes?(Graphql.at(ref, "kind").try(&.as_s?))
          ref = Graphql.at(ref, "ofType")
        end
        ref || raise Gori::Error.new("invalid GraphQL type reference")
      end

      private def charge : Nil
        @left -= 1
        raise Gori::Error.new("GraphQL operation exceeds #{MAX_NODES} generated nodes") if @left < 0
      end

      private def input_type!(ref : JSON::Any?) : Nil
        kind = Graphql.at(named(ref), "kind").try(&.as_s?)
        raise Gori::Error.new("GraphQL argument is not an input type") unless {"SCALAR", "ENUM", "INPUT_OBJECT"}.includes?(kind)
      end

      private def sample(ref : JSON::Any?, label : String, chain : Array(String)) : JSON::Any
        charge
        kind = Graphql.at(ref, "kind").try(&.as_s?)
        return sample(Graphql.at(ref, "ofType"), label, chain) if kind == "NON_NULL"
        return JSON::Any.new([] of JSON::Any) if kind == "LIST"
        n = name(ref)
        type = definition(n, kind || "")
        case kind
        when "SCALAR"
          case n
          when "Int", "Float" then JSON::Any.new(0_i64)
          when "Boolean"      then JSON::Any.new(true)
          else                     JSON::Any.new(label)
          end
        when "ENUM"
          value = name(head(type, "enumValues", 1).first?)
          raise Gori::Error.new("invalid GraphQL enum value") if {"true", "false", "null"}.includes?(value)
          JSON::Any.new(value)
        when "INPUT_OBJECT"
          input_sample(type, n, chain)
        else
          raise Gori::Error.new("GraphQL argument #{label} is not an input type")
        end
      end

      private def input_sample(type : JSON::Any, n : String, chain : Array(String)) : JSON::Any
        if repeated_at = chain.index(n)
          raise InputExpansionLimit.new(n, repeated_at)
        end
        raise InputExpansionLimit.new(n, 0) if chain.size >= MAX_DEPTH
        shape = input_shape(type, n)
        shape.error.try { |why| raise Gori::Error.new(why) }
        parents = chain + [n]
        return one_of_sample(shape, parents) if shape.one_of

        values = {} of String => JSON::Any
        shape.fields.each do |field|
          values[field.name] = input_field_sample(field, parents)
        end
        JSON::Any.new(values)
      end

      private def input_field_sample(field : InputField, parents : Array(String)) : JSON::Any
        sample(field.ref, field.name, parents)
      rescue ex : InputExpansionLimit
        # A nullable link on the cycle can end it, including one earlier in the
        # chain. An outer nullable field cannot make an all-required cycle valid.
        raise ex unless field.nullable && parents.size > ex.cut_from
        JSON::Any.new(nil)
      end

      private def one_of_sample(shape : InputShape, parents : Array(String)) : JSON::Any
        blocked = nil.as(InputExpansionLimit?)
        shape.fields.each do |field|
          return JSON::Any.new({field.name => sample(field.ref, field.name, parents)})
        rescue ex : InputExpansionLimit
          raise ex unless parents.size > ex.cut_from
          blocked = ex if !blocked || ex.cut_from < blocked.cut_from
        end
        raise(blocked || Gori::Error.new("GraphQL OneOf input has no fields"))
      end

      private def input_shape(type : JSON::Any, n : String) : InputShape
        @inputs[n] ||= begin
          fields = [] of InputField
          seen = Set(String).new
          one_of = Graphql.at(type, "isOneOf").try(&.as_bool?) == true
          error = nil
          begin
            list(type, "inputFields", MAX_ARGS).each do |field|
              f = name(field)
              raise Gori::Error.new("duplicate GraphQL input field #{f}") unless seen.add?(f)
              ref = Graphql.at(field, "type")
              input_type!(ref)
              nullable = Graphql.at(ref, "kind").try(&.as_s?) != "NON_NULL"
              if one_of && (!nullable || !Graphql.at(field, "defaultValue").try(&.raw).nil?)
                raise Gori::Error.new("GraphQL OneOf input field #{f} must be nullable without a default")
              end
              fields << InputField.new(f, ref, nullable)
            end
          rescue ex : Gori::Error
            error = ex.message || "invalid GraphQL input object #{n}"
          end
          # Each shape is built once, but one operation can reach many new ones.
          Fiber.yield
          InputShape.new(fields, one_of, error)
        end
      end

      # A field with more arguments than an operation may declare is skipped like one with a
      # required argument, rather than refusing the operation that selects it.
      private def requires_arguments?(field : JSON::Any) : Bool
        args = Graphql.at(field, "args").try(&.as_a?) || raise Gori::Error.new("GraphQL args is not an array")
        return true if args.size > MAX_ARGS
        args.any? do |arg|
          Graphql.at(Graphql.at(arg, "type"), "kind").try(&.as_s?) == "NON_NULL" &&
            Graphql.at(arg, "defaultValue").try(&.as_s?).nil?
        end
      end

      private def selection(ref : JSON::Any?, chain : Array(String), depth : Int32, prefix : String? = nil) : String
        charge
        leaf = named(ref)
        kind = Graphql.at(leaf, "kind").try(&.as_s?) || raise Gori::Error.new("invalid GraphQL result type")
        return "" if {"SCALAR", "ENUM"}.includes?(kind)
        n = name(leaf)
        unless {"OBJECT", "INTERFACE", "UNION"}.includes?(kind)
          raise Gori::Error.new("GraphQL result #{n} is not an output type")
        end
        return " { __typename }" if chain.includes?(n) || depth >= MAX_DEPTH || @left <= MAX_WIDTH
        type = definition(n, kind)
        members = ["__typename"]
        if kind == "UNION"
          head(type, "possibleTypes", MAX_WIDTH).each_with_index do |member, i|
            break if @left <= 0
            m = name(member)
            definition(m, "OBJECT")
            # Distinct union members can reuse a field name with incompatible response types.
            members << "... on #{m}#{selection(member, chain + [n], depth + 1, "gori_#{i}")}"
          end
        else
          head(type, "fields", MAX_WIDTH).each do |field|
            break if @left <= 0
            f = name(field)
            next if requires_arguments?(field)
            label = prefix ? "#{prefix}_#{f}: #{f}" : f
            members << "#{label}#{selection(Graphql.at(field, "type"), chain + [n], depth + 1)}"
          end
        end
        " { #{members.join(' ')} }"
      end
    end
  end
end
