# Dotfiles

The fleet's configuration and the services it runs: two NixOS hosts, their modules, and the automation that maintains them. This glossary covers only terms whose meaning here is narrower than, or different from, their ordinary use.

## AFK agent

The unattended runner's vocabulary - job, transition, claim, lease, command, hand-off - is defined in the [`afk-agent`](https://github.com/corygyarmathy/afk-agent) repository's `CONTEXT.md`, not here. This repository holds the NixOS module that packages and configures the runner, and (until cutover) the bash prototype it replaces; neither owns the language.
