{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "speech-server";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../.;
    filter = name: type:
      let base = baseNameOf name; in
      !(lib.hasPrefix "result" base)
      && base != ".build"
      && base != ".git"
      && base != ".direnv";
  };

  # Build relies on the host Xcode toolchain (Swift 6.2, CoreML, Apple Neural
  # Engine, private macOS SDKs) and on SwiftPM fetching deps over the network.
  # __noChroot lets the build reach /usr/bin/xcrun, /Applications/Xcode.app,
  # and the network.
  #
  # Requires `sandbox = relaxed` (Determinate Nix default on macOS). With
  # strict sandbox, run:
  #     nix build . --option sandbox relaxed
  __noChroot = true;

  # The output is a Mach-O binary produced by the Xcode toolchain — keep
  # nixpkgs' fixup phase from rewriting / stripping / re-signing it.
  dontPatchShebangs = true;
  dontStrip = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
    /usr/bin/xcrun swift build \
      -c release \
      --disable-sandbox \
      --scratch-path "$TMPDIR/scratch"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    bin=$(/usr/bin/xcrun swift build -c release \
      --scratch-path "$TMPDIR/scratch" \
      --show-bin-path)
    cp "$bin/speech-server" $out/bin/speech-server
    runHook postInstall
  '';

  meta = {
    description = "On-device OpenAI-compatible speech API + Wyoming server for macOS";
    homepage = "https://github.com/dokterbob/macos-speech-server";
    platforms = [ "aarch64-darwin" "x86_64-darwin" ];
    mainProgram = "speech-server";
  };
}
