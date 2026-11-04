# `programs.pdfcraft` for NixOS and home-manager.
#
# The option set is shared; `kind` selects only the behaviour the target module system can express:
# home-manager sets the palette variable per user, NixOS installs the package, the palette variable
# and the MIME default for the whole system.
#
# There is no `settings` option: PdfCraft stores its preferences in the eframe RON file
# `~/.config/pdfcraft/app.ron` (portable mode: `PdfCraftData/app.ron` beside the executable),
# which has no JSON loader to merge an overlay into. Generating RON is out of scope for this
# wave; a follow-up can add a JSON preference file.
{ kind }:
{
  config,
  lib,
  pkgs,
  # The package of this flake; `flake.nix` passes it through `_module.args`, so importing the
  # module directly needs no overlay.
  pdfcraftPackage ? pkgs.pdfcraft,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.pdfcraft;

  # The same list as `packaging/linux/ai.storyteller.pdfcraft.desktop` (`MimeType=`).
  mimeTypes = [
    "application/pdf"
  ];

  desktopFile = "ai.storyteller.pdfcraft.desktop";

  associations = lib.genAttrs mimeTypes (_: [ desktopFile ]);
in
{
  options.programs.pdfcraft = {
    enable = mkEnableOption "PdfCraft";

    package = mkOption {
      type = types.package;
      default = pdfcraftPackage;
      defaultText = lib.literalMD "the `pdfcraft` package of this flake";
      description = "The PdfCraft package to install.";
    };

    setAsDefault = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open PDF documents with PdfCraft by default (the MIME types of
        `packaging/linux/ai.storyteller.pdfcraft.desktop`).
      '';
    };

    paletteFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional shared palette file, exported as `CRAFT_PALETTE_FILE`. Inert until theming support
        lands.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable (
      if kind == "nixos" then
        {
          environment.systemPackages = [ cfg.package ];
          environment.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          xdg.mime.defaultApplications = mkIf cfg.setAsDefault associations;
        }
      else
        {
          home.packages = [ cfg.package ];
          home.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          xdg.mimeApps = mkIf cfg.setAsDefault {
            enable = true;
            defaultApplications = associations;
            # Associated even when another application stays the default.
            associations.added = associations;
          };
        }
    ))
  ];
}
