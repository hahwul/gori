require "json"
require "base64"

module Gori::Fuzz
  # Normalized options beyond the original tab format. Only prepared tabs write this
  # extension; ordinary and legacy tabs retain their existing serialized bytes.
  class SessionOptions
    include JSON::Serializable
    include JSON::Serializable::Strict

    property? auto_mark : Bool = false
    property marks : Array(String) = [] of String
    property? auto_encode : Bool = true
    property? verbatim : Bool = false
    property? verify : Bool = true
    property? include_sensitive : Bool = false
    property processors : Array(SavedProcessor) = [] of SavedProcessor
    property messages : Array(SavedMessage)? = nil
    property max_redirects : Int32 = 5
    property sse_events : Int32? = 50
    property sse_ms : Int64? = 5000_i64
    property ws_idle_ms : Int64 = 3000_i64
    property? ws_keep_key : Bool = false
    property? ws_deflate : Bool = false
    property race_warmup : String? = nil

    def initialize
    end

    def self.capture(options : PlanOptions) : SessionOptions
      new.tap do |saved|
        saved.auto_mark = options.auto_mark?
        saved.marks = options.marks
        saved.auto_encode = options.auto_encode?
        saved.verbatim = options.verbatim?
        saved.verify = options.verify?
        saved.processors = options.processors.map { |p| SavedProcessor.capture(p) }
        saved.messages = options.ws_messages.try(&.map { |m| SavedMessage.capture(m) })
        saved.max_redirects = options.config.max_redirects
        saved.sse_events = options.config.sse.try(&.max_events)
        saved.sse_ms = options.config.sse.try(&.max_time).try(&.total_milliseconds.to_i64)
        saved.ws_idle_ms = options.config.ws_idle.total_milliseconds.to_i64
        saved.ws_keep_key = options.config.ws_keep_key?
        saved.ws_deflate = options.config.ws_deflate?
        saved.race_warmup = options.config.race_warmup.try { |bytes| Base64.strict_encode(bytes) }
      end
    end

    # Rendering never builds a plan: that would count files, evaluate field payloads and
    # possibly run an exec chain. This preview only expands/marks text and parses positions.
    def position_count(text : String, evidence : Bool, http2 : Bool,
                       env_vars : Hash(String, String)? = nil) : Int32
      request = if @verbatim
                  text
                elsif evidence
                  env_vars ? Env.expand(text, env_vars, unescape: Env::Owns::None) : text
                else
                  String.new(Env.expand_wire(text))
                end
      marked = Plan.mark_text(request, @auto_mark, @marks)[0]
      count = Template.parse(marked, http2).position_count
      @messages.try(&.each do |message|
        frame = String.new(Base64.decode(message.payload))
        frame = Env.expand(frame) unless message.evidence? || @verbatim || message.opcode != Proxy::WS::OP_TEXT.to_i
        count += Template.parse(Plan.mark_text(frame, @auto_mark, @marks, message.opcode)[0]).position_count
      end)
      count
    rescue
      0
    end

    def summary : String
      parts = [] of String
      @messages.try { |messages| parts << "#{messages.size} WS frames" }
      parts << "#{@processors.size} processors" unless @processors.empty?
      parts << "auto positions" if @auto_mark
      parts << "#{@marks.size} mark tokens" unless @marks.empty?
      parts << "verbatim" if @verbatim
      parts.empty? ? "Additional options" : parts.join(" · ")
    end

    def apply(options : PlanOptions) : PlanOptions
      options.auto_mark = @auto_mark
      options.marks = @marks
      options.auto_encode = @auto_encode
      options.verbatim = @verbatim
      options.env_vars = nil if @verbatim
      options.verify = options.verify? && @verify
      options.processors = @processors.map(&.build)
      options.ws_messages = @messages.try(&.map(&.build))
      apply_config(options.config)
      options
    end

    def apply_config(config : Config) : Nil
      config.max_redirects = @max_redirects
      config.sse = @sse_events || @sse_ms ? Repeater::StreamBound.new(@sse_events, @sse_ms.try(&.milliseconds)) : nil
      config.ws_idle = @ws_idle_ms.milliseconds
      config.ws_keep_key = @ws_keep_key
      config.ws_deflate = @ws_deflate
      config.race_warmup = @race_warmup.try { |s| Base64.decode(s) }
    end
  end

  class SavedProcessor
    include JSON::Serializable
    include JSON::Serializable::Strict
    property type : String
    property value : String
    property replacement : String? = nil

    def initialize(@type, @value, @replacement = nil)
    end

    def self.capture(processor : Processor) : SavedProcessor
      case processor
      when Prefix       then new("prefix", processor.text)
      when Suffix       then new("suffix", processor.text)
      when Encode       then new("encode", processor.kind.to_s)
      when Case         then new("case", processor.kind.to_s)
      when Hasher       then new("hash", processor.algo.to_s)
      when RegexReplace then new("regex_replace", processor.pattern.source, processor.replacement)
      else                   raise Gori::Error.new("unknown persisted payload processor")
      end
    end

    def build : Processor
      case @type
      when "prefix"        then Prefix.new(@value)
      when "suffix"        then Suffix.new(@value)
      when "regex_replace" then RegexReplace.new(Regex.new(@value), @replacement || "")
      when "encode"        then build_encode
      when "case"
        raise Gori::Error.new("unknown persisted payload case") unless {"upper", "lower"}.includes?(@value)
        Case.new(@value == "upper" ? :upper : :lower)
      when "hash" then build_hash
      else
        raise Gori::Error.new("unknown persisted payload processor")
      end
    end

    private def build_encode : Processor
      kind = case @value
             when "url"     then :url
             when "url_all" then :url_all
             when "base64"  then :base64
             when "hex"     then :hex
             else                raise Gori::Error.new("unknown persisted payload encoding")
             end
      Encode.new(kind)
    end

    private def build_hash : Processor
      algo = case @value
             when "md5"    then :md5
             when "sha1"   then :sha1
             when "sha256" then :sha256
             else               raise Gori::Error.new("unknown persisted payload hash")
             end
      Hasher.new(algo)
    end
  end

  class SavedMessage
    include JSON::Serializable
    include JSON::Serializable::Strict
    property opcode : Int32
    property payload : String
    property? evidence : Bool
    property? fin : Bool
    property rsv : Int32
    property masked : Bool?
    property mask_key : String?
    property frames : Int32
    property declared_len : Int32?

    def initialize(@opcode, @payload, @evidence, @fin, @rsv, @masked, @mask_key, @frames, @declared_len)
    end

    def self.capture(message : WsMessageSource) : SavedMessage
      shape = message.shape
      new(message.opcode, Base64.strict_encode(message.payload.to_slice), message.evidence,
        shape.fin, shape.rsv, shape.masked, shape.mask_key.try { |b| Base64.strict_encode(b) },
        shape.frames, shape.declared_len)
    end

    def clear_marks : Nil
      text = String.new(Base64.decode(@payload))
      @payload = Base64.strict_encode(Template.clear_markers(text).to_slice)
    rescue Base64::Error
      # Keep an invalid imported payload inert and available for repair.
    end

    def build : WsMessageSource
      WsMessageSource.new(@opcode, String.new(Base64.decode(@payload)),
        Proxy::WS::Shape.new(@fin, @rsv, @masked, @mask_key.try { |s| Base64.decode(s) },
          @frames, @declared_len), @evidence)
    end
  end

  # A separate stop predicate uses the same dimensions as the main matcher. JSON avoids
  # inventing a separator that could collide with a regex or a response-header substring.
  class SavedMatcher
    include JSON::Serializable
    include JSON::Serializable::Strict
    {% for side in %w[match filter] %}
      {% for dim in %w[status grpc size words lines time header regex] %}
        property {{ side.id }}_{{ dim.id }} : String? = nil
      {% end %}
    {% end %}

    def initialize
    end

    def self.capture(matcher : Matcher) : SavedMatcher
      new.tap do |saved|
        {% for side in %w[match filter] %}
          {% for dim in %w[status grpc size words lines time header] %}
            saved.{{ side.id }}_{{ dim.id }} = matcher.{{ side.id }}_{{ dim.id }}
          {% end %}
          saved.{{ side.id }}_regex = matcher.{{ side.id }}_regex.try(&.source)
        {% end %}
      end
    end

    def build : Matcher
      Matcher.new.tap do |matcher|
        {% for side in %w[match filter] %}
          {% for dim in %w[status grpc size words lines time header] %}
            matcher.{{ side.id }}_{{ dim.id }} = @{{ side.id }}_{{ dim.id }}
          {% end %}
          matcher.{{ side.id }}_regex = @{{ side.id }}_regex.try { |pattern| Regex.new(pattern) }
        {% end %}
      end
    end
  end
end
