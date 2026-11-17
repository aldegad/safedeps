#!/usr/bin/env bash
# The runtime stage: which JDKs this host and the roots pin, and whether the
# vendor has shipped past what they run. It says update status, never a
# verdict: OSV stays the advisory truth for packages, and no JDK is "clean".
#
# Sources, all official and all read-only:
#   OpenJDK Vulnerability Group advisories (openjdk.org/groups/vulnerability/
#     advisories/): the index lists each advisory by date; each advisory names
#     the affected versions per line ("The affected versions are 21.0.13, ...,
#     and earlier"). The index also states the schedule: the third Tuesday of
#     January, April, July and October.
#   Adoptium API (api.adoptium.net/v3/assets/feature_releases/<F>/ga): the
#     latest Temurin GA build of a feature line, with its date.
#
# Each JDK gets one state from a closed set (state.jq: runtime_states):
#   update_available(vendor, current, latest, advisory_url, advisory_date)
#   pre_announced(source, date)   the newest advisory names this version as
#                                 affected and the vendor has no newer build,
#                                 or the next scheduled advisory is <= 14 days
#                                 away
#   current_as_of(advisory_date)  nothing newer as of that advisory; an
#                                 unannounced CVE is not covered by it
#   vendor_feed_missing           no feed for this vendor is read
#   feed_unavailable              a feed could not be read
# A JDK in a location this stage does not read is an unmeasured row.

SAFEDEPS_WATCH_OPENJDK_ADVISORIES_DEFAULT="https://openjdk.org/groups/vulnerability/advisories/"
SAFEDEPS_WATCH_ADOPTIUM_API_DEFAULT="https://api.adoptium.net"
SAFEDEPS_WATCH_PRE_ANNOUNCE_DAYS=14
SAFEDEPS_WATCH_ADVISORY_PAGES=6

safedeps_watch_runtime_feeds_moved() {
  local moved=""
  [[ -n "${SAFEDEPS_OPENJDK_ADVISORIES_URL:-}" && "${SAFEDEPS_OPENJDK_ADVISORIES_URL}" != "${SAFEDEPS_WATCH_OPENJDK_ADVISORIES_DEFAULT}" ]] \
    && moved="openjdk=${SAFEDEPS_OPENJDK_ADVISORIES_URL}"
  [[ -n "${SAFEDEPS_ADOPTIUM_API_URL:-}" && "${SAFEDEPS_ADOPTIUM_API_URL}" != "${SAFEDEPS_WATCH_ADOPTIUM_API_DEFAULT}" ]] \
    && moved="${moved:+${moved} }adoptium=${SAFEDEPS_ADOPTIUM_API_URL}"
  printf '%s' "${moved}"
}

# JDK release files of this host, one JSON line each:
#   {root:"@host", scope:"jdk", location, source, implementor, runtime_version}
# and locations this stage does not read, as unmeasured rows on fd 3.
safedeps_watch_host_jdks() {
  local f dir class implementor version real seen=" "
  local -a candidates=()
  for f in /Library/Java/JavaVirtualMachines/*/Contents/Home/release; do
    [[ -f "${f}" ]] && candidates+=("system|${f}")
  done
  for f in "${HOME}"/.sdkman/candidates/java/*/release; do
    [[ -f "${f}" ]] || continue
    [[ "${f}" == */current/release ]] && continue
    candidates+=("sdkman|${f}")
  done
  for f in "${candidates[@]+${candidates[@]}}"; do
    dir="${f#*|}"
    dir="${dir%/release}"
    class=$(safedeps_watch_classify_root "${dir}")
    [[ "${class%%$'\t'*}" == "ok" ]] || continue
    real="${class#*$'\t'}"
    [[ "${seen}" == *" ${real} "* ]] && continue
    seen="${seen}${real} "
    implementor=$(sed -n 's/^IMPLEMENTOR="\(.*\)"$/\1/p' "${real}/release" | head -1)
    version=$(sed -n 's/^JAVA_RUNTIME_VERSION="\(.*\)"$/\1/p' "${real}/release" | head -1)
    [[ -n "${version}" ]] || version=$(sed -n 's/^JAVA_VERSION="\(.*\)"$/\1/p' "${real}/release" | head -1)
    jq -nc --arg location "${real}" --arg source "${f%%|*}" --arg implementor "${implementor}" --arg version "${version}" \
      '{root:"@host", scope:"jdk", location:$location, source:$source, implementor:$implementor, runtime_version:$version}'
  done
  for dir in "${HOME}/.asdf/installs/java" "${HOME}/.local/share/mise/installs/java" "${HOME}/.jenv/versions" \
             /opt/homebrew/opt/openjdk /usr/local/opt/openjdk /usr/lib/jvm; do
    if [[ -d "${dir}" ]]; then
      jq -nc --arg path "${dir}" \
        '{kind:"jdk_location_not_scanned", root:"@host", path:$path, reason:"jdk location not scanned"}' >&3
    fi
  done
}

# A pin file of a root, as a JDK row: {root, scope, location, source,
# implementor, runtime_version}, or an unmeasured row on fd 3 when the pin names
# no full version of a vendor this stage reads.
safedeps_watch_pin_jdk() {
  local root="$1" rel="$2" kind="$3" file value vendor="" version=""
  file="${root}/${rel#./}"
  case "${kind}" in
    sdkmanrc) value=$(sed -n 's/^[[:space:]]*java[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "${file}" | head -1) ;;
    java_version) value=$(sed -n '1s/^[[:space:]]*\([^[:space:]#]*\).*/\1/p' "${file}") ;;
    tool_versions) value=$(sed -n 's/^[[:space:]]*java[[:space:]][[:space:]]*\([^[:space:]#]*\).*/\1/p' "${file}" | head -1) ;;
  esac
  [[ -n "${value}" ]] || return 0
  case "${value}" in
    *-tem) vendor="Eclipse Adoptium"; version="${value%-tem}" ;;
    temurin-*) vendor="Eclipse Adoptium"; version="${value#temurin-}"; version="${version%.LTS}" ;;
    adoptopenjdk-*) vendor="Eclipse Adoptium"; version="${value#adoptopenjdk-}" ;;
  esac
  if [[ -z "${vendor}" || ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    jq -nc --arg root "${root}" --arg path "${rel}" --arg pin "${value}" \
      '{kind:"jdk_pin_unrecognized", root:$root, path:$path, reason:("pin names no full version of a read vendor: " + $pin)}' >&3
    return 0
  fi
  jq -nc --arg root "${root}" --arg rel "${rel}" --arg vendor "${vendor}" --arg version "${version}" --arg kind "${kind}" \
    '{root:$root, scope:$rel, location:$rel, source:("pin:" + $kind), implementor:$vendor, runtime_version:$version}'
}

# Fetches the feeds the JDK rows in JDKS need into DIR:
#   openjdk-index.html, openjdk-<date>.txt (newest pages), adoptium-<F>.json
# and writes DIR/feeds.json: {openjdk:{ok, index_url, advisories:[{date,url,affected:[..]}], error},
# adoptium:{"<F>": {ok, latest, error}}}.
safedeps_watch_runtime_feeds() {
  local jdks="$1" dir="$2"
  local index_url adoptium date page text features feature ok=1 http
  index_url="${SAFEDEPS_OPENJDK_ADVISORIES_URL:-${SAFEDEPS_WATCH_OPENJDK_ADVISORIES_DEFAULT}}"
  adoptium="${SAFEDEPS_ADOPTIUM_API_URL:-${SAFEDEPS_WATCH_ADOPTIUM_API_DEFAULT}}"
  : > "${dir}/advisories.jsonl"
  local openjdk_error=""
  http=$(curl -fsS --max-time 20 -o "${dir}/openjdk-index.html" -w '%{http_code}' "${index_url}" 2>/dev/null) || http="${http:-none} exit $?"
  if [[ "${http}" != "200" ]]; then
    openjdk_error="index status ${http}"
  else
    local dates
    dates=$(grep -o 'href="[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}"' "${dir}/openjdk-index.html" | sed 's/href="\(.*\)"/\1/' | sort -ru | head -"${SAFEDEPS_WATCH_ADVISORY_PAGES}")
    if [[ -z "${dates}" ]]; then
      openjdk_error="index lists no advisory"
    fi
    while IFS= read -r date; do
      [[ -n "${date}" && -z "${openjdk_error}" ]] || continue
      page="${index_url%/}/${date}"
      http=$(curl -fsS --max-time 20 -o "${dir}/openjdk-${date}.html" -w '%{http_code}' "${page}" 2>/dev/null) || http="${http:-none} exit $?"
      if [[ "${http}" != "200" ]]; then
        openjdk_error="advisory ${date} status ${http}"
        break
      fi
      text=$(sed -e 's/<[^>]*>/ /g' "${dir}/openjdk-${date}.html" | tr '\n\t' '  ' | tr -s ' ')
      if ! jq -nc --arg date "${date}" --arg url "${page}" --arg text "${text}" '
          ($text | capture("affected versions are (?<v>.*?),? and earlier") | .v) as $v
          | {date:$date, url:$url, affected: ($v | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0)))}' \
          >> "${dir}/advisories.jsonl" 2>/dev/null; then
        openjdk_error="advisory ${date} names no affected versions"
        break
      fi
    done <<< "${dates}"
  fi
  [[ -z "${openjdk_error}" ]] || ok=0

  : > "${dir}/adoptium.jsonl"
  features=$(jq -r 'select(.implementor == "Eclipse Adoptium") | .runtime_version | sub("^1\\.8"; "8") | split(".")[0] | split("+")[0]' "${jdks}" | sort -u)
  while IFS= read -r feature; do
    [[ "${feature}" =~ ^[0-9]+$ ]] || continue
    http=$(curl -fsS --max-time 20 -o "${dir}/adoptium-${feature}.json" -w '%{http_code}' \
      "${adoptium%/}/v3/assets/feature_releases/${feature}/ga?image_type=jdk&vendor=eclipse&page_size=1&sort_order=DESC&sort_method=DATE" 2>/dev/null) \
      || http="${http:-none} exit $?"
    if [[ "${http}" == "200" ]] && jq -ce --arg f "${feature}" '
        select(type == "array" and length > 0 and (.[0].version_data.major | type) == "number")
        | .[0] | {feature: $f, ok: true, release_name, timestamp, release_link, version: .version_data}' \
        "${dir}/adoptium-${feature}.json" >> "${dir}/adoptium.jsonl" 2>/dev/null; then
      :
    else
      jq -nc --arg f "${feature}" --arg error "status ${http}" '{feature:$f, ok:false, error:$error}' >> "${dir}/adoptium.jsonl"
    fi
  done <<< "${features}"

  jq -n -c --arg index_url "${index_url}" --arg error "${openjdk_error}" \
    --slurpfile advisories "${dir}/advisories.jsonl" --slurpfile adoptium "${dir}/adoptium.jsonl" \
    '{openjdk: {ok: ($error == ""), index_url: $index_url, error: (if $error == "" then null else $error end), advisories: $advisories},
      adoptium: ($adoptium | map({key: .feature, value: .}) | from_entries)}' > "${dir}/feeds.json"
}

# jq that judges JDK rows against feeds.json. Prints, per JDK, a runtime row
# {..., state, ...}; the caller turns update_available and pre_announced into
# findings.
# shellcheck disable=SC2016  # jq text
SAFEDEPS_WATCH_RUNTIME_JQ='
def jver: (sub("^1\\.8\\.0_"; "8.0.") | sub("^(?<f>[0-9]+)u(?<u>[0-9]+)$"; "\(.f).0.\(.u)")
           | split("+")[0] | split("-")[0] | split(".") | map(tonumber? // 0)) + [0,0,0,0,0] | .[0:5];
def build_of: (capture("\\+(?<b>[0-9]+)") | .b | tonumber) // 0;
def third_tuesday($y; $m): ("\($y)-\(if $m < 10 then "0" else "" end)\($m)-01T00:00:00Z" | fromdateiso8601 | gmtime) as $t
  | (1 + ((2 - $t[6] + 7) % 7) + 14) as $d
  | "\($y)-\(if $m < 10 then "0" else "" end)\($m)-\(if $d < 10 then "0" else "" end)\($d)";
def next_scheduled($today): ($today[0:4] | tonumber) as $y
  | [($y, $y + 1) as $yy | (1, 4, 7, 10) as $mm | third_tuesday($yy; $mm)] | map(select(. > $today)) | min;
def days_between($a; $b): ((($b + "T00:00:00Z") | fromdateiso8601) - (($a + "T00:00:00Z") | fromdateiso8601)) / 86400;
'

safedeps_watch_runtime_judge() {
  local jdks="$1" feeds="$2" now="$3"
  jq -c --slurpfile feeds "${feeds}" --arg today "${now:0:10}" --argjson window "${SAFEDEPS_WATCH_PRE_ANNOUNCE_DAYS}" \
    "${SAFEDEPS_WATCH_RUNTIME_JQ}"'
    ($feeds[0]) as $f
    | . as $jdk
    | ($jdk.runtime_version | jver) as $cur
    | ($cur[0] | tostring) as $feature
    | if $jdk.implementor != "Eclipse Adoptium" then $jdk + {vendor: $jdk.implementor, state: "vendor_feed_missing"}
      elif ($f.openjdk.ok | not) then $jdk + {vendor: "temurin", state: "feed_unavailable", reason: ("openjdk advisories: " + $f.openjdk.error)}
      elif ($f.adoptium[$feature].ok // false | not) then $jdk + {vendor: "temurin", state: "feed_unavailable", reason: ("adoptium: " + ($f.adoptium[$feature].error // "not asked"))}
      else
        ($f.adoptium[$feature]) as $latest
        | ([$latest.version.major, $latest.version.minor, $latest.version.security, ($latest.version.patch // 0), 0]) as $lv
        | ([$f.openjdk.advisories[] | . as $a
            | ($a.affected | map(select((jver)[0] == $cur[0])) | first) as $bound
            | select($bound != null) | $a + {bound: $bound}] | sort_by(.date) | last) as $adv
        | ($adv != null and ($cur <= ($adv.bound | jver))) as $affected
        | (($f.openjdk.advisories | map(.date) | max) // null) as $newest
        # A pin names no build (21.0.14-tem is whichever 21.0.14 build the vendor
        # ships), so only a version with one is older than a later build.
        | ($lv > $cur or ($lv == $cur and ($jdk.runtime_version | test("\\+[0-9]"))
                          and (($latest.version.build // 0) > ($jdk.runtime_version | build_of)))) as $newer
        | next_scheduled($today) as $next
        | $jdk + {vendor: "temurin",
                  latest: ($latest.version.openjdk_version
                           // "\($latest.version.major).\($latest.version.minor).\($latest.version.security)+\($latest.version.build // 0)"),
                  latest_release: $latest.release_name,
                  latest_date: ($latest.timestamp // "" | .[0:10]), latest_link: $latest.release_link,
                  advisory: $adv, affected: $affected, next_scheduled: $next}
        | if $newer then . + {state: "update_available",
                              advisory_url: (if $affected then $adv.url else $latest.release_link end),
                              advisory_date: (if $affected then $adv.date else ($latest.timestamp // "" | .[0:10]) end)}
          elif $affected then . + {state: "pre_announced", source: $adv.url, date: $adv.date,
                                   reason: "the newest advisory names this version as affected and the vendor has no newer build"}
          elif days_between($today; $next) <= $window then . + {state: "pre_announced", source: $f.openjdk.index_url, date: $next,
                                   reason: "the next scheduled OpenJDK advisory"}
          else . + {state: "current_as_of", advisory_date: ($adv.date // $newest)}
          end
      end' "${jdks}"
}
