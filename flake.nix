{
  description = "gori: a fast, keyboard-driven HTTP/HTTPS intercepting proxy and web-hacking workbench for the terminal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Not eachDefaultSystem: that set includes x86_64-darwin, which nixpkgs 26.11
      # dropped outright, so every output would fail to even evaluate there (and take
      # `nix flake show` down with it). Intel macOS installs via Homebrew or the
      # release tarball instead.
      #
      # Bound once and read by both `eachSystem` and `meta.platforms`: written out
      # twice, the pair drifts the first time a system is added or restored, and the
      # two failures are silent in opposite directions — a flake output for a platform
      # `meta` calls unsupported, or a `meta` claim no output backs.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

      # Takes a package set rather than closing over this flake's own `nixpkgs`, so
      # the same definition can serve `overlays.default` below: an overlay that
      # reached back into this flake's nixpkgs would build gori against a different
      # stdenv than the one it is being applied to, which is how an overlay ends up
      # dragging a second glibc/openssl into a consumer's closure.
      mkGori = pkgs:
        let
          inherit (pkgs) lib;

          # nixpkgs still ships Crystal 1.19.1, which is below shard.yml's
          # `crystal: '>= 1.21.0'` and does not compile gori: src/gori/proxy/
          # socket_tuning.cr reopens OpenSSL::SSL::Socket to reach `#bio`, which only
          # exists from 1.20 on. So pin the version gori's CI builds with instead.
          # Delete this override (and use pkgs.crystal) once nixpkgs is >= 1.21.0.
          crystalVersion = "1.21.0";
          # `or (throw …)` because `overlays.default` runs this against a package set
          # this flake does not pin. Nixpkgs' own "attribute 'crystal_1_19' missing"
          # surfaces inside a consumer's `nixpkgs.overlays` with nothing naming gori,
          # so say which flake asked and what to do about it.
          crystalBase = pkgs.crystal_1_19 or (throw
            ("gori flake: this nixpkgs has no `crystal_1_19` to pin 1.21.0 onto. "
              + "If it now ships Crystal >= 1.21.0, drop the override in flake.nix and use pkgs.crystal."));
          crystal = crystalBase.overrideAttrs (old: {
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
            #
            # Checked, not assumed: `replaceStrings` returns the subject UNCHANGED when
            # the needle is absent, so against a nixpkgs whose installPhase has moved on
            # (which the overlay makes possible — see `crystalBase` above) the patch
            # would silently no-op and the compiler build would die minutes later on a
            # missing man page, with nothing pointing back here.
            installPhase =
              let
                needle = "installManPage man/crystal.1";
                patched = builtins.replaceStrings [ needle ] [ "" ] old.installPhase;
              in
              if patched == old.installPhase then
                throw "gori flake: nixpkgs' crystal installPhase no longer contains `${needle}` — re-check the man-page workaround in flake.nix."
              else
                patched;
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
          # `lib/` itself from nix/shards.nix, so a checkout that already ran `shards
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
        in
        crystal.buildCrystalPackage {
          pname = "gori";
          version = "0.4.0";

          inherit src;

          # `crystal` (not `shards`) as the builder: `lib/` is already materialised
          # from nix/shards.nix during configurePhase, so going through shards would
          # only add a dependency resolution step that the sandbox has no network for.
          format = "crystal";
          shardsFile = ./nix/shards.nix;

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
            changelog = "https://github.com/hahwul/gori/blob/main/CHANGELOG.md";
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
            # NOT `crystal.meta.platforms`, which buildCrystalPackage would otherwise
            # default this to: that set is every platform the compiler builds on, and
            # it would advertise the Intel macOS `supportedSystems` leaves out.
            platforms = supportedSystems;
          };
        };
    in
    {
      # The idiomatic entry point for a NixOS or home-manager config that already
      # threads its own `pkgs`: add this overlay once and `pkgs.gori` exists
      # everywhere, instead of spelling `inputs.gori.packages.${system}.default` out
      # at each use site. `final`, not `prev`, so a consumer's later overlays are
      # visible to the build.
      overlays.default = final: _prev: { gori = mkGori final; };
    }
    // flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        gori = mkGori pkgs;
      in
      {
        packages.default = gori;
        packages.gori = gori;

        apps.default = flake-utils.lib.mkApp { drv = gori; };
        # `nix run github:hahwul/gori#gori` — the spelling anyone who has read
        # `packages.gori` will reach for first, and an app output is not implied by a
        # package one, so without this line that command fails with "does not provide
        # attribute apps.<system>.gori".
        apps.gori = flake-utils.lib.mkApp { drv = gori; };

        checks.default = gori;
        # `checks.default` is built from `mkGori pkgs` directly, which is NOT the code
        # path `overlays.default` takes — so without this the overlay is a public
        # output nothing ever evaluates, and a typo in the attribute name or a
        # self-reference that recurses would first be reported by a NixOS user whose
        # `nixos-rebuild` stopped evaluating. Same derivation when both are healthy, so
        # `nix flake check` pays for it once.
        checks.overlay = (import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        }).gori;

        devShells.default = pkgs.mkShell {
          # crystal + the linked libraries, straight from the package definition.
          inputsFrom = [ gori ];
          # `shards` is absent from a format = "crystal" build; the dev loop needs it,
          # plus `just` for the task runner and `crystal2nix` to regenerate
          # nix/shards.nix whenever shard.lock moves.
          nativeBuildInputs = with pkgs; [ shards crystal2nix just git ];

          shellHook = ''
            echo "gori dev shell (crystal $(crystal version | head -n1 | cut -d' ' -f2))"
            echo "  just build   # bin/gori (debug)   just test   # crystal spec"
            echo "  after editing shard.lock: just nix-shards && just nix-shards-check"
          '';
        };
      });
}
