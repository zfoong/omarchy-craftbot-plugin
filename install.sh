#!/bin/bash
# Install CraftBot from source and start it, as its README describes
# (`git clone ... && python3 craftbot.py install`), but pinned: the code that
# runs is one exact, reviewed CraftBot commit, fetched and checked out detached
# and verified before anything executes.
#
# Run by the CraftBot bar widget in a floating terminal, so the ~1 GB download
# is visible. `craftbot.py install` starts CraftBot, turns on auto-start (a
# craftbot.service user unit) and opens it in the browser; the widget picks it
# up from there. Afterwards the checkout is put on a local `main` branch at the
# same commit, because CraftBot's own updater only updates a checkout on
# `main` (it runs `git pull --ff-only origin main` when you choose to update).
#
# An existing CraftBot in the folder is started, not replaced.
#
# Usage: install.sh [install-dir]   (default: ~/CraftBot)

set -o errexit -o nounset -o pipefail

REPO="https://github.com/CraftOS-dev/CraftBot.git"
# CraftBot v1.4.4. Bump together with CRAFTBOT_VERSION and the hash in the
# `checkout --detach` line below, in a new plugin release.
CRAFTBOT_COMMIT="1a9416856840c89f0f4b779311558bddca056600"
CRAFTBOT_VERSION="v1.4.4"

dir="${1:-$HOME/CraftBot}"

case "$dir" in
  "$HOME"/*) ;;
  *) echo "Refusing to install outside your home folder: $dir" >&2; exit 1 ;;
esac

for tool in git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "CraftBot needs $tool. Install it with: omarchy pkg add $tool" >&2
    exit 1
  fi
done

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
  echo "CraftBot needs Python 3.8 or newer (found $(python3 --version 2>&1))." >&2
  exit 1
fi

if [[ -f $dir/craftbot.py ]]; then
  echo "CraftBot is already in $dir. Starting it."
  cd "$dir"
  exec python3 craftbot.py start
fi

if [[ -e $dir ]] && [[ -n $(ls -A "$dir" 2>/dev/null) ]]; then
  echo "$dir already exists and isn't a CraftBot folder." >&2
  echo "Move it away, or set another folder: omarchy bar set craftbot.status installDir ~/somewhere" >&2
  exit 1
fi

echo "Installing CraftBot $CRAFTBOT_VERSION into $dir"
echo "This downloads about 1 GB and takes a few minutes."
echo

# Fetch exactly the pinned commit, check it out detached, verify it, and only
# then run CraftBot's installer, all in one chain that stops at the first
# failure. The hash is written out (not $CRAFTBOT_COMMIT) so review tools can
# see the pin.
git init -q "$dir"
git -C "$dir" remote add origin "$REPO"
git -C "$dir" fetch --depth 1 origin "$CRAFTBOT_COMMIT"
git -C "$dir" checkout -q --detach 1a9416856840c89f0f4b779311558bddca056600 \
  && [[ $(git -C "$dir" rev-parse HEAD) == "$CRAFTBOT_COMMIT" ]] \
  && cd "$dir" \
  && python3 craftbot.py install \
  || { echo "Installing CraftBot $CRAFTBOT_VERSION ($CRAFTBOT_COMMIT) failed; see above." >&2; exit 1; }

# Hand the checkout to CraftBot's own updater, which follows `main`. The code
# stays at the pinned commit until you choose to update from CraftBot.
git checkout -q -B main
git config branch.main.remote origin
git config branch.main.merge refs/heads/main
