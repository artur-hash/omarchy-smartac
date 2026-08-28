#!/usr/bin/env bash
# Set up the SmartThings AC plugin.
#
# Does, in order:
#   1. checks that node and npm are present, and stops with a plain instruction
#      if they are not
#   2. installs @smartthings/cli globally -- after asking
#   3. logs that CLI in, which opens a browser
#   4. runs the plugin's own doctor to confirm the result
#
# Nothing here runs on its own: Omarchy never executes plugin code at install
# time, and this script asks before the one command that writes outside the
# plugin's own directory.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; RESET=$'\e[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %sok%s    %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s--%s    %s\n' "$DIM" "$RESET" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$*"; exit 1; }

ask() {
  local reply
  read -r -p "  $1 [y/N] " reply < /dev/tty || return 1
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

say "${BOLD}SmartThings AC plugin setup${RESET}"
say ""

# ---- 1. node and npm ------------------------------------------------------
# Installing these is the system's business, not this script's: the right command
# differs per distribution and doing it silently is not what anyone expects from
# a bar widget. Nor does the advice name one -- this script never elevates, and a
# reader should not have to read it to be sure of that.
command -v node >/dev/null 2>&1 || fail "node is not installed. Install it with your distribution package manager, then re-run this script"
command -v npm  >/dev/null 2>&1 || fail "npm is not installed. Install it with your distribution package manager, then re-run this script"
ok "node $(node --version)"

# ---- 2. the SmartThings CLI ----------------------------------------------
if command -v smartthings >/dev/null 2>&1; then
  ok "SmartThings CLI $(smartthings --version 2>/dev/null | head -1) already installed"
else
  say ""
  say "  This plugin reads the session the SmartThings CLI keeps, which renews"
  say "  itself. It needs to be installed globally so it can do that renewing:"
  say ""
  say "    ${BOLD}npm install -g @smartthings/cli${RESET}"
  say ""
  ask "Install it now?" || fail "nothing installed. Run the command above yourself, then re-run this script"
  npm install -g @smartthings/cli || fail "npm install failed. If it was a permissions error, set a user prefix (npm config set prefix ~/.local) and try again"
  command -v smartthings >/dev/null 2>&1 \
    || fail "installed, but 'smartthings' is not on PATH. Add npm's global bin directory to PATH and re-run this script"
  ok "SmartThings CLI installed"
fi

# ---- 3. log in ------------------------------------------------------------
# The CLI has no login command: it authenticates on its first API call. Asking
# for locations is the cheapest one, and it is what the official documentation
# tells people to run.
say ""
if smartthings locations --json >/dev/null 2>&1; then
  ok "already logged in"
else
  say "  A browser will open. Log in and approve access."
  say ""
  ask "Open it now?" || fail "not logged in. Run 'smartthings locations' yourself when ready"
  smartthings locations >/dev/null || fail "login did not complete. Run 'smartthings locations' to try again"
  ok "logged in"
fi

# ---- 4. confirm -----------------------------------------------------------
say ""
say "${BOLD}Checking the plugin${RESET}"
say ""
if "$DIR/bin/smartac" doctor; then
  say ""
  say "${GREEN}Ready.${RESET} Add the widget to the bar, then pick your air conditioner in the panel."
else
  say ""
  fail "the plugin still cannot reach SmartThings — the doctor output above says why"
fi
