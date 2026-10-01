# env.sh - shell environment of the multi-agent flow.
# Usage: source .maf/env.sh
# The file puts .maf/bin on PATH. After that, a worker runs `coord`, not `./coord`.
MAF_BIN="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bin"
export MAF_BIN
case ":$PATH:" in *":$MAF_BIN:"*) ;; *) export PATH="$MAF_BIN:$PATH" ;; esac
