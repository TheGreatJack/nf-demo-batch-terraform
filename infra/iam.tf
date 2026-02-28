# 1. Batch service-linked role (only needed once per account)
resource "aws_iam_service_linked_role" "batch" {
  count            = var.create_batch_service_linked_role ? 1 : 0
  aws_service_name = "batch.amazonaws.com"
  tags             = var.tags
}

# 2. Custom orchestrator policy
resource "aws_iam_policy" "nextflow_orchestrator" {
  name        = "NextflowOrchestratorPolicy"
  description = "Minimum permissions for the Nextflow head node to orchestrate Batch jobs"
  tags        = var.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BatchControl"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs",
          "batch:CancelJob",
          "batch:TerminateJob",
          "batch:ListJobs",
          "batch:RegisterJobDefinition",
          "batch:DeregisterJobDefinition",
          "batch:DescribeJobDefinitions",
          "batch:DescribeJobQueues",
          "batch:DescribeComputeEnvironments",
          "batch:TagResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2AndECSDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceAttribute",
          "ecs:DescribeContainerInstances",
          "ecs:DescribeTasks",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRRead"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
      {
        Sid    = "S3WorkBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:PutObjectTagging",
        ]
        Resource = [
          "arn:aws:s3:::${local.bucket_name}",
          "arn:aws:s3:::${local.bucket_name}/*",
        ]
      },
    ]
  })
}

# 3. EC2 instance role
resource "aws_iam_role" "batch_instance" {
  name = "NextflowBatchInstanceRole"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 4. Policy attachments
resource "aws_iam_role_policy_attachment" "ecs_for_ec2" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "s3_full_access" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "nextflow_orchestrator" {
  role       = aws_iam_role.batch_instance.name
  policy_arn = aws_iam_policy.nextflow_orchestrator.arn
}

# 5. Instance profile (same name as role, per AWS convention)
resource "aws_iam_instance_profile" "batch_instance" {
  name = "NextflowBatchInstanceRole"
  role = aws_iam_role.batch_instance.name
  tags = var.tags
}
