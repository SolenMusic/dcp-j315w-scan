let
  pkgs = import (builtins.fetchTarball
    "https://github.com/NixOS/nixpkgs/archive/7c8764b7c7b09b34f632464276218ef9090eaa11.tar.gz") { };
in pkgs.callPackage ./default.nix { }
