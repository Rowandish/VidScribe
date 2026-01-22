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
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│   EventBridge   │      │   EventBridge   │      │                 │
│   (every 12h)   │      │  (Sat 09:00)    │      │   SSM Params    │
└────────┬────────┘      └────────┬────────┘      │  (Config/Keys)  │
         │                        │               └────────┬────────┘
         ▼                        │                        │
┌─────────────────┐               │               ┌────────┴────────┐
│  Poller Lambda  │───────────────┼───────────────│   DynamoDB      │
│  (YouTube API)  │               │               │ (Videos/Summaries)
└────────┬────────┘               │               └────────┬────────┘
         │                        │                        │
         ▼                        ▼                        │
┌─────────────────┐      ┌─────────────────┐               │
│   SQS Queue     │      │Newsletter Lambda│◄──────────────┘
│   + DLQ         │      │   (HTML email)  │
└────────┬────────┘      └────────┬────────┘
         │                        │
         ▼                        ▼
┌─────────────────┐      ┌─────────────────┐
│Processor Lambda │      │    AWS SES      │
│(Transcript+LLM) │      │   (Email)       │
└─────────────────┘      └─────────────────┘
```

**Key Features:**
- 🔒 **Security**: Least privilege IAM, encrypted secrets in SSM
- 💰 **Cost**: 100% Free Tier compatible
- 🛡️ **Resilience**: SQS with DLQ, automatic retries
- 📊 **Monitoring**: CloudWatch alarms, SNS notifications
- 🚀 **CI/CD**: Automated deployment via GitHub Actions

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
llm_model    = "gemini-1.5-flash"  # or "llama-3.1-70b-versatile"
```

### Step 4: Set API Keys

**Linux/Mac (Bash):**
```bash
export TF_VAR_youtube_api_key="YOUR_YOUTUBE_API_KEY"
export TF_VAR_llm_api_key="YOUR_GEMINI_OR_GROQ_API_KEY"
```

**Windows (PowerShell):**
```powershell
$env:TF_VAR_youtube_api_key="YOUR_YOUTUBE_API_KEY"
$env:TF_VAR_llm_api_key="YOUR_GEMINI_OR_GROQ_API_KEY"
```

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

Optional repository variables:

| Variable | Description |
|----------|-------------|
| `SENDER_EMAIL` | SES-verified sender email |
| `DESTINATION_EMAIL` | Newsletter recipient email |
| `ADMIN_EMAIL` | Error notification email |

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
```

---

## 🛠️ Troubleshooting

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
│   ├── poller/               # YouTube polling Lambda
│   ├── processor/            # Transcript + LLM Lambda
│   └── newsletter/           # Email newsletter Lambda
├── scripts/
│   ├── setup.sh              # Bootstrap automation (Linux/Mac)
│   ├── setup.ps1             # Bootstrap automation (Windows)
│   ├── build_layers.sh       # Lambda layer builder (Linux/Mac)
│   └── build_layers.ps1      # Lambda layer builder (Windows)
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
