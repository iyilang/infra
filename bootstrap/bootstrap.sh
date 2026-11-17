#!/usr/bin/env bash
set -euo pipefail

# This script is for review. --check is the default and is read-only. The
# privileged --apply path must run only in an approved CI environment.
PROJECT="${IYI_PROJECT_ID:-iyi-lang}"
REGION="${IYI_REGION:-us-central1}"
BUCKET="${IYI_TF_STATE_BUCKET:-iyi-lang-tfstate}"
POOL="iyi-github"
TERRAFORM_ACCOUNT="iyi-terraform"
PLAN_POOL="iyi-plan-github"
PLAN_ACCOUNT="iyi-terraform-plan"
PLAN_ROLE="iyiTerraformRead"
ROLE="iyiTerraformCreator"
MODE="check"
SENSITIVE_SA="${IYI_SENSITIVE_SERVICE_ACCOUNT:-firebase-adminsdk-fbsvc@${PROJECT}.iam.gserviceaccount.com}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DENY_POLICY="iyi-terraform-no-escalation"

usage() {
  printf '%s\n' 'Usage: bootstrap.sh [--check | --apply]' \
    'Default: --check. --apply changes Cloud resources and is intended only for approved CI.'
}

while (($#)); do
  case "$1" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$PROJECT" != iyi-lang ]]; then
  echo 'Unexpected project; refusing to inspect or change resources.' >&2
  exit 1
fi

for executable in gcloud jq grep; do
  command -v "$executable" >/dev/null || { printf 'Missing command: %s\n' "$executable" >&2; exit 1; }
done

# A failed describe is absent only for a recognized not-found response.
# Permission failures, API errors and network failures stop the script.
describe_status() {
  local label=$1 output
  shift
  if output=$("$@" 2>&1); then
    printf '%s: PRESENT\n' "$label"
    return 0
  fi
  if printf '%s\n' "$output" | grep -Eiq 'NOT_FOUND|not found|does not exist|notFound'; then
    printf '%s: ABSENT\n' "$label"
    return 1
  fi
  printf '%s: UNREADABLE: %s\n' "$label" "$output" >&2
  return 2
}

project_number=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
[[ "$project_number" =~ ^[0-9]+$ ]] || { echo 'Cannot resolve project number' >&2; exit 1; }
tf_email="${TERRAFORM_ACCOUNT}@${PROJECT}.iam.gserviceaccount.com"

check_apis() {
  local enabled api
  enabled=$(gcloud services list --enabled --project="$PROJECT" --format='value(config.name)')
  for api in firebase.googleapis.com firebasehosting.googleapis.com run.googleapis.com \
    iam.googleapis.com iamcredentials.googleapis.com secretmanager.googleapis.com \
    artifactregistry.googleapis.com sts.googleapis.com cloudbilling.googleapis.com \
    billingbudgets.googleapis.com serviceusage.googleapis.com; do
    if printf '%s\n' "$enabled" | grep -Fxq "$api"; then
      printf 'API %s: ENABLED\n' "$api"
    else
      printf 'API %s: DISABLED\n' "$api"
    fi
  done
}

# Check effective access, including inherited grants, instead of treating an
# empty direct service-account policy as proof. UNKNOWN is not a denial.
check_privileged_access() {
  local resource permission access failed=0
  if ! gcloud iam service-accounts describe "$tf_email" --project="$PROJECT" --format=json >/dev/null 2>&1; then
    echo 'Effective privilege checks: UNPROVEN (Terraform service account is unavailable)'
    return 1
  fi
  resource="//iam.googleapis.com/projects/${PROJECT}/serviceAccounts/${SENSITIVE_SA}"
  for permission in iam.serviceAccounts.actAs iam.serviceAccounts.getAccessToken \
    iam.serviceAccounts.signBlob iam.serviceAccounts.signJwt \
    iam.serviceAccounts.implicitDelegation iam.serviceAccounts.setIamPolicy; do
    if ! access=$(gcloud policy-troubleshoot iam "$resource" --principal-email="$tf_email" \
      --permission="$permission" --format='value(access)' 2>&1); then
      printf '%s: UNPROVEN (%s)\n' "$permission" "$access" >&2
      failed=1
    elif [[ "$access" == NOT_GRANTED ]]; then
      printf '%s: NOT_GRANTED\n' "$permission"
    else
      printf '%s: %s\n' "$permission" "${access:-UNPROVEN}" >&2
      failed=1
    fi
  done
  resource="//cloudresourcemanager.googleapis.com/projects/${PROJECT}"
  for permission in resourcemanager.projects.setIamPolicy iam.serviceAccounts.create \
    iam.roles.create iam.roles.update iam.workloadIdentityPools.create \
    iam.workloadIdentityPools.update iam.workloadIdentityPoolProviders.create \
    iam.workloadIdentityPoolProviders.update run.services.setIamPolicy; do
    if ! access=$(gcloud policy-troubleshoot iam "$resource" --principal-email="$tf_email" \
      --permission="$permission" --format='value(access)' 2>&1); then
      printf '%s: UNPROVEN (%s)\n' "$permission" "$access" >&2
      failed=1
    elif [[ "$access" == NOT_GRANTED ]]; then
      printf '%s: NOT_GRANTED\n' "$permission"
    else
      printf '%s: %s\n' "$permission" "${access:-UNPROVEN}" >&2
      failed=1
    fi
  done
  return "$failed"
}

check_all() {
  local status=0 name repo provider account rc
  check_apis || status=1
  describe_status 'State bucket' gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  describe_status 'Workload identity pool' gcloud iam workload-identity-pools describe "$POOL" --location=global --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  describe_status 'Plan workload identity pool' gcloud iam workload-identity-pools describe "$PLAN_POOL" --location=global --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  describe_status 'Plan WIF provider infra' gcloud iam workload-identity-pools providers describe infra --workload-identity-pool="$PLAN_POOL" --location=global --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  for provider in infra modproxy; do
    describe_status "WIF provider $provider" gcloud iam workload-identity-pools providers describe "$provider" \
      --workload-identity-pool="$POOL" --location=global --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  done
  for account in "$TERRAFORM_ACCOUNT" "$PLAN_ACCOUNT" iyi-modproxy-deployer iyi-proxy iyi-sum iyi-probe; do
    describe_status "Service account $account" gcloud iam service-accounts describe "${account}@${PROJECT}.iam.gserviceaccount.com" \
      --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  done
  describe_status 'Terraform project custom role' gcloud iam roles describe "$ROLE" --project="$PROJECT" --format=json || { rc=$?; ((rc == 1)) || status=1; }
  for name in infra modproxy; do
    repo="iyilang/$name"
    printf 'Provider %s required repository: %s\n' "$name" "$repo"
  done
  check_privileged_access || status=1
  return "$status"
}

if [[ "$MODE" == check ]]; then
  check_all
  exit $?
fi

if [[ "${CI:-}" != true ]]; then
  echo 'Refusing to mutate Google Cloud outside an approved CI environment.' >&2
  exit 1
fi

# The code below is intentionally not executed by --check. Existing Firebase
# services are left enabled and unmanaged. These required APIs are enabled
# before identity, storage, and budget resources are created.
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com secretmanager.googleapis.com \
  sts.googleapis.com cloudbilling.googleapis.com billingbudgets.googleapis.com \
  --project="$PROJECT"

if describe_status 'State bucket' gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" --format=json; then
  actual_project=$(gcloud storage buckets describe "gs://${BUCKET}" --format='value(projectNumber)')
  [[ "$actual_project" == "$project_number" ]] || { echo 'Bucket belongs to a different project; refusing adoption' >&2; exit 1; }
  managed_by=$(gcloud storage buckets describe "gs://${BUCKET}" --format='value(labels.managed_by)')
  [[ "$managed_by" == iyi_infra ]] || { echo 'Bucket lacks the bootstrap ownership marker; refusing adoption' >&2; exit 1; }
else
  rc=$?; ((rc == 1)) || exit "$rc"
  gcloud storage buckets create "gs://${BUCKET}" --project="$PROJECT" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention --labels=stack=iyi,managed_by=iyi_infra
fi
gcloud storage buckets update "gs://${BUCKET}" --versioning --quiet

ensure_pool() {
  local pool=$1 description rc
  if describe_status "WIF pool $pool" gcloud iam workload-identity-pools describe "$pool" --project="$PROJECT" --location=global --format=json; then
    description=$(gcloud iam workload-identity-pools describe "$pool" --project="$PROJECT" --location=global --format='value(description)')
    [[ "$description" == 'managed-by: iyilang/infra bootstrap' ]] || { echo 'Unowned pool; refusing adoption' >&2; return 1; }
  else
    rc=$?; ((rc == 1)) || return "$rc"
    gcloud iam workload-identity-pools create "$pool" --project="$PROJECT" --location=global \
      --display-name="$pool" --description='managed-by: iyilang/infra bootstrap'
  fi
}

ensure_provider() {
  local pool=$1 name=$2 condition=$3 existing rc
  if describe_status "Provider $pool/$name" gcloud iam workload-identity-pools providers describe "$name" \
    --workload-identity-pool="$pool" --project="$PROJECT" --location=global --format=json; then
    existing=$(gcloud iam workload-identity-pools providers describe "$name" --workload-identity-pool="$pool" \
      --project="$PROJECT" --location=global --format=json)
    if ! jq -e --arg condition "$condition" \
      '.attributeCondition == $condition and .oidc.issuerUri == "https://token.actions.githubusercontent.com" and
       .attributeMapping["google.subject"] == "assertion.sub" and
       .attributeMapping["attribute.repository"] == "assertion.repository" and .disabled != true' \
      <<<"$existing" >/dev/null; then
      printf 'Provider %s/%s trust configuration differs; refusing adoption\n' "$pool" "$name" >&2
      return 1
    fi
  else
    rc=$?; ((rc == 1)) || return "$rc"
    gcloud iam workload-identity-pools providers create-oidc "$name" --workload-identity-pool="$pool" \
      --project="$PROJECT" --location=global --issuer-uri='https://token.actions.githubusercontent.com' \
      --attribute-mapping='google.subject=assertion.sub,attribute.repository=assertion.repository' \
      --attribute-condition="$condition" --display-name="iyi $name GitHub Actions"
  fi
}

ensure_pool "$POOL"
ensure_pool "$PLAN_POOL"
for name in infra modproxy; do
  ensure_provider "$POOL" "$name" "assertion.repository == 'iyilang/${name}' && assertion.ref == 'refs/heads/main' && assertion.event_name == 'push'"
done
ensure_provider "$PLAN_POOL" infra "assertion.repository == 'iyilang/infra' && assertion.event_name == 'pull_request'"

for account in "$TERRAFORM_ACCOUNT" "$PLAN_ACCOUNT" iyi-modproxy-deployer iyi-proxy iyi-sum iyi-probe; do
  email="${account}@${PROJECT}.iam.gserviceaccount.com"
  if describe_status "Service account $account" gcloud iam service-accounts describe "$email" --project="$PROJECT" --format=json; then
    description=$(gcloud iam service-accounts describe "$email" --project="$PROJECT" --format='value(description)')
    [[ "$description" == 'managed-by: iyilang/infra bootstrap' ]] || { printf 'Unowned account %s; refusing adoption\n' "$account" >&2; exit 1; }
  else
    rc=$?; ((rc == 1)) || exit "$rc"
    gcloud iam service-accounts create "$account" --project="$PROJECT" \
      --display-name="$account" --description='managed-by: iyilang/infra bootstrap'
  fi
done

# A deny policy is optional because it requires iam.denyAdmin, which is not
# implied by project Owner. It denies escalation even if a later grant drifts.
# actAs is deliberately excluded: the deployment account needs it on the
# individually granted runtime accounts. Verify the privileged target below.
if [[ "${IYI_ENFORCE_DENY_POLICY:-false}" == true ]]; then
  attachment="cloudresourcemanager.googleapis.com/projects/${project_number}"
  deny_file=$(mktemp)
  trap 'rm -f -- "$deny_file"' EXIT
  jq --arg principal "principal://iam.googleapis.com/projects/-/serviceAccounts/${tf_email}" \
    '.rules[0].denyRule.deniedPrincipals = [$principal]' \
    "$SCRIPT_DIR/deny-policy.json" >"$deny_file"
  if describe_status 'Escalation deny policy' gcloud iam policies describe "$DENY_POLICY" \
    --attachment-point="$attachment" --kind=denypolicies --format=json; then
    existing=$(gcloud iam policies describe "$DENY_POLICY" --attachment-point="$attachment" --kind=denypolicies \
      --format=json | jq -S '.rules')
    expected=$(jq -S '.rules' "$deny_file")
    [[ "$existing" == "$expected" ]] || { echo 'Deny policy differs; refusing adoption' >&2; exit 1; }
  else
    rc=$?; ((rc == 1)) || exit "$rc"
    gcloud iam policies create "$DENY_POLICY" --attachment-point="$attachment" \
      --kind=denypolicies --policy-file="$deny_file"
  fi
fi

# No project IAM, service-account IAM, token minting, or pool administration
# permissions occur in this role. Cloud Run service IAM needs a separate,
# resource-scoped grant after creation; it is intentionally not granted here.
permissions='resourcemanager.projects.get,serviceusage.services.use,serviceusage.services.get,serviceusage.services.list,serviceusage.services.enable,run.services.create,run.services.get,run.services.list,run.services.getIamPolicy,run.operations.get,firebasehosting.sites.create,firebasehosting.sites.get,firebasehosting.sites.list,firebasehosting.sites.update,artifactregistry.repositories.create,artifactregistry.repositories.get,artifactregistry.repositories.list,secretmanager.secrets.create,secretmanager.secrets.get,secretmanager.secrets.list,storage.buckets.create,billing.resourcebudgets.read,billing.resourcebudgets.write'
if describe_status 'Terraform custom role' gcloud iam roles describe "$ROLE" --project="$PROJECT" --format=json; then
  existing=$(gcloud iam roles describe "$ROLE" --project="$PROJECT" --format=json | jq -r '.includedPermissions | sort | join(",")')
  expected=$(printf '%s' "$permissions" | tr ',' '\n' | sort | paste -sd, -)
  [[ "$existing" == "$expected" ]] || { echo 'Terraform custom role differs; refusing adoption' >&2; exit 1; }
else
  rc=$?; ((rc == 1)) || exit "$rc"
  gcloud iam roles create "$ROLE" --project="$PROJECT" --title='iyi Terraform create and read' \
    --stage=GA --permissions="$permissions"
fi

plan_permissions='resourcemanager.projects.get,serviceusage.services.use,serviceusage.services.get,serviceusage.services.list,run.services.get,run.services.list,run.services.getIamPolicy,run.operations.get,firebasehosting.sites.get,firebasehosting.sites.list,artifactregistry.repositories.get,artifactregistry.repositories.list,secretmanager.secrets.get,secretmanager.secrets.getIamPolicy,secretmanager.versions.get,secretmanager.versions.list,storage.buckets.get,storage.buckets.getIamPolicy,storage.buckets.list,billing.resourcebudgets.read,logging.exclusions.get,logging.exclusions.list'
if describe_status 'Terraform plan custom role' gcloud iam roles describe "$PLAN_ROLE" --project="$PROJECT" --format=json; then
  existing=$(gcloud iam roles describe "$PLAN_ROLE" --project="$PROJECT" --format=json | jq -r '.includedPermissions | sort | join(",")')
  expected=$(printf '%s' "$plan_permissions" | tr ',' '\n' | sort | paste -sd, -)
  [[ "$existing" == "$expected" ]] || { echo 'Terraform plan custom role differs; refusing adoption' >&2; exit 1; }
else
  rc=$?; ((rc == 1)) || exit "$rc"
  gcloud iam roles create "$PLAN_ROLE" --project="$PROJECT" --title='iyi Terraform read only' \
    --stage=GA --permissions="$plan_permissions"
fi

# Secret Manager supports resource-name conditions. This role can manage
# only iyi-prefixed secrets. Its policy permission can grant payload access
# on those secrets, even though direct version access is not granted here.
secret_role='iyiSecretMetadataManager'
secret_permissions='secretmanager.secrets.get,secretmanager.secrets.getIamPolicy,secretmanager.secrets.setIamPolicy,secretmanager.versions.add,secretmanager.versions.get,secretmanager.versions.list'
if describe_status 'Secret metadata custom role' gcloud iam roles describe "$secret_role" --project="$PROJECT" --format=json; then
  existing=$(gcloud iam roles describe "$secret_role" --project="$PROJECT" --format=json | jq -r '.includedPermissions | sort | join(",")')
  expected=$(printf '%s' "$secret_permissions" | tr ',' '\n' | sort | paste -sd, -)
  [[ "$existing" == "$expected" ]] || { echo 'Secret metadata custom role differs; refusing adoption' >&2; exit 1; }
else
  rc=$?; ((rc == 1)) || exit "$rc"
  gcloud iam roles create "$secret_role" --project="$PROJECT" --title='iyi secret metadata manager' \
    --stage=GA --permissions="$secret_permissions"
fi

gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${tf_email}" \
  --role="projects/${PROJECT}/roles/${secret_role}" \
  --condition="expression=resource.name.startsWith('projects/${project_number}/secrets/iyi-'),title=iyiSecrets" --quiet >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${tf_email}" \
  --role="projects/${PROJECT}/roles/${ROLE}" --condition=None --quiet >/dev/null
plan_email="${PLAN_ACCOUNT}@${PROJECT}.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${plan_email}" \
  --role="projects/${PROJECT}/roles/${PLAN_ROLE}" --condition=None --quiet >/dev/null
# Storage conditions support resource.name. The state bucket does not share
# this object-bucket prefix; state access is separately limited to objects.
gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${tf_email}" \
  --role=roles/storage.admin \
  --condition="expression=resource.name.startsWith('projects/_/buckets/iyi-${PROJECT}-'),title=iyiObjectBuckets" --quiet >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${tf_email}" --role=roles/storage.objectAdmin --quiet >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${plan_email}" --role=roles/storage.objectViewer --quiet >/dev/null

plan_member="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${PLAN_POOL}/attribute.repository/iyilang/infra"
gcloud iam service-accounts add-iam-policy-binding "$plan_email" --project="$PROJECT" \
  --role=roles/iam.workloadIdentityUser --member="$plan_member" --condition=None --quiet >/dev/null

for pair in 'infra:iyi-terraform' 'modproxy:iyi-modproxy-deployer'; do
  name=${pair%%:*}; account=${pair#*:}
  member="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/iyilang/${name}"
  gcloud iam service-accounts add-iam-policy-binding "${account}@${PROJECT}.iam.gserviceaccount.com" \
    --project="$PROJECT" --role=roles/iam.workloadIdentityUser --member="$member" --condition=None --quiet >/dev/null
done

for account in iyi-proxy iyi-sum iyi-probe; do
  gcloud iam service-accounts add-iam-policy-binding "${account}@${PROJECT}.iam.gserviceaccount.com" \
    --project="$PROJECT" --role=roles/iam.serviceAccountUser --member="serviceAccount:${tf_email}" --condition=None --quiet >/dev/null
done
for pair in 'iyi-proxy:iyi-modproxy-deployer' 'iyi-sum:iyi-modproxy-deployer'; do
  runtime=${pair%%:*}; deployer=${pair#*:}
  gcloud iam service-accounts add-iam-policy-binding "${runtime}@${PROJECT}.iam.gserviceaccount.com" \
    --project="$PROJECT" --role=roles/iam.serviceAccountUser \
    --member="serviceAccount:${deployer}@${PROJECT}.iam.gserviceaccount.com" --condition=None --quiet >/dev/null
done

check_privileged_access
printf '%s\n' 'Bootstrap complete. Resource-level Cloud Run policy, budget access and log-exclusion permissions remain unproven.'
