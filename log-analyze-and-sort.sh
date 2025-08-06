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
declare -A pod_cache=()  # Cache for pod lookups (including not found)

# Function to extract pod info from YAML manifest
extract_pod_from_yaml() {
  local pod_name="$1"
  local namespace="$2"
  local yaml_file="$3"

  # Create cache key with namespace to avoid conflicts
  local cache_key="${namespace}/${pod_name}"

  # Check cache first
  if [[ -n "${pod_cache[$cache_key]+x}" ]]; then
    if [[ "${pod_cache[$cache_key]}" != "NOT_FOUND" ]]; then
      echo "${pod_cache[$cache_key]}"
    fi
    return
  fi

  if [[ ! -f "$yaml_file" ]]; then
    pod_cache["$cache_key"]="NOT_FOUND"
    return
  fi

  # Parse YAML to find the specific pod and extract owner/node info
  # This searches for the pod by name and extracts owner reference and nodeName
  local result
  result=$(awk -v target_pod="$pod_name" '
    BEGIN {
      found_target = 0
      owner = "unknown"
      node = "unknown"
      in_owner_ref = 0
      output_done = 0
    }

    # Found the target pod name
    /^    name: / && $2 == target_pod {
      found_target = 1
      next
    }

    # Extract owner reference name when we find controller: true
    found_target && /^    - apiVersion:/ {
      in_owner_ref = 1
      next
    }

    found_target && in_owner_ref && /^      controller: true/ {
      # The next few lines should contain the owner name
      while ((getline line) > 0) {
        if (line ~ /^      name: /) {
          split(line, parts, ": ")
          owner = parts[2]
          break
        }
        if (line ~ /^    [^ ]/ || line ~ /^  [^ ]/) {
          # End of this owner reference block
          break
        }
      }
      in_owner_ref = 0
      next
    }

    # Extract node name
    found_target && /^    nodeName: / {
      node = $2
    }

    # End of current pod (start of next item) - output and exit
    found_target && /^- apiVersion: v1/ {
      if (!output_done) {
        print owner " " node
        output_done = 1
      }
      exit
    }

    # Alternative end condition - new pod item
    found_target && /^    name: / && $2 != target_pod {
      if (!output_done) {
        print owner " " node
        output_done = 1
      }
      exit
    }

    END {
      if (found_target && !output_done) {
        print owner " " node
      }
    }
  ' "$yaml_file")

  if [[ -n "$result" ]]; then
    # Clean up any newlines or extra whitespace from the result
    result=$(echo "$result" | tr -d '\n' | sed 's/[[:space:]]\+/ /g' | sed 's/^ *//;s/ *$//')
    pod_cache["$cache_key"]="$result"
    echo "$result"
  else
    pod_cache["$cache_key"]="NOT_FOUND"
  fi
}

# Function to find pod manifest file for a given namespace
find_pod_manifest() {
  local namespace="$1"

  # Try different possible locations for pod manifests
  local possible_locations=(
    "$sb_path/yamls/namespaced/$namespace/v1/pods.yaml"
    "$sb_path/yamls/$namespace/pods.yaml"
    "$sb_path/manifests/$namespace/pods.yaml"
    "$sb_path/objects/$namespace/pods.yaml"
  )

  for location in "${possible_locations[@]}"; do
    if [[ -f "$location" ]]; then
      echo "$location"
      return 0
    fi
  done

  return 1
}

if [[ "$pod_map_enabled" == "1" ]]; then
  echo "Pod annotation mode enabled - will discover namespaces dynamically"
  # We'll discover manifest files on-demand per namespace
fi

# ---------- transform function ----------
transform() {
  while IFS= read -r line; do
    # Match log paths with namespace/pod/file.log format
    # Supports both ./logs/namespace/pod/file.log and logs/namespace/pod/file.log formats
    if [[ "$line" =~ ^.*[/.]logs/([^/]+)/([^/]+)/[^:]+ ]]; then
      namespace="${BASH_REMATCH[1]}"
      pod="${BASH_REMATCH[2]}"
      # Remove .log or .log.N suffix if present
      pod=${pod%%.*}

      if [[ "$pod_map_enabled" == "1" ]]; then
        # Find the pod manifest file for this namespace
        yaml_pods_file=$(find_pod_manifest "$namespace")

        if [[ -n "$yaml_pods_file" ]]; then
          # Extract pod info on-demand with caching
          info=$(extract_pod_from_yaml "$pod" "$namespace" "$yaml_pods_file")

          if [[ -n "$info" ]]; then
            owner="${info%% *}"
            node="${info#* }"
            # Format with namespace, owner and node prepended
            echo "[${namespace}/${owner} ${node}]:${line#*:}"
          else
            # Pod not found in manifest, output with namespace only
            echo "[${namespace}]:${line#*:}"
          fi
        else
          # No manifest found for namespace, output with namespace only
          echo "[${namespace}]:${line#*:}"
        fi
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
