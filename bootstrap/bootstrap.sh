#!/usr/bin/env bash
# The billing account is accepted only in memory; never trace its expansion.
set +x
set -euo pipefail

# One human-run trust bootstrap. Terraform plans and applies run only in CI.
PROJECT=iyi-lang
PROJECT_NUMBER=477913052471
REGION=us-central1
REPOSITORY=iyilang/infra
POOL=iyi-github
PROVIDER=github
STATE_BUCKET=iyi-lang-tfstate
PROXY_BUCKET=iyi-iyi-lang-proxy-objects
SUM_BUCKET=iyi-iyi-lang-sum-staging-objects
SECRET=iyi-sum-staging-signing-key
REGISTRY=iyi
BUDGET_NAME='iyi-lang monthly alert'
OWNER_LABELS='stack=iyi,managed_by=iyi_infra'
OWNER_MARKER='managed-by: iyilang/infra bootstrap'
DEPLOYER="iyi-deployer@${PROJECT}.iam.gserviceaccount.com"
DEPLOYER_MEMBER="serviceAccount:${DEPLOYER}"
PRINCIPAL_ROOT="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repo_event/${REPOSITORY}"
PUSH_MEMBER="${PRINCIPAL_ROOT}:push"
PR_MEMBER="${PRINCIPAL_ROOT}:pull_request"
PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
CONDITION="assertion.repository == 'iyilang/infra' && assertion.repository_id == '1461001280' && assertion.repository_owner_id == '327116875' && (assertion.event_name == 'pull_request' || (assertion.event_name == 'push' && assertion.ref == 'refs/heads/main')) && assertion.workflow_ref.startsWith('iyilang/infra/.github/workflows/terraform.yml@')"
MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repo_event=assertion.repository + ':' + assertion.event_name"
APPLY_ROLE=iyiTerraformApply
PLAN_ROLE=iyiTerraformPlanRead
BUCKET_READ_ROLE=iyiTerraformBucketRead
REGISTRY_READ_ROLE=iyiTerraformRegistryRead
SECRET_READ_ROLE=iyiTerraformSecretRead
RUN_POLICY_ROLE=iyiRunSetIamPolicy
APPLY_PERMISSIONS='resourcemanager.projects.get,iam.serviceAccounts.get,serviceusage.services.use,serviceusage.services.get,serviceusage.services.list,serviceusage.services.enable,serviceusage.operations.get,run.services.create,run.services.get,run.services.list,run.services.update,run.services.getIamPolicy,run.jobs.create,run.jobs.get,run.jobs.list,run.jobs.update,run.operations.get,logging.exclusions.create,logging.exclusions.get,logging.exclusions.list,logging.exclusions.update'
PLAN_PERMISSIONS='resourcemanager.projects.get,iam.serviceAccounts.get,serviceusage.services.use,serviceusage.services.get,serviceusage.services.list,serviceusage.operations.get,run.services.get,run.services.list,run.services.getIamPolicy,run.jobs.get,run.jobs.list,run.operations.get,logging.exclusions.get,logging.exclusions.list'
RUNTIME_ACCOUNTS=(iyi-proxy iyi-sum-reader iyi-sum-sequencer iyi-ingest iyi-probe)
APIS=(iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com storage.googleapis.com billingbudgets.googleapis.com)
MODE=check
MODE_SET=0
BILLING_ACCOUNT="${IYI_BILLING_ACCOUNT:-}"
STATUS=0
PRESENT=0
CREATED=0
DESCRIPTION=

usage() {
  printf '%s\n' 'Usage: bootstrap.sh [--check | --dry-run | --apply] [--billing-account ACCOUNT]' \
    'Default --check is read-only; --dry-run is offline; --apply requires an approved human and gcloud CLI login.' \
    'For --check and --apply, supply the billing account through IYI_BILLING_ACCOUNT or --billing-account.'
}

while (($#)); do
  case "$1" in
    --check|--dry-run|--apply)
      if ((MODE_SET)); then usage >&2; exit 2; fi
      MODE=${1#--}
      MODE_SET=1
      ;;
    --billing-account)
      if (($# < 2)); then usage >&2; exit 2; fi
      BILLING_ACCOUNT=$2
      shift
      ;;
    --billing-account=*) BILLING_ACCOUNT=${1#--billing-account=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$MODE" != dry-run ]]; then
  BILLING_ACCOUNT=${BILLING_ACCOUNT#billingAccounts/}
  if [[ ! "$BILLING_ACCOUNT" =~ ^[[:alnum:]]{6}-[[:alnum:]]{6}-[[:alnum:]]{6}$ ]]; then
    echo 'Supply a valid billing account via IYI_BILLING_ACCOUNT or --billing-account; its value will not be printed.' >&2
    exit 2
  fi
fi

print_command() {
  printf '  +'
  printf ' %q' "$@"
  printf '\n'
}

mutate() {
  if [[ "$MODE" == dry-run ]]; then print_command "$@" --quiet; else "$@" --quiet; fi
}

drift() {
  printf 'DRIFT: %s\n' "$*" >&2
  if [[ "$MODE" == apply ]]; then exit 1; fi
  STATUS=1
}

# Only explicit not-found errors are absence. A 403 or ambiguous error is not.
describe() {
  local label=$1
  shift
  if DESCRIPTION=$("$@" 2>&1); then
    printf '%s: PRESENT\n' "$label"
    return 0
  fi
  if printf '%s\n' "$DESCRIPTION" | grep -Eiq 'PERMISSION_DENIED|permission|forbidden|unauthori[sz]ed|credential|authentication|access.denied|(^|[^0-9])403([^0-9]|$)'; then
    printf '%s: UNREADABLE (authorization or authentication error): %s\n' "$label" "$DESCRIPTION" >&2
    return 2
  fi
  if printf '%s\n' "$DESCRIPTION" | grep -Eiq 'NOT_FOUND|not found|does not exist|(^|[^0-9])404([^0-9]|$)'; then
    printf '%s: ABSENT\n' "$label"
    return 1
  fi
  printf '%s: UNREADABLE: %s\n' "$label" "$DESCRIPTION" >&2
  return 2
}

# Arguments are LABEL DESCRIBE... -- CREATE.... Existing resources are never
# silently overwritten. Type-specific checks below reject incompatible objects.
ensure_resource() {
  local label=$1 rc
  local -a read_command=() create_command=()
  shift
  while [[ "$1" != -- ]]; do read_command+=("$1"); shift; done
  shift
  create_command=("$@")
  PRESENT=0
  CREATED=0
  if [[ "$MODE" == dry-run ]]; then
    printf 'If %s is absent:\n' "$label"
    mutate "${create_command[@]}"
    PRESENT=1
    CREATED=1
  elif describe "$label" "${read_command[@]}"; then
    PRESENT=1
  else
    rc=$?
    ((rc == 1)) || exit "$rc"
    if [[ "$MODE" == apply ]]; then
      mutate "${create_command[@]}"
      PRESENT=1
      CREATED=1
    else
      STATUS=1
    fi
  fi
}

ensure_bucket() {
  local name=$1 valid
  ensure_resource "bucket gs://${name}" \
    gcloud storage buckets describe "gs://${name}" --project="$PROJECT" --raw --format=json -- \
    gcloud storage buckets create "gs://${name}" --project="$PROJECT" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention --labels="$OWNER_LABELS"
  ((PRESENT)) || return 0
  if [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
    if ! jq -e --arg project "$PROJECT_NUMBER" --arg region "$REGION" \
      '(.projectNumber | tostring) == $project and (.location | ascii_downcase) == $region and
       .labels.stack == "iyi" and .labels.managed_by == "iyi_infra"' \
      <<<"$DESCRIPTION" >/dev/null; then
      drift "gs://${name} has the wrong project, region, or ownership labels; refusing adoption"
      PRESENT=0
      return 0
    fi
    valid=$(jq -r '(.iamConfiguration.uniformBucketLevelAccess.enabled == true) and
      (.iamConfiguration.publicAccessPrevention == "enforced") and (.versioning.enabled == true)' <<<"$DESCRIPTION")
    if [[ "$valid" == true ]]; then return 0; fi
    if [[ "$MODE" == check ]]; then drift "gs://${name} must use uniform access, public access prevention, and versioning"; return 0; fi
  fi
  printf 'If gs://%s was created or its protections need repair:\n' "$name"
  mutate gcloud storage buckets update "gs://${name}" --project="$PROJECT" \
    --uniform-bucket-level-access --public-access-prevention --versioning
}

ensure_registry_cleanup() {
  local policies policy_file
  policies='[{"name":"retain-recent-images","action":{"type":"Keep"},"mostRecentVersions":{"keepCount":5}},{"name":"remove-older-images","action":{"type":"Delete"},"condition":{"tagState":"any","olderThan":"30d"}}]'
  if [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
    if jq -e '
      (.cleanupPolicies // {}) as $p |
      (($p | keys | sort) == ["remove-older-images", "retain-recent-images"]) and
      ($p["retain-recent-images"].action == "KEEP") and
      ($p["retain-recent-images"].mostRecentVersions.keepCount == 5) and
      (($p["retain-recent-images"].mostRecentVersions.packageNamePrefixes // []) | length == 0) and
      ($p["remove-older-images"].action == "DELETE") and
      ($p["remove-older-images"].condition.olderThan == "2592000s") and
      (($p["remove-older-images"].condition.tagState // "ANY") == "ANY") and
      (($p["remove-older-images"].condition.tagPrefixes // []) | length == 0) and
      (($p["remove-older-images"].condition.versionNamePrefixes // []) | length == 0) and
      (($p["remove-older-images"].condition.packageNamePrefixes // []) | length == 0) and
      (($p["remove-older-images"].condition.newerThan // "") == "")
    ' <<<"$DESCRIPTION" >/dev/null; then
      if jq -e '.cleanupPolicyDryRun != true' <<<"$DESCRIPTION" >/dev/null; then
        echo 'Artifact Registry cleanup policies: PRESENT'
        return 0
      fi
    elif jq -e '(.cleanupPolicies // {}) | length > 0' <<<"$DESCRIPTION" >/dev/null; then
      drift 'Artifact Registry cleanup policies differ; refusing to replace existing policies'
      return 0
    fi
    if [[ "$MODE" == check ]]; then
      drift 'Artifact Registry cleanup policies are absent or in dry-run mode'
      return 0
    fi
  fi
  echo 'If registry cleanup policies are absent or disabled, configure the following JSON:'
  printf '%s\n' "$policies"
  if [[ "$MODE" == dry-run ]]; then
    printf '%s\n' "  policy_file=\$(mktemp \"\${TMPDIR:-/tmp}/iyi-cleanup.XXXXXXXX\")"
    printf "  printf %%s %q > \"\$policy_file\"\n" "$policies"
    printf "  gcloud artifacts repositories set-cleanup-policies %q --project=%q --location=%q --policy=\"\$policy_file\" --no-dry-run --quiet\n" "$REGISTRY" "$PROJECT" "$REGION"
    printf '%s\n' "  rm -f -- \"\$policy_file\""
  else
    policy_file=$(mktemp "${TMPDIR:-/tmp}/iyi-cleanup.XXXXXXXX")
    trap 'rm -f -- "$policy_file"' EXIT
    printf '%s' "$policies" > "$policy_file"
    mutate gcloud artifacts repositories set-cleanup-policies "$REGISTRY" \
      --project="$PROJECT" --location="$REGION" --policy="$policy_file" --no-dry-run
    rm -f -- "$policy_file"
    trap - EXIT
  fi
}

ensure_role() {
  local name=$1 permissions=$2
  ensure_resource "custom role ${name}" \
    gcloud iam roles describe "$name" --project="$PROJECT" --format=json -- \
    gcloud iam roles create "$name" --project="$PROJECT" --title="$name" \
      --stage=GA --permissions="$permissions" --description="$OWNER_MARKER"
  ((PRESENT)) || return 0
  if [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
    if ! jq -e --arg permissions "$permissions" --arg marker "$OWNER_MARKER" \
      '(.deleted != true) and (.stage == "GA") and (.description == $marker) and
       ((.includedPermissions | sort) == ($permissions | split(",") | sort))' \
      <<<"$DESCRIPTION" >/dev/null; then
      drift "custom role ${name} has different permissions or no ownership marker; refusing adoption"
    fi
  fi
}

# Read the current policy and add exactly the missing unconditional member.
# No existing policy or third-party member is removed.
ensure_binding() {
  local label=$1 member=$2 role=$3 policy
  local -a read_command=() add_command=()
  shift 3
  while [[ "$1" != -- ]]; do read_command+=("$1"); shift; done
  shift
  add_command=("$@")
  if [[ "$MODE" == dry-run ]]; then
    printf 'If binding is absent on %s:\n' "$label"
    mutate "${add_command[@]}" --member="$member" --role="$role"
    return 0
  fi
  if ! policy=$("${read_command[@]}" 2>&1); then
    printf 'UNREADABLE IAM policy on %s: %s\n' "$label" "$policy" >&2
    exit 1
  fi
  if jq -e --arg member "$member" --arg role "$role" \
    '[.bindings[]? | select(.role == $role and .condition == null) | .members[]?] | index($member) != null' \
    <<<"$policy" >/dev/null; then
    printf 'Binding %s on %s for %s: PRESENT\n' "$role" "$label" "$member"
  elif [[ "$MODE" == apply ]]; then
    mutate "${add_command[@]}" --member="$member" --role="$role"
  else
    printf 'Binding %s on %s for %s: ABSENT\n' "$role" "$label" "$member"
    STATUS=1
  fi
}

project_binding() {
  local member=$1 role=$2
  ensure_binding "project ${PROJECT}" "$member" "$role" \
    gcloud projects get-iam-policy "$PROJECT" --format=json -- \
    gcloud projects add-iam-policy-binding "$PROJECT" --condition=None
}

account_binding() {
  local account=$1 member=$2 role=$3
  ensure_binding "service account ${account}" "$member" "$role" \
    gcloud iam service-accounts get-iam-policy "$account" --project="$PROJECT" --format=json -- \
    gcloud iam service-accounts add-iam-policy-binding "$account" --project="$PROJECT" --condition=None
}

bucket_binding() {
  local bucket=$1 member=$2 role=$3
  ensure_binding "bucket gs://${bucket}" "$member" "$role" \
    gcloud storage buckets get-iam-policy "gs://${bucket}" --project="$PROJECT" --format=json -- \
    gcloud storage buckets add-iam-policy-binding "gs://${bucket}" --project="$PROJECT"
}

registry_binding() {
  local member=$1 role=$2
  ensure_binding "registry ${REGISTRY}" "$member" "$role" \
    gcloud artifacts repositories get-iam-policy "$REGISTRY" --project="$PROJECT" --location="$REGION" --format=json -- \
    gcloud artifacts repositories add-iam-policy-binding "$REGISTRY" --project="$PROJECT" --location="$REGION"
}

secret_binding() {
  local member=$1 role=$2
  ensure_binding "secret ${SECRET}" "$member" "$role" \
    gcloud secrets get-iam-policy "$SECRET" --project="$PROJECT" --format=json -- \
    gcloud secrets add-iam-policy-binding "$SECRET" --project="$PROJECT"
}

ensure_budget() {
  local result
  echo 'Human review only, not run: update a verified budget ID after inspecting all mismatched settings.'
  printf '%s\n' "CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true gcloud billing budgets update \"\${BUDGET_ID}\" --billing-account=\"\${IYI_BILLING_ACCOUNT}\" --billing-project=iyi-lang --budget-amount=200USD --calendar-period=month --filter-projects=projects/477913052471 --quiet >/dev/null 2>&1"
  echo 'Threshold mismatches require the console or a separately reviewed --threshold-rules-from-file update.'
  echo 'The template does not clear other filters, Pub/Sub, spend caps, extra recipients, or re-enable disabled default recipients.'
  if [[ "$MODE" == dry-run ]]; then
    echo 'If the single-project budget is absent and no same-name budget exists:'
    printf '%s\n' "CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true gcloud billing budgets create --billing-account=\"\${IYI_BILLING_ACCOUNT}\" --billing-project=iyi-lang --display-name=\"iyi-lang monthly alert\" --budget-amount=200USD --calendar-period=month --filter-projects=projects/477913052471 --threshold-rule=percent=0.5,basis=current-spend --threshold-rule=percent=0.9,basis=current-spend --threshold-rule=percent=1.0,basis=current-spend --quiet >/dev/null 2>&1"
    echo 'Duplicate or incompatible same-name budgets stop bootstrap; none are updated or deleted automatically.'
    return 0
  fi
  if [[ "$MODE" == check ]] && ! printf '%s\n' "$enabled" | grep -Fxq billingbudgets.googleapis.com; then
    echo 'Budget: UNCHECKED (Billing Budget API is disabled)'
    return 0
  fi
  # gcloud's result is piped directly to jq; only fixed field names and status
  # leave the pipe. Never print its output or stderr, which can contain the ID.
  if ! result=$(gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
    --billing-project="$PROJECT" --format=json --quiet 2>/dev/null |
    jq -er --arg name "$BUDGET_NAME" --arg project "projects/${PROJECT_NUMBER}" '
      [.[] | select(.displayName == $name)] as $matches |
      if ($matches | length) == 0 then "ABSENT"
      elif ($matches | length) > 1 then "DUPLICATE"
      else
        $matches[0] |
        [
          (if (.budgetFilter.projects // []) == [$project] then empty else "project scope" end),
          (if ((.budgetFilter.calendarPeriod // "MONTH") == "MONTH") and (.budgetFilter.customPeriod == null)
            then empty else "calendar period" end),
          (if ((.budgetFilter.resourceAncestors // []) | length == 0) and
              ((.budgetFilter.services // []) | length == 0) and
              ((.budgetFilter.subaccounts // []) | length == 0) and
              ((.budgetFilter.labels // {}) | length == 0) and
              ((.budgetFilter.creditTypes // []) | length == 0) and
              ((.budgetFilter.creditTypesTreatment // "INCLUDE_ALL_CREDITS") == "INCLUDE_ALL_CREDITS" or
               .budgetFilter.creditTypesTreatment == "CREDIT_TYPES_TREATMENT_UNSPECIFIED")
            then empty else "additional filters" end),
          (if .amount.specifiedAmount.currencyCode == "USD" and
              ((.amount.specifiedAmount.units | tostring) == "200") and
              ((.amount.specifiedAmount.nanos // 0) == 0) and .amount.lastPeriodAmount == null
            then empty else "amount" end),
          (if ([.thresholdRules[]? | {percent: .thresholdPercent,
                basis: (if (.spendBasis // "BASIS_UNSPECIFIED") == "BASIS_UNSPECIFIED"
                        then "CURRENT_SPEND" else .spendBasis end)}] | sort_by(.percent)) ==
              [{"percent": 0.5, "basis": "CURRENT_SPEND"},
               {"percent": 0.9, "basis": "CURRENT_SPEND"},
               {"percent": 1, "basis": "CURRENT_SPEND"}]
            then empty else "threshold rules" end),
          (if all([.notificationsRule // {}, .allUpdatesRule // {}][];
                (.pubsubTopic // "") == "" and
                ((.monitoringNotificationChannels // []) | length == 0) and
                .disableDefaultIamRecipients != true and .enableProjectLevelRecipients != true)
            then empty else "notification recipients or Pub/Sub" end),
          (if .spendCap == null then empty else "spend cap" end)
        ] as $mismatches |
        if ($mismatches | length) == 0 then "PRESENT"
        else "DRIFT: " + ($mismatches | join(", ")) end
      end' 2>/dev/null); then
    echo 'Budget: UNREADABLE. Check the human CLI login, billing-account budget-list access, and quota project; the account is withheld.' >&2
    exit 1
  fi
  case "$result" in
    PRESENT) echo 'Budget: PRESENT and compatible' ;;
    DUPLICATE) drift 'budget has multiple same-name matches; refusing adoption' ;;
    DRIFT:*) drift "budget has mismatched fields: ${result#DRIFT: }; refusing adoption" ;;
    ABSENT)
      if [[ "$MODE" == check ]]; then
        echo 'Budget: ABSENT'
        STATUS=1
      elif ! gcloud billing budgets create --billing-account="$BILLING_ACCOUNT" --billing-project="$PROJECT" \
        --display-name="$BUDGET_NAME" --budget-amount=200USD --calendar-period=month \
        --filter-projects="projects/${PROJECT_NUMBER}" --threshold-rule=percent=0.5,basis=current-spend \
        --threshold-rule=percent=0.9,basis=current-spend --threshold-rule=percent=1.0,basis=current-spend \
        --quiet >/dev/null 2>&1; then
        echo 'Budget: CREATE FAILED. Check human budget-create access and the account currency; the account is withheld.' >&2
        exit 1
      else
        echo 'Budget: CREATED'
      fi
      ;;
    *) echo 'Budget: UNREADABLE (unexpected sanitized result)' >&2; exit 1 ;;
  esac
}

if [[ "$MODE" != dry-run ]]; then
  for executable in gcloud jq grep; do
    command -v "$executable" >/dev/null || { printf 'Missing command: %s\n' "$executable" >&2; exit 1; }
  done
  if [[ "$MODE" == apply && ( ! -t 0 || ! -t 1 || -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ) ]]; then
    echo 'Refusing --apply outside an interactive human session; it must never run in CI.' >&2
    exit 1
  fi
  for name in GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
    CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
    CLOUDSDK_AUTH_DISABLE_CREDENTIALS CLOUDSDK_CORE_ACCOUNT; do
    if [[ -n "${!name:-}" ]]; then
      printf 'Refusing credential or account override %s; use the active human gcloud CLI login.\n' "$name" >&2
      exit 1
    fi
  done
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  export CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true
  config=$(gcloud config list --format=json --quiet)
  if jq -e '(.auth.credential_file_override // "") != "" or
    (.auth.impersonate_service_account // "") != "" or (.auth.access_token_file // "") != ""' \
    <<<"$config" >/dev/null; then
    echo 'Refusing configured gcloud credential-file, token-file, or service-account impersonation override.' >&2
    exit 1
  fi
  active_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' --quiet)
  if [[ -z "$active_account" || "$active_account" == *gserviceaccount.com* ]]; then
    echo 'No active human gcloud CLI login. Run gcloud auth login interactively, then retry; ADC is not used.' >&2
    exit 1
  fi
  if ! gcloud auth print-access-token --quiet >/dev/null 2>&1; then
    echo 'The active gcloud CLI login is expired or cannot refresh. Run gcloud auth login interactively, then retry; ADC is not used.' >&2
    exit 1
  fi
  actual_number=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' --quiet)
  if [[ "$actual_number" != "$PROJECT_NUMBER" ]]; then
    printf 'Project number mismatch: expected %s, received %s; refusing to proceed.\n' "$PROJECT_NUMBER" "$actual_number" >&2
    exit 1
  fi
  enabled=$(gcloud services list --enabled --project="$PROJECT" --format='value(config.name)' --quiet)
fi

for api in "${APIS[@]}"; do
  if [[ "$MODE" == dry-run ]]; then
    printf 'If API %s is disabled:\n' "$api"
    mutate gcloud services enable "$api" --project="$PROJECT"
  elif printf '%s\n' "$enabled" | grep -Fxq "$api"; then
    printf 'API %s: ENABLED\n' "$api"
  elif [[ "$MODE" == apply ]]; then
    mutate gcloud services enable "$api" --project="$PROJECT"
  else
    printf 'API %s: DISABLED\n' "$api"
    STATUS=1
  fi
done

ensure_budget

ensure_resource "workload identity pool ${POOL}" \
  gcloud iam workload-identity-pools describe "$POOL" --location=global --project="$PROJECT" --format=json -- \
  gcloud iam workload-identity-pools create "$POOL" --location=global --project="$PROJECT" \
    --display-name="$POOL" --description="$OWNER_MARKER"
pool_present=$PRESENT
if ((pool_present)) && [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
  jq -e --arg marker "$OWNER_MARKER" '.disabled != true and .state == "ACTIVE" and .description == $marker' \
    <<<"$DESCRIPTION" >/dev/null || drift "workload identity pool is inactive or lacks its ownership marker"
fi

if ((pool_present)); then
  if [[ "$MODE" == dry-run ]]; then
    printf 'Precondition: pool %s in project %s must contain no active provider except %s; other providers are never deleted.\n' "$POOL" "$PROJECT" "$PROVIDER"
  else
    if ! providers=$(gcloud iam workload-identity-pools providers list --workload-identity-pool="$POOL" \
      --location=global --project="$PROJECT" --format=json --quiet 2>&1); then
      printf 'UNREADABLE workload identity providers in %s: %s\n' "$POOL" "$providers" >&2
      exit 1
    fi
    if ! jq -e --arg provider "$PROVIDER_NAME" \
      'all(.[]; .disabled == true or .state == "DELETED" or (.state == "ACTIVE" and .name == $provider))' \
      <<<"$providers" >/dev/null; then
      drift "pool ${POOL} contains another active or unknown-state provider; refusing to delete it or grant access"
    fi
  fi
fi

provider_present=0
if ((pool_present)); then
  ensure_resource "workload identity provider ${POOL}/${PROVIDER}" \
    gcloud iam workload-identity-pools providers describe "$PROVIDER" --workload-identity-pool="$POOL" --location=global --project="$PROJECT" --format=json -- \
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --workload-identity-pool="$POOL" \
      --location=global --project="$PROJECT" --issuer-uri='https://token.actions.githubusercontent.com' \
      --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION" --display-name='iyi GitHub Actions' \
      --description="$OWNER_MARKER"
  provider_present=$PRESENT
  if ((provider_present)) && [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
    if ! jq -e --arg condition "$CONDITION" --arg marker "$OWNER_MARKER" \
      '.disabled != true and .state == "ACTIVE" and .description == $marker and .oidc.issuerUri == "https://token.actions.githubusercontent.com" and
       .attributeCondition == $condition and .attributeMapping == {
         "google.subject": "assertion.sub",
         "attribute.repository": "assertion.repository",
         "attribute.repo_event": "assertion.repository + \u0027:\u0027 + assertion.event_name"
       }' <<<"$DESCRIPTION" >/dev/null; then
      drift 'workload identity provider ownership, issuer, condition, mapping, or state differs; refusing adoption'
    fi
  fi
fi

ensure_resource "service account ${DEPLOYER}" \
  gcloud iam service-accounts describe "$DEPLOYER" --project="$PROJECT" --format=json -- \
  gcloud iam service-accounts create iyi-deployer --project="$PROJECT" --display-name=iyi-deployer \
    --description="$OWNER_MARKER"
deployer_present=$PRESENT
if ((deployer_present)); then
  if [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
    jq -e --arg marker "$OWNER_MARKER" '.disabled != true and .description == $marker' \
      <<<"$DESCRIPTION" >/dev/null || drift "service account ${DEPLOYER} is disabled or lacks its ownership marker"
  fi
  if [[ "$MODE" == dry-run ]]; then
    echo 'Existing workloadIdentityUser bindings on the deployer must contain only the push principal, unconditionally.'
  else
    policy=$(gcloud iam service-accounts get-iam-policy "$DEPLOYER" --project="$PROJECT" --format=json --quiet)
    if ! jq -e --arg member "$PUSH_MEMBER" \
      'all(.bindings[]? | select(.role == "roles/iam.workloadIdentityUser" or (.role | startswith("roles/iam.workloadIdentityUser_withcond_")));
        .role == "roles/iam.workloadIdentityUser" and .condition == null and all(.members[]?; . == $member))' \
      <<<"$policy" >/dev/null; then
      drift 'deployer has another or conditional workloadIdentityUser binding; refusing to remove or widen it'
    fi
  fi
  account_binding "$DEPLOYER" "$PUSH_MEMBER" roles/iam.workloadIdentityUser
fi
for name in "${RUNTIME_ACCOUNTS[@]}"; do
  email="${name}@${PROJECT}.iam.gserviceaccount.com"
  ensure_resource "service account ${email}" \
    gcloud iam service-accounts describe "$email" --project="$PROJECT" --format=json -- \
    gcloud iam service-accounts create "$name" --project="$PROJECT" --display-name="$name" \
      --description="$OWNER_MARKER"
  if ((PRESENT)) && [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
    jq -e --arg marker "$OWNER_MARKER" '.disabled != true and .description == $marker' \
      <<<"$DESCRIPTION" >/dev/null || drift "service account ${email} is disabled or lacks its ownership marker"
  fi
  if ((PRESENT && deployer_present)); then
    account_binding "$email" "$DEPLOYER_MEMBER" roles/iam.serviceAccountUser
  fi
done

ensure_bucket "$STATE_BUCKET"; state_present=$PRESENT
ensure_bucket "$PROXY_BUCKET"; proxy_present=$PRESENT
ensure_bucket "$SUM_BUCKET"; sum_present=$PRESENT
ensure_resource "Artifact Registry repository ${REGISTRY}" \
  gcloud artifacts repositories describe "$REGISTRY" --project="$PROJECT" --location="$REGION" --format=json -- \
  gcloud artifacts repositories create "$REGISTRY" --project="$PROJECT" --location="$REGION" \
    --repository-format=docker --description='iyi package stack container images' --labels="$OWNER_LABELS"
registry_present=$PRESENT
if ((registry_present)) && [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
  if ! jq -e '.format == "DOCKER" and .labels.stack == "iyi" and .labels.managed_by == "iyi_infra"' \
    <<<"$DESCRIPTION" >/dev/null; then
    drift 'Artifact Registry repository has the wrong format or ownership labels; refusing adoption'
    registry_present=0
  fi
fi
if ((registry_present)); then ensure_registry_cleanup; fi
ensure_resource "staging secret ${SECRET}" \
  gcloud secrets describe "$SECRET" --project="$PROJECT" --format=json -- \
  gcloud secrets create "$SECRET" --project="$PROJECT" --replication-policy=automatic --labels="$OWNER_LABELS"
secret_present=$PRESENT
if ((secret_present)) && [[ "$MODE" != dry-run && "$CREATED" == 0 ]]; then
  if ! jq -e '.labels.stack == "iyi" and .labels.managed_by == "iyi_infra"' <<<"$DESCRIPTION" >/dev/null; then
    drift "staging secret ${SECRET} lacks the ownership labels; refusing adoption"
    secret_present=0
  fi
fi

ensure_role "$APPLY_ROLE" "$APPLY_PERMISSIONS"
ensure_role "$PLAN_ROLE" "$PLAN_PERMISSIONS"
ensure_role "$BUCKET_READ_ROLE" 'storage.buckets.get'
ensure_role "$REGISTRY_READ_ROLE" 'artifactregistry.repositories.get'
ensure_role "$SECRET_READ_ROLE" 'secretmanager.secrets.get'
ensure_role "$RUN_POLICY_ROLE" 'run.services.setIamPolicy'

# Firebase Hosting does not support custom roles. These predefined roles have
# project-wide scope. Admin can delete every site, including the default site.
project_binding "$DEPLOYER_MEMBER" "projects/${PROJECT}/roles/${APPLY_ROLE}"
project_binding "$DEPLOYER_MEMBER" "projects/${PROJECT}/roles/${RUN_POLICY_ROLE}"
project_binding "$DEPLOYER_MEMBER" roles/firebasehosting.admin
project_binding "$PR_MEMBER" "projects/${PROJECT}/roles/${PLAN_ROLE}"
project_binding "$PR_MEMBER" roles/firebasehosting.viewer


if ((state_present)); then
  bucket_binding "$STATE_BUCKET" "$DEPLOYER_MEMBER" roles/storage.objectAdmin
  bucket_binding "$STATE_BUCKET" "$PR_MEMBER" roles/storage.objectViewer
fi
if ((proxy_present)); then
  bucket_binding "$PROXY_BUCKET" "$DEPLOYER_MEMBER" "projects/${PROJECT}/roles/${BUCKET_READ_ROLE}"
  bucket_binding "$PROXY_BUCKET" "$PR_MEMBER" "projects/${PROJECT}/roles/${BUCKET_READ_ROLE}"
  bucket_binding "$PROXY_BUCKET" "serviceAccount:iyi-proxy@${PROJECT}.iam.gserviceaccount.com" roles/storage.objectViewer
  bucket_binding "$PROXY_BUCKET" "serviceAccount:iyi-ingest@${PROJECT}.iam.gserviceaccount.com" roles/storage.objectCreator
fi
if ((sum_present)); then
  bucket_binding "$SUM_BUCKET" "$DEPLOYER_MEMBER" "projects/${PROJECT}/roles/${BUCKET_READ_ROLE}"
  bucket_binding "$SUM_BUCKET" "$PR_MEMBER" "projects/${PROJECT}/roles/${BUCKET_READ_ROLE}"
  bucket_binding "$SUM_BUCKET" "serviceAccount:iyi-sum-reader@${PROJECT}.iam.gserviceaccount.com" roles/storage.objectViewer
  bucket_binding "$SUM_BUCKET" "serviceAccount:iyi-sum-sequencer@${PROJECT}.iam.gserviceaccount.com" roles/storage.objectViewer
  bucket_binding "$SUM_BUCKET" "serviceAccount:iyi-sum-sequencer@${PROJECT}.iam.gserviceaccount.com" roles/storage.objectCreator
fi
if ((registry_present)); then
  registry_binding "$DEPLOYER_MEMBER" roles/artifactregistry.writer
  registry_binding "$PR_MEMBER" "projects/${PROJECT}/roles/${REGISTRY_READ_ROLE}"
  for name in "${RUNTIME_ACCOUNTS[@]}"; do
    registry_binding "serviceAccount:${name}@${PROJECT}.iam.gserviceaccount.com" roles/artifactregistry.reader
  done
fi
if ((secret_present)); then
  secret_binding "$DEPLOYER_MEMBER" roles/secretmanager.secretVersionAdder
  secret_binding "$DEPLOYER_MEMBER" roles/secretmanager.viewer
  secret_binding "$PR_MEMBER" "projects/${PROJECT}/roles/${SECRET_READ_ROLE}"
  secret_binding "serviceAccount:iyi-sum-sequencer@${PROJECT}.iam.gserviceaccount.com" roles/secretmanager.secretAccessor
fi

cat <<EOF
Repository variables (commands are not run by this script):
gh variable set IYI_PROJECT_ID --repo ${REPOSITORY} --body ${PROJECT}
gh variable set IYI_WIF_PROVIDER --repo ${REPOSITORY} --body ${PROVIDER_NAME}
gh variable set IYI_DEPLOYER_SERVICE_ACCOUNT --repo ${REPOSITORY} --body ${DEPLOYER}
The billing account is supplied only to the human bootstrap, never to the CI plan or apply jobs.

The PR principal is direct WIF with metadata and state-object read access, not the deployer.
Principal-set grants trust the whole pool. A provider added or enabled later could match these attributes; restrict pool administration.
Artifact Registry writer is granted only on ${REGISTRY} after it exists, never project-wide.
Registry cleanup deletes versions older than 30 days except the five most recent per package; an active older image may be deleted.
No production sum bucket, production secret, secret value, or key version is created.
Firebase Hosting Admin can modify and delete every Hosting site in the project, including the default site.
run.services.setIamPolicy applies project-wide and can change access on any Cloud Run service.
API enablement, Cloud Run creation/updates, and log exclusions are project-wide.
Deploying code as the individually authorized runtime identities can exercise their data and staging-key access.
PR access to state may expose any sensitive values stored there. Existing and inherited IAM grants are not audited.
EOF
exit "$STATUS"
