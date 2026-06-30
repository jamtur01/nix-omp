# Packages the prebuilt `omp` release binary.
#
# omp ships as a Bun single-file executable: a host runtime with the bundled
# JS/TS, embedded `.node` native addons and the Rust core all appended to the
# end of the file. Bun locates that payload by seeking from EOF of its own
# executable, so the binary must NOT be modified — `strip` and `patchelf` both
# rewrite the ELF and shift/clobber the trailer, breaking startup. We therefore
# install the binary verbatim and, on Linux, run it through the Nix dynamic
# loader at launch instead of patching its interpreter.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  versionInfo ? lib.importJSON ./VERSION.json,
}:
let
  inherit (stdenvNoCC.hostPlatform) system;

  assets = {
    "x86_64-linux" = "omp-linux-x64";
    "aarch64-linux" = "omp-linux-arm64";
    "x86_64-darwin" = "omp-darwin-x64";
    "aarch64-darwin" = "omp-darwin-arm64";
  };

  asset = assets.${system} or (throw "omp: unsupported system '${system}'");
  hash = versionInfo.hashes.${system} or (throw "omp: no hash recorded for '${system}'");
  inherit (versionInfo) version;
in
stdenvNoCC.mkDerivation {
  pname = "omp";
  inherit version;

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/${asset}";
    inherit hash;
  };

  dontUnpack = true;
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = lib.optionals stdenvNoCC.isLinux [ makeWrapper ];

  # Bun resolves its embedded payload via /proc/self/exe, so the executed file
  # must keep the name `omp`. On Darwin the release binary is already adhoc
  # signed; a plain install is enough. On Linux the binary's interpreter points
  # at a non-existent FHS path, so we keep it untouched under libexec and launch
  # it through the Nix loader, passing the real argv0 so Bun still sees `omp`.
  installPhase =
    if stdenvNoCC.isDarwin then
      ''
        runHook preInstall
        install -Dm755 "$src" "$out/bin/omp"
        runHook postInstall
      ''
    else
      ''
        runHook preInstall
        install -Dm755 "$src" "$out/libexec/omp/omp"
        makeWrapper "$(cat ${stdenvNoCC.cc}/nix-support/dynamic-linker)" "$out/bin/omp" \
          --add-flags "$out/libexec/omp/omp" \
          --argv0 omp \
          --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ stdenvNoCC.cc.cc.lib ]}"
        runHook postInstall
      '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "oh-my-pi (omp) — a coding agent with the IDE wired in";
    homepage = "https://omp.sh";
    downloadPage = "https://github.com/can1357/oh-my-pi/releases";
    license = lib.licenses.mit;
    mainProgram = "omp";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames assets;
  };
}
