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

  # Skills may be a store path / local directory (linked recursively) or an
  # inline attrset `{ source = ...; }`.
  skillFiles = lib.mapAttrs' (
    name: value:
    lib.nameValuePair "${agentDir}/skills/${name}" (
      if lib.isAttrs value && !lib.isDerivation value then value else { source = value; }
    )
  ) cfg.skills;

  # omp shows a setup wizard until `setupVersion` is recorded; inject a value so
  # a declaratively-configured install starts straight into the agent.
  configContents = { setupVersion = 1; } // cfg.settings;
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

    themes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Theme definitions written to `~/.omp/agent/themes/<name>.json`.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''{ my-skill = ./skills/my-skill; }'';
      description = "Skills linked into `~/.omp/agent/skills/<name>` (a path or a `home.file` attrset).";
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
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.file = lib.mkMerge [
      (docFiles "rules" "md" cfg.rules)
      (docFiles "commands" "md" cfg.commands)
      (docFiles "agents" "md" cfg.agents)
      (docFiles "prompts" "md" cfg.prompts)
      (jsonFiles "themes" cfg.themes)
      skillFiles
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
    ];
  };
}
