# gstack source distribution + setup-runner wrapper.
#
# gstack is a Bun + TypeScript project with native deps (playwright, ngrok,
# transformers) that resolves modules online at install time. Running its
# build in a Nix sandbox would require either a fixed-output `bun install`
# step (fragile across bun versions) or a vendored node_modules tarball.
# Until we tackle that, this package ships the source tree plus a
# `gstack-setup` launcher that stages the source into $GSTACK_HOME (default
# ~/.local/share/gstack) and runs the upstream setup script there.
{
  pkgs,
}:

let
  inherit (pkgs) lib;

  src = pkgs.fetchFromGitHub {
    owner = "nhooey";
    repo = "gstack";
    rev = "6209163900beb7497391f8dfc35e2c7d362f23b8";
    hash = "sha256-cLW7NRXmuGGYIO3i/N2xM8Nay3Vm9+TC8iSMmAn9CM8=";
  };
in
pkgs.writeShellApplication {
  name = "gstack-setup";

  runtimeInputs = [
    pkgs.bun
    pkgs.nodejs_22
    pkgs.git
    pkgs.coreutils
    pkgs.bash
  ];

  text = ''
    GSTACK_HOME="''${GSTACK_HOME:-$HOME/.local/share/gstack}"

    if [ ! -d "$GSTACK_HOME" ]; then
      echo "Staging gstack ${src.rev} into $GSTACK_HOME" >&2
      mkdir -p "$(dirname "$GSTACK_HOME")"
      cp -R "${src}" "$GSTACK_HOME"
      chmod -R u+w "$GSTACK_HOME"
    fi

    cd "$GSTACK_HOME"
    exec bash ./setup "$@"
  '';

  meta = {
    description = "Garry's Stack — Claude Code skills + fast headless browser";
    longDescription = ''
      Stages the gstack source tree into $GSTACK_HOME (default
      ~/.local/share/gstack) on first run and invokes its upstream `setup`
      script, which builds the browse / make-pdf / design binaries with
      `bun build --compile` and registers gstack's Claude Code skills.

      The setup script needs network access (bun install, optional Playwright
      browser download), so this is a runtime-resolved package rather than a
      hermetic build.
    '';
    homepage = "https://github.com/nhooey/gstack";
    license = lib.licenses.mit;
    mainProgram = "gstack-setup";
    platforms = lib.platforms.unix;
  };
}
