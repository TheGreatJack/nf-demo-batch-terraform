# nf-core/demo on AWS Batch — Terraform Deployment Guide

## Architecture

```
Event / Developer
     │
     │ aws batch submit-job  ──►  head queue
     ▼
┌─────────────────────────┐   submits worker jobs   ┌──────────────────────────┐
│  Head Compute Env (EC2) │ ───────────────────────► │  Worker Compute Env (EC2)│
│  t3.medium / m5.large   │                          │  optimal (m5/c5/r5)      │
│  [nextflow-head image]  │                          │  [FastQC/seqtk/MultiQC]  │
└─────────────────────────┘                          └──────────────────────────┘
                      ▲  reads / writes S3  ▲
                ┌─────┴────────────────────-┴──────┐
                │  S3 Bucket                        │
                │  ├── work/                        │
                │  ├── results/                     │
                │  ├── inputs/                      │
                │  └── config/                      │
                └───────────────────────────────────┘
```

Credentials flow: EC2 instance profile → ECS agent → container. No static keys needed on Batch nodes.

---

## Prerequisites

- **Terraform** ≥ 1.5 (`conda activate terraform`)
- **AWS CLI** v2 with SSO profile `affc_prof` configured
- **Docker** (for building and pushing the head image)

Log in to AWS SSO before running Terraform or Docker commands:

```bash
aws sso login --profile affc_prof
```

---

## 1. Deploy Infrastructure

```bash
cd terraform/infra

# Initialise providers
terraform init

# Preview changes (~23 resources)
terraform plan

# Apply (< 5 minutes on a fresh account)
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
ACCOUNT_ID=$(aws sts get-caller-identity --profile affc_prof --query Account --output text)

# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 --profile affc_prof | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Build from the docker/ directory
docker build -t nextflow-head:25.10.4 docker/

# Tag and push
docker tag nextflow-head:25.10.4 "${ECR_IMAGE}"
docker tag nextflow-head:25.10.4 "${ECR_REPO}:latest"
docker push "${ECR_IMAGE}"
docker push "${ECR_REPO}:latest"
```

---

## 3. Upload Inputs (optional — skip for smoke test)

For a custom run with your own FASTQs:

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

# Upload samplesheet
aws s3 cp samplesheet.csv s3://${BUCKET}/inputs/samplesheet.csv --profile affc_prof

# Upload FASTQ files
aws s3 cp sample_R1.fastq.gz s3://${BUCKET}/inputs/ --profile affc_prof
aws s3 cp sample_R2.fastq.gz s3://${BUCKET}/inputs/ --profile affc_prof
```

The `test` profile (used in the smoke test below) pulls nf-core's public test
data directly — no upload needed.

---

## 4. Run Smoke Test

The `smoke_test_command` output contains a fully rendered `aws batch submit-job`
command using the `test,docker` profile:

```bash
terraform -chdir=infra output -raw smoke_test_command
# Copy and paste the output command, then run it
```

Or run it directly:

```bash
eval "$(terraform -chdir=infra output -raw smoke_test_command)"
```

---

## 5. Monitor Execution

**Tail the head job logs:**
```bash
aws logs tail /aws/batch/job --follow --profile affc_prof \
  --log-stream-name-prefix "nextflow-head/"
```

**Check head job status:**
```bash
aws batch describe-jobs --jobs <JOB_ID> --profile affc_prof \
  --query "jobs[0].{status:status,reason:statusReason}"
```

**List worker jobs:**
```bash
aws batch list-jobs \
  --job-queue nextflow-demo-worker-queue \
  --job-status RUNNING --profile affc_prof
```

---

## 6. Validate Outputs

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

aws s3 ls s3://${BUCKET}/results/test-run/ --recursive --human-readable --profile affc_prof
```

Expected structure:
```
results/test-run/
├── fastqc/
│   ├── <sample>_fastqc.html
│   └── <sample>_fastqc.zip
├── seqtk/
│   └── <sample>_trimmed.fastq.gz
├── multiqc/
│   └── multiqc_report.html
└── pipeline_info/
    ├── execution_report.html
    ├── execution_timeline.html
    └── nextflow.log
```

Download the MultiQC report:
```bash
aws s3 cp s3://${BUCKET}/results/test-run/multiqc/multiqc_report.html . --profile affc_prof
```

---

## 7. Cleanup

**Empty the S3 bucket first** (required before destroy):
```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)
aws s3 rm s3://${BUCKET}/ --recursive --profile affc_prof
```

**Destroy all Terraform-managed resources:**
```bash
terraform -chdir=infra destroy
```

> **Note:** The `AWSServiceRoleForBatch` service-linked role is excluded from
> `terraform destroy` by default. Delete it manually in IAM if needed, or leave
> it — it has no cost.

---

## Known Gotchas

| Issue | Resolution |
|---|---|
| `Error: role already exists` on apply | Set `create_batch_service_linked_role = false` in `terraform.tfvars` |
| Compute environment stuck in `INVALID` | Verify `instance_role` uses the **instance profile ARN** (not the role ARN) — already correct in this config |
| Perpetual diff on `desired_vcpus` | `lifecycle { ignore_changes }` is already set on both CEs |
| Jobs stuck in `RUNNABLE` | Check security group allows outbound; check subnet has a route to the internet |
| ECR auth expired | Re-run `aws ecr get-login-password ...` — tokens last 12 hours |
| SSO token expired | Re-run `aws sso login --profile affc_prof` before long sessions |
| S3 bucket not empty on destroy | Run `aws s3 rm s3://<bucket>/ --recursive` before `terraform destroy` |
