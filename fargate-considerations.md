# Fargate as an Alternative Compute Backend for AWS Batch

This document summarises what would change, what is gained, and what is lost if AWS
Fargate replaces EC2 as the compute backend for this Nextflow deployment.

---

## What Fargate changes in this project

| Area | Current (EC2) | Fargate |
|---|---|---|
| Compute type in both CEs | `"EC2"` | `"FARGATE"` or `"FARGATE_SPOT"` |
| Instance management | `instance_type`, `allocation_strategy`, `min/desired_vcpus` | Removed — AWS manages capacity |
| Custom worker AMI | Required (Packer build, `worker_ami_id`) | Removed — no host to customise |
| EC2 instance profile | Required (`aws_iam_instance_profile`) | Replaced by ECS task roles |
| IAM model | One instance role shared by all containers on a host | Two roles per task: execution role (agent) + job role (container) |
| Resource declaration in job definition | Top-level `vcpus` + `memory` fields | `resourceRequirements` array + `fargatePlatformConfiguration` |
| Disk space | Root EBS volume sized in the AMI or launch template | Ephemeral storage declared per task (default 20 GB, up to 200 GB) |
| AWS CLI in worker containers | Bind-mounted from host via `aws.batch.cliPath` | Must be inside the container — see below |

### Solving the AWS CLI problem on Fargate

On EC2, Nextflow bind-mounts the AWS CLI from the host into each worker container.
Fargate has no host, so this mechanism does not exist. Three alternatives:

1. **Fusion filesystem + Wave (recommended)** — Nextflow Fusion replaces `aws s3 cp`
   staging with a native S3 FUSE mount. Wave augments container images on-the-fly to
   inject the Fusion client, requiring no changes to the original tool images.
   Requires Nextflow ≥ 22.10 and a Wave service account (free tier available at
   wave.seqera.io).

2. **Bake AWS CLI v2 into each worker image** — Build derivative ECR images on top of
   each biocontainer (`FROM quay.io/biocontainers/fastqc:... + RUN install aws cli`).
   Practical for a small, stable set of containers like nf-core/demo. Becomes a
   maintenance burden at scale.

3. **ECS init container + shared ephemeral volume** — An init container copies the CLI
   binary to a shared volume before the main container starts. Requires pre-registered
   multi-container job definitions; Nextflow does not generate these natively.

---

## Advantages

**Operational simplicity**
- No AMI lifecycle to manage. The Packer build step and `worker_ami_id` variable are
  eliminated entirely.
- No ECS agent, Docker daemon, or host OS to patch or monitor.

**Security**
- Each Fargate task runs in its own AWS Firecracker microVM, providing stronger
  isolation than containers sharing an EC2 host.
- Per-task IAM job roles replace the broad instance-level role, reducing blast radius
  if a container is compromised.
- Each task gets its own elastic network interface (ENI), isolating network traffic at
  the task level.

**Cost model**
- Billed per second of actual vCPU + memory consumed per task. No idle EC2 capacity
  between workflow runs.
- `FARGATE_SPOT` can reduce worker compute costs by 50–70% for interruption-tolerant
  workloads. Nextflow's built-in retry logic handles spot interruptions gracefully.

**Scaling**
- Scales to zero automatically with no residual cost between runs.
- No instance provisioning delay for workers — tasks start as container capacity is
  available.

**Disk**
- Ephemeral storage is declared per task (up to 200 GB) rather than baked into an AMI
  or launch template, making it easy to adjust per process if needed.

---

## Limitations

**Resource ceiling per task**
- Maximum 16 vCPU and 120 GB RAM per Fargate task. This is sufficient for most
  nf-core processes but rules out memory-heavy jobs such as large-genome assembly or
  high-coverage alignment.

**No GPU support**
- Fargate does not support GPU instance types. Any Nextflow process requiring a GPU
  must run on an EC2-backed compute environment. A hybrid setup (Fargate for
  CPU tasks, EC2 for GPU tasks) is possible but adds configuration complexity.

**No persistent container layer cache**
- Fargate tasks do not share a Docker layer cache across runs. Large biocontainer
  images are pulled fresh for each task unless ECR pull-through cache is configured,
  which removes the inter-run download cost.

**Cost per vCPU-hour**
- Fargate on-demand pricing is higher per vCPU-hour than equivalently sized EC2
  instances. For sustained, high-throughput workloads that run continuously, EC2
  (especially Spot) may be more cost-effective. Fargate Spot narrows this gap
  significantly for batch workloads.

**Nextflow configuration changes required**
- Worker job definitions must include `fargatePlatformConfiguration`,
  `networkConfiguration`, and `resourceRequirements` in place of the flat `vcpus` and
  `memory` fields used today.
- The `aws.batch.cliPath` configuration in `nextflow.config` must be replaced by one
  of the approaches listed above.
