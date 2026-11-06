# Keep init available before submodules have been fetched on a fresh clone.
import? 'lib/just-foundry/justfile'

default:
    @just --list --unsorted

DEPLOY_SCRIPT := "script/Deploy.s.sol:Deploy"

# Run mainnet solver forks using vars; pass false to skip live aggregator APIs.
[group('test')]
fork-tests live="true":
    #!/usr/bin/env bash
    set -euo pipefail
    resolved=$(vars resolve --file script/open-fill/vars.yaml --partial)
    eval "$resolved"
    RUN_FORK_TESTS=true RUN_LIVE_QUOTES={{ quote(live) }} forge test --match-contract GenericOpenFillForkTest --ffi -vv

# Fetch dependencies, create local configuration and select the network.
[group('setup')]
init network="mainnet":
    #!/usr/bin/env bash
    set -euo pipefail
    git submodule update --init --recursive
    if [ ! -f .env ]; then
        cp .env.example .env
        echo "Created .env from .env.example. Configure deployment settings before broadcasting."
    fi
    if ! command -v forge &>/dev/null; then
        echo "Error: Foundry is not installed. Run 'just setup' to install it."
        exit 1
    fi
    if ! command -v vars &>/dev/null; then
        echo "Note: vars is optional. Use .env for secrets, or install vars with 'just install-vars'."
    fi
    just switch {{ quote(network) }}
