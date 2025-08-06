#!/usr/bin/env bash
set -euo pipefail

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
  $0 <search_dir> <search_string> <file_patterns> <exclude_string> <output_file>
    (original search mode)

  $0 --filter-only <input_file> <remove_list> <output_file>
    (filter-only mode: remove lines containing any comma-separated strings, then collapse blank lines)

ENV:
  SORT_ORDER=asc|desc   (default asc)  asc = oldest->newest, desc = newest->oldest
EOF
  exit 1
}

# ---------- parse args -------------------------------------------------
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
if [ "$#" -ne 5 ]; then usage; fi

search_dir="$1"
search_str="$2"
patterns_arg="$3"
exclude_str="$4"
output_file="$5"

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
declare -A pod_map
while read -r pod owner node; do
  [[ -n "$pod" && -n "$owner" && -n "$node" ]] || continue
  pod_map["$pod"]="$owner $node"
done < <(
  kubectl get pods -n longhorn-system \
    -o=jsonpath='{range .items[*]}{.metadata.name} {.metadata.ownerReferences[?(@.controller==true)].name} {.spec.nodeName}{"\n"}{end}'
)

# ---------- transform function ----------
transform() {
  while IFS= read -r line; do
    # Match both ./logs/longhorn-system/pod/file.log and logs/longhorn-system/pod/file.log formats
    if [[ "$line" =~ ^\.?/?logs/longhorn-system/([^/]+)/[^:]+:(.+) ]]; then
      pod="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      info="${pod_map[$pod]:-$pod unknown}"
      owner="${info%% *}"
      node="${info#* }"
      printf "[%s %s]:%s\n" "$owner" "$node" "$rest"
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
