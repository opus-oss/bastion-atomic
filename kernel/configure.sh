#!/usr/bin/env bash
# Configure a patched linux-hardened tree:  configure.sh <source tree> <base config> [fragment...]
# Run by the Containerfile's kernel stage, and runnable by hand to check a fragment change before
# pushing it. Fragments are merged over the base in order, then the kernel's own kconfig settles
# defaults and dependencies; any fragment line olddefconfig changed fails the run, so a typo or
# an unmet dependency is a build error rather than a kernel that quietly lacks the option. A later
# fragment may override an earlier one's line.
set -euo pipefail
src=$1 base=$2
shift 2

cd "$src"
cp "$base" .config
for frag in "$@"; do
  ./scripts/kconfig/merge_config.sh -m -O . .config "$frag" >/dev/null
done
make -s olddefconfig

# Check what the fragments ask for, the last fragment's word winning where two name the same
# option (kernel/vm/ubuntu.config overrides common.config's LSM, for example).
status=0
declare -A want=()
for frag in "$@"; do
  while IFS= read -r line; do
    case $line in
      CONFIG_*=*) want[${line%%=*}]=$line ;;
      "# CONFIG_"*" is not set") opt=${line#\# }; want[${opt%% *}]=$line ;;
    esac
  done < "$frag"
done
for opt in "${!want[@]}"; do
  line=${want[$opt]}
  case $line in
    CONFIG_*=*) grep -qxF -- "$line" .config || { echo "not applied: $line (now: $(grep -E "^(# )?${opt}[= ]" .config || echo absent))"; status=1; } ;;
    *) ! grep -qE "^$opt=" .config || { echo "not applied: $line"; status=1; } ;;
  esac
done
exit $status
