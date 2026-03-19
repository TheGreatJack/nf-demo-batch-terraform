# ── Launch template for worker disk sizing ──────────────────────────────────
resource "aws_launch_template" "worker" {
  name_prefix = "nf-worker-"
  tags        = var.tags

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.worker_volume_size_gb
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }
}

# ── Head Compute Environment ─────────────────────────────────────────────────
resource "aws_batch_compute_environment" "head" {
  compute_environment_name = var.head_ce_name
  type                     = "MANAGED"
  state                    = "ENABLED"
  tags                     = var.tags

  compute_resources {
    type                = "EC2"
    allocation_strategy = "BEST_FIT_PROGRESSIVE"
    instance_type       = ["optimal"]
    min_vcpus           = 0
    desired_vcpus       = 0
    max_vcpus           = var.head_ce_max_vcpus
    instance_role       = aws_iam_instance_profile.batch_instance.arn
    subnets             = data.aws_subnets.public.ids
    security_group_ids  = [aws_security_group.batch.id]
    tags                = var.tags
  }

  depends_on = [
    aws_iam_service_linked_role.batch,
    aws_iam_role_policy_attachment.ecs_for_ec2,
  ]

  lifecycle {
    ignore_changes = [compute_resources[0].desired_vcpus]
  }
}

# ── Worker Compute Environment ────────────────────────────────────────────────
# Custom AL2023 ECS-optimized AMI with AWS CLI v2 at /opt/aws-cli/bin/aws.
# Built with Packer (docker/worker-ami/worker.pkr.hcl).
resource "aws_batch_compute_environment" "worker" {
  compute_environment_name_prefix = "${var.worker_ce_name}-"
  type                     = "MANAGED"
  state                    = "ENABLED"
  tags                     = var.tags

  compute_resources {
    type                = "EC2"
    allocation_strategy = "BEST_FIT_PROGRESSIVE"
    instance_type       = ["optimal"]
    min_vcpus           = 0
    desired_vcpus       = 0
    max_vcpus           = var.worker_ce_max_vcpus
    instance_role       = aws_iam_instance_profile.batch_instance.arn
    subnets             = data.aws_subnets.public.ids
    security_group_ids  = [aws_security_group.batch.id]
    image_id            = var.worker_ami_id
    tags                = var.tags

    launch_template {
      launch_template_id = aws_launch_template.worker.id
      version            = "$Latest"
    }
  }

  depends_on = [
    aws_iam_service_linked_role.batch,
    aws_iam_role_policy_attachment.ecs_for_ec2,
  ]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [compute_resources[0].desired_vcpus]
  }
}

# ── Head Job Queue ────────────────────────────────────────────────────────────
resource "aws_batch_job_queue" "head" {
  name     = var.head_queue_name
  state    = "ENABLED"
  priority = 1
  tags     = var.tags

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.head.arn
  }
}

# ── Worker Job Queue ──────────────────────────────────────────────────────────
resource "aws_batch_job_queue" "worker" {
  name     = var.worker_queue_name
  state    = "ENABLED"
  priority = 1
  tags     = var.tags

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.worker.arn
  }
}

# ── Head Job Definition ───────────────────────────────────────────────────────
resource "aws_batch_job_definition" "head" {
  name = var.job_definition_name
  type = "container"
  tags = var.tags

  container_properties = jsonencode({
    image  = local.ecr_image_uri
    vcpus  = var.head_job_vcpus
    memory = var.head_job_memory_mb

    environment = [
      { name = "NXF_CONFIG_S3", value = local.s3_config_uri },
      { name = "NF_WORKDIR", value = local.s3_workdir_uri },
      { name = "NF_PROFILE", value = "docker" },
      { name = "NF_PIPELINE", value = var.nf_pipeline },
      { name = "NF_REVISION", value = var.nf_revision },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "nextflow-head"
      }
    }
  })

  retry_strategy {
    attempts = 1
  }

  timeout {
    attempt_duration_seconds = var.head_job_timeout_seconds
  }
}
