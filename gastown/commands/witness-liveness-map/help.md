# gc gastown witness-liveness-map

Build a read-only liveness snapshot for witness orphan recovery. On stdout the
command prints one line of JSON: `{"map":{...},"map_count":N,"session_count":M}`.
The map associates exact session identities with their states; the counts are
map entries and roster sessions respectively. Diagnostics go to stderr.

- `0`: the map is usable, including an empty map for an empty roster.
- `1`: a query or jq failed, or the map is empty while sessions exist. This
  means liveness could not be verified; do not treat the map as evidence that
  an assignee is absent. Every exit-1 path prints one parseable JSON line;
  a failed query reports both counts as 0, while a jq or empty-map failure
  keeps the readable session count.
- `2`: `GC_PACK_DIR` is missing. stdout is empty on this path.
