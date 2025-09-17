{
  description = "Kiosk ISO via nixos-generators";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    generators.url = "github:nix-community/nixos-generators";
  };

  outputs = { self, nixpkgs, generators }:
  let
    system = "x86_64-linux";
  in {
    # Build with: nix build .#iso
    packages.${system}.iso = generators.nixosGenerate {
      inherit system;
      format = "iso";
      modules = [ ./kiosk.nix ];
    };
  };
}