resource "aws_security_group" "batch" {
  name        = "nextflow-batch-sg"
  description = "Batch EC2 instances for Nextflow demo - no inbound, all outbound"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(var.tags, { Name = "nextflow-batch-sg" })

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
