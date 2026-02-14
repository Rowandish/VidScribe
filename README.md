# VidScribe 📺✉️

**Automated YouTube Newsletter Service** - Monitor YouTube channels, summarize new videos with AI, and receive a weekly email digest.

![AWS](https://img.shields.io/badge/AWS-Serverless-orange?logo=amazon-aws)
![Terraform](https://img.shields.io/badge/IaC-Terraform-purple?logo=terraform)
![Python](https://img.shields.io/badge/Python-3.11-blue?logo=python)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 🎯 What is VidScribe?

VidScribe is a serverless application that:

1. **Monitors** your favorite YouTube channels every 12 hours
2. **Downloads** transcripts from new videos
3. **Summarizes** them using AI (Gemini or Groq)
4. **Sends** you a beautiful weekly newsletter every Saturday

Perfect for staying up-to-date with educational content, tech news, or any YouTube channels without spending hours watching videos.

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                  VidScribe                                   │
│        Monitor YouTube → Transcript → LLM Summary → Weekly Email Digest       │
└──────────────────────────────────────────────────────────────────────────────┘

                (SSM Parameter Store: runtime configuration)
      ┌─────────────────────────────────────────────────────────────┐
      │ /vidscribe/youtube_channels   (JSON list of channel IDs)     │
      │ /vidscribe/llm_config         (model/provider + settings)    │
      │ /vidscribe/destination_email  (newsletter recipient)         │
      │ /vidscribe/sender_email       (SES-verified sender)          │
      └─────────────────────────────────────────────────────────────┘


1) Poll new videos (every 12h)
───────────────────────────────────────────────────────────────────────────────
            ┌─────────────────────┐
            │ EventBridge (12h)   │
            └─────────┬───────────┘
                      │
                      v
            ┌─────────────────────┐
            │ Lambda: Poller      │
            │ - read channels     │
            │ - YouTube API:      │
            │   publishedAfter    │
            │   (last 24h only)   │
            └─────────┬───────────┘
                      │
        checks idempotency in DynamoDB (videoId as key, TTL 30d)
                      │
          ┌───────────┴───────────┐
          │ new video?            │
          │ (not already stored)  │
          └───────┬───────────────┘
                  │ yes
                  v
      ┌───────────────────────────────┐
      │ SQS: video-queue              │
      │ - 1 msg = 1 videoId           │
      │ - retries + DLQ (maxReceive=3)│
      └──────────────┬────────────────┘
                     │
                     v
2) Process videos (on demand, per message)
───────────────────────────────────────────────────────────────────────────────
      ┌───────────────────────────────┐
      │ Lambda: Processor             │
      │ - triggered by SQS (batch=1)  │
      │ - fetch transcript            │
      │   (youtube-transcript-api)    │
      │ - call external LLM API       │
      │   (Gemini / Groq via REST)    │
      │ - store summary in DynamoDB   │
      └──────────────┬────────────────┘
                     │
                     v
      ┌───────────────────────────────┐
      │ DynamoDB: vidscribe-videos    │
      │ - PK: videoId                 │
      │ - transcript + summary        │
      │ - publishedAt / processedAt   │
      │ - TTL: auto-cleanup (30 days) │
      └───────────────────────────────┘

   (failures)
      ┌───────────────────────────────┐
      │ SQS DLQ: video-dlq            │
      │ - messages that exceeded      │
      │   retry policy                │
      └───────────────────────────────┘


3) Weekly newsletter (Saturday 09:00)
───────────────────────────────────────────────────────────────────────────────
            ┌─────────────────────────┐
            │ EventBridge (Sat 09:00) │
            └───────────┬─────────────┘
                        │
                        v
            ┌─────────────────────────┐
            │ Lambda: Newsletter      │
            │ - query DynamoDB for    │
            │   last 7 days summaries │
            │ - render HTML digest    │
            │ - send via AWS SES      │
            └───────────┬─────────────┘
                        │
                        v
            ┌─────────────────────────┐
            │ Email Inbox (recipient) │
            └─────────────────────────┘


Observability & alerts
───────────────────────────────────────────────────────────────────────────────
   ┌───────────────────────────┐        ┌───────────────────────────┐
   │ CloudWatch Log Groups     │        │ SNS Alerts Topic          │
   │ - 1 per Lambda            │        │ - email notifications     │
   │ - retention: 7 days       │        │   on failures/alarms      │
   └───────────────────────────┘        └───────────────────────────┘

```

**Key Features:**
- 🔒 **Security**: Least privilege IAM, encrypted secrets in SSM
- 💰 **Cost**: 100% Free Tier compatible
- 🛡️ **Resilience**: SQS with DLQ, automatic retries, NO_TRANSCRIPT retry logic (3 attempts over 5 days)
- 🧹 **Maintenance**: Monthly automated cleanup of permanently failed records
- 📊 **Monitoring**: CloudWatch alarms, SNS notifications
- 🚀 **CI/CD**: Automated deployment via GitHub Actions
- 🛠️ **Management**: Unified CLI tool for channels, newsletter, errors, logs, and more

---

## 📋 Prerequisites

Before you begin, ensure you have:

1. **AWS Account** with admin access
2. **AWS CLI** installed and configured (`aws configure`)
3. **Terraform** >= 1.0.0 installed
4. **Python** 3.11+ (for local testing)
5. **Git** for cloning and version control

### API Keys Required

| Service | Purpose | How to Get |
|---------|---------|------------|
| **YouTube Data API v3** | Fetch channel videos | [Google Cloud Console](https://console.cloud.google.com/apis/library/youtube.googleapis.com) |
| **Gemini API** | AI summarization | [Google AI Studio](https://aistudio.google.com/app/apikey) |
| **Groq API** (alternative) | AI summarization | [Groq Console](https://console.groq.com/keys) |
| **Webshare Proxy** | Avoid IP blocking | [Webshare Dashboard](https://www.webshare.io/) |
| **Gmail App Password** | Optional: Send via Gmail | [Google Account](https://myaccount.google.com/apppasswords) |

> **Warning**: YouTube frequently blocks requests arising from cloud IPs (like AWS Lambda). It is **highly recommended** to use a rotating residential proxy like Webshare. See [youtube-transcript-api workaround](https://github.com/jdepoix/youtube-transcript-api?tab=readme-ov-file#working-around-ip-bans-requestblocked-or-ipblocked-exception) for details.

### 🖥️ Windows vs Linux/Mac

This project supports both **Windows (PowerShell)** and **Linux/Mac (Bash)** for local development:

| Files | Windows | Linux/Mac/CI |
|-------|---------|-------------|
| Setup script | `scripts/setup.ps1` | `scripts/setup.sh` |
| Layer builder | `scripts/build_layers.ps1` | `scripts/build_layers.sh` |

**Windows users**: Add `use_windows_scripts = true` to your `terraform.tfvars` to use PowerShell scripts during Terraform operations.

**GitHub Actions**: Always uses Bash (Ubuntu), so no configuration needed for CI/CD.

---

## 🚀 Quick Start

### Step 1: Clone the Repository

```bash
git clone https://github.com/yourusername/VidScribe.git
cd VidScribe
```

### Step 2: Bootstrap Terraform State

First, create the S3 bucket and DynamoDB table for Terraform state:

```bash
cd infra/bootstrap

# Initialize and apply
terraform init
terraform apply -var="bucket_name=YOUR-UNIQUE-BUCKET-NAME" -var="aws_region=eu-west-1"
```

> **Note**: The bucket name must be globally unique across all AWS accounts.

### Step 3: Configure Your Settings

```bash
cd ../  # Back to infra/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# WINDOWS USERS: Uncomment the next line to use PowerShell scripts
# use_windows_scripts = true

# Required: Email Configuration
sender_email      = "your-verified-email@example.com"
destination_email = "recipient@example.com"
admin_email       = "admin@example.com"

# Required: YouTube Channels to Monitor
youtube_channels = "[\"CHANNEL_ID_1\", \"CHANNEL_ID_2\"]"

# LLM Configuration (choose one)
llm_provider = "gemini"  # or "groq"
llm_model    = "gemini-flash-latest"  # or "llama-3.1-70b-versatile"
summarization_language = "Italian"

# Optional: Residential Proxy (Recommended)
# webshare_username = "..."
# webshare_password = "..."

# Optional: Gmail SMTP (instead of SES)
# use_gmail_smtp     = true
# gmail_sender       = "user@gmail.com"
# gmail_app_password = "xxxx xxxx xxxx xxxx"
```

> [!TIP]
> **GitHub Actions Users**: Since `terraform.tfvars` is not committed to Git, you should set your preferred language as a **Repository Variable** in GitHub (Settings -> Secrets and variables -> Actions -> Variables) with the name `SUMMARIZATION_LANGUAGE`.

### Step 4: Set API Keys

**Linux/Mac (Bash):**
```bash
export TF_VAR_youtube_api_key="YOUR_YOUTUBE_API_KEY"
export TF_VAR_llm_api_key="YOUR_GEMINI_OR_GROQ_API_KEY"
export TF_VAR_webshare_username="YOUR_WEBSHARE_USERNAME"
export TF_VAR_webshare_password="YOUR_WEBSHARE_PASSWORD"
```

**Windows (PowerShell):**
```powershell
$env:TF_VAR_youtube_api_key="YOUR_YOUTUBE_API_KEY"
$env:TF_VAR_llm_api_key="YOUR_GEMINI_OR_GROQ_API_KEY"
$env:TF_VAR_webshare_username="YOUR_WEBSHARE_USERNAME"
$env:TF_VAR_webshare_password="YOUR_WEBSHARE_PASSWORD"
```

> **Note:** Webshare credentials are **never** stored in SSM. Provide them locally via the `TF_VAR_webshare_*` exports above and configure GitHub secrets named `WEBSHARE_USERNAME` and `WEBSHARE_PASSWORD` so Terraform can inject the values into Lambda without persisting them elsewhere.

### Step 5: Deploy

```bash
# Initialize Terraform with remote state
terraform init \
  -backend-config="bucket=YOUR-UNIQUE-BUCKET-NAME" \
  -backend-config="dynamodb_table=vidscribe-terraform-lock" \
  -backend-config="region=eu-west-1"

# Review the plan
terraform plan

# Deploy!
terraform apply
```

### Step 6: Verify Email Addresses

After deployment, check your email for verification links from AWS SES:
- Sender email address
- Recipient email address (if different)

> **Important**: In SES sandbox mode, both sender AND recipient must be verified.

---

## ⚙️ Configuration

### Finding YouTube Channel IDs

1. Go to the YouTube channel page
2. Click "About" → "Share" → "Copy channel ID"
3. Or extract from URL: `youtube.com/channel/CHANNEL_ID`

### Updating Configuration After Deployment

You can update settings without redeploying:

```bash
# Update YouTube channels
aws ssm put-parameter \
  --name "/vidscribe/youtube_channels" \
  --value '["UCnew123", "UCother456"]' \
  --type String \
  --overwrite

# Update API keys
aws ssm put-parameter \
  --name "/vidscribe/youtube_api_key" \
  --value "new-api-key" \
  --type SecureString \
  --overwrite
```

---

## 🔧 GitHub Actions Setup

For automated deployments, configure the following secrets in your GitHub repository:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS IAM access key |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform state |
| `TF_LOCK_TABLE` | DynamoDB table name (usually `vidscribe-terraform-lock`) |
| `TF_VAR_YOUTUBE_API_KEY` | YouTube Data API key |
| `TF_VAR_LLM_API_KEY` | Gemini or Groq API key |
| `WEBSHARE_USERNAME` | Webshare proxy username (optional) |
| `WEBSHARE_PASSWORD` | Webshare proxy password (optional) |
| `GENERIC_PROXY_HTTP_URL` | Alternative proxy HTTP URL (optional, format: `http://user:pass@host:port`) |
| `GENERIC_PROXY_HTTPS_URL` | Alternative proxy HTTPS URL (optional) |
| `GMAIL_APP_PASSWORD` | Gmail app password for SMTP (optional) |

Repository variables:

| Variable | Description |
|----------|-------------|
| `SENDER_EMAIL` | SES-verified sender email |
| `DESTINATION_EMAIL` | Newsletter recipient email |
| `ADMIN_EMAIL` | Error notification email |
| `SUMMARIZATION_LANGUAGE` | Language for summaries (default: English) |
| `PROXY_TYPE` | Proxy type: `webshare`, `generic`, or `none` |
| `USE_GMAIL_SMTP` | Set to `true` to use Gmail instead of SES |
| `GMAIL_SENDER` | Gmail address to send from |

---

## 💰 Cost Estimation

VidScribe is designed to stay within AWS Free Tier limits:

| Service | Free Tier | VidScribe Usage |
|---------|-----------|-----------------|
| Lambda | 1M requests, 400K GB-s | ~200 invocations/month |
| DynamoDB | 25 RCU, 25 WCU | Minimal (on-demand) |
| SQS | 1M requests | ~100 messages/month |
| CloudWatch | 5GB logs, 10 alarms | Well under |
| SES | 62K emails (from EC2) | 4 emails/month |
| EventBridge | Free | 2 rules |
| SSM Parameter Store | 10,000 parameters | 6 parameters |

**Estimated Cost: $0.00/month** (within Free Tier)

### API Costs

- **YouTube Data API**: 10,000 units/day free (~100 channel checks/day)
- **Gemini API**: 15 RPM, 1M tokens/day free
- **Groq API**: Very generous free tier

---

## 🧪 Testing

### Run Unit Tests

```bash
# Install development dependencies
pip install -r requirements-dev.txt

# Run tests
pytest tests/ -v

# Run with coverage report
pytest tests/ -v --cov=src --cov-report=html
```

### Manual Testing

```bash
# Invoke the Poller Lambda manually
aws lambda invoke \
  --function-name vidscribe-prod-poller \
  --payload '{}' \
  output.json && cat output.json

# Check SQS queue
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages

# View CloudWatch logs
aws logs tail /aws/lambda/vidscribe-prod-poller --follow

# Manual Video Processing
# Windows:
.\scripts\vidscribe.ps1 -Urls "https://youtube.com/watch?v=jH9BCOpL_bY"
# Linux/Mac:
./scripts/vidscribe.sh "https://youtube.com/watch?v=jH9BCOpL_bY"

# Process multiple videos:
.\scripts\vidscribe.ps1 -Urls "video1","video2" -SkipNewsletter

# Test newsletter only:
.\scripts\vidscribe.ps1 -TestNewsletter
```

---

## 🛠️ Management Tool

VidScribe includes a unified management tool for all operations. Available as both **PowerShell** and **Bash** scripts.

### Quick Start

```powershell
# PowerShell (Windows)
.\scripts\manage.ps1 help

# Bash (Linux/Mac)
./scripts/manage.sh help
```

### Commands

| Command | Description |
|---------|-------------|
| `channels list` | List monitored channels with resolved names |
| `channels add <ID>` | Add a YouTube channel |
| `channels remove <ID>` | Remove a channel |
| `channels clear` | Remove all channels |
| `newsletter frequency <f>` | Set newsletter schedule (`daily`, `weekly`, `monthly`) |
| `newsletter test [URL]` | Send a test newsletter |
| `errors` | Show failed videos, DLQ depth, and Lambda errors |
| `logs <function>` | Tail CloudWatch logs (`poller`, `processor`, `newsletter`, `cleanup`) |
| `apikeys update` | Interactive API key update wizard |
| `info` | Full system status dashboard |
| `cleanup run` | Manually trigger DynamoDB cleanup |
| `cleanup status` | Show permanently failed record count |
| `retry list` | Show videos awaiting transcript retry |

### Examples

```powershell
# Add a channel
.\scripts\manage.ps1 channels add "UCBcRF18a7Qf58cCRy5xuWwQ"

# Change newsletter to daily
.\scripts\manage.ps1 newsletter frequency daily

# View processor logs (last 100 lines)
.\scripts\manage.ps1 logs processor -Lines 100

# Check system health
.\scripts\manage.ps1 errors -DaysBack 14

# View full system info
.\scripts\manage.ps1 info
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `-Lines` / `--lines` | 50 | Number of log lines to show |
| `-DaysBack` / `--days-back` | 7 | Days to look back for errors |
| `-ProjectName` / `--project` | vidscribe | Project name prefix |
| `-Stage` / `--stage` | prod | Deployment stage |

---

## 🔄 NO_TRANSCRIPT Retry Logic

When a video fails with `NO_TRANSCRIPT`, VidScribe automatically retries up to **3 times** over **5 days**:

| Attempt | Day | Action |
|---------|-----|--------|
| 1 | Day 1 | First transcript download attempt |
| 2 | Day 3 | Automatic retry via Poller |
| 3 | Day 5 | Final retry attempt |

If all 3 attempts fail, the video is marked as `PERMANENTLY_FAILED` with reason `NO_TRANSCRIPT_EXHAUSTED`.

### Monthly Cleanup

A dedicated **Cleanup Lambda** runs on the 1st of each month to delete `PERMANENTLY_FAILED` records older than 30 days. You can also trigger it manually:

```powershell
.\scripts\manage.ps1 cleanup run
```

---

## 🔧 Troubleshooting

### Common Issues

**1. "No transcripts available"**
- Some videos have transcripts disabled
- Videos in non-English may not have translated transcripts
- Very new videos might not have transcripts yet

**2. "SES email not sending"**
- Verify both sender and recipient emails in SES
- Check if you're in SES sandbox (need to request production access for unrestricted sending)

**3. "YouTube API quota exceeded"**
- Check your quota at [Google Cloud Console](https://console.cloud.google.com/apis/api/youtube.googleapis.com/quotas)
- Reduce the number of channels or polling frequency

**4. "LLM API errors"**
- Verify your API key is correct
- Check the provider's status page for outages
- Ensure you haven't exceeded rate limits

### Viewing Logs

```bash
# Poller logs
aws logs tail /aws/lambda/vidscribe-prod-poller --since 1h

# Processor logs
aws logs tail /aws/lambda/vidscribe-prod-processor --since 1h

# Newsletter logs
aws logs tail /aws/lambda/vidscribe-prod-newsletter --since 1d
```

### Checking DLQ for Failed Messages

```bash
aws sqs receive-message \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --max-number-of-messages 10
```

---

## 📁 Project Structure

```
VidScribe/
├── infra/                    # Terraform IaC
│   ├── bootstrap/            # State bucket setup
│   ├── backend.tf            # S3 backend config
│   ├── cloudwatch.tf         # Logs and alarms
│   ├── dynamodb.tf           # Video/summary storage
│   ├── eventbridge.tf        # Scheduled triggers
│   ├── iam.tf                # Least privilege roles
│   ├── lambda.tf             # Lambda functions
│   ├── locals.tf             # Local values
│   ├── outputs.tf            # Terraform outputs
│   ├── providers.tf          # AWS provider
│   ├── ses.tf                # Email sending
│   ├── sns.tf                # Error alerts
│   ├── sqs.tf                # Message queue + DLQ
│   ├── ssm.tf                # Config/secrets
│   └── variables.tf          # Input variables
├── src/
│   ├── poller/               # YouTube polling + retry requeue Lambda
│   ├── processor/            # Transcript + LLM Lambda (with retry logic)
│   ├── newsletter/           # Email newsletter Lambda
│   └── cleanup/              # Monthly DynamoDB cleanup Lambda
├── scripts/
│   ├── manage.ps1            # 🛠️ Unified management tool (PowerShell)
│   ├── manage.sh             # 🛠️ Unified management tool (Bash)
│   ├── vidscribe.ps1         # Video processing workflow (PowerShell)
│   ├── vidscribe.sh          # Video processing workflow (Bash)
│   ├── monitor_errors.ps1    # Error monitoring (PowerShell)
│   ├── monitor_errors.sh     # Error monitoring (Bash)
│   ├── setup.ps1             # Bootstrap automation (Windows)
│   ├── setup.sh              # Bootstrap automation (Linux/Mac)
│   ├── build_layers.ps1      # Lambda layer builder (Windows)
│   └── build_layers.sh       # Lambda layer builder (Linux/Mac)
├── tests/                    # Pytest unit tests
├── .github/workflows/        # CI/CD pipeline
└── README.md                 # This file
```

---

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- [youtube-transcript-api](https://github.com/jdepoix/youtube-transcript-api) for transcript downloading
- [Google Gemini](https://ai.google.dev/) and [Groq](https://groq.com/) for AI summarization
- [Terraform](https://www.terraform.io/) for Infrastructure as Code
- [moto](https://github.com/getmoto/moto) for AWS mocking in tests

---

<p align="center">
  Made with ❤️ for YouTube enthusiasts who value their time
</p>
