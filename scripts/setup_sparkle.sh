#!/usr/bin/env bash
#
# Fetches the Sparkle CLI tools (generate_keys, sign_update, etc.) into
# scripts/sparkle/. These tools are NOT shipped in the Swift package — only
# the runtime is. We need them for key generation and per-release signing.
#
# The tools directory is gitignored. Re-run this on any new machine.
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${SPARKLE_VERSION:-2.9.2}"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"

if [ -x scripts/sparkle/bin/generate_keys ]; then
  echo "Sparkle tools already installed at scripts/sparkle/bin/"
  echo "Delete that directory and re-run to refresh."
  exit 0
fi

echo "==> Downloading Sparkle ${VERSION}"
mkdir -p scripts/sparkle
curl -fsSL -o scripts/sparkle/Sparkle.tar.xz "$URL"

echo "==> Extracting"
tar -xf scripts/sparkle/Sparkle.tar.xz -C scripts/sparkle
rm scripts/sparkle/Sparkle.tar.xz

echo "==> Done"
echo
echo "Tools available:"
ls scripts/sparkle/bin/
echo
echo "First time? Run:"
echo "    ./scripts/sparkle/bin/generate_keys"
echo "to create an EdDSA key pair (private key → Keychain, public key → stdout)."
