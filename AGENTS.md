# Prompt Yourself

A chatbot for analyzing your journal together with you. The user is expected to have an existing journal and work on an arbitrary growth goal. Only if needed you can find all details about the interaction in core/resources/system-prompt.md

The journal is not part of this application but must be passed somehow to the application core. This way we can plug in any kind of journalling app or format.

## Architecture

We follow the hexagonal architecture. The application core with all port definitions is in the `core` crate. The `core-wasm` crate acts as a glue between the core and browser based journalling experts.

Journalling experts are the driving adapters that call the core and plug in the actual journal and control interface. They each get their own root folder in the workspace.

This information should help you to find the files you need faster and ignore what you don't need right now.

Currently there are three experts
* `obsidian-plugin`
* `cli`
* `ios-app`

Additional folders in the workspace root are:
* `sandbox`: docker container to run a coding agent in a sandboxed environment. They are started via `pi.sh` or `claude.sh`. Probably this will be also you.
* `scripts`: various scripts to be used by human or agent for routine tasks like building, ...

## Hard Rules
* ALWAYS rebuild the obsidian plugin after you did a change that affects it (scripts/build-plugin.sh)!
* The `ios-app` expert must be built on macOS with Xcode (not possible in the Linux container)
* NEVER git commit or push code yourself or modify the commit history! You MAY use read-only git commands like `git status`, log etc.
