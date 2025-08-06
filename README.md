# log-analyze-and-sort.sh

A Bash script to search for log lines matching a string in files under a directory, sort them by timestamp, and write the results to an output file. It can also filter lines from an existing file by removing lines containing specified strings.

## Usage

```
./log-analyze-and-sort.sh <search_dir> <search_string> <file_patterns> <exclude_string> <output_file>
    (search & sort mode)

./log-analyze-and-sort.sh --filter-only <input_file> <remove_list> <output_file>
    (filter-only mode)
```

- `search_dir`: Directory under which to search for log files.
- `search_string`: Literal string to match inside files.
- `file_patterns`: Comma-separated filename globs (e.g. `'*foo*,*bar*'`). Use `'*'` to match all files.
- `exclude_string`: Literal string; any matched line containing this will be excluded. Use `''` to disable.
- `output_file`: File to write the time-sorted matches into.
- `input_file`: (filter-only mode) File to filter lines from.
- `remove_list`: (filter-only mode) Comma-separated list of strings; lines containing any will be removed.

### Environment Variables
- `SORT_ORDER=asc|desc` (default: `asc`)
  - `asc`: Sort from oldest to newest.
  - `desc`: Sort from newest to oldest.

## Features
- **Search & sort mode:**
  - Searches for files matching the given patterns under the specified directory.
  - Finds lines containing the search string.
  - Excludes lines containing the exclude string (if provided).
  - Sorts the results by timestamp (ISO8601 format required in log lines).
  - For log files under `/logs/longhorn-system/<pod>/`, prepends `[owner node]:` to each line using pod info from Kubernetes (requires `kubectl` access to a real cluster or an `sb` simulator).
  - Collapses multiple blank lines into a single blank line.
- **Filter-only mode:**
  - Removes lines containing any string in `remove_list`.
  - Collapses blank lines.
  - Supports in-place filtering if input and output files are the same.

## Examples

**Search & sort mode:**
```
./log-analyze-and-sort.sh /path/to/logs my-search-term '*longhorn-csi-plugin*,*longhorn-manager*' 'Request (user: system:serviceaccount:longhorn-system:longhorn-service-account' ./sorted.log
```
This will:
- Search for files matching `*longhorn-csi-plugin*` or `*longhorn-manager*` under `/path/to/logs`.
- Find lines containing `my-search-term`.
- Exclude lines containing the specified `exclude_string`.
- Sort the results by timestamp and write to `./sorted.log`.
- For log files under `/logs/longhorn-system/<pod>/`, prepend `[owner node]:` to each line using pod info from Kubernetes.

**Filter-only mode:**
```
./log-analyze-and-sort.sh --filter-only ./sorted.log 'foo,bar,baz' ./filtered.log
```
This will:
- Remove lines containing `foo`, `bar`, or `baz` from `./sorted.log`.
- Collapse blank lines.
- Write the result to `./filtered.log`.
- If input and output files are the same, filtering is done safely in-place.

---

For more details, see comments in the script file.