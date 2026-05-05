#!/usr/bin/env bash
set -euo pipefail

LARGE_DIR_THRESHOLD="${LARGE_DIR_THRESHOLD:-500}"
LARGE_FILE_BYTES="${LARGE_FILE_BYTES:-1048576}"

root="${1:-.}"

if [[ ! -d "$root" ]]; then
  printf 'Error: not a directory: %s\n' "$root" >&2
  exit 1
fi

# Allowed code/text extensions
declare -A ALLOWED_EXT=(
  [txt]=1 [py]=1 [cpp]=1 [c]=1 [h]=1 [hpp]=1
  [json]=1 [ps1]=1 [sh]=1 [java]=1
  [js]=1 [ts]=1 [html]=1 [css]=1
  [go]=1 [rs]=1 [rb]=1 [php]=1
  [sql]=1 [yml]=1 [yaml]=1 [xml]=1
  [md]=1
)

# Exclude hidden directories like .git, .venv, etc.
PRUNE_DIRS=(-name .git -o -name .venv -o -name node_modules)

should_prune() {
  local path="$1"
  for d in .git .venv node_modules; do
    [[ "$path" == */"$d" ]] && return 0
  done
  return 1
}

file_count="$(find "$root" \( -type d \( -name .git -o -name .venv -o -name node_modules \) -prune \) -o -type f -print | wc -l | tr -d ' ')"

if (( file_count > LARGE_DIR_THRESHOLD )); then
  printf 'Warning: large directory detected (%s files).\nContinue? (y/n): ' "$file_count" >&2
  read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 0
fi

has_allowed_ext() {
  local f="$1"
  local ext="${f##*.}"
  [[ "$f" == "$ext" ]] && return 1
  [[ -n "${ALLOWED_EXT[$ext]+x}" ]]
}

# Clipboard detection (Linux/macOS/WSL)
copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif command -v clip.exe >/dev/null 2>&1; then
    clip.exe
  else
    cat >/dev/null
    printf 'Warning: no clipboard utility found.\n' >&2
  fi
}

# Tree printer (no external `tree` dependency)
print_tree() {
  local dir="$1"
  local prefix="$2"

  local entries=()
  while IFS= read -r -d '' e; do
    if [[ -d "$e" ]]; then
      # include dir only if it contains at least one allowed file somewhere
      if find "$e" -type f -print0 | while IFS= read -r -d '' f; do
  has_allowed_ext "$f" && return 0
done; then
  entries+=("$e")
fi
    else
      has_allowed_ext "$e" && entries+=("$e")
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  local total="${#entries[@]}"
  for ((i=0; i<total; i++)); do
    local entry="${entries[$i]}"
    local name="${entry##*/}"
    local connector="├── "
    local next_prefix="${prefix}│   "

    if (( i == total - 1 )); then
      connector="└── "
      next_prefix="${prefix}    "
    fi

    printf '%s%s%s\n' "$prefix" "$connector" "$name"

    [[ -d "$entry" ]] && print_tree "$entry" "$next_prefix"
  done
}

# Build full output, then tee to stdout + clipboard
{
    find "$root" \( -type d \( -name .git -o -name .venv -o -name node_modules \) -prune \) -o -type f -print0 |
    while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    has_allowed_ext "$file" || continue

    size=$(wc -c < "$file" | tr -d ' ')

    if (( size > LARGE_FILE_BYTES )); then
      printf 'Large file: %s (%d bytes). Continue? (y/n): ' "$file" "$size" >&2
      read -r ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || continue
    fi

    printf '===== %s =====\n' "${file#./}"
    tr -d '\r\n' < "$file"
    printf '\n\n'
  done

  printf '===== DIRECTORY TREE =====\n'
  printf '%s\n' "${root%/}"
  print_tree "$root" ""
} | tee >(copy_to_clipboard)

printf 'Done. Press Enter to exit.'
read -r