# AWS log retention for the ECS benchmark

**Inspected / updated:** 2026-10-01, `us-east-1`

## Current AWS behavior

- There is no CloudTrail Trail or CloudTrail Lake event data store configured for this account/region. CloudTrail Event History keeps management events for its built-in 90 days; this retention is not configurable and does not require an S3/CloudWatch archive.
- The ECS benchmark did not have a CloudWatch Logs group or `awslogs` task logging configuration. It collected standard ECS CPU metrics and temporary target-tracking alarms; those alarms are removed with the scaling policy. Standard service metrics are not log-group storage and have no per-metric expiration knob to set here.
- Two unrelated Lambda log groups initially had no retention policy: `/aws/lambda/lambda-nodejs-sqlite3-efs-api` (~43 KB stored) and `/aws/lambda/lambda-rust-sqlite3-efs-api` (~25 KB). Both now have seven-day retention, applied explicitly and verified on 2026-10-01. They are not owned by this benchmark's OpenTofu stack.

## Benchmark policy

Each run provisions `/ecs/ecs-mi-benchmark/<run-id>` with CloudWatch Logs retention set to **7 days**, and configures the parking API task to send stdout/stderr to that group. The run script exports its events to ignored `results/<run-id>-app-logs.json` before teardown. A successful OpenTofu destroy deletes the per-run group, leaving the local archive; if cleanup fails, the seven-day retention limits the lifetime of the leftover log group.

No CloudTrail Trail or CloudTrail Lake archive is added for this transient load test. The free Event History remains the audit record. Any future request for a persistent trail should define retention/lifecycle on its destination explicitly before enabling it.

## Account-level Lambda setting — applied

The approved seven-day policy was applied only to these two groups and read back successfully:

```bash
aws logs put-retention-policy --region us-east-1 \
  --log-group-name /aws/lambda/lambda-nodejs-sqlite3-efs-api \
  --retention-in-days 7

aws logs put-retention-policy --region us-east-1 \
  --log-group-name /aws/lambda/lambda-rust-sqlite3-efs-api \
  --retention-in-days 7
```

CloudWatch Logs expires events older than the retention period asynchronously; the existing stored-byte totals need not drop immediately. No policy was applied to any other log group. No CloudTrail Trail or event data store was created, and the benchmark-specific CloudWatch log group has not yet been provisioned in AWS.
