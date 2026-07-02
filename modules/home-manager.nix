# Home Manager module for declarative omp configuration.
#
# Writes into the default-profile agent dir (`~/.omp/agent`), which is where
# omp loads `config.yml`, `models.yml`, `keybindings.yml`, `mcp.json`,
# `SYSTEM.md`, and the `skills/`, `commands/`, `rules/`, `agents/`, `prompts/`,
# `themes/` subdirectories from.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omp;
  yaml = pkgs.formats.yaml { };
  agentDir = ".omp/agent";

  # Map an attrset of name -> (string | path) into home.file entries under a
  # subdirectory, giving every value the supplied extension.
  docFiles =
    sub: ext: attrs:
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "${agentDir}/${sub}/${name}.${ext}" (
        if lib.isPath value || lib.isStorePath value then { source = value; } else { text = value; }
      )
    ) attrs;

  jsonFiles =
    sub: attrs:
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "${agentDir}/${sub}/${name}.json" {
        source = pkgs.writeText "omp-${sub}-${name}.json" (builtins.toJSON value);
      }
    ) attrs;

  # Map a nullable (string | path) into a single top-level home.file entry under
  # the agent dir, or nothing when null. Paths link by source; strings are
  # written verbatim.
  topDocFile =
    file: value:
    lib.optionalAttrs (value != null) {
      "${agentDir}/${file}" =
        if lib.isPath value || lib.isStorePath value then { source = value; } else { text = value; };
    };

  # Parse "github:owner/repo[/subdir]@ref" into its parts, or null if it does
  # not match. A 40-char lowercase-hex ref is treated as a commit (allows pure
  # evaluation); anything else is a branch/tag passed to `builtins.fetchGit`.
  parseGithubRef =
    s:
    let
      m = builtins.match "github:([^/]+)/([^/@]+)(/[^@]*)?@(.+)" s;
    in
    if m == null then
      null
    else
      {
        owner = builtins.elemAt m 0;
        repo = builtins.elemAt m 1;
        subdir =
          let
            raw = builtins.elemAt m 2;
          in
          if raw == null then "" else lib.removePrefix "/" raw;
        ref = builtins.elemAt m 3;
      };

  isCommitHash = s: builtins.match "[0-9a-f]{40}" s != null;

  fetchGithubSkill =
    {
      owner,
      repo,
      subdir,
      ref,
    }:
    let
      fetched = builtins.fetchGit (
        {
          url = "https://github.com/${owner}/${repo}";
        }
        // (if isCommitHash ref then { rev = ref; } else { inherit ref; })
      );
      base = builtins.toString fetched;
    in
    if subdir != "" then "${base}/${subdir}" else base;

  # A skill value is one of:
  #   - a path to a directory (linked recursively as `skills/<name>/`)
  #   - a path to a SKILL.md file (linked as `skills/<name>/SKILL.md`)
  #   - a "github:owner/repo[/subdir]@ref" string (fetched, linked recursively)
  #   - an inline string (written to `skills/<name>/SKILL.md`)
  #   - a `{ src; subdir ? ""; }` attrset for a pre-fetched source (recursive)
  #   - any other `home.file` attrset (escape hatch, passed through verbatim)
  mkSkillEntry =
    name: value:
    let
      target = "${agentDir}/skills/${name}";
      githubRef = if lib.isString value then parseGithubRef value else null;
    in
    if lib.isPath value && lib.pathIsDirectory value then
      lib.nameValuePair target {
        source = value;
        recursive = true;
      }
    else if lib.isPath value then
      lib.nameValuePair "${target}/SKILL.md" { source = value; }
    else if githubRef != null then
      lib.nameValuePair target {
        source = fetchGithubSkill githubRef;
        recursive = true;
      }
    else if lib.isString value then
      lib.nameValuePair "${target}/SKILL.md" { text = value; }
    else if lib.isAttrs value && !lib.isDerivation value && value ? src then
      lib.nameValuePair target {
        source = if value.subdir or "" != "" then "${value.src}/${value.subdir}" else "${value.src}";
        recursive = true;
      }
    else if lib.isAttrs value && !lib.isDerivation value then
      lib.nameValuePair target value
    else
      lib.nameValuePair target { source = value; };

  skillFiles = lib.mapAttrs' mkSkillEntry cfg.skills;

  # Extension modules are discovered from `~/.omp/agent/extensions/`; link each
  # by its file name.
  extensionFiles = lib.listToAttrs (
    map (
      p: lib.nameValuePair "${agentDir}/extensions/${baseNameOf (toString p)}" { source = p; }
    ) cfg.extensions
  );

  # Custom tool files/dirs are discovered from `~/.omp/agent/tools/`; link each
  # by its name (a file like `my-tool.ts` or a directory with `index.ts`).
  toolFiles = lib.listToAttrs (
    map (p: lib.nameValuePair "${agentDir}/tools/${baseNameOf (toString p)}" { source = p; }) cfg.tools
  );

  # Hooks live under `~/.omp/agent/hooks/<phase>/<name>`, where the file's base
  # name is the tool it fires for (`*` matches all tools). They are invoked as
  # executables, so mark them +x.
  hookFiles =
    phase: attrs:
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "${agentDir}/hooks/${phase}/${name}" (
        (if lib.isPath value || lib.isStorePath value then { source = value; } else { text = value; })
        // {
          executable = true;
        }
      )
    ) attrs;

  # The `hindsight` memory backend is configured through `hindsight.*` keys in
  # config.yml. The API token is deliberately not a module option: it must come
  # from the `HINDSIGHT_API_TOKEN` environment variable (which overrides the
  # setting) so the secret never lands in the world-readable Nix store.
  hindsightBlock = lib.optionalAttrs cfg.hindsight.enable {
    memory.backend = "hindsight";
    hindsight =
      lib.filterAttrs (_: v: v != null) { inherit (cfg.hindsight) apiUrl scoping; }
      // cfg.hindsight.settings;
  };

  # omp shows a setup wizard until `setupVersion` is recorded; inject a value so
  # a declaratively-configured install starts straight into the agent. User
  # `settings` deep-merge last so they can override the derived blocks.
  configContents = lib.recursiveUpdate ({ setupVersion = 1; } // hindsightBlock) cfg.settings;

  # Secret-bearing config keys: writing any of these into config.yml lands the
  # secret in the world-readable Nix store. Each has an env-var/OAuth equivalent
  # (HINDSIGHT_API_TOKEN, OMP_AUTH_BROKER_TOKEN, XAI_API_KEY, ...) — supply those
  # out of band (e.g. via sops-nix) instead.
  secretSentinel = "__omp_unset_sentinel__";
  secretPaths = [
    [
      "auth"
      "broker"
      "token"
    ]
    [
      "hindsight"
      "apiToken"
    ]
    [
      "mnemopi"
      "embeddingApiKey"
    ]
    [
      "mnemopi"
      "llmApiKey"
    ]
    [
      "searxng"
      "token"
    ]
    [
      "searxng"
      "basicPassword"
    ]
    [
      "dev"
      "autoqaPush"
      "token"
    ]
  ];
  leakedSecrets =
    lib.filter (p: lib.attrByPath p secretSentinel cfg.settings != secretSentinel) secretPaths
    ++ lib.optional (cfg.hindsight.settings ? apiToken) [
      "hindsight"
      "apiToken"
    ];
in
{
  options.programs.omp = {
    enable = lib.mkEnableOption "the omp coding agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "omp.packages.\${system}.default";
      description = "The omp package to install.";
    };

    settings = lib.mkOption {
      type = yaml.type;
      default = { };
      example = lib.literalExpression ''{ model = "anthropic/claude-opus-4-8"; }'';
      description = "Contents of `~/.omp/agent/config.yml` (`setupVersion` is added automatically).";
    };

    models = lib.mkOption {
      type = yaml.type;
      default = { };
      description = "Custom model/provider definitions written to `~/.omp/agent/models.yml`.";
    };

    keybindings = lib.mkOption {
      type = yaml.type;
      default = { };
      description = "Keybinding overrides written to `~/.omp/agent/keybindings.yml`.";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''{ fetch = { command = "uvx"; args = [ "mcp-server-fetch" ]; }; }'';
      description = "MCP server definitions written to `~/.omp/agent/mcp.json`.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = { };
      description = "Markdown rule files written to `~/.omp/agent/rules/<name>.md`.";
    };

    commands = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = { };
      description = "Slash-command files written to `~/.omp/agent/commands/<name>.md`.";
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = { };
      description = "Custom agent files written to `~/.omp/agent/agents/<name>.md`.";
    };

    prompts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = { };
      description = "Prompt template files written to `~/.omp/agent/prompts/<name>.md`.";
    };

    instructions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = { };
      description = "Instruction files written to `~/.omp/agent/instructions/<name>.md`.";
    };

    themes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Theme definitions written to `~/.omp/agent/themes/<name>.json`.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''{ my-skill = ./skills/my-skill; remote = "github:owner/repo/path@main"; }'';
      description = ''
        Skills linked into `~/.omp/agent/skills/<name>`. Each value is a path to a
        skill directory or a `SKILL.md` file, an inline `SKILL.md` string, a
        `"github:owner/repo[/subdir]@ref"` source, a `{ src; subdir ? ""; }`
        attrset, or any `home.file` attrset (escape hatch).
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression "[ ./extensions/my-extension.ts ]";
      description = "Extension module files linked into `~/.omp/agent/extensions/` (discovered by file name).";
    };

    tools = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression "[ ./tools/my-tool.ts ]";
      description = "Custom tool files or directories linked into `~/.omp/agent/tools/` (discovered by name).";
    };

    hooks = {
      pre = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = { };
        example = lib.literalExpression "{ bash = ./hooks/pre-bash.sh; }";
        description = "Pre-tool hooks linked into `~/.omp/agent/hooks/pre/<name>` (name is the tool to hook, or `*` for all).";
      };

      post = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = { };
        example = lib.literalExpression ''{ "*" = ./hooks/post-all.sh; }'';
        description = "Post-tool hooks linked into `~/.omp/agent/hooks/post/<name>` (name is the tool to hook, or `*` for all).";
      };
    };

    hindsight = {
      enable = lib.mkEnableOption "the Hindsight long-term memory backend (`memory.backend = hindsight`)";

      apiUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://hindsight.example.com";
        description = ''
          `hindsight.apiUrl`. The API token must be supplied out of band via the
          `HINDSIGHT_API_TOKEN` environment variable (e.g. rendered by sops-nix),
          which overrides the setting — never write it to the Nix store.
        '';
      };

      scoping = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "global"
            "per-project"
            "per-project-tagged"
          ]
        );
        default = null;
        description = "`hindsight.scoping`.";
      };

      settings = lib.mkOption {
        type = yaml.type;
        default = { };
        example = lib.literalExpression "{ autoRecall = true; mentalModelsEnabled = true; }";
        description = "Extra `hindsight.*` keys merged into config.yml (e.g. `autoRetain`, `retainMode`, `recallBudget`).";
      };
    };

    systemPrompt = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Replaces the default system prompt (`~/.omp/agent/SYSTEM.md`).";
    };

    appendSystemPrompt = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Appended to the default system prompt (`~/.omp/agent/APPEND_SYSTEM.md`).";
    };

    agentsMd = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      example = lib.literalExpression ''"# Conventions\n\nUse tabs."'';
      description = ''
        User-level context written to `~/.omp/agent/AGENTS.md`. The native
        discovery provider loads it into every session's opening context (the
        omp-native equivalent of `CLAUDE.md`); a native `AGENTS.md` shadows a
        user-level `~/.claude/CLAUDE.md`.
      '';
    };

    rulesMd = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      example = lib.literalExpression ''"Never commit unless asked."'';
      description = ''
        User-level sticky rules written to `~/.omp/agent/RULES.md`. Loaded as an
        always-apply rule re-attached near the current turn, so it holds across
        long sessions. Keep it short; put bulk guidance in `agentsMd`.
      '';
    };

    watchdogMd = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      example = lib.literalExpression ''"Especially watch for secrets in the Nix store."'';
      description = ''
        User-level advisor guidance written to `~/.omp/agent/WATCHDOG.md`.
        Appended to the advisor's system prompt (review priorities and traps);
        not injected into the primary agent's context.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = leakedSecrets == [ ];
        message =
          "programs.omp: secret value(s) "
          + lib.concatMapStringsSep ", " (lib.concatStringsSep ".") leakedSecrets
          + " would be written into the world-readable Nix store. Supply them via environment variables "
          + "(e.g. HINDSIGHT_API_TOKEN, OMP_AUTH_BROKER_TOKEN, XAI_API_KEY) from your secret manager instead.";
      }
    ];

    home.packages = [ cfg.package ];

    home.file = lib.mkMerge [
      (docFiles "rules" "md" cfg.rules)
      (docFiles "commands" "md" cfg.commands)
      (docFiles "agents" "md" cfg.agents)
      (docFiles "prompts" "md" cfg.prompts)
      (docFiles "instructions" "md" cfg.instructions)
      (jsonFiles "themes" cfg.themes)
      skillFiles
      extensionFiles
      toolFiles
      (hookFiles "pre" cfg.hooks.pre)
      (hookFiles "post" cfg.hooks.post)
      (lib.mkIf (configContents != { }) {
        "${agentDir}/config.yml".source = yaml.generate "omp-config.yml" configContents;
      })
      (lib.mkIf (cfg.models != { }) {
        "${agentDir}/models.yml".source = yaml.generate "omp-models.yml" cfg.models;
      })
      (lib.mkIf (cfg.keybindings != { }) {
        "${agentDir}/keybindings.yml".source = yaml.generate "omp-keybindings.yml" cfg.keybindings;
      })
      (lib.mkIf (cfg.mcpServers != { }) {
        "${agentDir}/mcp.json".source = pkgs.writeText "omp-mcp.json" (
          builtins.toJSON { mcpServers = cfg.mcpServers; }
        );
      })
      (lib.mkIf (cfg.systemPrompt != null) {
        "${agentDir}/SYSTEM.md".text = cfg.systemPrompt;
      })
      (lib.mkIf (cfg.appendSystemPrompt != null) {
        "${agentDir}/APPEND_SYSTEM.md".text = cfg.appendSystemPrompt;
      })
      (topDocFile "AGENTS.md" cfg.agentsMd)
      (topDocFile "RULES.md" cfg.rulesMd)
      (topDocFile "WATCHDOG.md" cfg.watchdogMd)
    ];
  };
}
