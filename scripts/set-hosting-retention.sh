#!/usr/bin/env bash
set -euo pipefail

project=${IYI_PROJECT_ID:?set IYI_PROJECT_ID}
if [[ "$project" != crystalshards-org ]]; then
  echo 'Unexpected project; refusing to update Hosting configuration' >&2
  exit 2
fi

# Only the four owned sites are addressed. A token is passed through stdin,
# not a command-line argument or file. The API mask changes no other setting.
for site in iyi-proxy iyi-sum iyi-newsletter iyi-probe; do
  printf 'header = "Authorization: Bearer %s"\n' "$(gcloud auth print-access-token)" |
    curl --fail --silent --show-error --config - --request PATCH \
      --header "X-Goog-User-Project: $project" --header 'Content-Type: application/json' \
      --data '{"maxVersions":"10"}' \
      "https://firebasehosting.googleapis.com/v1beta1/sites/${site}/config?updateMask=maxVersions" \
      --output /dev/null
  printf 'Set Hosting version retention for %s to 10\n' "$site"
done
