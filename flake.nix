{
  description = "Public NixOS modules for building a customised installer ISO and the builder VM that produces it.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules = {
      installer     = import ./modules/installer.nix;
      nixos-builder = import ./modules/nixos-builder.nix;
      iso-builder   = import ./modules/iso-builder.nix;
    };
  };
}
