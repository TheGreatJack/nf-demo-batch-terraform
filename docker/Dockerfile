# Nextflow head job container
# Nextflow 23.10.0 + AWS CLI v2 on Amazon Corretto 17 (Java 17 LTS)
#
# Build:
#   docker build -t nextflow-head:23.10.0 .
#
# Run locally (for testing):
#   docker run --rm \
#     -e NF_PIPELINE=nf-core/demo \
#     -e NF_REVISION=1.1.0 \
#     -e NF_PROFILE=test,docker \
#     -e NF_OUTDIR=s3://my-bucket/results/test \
#     -e NF_WORKDIR=s3://my-bucket/work \
#     -e NXF_CONFIG_S3=s3://my-bucket/config/nextflow.config \
#     -e AWS_DEFAULT_REGION=us-east-1 \
#     -e NF_EXTRA_ARGS="--max_memory 8.GB --max_cpus 4" \
#     nextflow-head:23.10.0

FROM amazoncorretto:17-al2023

# Install dependencies
RUN dnf install -y --allowerasing \
        curl \
        unzip \
        bash \
        tar \
    && dnf clean all

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && aws --version

# Install Nextflow 23.10.0
ENV NXF_VER=23.10.0
RUN curl -fsSL https://github.com/nextflow-io/nextflow/releases/download/v${NXF_VER}/nextflow \
        -o /usr/local/bin/nextflow \
    && chmod +x /usr/local/bin/nextflow \
    && nextflow -version

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Nextflow JVM settings
ENV NXF_OPTS="-Xms512m -Xmx2g"
ENV NXF_ANSI_LOG=false

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
