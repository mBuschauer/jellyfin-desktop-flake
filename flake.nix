{
  description = "Jellyfin Desktop Client (Rust + CEF + mpv)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    jellyfin-desktop-src = {
      url = "git+https://github.com/jellyfin/jellyfin-desktop.git?submodules=1";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      jellyfin-desktop-src,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # App version comes straight from the Cargo workspace manifest.
      cargoToml = fromTOML (builtins.readFile "${jellyfin-desktop-src}/src/Cargo.toml");
      appVersion = cargoToml.workspace.package.version;

      # Shared by the `cef` fetcher and the main package: both vendor the same
      # workspace lockfile and need the hash for the one git dependency.
      cargoLock = {
        lockFile = "${jellyfin-desktop-src}/src/Cargo.lock";
        outputHashes = {
          "wl-proxy-0.1.2" = "sha256-8NMNPhBSW2gLXc9bwyg2kmHb12XIaV6b4PjM62xLldQ=";
        };
      };

      # Fixed-output derivation that downloads the prebuilt Chromium Embedded
      # Framework via `cargo xtask fetch-cef`. It is an FOD (pinned by
      # `outputHash`) so the network fetch is allowed; `cargoLock` is only here
      # so the xtask crate itself can build offline.
      cef = pkgs.rustPlatform.buildRustPackage {
        pname = "jellyfin-desktop-cef";
        version = appVersion;
        src = jellyfin-desktop-src;
        sourceRoot = "source";

        inherit cargoLock;

        nativeBuildInputs = [
          pkgs.cacert
          pkgs.pkg-config
          pkgs.python3
        ];

        dontCargoBuild = true;
        dontCargoInstall = true;
        doCheck = false;

        postUnpack = ''
          ln -s src/Cargo.lock $sourceRoot/Cargo.lock
        '';

        buildPhase = ''
          # CA certs so the CEF download over HTTPS succeeds.
          export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          cargo xtask fetch-cef
        '';

        installPhase = ''
          mkdir -p $out
          cp -r .cache/cef/* $out/
        '';

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-xT6q/kDUwbRT/3GVnW70C4QbdTytk21gyDeovTTg4/Q=";
      };

      # mpv built from the vendored sources in `third_party/mpv`, exposing libmpv.
      mpv = pkgs.mpv-unwrapped.overrideAttrs (old: {
        pname = "jellyfin-desktop-mpv";
        src = jellyfin-desktop-src;
        sourceRoot = "source/third_party/mpv";
        postPatch =
          # Make upstream's now-stale substitution non-fatal instead of erroring.
          builtins.replaceStrings [ "--replace-fail" ] [ "--replace-quiet" ] (old.postPatch or "")
          # Re-apply the reproducibility strip against the actual vendored line.
          + ''
            substituteInPlace meson.build \
              --replace-fail "meson.build_options()" "'''"
          '';

        mesonFlags = (old.mesonFlags or [ ]) ++ [
          "-Dlibmpv=true"
          "-Dalsa=disabled"
        ];
        doCheck = false;
        doInstallCheck = false;
      });

      # Build-time tools.
      nativeBuildDeps = with pkgs; [
        pkg-config
        python3
        makeWrapper
        autoPatchelfHook
        rustPlatform.bindgenHook
      ];

      # Libraries linked into / loaded by the app at build and run time.
      buildDeps = with pkgs; [
        mpv
        ffmpeg

        wayland
        libglvnd
        libxcb
        libxkbcommon
        xcbutilcursor
        systemd
        mesa

        alsa-lib
        atk
        at-spi2-core
        at-spi2-atk
        cairo
        cups
        dbus
        expat
        fontconfig
        freetype
        gdk-pixbuf
        glib
        gtk3
        nspr
        nss
        pango
        libX11
        libXcomposite
        libXdamage
        libXext
        libXfixes
        libXi
        libXrandr
        libXrender
        libXtst
        xcbutil
        xcbutilkeysyms
      ];

      jellyfin-desktop = pkgs.rustPlatform.buildRustPackage {
        pname = "jellyfin-desktop";
        version = appVersion;
        src = jellyfin-desktop-src;
        sourceRoot = "source";

        inherit cargoLock;

        buildAndTestSubdir = "src";

        nativeBuildInputs = nativeBuildDeps;
        buildInputs = buildDeps;

        # The real build is driven by the project's xtask, not cargo directly.
        dontCargoBuild = true;
        dontCargoInstall = true;
        doCheck = false;

        CEF_PATH = "${cef}";
        EXTERNAL_MPV_DIR = "${mpv}";

        # Tell the linker where to find CEF's transitive dependencies at build time.
        NIX_LDFLAGS = "-rpath-link ${lib.makeLibraryPath buildDeps}";

        postUnpack = ''
          ln -s src/Cargo.lock $sourceRoot/Cargo.lock

          # `cargo xtask install` patches and strips CEF/mpv, so it needs writable
          # copies — the Nix store originals are read-only, which would otherwise
          # cause "Permission denied" (OS error 13).
          cp -rL ${cef} $NIX_BUILD_TOP/writable-cef
          chmod -R u+w $NIX_BUILD_TOP/writable-cef

          cp -rL ${mpv} $NIX_BUILD_TOP/writable-mpv
          chmod -R u+w $NIX_BUILD_TOP/writable-mpv
        '';

        buildPhase = ''
          runHook preBuild

          cargo xtask build \
            --external-cef "$NIX_BUILD_TOP/writable-cef" \
            --external-mpv "$NIX_BUILD_TOP/writable-mpv" \
            --no-kde-palette \
            --out build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          # Let the project's xtask stage CEF, libmpv, and the binary.
          cargo xtask install \
            --external-cef "$NIX_BUILD_TOP/writable-cef" \
            --external-mpv "$NIX_BUILD_TOP/writable-mpv" \
            --no-kde-palette \
            --prefix "$out/opt/jellyfin-desktop"

          patchelf --set-rpath "\$ORIGIN" $out/opt/jellyfin-desktop/jellyfin-desktop

          # Symlink into /bin and wrap so the GPU drivers resolve at runtime.
          mkdir -p $out/bin
          makeWrapper $out/opt/jellyfin-desktop/jellyfin-desktop $out/bin/jellyfin-desktop \
            --prefix LD_LIBRARY_PATH : ${
              lib.makeLibraryPath [
                pkgs.libglvnd
                pkgs.mesa
              ]
            }

          # Desktop entry and icon.
          install -Dm644 resources/linux/org.jellyfin.JellyfinDesktop.svg \
            $out/share/icons/hicolor/scalable/apps/org.jellyfin.JellyfinDesktop.svg
          install -Dm644 resources/linux/org.jellyfin.JellyfinDesktop.desktop \
            $out/share/applications/org.jellyfin.JellyfinDesktop.desktop

          runHook postInstall
        '';

        meta = {
          description = "Jellyfin Desktop Client";
          homepage = "https://github.com/jellyfin/jellyfin-desktop";
          license = lib.licenses.gpl2Only;
          platforms = [ "x86_64-linux" ];
          mainProgram = "jellyfin-desktop";
        };
      };
    in
    {
      packages.${system} = {
        default = jellyfin-desktop;
        inherit jellyfin-desktop cef mpv;
      };

      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs =
          nativeBuildDeps
          ++ (with pkgs; [
            just
            git
            rustc
            cargo
          ]);
        buildInputs = buildDeps;

        CEF_PATH = "${cef}";
        EXTERNAL_MPV_DIR = "${mpv}";

        shellHook = ''
          echo "Jellyfin Desktop Dev Environment (Rust Edition)"
          echo "CEF is at: $CEF_PATH"
          echo "MPV is at: $EXTERNAL_MPV_DIR"
        '';
      };

      apps.${system}.default = {
        type = "app";
        program = lib.getExe jellyfin-desktop;
      };
    };
}
