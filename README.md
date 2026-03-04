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

## AWS Services

| Service | Role in this deployment |
|---|---|
| **AWS Batch** | Two Compute Environments (head + worker), two Job Queues, one Job Definition |
| **EC2** | Instances launched by Batch; head uses `t3.medium`/`m5.large`, worker uses `optimal` (m5/c5/r5) |
| **ECR** | Repository `nextflow-head` stores the Nextflow head container image |
| **ECS** | Managed implicitly by Batch to schedule and run containers on EC2 instances |
| **S3** | Work bucket for input staging, Nextflow work directory, results, and pipeline config |
| **IAM** | Batch service-linked role, EC2 instance role + profile, custom orchestrator policy |
| **CloudWatch Logs** | Log group `/aws/batch/job` captures head and worker job output (30-day retention) |
| **VPC / Networking** | Default VPC, public subnets (data sources), Security Group with egress-only rules |

---

## Prerequisites

- **Terraform** ≥ 1.5 (`conda activate terraform`)
- **AWS CLI** v2 with SSO profile `your-aws-profile` configured
- **Docker** (for building and pushing the head image)
- **Packer** ≥ 1.9 (for building the custom worker AMI)

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

# Preview changes (~23 resources)
terraform plan

# Apply (< 5 minutes on a fresh account)
terraform apply
```

> **First-time account:** Leave `create_batch_service_linked_role = true` (default).
> If you see an error that the role already exists, set it to `false` in
> `terraform.tfvars` and re-apply.

---

## 2. Build Worker AMI

Worker tasks need the AWS CLI to stage files to/from S3. The default ECS-optimised
AMI does not bundle the CLI in a path Nextflow can bind-mount into containers, so a
custom AMI is required. This step only needs to be repeated when you want to update
the CLI version; the same AMI survives `terraform destroy` / re-apply cycles.

```bash
cd docker/worker-ami

# Download the Packer Amazon provider plugin (one-time per machine)
packer init .

# Build (~6 min). micromamba installs AWS CLI v2 into /home/ec2-user/aws-cli
# with all shared libs (including libz) bundled inside the conda environment.
AWS_PROFILE=your-aws-profile packer build worker.pkr.hcl
# → AMI ID printed at the end, e.g.: ami-0bf22b7b00d741f55
```

Add the AMI ID to `infra/terraform.tfvars`, then re-apply to update the worker
Compute Environment:

```bash
echo 'worker_ami_id = "ami-0abc123..."' >> infra/terraform.tfvars
cd infra && terraform apply
```

Nextflow finds the CLI via `cliPath = '/home/ec2-user/aws-cli/bin/aws'` in
`nextflow.config` and automatically bind-mounts that directory into every worker
container — no changes to pipeline Docker images required.

---

## 3. Build & Push Docker Image

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
docker build -t nextflow-head:25.10.4 docker/

# Tag and push
docker tag nextflow-head:25.10.4 "${ECR_IMAGE}"
docker tag nextflow-head:25.10.4 "${ECR_REPO}:latest"
docker push "${ECR_IMAGE}"
docker push "${ECR_REPO}:latest"
```

---

## 4. Upload Inputs (optional — skip for smoke test)

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

## 5. Run Smoke Test

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

## 6. Monitor Execution

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

## 7. Validate Outputs

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

aws s3 ls s3://${BUCKET}/results/test-run/ --recursive --human-readable --profile your-aws-profile
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
aws s3 cp s3://${BUCKET}/results/test-run/multiqc/multiqc_report.html . --profile your-aws-profile
```

---

## 8. Cleanup

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

## Known Gotchas

| Issue | Resolution |
|---|---|
| Worker tasks fail: `libz.so.1: cannot open shared object file` | Worker containers don't ship zlib. Build the custom worker AMI (step 2) — `micromamba` bundles `libzlib` inside the conda env so it is available when Nextflow bind-mounts the `cliPath` directory |
| Worker tasks fail: `aws: command not found` | Custom worker AMI not applied. Add `worker_ami_id` to `terraform.tfvars` and run `terraform apply` |
| `Error: role already exists` on apply | Set `create_batch_service_linked_role = false` in `terraform.tfvars` |
| Compute environment stuck in `INVALID` | Verify `instance_role` uses the **instance profile ARN** (not the role ARN) — already correct in this config |
| Perpetual diff on `desired_vcpus` | `lifecycle { ignore_changes }` is already set on both CEs |
| Jobs stuck in `RUNNABLE` | Check security group allows outbound; check subnet has a route to the internet |
| ECR auth expired | Re-run `aws ecr get-login-password ...` — tokens last 12 hours |
| SSO token expired | Re-run `aws sso login --profile your-aws-profile` before long sessions |
| S3 bucket not empty on destroy | Run `aws s3 rm s3://<bucket>/ --recursive` before `terraform destroy` |
