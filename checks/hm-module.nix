# Evaluation test for the `programs.omp` Home Manager module.
#
# It stubs the `home.{file,packages}` and `assertions` options Home Manager
# would normally supply, evaluates the module against a representative config,
# and asserts that every expected `~/.omp/agent/...` entry is produced and that
# the secret-leak guard fires when a secret is placed in `settings`.
{
  pkgs,
  lib,
  hmModule,
}:
let
  # Minimal stand-ins for the Home Manager options the module writes to.
  hmStub =
    { ... }:
    {
      options.home = {
        file = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                source = lib.mkOption {
                  type = lib.types.anything;
                  default = null;
                };
                text = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
                recursive = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
                executable = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                };
              };
            }
          );
          default = { };
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
      };
      options.assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
    };

  baseConfig =
    { ... }:
    {
      programs.omp = {
        enable = true;
        settings = {
          model = "anthropic/claude-opus-4-8";
          theme = "dark-nebula";
        };
        models.providers.custom = {
          baseUrl = "http://localhost:11434";
          api = "openai-completions";
        };
        mcpServers.filesystem = {
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-filesystem"
          ];
        };
        keybindings.submit = "ctrl+enter";
        themes.mytheme = {
          name = "mytheme";
          colors = { };
        };
        prompts.review = "Review this PR carefully.";
        instructions.style = "Be concise.";
        commands.hello = "Say hello.";
        rules.no-yolo = "Never use yolo mode.";
        agents.planner = "You are a planning agent.";
        skills = {
          inline = "---\nname: inline\ndescription: Inline skill.\n---\nBody.";
          sample = ./fixtures/sample-skill;
          single = ./fixtures/sample-skill/SKILL.md;
        };
        hooks.pre.bash = "#!/bin/sh\nexit 0\n";
        hooks.post."*" = "#!/bin/sh\nexit 0\n";
        hindsight = {
          enable = true;
          apiUrl = "https://hindsight.example.com";
          scoping = "per-project-tagged";
        };
        systemPrompt = "You are a helpful assistant.";
        appendSystemPrompt = "Always cite sources.";
      };
    };

  evalConfig =
    extra:
    lib.evalModules {
      modules = [
        hmStub
        hmModule
        baseConfig
        extra
      ];
      specialArgs = { inherit pkgs; };
    };

  evaluated = evalConfig ({ ... }: { });
  files = evaluated.config.home.file;

  expectations = [
    ".omp/agent/config.yml"
    ".omp/agent/models.yml"
    ".omp/agent/mcp.json"
    ".omp/agent/keybindings.yml"
    ".omp/agent/themes/mytheme.json"
    ".omp/agent/prompts/review.md"
    ".omp/agent/instructions/style.md"
    ".omp/agent/commands/hello.md"
    ".omp/agent/rules/no-yolo.md"
    ".omp/agent/agents/planner.md"
    ".omp/agent/skills/inline/SKILL.md"
    ".omp/agent/skills/sample"
    ".omp/agent/skills/single/SKILL.md"
    ".omp/agent/hooks/pre/bash"
    ".omp/agent/hooks/post/*"
    ".omp/agent/SYSTEM.md"
    ".omp/agent/APPEND_SYSTEM.md"
  ];

  missing = builtins.filter (p: !(builtins.hasAttr p files)) expectations;

  # The directory-form skill must be linked recursively, the file/inline forms
  # as plain SKILL.md entries.
  sampleRecursive = files.".omp/agent/skills/sample".recursive or false;
  inlineHasText = (files.".omp/agent/skills/inline/SKILL.md".text or null) != null;

  # config.yml must carry the injected hindsight backend + setupVersion.
  configFile = files.".omp/agent/config.yml".source;
  configText = builtins.readFile configFile;
  hasHindsight = lib.hasInfix "backend: hindsight" configText;

  # Active assertions in the base config must all pass (secret guard happy path).
  baseFailures = lib.filter (a: !a.assertion) evaluated.config.assertions;

  # Placing a secret in settings must trip the guard.
  leaked = evalConfig ({ ... }: { programs.omp.settings.searxng.token = "leak-me"; });
  leakFailures = lib.filter (a: !a.assertion) leaked.config.assertions;

  errors =
    lib.optional (missing != [ ]) "missing entries: ${builtins.concatStringsSep ", " missing}"
    ++ lib.optional (!sampleRecursive) "skills/sample not linked recursively"
    ++ lib.optional (!inlineHasText) "skills/inline/SKILL.md not written as text"
    ++ lib.optional (!hasHindsight) "config.yml missing hindsight backend"
    ++ lib.optional (baseFailures != [ ]) "base config tripped an assertion unexpectedly"
    ++ lib.optional (leakFailures == [ ]) "secret-leak guard did not fire for settings.searxng.token";

  report =
    if errors == [ ] then
      "ok: ${toString (builtins.length expectations)} entries, skill forms, hindsight block, and secret guard verified."
    else
      builtins.throw ("hm-module check failed:\n  " + builtins.concatStringsSep "\n  " errors);
in
pkgs.runCommand "omp-hm-module-test" { } ''
  echo "${report}"
  touch $out
''
