variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = null
}

variable "nextflow_version" {
  description = "Nextflow version tag used for the ECR image"
  type        = string
  default     = "25.10.4"
}

variable "head_ce_name" {
  description = "Name of the head compute environment"
  type        = string
  default     = "nextflow-demo-head-ce"
}

variable "worker_ce_name" {
  description = "Name of the worker compute environment"
  type        = string
  default     = "nextflow-demo-worker-ce"
}

variable "head_queue_name" {
  description = "Name of the head job queue"
  type        = string
  default     = "nextflow-demo-head-queue"
}

variable "worker_queue_name" {
  description = "Name of the worker job queue"
  type        = string
  default     = "nextflow-demo-worker-queue"
}

variable "job_definition_name" {
  description = "Name of the Batch job definition for the head job"
  type        = string
  default     = "nextflow-head-job"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the head container image"
  type        = string
  default     = "nextflow-head"
}

variable "log_group_name" {
  description = "CloudWatch log group name for Batch jobs"
  type        = string
  default     = "/aws/batch/job"
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 30
}

variable "head_ce_max_vcpus" {
  description = "Maximum vCPUs for the head compute environment"
  type        = number
  default     = 4
}

variable "worker_ce_max_vcpus" {
  description = "Maximum vCPUs for the worker compute environment"
  type        = number
  default     = 12
}

variable "head_job_vcpus" {
  description = "vCPUs allocated to the head Batch job"
  type        = number
  default     = 2
}

variable "head_job_memory_mb" {
  description = "Memory (MB) allocated to the head Batch job"
  type        = number
  default     = 4096
}

variable "head_job_timeout_seconds" {
  description = "Timeout in seconds for the head Batch job"
  type        = number
  default     = 3600
}

variable "create_batch_service_linked_role" {
  description = "Set to false if the AWSServiceRoleForBatch role already exists in the account"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "nf-core-demo"
    ManagedBy   = "Terraform"
    Environment = "dev"
  }
}

variable "worker_ami_id" {
  description = "Custom AMI ID for worker compute environment instances (must have AWS CLI at /home/ec2-user/aws-cli/bin/aws). Leave null to use the AWS-managed default."
  type        = string
  default     = null
}
