{
  description = "Kiosk ISO";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      # Build the ISO by running: nix build .#iso
      iso = pkgs.nixos ({
        system = "x86_64-linux";
        modules = [ ./kiosk.nix ];
      }).config.system.build.isoImage;
    };
}