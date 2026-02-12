#!/bin/bash
# deploy-shannon.sh - Shannon Bedrock One-Click Deployment
# Automates: IAM -> EC2 -> Shannon setup -> execution via SSM
# For authorized security testing only.
set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================
REGION="us-east-1"
INSTANCE_TYPE="t3.large"
MODEL="us.anthropic.claude-sonnet-4-20250514-v1:0"
ROLE_NAME="shannon-ec2-bedrock-role"
PROFILE_NAME="shannon-ec2-bedrock-profile"
REPO_NAME=""
INSTANCE_ID=""
TEARDOWN=false
GITHUB_REPO=""
GITHUB_BRANCH="main"
TARGET_URL=""
S3_SOURCE=""

# =============================================================================
# Usage
# =============================================================================
show_help() {
  cat << 'EOF'
Usage:
  ./deploy-shannon.sh \
    --github-repo <user/shannon> \
    --target-url <https://target-site.com> \
    --s3-source <s3://bucket/src.tar.gz> \
    [--github-branch <branch>] [options]

Required:
  --github-repo   GitHub repository (e.g. Frangke/shannon-bedrock)
  --target-url    Pentest target URL
  --s3-source     Target source code S3 path (tar.gz)

Options:
  --github-branch   Branch to clone (default: main)
  --repo-name       Folder name under repos/ (default: extracted from S3 filename)
  --model           Bedrock model ID (default: us.anthropic.claude-sonnet-4-20250514-v1:0)
  --region          AWS region (default: us-east-1)
  --instance-type   EC2 instance type (default: t3.large)
  --instance-id     Reuse existing EC2 instance (skip Phase 1)
  --teardown        Teardown mode: terminate EC2 + delete IAM resources

Teardown:
  ./deploy-shannon.sh --teardown --instance-id i-xxxxx [--region us-east-1]

Examples:
  ./deploy-shannon.sh \
    --github-repo Frangke/shannon-bedrock \
    --target-url https://juice-shop.example.com \
    --s3-source s3://my-bucket/juice-shop-src.tar.gz

  ./deploy-shannon.sh \
    --github-repo Frangke/shannon-bedrock \
    --target-url https://target.com \
    --s3-source s3://bucket/app.tar.gz \
    --repo-name my-app \
    --model us.anthropic.claude-sonnet-4-20250514-v1:0 \
    --instance-type t3.xlarge

  ./deploy-shannon.sh --teardown --instance-id i-0abc123def456
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-repo)   GITHUB_REPO="$2"; shift 2 ;;
    --github-branch) GITHUB_BRANCH="$2"; shift 2 ;;
    --target-url)    TARGET_URL="$2"; shift 2 ;;
    --s3-source)     S3_SOURCE="$2"; shift 2 ;;
    --repo-name)     REPO_NAME="$2"; shift 2 ;;
    --model)         MODEL="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --instance-id)   INSTANCE_ID="$2"; shift 2 ;;
    --teardown)      TEARDOWN=true; shift ;;
    --help|-h)       show_help; exit 0 ;;
    *) echo "ERROR: Unknown option: $1"; show_help; exit 1 ;;
  esac
done

# =============================================================================
# Helper: Run command on EC2 via SSM and wait for completion
# =============================================================================
ssm_run() {
  local instance_id="$1"
  local comment="$2"
  shift 2
  local commands=("$@")

  # Build JSON array for commands
  local commands_json="["
  local first=true
  for cmd in "${commands[@]}"; do
    if [ "$first" = false ]; then
      commands_json="${commands_json},"
    fi
    first=false
    # Escape quotes and backslashes in the command
    local escaped_cmd=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    commands_json="${commands_json}\"${escaped_cmd}\""
  done
  commands_json="${commands_json}]"

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "$comment" \
    --parameters "{\"commands\":${commands_json}}" \
    --output text \
    --query 'Command.CommandId')

  echo "  SSM command: $cmd_id ($comment)"

  # Wait for command to complete
  local status=""
  for i in $(seq 1 120); do
    status=$(aws ssm get-command-invocation \
      --region "$REGION" \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")

    case "$status" in
      Success) return 0 ;;
      Failed|TimedOut|Cancelled)
        echo "  ERROR: Command '$comment' failed with status: $status"
        aws ssm get-command-invocation \
          --region "$REGION" \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --query 'StandardErrorContent' --output text 2>/dev/null || true
        return 1
        ;;
    esac
    sleep 5
  done

  echo "  ERROR: Timed out waiting for command '$comment'"
  return 1
}

# =============================================================================
# Teardown Mode
# =============================================================================
if [ "$TEARDOWN" = true ]; then
  if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: --instance-id is required for --teardown"
    exit 1
  fi

  echo "=== Teardown Mode ==="
  echo ""

  echo "[1/3] Terminating EC2 instance: $INSTANCE_ID"
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --no-cli-pager || true
  echo "  Waiting for termination..."
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  echo "  Instance terminated."

  echo ""
  echo "[2/3] Removing IAM Instance Profile: $PROFILE_NAME"
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile \
    --instance-profile-name "$PROFILE_NAME" 2>/dev/null || true
  echo "  Instance profile deleted."

  echo ""
  echo "[3/3] Deleting IAM Role: $ROLE_NAME"
  # Detach managed policies
  aws iam detach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  # Delete inline policies
  aws iam delete-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name bedrock-invoke 2>/dev/null || true
  aws iam delete-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name s3-read 2>/dev/null || true
  # Delete role
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  echo "  IAM role deleted."

  echo ""
  echo "=== Teardown Complete ==="
  exit 0
fi

# =============================================================================
# Validate Required Arguments
# =============================================================================
if [ -z "$GITHUB_REPO" ] || [ -z "$TARGET_URL" ] || [ -z "$S3_SOURCE" ]; then
  echo "ERROR: --github-repo, --target-url, and --s3-source are required"
  echo ""
  show_help
  exit 1
fi

# Extract repo name from S3 path if not provided
if [ -z "$REPO_NAME" ]; then
  # s3://bucket/path/vuln-site-src.tar.gz -> vuln-site-src
  S3_BASENAME=$(basename "$S3_SOURCE")
  REPO_NAME="${S3_BASENAME%.tar.gz}"
  REPO_NAME="${REPO_NAME%.tgz}"
  echo "Auto-detected repo name: $REPO_NAME"
fi

# Extract S3 bucket for IAM policy
S3_BUCKET=$(echo "$S3_SOURCE" | sed 's|s3://\([^/]*\)/.*|\1|')

echo "=== Shannon Bedrock Deployment ==="
echo "  GitHub repo:   $GITHUB_REPO ($GITHUB_BRANCH)"
echo "  Target URL:    $TARGET_URL"
echo "  S3 source:     $S3_SOURCE"
echo "  Repo name:     $REPO_NAME"
echo "  Model:         $MODEL"
echo "  Region:        $REGION"
echo "  Instance type: $INSTANCE_TYPE"
if [ -n "$INSTANCE_ID" ]; then
  echo "  Reusing:       $INSTANCE_ID"
fi
echo ""

# =============================================================================
# Phase 1: AWS Infrastructure (skip if --instance-id provided)
# =============================================================================
if [ -z "$INSTANCE_ID" ]; then
  echo "=== Phase 1: AWS Infrastructure ==="
  echo ""

  # --- IAM Role (idempotent) ---
  echo "[1/3] Creating IAM Role: $ROLE_NAME"

  cat > /tmp/ec2-trust.json << 'TRUSTEOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUSTEOF

  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ec2-trust.json \
    --no-cli-pager 2>/dev/null || echo "  Role already exists, skipping creation."

  # SSM managed policy
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

  # Bedrock invoke policy
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name bedrock-invoke \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"bedrock:InvokeModel\",
            \"bedrock:InvokeModelWithResponseStream\"
          ],
          \"Resource\": \"arn:aws:bedrock:${REGION}::foundation-model/*\"
        }
      ]
    }"

  # S3 read policy for source code download
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name s3-read \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [
            \"s3:GetObject\",
            \"s3:ListBucket\"
          ],
          \"Resource\": [
            \"arn:aws:s3:::${S3_BUCKET}\",
            \"arn:aws:s3:::${S3_BUCKET}/*\"
          ]
        }
      ]
    }"

  # Instance profile
  aws iam create-instance-profile \
    --instance-profile-name "$PROFILE_NAME" 2>/dev/null || echo "  Profile already exists."
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || echo "  Role already attached."

  echo "  Waiting for IAM propagation (15s)..."
  sleep 15

  # --- EC2 Instance ---
  echo ""
  echo "[2/3] Launching EC2 Instance"

  UBUNTU_AMI=$(aws ec2 describe-images \
    --region "$REGION" --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

  echo "  AMI: $UBUNTU_AMI"

  USER_DATA=$(cat << 'UDEOF'
#!/bin/bash
set -e
# Disable automatic reboot
sed -i 's/Unattended-Upgrade::Automatic-Reboot "true"/Unattended-Upgrade::Automatic-Reboot "false"/' \
  /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

apt-get update
apt-get install -y ca-certificates curl gnupg git

# Docker installation
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Signal that setup is complete
touch /tmp/docker-setup-complete
UDEOF
  )

  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$UBUNTU_AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --iam-instance-profile Name="$PROFILE_NAME" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=shannon-pentest}]" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --user-data "$USER_DATA" \
    --query 'Instances[0].InstanceId' --output text)

  echo "  Instance ID: $INSTANCE_ID"

  # --- Wait for instance ---
  echo ""
  echo "[3/3] Waiting for instance to be ready"
  aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "  Instance is ready."
  echo ""
fi

# =============================================================================
# Phase 2: Shannon Setup (via SSM)
# =============================================================================
echo "=== Phase 2: Shannon Setup ==="
echo ""

# Wait for Docker to be ready (user-data may still be running)
echo "[1/5] Waiting for Docker installation..."
for i in $(seq 1 60); do
  DOCKER_OK=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["docker --version 2>/dev/null && echo DOCKER_READY || echo DOCKER_NOT_READY"]' \
    --output text --query 'Command.CommandId' 2>/dev/null) || true

  if [ -n "$DOCKER_OK" ]; then
    sleep 5
    RESULT=$(aws ssm get-command-invocation \
      --region "$REGION" \
      --command-id "$DOCKER_OK" \
      --instance-id "$INSTANCE_ID" \
      --query 'StandardOutputContent' --output text 2>/dev/null) || true

    if echo "$RESULT" | grep -q "DOCKER_READY"; then
      echo "  Docker is ready."
      break
    fi
  fi

  if [ "$i" -eq 60 ]; then
    echo "  ERROR: Timed out waiting for Docker"
    exit 1
  fi

  echo "  Docker not ready yet, retrying... ($i/60)"
  sleep 10
done

# Clone Shannon repo
echo ""
echo "[2/5] Cloning Shannon repository..."
ssm_run "$INSTANCE_ID" "git-clone" \
  "sudo -u ubuntu bash -c 'cd /home/ubuntu && rm -rf shannon && git clone -b ${GITHUB_BRANCH} https://github.com/${GITHUB_REPO}.git shannon'"

# Create .env with IMDS credentials
echo ""
echo "[3/5] Creating .env (Bedrock configuration)..."
ssm_run "$INSTANCE_ID" "create-env" \
  "sudo -u ubuntu bash -c 'cd /home/ubuntu/shannon && cat > .env << ENVEOF
CLAUDE_CODE_USE_BEDROCK=1
CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
AWS_REGION=${REGION}
ANTHROPIC_MODEL=${MODEL}
ENVEOF
'"

# Download source code from S3
echo ""
echo "[4/5] Downloading source code from S3..."
ssm_run "$INSTANCE_ID" "s3-download" \
  "sudo -u ubuntu bash -c 'cd /home/ubuntu/shannon && mkdir -p repos && aws s3 cp ${S3_SOURCE} /tmp/source.tar.gz --region ${REGION} && tar xzf /tmp/source.tar.gz -C repos/ && rm -f /tmp/source.tar.gz'"

# Fix permissions
echo ""
echo "[5/5] Setting permissions..."
ssm_run "$INSTANCE_ID" "fix-permissions" \
  "sudo -u ubuntu bash -c 'chmod -R 777 /home/ubuntu/shannon/repos/${REPO_NAME}/'"

echo ""

# =============================================================================
# Phase 3: Start Shannon
# =============================================================================
echo "=== Phase 3: Starting Shannon ==="
echo ""

# Start Shannon via SSM (runs in background)
START_CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "shannon-start" \
  --timeout-seconds 600 \
  --parameters "commands=[\"sudo -u ubuntu bash -c 'cd /home/ubuntu/shannon && ./shannon start URL=${TARGET_URL} REPO=${REPO_NAME}'\"]" \
  --output text --query 'Command.CommandId')

echo "  Shannon start command: $START_CMD_ID"
echo "  Waiting for workflow ID (this may take a few minutes while Docker images build)..."

# Wait for the start command to complete and capture output
for i in $(seq 1 120); do
  STATUS=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$START_CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")

  case "$STATUS" in
    Success)
      START_OUTPUT=$(aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$START_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' --output text 2>/dev/null)

      # Try to extract workflow ID from output
      WORKFLOW_ID=$(echo "$START_OUTPUT" | grep -oE '[a-zA-Z0-9._-]+_shannon-[0-9]+' | tail -1 || true)
      break
      ;;
    Failed|TimedOut|Cancelled)
      echo "  ERROR: Shannon start failed with status: $STATUS"
      aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$START_CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardErrorContent' --output text 2>/dev/null || true
      echo ""
      echo "  Debug: Check logs via SSM"
      echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
      exit 1
      ;;
  esac

  sleep 10
done

echo ""

# =============================================================================
# Phase 4: Output
# =============================================================================
echo "=== Phase 4: Deployment Complete ==="
echo ""
echo "  Instance ID:  $INSTANCE_ID"
echo "  Region:       $REGION"
if [ -n "${WORKFLOW_ID:-}" ]; then
  echo "  Workflow ID:  $WORKFLOW_ID"
fi
echo ""
echo "--- Monitor ---"
echo ""
echo "  # SSH via SSM"
echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
echo "  # View logs (inside SSM session)"
echo "  sudo su - ubuntu"
echo "  cd ~/shannon"
if [ -n "${WORKFLOW_ID:-}" ]; then
  echo "  ./shannon logs ID=$WORKFLOW_ID"
  echo "  ./shannon query ID=$WORKFLOW_ID"
fi
echo ""
echo "  # Temporal Web UI (via port forwarding)"
echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION \\"
echo "    --document-name AWS-StartPortForwardingSession \\"
echo "    --parameters '{\"portNumber\":[\"8233\"],\"localPortNumber\":[\"8233\"]}'"
echo "  # Then open: http://localhost:8233"
echo ""
echo "--- Download Results ---"
echo ""
echo "  # From inside SSM session:"
echo "  sudo su - ubuntu && cd ~/shannon"
echo "  tar czf /tmp/shannon-results.tar.gz audit-logs/"
echo "  aws s3 cp /tmp/shannon-results.tar.gz s3://${S3_BUCKET}/shannon-results.tar.gz"
echo ""
echo "  # Then from local machine:"
echo "  aws s3 cp s3://${S3_BUCKET}/shannon-results.tar.gz ./shannon-results.tar.gz"
echo ""
echo "--- Teardown ---"
echo ""
echo "  ./deploy-shannon.sh --teardown --instance-id $INSTANCE_ID --region $REGION"
