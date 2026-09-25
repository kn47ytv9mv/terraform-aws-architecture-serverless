module "key" {
  source  = "kn47ytv9mv/kms-key/aws"
  version = "~> 1.0"

  description = "${var.name} architecture data key"

  tags = var.tags
}

module "key_alias" {
  source  = "kn47ytv9mv/kms-alias/aws"
  version = "~> 1.0"

  name          = var.name
  target_key_id = module.key.arn
}

module "log_bucket" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket = "${var.name}-logs"

  tags = var.tags
}

module "content" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket                = "${var.name}-content"
  kms_master_key_id     = module.key.arn
  enable_access_logging = true
  access_log_bucket     = module.log_bucket.bucket
  access_log_prefix     = "content"

  tags = var.tags
}

module "artifacts" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket                = "${var.name}-artifacts"
  kms_master_key_id     = module.key.arn
  enable_access_logging = true
  access_log_bucket     = module.log_bucket.bucket
  access_log_prefix     = "artifacts"

  tags = var.tags
}

module "web_acl" {
  source  = "kn47ytv9mv/wafv2-web-acl/aws"
  version = "~> 1.0"
  count   = var.waf_rate_limit != null ? 1 : 0

  providers = {
    aws = aws.us_east_1
  }

  name           = "${var.name}-edge"
  description    = "Rate limiting for the ${var.name} distribution."
  scope          = "CLOUDFRONT"
  default_action = "allow"

  rules_json = jsonencode([
    {
      Name     = "rate-limit"
      Priority = 0
      Action   = { Block = {} }

      Statement = {
        RateBasedStatement = {
          Limit            = var.waf_rate_limit
          AggregateKeyType = "IP"
        }
      }

      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "${var.name}-rate-limit"
        SampledRequestsEnabled   = true
      }
    },
  ])

  visibility_config = {
    metric_name = "${var.name}-edge"
  }

  tags = var.tags
}

module "certificate" {
  source  = "kn47ytv9mv/acm-certificate/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  providers = {
    aws = aws.us_east_1
  }

  domain_name = var.domain_name

  tags = var.tags
}

module "distribution" {
  source  = "kn47ytv9mv/cloudfront/aws"
  version = "~> 1.0"

  comment             = "${var.name} serverless application"
  default_root_object = var.default_root_object
  price_class         = var.price_class
  http_version        = "http2and3"
  aliases             = var.domain_name != null ? [var.domain_name] : null
  web_acl_id          = var.waf_rate_limit != null ? module.web_acl[0].arn : null

  origins = merge(
    {
      static = {
        domain_name              = "${var.name}-content.s3.${var.region}.amazonaws.com"
        origin_access_control_id = var.origin_access_control_id
        custom_origin_config     = var.origin_access_control_id == null ? {} : null
      }
    },
    var.api_origin_domain_name != null ? {
      api = {
        domain_name              = var.api_origin_domain_name
        origin_access_control_id = null
        custom_origin_config     = {}
      }
    } : {},
  )

  default_cache_behavior = {
    target_origin_id = "static"
  }

  ordered_cache_behaviors = var.api_origin_domain_name != null ? [
    {
      path_pattern     = "/api/*"
      target_origin_id = "api"
      allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods   = ["GET", "HEAD"]
      cache_policy_id  = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    },
  ] : []

  custom_error_responses = [
    { error_code = 403, response_code = 200, response_page_path = "/${var.default_root_object}" },
    { error_code = 404, response_code = 200, response_page_path = "/${var.default_root_object}" },
  ]

  viewer_certificate = var.domain_name != null ? {
    acm_certificate_arn = module.certificate[0].arn
  } : null

  logging_config = {
    bucket = "${module.log_bucket.bucket}.s3.amazonaws.com"
    prefix = "cloudfront"
  }

  tags = var.tags
}

module "zone" {
  source  = "kn47ytv9mv/route53-zone/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  name = var.domain_name

  tags = var.tags
}

module "records" {
  source  = "kn47ytv9mv/route53-record/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  records = {
    apex = {
      zone_id = module.zone[0].id
      name    = var.domain_name
      type    = "A"

      alias = {
        name    = module.distribution.domain_name
        zone_id = module.distribution.hosted_zone_id
      }
    }
  }
}

module "table" {
  source  = "kn47ytv9mv/dynamodb-table/aws"
  version = "~> 1.0"

  name      = "${var.name}-state"
  hash_key  = var.table_hash_key
  range_key = var.table_range_key

  attributes = [
    { name = var.table_hash_key, type = "S" },
    { name = var.table_range_key, type = "S" },
  ]

  server_side_encryption_enabled     = true
  server_side_encryption_kms_key_arn = module.key.arn
  point_in_time_recovery_enabled     = true
  stream_enabled                     = true
  stream_view_type                   = "NEW_AND_OLD_IMAGES"

  ttl = var.table_ttl_attribute != null ? { attribute_name = var.table_ttl_attribute } : null

  tags = var.tags
}

module "config" {
  source  = "kn47ytv9mv/secretsmanager-secret/aws"
  version = "~> 1.0"

  name        = "${var.name}/config"
  description = "Runtime configuration for ${var.name}, read by the functions at invocation rather than baked into their environment variables where the console would display it."
  kms_key_id  = module.key.arn

  tags = var.tags
}

module "function_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-function"
  principal_identifiers = ["lambda.amazonaws.com"]
  managed_policy_arns   = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]

  inline_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"]
        Resource = [module.table.arn, "${module.table.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]
        Resource = ["${module.table.arn}/stream/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [module.config.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [module.key.arn]
      },
    ]
  })

  tags = var.tags
}

module "api_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/lambda/${var.name}-api"
  retention_in_days = var.log_retention_days
  kms_key_id        = module.key.arn

  tags = var.tags
}

module "stream_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/lambda/${var.name}-stream"
  retention_in_days = var.log_retention_days
  kms_key_id        = module.key.arn

  tags = var.tags
}

module "api" {
  source  = "kn47ytv9mv/lambda-function/aws"
  version = "~> 1.0"

  function_name = "${var.name}-api"
  description   = "Request handler for ${var.name}."
  role          = module.function_role.arn

  runtime       = var.runtime
  handler       = var.api_handler
  s3_bucket     = module.artifacts.bucket
  s3_key        = var.api_package_key
  architectures = var.architectures
  memory_size   = var.memory_size
  timeout       = var.timeout
  tracing_mode  = "Active"
  kms_key_arn   = module.key.arn

  environment_variables = {
    TABLE_NAME  = module.table.name
    CONFIG_NAME = module.config.name
  }

  logging_config = {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = module.api_log_group.name
  }

  tags = var.tags
}

module "stream_processor" {
  source  = "kn47ytv9mv/lambda-function/aws"
  version = "~> 1.0"

  function_name = "${var.name}-stream"
  description   = "Processes change records from the ${var.name} state table."
  role          = module.function_role.arn

  runtime       = var.runtime
  handler       = var.stream_handler
  s3_bucket     = module.artifacts.bucket
  s3_key        = var.stream_package_key
  architectures = var.architectures
  memory_size   = var.memory_size
  timeout       = var.timeout
  tracing_mode  = "Active"
  kms_key_arn   = module.key.arn

  environment_variables = {
    TABLE_NAME  = module.table.name
    CONFIG_NAME = module.config.name
  }

  logging_config = {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = module.stream_log_group.name
  }

  tags = var.tags
}

module "alerts" {
  source  = "kn47ytv9mv/sns-topic/aws"
  version = "~> 1.0"

  name         = "${var.name}-alerts"
  display_name = "${var.name} alerts"

  subscriptions = var.alarm_email != null ? [
    { protocol = "email", endpoint = var.alarm_email },
  ] : []

  tags = var.tags
}

module "monitoring" {
  source  = "kn47ytv9mv/monitoring-baseline/aws"
  version = "~> 1.0"

  name_prefix   = var.name
  alarm_actions = [module.alerts.arn]
  ok_actions    = [module.alerts.arn]

  lambda_functions = {
    api    = { function_name = module.api.function_name }
    stream = { function_name = module.stream_processor.function_name }
  }

  dynamodb_tables = {
    state = { table_name = module.table.name }
  }

  tags = var.tags
}

module "backup_vault" {
  source  = "kn47ytv9mv/backup-vault/aws"
  version = "~> 1.0"

  name        = var.name
  kms_key_arn = module.key.arn

  tags = var.tags
}

module "backup_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-backup"
  principal_identifiers = ["backup.amazonaws.com"]
  managed_policy_arns   = ["arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"]

  tags = var.tags
}

module "backup_plan" {
  source  = "kn47ytv9mv/backup-plan/aws"
  version = "~> 1.0"

  name = var.name

  rules = [
    {
      rule_name         = "daily"
      target_vault_name = module.backup_vault.name
      schedule          = "cron(0 5 * * ? *)"
      lifecycle         = { delete_after = 35 }
    },
  ]

  selections = [
    {
      name         = "tagged"
      iam_role_arn = module.backup_role.arn
      resources    = ["*"]

      selection_tags = [
        { key = "Backup", value = "true" },
      ]
    },
  ]

  tags = var.tags
}

module "budget" {
  source  = "kn47ytv9mv/budget/aws"
  version = "~> 1.0"
  count   = var.monthly_budget != null ? 1 : 0

  name         = "${var.name}-monthly"
  limit_amount = var.monthly_budget

  notifications = [
    {
      threshold                 = 80
      notification_type         = "FORECASTED"
      subscriber_sns_topic_arns = [module.alerts.arn]
    },
  ]

  tags = var.tags
}

output "distribution_domain_name" {
  description = "The distribution's own *.cloudfront.net name — the architecture's entry point when no domain_name was supplied."
  value       = module.distribution.domain_name
}

output "distribution_id" {
  description = "ID of the CloudFront distribution, for issuing cache invalidations after a content deployment."
  value       = module.distribution.id
}

output "origin_ids" {
  description = "Origin IDs configured on the distribution. 'static' is always present; 'api' appears only when api_origin_domain_name was supplied. Reference these when adding further cache behaviors."
  value       = var.api_origin_domain_name != null ? ["static", "api"] : ["static"]
}

output "content_bucket" {
  description = "Name of the bucket holding the static content the distribution serves."
  value       = module.content.bucket
}

output "artifacts_bucket" {
  description = "Name of the bucket the functions read their deployment archives from."
  value       = module.artifacts.bucket
}

output "table_name" {
  description = "Name of the DynamoDB table holding the application's state."
  value       = module.table.name
}

output "table_stream_arn" {
  description = "ARN of the state table's change stream, to attach an event source mapping for the stream-processing function."
  value       = module.table.stream_arn
}

output "function_arns" {
  description = "ARNs of the two functions, keyed by role."
  value = {
    api    = module.api.arn
    stream = module.stream_processor.arn
  }
}

output "function_role_arn" {
  description = "ARN of the execution role both functions assume."
  value       = module.function_role.arn
}

output "alerts_topic_arn" {
  description = "ARN of the topic every alarm in this architecture notifies."
  value       = module.alerts.arn
}

output "alarm_count" {
  description = "Number of CloudWatch alarms the monitoring baseline created."
  value       = module.monitoring.alarm_count
}

output "web_acl_arn" {
  description = "ARN of the WAF web ACL attached to the distribution. Null when no waf_rate_limit was supplied."
  value       = var.waf_rate_limit != null ? module.web_acl[0].arn : null
}

output "name_servers" {
  description = "Name servers for the hosted zone, to delegate the domain to. Empty when no domain_name was supplied."
  value       = var.domain_name != null ? module.zone[0].name_servers : []
}
