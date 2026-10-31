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
#   2. `gstack` — patches upstream `scripts/write-version-files.sh` to stamp
#      the pinned rev (no .git in sandbox), patches `setup` to fail instead of
#      rebuilding or downloading Chromium under GSTACK_PREBUILT=1, copies vendored node_modules in, runs `bun run build`
#      to compile browse/design/make-pdf binaries, codesigns on darwin, and
#      installs the tree to $out/share/gstack.
#
#   3. `skills` — gstack's tree with its skills rendered for a read-only
#      install: a symlink copy of `gstack`'s tree (node_modules a single
#      link), with upstream's renderer, `scripts/gen-skill-docs.ts`, run
#      with `--install-root` and `--link-root` set to the copy itself. Every
#      path a skill would take from ~/.claude/skills/gstack then points at
#      the copy in the store, including the SKILL.md files that /autoplan
#      reads for the other reviews, so no `gstack` folder is needed among
#      the installed skills. flake.nix makes one agent-skill-flake package
#      of each skill.
#
#   4. `gstack-setup` (the file's output) — activation wrapper. Copies
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

  # Single source of truth for the Node toolchain — bump here only.
  nodejs = pkgs.nodejs_22;

  src = pkgs.fetchFromGitHub {
    owner = "garrytan";
    repo = "gstack";
    rev = "088bfc5914f8001a3d49b3a0c35d6f7cb800268c";
    hash = "sha256-hvq185yLAmtwqO6rezP35F7kAGrsHlq+nouPFzwwvQg=";
  };

  nodeModulesHash =
    {
      "aarch64-darwin" = "sha256-54E9FwheEz3giVVabKk1J07/6Gh5qg5v/4ew0g5+QGg=";
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
      nodejs
      pkgs.perl # browse/scripts/build-node-server.sh shells out to perl
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      pkgs.darwin.sigtool # stdenv-darwin's auto-codesign fixup hook
      pkgs.rcodesign # tolerates the malformed Mach-O that bun --compile emits
    ];

    # The installed scripts run under bun. fixupPhase's patchShebangs resolves
    # their `#!/usr/bin/env -S bun …` lines against buildInputs only; with bun
    # in nativeBuildInputs alone, the interpreter came out empty.
    buildInputs = [ pkgs.bun ];

    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

    dontConfigure = true;

    postPatch = ''
      # `git rev-parse HEAD` is unavailable in the sandbox, so upstream's
      # version stamp would come out empty. Stamp our pinned rev instead, so
      # browse / design / make-pdf embed the SHA. --replace-fail fails the
      # build if upstream restructures the stamp script.
      substituteInPlace scripts/write-version-files.sh \
        --replace-fail \
          'if git_head="$(git rev-parse HEAD 2>/dev/null)"; then' \
          'if git_head="${src.rev}"; then'

      # Activation must never rebuild: the build runs `bun install` (network)
      # and recompiles what this derivation already built. The wrapper below
      # re-stamps browse/dist/.build-complete after staging, so setup's
      # mtime checks see a current build; if they still decide to rebuild,
      # fail loudly instead of reaching the network.
      substituteInPlace setup \
        --replace-fail \
          'log "Building browse binary..."' \
          'if [ "''${GSTACK_PREBUILT:-0}" = "1" ]; then echo "ERROR: hermetic gstack expected a prebuilt tree, but setup decided to rebuild it" >&2; exit 1; fi; log "Building browse binary..."'

      # The `bun x playwright install` fallback must not run in hermetic mode:
      # PLAYWRIGHT_BROWSERS_PATH supplies Chromium. Fail loudly if setup's
      # browser check ever drops into this branch (would indicate playwright
      # npm version drift vs pkgs.playwright-driver).
      substituteInPlace setup \
        --replace-fail \
          'echo "Installing Playwright Chromium..."' \
          'echo "ERROR: hermetic build expected Chromium via PLAYWRIGHT_BROWSERS_PATH but the browser check failed (playwright/playwright-driver version mismatch?)" >&2; exit 1; echo "Installing Playwright Chromium..."'
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
      # bun --compile emits Mach-O where __LINKEDIT doesn't cover end-of-file
      # (bun appends embedded JS past LINKEDIT), so Apple's `codesign_allocate`
      # aborts and `codesign --remove-signature` + resign can't recover.
      # `rcodesign` (sigstore) rewrites the load commands tolerantly and
      # produces a valid adhoc signature. Pre-signing at build time avoids
      # re-signing on every activation.
      for bin in \
        browse/dist/browse \
        browse/dist/find-browse \
        design/dist/design \
        make-pdf/dist/pdf \
        bin/gstack-global-discover; do
        [ -x "$bin" ] || continue
        rcodesign sign "$bin"
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

    # Many bash scripts call `bun` by name, among them the skills' hooks,
    # which Claude Code runs outside any devshell. Put bun on each bash
    # script's own PATH, right after its (already patched) shebang.
    postFixup = ''
      while IFS= read -r -d "" f; do
        head -n1 "$f" | grep -q '^#!/nix/store/[^/ ]*-bash-[^/ ]*/bin/bash' || continue
        sed -i '1a export PATH=${pkgs.bun}/bin''${PATH:+:$PATH}' "$f"
      done < <(find $out/share/gstack -path $out/share/gstack/node_modules -prune \
        -o -type f -perm -u+x -print0)
    '';

    meta = {
      description = "Garry's Stack — compiled binaries + skill tree (hermetic build)";
      homepage = "https://github.com/garrytan/gstack";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };

  skills = pkgs.runCommand "gstack-skills-${gstack.version}" { nativeBuildInputs = [ pkgs.bun ]; } ''
    export HOME=$TMPDIR
    tree=${gstack}/share/gstack
    mkdir -p $out
    for entry in "$tree"/* "$tree"/.[!.]*; do
      [ -e "$entry" ] || continue
      case "$(basename "$entry")" in
        node_modules) ln -s "$entry" $out/node_modules ;;
        *) cp -rs "$entry" $out/ ;;
      esac
    done
    chmod -R u+w $out
    cd "$tree"
    bun run scripts/gen-skill-docs.ts --host claude --out-dir $TMPDIR/render \
      --install-root $out --link-root $out
    # The rendered files replace the links to their unrendered originals.
    cp -R --remove-destination $TMPDIR/render/. $out/
  '';

in
pkgs.writeShellApplication {
  name = "gstack-setup";

  runtimeInputs = [
    pkgs.bun
    nodejs
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
      # The copy gives every file a fresh mtime; re-stamp the build after it
      # so setup's "sources newer than the build" check doesn't fire.
      touch "$GSTACK_HOME/browse/dist/.build-complete"
    fi

    export GSTACK_PREBUILT=1
    # CSO's native core doesn't build in the sandbox (scripts/build-cso.sh
    # records the failure and the rest of the build continues). Tell setup it
    # is unavailable, or the missing launcher would make setup try to rebuild;
    # /cso then stays visibly fail-closed, as upstream intends.
    export GSTACK_SETUP_SKIP_CSO_BUILD=1
    # setup installs coreutils through Homebrew on macOS: a machine-wide
    # change that activation must not make.
    export GSTACK_SKIP_COREUTILS=1
    export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

    cd "$GSTACK_HOME"
    exec bash ./setup "$@"
  '';

  passthru = {
    inherit
      gstack
      nodeModules
      skills
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
