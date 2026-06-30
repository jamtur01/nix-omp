{
  description = "Nix packaging for oh-my-pi (omp), a coding agent with the IDE wired in";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (
        system:
        let
          omp = (pkgsFor system).callPackage ./package.nix { };
        in
        {
          inherit omp;
          default = omp;
        }
      );

      overlays.default = _final: prev: {
        omp = prev.callPackage ./package.nix { };
      };

      homeModules.default = import ./modules/home-manager.nix self;

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      checks = forAllSystems (system: { omp = self.packages.${system}.omp; });
    };
}
