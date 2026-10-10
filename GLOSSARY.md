# Dotfiles

The fleet's configuration and the services it runs: two NixOS hosts, their modules, and the automation that maintains them. This glossary covers only terms whose meaning here is narrower than, or different from, their ordinary use.

## AFK agent

The unattended runner's vocabulary - job, transition, claim, lease, command, hand-off - is defined in the [`afk-agent`](https://github.com/corygyarmathy/afk-agent) repository's `GLOSSARY.md`, not here. This repository is where the NixOS module that packages and configures the runner lives (#281), and it does not own the language.

## Digital garden

The garden's vocabulary - vault, staging tree, publish boundary, maturity, topic and hue, bonsai - is defined in the [`digital-garden`](https://github.com/corygyarmathy/digital-garden) repository's `GLOSSARY.md`, not here. That repository owns the pipeline (the publish filter, the renderer, the preview); this one holds the NixOS module that runs it on homelab01, and it does not own the language.
