require "./paths"

module Gori
  # Resolved runtime configuration (from CLI flags + defaults).
  struct Config
    property listen : String
    property port : Int32
    property db_path : String
    property ca_dir : String
    property? insecure_upstream : Bool

    def initialize(@listen : String = "127.0.0.1", @port : Int32 = 8070,
                   @db_path : String = Paths.default_db, @ca_dir : String = Paths.default_ca_dir,
                   @insecure_upstream : Bool = false)
    end
  end
end
