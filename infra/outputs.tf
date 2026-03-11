output "bucket_name" {
  description = "S3 bucket used for Nextflow work, results, inputs, and config"
  value       = aws_s3_bucket.pipeline.id
}

output "ecr_repository_url" {
  description = "ECR repository URI (without tag) — use for docker tag/push"
  value       = aws_ecr_repository.head.repository_url
}

output "ecr_image_uri" {
  description = "Full ECR image URI including version tag"
  value       = local.ecr_image_uri
}

output "head_queue_name" {
  description = "Batch head job queue name"
  value       = aws_batch_job_queue.head.name
}

output "worker_queue_name" {
  description = "Batch worker job queue name"
  value       = aws_batch_job_queue.worker.name
}

output "job_definition_name" {
  description = "Batch job definition name for the head job"
  value       = aws_batch_job_definition.head.name
}

output "nextflow_config_s3_uri" {
  description = "S3 URI of the uploaded nextflow.config"
  value       = local.s3_config_uri
}

output "smoke_test_command" {
  description = "Copy-paste AWS CLI command to submit a smoke test run"
  value       = <<-EOT
    aws batch submit-job \
      --profile ${var.aws_profile} \
      --job-name "nf-demo-test-$(date +%Y%m%d-%H%M%S)" \
      --job-queue ${aws_batch_job_queue.head.name} \
      --job-definition ${aws_batch_job_definition.head.name} \
      --container-overrides '{"environment":[{"name":"NF_PIPELINE","value":"nf-core/demo"},{"name":"NF_REVISION","value":"1.1.0"},{"name":"NF_PROFILE","value":"test,docker"},{"name":"NF_OUTDIR","value":"s3://${aws_s3_bucket.pipeline.id}/results/test-run"},{"name":"NF_WORKDIR","value":"s3://${aws_s3_bucket.pipeline.id}/work"}]}'
  EOT
}
