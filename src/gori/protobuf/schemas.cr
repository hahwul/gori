require "../paths"
require "../url"
require "../store"
require "./schema"

module Gori::Protobuf
  # WHERE the open project's `.proto` schema comes from, and what a captured gRPC path
  # resolves to through it. `Schema` parses a descriptor set; this decides which ones are
  # loaded and answers "what message is `/demo.Users/GetUser`'s request?".
  #
  # ## A per-project global, like `Settings.project_env_vars`
  #
  # The four surfaces that render a gRPC body — the History framing pane, the Repeater
  # transcript, `gori run show --format json`, MCP `get_flow` — reach the payload through
  # class methods and static serializers with no Store in hand. Threading a store into each
  # would mean four independently-drifting answers to "is there a schema?", which is the
  # shape #496 already cost this code once. So the loaded schema is published HERE, by
  # `load_project`, from the same handful of sites that publish the project's env vars and
  # network overrides — see the call sites in `Session.open`, `CLI::Run.open_store` and MCP's
  # bind/switch.
  #
  # ## Loading a file is not an outbound action; reflection is
  #
  # P4 constrains gori from touching the network unasked; reading a descriptor set the
  # operator dropped in their own directory is neither a request nor a disclosure. Server
  # REFLECTION (#827) IS an outbound request, and nothing in THIS module makes one: the
  # network belongs to `Protobuf::Reflection`, which runs only when an operator asks. What
  # arrives here is the CACHED result (`Store#grpc_reflections`) — bytes already on disk,
  # read exactly as a file source is read.
  #
  # ## Both sources merge, with reflection last
  #
  # Files load first, then each cached reflection target in fetch order. Last-wins on a
  # fully-qualified name, so a target reflected after a file was loaded supersedes it — which
  # is the direction the operator's most recent deliberate act points. Nothing is hidden by
  # it: `Schema#conflicts` counts every differing redefinition and `status` prints the count.
  module Schemas
    # Per-project settings row: the file or directory this project's schema comes from.
    # Blank (or absent) means the convention directory below.
    SETTING_KEY = "grpc.descriptors"

    # Extensions treated as descriptor sets when a DIRECTORY is loaded. Naming a file
    # directly bypasses this — an operator who points at `api.protoset.v2` means it.
    EXTENSIONS = %w[.desc .pb .protoset .fds .bin]

    # A descriptor set is normally tens of kilobytes; `--include_imports` on a large API can
    # reach a few megabytes. Past this it is not a descriptor set, and parsing it would build
    # a wire tree over the whole file before finding that out.
    MAX_FILE_BYTES = 32 * 1024 * 1024

    # Files taken from a directory. A `protos/` folder someone points at their whole
    # generated-artifact tree should stop, not stall the project open.
    MAX_FILES = 64

    # WHERE one loaded schema came from. A file the operator pointed at, or a gRPC server
    # reflection fetch they ran against a target (#827) — the Project settings row has to say
    # which, because "3 messages · 1 rpc" reads identically for both and only one of them
    # involved touching the network.
    enum Origin
      File
      Reflection
    end

    # One source the loader tried. `error` is nil on success — and is shown, not swallowed:
    # an operator who set a path and sees no field names needs to know whether the file was
    # missing, was the `.proto` source, or simply covers different services.
    #
    # `path` is the file path for a File source and the reflected TARGET
    # (`https://api.test:443`) for a Reflection one — in both cases the thing the operator
    # names to change or remove it.
    record Source,
      path : String,
      error : String? = nil,
      messages : Int32 = 0,
      methods : Int32 = 0,
      origin : Origin = Origin::File do
      # The short label a status line or a settings row shows. A file is named by its
      # basename (the directory is in the field beside it); a reflection source is named by
      # its target, because there is no field anywhere that already shows it.
      def label : String
        origin.reflection? ? path : (File.basename(path).presence || path)
      end
    end

    # A captured gRPC path, bound to the message type it carries.
    record Binding,
      schema : Schema,
      method : Schema::MethodDef,
      type : Schema::MessageType,
      request : Bool

    # The merged schema, or nil when nothing loaded — which is the default and, per #823's
    # last acceptance criterion, must leave every surface byte-identical to before.
    class_getter schema : Schema? = nil
    class_getter sources : Array(Source) = [] of Source
    class_getter spec : String = ""

    # Bumped whatever `apply` does. The gRPC panes bake their rows into a cache, so a schema
    # loaded from the Project pane would otherwise leave the flow already on screen rendering
    # through the OLD lens until something unrelated invalidated it — the same trap
    # `Theme.revision` exists for, answered the same way.
    class_getter revision : Int32 = 0

    # The reflected descriptor sets in play, in fetch order — the project's cache as of the
    # last `load_project` / `adopt` / `forget`. Held here rather than re-read from the Store
    # on every `apply` for the reason the whole module exists: the four rendering surfaces
    # have no Store in hand, and `apply` is called from a settings edit that must not turn
    # into a database read on the UI fiber.
    class_getter reflections : Array(Store::GrpcReflection) = [] of Store::GrpcReflection

    # Publish the open project's schema: the descriptor-set path from settings, plus every
    # target this project has already reflected against. Never raises — a project must open
    # even when its descriptor path is gone, and the failure is reported through `sources`.
    #
    # Reads the cache; sends nothing. The one place a reflection REQUEST is made is
    # `Protobuf::Reflection::Client#fetch`, from a verb / CLI command / MCP tool (P4).
    def self.load_project(store : Store) : Nil
      @@reflections = store.grpc_reflections
      apply(store.setting(SETTING_KEY))
    rescue ex
      # `clear`, NOT `apply(nil)`. A blank spec means the convention directory, so falling back
      # to it here would load ANOTHER engagement's `.proto` over these bytes — and then report
      # "nothing loaded", because the error record below replaces the sources that describe it.
      # When gori cannot read what this project asked for, it applies no lens at all.
      clear
      @@sources = [Source.new("", error: "could not read the project setting: #{ex.message}")]
    end

    # Load `spec` — a file, a directory, or blank for the convention directory — replacing
    # whatever was loaded before. A REPLACEMENT and not a merge: carrying one project's
    # `.proto` into the next would put another engagement's field names over these bytes.
    #
    # The reflected sources ride through unchanged: `spec` is the FILE half of the answer,
    # and an operator editing the path in Project settings has not withdrawn a fetch they ran.
    # `forget` is how a reflected target is removed.
    def self.apply(spec : String?) : Nil
      @@spec = spec.try(&.strip) || ""
      rebuild
    end

    # Adopt a completed reflection fetch: remember it in the project (so one fetch serves
    # every flow on that target, and survives a restart) and re-publish the merged schema.
    # Returns whether the row COMMITTED — the schema is applied either way, on the trade
    # `Runner#apply_project_protos` already states: the operator asked to look through these
    # descriptors, and a busy writer must not be the reason they cannot.
    def self.adopt(store : Store, target : String, service : String, services : Int32,
                   files : Int32, descriptor : Bytes) : Bool
      committed = store.put_grpc_reflection(target, service, services, files, descriptor)
      # Re-read rather than splice the row in by hand: the Store is what orders them and what
      # the next `load_project` will replay, and two constructions of one list is how they
      # come to disagree.
      @@reflections = store.grpc_reflections
      rebuild
      committed
    end

    # Drop one reflected target (or every one, with a nil target) and re-publish. The
    # operator's exit from a schema they fetched — nothing here expires on its own.
    def self.forget(store : Store, target : String?) : Bool
      committed = target ? store.delete_grpc_reflection(target) : store.clear_grpc_reflections
      @@reflections = store.grpc_reflections
      rebuild
      committed
    end

    def self.clear : Nil
      @@schema = nil
      @@sources = [] of Source
      @@spec = ""
      @@dropped = 0
      @@reflections = [] of Store::GrpcReflection
      @@revision += 1
    end

    # Merge everything in play into one published schema. The ONE place `@@schema`,
    # `@@sources` and `@@revision` are written together, so a caller cannot advance one
    # without the others — which is the trap `revision` exists to close.
    private def self.rebuild : Nil
      @@dropped = 0
      paths, error = resolve_paths(@@spec)
      merged = Schema.new
      sources = [] of Source
      if error
        sources << Source.new(@@spec, error: error)
      else
        paths.each { |p| sources << load_file(merged, p) }
      end
      @@reflections.each { |r| sources << absorb_reflection(merged, r) }
      @@schema = merged.empty? ? nil : merged
      @@sources = sources
      @@revision += 1
    end

    # One cached reflection target folded into the merged schema. Parsed by `Schema.parse` —
    # the SAME entry point a file goes through — which is what makes #827's third acceptance
    # criterion ("fetched descriptors resolve exactly as a file-loaded set does") true by
    # construction rather than by a parallel reader.
    private def self.absorb_reflection(into : Schema, row : Store::GrpcReflection) : Source
      case parsed = Schema.parse(row.descriptor)
      in String
        Source.new(row.target, error: parsed, origin: Origin::Reflection)
      in Schema
        before_msgs = into.messages.size
        before_rpcs = into.methods.size
        into.merge!(parsed)
        Source.new(row.target,
          messages: into.messages.size - before_msgs,
          methods: into.methods.size - before_rpcs,
          origin: Origin::Reflection)
      end
    rescue ex
      Source.new(row.target, error: ex.message || "could not be read", origin: Origin::Reflection)
    end

    # Whether anything was lost — a file that failed to parse, or one the directory cap
    # dropped. What the settings row colours on, so a partial load does not read as a clean one.
    def self.errors? : Bool
      @@sources.any?(&.error) || @@dropped > 0
    end

    # One line for the operator: what loaded, or why nothing did. The Project settings row
    # and the commit toast both show it, so "I set the path and nothing changed" always has
    # an answer on screen.
    def self.status : String
      return "no descriptor set loaded" if @@sources.empty?
      if (bad = @@sources.select(&.error)) && bad.size == @@sources.size
        return bad.size == 1 ? "#{bad[0].label}: #{bad[0].error}" : "#{bad.size} sources failed to load"
      end
      s = @@schema
      msgs = s.try(&.messages.size) || 0
      rpcs = s.try(&.methods.size) || 0
      loaded = @@sources.select { |src| src.error.nil? }
      files = loaded.count(&.origin.file?)
      reflected = loaded.select(&.origin.reflection?)
      # WHERE the schema came from, named on the row itself — #827's fourth acceptance
      # criterion. One target is named; several are counted, because the row has one line.
      # A count of zero for either half is LEFT OUT rather than printed: "0 files · reflection
      # https://api.test" reads as a partial failure, and a project that only ever reflected
      # has no file to have failed.
      where = [] of String
      where << "#{files} file#{files == 1 ? "" : "s"}" if files > 0 || reflected.empty?
      unless reflected.empty?
        where << (reflected.size == 1 ? "reflection #{reflected[0].path}" : "reflection ×#{reflected.size}")
      end
      line = where.join(" · ")
      line += " · #{msgs} message#{msgs == 1 ? "" : "s"} · #{rpcs} rpc#{rpcs == 1 ? "" : "s"}"
      line += " · #{bad.size} failed" unless bad.empty?
      line += " · #{@@dropped} over the #{MAX_FILES}-file limit" if @@dropped > 0
      line += " · #{s.conflicts} redefined" if s && s.conflicts > 0
      line
    end

    # The message a captured gRPC exchange carries, or nil when nothing resolves — no
    # schema, a target that is not a gRPC method path, a method this schema does not
    # declare, or a message type the set is missing. Every one of those falls back to the
    # schema-less rendering, which is the whole point: the lens is optional.
    def self.resolve(target : String?, *, request : Bool) : Binding?
      s = @@schema || return nil
      t = target || return nil
      m = s.method?(method_path(t)) || return nil
      type = s.message?(request ? m.input_type : m.output_type) || return nil
      Binding.new(s, m, type, request)
    end

    # The `/package.Service/Method` half of a captured target. gRPC has no query string, but
    # a stored target can be absolute-form (a proxied absolute request line), and a
    # grpc-web call from a browser can carry one, so both are trimmed off.
    def self.method_path(target : String) : String
      p = Url.origin_path(target)
      if i = p.index('?')
        p = p[0, i]
      end
      if i = p.index('#')
        p = p[0, i]
      end
      p
    end

    # --- loading ------------------------------------------------------------

    # The files a spec names, in load order, plus the reason there are none. A blank spec is
    # the convention directory and an ABSENT convention directory is not an error — that is
    # the state every project starts in.
    private def self.resolve_paths(spec : String) : {Array(String), String?}
      if spec.empty?
        dir = Paths.protos_dir
        return {Dir.exists?(dir) ? descriptor_files(dir) : [] of String, nil}
      end
      path = expand(spec)
      return {descriptor_files(path), nil} if Dir.exists?(path)
      return {[path], nil} if File.exists?(path)
      {[] of String, "no such file or directory"}
    end

    # Files a directory held past MAX_FILES, counted so `status` can name them. A silent
    # truncation is the one failure this row cannot afford: an rpc declared only in a dropped
    # file resolves to nil and renders schema-less, which reads exactly like "that rpc is not
    # in my `.proto`". This module already counts `conflicts` rather than swallowing them.
    class_getter dropped : Int32 = 0

    # A bare name (no separator) is looked up in the convention directory first and then
    # relative to the working directory — the same rule the Fuzzer's wordlist field uses, so
    # dropping `api.desc` into `~/.gori/protos/` and typing `api.desc` works.
    private def self.expand(spec : String) : String
      p = Path[spec].expand(home: true).to_s
      return p if spec.includes?(File::SEPARATOR) || spec.starts_with?('~')
      candidate = File.join(Paths.protos_dir, spec)
      File.exists?(candidate) || Dir.exists?(candidate) ? candidate : p
    end

    private def self.descriptor_files(dir : String) : Array(String)
      named = Dir.children(dir)
        .select { |n| EXTENSIONS.includes?(File.extname(n).downcase) }
        .sort!
        .map { |n| File.join(dir, n) }
        .select { |p| File.file?(p) }
      @@dropped += {named.size - MAX_FILES, 0}.max
      named.first(MAX_FILES)
    rescue
      [] of String
    end

    private def self.load_file(into : Schema, path : String) : Source
      size = File.size(path)
      if size > MAX_FILE_BYTES
        return Source.new(path, error: "#{size} bytes — larger than the #{MAX_FILE_BYTES // (1024 * 1024)} MiB descriptor-set limit")
      end
      data = File.open(path, "rb") do |f|
        buf = Bytes.new(size.to_i)
        f.read_fully(buf)
        buf
      end
      case parsed = Schema.parse(data)
      in String
        Source.new(path, error: parsed)
      in Schema
        before_msgs = into.messages.size
        before_rpcs = into.methods.size
        into.merge!(parsed)
        Source.new(path,
          messages: into.messages.size - before_msgs,
          methods: into.methods.size - before_rpcs)
      end
    rescue ex
      Source.new(path, error: ex.message || "could not be read")
    end
  end
end
