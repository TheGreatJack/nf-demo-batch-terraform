# Nextflow on AWS Batch — Terraform Deployment Guide

Run **any** Nextflow pipeline from GitHub on AWS Batch. This branch targets
**Nextflow 23.10.0** and uses a **custom AL2023 ECS-optimized AMI** with a
self-contained AWS CLI v2 installed via micromamba at `/opt/aws-cli/bin/aws`
(required because Nextflow bind-mounts the grandparent of `cliPath` into worker
containers — paths under `/usr` shadow container contents).

## Architecture

```
Event / Developer
     |
     |  aws batch submit-job  -->  head queue
     v
+---------------------------+   submits worker jobs   +----------------------------+
|  Head Compute Env (EC2)   | ----------------------> |  Worker Compute Env (EC2)  |
|  optimal                  |                         |  optimal (m5/c5/r5)        |
|  [nextflow-head image]    |                         |  Custom AL2023 AMI         |
+---------------------------+                         +----------------------------+
            |                                                    |
            |   Private Subnets (no public IPs)                  |
            +------- 172.31.96/112/128.0/20 ---------------------+
                         |                     |
                    NAT Gateway           S3 VPC Endpoint
                    (outbound)            (free, no NAT cost)
                         |
                    Internet Gateway
                         |
                +-----------------+
                |  S3 Bucket      |
                |  +-- work/      |
                |  +-- results/   |
                |  +-- inputs/    |
                |  +-- config/    |
                +-----------------+

State Management:
  S3 bucket  (onionomics-tfstate-<ACCOUNT>-<REGION>) + use_lockfile = true
  Deployed once via bootstrap/ before the main infra.
```

Credentials flow: EC2 instance profile -> ECS agent -> container. No static keys needed.

---

## AWS Services

| Service | Role in this deployment |
|---|---|
| **AWS Batch** | Two Compute Environments (head + worker), two Job Queues, one Job Definition |
| **EC2** | Instances launched by Batch in private subnets; worker instances use a custom AL2023 AMI with configurable disk |
| **ECR** | Repository `nextflow-head` stores the Nextflow head container image (immutable tags) |
| **ECS** | Managed implicitly by Batch to schedule and run containers on EC2 instances |
| **S3** | Work bucket for input staging, Nextflow work directory, results, and pipeline config |
| **IAM** | Batch service-linked role, EC2 instance role + profile, least-privilege orchestrator policy |
| **CloudWatch Logs** | Log group `/aws/batch/job` captures head and worker job output (30-day retention) |
| **VPC / Networking** | Default VPC, 3 private subnets, NAT Gateway (single-AZ), S3 VPC Gateway Endpoint, egress-only Security Group |
| **DynamoDB** | State-locking table for Terraform remote backend (created by bootstrap) |

---

## Prerequisites

- **Terraform** >= 1.5 (`mamba activate terraform`)
- **AWS CLI** v2 with SSO profile configured
- **Docker** (for building and pushing the head image)
- **Packer** >= 1.9 (for building the custom worker AMI)

Log in to AWS SSO before running any commands:

```bash
aws sso login --profile your-aws-profile
```

---

## 0. Bootstrap Remote State (one-time per account)

The main infrastructure uses an S3 backend for Terraform state with DynamoDB
locking. You must create these resources **before** deploying the infra.

```bash
cd bootstrap

# Initialise providers
terraform init

# Apply — creates the S3 state bucket and DynamoDB lock table
terraform apply -var='aws_profile=your-aws-profile'
```

This creates:
- **S3 bucket:** `onionomics-tfstate-<ACCOUNT_ID>-<REGION>` (versioned, encrypted, public access blocked)
- **DynamoDB table:** `onionomics-tfstate-lock` (PAY_PER_REQUEST)

Note the output values:

```bash
terraform output
# state_bucket_name = "onionomics-tfstate-123456789012-us-east-1"
# lock_table_name   = "onionomics-tfstate-lock"
```

### Configure the infra backend

Open `infra/main.tf` and update the `backend "s3"` block with your actual values:

```hcl
backend "s3" {
  bucket       = "onionomics-tfstate-<YOUR_ACCOUNT_ID>-us-east-1"  # from bootstrap output
  key          = "batch/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true
  encrypt      = true
  profile      = "your-aws-profile"
}
```

> **Important:** The bootstrap state itself is stored locally (in
> `bootstrap/terraform.tfstate`). This file is gitignored but should be backed
> up or kept on a secure machine. Losing it makes the bootstrap resources
> harder to manage (though they can be imported).

---

## 1. Deploy Infrastructure

```bash
cd infra

# Copy the example tfvars file and edit it
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your aws_profile, worker_ami_id, etc.

# Initialise providers and the remote backend
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

## 2. Build Worker AMI

Worker tasks need the AWS CLI to stage files to/from S3. Nextflow bind-mounts the
grandparent directory of `cliPath` into every worker container — if the CLI lives
under `/usr`, this shadows critical container binaries. The custom AMI installs a
fully self-contained AWS CLI (via micromamba) at `/opt/aws-cli/bin/aws`, which is
safe to mount.

```bash
cd docker/worker-ami

# Download the Packer Amazon provider plugin (one-time per machine)
packer init .

# Build (~6 min). micromamba installs AWS CLI v2 + all shared libs at /opt/aws-cli
AWS_PROFILE=your-aws-profile packer build worker.pkr.hcl
# -> AMI ID printed at the end, e.g.: ami-031fa1e1f97828470
```

Add the AMI ID to `infra/terraform.tfvars`, then re-apply to update the worker
Compute Environment:

```bash
# In infra/terraform.tfvars, set:
#   worker_ami_id = "ami-0abc123..."
cd infra && terraform apply
```

This step only needs to be repeated when you want to update the CLI version; the
same AMI survives `terraform destroy` / re-apply cycles.

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
docker build -t nextflow-head:23.10.0 docker/

# Tag and push
docker tag nextflow-head:23.10.0 "${ECR_IMAGE}"
docker push "${ECR_IMAGE}"
```

> **Note:** ECR image tags are immutable. If you need to push an updated image
> with the same Nextflow version, use the `image_tag_suffix` variable (e.g.,
> set it to a git short SHA) to produce a unique tag like `23.10.0-a1b2c3d`.

---

## 4. Upload Inputs (optional -- skip for smoke test)

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

## 5. Run a Pipeline

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
  --job-queue onionomics-worker-queue \
  --job-status RUNNING --profile your-aws-profile
```

---

## 7. Validate Outputs

```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)

aws s3 ls s3://${BUCKET}/results/test-run/ --recursive --human-readable --profile your-aws-profile
```

Download the MultiQC report:
```bash
aws s3 cp s3://${BUCKET}/results/test-run/multiqc/multiqc_report.html . --profile your-aws-profile
```

---

## 8. Cleanup

### Destroy the main infrastructure

**Empty the S3 pipeline bucket first** (required before destroy):
```bash
BUCKET=$(terraform -chdir=infra output -raw bucket_name)
aws s3 rm s3://${BUCKET}/ --recursive --profile your-aws-profile
```

**Destroy all infra resources:**
```bash
terraform -chdir=infra destroy
```

### Destroy the bootstrap (optional)

Only do this if you are tearing down the entire project and no other Terraform
configurations share the state bucket.

```bash
# Empty the state bucket first
STATE_BUCKET=$(terraform -chdir=bootstrap output -raw state_bucket_name)
aws s3 rm s3://${STATE_BUCKET}/ --recursive --profile your-aws-profile

terraform -chdir=bootstrap destroy -var='aws_profile=your-aws-profile'
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

## Project Structure

```
bootstrap/            # One-time remote state setup (S3 + DynamoDB)
  main.tf             #   State bucket, versioning, encryption, lock table
  variables.tf        #   aws_region, aws_profile
  outputs.tf          #   state_bucket_name, lock_table_name
infra/                # Main infrastructure
  main.tf             #   Provider config, S3 backend (use_lockfile = true)
  variables.tf        #   All configurable inputs (19 variables)
  locals.tf           #   Derived values (account ID, bucket name, ECR URI)
  data.tf             #   VPC, subnets, availability zones
  networking.tf       #   Private subnets, NAT gateway, S3 VPC endpoint, SG
  iam.tf              #   Instance role, orchestrator policy, instance profile
  batch.tf            #   Compute environments, job queues, job definition
  ecr.tf              #   ECR repository, lifecycle policy
  s3.tf               #   Pipeline bucket, nextflow.config upload
  cloudwatch.tf       #   Log group
  outputs.tf          #   11 key outputs (bucket, queues, smoke test, etc.)
  nextflow.config.tpl #   Nextflow config template for Batch executor
  terraform.tfvars.example
docker/
  Dockerfile          #   Nextflow head image (Corretto 17 + AWS CLI v2)
  entrypoint.sh       #   Head job orchestration script
  worker-ami/
    worker.pkr.hcl    #   Packer build for AL2023 AMI with AWS CLI
```

---

## Known Gotchas

| Issue | Resolution |
|---|---|
| `Error: role already exists` on apply | Set `create_batch_service_linked_role = false` in `terraform.tfvars` |
| Compute environment stuck in `INVALID` | Verify `instance_role` uses the **instance profile ARN** (not the role ARN) — already correct in this config |
| Perpetual diff on `desired_vcpus` | `lifecycle { ignore_changes }` is already set on both CEs |
| Jobs stuck in `RUNNABLE` | Check NAT gateway is healthy; instances in private subnets need NAT for outbound access (except S3, which uses the VPC endpoint) |
| Worker tasks fail: `aws: command not found` | Verify `cliPath` in `nextflow.config.tpl` matches the CLI location on the AMI (`/opt/aws-cli/bin/aws`) |
| Worker tasks fail: `libz.so.1: cannot open shared object file` | The AWS CLI must be installed via micromamba (not the official installer) so shared libs are bundled. Rebuild the worker AMI with `packer build` |
| Worker tasks fail: `/usr/local/env-execute: no such file or directory` | `cliPath` is under `/usr/local` or `/usr`, causing Nextflow to shadow container contents. Use the custom AMI with CLI at `/opt/aws-cli` |
| ECR push fails: tag already exists | ECR uses immutable tags. Set `image_tag_suffix` in `terraform.tfvars` to a unique value (e.g., git short SHA) and re-apply |
| ECR auth expired | Re-run `aws ecr get-login-password ...` — tokens last 12 hours |
| SSO token expired | Re-run `aws sso login --profile your-aws-profile` before long sessions |
| S3 bucket not empty on destroy | Run `aws s3 rm s3://<bucket>/ --recursive` before `terraform destroy` |
| `terraform init` fails on backend | Run bootstrap first (Step 0); ensure the S3 bucket and DynamoDB table exist |
