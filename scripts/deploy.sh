#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_REPOSITORY:-}" != iyilang/infra || \
      "${GITHUB_EVENT_NAME:-}" != push || "${GITHUB_REF:-}" != refs/heads/main ]]; then
  echo 'Hosting deployment is restricted to a main-branch push in iyilang/infra.' >&2
  exit 1
fi
project=${IYI_PROJECT_ID:?IYI_PROJECT_ID is required}
images=${TF_VAR_service_images:?TF_VAR_service_images is required}
runner_temp=${RUNNER_TEMP:?RUNNER_TEMP is required}
if [[ "$project" != iyi-lang ]]; then
  echo 'Unexpected project; refusing Hosting deployment.' >&2
  exit 1
fi
if ! jq -e 'type == "object" and all(.[]; type == "string")' <<<"$images" >/dev/null 2>&1; then
  echo 'Service images must be an object of service names to image strings.' >&2
  exit 1
fi

firebase=(npx --yes firebase-tools@15.36.0)
sites="$runner_temp/iyi-hosting-sites.json"
if ! "${firebase[@]}" hosting:sites:list --project "$project" --config probe/firebase.json --non-interactive --json >"$sites" 2>"$runner_temp/iyi-hosting-sites-error.log"; then
  echo 'Cannot list Firebase Hosting sites. Check bootstrap and deployer access.' >&2
  exit 1
fi

check_site() {
  local site=$1 config=$2
  if ! jq -e --arg site "$site" '
    .status == "success" and (.result.sites | type == "array") and
    any(.result.sites[]; (.name | split("/") | last) == $site)
  ' "$sites" >/dev/null; then
    printf 'Hosting site %s is absent or could not be verified. Apply Terraform first.\n' "$site" >&2
    return 1
  fi
  if ! jq -e --arg site "$site" '
    .hosting as $hosting |
    ($hosting | type == "object") and $hosting.site == $site and
    ($hosting | has("target") | not) and
    all(["/", "**"][]; . as $source |
      any($hosting.headers[]?;
        .source == $source and
        any(.headers[]?; (.key | ascii_downcase) == "x-robots-tag" and
          (.value | ascii_downcase | contains("noindex")))))
  ' "$config" >/dev/null; then
    printf 'Hosting config for %s must name that site and preserve its noindex headers.\n' "$site" >&2
    return 1
  fi
}

deploy_site() {
  local site=$1 config=$2
  check_site "$site" "$config"
  "${firebase[@]}" deploy --only hosting --project "$project" --config "$config" --non-interactive
}

for service in iyi-probe-public iyi-probe-internal; do
  if ! gcloud run services describe "$service" --project "$project" --region us-central1 --format='value(metadata.name)' >"$runner_temp/iyi-$service.log" 2>&1; then
    printf 'Cloud Run service %s is unavailable. Apply Terraform before deploying Hosting.\n' "$service" >&2
    exit 1
  fi
done
deploy_site iyi-probe probe/firebase.json

if jq -e '."iyi-proxy" | strings | test("[^[:space:]]")' <<<"$images" >/dev/null; then
  deploy_site iyi-proxy hosting/proxy.firebase.json
fi
if jq -e '."iyi-sum" | strings | test("[^[:space:]]")' <<<"$images" >/dev/null; then
  deploy_site iyi-sum hosting/sum.firebase.json
fi
