#!/bin/zsh

set -euo pipefail

PORT="${1:-4173}"
DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"

echo "Serving Sailor Piece live document from ${DIRECTORY} on http://127.0.0.1:${PORT}"
cd "${DIRECTORY}"
exec env BIND_ADDRESS="${BIND_ADDRESS}" ruby ./server.rb "${PORT}"
