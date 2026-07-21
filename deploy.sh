#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy Deepgram MCP Gateway to Amazon ECS Express Mode
#
# Works from AWS CloudShell or any machine with the AWS CLI configured.
# No local Docker required — AWS CodeBuild builds the image in the cloud.
#
# What this script does:
#   1. Prompts for all required configuration
#   2. Creates an Amazon ECR repository for the container image
#   3. Creates an AWS CodeBuild project that builds the Docker image from GitHub
#      and pushes it to ECR (no local Docker needed)
#   4. Runs the CodeBuild build and waits for it to complete
#   5. Stores the Deepgram API key in AWS Secrets Manager
#   6. Creates the two IAM roles required by ECS Express Mode
#   7. Deploys the service with Amazon ECS Express Mode (auto-provisions an
#      Application Load Balancer, HTTPS cert, autoscaling, and a stable URL)
#   8. Waits for the service to reach ACTIVE status
#   9. Prints the HTTPS endpoint to register in CyberArk SAIA
#
# Prerequisites (all available in AWS CloudShell by default):
#   - AWS CLI  (pre-installed in CloudShell)
#   - Python 3 (pre-installed in CloudShell, used to generate JSON payloads)
#
# Usage:
#   # From AWS CloudShell:
#   git clone https://github.com/ChadPapineau/deepgram-mcp-gateway
#   cd deepgram-mcp-gateway
#   bash deploy.sh
#
# Re-running this script on an existing deployment updates configuration
# (e.g. rotates the Deepgram API key) and triggers a fresh image build + deploy.
# =============================================================================

set -euo pipefail

# ── colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "\n${GREEN}▶  $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠  $*${NC}"; }
err()   { echo -e "${RED}✖  $*${NC}" >&2; }
info()  { echo -e "${CYAN}   $*${NC}"; }
ok()    { echo -e "${GREEN}✔  $*${NC}"; }

# ── prerequisites ──────────────────────────────────────────────────────────────
if ! command -v aws >/dev/null 2>&1; then
  err "AWS CLI not found."
  err "In CloudShell it is pre-installed. Locally: https://aws.amazon.com/cli/"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  err "python3 not found (needed to generate JSON payloads)."
  exit 1
fi

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Deepgram MCP Gateway — ECS Express Mode Deployment         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "  This script deploys the Deepgram MCP server to Amazon ECS"
echo "  Express Mode and prints a permanent HTTPS URL to register"
echo "  in CyberArk SAIA / Idira."
echo
echo "  Required inputs:"
echo "    • AWS region"
echo "    • Service / resource name prefix"
echo "    • GitHub repo URL and branch"
echo "    • Deepgram API key  (stored in Secrets Manager)"
echo
read -rp "Press Enter to continue (Ctrl+C to cancel) ..."

# ── 1. region ─────────────────────────────────────────────────────────────────
step "AWS Region"
DETECTED_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
read -rp "  Region [${DETECTED_REGION}]: " REGION
REGION="${REGION:-${DETECTED_REGION}}"
info "Region: ${REGION}"

# ── 2. account ID ─────────────────────────────────────────────────────────────
step "Detecting AWS account"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${REGION}")
CALLER=$(aws sts get-caller-identity --query Arn --output text --region "${REGION}")
info "Account : ${ACCOUNT_ID}"
info "Identity: ${CALLER}"

# ── 3. service name ───────────────────────────────────────────────────────────
step "Service name"
read -rp "  Name prefix for all resources [deepgram-mcp-gateway]: " SERVICE_NAME
SERVICE_NAME="${SERVICE_NAME:-deepgram-mcp-gateway}"
info "Service name: ${SERVICE_NAME}"

# ── 4. GitHub repo ────────────────────────────────────────────────────────────
step "GitHub repository"
read -rp "  Repo URL [https://github.com/ChadPapineau/deepgram-mcp-gateway]: " REPO_URL
REPO_URL="${REPO_URL:-https://github.com/ChadPapineau/deepgram-mcp-gateway}"
read -rp "  Branch [main]: " BRANCH
BRANCH="${BRANCH:-main}"
info "Repo  : ${REPO_URL}"
info "Branch: ${BRANCH}"

# ── 5. Deepgram API key ───────────────────────────────────────────────────────
step "Deepgram API key"
echo "  Stored in AWS Secrets Manager — never committed to the repo."
echo
read -rsp "  Deepgram API key (hidden): " DEEPGRAM_API_KEY
echo
if [ -z "${DEEPGRAM_API_KEY}" ]; then
  err "DEEPGRAM_API_KEY is required. Get one at https://console.deepgram.com"
  exit 1
fi

# ── 6. confirm ────────────────────────────────────────────────────────────────
ECR_REPO_NAME="${SERVICE_NAME}"
ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"
echo
echo "─────────────────────────────────────────────────────────────────"
info "  Region      : ${REGION}"
info "  Account     : ${ACCOUNT_ID}"
info "  Service     : ${SERVICE_NAME}"
info "  Repo        : ${REPO_URL} (${BRANCH})"
info "  ECR image   : ${ECR_REPO_URI}:latest"
echo "─────────────────────────────────────────────────────────────────"
echo
read -rp "Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── 7. ECR repository ──────────────────────────────────────────────────────────
step "Creating ECR repository"
if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" \
    --region "${REGION}" >/dev/null 2>&1; then
  ok "ECR repository already exists: ${ECR_REPO_NAME}"
else
  aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true >/dev/null
  ok "ECR repository created: ${ECR_REPO_NAME}"
fi

# ── 8. CodeBuild service role ─────────────────────────────────────────────────
step "Creating CodeBuild service role"
CB_ROLE_NAME="${SERVICE_NAME}-codebuild-role"
CB_TRUST='{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
if ! aws iam get-role --role-name "${CB_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${CB_ROLE_NAME}" \
    --assume-role-policy-document "${CB_TRUST}" \
    --description "CodeBuild role for ${SERVICE_NAME} image builds" >/dev/null
  ok "CodeBuild role created: ${CB_ROLE_NAME}"
else
  ok "CodeBuild role already exists: ${CB_ROLE_NAME}"
fi
CB_ROLE_ARN=$(aws iam get-role --role-name "${CB_ROLE_NAME}" --query Role.Arn --output text)

aws iam put-role-policy \
  --role-name "${CB_ROLE_NAME}" \
  --policy-name "BuildAndPushToECR" \
  --policy-document "$(python3 -c "
import json, sys
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [
    {
      'Effect': 'Allow',
      'Action': [
        'logs:CreateLogGroup','logs:CreateLogStream','logs:PutLogEvents'
      ],
      'Resource': '*'
    },
    {
      'Effect': 'Allow',
      'Action': ['ecr:GetAuthorizationToken'],
      'Resource': '*'
    },
    {
      'Effect': 'Allow',
      'Action': [
        'ecr:BatchCheckLayerAvailability','ecr:GetDownloadUrlForLayer',
        'ecr:BatchGetImage','ecr:PutImage','ecr:InitiateLayerUpload',
        'ecr:UploadLayerPart','ecr:CompleteLayerUpload'
      ],
      'Resource': 'arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}'
    }
  ]
}))
")" >/dev/null
ok "CodeBuild IAM policy attached"

# IAM is eventually consistent — newly created roles take ~15 s to propagate
# before CodeBuild can assume them. Without this wait, create-project fails
# with "CodeBuild is not authorized to perform: sts:AssumeRole on service role."
echo "  Waiting 20 s for IAM role to propagate..."
sleep 20

# ── 9. CodeBuild project ──────────────────────────────────────────────────────
step "Creating CodeBuild project"
CB_PROJECT_NAME="${SERVICE_NAME}-build"
CB_PROJECT_JSON=$(python3 - <<PYEOF
import json
print(json.dumps({
  "name": "${CB_PROJECT_NAME}",
  "description": "Builds Docker image for ${SERVICE_NAME} MCP server",
  "source": {
    "type": "GITHUB",
    "location": "${REPO_URL}",
    "buildspec": "buildspec.yml"
  },
  "sourceVersion": "${BRANCH}",
  "artifacts": {"type": "NO_ARTIFACTS"},
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": True,
    "environmentVariables": [
      {"name": "ECR_REPO_URI", "value": "${ECR_REPO_URI}", "type": "PLAINTEXT"},
      {"name": "AWS_DEFAULT_REGION", "value": "${REGION}", "type": "PLAINTEXT"}
    ]
  },
  "serviceRole": "${CB_ROLE_ARN}",
  "logsConfig": {
    "cloudWatchLogs": {
      "status": "ENABLED",
      "groupName": "/aws/codebuild/${CB_PROJECT_NAME}"
    }
  }
}))
PYEOF
)

if aws codebuild batch-get-projects --names "${CB_PROJECT_NAME}" \
    --region "${REGION}" --query "projects[0].name" --output text 2>/dev/null \
    | grep -q "${CB_PROJECT_NAME}"; then
  aws codebuild update-project --cli-input-json "${CB_PROJECT_JSON}" \
    --region "${REGION}" >/dev/null
  ok "CodeBuild project updated: ${CB_PROJECT_NAME}"
else
  aws codebuild create-project --cli-input-json "${CB_PROJECT_JSON}" \
    --region "${REGION}" >/dev/null
  ok "CodeBuild project created: ${CB_PROJECT_NAME}"
fi

# ── 10. run CodeBuild to build & push Docker image ────────────────────────────
step "Building Docker image (this takes ~3 minutes)"
echo "  CodeBuild pulls from GitHub, runs docker build, and pushes to ECR."
echo "  No local Docker needed."
echo
BUILD_ID=$(aws codebuild start-build \
  --project-name "${CB_PROJECT_NAME}" \
  --region "${REGION}" \
  --query "build.id" --output text)
ok "Build started: ${BUILD_ID}"

BUILD_URL="https://console.aws.amazon.com/codesuite/codebuild/${ACCOUNT_ID}/projects/${CB_PROJECT_NAME}/build/${BUILD_ID//:/}/view/new"
info "Live logs: ${BUILD_URL}"

# Poll until build finishes
ATTEMPTS=40  # 40 × 15s = 10 minutes max
for i in $(seq 1 ${ATTEMPTS}); do
  BUILD_STATUS=$(aws codebuild batch-get-builds --ids "${BUILD_ID}" \
    --region "${REGION}" \
    --query "builds[0].buildStatus" --output text)
  printf "  [%2d/%d] Build status: %s\n" "${i}" "${ATTEMPTS}" "${BUILD_STATUS}"
  case "${BUILD_STATUS}" in
    SUCCEEDED) ok "Docker image built and pushed to ECR!"; break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      err "Build failed (${BUILD_STATUS})."
      err "Check logs: ${BUILD_URL}"
      exit 1 ;;
  esac
  sleep 15
done

if [ "${BUILD_STATUS}" != "SUCCEEDED" ]; then
  err "Build timed out. Check the CodeBuild console for logs."
  exit 1
fi

# ── 11. Secrets Manager ───────────────────────────────────────────────────────
step "Storing Deepgram API key in Secrets Manager"
SECRET_NAME="${SERVICE_NAME}/deepgram-api-key"
if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" \
    --region "${REGION}" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${DEEPGRAM_API_KEY}" \
    --region "${REGION}" >/dev/null
  ok "Secret updated: ${SECRET_NAME}"
else
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --description "Deepgram API key for ${SERVICE_NAME} MCP server" \
    --secret-string "${DEEPGRAM_API_KEY}" \
    --region "${REGION}" >/dev/null
  ok "Secret created: ${SECRET_NAME}"
fi
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "${SECRET_NAME}" --region "${REGION}" \
  --query ARN --output text)
info "Secret ARN: ${SECRET_ARN}"

# ── 12. ECS task execution role ───────────────────────────────────────────────
step "Creating ECS task execution role"
EXEC_ROLE_NAME="${SERVICE_NAME}-ecs-exec-role"
EXEC_TRUST='{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
if ! aws iam get-role --role-name "${EXEC_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${EXEC_ROLE_NAME}" \
    --assume-role-policy-document "${EXEC_TRUST}" \
    --description "ECS task execution role for ${SERVICE_NAME}" >/dev/null
  ok "Execution role created: ${EXEC_ROLE_NAME}"
else
  ok "Execution role already exists: ${EXEC_ROLE_NAME}"
fi
EXEC_ROLE_ARN=$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "${EXEC_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
  2>/dev/null || true

aws iam put-role-policy \
  --role-name "${EXEC_ROLE_NAME}" \
  --policy-name "ReadDeepgramSecret" \
  --policy-document "$(python3 -c "
import json
print(json.dumps({
  'Version':'2012-10-17',
  'Statement':[{
    'Effect':'Allow',
    'Action':['secretsmanager:GetSecretValue'],
    'Resource':'${SECRET_ARN}'
  }]
}))
")" >/dev/null
ok "IAM policy attached (secretsmanager:GetSecretValue)"
info "Execution role ARN: ${EXEC_ROLE_ARN}"

# ── 13. ECS infrastructure role ───────────────────────────────────────────────
step "Creating ECS infrastructure role (for Express Mode)"
INFRA_ROLE_NAME="${SERVICE_NAME}-ecs-infra-role"
INFRA_TRUST='{
  "Version":"2012-10-17",
  "Statement":[{
    "Sid":"AllowAccessInfrastructureForECSExpressServices",
    "Effect":"Allow",
    "Principal":{"Service":"ecs.amazonaws.com"},
    "Action":"sts:AssumeRole"
  }]
}'
if ! aws iam get-role --role-name "${INFRA_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${INFRA_ROLE_NAME}" \
    --assume-role-policy-document "${INFRA_TRUST}" \
    --description "ECS infrastructure role for ${SERVICE_NAME} Express Mode" >/dev/null
  ok "Infrastructure role created: ${INFRA_ROLE_NAME}"
else
  ok "Infrastructure role already exists: ${INFRA_ROLE_NAME}"
fi
INFRA_ROLE_ARN=$(aws iam get-role --role-name "${INFRA_ROLE_NAME}" \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "${INFRA_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices" \
  2>/dev/null || true

info "Infrastructure role ARN: ${INFRA_ROLE_ARN}"

# IAM roles are eventually consistent; give them a moment to propagate
echo "  Waiting 15 s for IAM roles to propagate..."
sleep 15

# ── 14. build --primary-container JSON ────────────────────────────────────────
PRIMARY_CONTAINER=$(python3 - <<PYEOF
import json
print(json.dumps({
  "image": "${ECR_REPO_URI}:latest",
  "containerPort": 8080,
  "environment": [
    {"name": "MCP_HOST",         "value": "0.0.0.0"},
    {"name": "MCP_PORT",         "value": "8080"},
    {"name": "PYTHONUNBUFFERED", "value": "1"}
  ],
  "secrets": [
    {"name": "DEEPGRAM_API_KEY", "valueFrom": "${SECRET_ARN}"}
  ]
}))
PYEOF
)

# ── 15. deploy ECS Express Mode service ───────────────────────────────────────
step "Deploying ECS Express Mode service"
echo "  ECS Express Mode auto-provisions an ALB, HTTPS cert, and stable URL."

# Check if service already exists
EXISTING_SERVICE_ARN=$(aws ecs list-services \
  --cluster default --region "${REGION}" \
  --query "serviceArns[?contains(@, '${SERVICE_NAME}')]" \
  --output text 2>/dev/null | head -1 || true)

if [ -n "${EXISTING_SERVICE_ARN}" ]; then
  warn "Service '${SERVICE_NAME}' already exists — updating with new image..."
  aws ecs update-express-gateway-service \
    --service-arn "${EXISTING_SERVICE_ARN}" \
    --primary-container "${PRIMARY_CONTAINER}" \
    --execution-role-arn "${EXEC_ROLE_ARN}" \
    --health-check-path "/health" \
    --region "${REGION}" >/dev/null
  SERVICE_ARN="${EXISTING_SERVICE_ARN}"
  ok "Update triggered."
  # Give ECS time to begin rolling out the new revision before we start polling
  echo "  Waiting 30 s for rolling update to begin..."
  sleep 30
else
  SERVICE_ARN=$(aws ecs create-express-gateway-service \
    --service-name "${SERVICE_NAME}" \
    --primary-container "${PRIMARY_CONTAINER}" \
    --execution-role-arn "${EXEC_ROLE_ARN}" \
    --infrastructure-role-arn "${INFRA_ROLE_ARN}" \
    --health-check-path "/health" \
    --region "${REGION}" \
    --query "service.serviceArn" --output text)
  ok "ECS Express Mode service created: ${SERVICE_ARN}"
fi

# ── 16. wait for ACTIVE ────────────────────────────────────────────────────────
step "Waiting for service to become ACTIVE (typically 3–5 minutes)"
ATTEMPTS=36   # 36 × 10s = 6 minutes max
STATUS=""
for i in $(seq 1 ${ATTEMPTS}); do
  STATUS=$(aws ecs describe-express-gateway-service \
    --service-arn "${SERVICE_ARN}" --region "${REGION}" \
    --query "service.status.statusCode" --output text 2>/dev/null || echo "UNKNOWN")
  printf "  [%2d/%d] Service status: %s\n" "${i}" "${ATTEMPTS}" "${STATUS}"
  case "${STATUS}" in
    ACTIVE)   break ;;
    FAILED|\
    DELETING) err "Service failed to start (${STATUS}). Check ECS console."; exit 1 ;;
  esac
  sleep 10
done

if [ "${STATUS}" != "ACTIVE" ]; then
  err "Timed out waiting for ACTIVE. Last status: ${STATUS}"
  err "Check the ECS console for progress."
  exit 1
fi

# ── 17. get the public URL ─────────────────────────────────────────────────────
URL=$(aws ecs describe-express-gateway-service \
  --service-arn "${SERVICE_ARN}" --region "${REGION}" \
  --query "service.activeConfigurations[0].ingressPaths[?accessType=='PUBLIC'].endpoint | [0]" \
  --output text 2>/dev/null || echo "")

# Ensure https:// prefix
if [ -z "${URL}" ] || [ "${URL}" = "None" ] || [ "${URL}" = "null" ]; then
  err "Could not read the service URL. Run the describe command below to find it manually:"
  err "  aws ecs describe-express-gateway-service --service-arn ${SERVICE_ARN} --region ${REGION} --query \"service.activeConfigurations[0].ingressPaths\" --output json"
  exit 1
fi
[[ "${URL}" == https://* ]] || URL="https://${URL}"

MCP_URL="${URL%/}/mcp"

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Deployment complete!                                        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                               ║"
printf "║  MCP endpoint:  %-46s║\n" "${MCP_URL}"
echo "║                                                               ║"
echo "║  Steps to register in CyberArk SAIA (Idira):                 ║"
echo "║    1. Open SAIA → Register MCP server                         ║"
echo "║    2. Paste the URL above into 'Server URL'                   ║"
echo "║    3. Click Discover → Auth method should be 'None'           ║"
echo "║    4. Fill in name / category and click Register              ║"
echo "║                                                               ║"
printf "║  Health check:  %-46s║\n" "${URL%/}/health"
echo "║                                                               ║"
echo "║  Future deployments: git push origin main                     ║"
echo "║    → re-run  bash deploy.sh  to build & push new image        ║"
echo "║                                                               ║"
echo "║  To rotate the API key: re-run  bash deploy.sh                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
