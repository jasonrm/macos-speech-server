{
  description = "macos-speech-server — OpenAI-compatible speech API + Wyoming on macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      # Overlay: adds `pkgs.speech-server` to any nixpkgs instance.
      overlays.default = final: prev: {
        speech-server = final.callPackage ./nix/package.nix { };
      };

      # nix-darwin module: import to enable speech-server as a launchd daemon.
      # Composes the overlay so `pkgs.speech-server` is available inside the module.
      darwinModules.default = { ... }: {
        imports = [ ./nix/module.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
      darwinModules.speech-server = self.darwinModules.default;
    }
    //
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system}.extend self.overlays.default;
      in
      {
        packages.default = pkgs.speech-server;
        packages.speech-server = pkgs.speech-server;

        apps.default = {
          type = "app";
          program = "${pkgs.speech-server}/bin/speech-server";
        };

        devShells.default = pkgs.mkShell {
          shellHook = ''
            export PATH=/usr/bin:$PATH
            echo "Using system Swift: $(/usr/bin/xcrun swift --version | head -1)"
          '';
        };
      });
}
