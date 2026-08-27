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
  # ## Loading a file is not an outbound action
  #
  # P4 constrains gori from touching the network unasked; reading a descriptor set the
  # operator dropped in their own directory is neither a request nor a disclosure. Server
  # REFLECTION — the other schema source #823 describes — IS an outbound request and is a
  # separate, operator-initiated path that does not exist yet.
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

    # One file the loader tried. `error` is nil on success — and is shown, not swallowed:
    # an operator who set a path and sees no field names needs to know whether the file was
    # missing, was the `.proto` source, or simply covers different services.
    record Source,
      path : String,
      error : String? = nil,
      messages : Int32 = 0,
      methods : Int32 = 0

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

    # Publish the open project's schema. Never raises: a project must open even when its
    # descriptor path is gone, and the failure is reported through `sources`.
    def self.load_project(store : Store) : Nil
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
    def self.apply(spec : String?) : Nil
      @@spec = spec.try(&.strip) || ""
      @@dropped = 0
      paths, error = resolve_paths(@@spec)
      if error
        @@schema = nil
        @@sources = [Source.new(@@spec, error: error)]
        @@revision += 1
        return
      end
      merged = Schema.new
      sources = [] of Source
      paths.each { |p| sources << load_file(merged, p) }
      @@schema = merged.empty? ? nil : merged
      @@sources = sources
      @@revision += 1
    end

    def self.clear : Nil
      @@schema = nil
      @@sources = [] of Source
      @@spec = ""
      @@dropped = 0
      @@revision += 1
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
        return bad.size == 1 ? "#{File.basename(bad[0].path)}: #{bad[0].error}" : "#{bad.size} files failed to load"
      end
      s = @@schema
      msgs = s.try(&.messages.size) || 0
      rpcs = s.try(&.methods.size) || 0
      ok = @@sources.count { |src| src.error.nil? }
      line = "#{ok} file#{ok == 1 ? "" : "s"} · #{msgs} message#{msgs == 1 ? "" : "s"} · #{rpcs} rpc#{rpcs == 1 ? "" : "s"}"
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
