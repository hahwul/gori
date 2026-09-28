require "json"
require "./schema"

module Gori
  module Graphql
    # One request per root field of a schema: every query and every mutation, written the way an
    # operator would start one by hand, so it can be sent from History or the Repeater, or handed
    # to the Fuzzer, Miner or Authorize, as it is.
    #
    #   query user($id: ID!, $filter: UserFilter) {
    #     user(id: $id, filter: $filter) {
    #       id
    #       name
    #     }
    #   }
    #
    # Every argument becomes a variable and is passed, so the document shows what the field
    # accepts. Only the REQUIRED ones get a value in `variables`: GraphQL treats a declared variable
    # the request does not supply as an argument that was not given, so an optional filter stays
    # off until the operator fills it in, instead of going out as an empty string that changes
    # what the field returns.
    #
    # Subscriptions are listed in the notes and not generated: they run over a WebSocket, and a
    # History request template is an HTTP request.
    module Operations
      extend self

      record Operation, kind : String, field : String, document : String, variables : String?

      record Generated, operations : Array(Operation), notes : Array(String)

      # How many object levels a selection descends below the root field. The document is
      # regenerated shallower when it comes out past `MAX_DOCUMENT`.
      MAX_DEPTH = 3

      # A document past this is written again one level shallower, down to the root field's own
      # scalars. A connection type on a large schema fans out fast, and a 200 KB request nobody
      # can read is not a starting point.
      MAX_DOCUMENT = 16 * 1024

      # Fields listed per selection set. The rest of a very wide type is left for the operator.
      MAX_FIELDS = 64

      # How deep a placeholder input object is filled in. Past it, a required nested input is `{}`.
      MAX_INPUT_DEPTH = 5

      def generate(schema : Schema) : Generated
        ops = [] of Operation
        notes = [] of String
        {"query" => schema.query_type, "mutation" => schema.mutation_type}.each do |kind, root|
          next unless root
          unless type = schema.types[root]?
            notes << "the schema names #{root} as its #{kind} type but does not describe it"
            next
          end
          type.fields.each do |field|
            next if field.name.starts_with?("__")
            ops << operation(schema, kind, field)
          end
        end
        if (sub = schema.subscription_type) && (t = schema.types[sub]?)
          n = t.fields.count { |f| !f.name.starts_with?("__") }
          if n > 0
            notes << "#{n} subscription field#{n == 1 ? "" : "s"} not generated — subscriptions run over a WebSocket"
          end
        end
        Generated.new(ops, notes)
      end

      private def operation(schema : Schema, kind : String, field : Field) : Operation
        doc = ""
        MAX_DEPTH.downto(0) do |depth|
          doc = document(schema, kind, field, depth)
          break if doc.bytesize <= MAX_DOCUMENT
        end
        Operation.new(kind, field.name, doc, variables(schema, field))
      end

      private def document(schema : Schema, kind : String, field : Field, depth : Int32) : String
        String.build do |io|
          io << kind << ' ' << field.name
          unless field.args.empty?
            io << '('
            field.args.each_with_index do |arg, i|
              io << ", " if i > 0
              io << '$' << arg.name << ": " << arg.type
            end
            io << ')'
          end
          io << " {\n  " << field.name
          unless field.args.empty?
            io << '('
            field.args.each_with_index do |arg, i|
              io << ", " if i > 0
              io << arg.name << ": $" << arg.name
            end
            io << ')'
          end
          if (named = field.type.named) && (sel = selection(schema, named, 1, depth, "    "))
            io << " {\n" << sel << "\n  }"
          end
          io << "\n}"
        end
      end

      # The selection set for a value of type `name`, or nil for a leaf (a scalar or an enum is
      # selected by naming it, with no braces). An object with nothing selectable at this depth
      # still gets `__typename`, because an empty selection set is a syntax error.
      private def selection(schema : Schema, name : String, depth : Int32, max : Int32, pad : String) : String?
        type = schema.types[name]? || return nil
        case type.kind
        when .object?, .interface?
          lines = [] of String
          type.fields.each do |f|
            break if lines.size >= MAX_FIELDS
            next if f.name.starts_with?("__")
            # A field with a required argument cannot be selected without a value for it.
            next if f.args.any?(&.required?)
            inner = f.type.named || next
            it = schema.types[inner]? || next
            if it.kind.leaf?
              lines << "#{pad}#{f.name}"
            elsif depth < max
              if sub = selection(schema, inner, depth + 1, max, pad + "  ")
                lines << "#{pad}#{f.name} {\n#{sub}\n#{pad}}"
              end
            end
          end
          lines.empty? ? "#{pad}__typename" : lines.join('\n')
        when .union?
          lines = ["#{pad}__typename"]
          if depth < max
            type.possible_types.each do |member|
              break if lines.size > MAX_FIELDS
              if sub = selection(schema, member, depth + 1, max, pad + "  ")
                lines << "#{pad}... on #{member} {\n#{sub}\n#{pad}}"
              end
            end
          end
          lines.join('\n')
        end
      end

      # `{"id": ""}` for the required arguments, or nil when there are none.
      private def variables(schema : Schema, field : Field) : String?
        required = field.args.select(&.required?)
        return nil if required.empty?
        JSON.build do |j|
          j.object do
            required.each do |arg|
              j.field arg.name do
                placeholder(schema, arg.type, 0, j)
              end
            end
          end
        end
      end

      # A value of the right shape for `ref`: `0`, `0.0`, `false`, `""`, an enum's first value, a
      # one-element list, or an input object with its own required fields filled in.
      private def placeholder(schema : Schema, ref : Schema::TypeRef, depth : Int32, j : JSON::Builder) : Nil
        case ref.kind
        when .non_null?
          if inner = ref.of_type
            placeholder(schema, inner, depth, j)
          else
            j.null
          end
        when .list?
          j.array do
            ref.of_type.try { |inner| placeholder(schema, inner, depth, j) }
          end
        else
          name = ref.name || return j.null
          case name
          when "Int"     then j.number(0)
          when "Float"   then j.number(0.0)
          when "Boolean" then j.bool(false)
          when "String", "ID"
            j.string("")
          else
            named_placeholder(schema, schema.types[name]?, depth, j)
          end
        end
      end

      private def named_placeholder(schema : Schema, type : Schema::Type?, depth : Int32, j : JSON::Builder) : Nil
        unless type
          j.string("")
          return
        end
        case type.kind
        when .enum?
          if first = type.enum_values.first?
            j.string(first)
          else
            j.null
          end
        when .input_object?
          j.object do
            if depth < MAX_INPUT_DEPTH
              type.input_fields.each do |f|
                next unless f.required?
                j.field f.name do
                  placeholder(schema, f.type, depth + 1, j)
                end
              end
            end
          end
        else
          # A custom scalar (`DateTime`, `JSON`, `Upload`): its format is the server's, and a
          # string is the likeliest to parse and the easiest to replace.
          j.string("")
        end
      end
    end
  end
end
