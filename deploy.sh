#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy Deepgram MCP Gateway to AWS App Runner
#
# Works from AWS CloudShell or any machine with the AWS CLI configured.
# No Docker required — App Runner builds directly from your GitHub repo.
#
# What this script does:
#   1. Prompts for all required configuration (region, service name, API key…)
#   2. Stores the Deepgram API key in AWS Secrets Manager
#   3. Creates an IAM role so App Runner can read the secret at runtime
#   4. Creates (or updates) an App Runner service linked to your GitHub repo
#   5. Waits for the deployment to complete
#   6. Prints the HTTPS URL to paste into CyberArk SAIA
#
# Prerequisites (one-time, before running this script):
#   a) Connect App Runner to GitHub in the AWS Console:
#      https://console.aws.amazon.com/apprunner/home#/github-connections
#      → "Add new" → authorise GitHub → copy the Connection ARN
#   b) AWS CLI configured (in CloudShell this is automatic)
#
# Usage:
#   bash deploy.sh
#
# Re-running this script on an existing service updates the configuration
# (e.g. rotates the API key) and triggers a fresh deployment.
# =============================================================================

set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${GREEN}▶ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠  $*${NC}"; }
err()   { echo -e "${RED}✖  $*${NC}" >&2; }
info()  { echo -e "${CYAN}   $*${NC}"; }
ok()    { echo -e "${GREEN}✔  $*${NC}"; }

# ── prerequisite check ────────────────────────────────────────────────────────
if ! command -v aws >/dev/null 2>&1; then
  err "AWS CLI not found."
  err "In CloudShell it is pre-installed. Locally: https://aws.amazon.com/cli/"
  exit 1
fi

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Deepgram MCP Gateway — AWS App Runner Deployment           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "This script will deploy the Deepgram MCP server to AWS App Runner"
echo "and print a permanent HTTPS URL to register in CyberArk SAIA."
echo
echo "You will be prompted for the following:"
echo "  • AWS region"
echo "  • App Runner service name"
echo "  • GitHub repo URL and branch"
echo "  • GitHub Connection ARN  (from the App Runner console)"
echo "  • Deepgram API key       (stored securely in Secrets Manager)"
echo
read -rp "Press Enter to continue (Ctrl+C to cancel)..."

# ── 1. region ─────────────────────────────────────────────────────────────────
step "AWS Region"
DETECTED_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
read -rp "  Region [${DETECTED_REGION}]: " REGION
REGION="${REGION:-${DETECTED_REGION}}"
info "Using region: ${REGION}"

# ── 2. account ID ─────────────────────────────────────────────────────────────
step "Detecting AWS account"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${REGION}")
CALLER=$(aws sts get-caller-identity --query Arn --output text --region "${REGION}")
info "Account ID : ${ACCOUNT_ID}"
info "Identity   : ${CALLER}"

# ── 3. service name ───────────────────────────────────────────────────────────
step "App Runner service name"
read -rp "  Service name [deepgram-mcp-gateway]: " SERVICE_NAME
SERVICE_NAME="${SERVICE_NAME:-deepgram-mcp-gateway}"
info "Service name: ${SERVICE_NAME}"

# ── 4. github repo + branch ───────────────────────────────────────────────────
step "GitHub repository"
read -rp "  Repo URL [https://github.com/ChadPapineau/deepgram-mcp-gateway]: " REPO_URL
REPO_URL="${REPO_URL:-https://github.com/ChadPapineau/deepgram-mcp-gateway}"
read -rp "  Branch [main]: " BRANCH
BRANCH="${BRANCH:-main}"
info "Repository : ${REPO_URL}"
info "Branch     : ${BRANCH}"

# ── 5. github connection ARN ──────────────────────────────────────────────────
step "GitHub Connection ARN"
echo
echo "  App Runner needs a GitHub connection to pull your repository."
echo "  If you have not created one yet:"
echo "    1. Open the link below in your browser:"
info "   https://console.aws.amazon.com/apprunner/home?region=${REGION}#/github-connections"
echo "    2. Click 'Add new', authorise GitHub, complete the setup"
echo "    3. Copy the Connection ARN and paste it below"
echo
# List any existing available connections
CONNECTIONS=$(aws apprunner list-connections --region "${REGION}" \
  --query 'ConnectionSummaryList[?Status==`AVAILABLE`].[ConnectionArn,ConnectionName]' \
  --output text 2>/dev/null || true)
if [ -n "${CONNECTIONS}" ]; then
  echo "  Existing available connections:"
  while IFS=$'\t' read -r arn name; do
    info "  ${name}  →  ${arn}"
  done <<< "${CONNECTIONS}"
  echo
fi
read -rp "  GitHub Connection ARN: " GITHUB_CONNECTION_ARN
if [ -z "${GITHUB_CONNECTION_ARN}" ]; then
  err "GitHub Connection ARN is required. Create one in the App Runner console first."
  exit 1
fi

# ── 6. deepgram API key ───────────────────────────────────────────────────────
step "Deepgram API key"
echo "  This is stored in AWS Secrets Manager and injected at runtime."
echo "  It is never stored in the repo or visible in App Runner logs."
echo
read -rsp "  Deepgram API key (hidden): " DEEPGRAM_API_KEY
echo
if [ -z "${DEEPGRAM_API_KEY}" ]; then
  err "DEEPGRAM_API_KEY is required. Get one at https://console.deepgram.com"
  exit 1
fi

# ── 7. confirm before proceeding ─────────────────────────────────────────────
echo
echo "─────────────────────────────────────────────────────────────────"
echo "  Ready to deploy with these settings:"
info "  Region      : ${REGION}"
info "  Account     : ${ACCOUNT_ID}"
info "  Service     : ${SERVICE_NAME}"
info "  Repo        : ${REPO_URL} (branch: ${BRANCH})"
info "  Connection  : ${GITHUB_CONNECTION_ARN}"
echo "─────────────────────────────────────────────────────────────────"
echo
read -rp "Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── 8. store API key in Secrets Manager ──────────────────────────────────────
step "Storing Deepgram API key in Secrets Manager"
SECRET_NAME="${SERVICE_NAME}/deepgram-api-key"
if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" \
    --region "${REGION}" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${DEEPGRAM_API_KEY}" \
    --region "${REGION}" >/dev/null
  ok "Updated existing secret: ${SECRET_NAME}"
else
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --description "Deepgram API key for ${SERVICE_NAME} MCP server" \
    --secret-string "${DEEPGRAM_API_KEY}" \
    --region "${REGION}" >/dev/null
  ok "Created secret: ${SECRET_NAME}"
fi
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "${SECRET_NAME}" --region "${REGION}" \
  --query ARN --output text)
info "Secret ARN: ${SECRET_ARN}"

# ── 9. create IAM instance role ───────────────────────────────────────────────
step "Creating IAM instance role"
ROLE_NAME="${SERVICE_NAME}-instance-role"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "tasks.apprunner.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "App Runner instance role for ${SERVICE_NAME}" >/dev/null
  ok "Role created: ${ROLE_NAME}"
else
  ok "Role already exists: ${ROLE_NAME}"
fi

ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" \
  --query Role.Arn --output text)

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "ReadDeepgramSecret" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"secretsmanager:GetSecretValue\"],
      \"Resource\": \"${SECRET_ARN}\"
    }]
  }" >/dev/null
ok "IAM policy attached (secretsmanager:GetSecretValue)"
info "Role ARN: ${ROLE_ARN}"

# ── 10. build service configuration JSON ──────────────────────────────────────
SERVICE_CONFIG=$(python3 - <<PYEOF
import json
cfg = {
  "ServiceName": "${SERVICE_NAME}",
  "SourceConfiguration": {
    "CodeRepository": {
      "RepositoryUrl": "${REPO_URL}",
      "SourceCodeVersion": {
        "Type": "BRANCH",
        "Value": "${BRANCH}"
      },
      "CodeConfiguration": {
        "ConfigurationSource": "API",
        "CodeConfigurationValues": {
          "Runtime": "PYTHON_3",
          "BuildCommand": "pip install -r requirements.txt",
          "StartCommand": "python deepgram_tools_mcp.py --host 0.0.0.0 --port 8080",
          "Port": "8080",
          "RuntimeEnvironmentVariables": {
            "MCP_HOST": "0.0.0.0",
            "MCP_PORT":  "8080",
            "PYTHONUNBUFFERED": "1"
          },
          "RuntimeEnvironmentSecrets": {
            "DEEPGRAM_API_KEY": "${SECRET_ARN}"
          }
        }
      }
    },
    "AuthenticationConfiguration": {
      "ConnectionArn": "${GITHUB_CONNECTION_ARN}"
    },
    "AutoDeploymentsEnabled": True
  },
  "InstanceConfiguration": {
    "Cpu":             "0.25 vCPU",
    "Memory":          "0.5 GB",
    "InstanceRoleArn": "${ROLE_ARN}"
  },
  "HealthCheckConfiguration": {
    "Protocol":           "HTTP",
    "Path":               "/health",
    "Interval":           20,
    "Timeout":            5,
    "HealthyThreshold":   1,
    "UnhealthyThreshold": 5
  },
  "Tags": [
    {"Key": "project",    "Value": "deepgram-mcp-gateway"},
    {"Key": "managed-by", "Value": "deploy.sh"}
  ]
}
print(json.dumps(cfg))
PYEOF
)

# ── 11. create or update App Runner service ───────────────────────────────────
step "Deploying App Runner service"

EXISTING_ARN=$(aws apprunner list-services --region "${REGION}" \
  --query "ServiceSummaryList[?ServiceName=='${SERVICE_NAME}'].ServiceArn" \
  --output text 2>/dev/null || true)

if [ -n "${EXISTING_ARN}" ]; then
  warn "Service already exists — updating configuration and redeploying…"

  # Build update payload (subset of create payload)
  UPDATE_CONFIG=$(python3 - <<PYEOF
import json
cfg = {
  "ServiceArn": "${EXISTING_ARN}",
  "SourceConfiguration": {
    "CodeRepository": {
      "RepositoryUrl": "${REPO_URL}",
      "SourceCodeVersion": { "Type": "BRANCH", "Value": "${BRANCH}" },
      "CodeConfiguration": {
        "ConfigurationSource": "API",
        "CodeConfigurationValues": {
          "Runtime": "PYTHON_3",
          "BuildCommand": "pip install -r requirements.txt",
          "StartCommand": "python deepgram_tools_mcp.py --host 0.0.0.0 --port 8080",
          "Port": "8080",
          "RuntimeEnvironmentVariables": {
            "MCP_HOST": "0.0.0.0",
            "MCP_PORT":  "8080",
            "PYTHONUNBUFFERED": "1"
          },
          "RuntimeEnvironmentSecrets": {
            "DEEPGRAM_API_KEY": "${SECRET_ARN}"
          }
        }
      }
    },
    "AuthenticationConfiguration": { "ConnectionArn": "${GITHUB_CONNECTION_ARN}" },
    "AutoDeploymentsEnabled": True
  },
  "InstanceConfiguration": {
    "Cpu":             "0.25 vCPU",
    "Memory":          "0.5 GB",
    "InstanceRoleArn": "${ROLE_ARN}"
  },
  "HealthCheckConfiguration": {
    "Protocol": "HTTP", "Path": "/health",
    "Interval": 20, "Timeout": 5,
    "HealthyThreshold": 1, "UnhealthyThreshold": 5
  }
}
print(json.dumps(cfg))
PYEOF
  )

  aws apprunner update-service \
    --region "${REGION}" \
    --cli-input-json "${UPDATE_CONFIG}" >/dev/null
  SERVICE_ARN="${EXISTING_ARN}"
  ok "Update triggered for: ${SERVICE_ARN}"
else
  SERVICE_ARN=$(aws apprunner create-service \
    --region "${REGION}" \
    --cli-input-json "${SERVICE_CONFIG}" \
    --query Service.ServiceArn --output text)
  ok "Service created: ${SERVICE_ARN}"
fi

# ── 12. wait for deployment ───────────────────────────────────────────────────
step "Waiting for deployment (typically 2–4 minutes)"
ATTEMPTS=36   # 36 × 10s = 6 minutes max
for i in $(seq 1 ${ATTEMPTS}); do
  STATUS=$(aws apprunner describe-service \
    --service-arn "${SERVICE_ARN}" --region "${REGION}" \
    --query Service.Status --output text)
  printf "  [%2d/%d] Status: %s\n" "${i}" "${ATTEMPTS}" "${STATUS}"
  case "${STATUS}" in
    RUNNING)          break ;;
    CREATE_FAILED|\
    UPDATE_FAILED|\
    DELETE_FAILED)
      err "Deployment failed (${STATUS})."
      err "Check logs: App Runner console → ${SERVICE_NAME} → Logs"
      exit 1 ;;
  esac
  sleep 10
done

if [ "${STATUS}" != "RUNNING" ]; then
  err "Timed out waiting for RUNNING status. Last status: ${STATUS}"
  err "Check the App Runner console for progress."
  exit 1
fi

# ── 13. get public URL and print summary ─────────────────────────────────────
URL=$(aws apprunner describe-service \
  --service-arn "${SERVICE_ARN}" --region "${REGION}" \
  --query Service.ServiceUrl --output text)

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Deployment complete!                                        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                               ║"
printf "║  MCP endpoint: %-47s║\n" "https://${URL}/mcp"
echo "║                                                               ║"
echo "║  Steps to register in CyberArk SAIA (Idira):                 ║"
echo "║    1. Open SAIA → Register MCP server                         ║"
echo "║    2. Paste the URL above into 'Server URL'                   ║"
echo "║    3. Click Discover → Auth method should be 'None'           ║"
echo "║    4. Fill in name/category and click Register                ║"
echo "║                                                               ║"
echo "║  Health check: https://${URL}/health"
echo "║                                                               ║"
echo "║  To redeploy after a code push (auto-deploy is ON):           ║"
echo "║    git push origin main    ← App Runner detects & rebuilds    ║"
echo "║                                                               ║"
echo "║  To rotate the Deepgram API key, re-run: bash deploy.sh       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
