{
  description = "Panoramax Belgium — NixOS flake for panoramax.osm.be";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  # Submodule note: the encrypted secrets file lives in the `secrets/`
  # submodule (private `panoramax-secrets` repo). By default, Nix flakes do
  # NOT include submodule content in the source tree — operations that need
  # real secrets must use `?submodules=1` on the flake URL, e.g.
  #   nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'
  # `nix flake check` without `?submodules=1` (the CI default) deliberately
  # skips the submodule and falls back to secrets-dummy.yaml — see below.

  outputs =
    { self, nixpkgs, sops-nix, disko, ... }@inputs:
    let
      system = "x86_64-linux";

      # Fresh-clone fallback. The encrypted secrets file lives in the private
      # `panoramax-secrets` repo, attached here as a git submodule at
      # ./secrets/. When the submodule isn't initialised (e.g. CI on a fresh
      # clone, or a contributor without access to the private repo), the file
      # doesn't exist on disk and we fall back to a plaintext placeholder so
      # `nix flake check` still succeeds. Sops file *validation* is skipped on
      # the fallback path; the real encrypted file is always validated.
      realSecrets = ./secrets/panoramax-osmbe.yaml;
      hasRealSecrets = builtins.pathExists realSecrets;
      sopsFile = if hasRealSecrets then realSecrets else ./secrets-dummy.yaml;
    in
    {
      nixosConfigurations.panoramax-osmbe = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs sopsFile hasRealSecrets;
        };
        modules = [
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/panoramax-osmbe
        ];
      };
    };
}
