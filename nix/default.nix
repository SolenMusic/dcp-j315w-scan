{ lib, stdenv, sane-backends, python3, printerAddresses ? [ ] }:

let
  validAddress = address:
    let
      octets = lib.splitString "." address;
      validOctet = octet:
        builtins.match "(0|[1-9][0-9]{0,2})" octet != null
        && builtins.fromJSON octet <= 255;
    in builtins.length octets == 4 && builtins.all validOctet octets;
in
assert lib.assertMsg (builtins.all validAddress printerAddresses)
  "printerAddresses must contain numeric IPv4 addresses";
stdenv.mkDerivation {
  pname = "dcp-j315w-scan";
  version = lib.removeSuffix "\n" (builtins.readFile ../VERSION);
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src ../linux/sane-dcpj315w.c ../build-linux-sane.sh
      ../test_sane.py ../LICENSE ../VERSION
    ];
  };
  strictDeps = true;
  buildInputs = [ (lib.getDev sane-backends) ];
  nativeCheckInputs = [ python3 (lib.getLib sane-backends) ];
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    ./build-linux-sane.sh
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export LD_LIBRARY_PATH="$PWD/build/linux-sane:${lib.getLib sane-backends}/lib"
    export PATH="${sane-backends}/bin:$PATH"
    python3 test_sane.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -d "$out/lib/sane" "$out/etc/sane.d" "$out/share/doc/dcp-j315w-scan"
    install -m755 build/linux-sane/libsane-dcpj315w.so.1.0.0 "$out/lib/sane/"
    ln -s libsane-dcpj315w.so.1.0.0 "$out/lib/sane/libsane-dcpj315w.so.1"
    ln -s libsane-dcpj315w.so.1 "$out/lib/sane/libsane-dcpj315w.so"
    printf 'dcpj315w\n' > "$out/etc/sane.d/dll.conf"
    printf '%s\n' ${lib.escapeShellArgs printerAddresses} > "$out/etc/sane.d/dcpj315w.conf"
    install -m644 LICENSE "$out/share/doc/dcp-j315w-scan/"
    runHook postInstall
  '';
  meta = {
    description = "Independent Wi-Fi SANE scanner backend for the Brother DCP-J315W";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
