require "../env_migration"

module Gori
  module EnvMigration
    # The GLOBAL rewrite rules — `rewriter.rules` in settings.json, the ones that rewrite traffic
    # in EVERY project — re-spelled when this install's token grammar moves.
    #
    # They are the half of the migration a project database cannot reach: a `$token` in a global
    # rule's `replacement` goes quiet the moment the grammar changes under it, and nothing in any
    # project DB would say so. The per-project reconcile (`env_migration/store.cr`) walks rows;
    # this walks the one file that sits above all of them.
    #
    # Rewritten as `Kind::Rule`: `Rules#substitute` owns `$$` and `$1..$9` in BOTH grammars, so
    # only the token spelling follows the syntax.

    # What a re-spelling of the global rules did. Nil is returned instead when nothing changed,
    # so a caller never has to test the counters to decide whether to speak.
    record GlobalReport,
      from : Env::Syntax,
      to : Env::Syntax,
      rules : Int32,
      tokens : Int32,
      backup : String? do
      # The one line every surface prints for this. The counters first (what moved), the backup
      # last (how to get back) — the same shape as the per-project line.
      def line : String
        tail = (b = backup) ? " — backup at #{b}" : ""
        "global rewrite rules: #{EnvMigration.counted(tokens, "token")} re-spelled to " \
        "#{EnvMigration.spelling(to)} in #{EnvMigration.counted(rules, "rule")}#{tail}"
      end
    end

    # Re-spell every global rule's `replacement` from `from` into `to`, in memory, and copy
    # settings.json aside FIRST when anything actually changes.
    #
    # Does NOT save: the caller owns that write, because both callers have another reason to save
    # in the same breath (`Settings.load` is also writing the `env.syntax` key it just decided,
    # and the CLI verb the grammar the operator typed). Two saves would write the file twice and
    # give the 3-way merge a base that already holds half the change.
    #
    # `env_names` / `bind_names` are the tables the OLD grammar resolved a bare `$NAME` out of. At
    # `Settings.load` time only the GLOBAL env vars are known — there is no project open, and
    # opening every project to read its tables is not something a settings load may do — so a
    # global rule that names a project var or an extract rule is re-spelled later, by the
    # project-open reconcile that DOES know those names (it passes them in here).
    def self.migrate_global_rules(*, from : Env::Syntax, to : Env::Syntax,
                                  env_names : Enumerable(String)? = nil,
                                  bind_names : Enumerable(String) = [] of String) : GlobalReport?
      return nil if from == to
      rules = Settings.rewriter_rules
      return nil if rules.empty?
      env = (env_names || Settings.env_vars.map(&.[0])).to_set
      bind = bind_names.to_set
      touched = 0
      tokens = 0
      migrated = rules.map do |rule|
        next rule if rule.replacement.empty?
        after, changes = rewrite(rule.replacement.to_slice, from: from, to: to,
          env_names: env, bind_names: bind, kind: Kind::Rule, prefix: Settings.env_prefix)
        next rule unless changes.size > 0
        touched += 1
        tokens += changes.size
        rule.copy_with(replacement: String.new(after))
      end
      return nil if touched.zero?
      backup = backup_settings_file(to)
      Settings.rewriter_rules = migrated
      GlobalReport.new(from, to, touched, tokens, backup)
    end

    # `settings.json.pre-namespaced-20260913-142530` beside the file, before the rules in it are
    # rewritten. A COPY rather than a rename: the live file must keep working for a peer process
    # that has it open, and the operator's way back is a file they can diff and move into place.
    #
    # Best-effort by design — a home that cannot be written to is a home whose settings.json is
    # about to fail its save too, and the report says "no backup" rather than refusing the
    # re-spelling of a grammar this install has already adopted for reading.
    private def self.backup_settings_file(to : Env::Syntax) : String?
      path = Settings.path
      return nil unless File.exists?(path)
      dest = unique_path("#{path}.pre-#{to.to_s.downcase}-#{stamp}")
      File.copy(path, dest)
      File.chmod(dest, 0o600) rescue nil
      dest
    rescue
      nil
    end

    # `%Y%m%d-%H%M%S`, LOCAL: the operator reads this name in a directory listing next to files
    # their own shell wrote, and a UTC stamp there reads as an hour that never happened.
    def self.stamp : String
      Time.local.to_s("%Y%m%d-%H%M%S")
    end

    # A path nothing occupies yet. Two migrations in one second is not a case worth losing a
    # backup over.
    def self.unique_path(base : String) : String
      return base unless File.exists?(base)
      n = 2
      while File.exists?("#{base}.#{n}")
        n += 1
      end
      "#{base}.#{n}"
    end

    # How a token is SPELLED in `syntax`, for the report line. Through `Env.spell` so a non-default
    # prefix shows, and BOTH namespaces, because the line has to be as true of a binding as of an
    # env var — `$ENV.KEY/$BIND.NAME` namespaced, `$KEY/$NAME` bare.
    def self.spelling(syntax : Env::Syntax) : String
      "#{Env.spell("KEY", Env::Namespace::Env, syntax)}/#{Env.spell("NAME", Env::Namespace::Bind, syntax)}"
    end

    def self.counted(n : Int32, noun : String) : String
      "#{n} #{noun}#{n == 1 ? "" : "s"}"
    end
  end
end
