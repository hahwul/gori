{
  description = "gori: a fast, keyboard-driven HTTP/HTTPS intercepting proxy and web-hacking workbench for the terminal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # Not eachDefaultSystem: that set includes x86_64-darwin, which nixpkgs 26.11
    # dropped outright, so every output would fail to even evaluate there (and take
    # `nix flake show` down with it). Intel macOS installs via Homebrew or the
    # release tarball instead.
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        # nixpkgs still ships Crystal 1.19.1, which is below shard.yml's
        # `crystal: '>= 1.20.2'` and does not compile gori: src/gori/proxy/
        # socket_tuning.cr reopens OpenSSL::SSL::Socket to reach `#bio`, which only
        # exists from 1.20 on. So pin the version gori's CI builds with instead.
        # Delete this override (and use pkgs.crystal) once nixpkgs is >= 1.20.2.
        crystalVersion = "1.21.0";
        crystal = pkgs.crystal_1_19.overrideAttrs (old: {
          version = crystalVersion;
          src = pkgs.fetchFromGitHub {
            owner = "crystal-lang";
            repo = "crystal";
            rev = crystalVersion;
            hash = "sha256-QnFj6JIWdfkTLKvqT3R9LwdImwunkLz+YTDVmPtKSzk=";
          };
          makeFlags = [ "CRYSTAL_CONFIG_VERSION=${crystalVersion}" "progress=1" ];
          # 1.21 stopped shipping a pre-generated man/crystal.1 — it is rendered from
          # doc/man/*.adoc by a make target nixpkgs' buildFlags do not run, so the
          # stock installPhase dies on it. Dropping that one line beats pulling
          # asciidoctor into the compiler build for a page nothing here reads.
          installPhase = builtins.replaceStrings
            [ "installManPage man/crystal.1" ] [ "" ] old.installPhase;
        });

        # Libraries gori links on top of what the `crystal` wrapper already puts on
        # CRYSTAL_LIBRARY_PATH (openssl, libyaml, zlib, pcre2, boehm-gc, libevent):
        #
        #   brotli -> src/gori/proxy/codec/brotli.cr  @[Link(pkg_config: "libbrotlidec")]
        #   zstd   -> src/gori/proxy/codec/zstd.cr    @[Link(pkg_config: "libzstd")]
        #   sqlite -> the sqlite3 shard               @[Link("sqlite3")]
        #   gmp    -> src/gori/decoder/codecs.cr      `require "big"`
        #
        # gmp is easy to miss: nixpkgs' crystal lists it under nativeCheckInputs only,
        # so the stdlib emits `-lgmp` with no `-L` to match and the link dies.
        # brotli/zstd resolve through pkg-config, so they need their `dev` outputs —
        # which is exactly what listing them in buildInputs arranges.
        nativeLibs = with pkgs; [ brotli zstd sqlite gmp ];

        # `lib/` and `bin/` are shards' working dirs: buildCrystalPackage populates
        # `lib/` itself from shards.nix, so a checkout that already ran `shards
        # install` must not leak its copy into the sandbox. `docs/` is the website
        # and is never compiled — dropping it keeps doc edits from busting the
        # build's input hash.
        src = lib.cleanSourceWith {
          name = "gori-source";
          src = lib.cleanSource ./.;
          filter = path: type:
            let base = baseNameOf (toString path);
            in !(type == "directory" && (base == "lib" || base == "bin" || base == "docs"));
        };

        gori = crystal.buildCrystalPackage {
          pname = "gori";
          version = "0.1.3";

          inherit src;

          # `crystal` (not `shards`) as the builder: `lib/` is already materialised
          # from shards.nix during configurePhase, so going through shards would only
          # add a dependency resolution step that the sandbox has no network for.
          format = "crystal";
          shardsFile = ./shards.nix;

          crystalBinaries.gori.src = "src/main.cr";
          # Deliberately NO `-Dpreview_mt`: Store, Fuzz::Engine, Miner::Engine and
          # Store::SafeRegexp rely on the single-threaded fiber scheduler for their
          # unguarded ivars. See the comments in those files before changing this.
          crystalBinaries.gori.options = [ "--release" "--no-debug" "--progress" ];

          buildInputs = nativeLibs;

          # The suite binds real ports and spawns proxies; leave it to CI.
          doCheck = false;

          meta = {
            description = "A fast, keyboard-driven HTTP/HTTPS intercepting proxy and web-hacking workbench for the terminal";
            homepage = "https://gori.hahwul.com";
            downloadPage = "https://github.com/hahwul/gori/releases";
            license = lib.licenses.asl20;
            # An attrset, not a bare string: nixpkgs types this as `listOf attrs`
            # (check-meta.nix), and anything reading meta.maintainers expects the
            # maintainer shape. No lib.maintainers.hahwul exists to reference yet.
            maintainers = [{
              name = "hahwul";
              email = "hahwul@gmail.com";
              github = "hahwul";
              githubId = 13212227;
            }];
            mainProgram = "gori";
          };
        };
      in
      {
        packages.default = gori;
        packages.gori = gori;

        apps.default = flake-utils.lib.mkApp { drv = gori; };

        checks.default = gori;

        devShells.default = pkgs.mkShell {
          # crystal + the linked libraries, straight from the package definition.
          inputsFrom = [ gori ];
          # `shards` is absent from a format = "crystal" build; the dev loop needs it,
          # plus `just` for the task runner and `crystal2nix` to regenerate shards.nix
          # whenever shard.lock moves.
          nativeBuildInputs = with pkgs; [ shards crystal2nix just git ];

          shellHook = ''
            echo "gori dev shell (crystal $(crystal version | head -n1 | cut -d' ' -f2))"
            echo "  just build   # bin/gori (debug)   just test   # crystal spec"
            echo "  after editing shard.lock: crystal2nix && git add shards.nix"
          '';
        };
      });
}
