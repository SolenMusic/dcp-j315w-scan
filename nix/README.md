# NixOS source recipe

Use NixOS's SANE configuration merger, rather than the imperative Bash installer.
Add a local checkout of this project to your NixOS configuration:

```nix
{ pkgs, ... }:
let
  dcpScanner = pkgs.callPackage /path/to/dcp-j315w-scan/nix/default.nix {
    printerAddresses = [ "192.0.2.10" ];
  };
in {
  hardware.sane.enable = true;
  hardware.sane.extraBackends = [ dcpScanner ];
  environment.systemPackages = [ pkgs.simple-scan ];
}
```

Replace the example address and checkout path with your scanner's actual values,
then rebuild your NixOS configuration. Address configuration is part of the Nix
store and is not a secret. An empty address list is allowed; in that case use an
explicit `dcpj315w:IPV4` device name rather than relying on the device list.

The recipe provides the shared library under `lib/sane`, its backend registration
in `etc/sane.d/dll.conf`, and `dcpj315w.conf`. This matches the official NixOS SANE
module and configuration merger. It contains no proprietary scanner software.
The recipe's check phase uses the same libSANE/scanimage loopback checks as Linux
containers. CI is configured to run the pinned recipe on both CPUs.

**Prepared but not yet verified locally:** no Nix build or physical NixOS scan has
been performed. Successful Debian/Fedora/Alpine tests do not establish NixOS
integration. The recipe will need its CI check before being advertised as tested.

Primary references checked at the pinned baseline:
[NixOS SANE module](https://github.com/NixOS/nixpkgs/blob/7c8764b7c7b09b34f632464276218ef9090eaa11/nixos/modules/services/hardware/sane.nix),
[configuration merger](https://github.com/NixOS/nixpkgs/blob/7c8764b7c7b09b34f632464276218ef9090eaa11/pkgs/applications/graphics/sane/config.nix).
