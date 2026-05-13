# Hermetic gstack build.
#
# Architecture:
#   1. `nodeModules` — fixed-output derivation that runs `bun install
#      --frozen-lockfile` with network. Postinstalls execute (so native bits
#      like @ngrok/ngrok land), but Playwright's Chromium download is skipped
#      via PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD — Chromium comes from
#      pkgs.playwright-driver.browsers at runtime. Output is platform-specific;
#      `nodeModulesHash` is a per-system table.
#
#   2. `gstack` — patches upstream `package.json` to drop `git rev-parse HEAD`
#      (no .git in sandbox), patches `setup` to gate non-hermetic steps behind
#      GSTACK_PREBUILT=1, copies vendored node_modules in, runs `bun run build`
#      to compile browse/design/make-pdf binaries, codesigns on darwin, and
#      installs the tree to $out/share/gstack.
#
#   3. `gstack-setup` (the file's output) — activation wrapper. Copies
#      $out/share/gstack into $GSTACK_HOME on first run, exports
#      GSTACK_PREBUILT=1 + PLAYWRIGHT_BROWSERS_PATH, then execs upstream
#      `setup` to do skill registration (~/.claude/skills/*, etc.) without
#      touching the network.
#
# Re-pinning workflow when upstream rev or bun.lock changes:
#   1. Bump `src.rev` + `src.hash`
#   2. Empty the affected entry in `nodeModulesHash`
#   3. `nix build` — error reports the correct hash
#   4. Paste it back
{
  pkgs,
}:

let
  inherit (pkgs) lib;

  src = pkgs.fetchFromGitHub {
    owner = "garrytan";
    repo = "gstack";
    rev = "dc6252d1df7f1f650ea6e9b2bba7d08fab5de902";
    hash = "sha256-4Qns7n4f+TYjwsTscwHaGxpAFz++5Xo1D/XJILt46VQ=";
  };

  nodeModulesHash =
    {
      "aarch64-darwin" = "sha256-oQWGwLY5eJTuWqeCj4jel4gYkhoomPgRW/FK0GVC+Nw=";
      "x86_64-darwin" = "sha256-L9xus4HYkMxeQwJWLJbyPBMT1Z2CeGnckyD+NENiZxY=";
      "aarch64-linux" = "sha256-Fzmf0td3cMejHy+H7hfI15Ikt0LhVPOQ0gPNkxOG/Io=";
      "x86_64-linux" = "sha256-o36m2aYuieuGJi1mxAZiCR9ENsMNow+quO1NqRCMiB4=";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "gstack: no nodeModulesHash entry for ${pkgs.stdenv.hostPlatform.system}");

  # Curated list of npm/PyPI package names known to be compromised in
  # recent supply-chain incidents (Mini Shai-Hulud, etc.). Scanned against
  # bun.lock before any install runs — see `supplyChainCheck` below for the
  # reusable version exposed to `nix flake check`.
  compromisedList = ./compromised-packages.txt;

  # Reusable scan: greps bun.lock against the curated compromised-package
  # list and fails the derivation if any line matches. Exposed both as a
  # standalone `passthru.supplyChainCheck` (wired into `nix flake check`
  # via flake.nix) and run inline at the top of the FOD's buildPhase so
  # a compromised dep can't reach `bun install` in the first place.
  #
  # Reads the curated list with comments / blank lines stripped — a stray
  # blank line in the patterns file would otherwise match every line in
  # bun.lock (grep treats an empty pattern as match-all).
  supplyChainCheck = pkgs.runCommand "gstack-supply-chain-check" { } ''
    patterns=$(grep -v '^[[:space:]]*\(#\|$\)' ${compromisedList})
    if matches=$(echo "$patterns" | grep -wFf - ${src}/bun.lock); then
      echo "" >&2
      echo "ERROR: bun.lock references known-compromised npm/PyPI packages:" >&2
      echo "$matches" | sed 's/^/  /' >&2
      echo "See nix/compromised-packages.txt. Refusing to build." >&2
      exit 1
    fi
    touch $out
  '';

  nodeModules = pkgs.stdenv.mkDerivation {
    pname = "gstack-node-modules";
    version = builtins.substring 0 7 src.rev;
    inherit src;

    nativeBuildInputs = [
      pkgs.bun
      pkgs.cacert
    ];

    # Even with --ignore-scripts blocking lifecycle hooks, leave Playwright's
    # browser-download env var set — defensive in case bun changes default
    # behavior around optional postinstalls.
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      # Supply-chain assertion: refuse to call `bun install` if bun.lock
      # references any known-compromised package name. Stops the next
      # Mini Shai-Hulud-class incident from executing during install even
      # if --ignore-scripts is later loosened. The patterns file is
      # stripped of comments and blank lines first — an empty pattern
      # would otherwise match every line in bun.lock.
      patterns=$(grep -v '^[[:space:]]*\(#\|$\)' ${compromisedList})
      if matches=$(echo "$patterns" | grep -wFf - bun.lock); then
        echo "" >&2
        echo "ERROR: bun.lock references known-compromised packages:" >&2
        echo "$matches" | sed 's/^/  /' >&2
        echo "See nix/compromised-packages.txt. Refusing to install." >&2
        exit 1
      fi

      export HOME=$TMPDIR

      # --ignore-scripts blocks preinstall / install / postinstall / prepare
      # hooks. This is the primary defense against Mini Shai-Hulud-class
      # supply-chain attacks: even a compromised dep can't execute payload
      # code during `bun install`. Side effect: native modules that rely on
      # postinstall to build (rare in bun's tree — most ship prebuilt) won't
      # work. @ngrok/ngrok ships prebuilt platform binaries via
      # optionalDependencies, so it keeps working.
      bun install --frozen-lockfile --ignore-scripts --no-progress --no-summary
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mv node_modules $out
      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = nodeModulesHash;
  };

  gstack = pkgs.stdenv.mkDerivation {
    pname = "gstack";
    version = builtins.substring 0 7 src.rev;
    inherit src;

    nativeBuildInputs = [
      pkgs.bun
      pkgs.nodejs_22
      pkgs.perl # browse/scripts/build-node-server.sh shells out to perl
    ]
    ++ lib.optional pkgs.stdenv.isDarwin pkgs.darwin.sigtool;

    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

    dontConfigure = true;

    postPatch = ''
      # `git rev-parse HEAD` is unavailable in the sandbox. Upstream wraps it
      # in `2>/dev/null || true` so the build won't fail on missing git, but
      # the resulting .version files would be empty. Replace with our pinned
      # rev so binaries embed the SHA. The loop fails loudly if any binary's
      # .version stamp goes missing — defending against upstream restructuring.
      for dist in browse design make-pdf; do
        substituteInPlace package.json \
          --replace-fail \
            "{ git rev-parse HEAD 2>/dev/null || true; } > $dist/dist/.version" \
            "printf %s ${src.rev} > $dist/dist/.version"
      done

      # Gate the three non-hermetic regen blocks in `setup` behind
      # GSTACK_PREBUILT=1. All three share the suffix `&& [ "$NEEDS_BUILD"
      # -eq 0 ]; then` and only those three lines do (verified at refactor
      # time), so one substitution updates all three. The build phase
      # pre-generates .agents/.factory/.opencode/ via
      # `bun run gen:skill-docs --host all`; re-running per-host at
      # activation is both redundant and would call `bun install` (network).
      substituteInPlace setup \
        --replace-fail \
          '&& [ "$NEEDS_BUILD" -eq 0 ]; then' \
          '&& [ "$NEEDS_BUILD" -eq 0 ] && [ "''${GSTACK_PREBUILT:-0}" != "1" ]; then'

      # The `bunx playwright install` fallback must not run in hermetic mode —
      # PLAYWRIGHT_BROWSERS_PATH supplies Chromium. Fail loudly if the
      # ensure_playwright_browser check ever drops into this branch (would
      # indicate playwright npm version drift vs pkgs.playwright-driver).
      substituteInPlace setup \
        --replace-fail \
          'echo "Installing Playwright Chromium..."' \
          'echo "ERROR: hermetic build expected Chromium via PLAYWRIGHT_BROWSERS_PATH but ensure_playwright_browser failed (playwright/playwright-driver version mismatch?)" >&2; exit 1; echo "Installing Playwright Chromium..."'
    '';

    preBuild = ''
      cp -R ${nodeModules} node_modules
      chmod -R u+w node_modules
    '';

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      bun run build
      runHook postBuild
    '';

    postBuild = lib.optionalString pkgs.stdenv.isDarwin ''
      # bun --compile produces a malformed code signature on Apple Silicon;
      # the remove-then-resign two-step is required because a naive `codesign
      # -s - -f` fails when the existing signature block is corrupt. Doing it
      # at build time means every activation isn't re-signing.
      for bin in \
        browse/dist/browse \
        browse/dist/find-browse \
        design/dist/design \
        make-pdf/dist/pdf \
        bin/gstack-global-discover; do
        [ -x "$bin" ] || continue
        codesign --remove-signature "$bin" 2>/dev/null || true
        codesign -s - -f "$bin"
      done
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/gstack $out/bin
      cp -R . $out/share/gstack/

      ln -s $out/share/gstack/browse/dist/browse $out/bin/browse
      ln -s $out/share/gstack/design/dist/design $out/bin/design
      ln -s $out/share/gstack/make-pdf/dist/pdf $out/bin/make-pdf
      runHook postInstall
    '';

    meta = {
      description = "Garry's Stack — compiled binaries + skill tree (hermetic build)";
      homepage = "https://github.com/garrytan/gstack";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
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
      cp -R "${gstack}/share/gstack/." "$GSTACK_HOME/"
      chmod -R u+w "$GSTACK_HOME"
    fi

    export GSTACK_PREBUILT=1
    export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

    cd "$GSTACK_HOME"
    exec bash ./setup "$@"
  '';

  passthru = {
    inherit
      gstack
      nodeModules
      src
      supplyChainCheck
      ;
  };

  meta = {
    description = "Garry's Stack — Claude Code skills + fast headless browser (hermetic)";
    longDescription = ''
      Hermetic packaging of gstack. browse / design / make-pdf are built
      inside the Nix sandbox via a fixed-output node_modules derivation,
      with Chromium supplied by pkgs.playwright-driver.browsers (no
      runtime download).

      Activation copies the prebuilt $out/share/gstack into $GSTACK_HOME
      (default ~/.local/share/gstack) and runs upstream `setup` with
      GSTACK_PREBUILT=1 — the build/install/codesign half is gated out, so
      activation is offline and only does skill registration.

      Re-pinning node_modules: clear the entry in `nodeModulesHash` for the
      affected system in nix/gstack.nix, run `nix build`, paste the suggested
      hash back.
    '';
    homepage = "https://github.com/garrytan/gstack";
    license = lib.licenses.mit;
    mainProgram = "gstack-setup";
    platforms = lib.platforms.unix;
  };
}
