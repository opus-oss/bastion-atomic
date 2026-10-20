#!/usr/bin/env bash
# Configure a patched linux-hardened tree:  configure.sh <source tree> <base config> [fragment...]
# Run by the Containerfile's kernel stage, and runnable by hand to check a fragment change before
# pushing it. Fragments are merged over the base in order, then the kernel's own kconfig settles
# defaults and dependencies; any fragment line olddefconfig changed fails the run, so a typo or
# an unmet dependency is a build error rather than a kernel that quietly lacks the option.
set -euo pipefail
src=$1 base=$2
shift 2

cd "$src"
cp "$base" .config
for frag in "$@"; do
  ./scripts/kconfig/merge_config.sh -m -O . .config "$frag" >/dev/null
done
make -s olddefconfig

status=0
for frag in "$@"; do
  while IFS= read -r line; do
    case $line in
      CONFIG_*=*) grep -qxF -- "$line" .config || { echo "not applied: $line (now: $(grep -E "^(# )?${line%%=*}[= ]" .config || echo absent))"; status=1; } ;;
      "# CONFIG_"*" is not set") opt=${line#\# }; opt=${opt%% *}; ! grep -qE "^$opt=" .config || { echo "not applied: $line"; status=1; } ;;
    esac
  done < "$frag"
done
exit $status
