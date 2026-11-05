{
  description = "PdfCraft — native PDF workbench, in pure Rust";

  inputs = {
    # PdfCraft needs edition 2024 and rustc ≥ 1.95, so the flake tracks unstable. Consumers on a
    # release channel can retarget it: `inputs.pdfcraft.inputs.nixpkgs.follows = "nixpkgs";`
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # PdfCraft's OCR stack (rten-gemm 0.26) does not compile with rustc 1.99. The app CI uses
    # 1.96.0. Pin that toolchain locally instead of moving the whole suite.
    rust-overlay.url = "github:oxalica/rust-overlay";

    # Optional build input of the repository: the fonts that `crates/fonts/build.rs` embeds when
    # `CRAFT_FONTS_DIR` is set. Official releases always build with them; without them everything
    # works but non-Latin text lacks glyphs. Pinned to the revision `.github/workflows/release.yml`
    # fetches — bump both together (`nix flake update craft-fonts`).
    craft-fonts = {
      url = "github:storytold/craft-fonts/b076417b5880bd4154bd22f00695b1d28c6bea83";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      craft-fonts,
    }:
    let
      inherit (nixpkgs) lib;

      # No x86_64-darwin: the pinned nixpkgs dropped it. On an Intel Mac, retarget nixpkgs at a
      # release that still has it, or install the release build.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The AppStream metadata carries a release date. The flake source's own commit date is
      # reproducible, unlike "now"; a tarball or dirty tree without one falls back to the epoch.
      buildDate =
        let
          d = self.lastModifiedDate or "";
        in
        if builtins.stringLength d >= 8 then
          "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
        else
          "1970-01-01";

      packageArgs = {
        inherit craft-fonts buildDate;
      };

      rustFor =
        pkgs:
        pkgs.rust-bin.stable."1.96.0".default.override {
          extensions = [
            "clippy"
            "rust-analyzer"
            "rustfmt"
          ];
        };

      mkPackage =
        pkgs:
        pkgs.callPackage ./nix/package.nix (
          packageArgs
          // {
            rustPlatform = pkgs.makeRustPlatform {
              cargo = rustFor pkgs;
              rustc = rustFor pkgs;
            };
          }
        );

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

      forAllSystems = f: lib.genAttrs systems (system: f (pkgsFor system) system);
    in
    {
      packages = forAllSystems (
        pkgs: _:
        let
          pdfcraft = mkPackage pkgs;
        in
        {
          inherit pdfcraft;
          default = pdfcraft;
        }
      );

      # `nixpkgs.overlays = [ inputs.pdfcraft.overlays.default ]` → `pkgs.pdfcraft` everywhere.
      # The overlay brings rust-overlay with it so `rust-bin` exists in the extended package set.
      overlays.default = _final: prev: {
        pdfcraft = mkPackage (prev.extend (import rust-overlay));
      };

      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = lib.getExe self.packages.${system}.pdfcraft;
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system:
        let
          pdfcraft = self.packages.${system}.pdfcraft;
        in
        {
          default = pkgs.mkShell (
            {
              # The package's own native inputs, so `cargo run` in the shell needs no extra setup.
              inputsFrom = [ pdfcraft ];
              packages = [ (rustFor pkgs) ];
              # The package's native inputs may put a nixpkgs cargo on PATH; the pinned toolchain wins.
              shellHook = ''
                export PATH="${rustFor pkgs}/bin:$PATH"
              '';
              # `cargo run` dlopens the Vulkan loader, libwayland and libxkbcommon like the packaged binary.
              LD_LIBRARY_PATH = lib.makeLibraryPath pdfcraft.passthru.runtimeLibs;
              RUST_BACKTRACE = "1";
            }
            // lib.optionalAttrs (craft-fonts != null) {
              # Embedded fonts in `cargo run` too; build.rs reads this as CRAFT_FONTS_DIR.
              CRAFT_FONTS_DIR = toString craft-fonts;
            }
          );
        }
      );

      checks = forAllSystems (
        pkgs: system:
        let
          pdfcraft = self.packages.${system}.pdfcraft;
        in
        {
          pdfcraft = pdfcraft;

          # Both module entry points evaluate with `enable = true` (no full NixOS evaluation).
          modules = pkgs.callPackage ./nix/module-check.nix { inherit pdfcraft; };

          # `nix fmt` formats the flake; this keeps it formatted.
          formatting = pkgs.runCommand "pdfcraft-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./nix}
            touch $out
          '';
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);

      # Both modules take the package from this flake unless `programs.pdfcraft.package` is set,
      # so `nixosModules.default`/`homeManagerModules.default` work without the overlay.
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./nix/module.nix { kind = "nixos"; }) ];
          _module.args.pdfcraftPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.pdfcraft;
        };

      homeManagerModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./nix/module.nix { kind = "home-manager"; }) ];
          _module.args.pdfcraftPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.pdfcraft;
        };
    };
}
