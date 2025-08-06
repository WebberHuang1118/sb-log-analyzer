#!/usr/bin/env bash
set -eo pipefail
# Removed the 'u' option to allow for unbound variable checks to be handled manually

# sb-log-analyzer: Log sorting and filtering utility
#
# Usage examples:
#   ./sb-log-analyzer.sh <search_dir> <search_string> <file_patterns> <exclude_string> <output_file>
#   ./sb-log-analyzer.sh --filter-only <input_file> <remove_list> <output_file>
#
# Features:
#   - Search and sort log files by timestamp (asc/desc)
#   - Filter out lines by string(s)
#   - Collapse blank lines
#   - Kubernetes pod owner/node annotation for Longhorn logs
#
# For details, see README.md

usage() {
  cat <<EOF
Usage:
  $0 [--sb-path <sb_path>] [--annotate-pods] <search_string> <file_patterns> <exclude_string> <output_file>
    (original search mode, always searches logs/ under sb_path)

  $0 --filter-only <input_file> <remove_list> <output_file>
    (filter-only mode: remove lines containing any comma-separated strings, then collapse blank lines)

ENV:
  SORT_ORDER=asc|desc   (default asc)  asc = oldest->newest, desc = newest->oldest
EOF
  exit 1
}

# ---------- parse args -------------------------------------------------
# Default values
sb_path=""
annotate_pods=0

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sb-path)
      sb_path="$2"; shift 2;;
    --annotate-pods)
      annotate_pods=1; shift;;
    --filter-only)
      args+=("$1" "$2" "$3" "$4"); shift 4;;
    *)
      args+=("$1"); shift;;
  esac
done

set -- "${args[@]}"

if [[ "$#" -eq 4 && "$1" == "--filter-only" ]]; then
  # filter-only mode
  input_file="$2"
  remove_arg="$3"
  output_file="$4"

  # build grep -v command for multiple patterns
  IFS=',' read -r -a remove_list <<< "$remove_arg"
  exclude_cmd=( grep -F -v )
  for pat in "${remove_list[@]}"; do
    exclude_cmd+=( -e "$pat" )
  done

  # collapse blank lines to one
  collapse_blanks() {
    awk 'BEGIN{prev=0} \
         /^$/   { if(prev==0){ print; prev=1 } ; next } \
               { prev=0; print }'
  }

  # perform in-place safe filtering if input == output
  if [[ "$input_file" == "$output_file" ]]; then
    tmpfile=$(mktemp)
    "${exclude_cmd[@]}" "$input_file" | collapse_blanks > "$tmpfile"
    mv "$tmpfile" "$output_file"
    echo "Filtered $input_file -> $output_file (in-place) (removed: ${remove_list[*]})"
  else
    "${exclude_cmd[@]}" "$input_file" | collapse_blanks > "$output_file"
    echo "Filtered $input_file -> $output_file (removed: ${remove_list[*]})"
  fi
  exit 0
fi

# ---------- original search pipeline mode ------------------------------
if [ "$#" -ne 4 ]; then usage; fi

if [[ -z "$sb_path" ]]; then
  echo "Error: --sb-path <sb_path> must be specified." >&2
  usage
fi
search_dir="$sb_path/logs"
search_str="$1"
patterns_arg="$2"
exclude_str="$3"
output_file="$4"

# ---------- expand file globs ----------
if [ -z "$patterns_arg" ]; then
  patterns=( '*' )
else
  IFS=',' read -r -a patterns <<< "$patterns_arg"
fi

name_expr=()
[[ ${#patterns[@]} -gt 1 ]] && name_expr+=( '(' )
for i in "${!patterns[@]}"; do
  name_expr+=( -name "${patterns[i]}" )
  [[ "$i" -lt $(( ${#patterns[@]} - 1 )) ]] && name_expr+=( -o )
 done
[[ ${#patterns[@]} -gt 1 ]] && name_expr+=( ')' )

# ---------- exclude filter ----------
if [[ -n "$exclude_str" ]]; then
  exclude_cmd=( grep -F -v -- "$exclude_str" )
else
  exclude_cmd=( cat )
fi

# ---------- sort order ----------
sort_flags=()
[[ "${SORT_ORDER:-asc}" == "desc" ]] && sort_flags+=( -r )

# non-printing delimiter (Unit Separator)
delim=$'\x1f'

# ---------- build pod->(owner,node) map ----------
pod_map_enabled="$annotate_pods"
declare -A pod_map=()  # Initialize empty associative array explicitly
if [[ "$pod_map_enabled" == "1" ]]; then
  # First try to get pod information from the support bundle
  pod_list_file=""
  possible_locations=(
    "$sb_path/objects/longhorn-system/pods.json"
    "$sb_path/objects/longhorn-system/pods.yaml"
    "$sb_path/objects/api/v1/namespaces/longhorn-system/pods.json"
  )

  for location in "${possible_locations[@]}"; do
    if [[ -f "$location" ]]; then
      pod_list_file="$location"
      break
    fi
  done

  if [[ -n "$pod_list_file" ]]; then
    echo "Loading pod information from $pod_list_file"
    if [[ "$pod_list_file" == *.json ]]; then
      # Extract pod info from JSON (requires jq)
      if command -v jq >/dev/null 2>&1; then
        while read -r pod owner node; do
          [[ -n "$pod" && -n "$owner" && -n "$node" ]] || continue
          pod_map["$pod"]="$owner $node"
        done < <(
          jq -r '.items[] | select(.metadata.name != null) |
            [.metadata.name,
             (.metadata.ownerReferences[] | select(.controller==true) | .name) // "unknown",
             .spec.nodeName // "unknown"] | 
            @tsv' "$pod_list_file"
        )
      else
        echo "Warning: jq not found. Cannot parse JSON pod information." >&2
      fi
    elif [[ "$pod_list_file" == *.yaml ]]; then
      echo "Warning: YAML parsing not implemented yet. Using kubectl fallback." >&2
    fi
  fi

  # Fallback to kubectl if no pods were loaded from files
  if [[ ${#pod_map[@]} -eq 0 ]]; then
    echo "Trying to get pod information from kubectl..."
    while read -r pod owner node; do
      [[ -n "$pod" && -n "$owner" && -n "$node" ]] || continue
      pod_map["$pod"]="$owner $node"
    done < <(
      kubectl get pods -n longhorn-system \
        -o=jsonpath='{range .items[*]}{.metadata.name} {.metadata.ownerReferences[?(@.controller==true)].name} {.spec.nodeName}{"\n"}{end}' 2>/dev/null || echo ""
    )
  fi

  # Report pod map status
  if [[ ${#pod_map[@]} -gt 0 ]]; then
    echo "Successfully loaded information for ${#pod_map[@]} pods"
  else
    echo "Warning: Could not load pod information. Pod annotations will not be applied." >&2
    pod_map_enabled=0
  fi
fi

# ---------- transform function ----------
transform() {
  while IFS= read -r line; do
    # Match both ./logs/longhorn-system/pod/file.log and logs/longhorn-system/pod/file.log formats
    if [[ "$line" =~ ^.*[/.]logs/longhorn-system/([^/]+)/[^:]+ ]]; then
      pod="${BASH_REMATCH[1]}"
      # Remove .log or .log.N suffix if present
      pod=${pod%%.*}

      if [[ "$pod_map_enabled" == "1" && -n "${pod_map[$pod]+x}" ]]; then
        info="${pod_map[$pod]}"
        owner="${info%% *}"
        node="${info#* }"
        # Format with owner and node prepended
        echo "[${owner} ${node}]:${line#*:}"
      else
        echo "$line"
      fi
    else
      echo "$line"
    fi
  done
}

# ---------- collapse blank lines to single ----------
collapse_blanks() {
  awk 'BEGIN{prev=0} \
       /^$/   { if(prev==0){ print; prev=1 } ; next } \
             { prev=0; print }'
}

# ---------- pipeline ----------
find "$search_dir" -type f "${name_expr[@]}" \
  -exec grep -H -F -- "$search_str" {} + | \
  "${exclude_cmd[@]}"          | \
  awk -v d="$delim" '         
    {                            
      line = substr($0, index($0,":")+1)
      if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?/)) {
        ts = substr(line, RSTART, RLENGTH)
        printf "%s%s%s\n", ts, d, $0
      }
    }
  ' | \
  LC_ALL=C sort -t"$delim" -k1,1 "${sort_flags[@]}" | \
  cut -d"$delim" -f2-       | \
  transform                   | \
  sed 'G'                     | \
  collapse_blanks >"$output_file"

echo "Wrote results to $output_file  (order=${SORT_ORDER:-asc})"
