resource "aws_security_group" "batch" {
  name        = "nextflow-batch-sg"
  description = "Batch EC2 instances for Nextflow demo - no inbound, all outbound"
  vpc_id      = data.aws_vpc.default.id
  tags        = { Name = "nextflow-batch-sg" }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── Private Subnets ──────────────────────────────────────────────────────────
# Batch instances are placed here — no public IPs, outbound via NAT gateway.
locals {
  private_subnet_count = 3
  private_subnet_cidrs = [
    "172.31.96.0/20",  # us-east-1a
    "172.31.112.0/20", # us-east-1b
    "172.31.128.0/20", # us-east-1c
  ]
}

resource "aws_subnet" "private" {
  count                   = local.private_subnet_count
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "nextflow-batch-private-${data.aws_availability_zones.available.names[count.index]}" }
}

# ── NAT Gateway (single-AZ for cost savings) ─────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "nextflow-batch-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = tolist(data.aws_subnets.public.ids)[0]
  tags          = { Name = "nextflow-batch-nat" }
}

# ── Route Table for Private Subnets ───────────────────────────────────────────
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id
  tags   = { Name = "nextflow-batch-private-rt" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  count          = local.private_subnet_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── S3 Gateway Endpoint (free — avoids NAT charges for S3 traffic) ───────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "nextflow-batch-s3-endpoint" }
}
