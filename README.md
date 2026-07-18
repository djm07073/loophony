# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Quant profile in this fork

This fork includes a single-worker, Linear-driven 24/7 quant research profile under
[`quant/`](quant/README.md). It keeps the official Elixir orchestrator as the control plane and
uses the installed Loophony plugin as its Codex App control plane and the Alpaca plugin for
optional read-only market-data capabilities. A local
SQLite checkpoint ledger carries observations, decisions, evidence, and next actions across fresh
Codex sessions while Linear remains the human-facing record. Durable 10:00 and 22:00 KST review
gates pause orchestration until the user explicitly maintains or adjusts the goal with feedback.

### Install on another Mac

Install the standalone bootstrap skill from this public repository:

```sh
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo djm07073/loophony \
  --path skills/loophony-setup
```

Start a new Codex task and invoke `$loophony-setup`. It registers this repository as the
`loophony-public` marketplace, installs the Loophony, Linear, and Alpaca plugins, clones and builds
the daemon, renders local configuration, and can register the launchd service. Connector OAuth and
Keychain secret entry remain explicit user steps.

To install only the plugin:

```sh
/Applications/Codex.app/Contents/Resources/codex plugin marketplace add djm07073/loophony
/Applications/Codex.app/Contents/Resources/codex plugin add loophony@loophony-public
```

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
