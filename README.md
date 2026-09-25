# terraform-aws-architecture-serverless

Terraform module for a serverless application architecture — a
CloudFront distribution over a private S3 origin for static content, two
Lambda functions for compute, and a DynamoDB table for state —
assembled from this family's single-purpose modules.

## Cost

This architecture is the cheap end of what a composition in this family
can stand up, because almost everything in it is billed per request
rather than per hour. At the defaults there are no standing compute
charges at all: Lambda bills per gigabyte-second, DynamoDB is on-demand
and costs nothing when idle, and CloudFront bills per request and per
gigabyte served. What does accrue regardless of traffic is small and
fixed — one customer managed KMS key, six CloudWatch alarms, an SNS
topic, a Secrets Manager secret, the S3 storage the content and log
buckets occupy, and a backup vault holding daily recovery points.

The two costs that surprise people are logs and egress. CloudWatch Logs
bills for ingestion as well as storage, which is why `log_retention_days`
defaults to 30 rather than leaving AWS's indefinite default in place, and
`price_class` defaults to `PriceClass_100` because the cheapest edge
footprint is almost always the right starting point. Setting
`waf_rate_limit` adds a WAF web ACL, which carries a real monthly charge
per ACL plus a per-request charge, so it is off by default. Set
`monthly_budget` so a forecast overrun reaches you.

## Design

Every resource comes from a published module in this family, resolved
from the Terraform Registry under a `~> 1.0` version constraint. This
module contains no `resource` blocks of its own; it is wiring and
nothing else. Read any individual module's README to
understand what it creates and why its defaults are what they are.

### What it builds

| Layer | Contents |
|---|---|
| Edge | CloudFront distribution, HTTP/3, SPA-style 403 and 404 rewrites to the root object, access logs to S3, optional CloudFront-scoped WAF rate limit |
| Content | Private S3 bucket for static assets and a second S3 bucket for Lambda deployment archives, both encrypted with the architecture's own KMS key and logging to a third bucket |
| Compute | A request-handling function and a stream-processing function, both arm64, both writing structured JSON logs to their own retained log groups |
| State | DynamoDB table with a partition and sort key, a customer managed key, point-in-time recovery, a `NEW_AND_OLD_IMAGES` change stream, and optional item expiry |
| Cross-cutting | Customer managed KMS key and alias, Secrets Manager secret for runtime configuration, one IAM execution role, SNS alarm topic, six CloudWatch alarms, daily AWS Backup plan, optional hosted zone, certificate and apex record, optional budget |

Both functions share a single execution role whose inline policy is
written against the ARNs this architecture created: item operations on
the state table and its indexes, stream reads on that table's stream,
`GetSecretValue` on the one configuration secret, and `Decrypt` on the
one key. Nothing in that policy uses a wildcard resource, so a second
copy of this architecture in the same account cannot read the first
one's data.

### What it deliberately leaves to the caller

This family has no API Gateway module and no SQS module, and this
architecture does not pretend otherwise. Three wires are therefore
outside it, and all three are small:

- **The origin access control.** CloudFront reads a private S3 bucket
  through an origin access control and a bucket policy that trusts it.
  Neither is modeled in this family, so `origin_access_control_id` takes
  the ID of one you created. Left null, the distribution falls back to
  treating the bucket as an ordinary HTTPS origin, which only serves
  objects the bucket already makes readable — fine for a first plan,
  wrong for anything real.
- **The API origin.** There is no module here that puts an HTTP endpoint
  in front of a Lambda function. `api_origin_domain_name` takes the host
  name of one you have — a Lambda function URL is the usual answer — and
  the distribution then gains a second origin and a `/api/*` behavior
  with caching disabled.
- **The event source mapping.** The state table's stream is enabled and
  the stream-processing function has the permissions to read it, but
  nothing subscribes one to the other. That is a single
  `aws_lambda_event_source_mapping` resource joining the
  `table_stream_arn` output to the `stream` entry of `function_arns`.

The deployment archives are the other thing the caller supplies.
`api_package_key` and `stream_package_key` name objects in the artifacts
bucket this architecture creates, and Lambda reads them during creation
— so on a first apply, upload the archives to that bucket before the
functions are created, or the apply fails on a missing key.

### Two regions, one architecture

CloudFront is global, and AWS requires both its ACM certificate and its
WAF web ACL to live in `us-east-1` no matter where the rest of the
architecture runs. A single-region provider cannot do that, so this
module declares a second `aws` provider aliased to `us_east_1` and hands
it to the certificate and web ACL modules explicitly. Everything else
uses `region`. This is worth knowing about before you set `region` to
something else: nothing breaks, but the certificate and the ACL will not
appear in the region you set.

### The key policy the log groups need

The customer managed KMS key is created with AWS's default key policy,
which grants the account root full access and grants no service
principal anything. CloudWatch Logs encrypts a log group with a
customer managed key only if the key policy names `logs.amazonaws.com`
directly, so the two Lambda log groups will fail to create until it
does. The grant goes in the `policy` variable of the `key` module. It is
not built here because composing it requires the account ID from a data
source, and this module has neither `resource` nor `data` blocks by
design.

The SNS alarm topic is deliberately left unencrypted for the mirror
image of the same reason. CloudWatch cannot publish to a topic encrypted
with AWS's own `alias/aws/sns` key, whose policy cannot be edited, and
alarm notifications then fail silently — a monitoring setup that looks
correct and delivers nothing is worse than an unencrypted topic carrying
alarm names.

### Things it deliberately does not do

One Trivy finding survives on this configuration by design:

- **No access logging on the log bucket.** The bucket that receives the
  content bucket's, the artifacts bucket's, and CloudFront's access logs
  does not log access to itself. Pointing it at itself would log its own
  log writes indefinitely, and a fourth bucket only moves the same
  finding one hop further away.

`deletion_protection_enabled` is left off on the state table for the
same reason the rest of this family leaves it off: enabling it makes
`terraform destroy` fail until a separate apply turns it off again,
which is hostile for an architecture people stand up to evaluate. Turn
it on for anything you intend to keep. `force_destroy` on the backup
vault is off for the opposite reason — a destroy that would discard
every recovery point fails instead, which is the safer failure.

## Usage

```hcl
module "staging" {
  source  = "kn47ytv9mv/architecture-serverless/aws"
  version = "~> 1.0"

  name        = "staging"
  alarm_email = "ops@example.com"
}
```

A production environment with a private origin, an API behind the same
distribution, a domain, a rate limit, and a budget:

```hcl
module "production" {
  source = "github.com/kn47ytv9mv/terraform-aws-architecture-serverless"

  name   = "production"
  region = "eu-west-1"

  origin_access_control_id = aws_cloudfront_origin_access_control.content.id
  api_origin_domain_name   = "abc123.lambda-url.eu-west-1.on.aws"

  memory_size        = 1024
  timeout            = 60
  log_retention_days = 90
  price_class        = "PriceClass_All"

  domain_name    = "example.com"
  waf_rate_limit = 2000
  alarm_email    = "ops@example.com"
  monthly_budget = "400"

  tags = {
    Environment = "production"
    Backup      = "true"
  }
}
```

The `Backup` tag in that example is not decorative — the backup plan
selects resources by `Backup = "true"`, so the state table is created
but never backed up without it.

**Setting `domain_name` does not finish the job.** A newly created
hosted zone is not authoritative for the domain until the registrar is
pointed at it, and ACM cannot validate the certificate until it is. Take
the `name_servers` output to the registrar; until you do, the apply will
wait on certificate validation and eventually time out.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.11 |
| aws | ~> 6.61 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |
| aws.us_east_1 | ~> 6.61 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| region | Region every regional resource in this architecture is created in. The CloudFront distribution, its ACM certificate, and its WAF web ACL are global and are always created in us-east-1 regardless of this value, because AWS accepts them nowhere else. | `"us-east-1"` | no |
| name | Name prefix applied to every resource, so one account can hold several copies of this architecture without collision. | `"serverless"` | no |
| runtime | Language runtime both functions execute under. AWS deprecates runtimes on a published schedule, after which a function can no longer be updated, so this is worth revisiting rather than pinning forever. | `"python3.13"` | no |
| architectures | Instruction set both functions run on. arm64 costs materially less per millisecond than x86_64 and is the better default for anything whose dependencies compile for it. | `["arm64"]` | no |
| memory_size | Memory available to each function, in mebibytes. Lambda allocates CPU in proportion, so raising this speeds up compute-bound work as well and a function can get cheaper at a higher setting by finishing proportionally faster. | `512` | no |
| timeout | Seconds a function may run before AWS kills it. The Lambda default of 3 seconds is short enough to surprise anything doing real work, so this architecture sets its own. | `30` | no |
| api_handler | Entry point of the request-handling function, in the runtime's own convention. | `"api.handler"` | no |
| api_package_key | Object key of the request-handling function's deployment archive within the artifacts bucket. The object must already exist when this architecture is applied, because Lambda reads it during creation. | `"api.zip"` | no |
| stream_handler | Entry point of the stream-processing function, in the runtime's own convention. | `"stream.handler"` | no |
| stream_package_key | Object key of the stream-processing function's deployment archive within the artifacts bucket. The object must already exist when this architecture is applied, because Lambda reads it during creation. | `"stream.zip"` | no |
| log_retention_days | Days of function logs CloudWatch keeps before expiring them. Logs that never expire are the quietest recurring cost in a serverless account, so this architecture sets a finite retention rather than leaving AWS's indefinite default in place. | `30` | no |
| table_hash_key | Partition key of the state table. Changing it after the table exists replaces the table, and the data with it. | `"pk"` | no |
| table_range_key | Sort key of the state table, which is what makes a single-table design able to hold several item collections under one partition. Changing it after the table exists replaces the table. | `"sk"` | no |
| table_ttl_attribute | Item attribute holding an epoch timestamp after which DynamoDB deletes the item. If null, no expiry is applied and every item written is kept until something deletes it. DynamoDB removes expired items on its own schedule, typically within days, and they stay readable until it does. | `"expires_at"` | no |
| origin_access_control_id | ID of an existing CloudFront origin access control, which is how the distribution reads a private S3 bucket without the bucket being public. No module in this family manages an origin access control or the bucket policy that trusts it, so both are the caller's to create. If null, the distribution is wired to the bucket's REST endpoint as an ordinary custom origin, which only serves objects the bucket already makes readable — see the README before relying on that. | `null` | no |
| api_origin_domain_name | Host name of an HTTPS origin serving the application's API, for example a Lambda function URL's host. Supplying one adds a second origin and a cache behavior routing `/api/*` to it with caching disabled. If null, the distribution serves static content only. | `null` | no |
| default_root_object | Object CloudFront requests from the static origin when a viewer asks for the root URL. | `"index.html"` | no |
| price_class | Edge locations that serve the distribution. PriceClass_100 covers North America and Europe and is the cheapest; PriceClass_All reaches every region at the lowest latency and costs the most. | `"PriceClass_100"` | no |
| waf_rate_limit | Requests a single IP address may make in a five-minute window before the web ACL blocks it. Setting it creates a CloudFront-scoped WAF web ACL and attaches it to the distribution. If null, no web ACL is created and the distribution accepts whatever arrives. | `null` | no |
| domain_name | Domain the distribution serves. Setting it creates a public hosted zone, an ACM certificate in us-east-1, and an alias record at the apex pointing to the distribution. If null, the distribution's own `*.cloudfront.net` name is the only entry point. | `null` | no |
| alarm_email | Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then. | `null` | no |
| monthly_budget | Monthly spend in USD to alarm on, as a string. If null, no budget is created. | `null` | no |
| tags | A map of tags applied to every resource in the architecture. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| distribution_domain_name | The distribution's own `*.cloudfront.net` name — the architecture's entry point when no `domain_name` was supplied. |
| distribution_id | ID of the CloudFront distribution, for issuing cache invalidations after a content deployment. |
| origin_ids | Origin IDs configured on the distribution. `static` is always present; `api` appears only when `api_origin_domain_name` was supplied. Reference these when adding further cache behaviors. |
| content_bucket | Name of the bucket holding the static content the distribution serves. |
| artifacts_bucket | Name of the bucket the functions read their deployment archives from. |
| table_name | Name of the DynamoDB table holding the application's state. |
| table_stream_arn | ARN of the state table's change stream, to attach an event source mapping for the stream-processing function. |
| function_arns | ARNs of the two functions, keyed by role. |
| function_role_arn | ARN of the execution role both functions assume. |
| alerts_topic_arn | ARN of the topic every alarm in this architecture notifies. |
| alarm_count | Number of CloudWatch alarms the monitoring baseline created. |
| web_acl_arn | ARN of the WAF web ACL attached to the distribution. Null when no `waf_rate_limit` was supplied. |
| name_servers | Name servers for the hosted zone, to delegate the domain to. Empty when no `domain_name` was supplied. |

## License

MIT — see [LICENSE.md](LICENSE.md).
