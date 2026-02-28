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
resource "aws_batch_compute_environment" "worker" {
  compute_environment_name = var.worker_ce_name
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
