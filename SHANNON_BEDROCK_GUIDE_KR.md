# Shannon + AWS Bedrock 실행 가이드

> **[English version](./SHANNON_BEDROCK_GUIDE.md)**

> **경고: 이 가이드는 내부 보안 테스트 전용입니다.**
> 본인이 소유하거나 명시적으로 테스트 허가를 받은 시스템에만 사용하세요.
> 허가 없이 타인의 시스템에 펜테스트를 수행하는 것은 불법입니다.

Shannon AI 펜테스트 프레임워크를 AWS Bedrock으로 동작하도록 설정하고, EC2에서 실행하는 가이드입니다.

> Shannon 원본: https://github.com/KeygraphHQ/shannon

> **Shannon Lite는 화이트박스(소스코드 기반) 전용입니다.**
> Shannon은 타겟 애플리케이션의 소스코드에 접근할 수 있어야 합니다.
> `repos/<name>/` 디렉토리에 소스코드가 없으면 pre-recon 에이전트가 빈 디렉토리를 분석하다 실패합니다.
> 블랙박스(소스코드 없이 URL만으로) 테스트는 지원하지 않습니다.

## 아키텍처 개요

```mermaid
graph TB
    subgraph EC2["EC2 인스턴스 (Ubuntu, t3.large, IAM Role)"]
        subgraph Docker["Docker Compose"]
            Temporal[Temporal Server]
            Worker["Shannon Worker<br/>(claude-agent-sdk = Claude Code)"]
            Worker -->|통신| Temporal
            Worker -->|API 호출| Bedrock[AWS Bedrock API]
        end
    end

    style EC2 fill:#f9f9f9,stroke:#333,stroke-width:2px
    style Docker fill:#e8f4f8,stroke:#0066cc,stroke-width:2px
    style Temporal fill:#fff,stroke:#666,stroke-width:1px
    style Worker fill:#fff,stroke:#666,stroke-width:1px
    style Bedrock fill:#ff9900,stroke:#232f3e,stroke-width:2px,color:#fff
```

### 핵심 동작 원리

EC2에서 Docker Compose로 컨테이너(Temporal + Worker)를 실행합니다.
Shannon 코드는 Worker 컨테이너 안에서 동작하며, 환경변수 흐름은 다음과 같습니다:

```
EC2 호스트 (.env) → docker-compose.yml environment → Worker 컨테이너 → spawn된 cli.js
```

1. Shannon은 `@anthropic-ai/claude-agent-sdk`를 사용
2. SDK의 `query()` 함수가 번들된 `cli.js`(Claude Code)를 `child_process.spawn()`으로 실행
3. Shannon의 executor(`claude-executor.ts`)는 SDK에 `env`를 명시적으로 전달하지 않으므로, **Worker 컨테이너의 환경변수가 그대로 CLI 프로세스에 상속**됨
4. Claude Code(`cli.js`)는 `CLAUDE_CODE_USE_BEDROCK=1` 환경변수를 감지하여 Bedrock 모드로 진입
5. `cli.js`에 `@aws-sdk/credential-providers`가 이미 번들링되어 있어 별도 패키지 설치 불필요

### 프리패치 상태

이 fork에는 Bedrock 지원을 위한 소스 패치가 이미 적용되어 있습니다:

| 파일 | 패치 내용 |
|------|-----------|
| `docker-compose.yml` | worker에서 `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` 삭제. Bedrock/AWS 환경변수 추가 |
| `shannon` | API 키 검증에 Bedrock 모드 바이패스 추가 |
| `src/ai/claude-executor.ts` | 하드코딩된 모델명을 `process.env.ANTHROPIC_MODEL \|\| 'claude-sonnet-4-5-20250929'`로 변경 |

---

## 사전 요구사항

- AWS CLI 설치 및 설정 완료
- AWS 계정에 Bedrock Claude 모델 접근 권한 활성화 (us-east-1 리전)
- **타겟 애플리케이션의 소스코드** (S3에 tar.gz로 업로드)

---

## Quick Start: 원클릭 배포 (`deploy-shannon.sh`)

`deploy-shannon.sh` 스크립트 하나로 IAM Role 생성 → EC2 생성 → Shannon 설치 → 실행까지 모두 자동화합니다.

### Step 1: 타겟 애플리케이션 소스코드 S3 업로드

**중요:** Shannon 프레임워크 코드는 배포 시 GitHub에서 자동으로 clone됩니다.
사용자는 **테스트할 대상 애플리케이션의 소스코드만** S3에 업로드하면 됩니다.

타겟 애플리케이션의 소스코드를 tar.gz로 묶어 S3에 업로드합니다.

```bash
# 소스코드를 tar.gz로 묶기
cd /path/to/target-source
tar czf /tmp/vuln-site-src.tar.gz .

# S3에 업로드
aws s3 cp /tmp/vuln-site-src.tar.gz s3://your-bucket/vuln-site-src.tar.gz --region us-east-1
```

> macOS에서 `._` prefix 파일이 포함되는 게 신경 쓰인다면 `COPYFILE_DISABLE=1 tar czf ...` 사용.

### Step 2: 배포 실행

```bash
./deploy-shannon.sh \
  --github-repo Frangke/shannon-bedrock \
  --target-url https://target-site.com \
  --s3-source s3://your-bucket/vuln-site-src.tar.gz
```

스크립트가 자동으로 수행하는 작업:

| Phase | 내용 |
|-------|------|
| **Phase 1** | IAM Role 생성 (SSM + Bedrock + S3 권한), EC2 인스턴스 생성, 준비 대기 |
| **Phase 2** | Docker 설치 대기, **GitHub에서 Shannon clone**, .env 생성, **S3에서 타겟 앱 소스 다운로드**, 권한 설정 |
| **Phase 3** | `./shannon start` 실행, 워크플로우 ID 캡처 |
| **Phase 4** | 결과 출력 (워크플로우 ID, 모니터링 명령어, 다운로드 명령어) |

#### 전체 파라미터

| 파라미터 | 필수 | 기본값 | 설명 |
|---------|------|--------|------|
| `--github-repo` | O | - | GitHub 저장소 (예: `Frangke/shannon-bedrock`) |
| `--github-branch` | X | `main` | clone할 브랜치명 |
| `--target-url` | O | - | 펜테스트 대상 URL |
| `--s3-source` | O | - | 타겟 소스코드 S3 경로 (tar.gz) |
| `--repo-name` | X | S3 파일명에서 추출 | repos/ 하위 폴더명 |
| `--model` | X | `us.anthropic.claude-sonnet-4-20250514-v1:0` | Bedrock 모델 ID |
| `--region` | X | `us-east-1` | AWS 리전 |
| `--instance-type` | X | `t3.large` | EC2 인스턴스 타입 |
| `--instance-id` | X | - | 기존 EC2 재사용 시 인스턴스 ID (Phase 1 스킵) |
| `--teardown` | X | - | 리소스 정리 모드 |

#### 기존 인스턴스 재사용

이미 생성된 EC2가 있으면 `--instance-id`로 Phase 1을 건너뛸 수 있습니다.

```bash
./deploy-shannon.sh \
  --github-repo Frangke/shannon-bedrock \
  --target-url https://target-site.com \
  --s3-source s3://your-bucket/vuln-site-src.tar.gz \
  --instance-id i-0abc123def456
```

### Step 3: 모니터링

배포 완료 시 출력되는 명령어로 모니터링합니다.

```bash
# SSM으로 EC2 접속
aws ssm start-session --target <instance-id> --region us-east-1

# ubuntu 유저로 전환
sudo su - ubuntu
cd ~/shannon

# 로그 확인
./shannon logs ID=<workflow-id>
./shannon query ID=<workflow-id>

# Temporal Web UI (포트 포워딩)
aws ssm start-session --target <instance-id> --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8233"],"localPortNumber":["8233"]}'
# 브라우저에서 http://localhost:8233 접속
```

### Step 4: 결과 다운로드

Shannon은 결과물을 `repos/<name>/deliverables/`에 저장합니다.

```bash
# EC2 내부에서 (SSM 세션)
sudo su - ubuntu && cd ~/shannon
tar czf /tmp/shannon-results.tar.gz audit-logs/ repos/*/deliverables/
aws s3 cp /tmp/shannon-results.tar.gz s3://your-bucket/shannon-results.tar.gz

# 로컬에서
aws s3 cp s3://your-bucket/shannon-results.tar.gz ./shannon-results.tar.gz
tar xzf shannon-results.tar.gz
```

### Step 5: 정리 (Teardown)

```bash
./deploy-shannon.sh --teardown --instance-id <instance-id> --region us-east-1
```

EC2 인스턴스 종료 + IAM Role/Instance Profile 삭제를 자동으로 수행합니다.

---

## 수동 배포 (참고용)

자동 배포 스크립트를 사용하지 않고 직접 단계별로 실행하는 방법입니다.

### 1. IAM Role 생성 (SSM + Bedrock)

```bash
# Trust Policy 파일 생성
cat > /tmp/ec2-trust.json << 'EOF'
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
EOF

# IAM Role 생성
aws iam create-role \
  --role-name shannon-ec2-bedrock-role \
  --assume-role-policy-document file:///tmp/ec2-trust.json \
  --no-cli-pager

# SSM 관리 정책 연결
aws iam attach-role-policy \
  --role-name shannon-ec2-bedrock-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Bedrock 인라인 정책 추가
aws iam put-role-policy \
  --role-name shannon-ec2-bedrock-role \
  --policy-name bedrock-invoke \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ],
        "Resource": "arn:aws:bedrock:us-east-1::foundation-model/*"
      }
    ]
  }'

# Instance Profile 생성 및 Role 연결
aws iam create-instance-profile \
  --instance-profile-name shannon-ec2-bedrock-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name shannon-ec2-bedrock-profile \
  --role-name shannon-ec2-bedrock-role

echo "IAM 전파 대기 (15초)..."
sleep 15
```

### 2. EC2 인스턴스 생성

```bash
UBUNTU_AMI=$(aws ec2 describe-images \
  --region us-east-1 --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --region us-east-1 \
  --image-id $UBUNTU_AMI \
  --instance-type t3.large \
  --iam-instance-profile Name=shannon-ec2-bedrock-profile \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=shannon-pentest}]' \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
  --user-data '#!/bin/bash
sed -i "s/Unattended-Upgrade::Automatic-Reboot \"true\"/Unattended-Upgrade::Automatic-Reboot \"false\"/" /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
apt-get update
apt-get install -y ca-certificates curl gnupg git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu
' \
  --query 'Instances[0].InstanceId' --output text)

echo "인스턴스 ID: $INSTANCE_ID"
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID --region us-east-1
```

### 3. EC2 접속 및 Shannon 설정

```bash
aws ssm start-session --target $INSTANCE_ID --region us-east-1
```

접속 후:

```bash
sudo su - ubuntu

# Shannon 클론
git clone https://github.com/Frangke/shannon-bedrock.git ~/shannon
cd ~/shannon

# .env 생성 (IMDSv2에서 자격증명 가져오기)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME)

AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Token'])")

cat > .env << EOF
CLAUDE_CODE_USE_BEDROCK=1
CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
AWS_REGION=us-east-1
ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN
EOF
```

> `.env`에 `ANTHROPIC_API_KEY`를 **절대 넣지 마세요.**
> IMDS 임시 자격증명은 만료됩니다. 인증 오류 발생 시 위 명령어를 다시 실행하여 `.env`를 갱신하세요.

### 4. 소스코드 배치 및 실행

```bash
# S3에서 소스코드 다운로드
mkdir -p repos/vuln-site
aws s3 cp s3://your-bucket/vuln-site-src.tar.gz /tmp/
tar xzf /tmp/vuln-site-src.tar.gz -C repos/vuln-site/

# 권한 설정 (필수!)
chmod -R 777 repos/vuln-site/

# 실행
./shannon start URL=https://target-site.com REPO=vuln-site
```

### 5. 정리

```bash
# EC2 종료
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region us-east-1

# IAM 리소스 정리
aws iam remove-role-from-instance-profile \
  --instance-profile-name shannon-ec2-bedrock-profile \
  --role-name shannon-ec2-bedrock-role
aws iam delete-instance-profile \
  --instance-profile-name shannon-ec2-bedrock-profile
aws iam delete-role-policy \
  --role-name shannon-ec2-bedrock-role \
  --policy-name bedrock-invoke
aws iam detach-role-policy \
  --role-name shannon-ec2-bedrock-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role \
  --role-name shannon-ec2-bedrock-role
```

---

## Deliverables 확인

### 파일 위치

> Shannon은 결과물을 `repos/<name>/deliverables/`에 저장합니다.
> `audit-logs/` 폴더에는 세션 메타데이터, 에이전트 로그, 프롬프트 스냅샷만 저장됩니다.

```bash
ls ~/shannon/repos/vuln-site/deliverables/
```

### 생성되는 파일

| 파일 | 내용 | 생성 에이전트 |
|------|------|---------------|
| `comprehensive_security_assessment_report.md` | **최종 종합 보안 평가 리포트** | report |
| `code_analysis_deliverable.md` | 소스코드 정적 분석 결과 | pre-recon |
| `recon_deliverable.md` | 정찰 (엔드포인트, 인프라) 결과 | recon |
| `injection_analysis_deliverable.md` | SQL/Command Injection 분석 | injection-vuln |
| `injection_exploitation_evidence.md` | Injection 공격 증거 (PoC 포함) | injection-exploit |
| `xss_analysis_deliverable.md` | XSS 취약점 분석 | xss-vuln |
| `xss_exploitation_evidence.md` | XSS 공격 증거 (PoC 포함) | xss-exploit |
| `auth_analysis_deliverable.md` | 인증 취약점 분석 | auth-vuln |
| `auth_exploitation_evidence.md` | 인증 공격 증거 (PoC 포함) | auth-exploit |
| `authz_analysis_deliverable.md` | 인가 취약점 분석 | authz-vuln |
| `authz_exploitation_evidence.md` | 인가 공격 증거 (PoC 포함) | authz-exploit |
| `ssrf_analysis_deliverable.md` | SSRF 분석 | ssrf-vuln |

> 취약점 미발견 시 해당 exploit 에이전트는 자동 스킵됩니다.

### 실행 비용 참고

| 모델 | 예상 소요시간 | 예상 비용 |
|------|---------------|-----------|
| Claude Sonnet 4 (us.anthropic) | ~1.5시간 | ~$23 |
| Claude Sonnet 4.5 | ~1.5시간 | ~$50 |

> 비용은 타겟 애플리케이션의 복잡도에 따라 달라집니다.

---

## `ANTHROPIC_MODEL` 설정 가이드

Shannon 배포에 사용 가능한 Bedrock Claude 모델:

| 모델 ID | 모델 | 리전 타입 | 비고 |
|---------|------|-----------|------|
| `us.anthropic.claude-sonnet-4-20250514-v1:0` | Claude Sonnet 4 | 단일 리전 (`us.`) | CRIS 설정 불필요 |
| `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Claude Sonnet 4.5 | 단일 리전 (`us.`) | CRIS 설정 불필요 |
| `global.anthropic.claude-sonnet-4-5-20250929-v1:0` | Claude Sonnet 4.5 | 글로벌 라우팅 | AWS 콘솔에서 CRIS 활성화 필요 |
| `us.anthropic.claude-opus-4-20250514-v1:0` | Claude Opus 4 | 단일 리전 (`us.`) | 높은 비용, 최고 추론 능력 |
| `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Claude Haiku 4.5 | 단일 리전 (`us.`) | 낮은 비용, 빠르지만 능력 제한적 |

**Prefix 설명:**
- `us.` prefix: 단일 AWS 리전 라우팅, 별도 설정 없이 사용 가능
- `global.` prefix: Cross-Region Inference(CRIS) 사용, AWS 콘솔 > Bedrock > Model access에서 활성화 필요

**모델 선택:**
테스트 목적과 예산에 맞춰 선택하세요. 배포 전에 AWS 계정의 Bedrock 모델 액세스 설정에서 해당 모델이 활성화되어 있는지 확인하세요.

---

## 기술 레퍼런스

### cli.js 내부 모델 선택 흐름

```
모델 선택 (sl → jE 함수):
├─ A71(): query()의 model 파라미터 확인 → 있으면 그대로 사용 (최우선)
├─ process.env.ANTHROPIC_MODEL 확인 → 있으면 사용
└─ 없으면 → 기본 매핑 사용:
    ├─ bedrock provider: dZ0.bedrock = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
    └─ global. prefix → Cross-Region Inference(CRIS) 필요
```

> `claude-executor.ts`가 `process.env.ANTHROPIC_MODEL`을 `query({ model: ... })`로 전달하므로, `.env`의 `ANTHROPIC_MODEL` 값이 최우선으로 적용됩니다.

### cli.js 내부 Bedrock 인증 흐름

```
J$ 함수 (클라이언트 생성):
├─ CLAUDE_CODE_USE_BEDROCK=1 확인
├─ oA1() 호출 → Docker에선 settings 없음 → null
├─ fallback: new AnthropicBedrock(F) 생성
│   └─ 요청 시 fromNodeProviderChain() (번들 내장)
│       └─ fromEnv() → process.env.AWS_ACCESS_KEY_ID 읽음
└─ SigV4 서명 후 Bedrock API 호출
```

### 환경변수 주의사항

| 환경변수 | 주의 |
|----------|------|
| `ANTHROPIC_API_KEY` | **절대 설정하지 마세요.** 빈 문자열(`""`)이라도 존재하면 `cli.js`가 Bedrock 대신 Anthropic API로 요청합니다. |
| `ANTHROPIC_AUTH_TOKEN` | **worker에 설정하지 마세요.** SigV4 서명과 충돌할 수 있습니다. |
| `ANTHROPIC_BASE_URL` | **worker에 설정하지 마세요.** 설정되면 Bedrock endpoint 대신 해당 URL로 요청합니다. |

> 이 fork의 `docker-compose.yml`에서는 위 3개 환경변수가 worker 섹션에서 이미 제거되어 있습니다.
> router 서비스의 `ANTHROPIC_API_KEY`는 별도 서비스이므로 그대로 유지됩니다.

---

## 트러블슈팅

### 403 Authorization header requires 'Credential' parameter

Bedrock API에 SigV4 서명 없이 요청이 도달했다는 의미입니다.

**확인 순서:**

1. **컨테이너에 `ANTHROPIC_API_KEY`가 존재하는지 확인**
   ```bash
   docker compose exec worker node -e "console.log('ANTHROPIC_API_KEY:', JSON.stringify(process.env.ANTHROPIC_API_KEY))"
   ```
   `undefined`여야 합니다. `""` (빈 문자열)이라도 문제입니다.

2. **컨테이너에 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`이 존재하는지 확인**
   ```bash
   docker compose exec worker node -e "
     console.log('AUTH_TOKEN:', JSON.stringify(process.env.ANTHROPIC_AUTH_TOKEN));
     console.log('BASE_URL:', JSON.stringify(process.env.ANTHROPIC_BASE_URL));
   "
   ```
   둘 다 `undefined`여야 합니다.

3. **AWS 자격증명이 컨테이너에 전달되는지 확인**
   ```bash
   docker compose exec worker node -e "
     console.log('AWS_ACCESS_KEY_ID:', process.env.AWS_ACCESS_KEY_ID?.substring(0,8));
     console.log('AWS_SECRET_ACCESS_KEY:', process.env.AWS_SECRET_ACCESS_KEY ? 'SET' : 'MISSING');
     console.log('AWS_SESSION_TOKEN:', process.env.AWS_SESSION_TOKEN ? 'SET' : 'MISSING');
     console.log('AWS_REGION:', process.env.AWS_REGION);
     console.log('CLAUDE_CODE_USE_BEDROCK:', process.env.CLAUDE_CODE_USE_BEDROCK);
   "
   ```

### 400 The provided model identifier is invalid

`cli.js`가 잘못된 모델 ID로 Bedrock API를 호출하고 있습니다.

**원인:** `ANTHROPIC_MODEL`이 설정되지 않으면 기본값으로 `global.anthropic.claude-sonnet-4-5-20250929-v1:0`이 사용되며, CRIS가 활성화되지 않으면 에러가 발생합니다.

**해결:**
1. `.env`에 `ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0` 설정 확인
2. `docker-compose.yml`에 `ANTHROPIC_MODEL` 환경변수가 worker에 전달되는지 확인
3. 패치 후 `REBUILD=true`로 재시작 (TypeScript 재빌드 필요)

```bash
docker compose exec worker env | grep ANTHROPIC_MODEL
```

### 기타 문제

| 문제 | 해결 |
|------|------|
| `Activity task failed` (pre-recon) | **소스코드가 `repos/<name>/`에 있는지 확인.** Shannon은 화이트박스 전용이므로 빈 디렉토리면 실패합니다 |
| `docker: permission denied` | `newgrp docker` 또는 재접속 |
| `Cannot connect to Docker daemon` | `sudo systemctl start docker` |
| `ERROR: Set ANTHROPIC_API_KEY` | `.env`에 `CLAUDE_CODE_USE_BEDROCK=1`이 설정되어 있는지 확인 |
| `Repository not found at ./repos/...` | `mkdir -p repos/<name>` |
| `AccessDeniedException` | IAM Role에 `bedrock:InvokeModel` 권한 확인 |
| 모델 접근 불가 | AWS 콘솔 > Bedrock > Model access에서 Claude 모델 활성화 |
| 인증 실패 (실행 중 갑자기) | `.env`의 임시 자격증명 만료. IMDS에서 재발급 후 재시작 |
| 빌드 중 갑자기 리부팅 | Ubuntu 자동 보안 업데이트. user-data에 `Automatic-Reboot "false"` 설정 확인 |
| Docker build `permission denied` (audit-logs) | `sudo chown -R ubuntu:docker audit-logs && sudo chmod -R 755 audit-logs` 후 재시작 |
| `Validation failed: Missing required deliverable files` | `chmod -R 777 repos/<name>/` 후 재시작 |
