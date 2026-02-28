resource "aws_s3_bucket" "pipeline" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_object" "nextflow_config" {
  bucket  = aws_s3_bucket.pipeline.id
  key     = "config/nextflow.config"
  content = local.nextflow_config_content
  etag    = md5(local.nextflow_config_content)
  tags    = var.tags
}
