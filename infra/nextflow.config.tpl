// Managed by Terraform — do not edit directly
// Downloaded at runtime by entrypoint.sh via $NXF_CONFIG_S3

process {
    executor = 'awsbatch'
    queue    = '${worker_queue_name}'
}

aws {
    region = '${aws_region}'
    batch {
        cliPath             = '/home/ec2-user/aws-cli/bin/aws'
        maxParallelTransfers = 4
    }
}
// workDir is injected at runtime via -work-dir flag
