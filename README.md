# Nextflow on AWS Batch — Terraform Deployment Guide

Run **any** Nextflow pipeline from GitHub on AWS Batch. This branch targets
**Nextflow 23.10.0** and uses the **Amazon Linux 2023 ECS-optimized AMI** for
worker instances (Docker + AWS CLI v2 included — no custom AMI build required).

## Architecture

```
Event / Developer
     │
     │ aws batch submit-job  ──►  head queue
     ▼
┌─────────────────────────┐   submits worker jobs   ┌──────────────────────────┐
│  Head Compute Env (EC2) │ ───────────────────────► │  Worker Compute Env (EC2)│
│  optimal                │                          │  optimal (m5/c5/r5)      │
│  [nextflow-head image]  │                          │  AL2023 ECS-optimized    │
└─────────────────────────┘                          └──────────────────────────┘
                      ▲  reads / writes S3  ▲
                ┌─────┴─────────────────────┴─────┐
                │  S3 Bucket                       │
                │  ├── work/                       │
                │  ├── results/                    │
                │  ├── inputs/                     │
                │  └── config/                     │
                └──────────────────────────────────┘
```

Credentials flow: EC2 instance profile → ECS agent → container. No static keys needed.

---

## AWS Services

| Service | Role in this deployment |
|---|---|
| **AWS Batch** | Two Compute Environments (head + worker), two Job Queues, one Job Definition |
| **EC2** | Instances launched by Batch; worker instances use AL2023 ECS-optimized AMI with configurable disk |
| **ECR** | Repository `nextflow-head` stores the Nextflow head container image |
| **ECS** | Managed implicitly by Batch to schedule and run containers on EC2 instances |
| **S3** | Work bucket for input staging, Nextflow work directory, results, and pipeline config |
| **IAM** | Batch service-linked role, EC2 instance role + profile, custom orchestrator policy |
| **CloudWatch Logs** | Log group `/aws/batch/job` captures head and worker job output (30-day retention) |
| **VPC / Networking** | Default VPC, public subnets (data sources), Security Group with egress-only rules |

---

## Prerequisites

- **Terraform** ≥ 1.5 (`mamba activate terraform`)
- **AWS CLI** v2 with SSO profile configured
- **Docker** (for building and pushing the head image)

Log in to AWS SSO before running Terraform or Docker commands:

```bash
aws sso login --profile your-aws-profile
```

---

## 1. Deploy Infrastructure

```bash
cd terraform/infra

# Initialise providers
terraform init

# Preview changes
terraform plan

# Apply
terraform apply
```

> **First-time account:** Leave `create_batch_service_linked_role = true` (default).
> If you see an error that the role already exists, set it to `false` in
> `terraform.tfvars` and re-apply.

---

## 2. Build & Push Docker Image

```bash
# Get the full ECR image URI from Terraform output
ECR_IMAGE=$(terraform -chdir=infra output -raw ecr_image_uri)
ECR_REPO=$(terraform -chdir=infra output -raw ecr_repository_url)
ACCOUNT_ID=$(aws sts get-caller-identity --profile your-aws-profile --query Account --output text)

# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 --profile your-aws-profile | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Build from the docker/ directory
docker build -t nextflow-head:23.10.0 docker/

# Tag and push
docker tag nextflow-head:23.10.0 "${ECR_IMAGE}"
docker tag nextflow-head:23.10.0 "${ECR_REPO}:latest"
docker push "${ECR_IMAGE}"
docker push "${ECR_REPO}:latest"
```

---

## 3. Upload Inputs (optional — skip for smoke test)

For a custom run with your own FASTQs:

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

# Upload samplesheet
aws s3 cp samplesheet.csv s3://${BUCKET}/inputs/samplesheet.csv --profile your-aws-profile

# Upload FASTQ files
aws s3 cp sample_R1.fastq.gz s3://${BUCKET}/inputs/ --profile your-aws-profile
aws s3 cp sample_R2.fastq.gz s3://${BUCKET}/inputs/ --profile your-aws-profile
```

The `test` profile (used in the smoke test below) pulls nf-core's public test
data directly — no upload needed.

---

## 4. Run a Pipeline

### Smoke test (nf-core/demo)

```bash
terraform -chdir=infra output -raw smoke_test_command
# Copy and paste the output command, then run it
```

### Run any pipeline

Submit a job with `--container-overrides` to specify the pipeline, revision, and
any extra Nextflow flags:

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

aws batch submit-job \
  --profile your-aws-profile \
  --job-name "rnaseq-run-$(date +%Y%m%d-%H%M%S)" \
  --job-queue $(terraform -chdir=infra output -raw head_queue_name) \
  --job-definition $(terraform -chdir=infra output -raw job_definition_name) \
  --container-overrides '{
    "environment": [
      {"name": "NF_PIPELINE",   "value": "nf-core/rnaseq"},
      {"name": "NF_REVISION",   "value": "3.14.0"},
      {"name": "NF_PROFILE",    "value": "test,docker"},
      {"name": "NF_OUTDIR",     "value": "s3://'"${BUCKET}"'/results/rnaseq-run"},
      {"name": "NF_WORKDIR",    "value": "s3://'"${BUCKET}"'/work"},
      {"name": "NF_EXTRA_ARGS", "value": "--max_memory 8.GB --max_cpus 4"}
    ]
  }'
```

### Environment variables reference

| Variable | Required | Description |
|---|---|---|
| `NF_PIPELINE` | Yes | Pipeline to run (e.g. `nf-core/rnaseq`, `nf-core/demo`) |
| `NF_REVISION` | No | Pipeline version/tag/branch (e.g. `3.14.0`). Omit for latest |
| `NF_PROFILE` | No | Nextflow profiles, comma-separated (default: `docker`) |
| `NF_OUTDIR` | Yes | S3 URI for results |
| `NF_WORKDIR` | Yes | S3 URI for Nextflow work directory |
| `NF_EXTRA_ARGS` | No | Additional flags appended to the `nextflow run` command |
| `NXF_CONFIG_S3` | No | S3 URI of a custom `nextflow.config` to download at runtime |
| `NF_INPUT` | No | S3 URI of an input samplesheet |

---

## 5. Monitor Execution

**Tail the head job logs:**
```bash
aws logs tail /aws/batch/job --follow --profile your-aws-profile \
  --log-stream-name-prefix "nextflow-head/"
```

**Check head job status:**
```bash
aws batch describe-jobs --jobs <JOB_ID> --profile your-aws-profile \
  --query "jobs[0].{status:status,reason:statusReason}"
```

**List worker jobs:**
```bash
aws batch list-jobs \
  --job-queue nextflow-demo-worker-queue \
  --job-status RUNNING --profile your-aws-profile
```

---

## 6. Validate Outputs

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

aws s3 ls s3://${BUCKET}/results/test-run/ --recursive --human-readable --profile your-aws-profile
```

Download the MultiQC report:
```bash
aws s3 cp s3://${BUCKET}/results/test-run/multiqc/multiqc_report.html . --profile your-aws-profile
```

---

## 7. Cleanup

**Empty the S3 bucket first** (required before destroy):
```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)
aws s3 rm s3://${BUCKET}/ --recursive --profile your-aws-profile
```

**Destroy all Terraform-managed resources:**
```bash
terraform -chdir=infra destroy
```

> **Note:** The `AWSServiceRoleForBatch` service-linked role is excluded from
> `terraform destroy` by default. Delete it manually in IAM if needed, or leave
> it — it has no cost.

---

## Tuning Worker Disk Size

Worker jobs run on EC2 instances with a configurable root EBS volume. If pipeline
steps fail with "No space left on device", increase the volume size:

```hcl
# terraform.tfvars
worker_volume_size_gb = 200   # default: 100 GB
```

Then run `terraform apply` to update the launch template. New instances will use
the larger volume; existing running instances are not affected.

---

## Known Gotchas

| Issue | Resolution |
|---|---|
| `Error: role already exists` on apply | Set `create_batch_service_linked_role = false` in `terraform.tfvars` |
| Compute environment stuck in `INVALID` | Verify `instance_role` uses the **instance profile ARN** (not the role ARN) — already correct in this config |
| Perpetual diff on `desired_vcpus` | `lifecycle { ignore_changes }` is already set on both CEs |
| Jobs stuck in `RUNNABLE` | Check security group allows outbound; check subnet has a route to the internet |
| Worker tasks fail: `aws: command not found` | Verify `cliPath` in `nextflow.config.tpl` matches the CLI location on the AMI (`/usr/local/bin/aws` for AL2023) |
| ECR auth expired | Re-run `aws ecr get-login-password ...` — tokens last 12 hours |
| SSO token expired | Re-run `aws sso login --profile your-aws-profile` before long sessions |
| S3 bucket not empty on destroy | Run `aws s3 rm s3://<bucket>/ --recursive` before `terraform destroy` |
