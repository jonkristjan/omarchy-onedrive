#!/bin/bash
# Make OneDrive Office files open in the Office web apps.
#
#   ./install-office-opener.sh              link the opener and make it the default for Office files
#   ./install-office-opener.sh --uninstall  put the previous defaults back and remove the links
#
# Links (not copies) point into this checkout, so `omarchy plugin update`
# updates the opener too.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="$HOME/.local/bin"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/onedrive-office"
SAVED="$STATE/previous-defaults"
DESKTOP="onedrive-office.desktop"

TYPES=(
  application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  application/vnd.ms-excel.sheet.macroEnabled.12
  application/vnd.ms-excel.sheet.binary.macroEnabled.12
  application/vnd.ms-excel
  application/vnd.openxmlformats-officedocument.wordprocessingml.document
  application/vnd.ms-word.document.macroEnabled.12
  application/msword
  application/vnd.openxmlformats-officedocument.presentationml.presentation
  application/vnd.ms-powerpoint.presentation.macroEnabled.12
  application/vnd.ms-powerpoint
  application/vnd.openxmlformats-officedocument.presentationml.slideshow
)

MIMEAPPS="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"

# The first desktop id listed for a type under [Default Applications], or "".
explicit_default() {
  [[ -f $MIMEAPPS ]] || return 0
  awk -v type="$1" '
    /^\[/ { section = $0; next }
    section == "[Default Applications]" && index($0, type "=") == 1 {
      value = substr($0, length(type) + 2); sub(/;.*/, "", value); print value; exit
    }' "$MIMEAPPS"
}

install() {
  for cmd in onedrive omarchy-launch-webapp python3 xdg-mime; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }
  done
  command -v libreoffice >/dev/null || echo "Note: LibreOffice is not installed; files outside OneDrive will have no local app." >&2

  mkdir -p "$BIN" "$APPS" "$STATE"

  # Remember the defaults set explicitly in mimeapps.list, once, so --uninstall
  # can restore them. Not `xdg-mime query default`: for a type with no default
  # it reports a guess, and restoring that would pin an app nobody chose.
  if [[ ! -f $SAVED ]]; then
    for type in "${TYPES[@]}"; do
      previous=$(explicit_default "$type")
      [[ $previous == "$DESKTOP" ]] && previous=""
      echo "$type=$previous"
    done >"$SAVED"
  fi

  ln -sfn "$DIR/office/onedrive-office-open" "$BIN/onedrive-office-open"
  ln -sfn "$DIR/office/$DESKTOP" "$APPS/$DESKTOP"
  update-desktop-database "$APPS" 2>/dev/null || true

  xdg-mime default "$DESKTOP" "${TYPES[@]}"
  echo "Office files under your OneDrive folder now open in the Office web apps."
  echo "Undo with: $0 --uninstall"
}

uninstall() {
  # Drop our default for every type, then put back what was there before.
  # --follow-symlinks keeps a mimeapps.list that is a link (dotfiles) a link.
  [[ -f $MIMEAPPS ]] && sed --follow-symlinks -i "/=${DESKTOP//./\\.}\$/d" "$MIMEAPPS"
  if [[ -f $SAVED ]]; then
    while IFS='=' read -r type previous; do
      if [[ -n $previous && $previous != "$DESKTOP" ]]; then
        xdg-mime default "$previous" "$type"
      fi
    done <"$SAVED"
    rm -f "$SAVED"
  fi
  [[ -L $BIN/onedrive-office-open ]] && rm -f "$BIN/onedrive-office-open"
  [[ -L $APPS/$DESKTOP ]] && rm -f "$APPS/$DESKTOP"
  update-desktop-database "$APPS" 2>/dev/null || true
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/onedrive-office"
  echo "Removed. Office files open with their previous apps again."
}

case "${1:-}" in
  "") install ;;
  --uninstall) uninstall ;;
  -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac
