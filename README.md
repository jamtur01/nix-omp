# nix-omp

Nix packaging for [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`), a
coding agent with the IDE wired in.

This packages the official prebuilt release binary rather than building from
source. omp ships as a Bun single-file executable with its native `.node`
addons and ~55k-line Rust core embedded in the binary, plus several
per-release codegen steps — reproducing that build in Nix is fragile, and the
release binary is the artifact upstream actually signs and ships. The package
installs it verbatim; on Linux it is launched through the Nix dynamic loader
(no `patchelf`/`strip`, which corrupt Bun's appended payload).

Supports `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, and `x86_64-linux`.

## Try it

```sh
nix run github:jamtur01/nix-omp
```

## Install

### Flake input

```nix
{
  inputs.omp.url = "github:jamtur01/nix-omp";
  inputs.omp.inputs.nixpkgs.follows = "nixpkgs";
}
```

### Home Manager

```nix
{ inputs, ... }:
{
  imports = [ inputs.omp.homeModules.default ];

  programs.omp = {
    enable = true;
    settings.model = "anthropic/claude-opus-4-8";
    # models.providers = { ... };           # ~/.omp/agent/models.yml
    # keybindings = { ... };                 # ~/.omp/agent/keybindings.yml
    # mcpServers.fetch = { command = "uvx"; args = [ "mcp-server-fetch" ]; };
    # rules.style = ./rules/style.md;        # ~/.omp/agent/rules/style.md
    # commands.deploy = ./commands/deploy.md;
    # skills.my-skill = ./skills/my-skill;   # ~/.omp/agent/skills/my-skill
    # extensions = [ ./extensions/my-extension.ts ];
    # tools = [ ./tools/my-tool.ts ];        # ~/.omp/agent/tools/
    # hooks.pre.bash = ./hooks/pre-bash.sh;  # fires before the bash tool
    # hooks.post."*" = ./hooks/post-all.sh;  # fires after every tool
    # appendSystemPrompt = "Be concise.";

    hindsight = {
      enable = true;                         # memory.backend = hindsight
      apiUrl = "https://hindsight.example.com";
      scoping = "per-project-tagged";
      # settings.autoRecall = true;          # any other hindsight.* key
    };
  };
}
```

### Hindsight token

The `hindsight` backend's API token is **not** a module option — writing it to
`config.yml` would put the secret in the world-readable Nix store. omp reads
`HINDSIGHT_API_TOKEN` from the environment (it overrides the setting), so supply
it out of band, e.g. with sops-nix:

```nix
# token rendered to a file by sops-nix, exported into the session environment
home.sessionVariablesExtra = ''
  export HINDSIGHT_API_TOKEN="$(cat ${config.sops.secrets.hindsight-token.path})"
'';
```

The module asserts if `hindsight.settings.apiToken` is set, to catch the
store-leak mistake.

### Package only (nix-darwin / NixOS)

Add the overlay and install system-wide:

```nix
{ inputs, ... }:
{
  nixpkgs.overlays = [ inputs.omp.overlays.default ];
  environment.systemPackages = [ pkgs.omp ];
}
```

## Config paths

The Home Manager module writes into the default profile's agent directory,
`~/.omp/agent/`:

| option | file |
|---|---|
| `settings` | `config.yml` (`setupVersion` injected) |
| `models` | `models.yml` |
| `keybindings` | `keybindings.yml` |
| `mcpServers` | `mcp.json` |
| `rules.<n>` / `commands.<n>` / `agents.<n>` / `prompts.<n>` | `<dir>/<n>.md` |
| `themes.<n>` | `themes/<n>.json` |
| `skills.<n>` | `skills/<n>` |
| `extensions` / `tools` | `extensions/<basename>` / `tools/<basename>` |
| `hooks.pre.<n>` / `hooks.post.<n>` | `hooks/pre/<n>` / `hooks/post/<n>` (executable; `<n>` = tool or `*`) |
| `systemPrompt` / `appendSystemPrompt` | `SYSTEM.md` / `APPEND_SYSTEM.md` |

## Updating

`./update.sh` bumps `VERSION.json` to the latest release and refreshes all four
platform hashes (needs `gh`, `nix`, `jq`).

## Prior art

- [git.molez.org/mandlm/omp-nix](https://git.molez.org/mandlm/omp-nix) — the
  binary-fetch approach and config path mapping are adapted from this.
- [lukasl-dev/pi.nix](https://github.com/lukasl-dev/pi.nix) — flake/module
  layout inspiration (targets upstream `pi`, not omp).
