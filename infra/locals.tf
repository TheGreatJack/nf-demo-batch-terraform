locals {
  account_id     = data.aws_caller_identity.current.account_id
  bucket_name    = "nf-demo-${local.account_id}-${var.aws_region}"
  ecr_image_uri  = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repository_name}:${var.nextflow_version}"
  s3_config_uri  = "s3://${local.bucket_name}/config/nextflow.config"
  s3_workdir_uri = "s3://${local.bucket_name}/work"

  # Rendered once, reused in aws_s3_object content + etag
  nextflow_config_content = templatefile("${path.module}/nextflow.config.tpl", {
    worker_queue_name = var.worker_queue_name
    aws_region        = var.aws_region
  })
}
