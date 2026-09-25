mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "random" {}

run "an_unsupported_log_retention_is_rejected" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

run "a_timeout_beyond_the_lambda_maximum_is_rejected" {
  command = plan

  variables {
    timeout = 901
  }

  expect_failures = [var.timeout]
}

run "the_default_architecture_alarms_on_both_functions_and_the_table" {
  command = plan

  assert {
    condition     = module.monitoring.alarm_count == 6
    error_message = "Both functions should alarm on errors and throttles, and the table on read and write throttles."
  }

  assert {
    condition     = length(module.monitoring.alarm_names) == module.monitoring.alarm_count
    error_message = "Every alarm created should appear in the alarm_names output."
  }
}

run "every_named_resource_takes_the_name_prefix" {
  command = plan

  variables {
    name = "shop"
  }

  assert {
    condition     = module.api.function_name == "shop-api"
    error_message = "The request handler should be named from the prefix, so two copies of this architecture can share an account."
  }

  assert {
    condition     = module.stream_processor.function_name == "shop-stream"
    error_message = "The stream processor should be named from the prefix, so two copies of this architecture can share an account."
  }

  assert {
    condition     = module.table.name == "shop-state"
    error_message = "The state table should be named from the prefix."
  }

  assert {
    condition     = module.backup_vault.name == "shop"
    error_message = "The backup vault should be named from the prefix."
  }
}

run "no_api_origin_serves_static_content_only" {
  command = plan

  assert {
    condition     = contains(output.origin_ids, "static") && !contains(output.origin_ids, "api")
    error_message = "Without an API origin the distribution should have only the static origin."
  }

  assert {
    condition     = length(output.origin_ids) == 1
    error_message = "Without an API origin the distribution should have exactly one origin."
  }
}

run "an_api_origin_adds_a_second_origin_and_a_routing_behavior" {
  command = plan

  variables {
    api_origin_domain_name = "abc123.lambda-url.us-east-1.on.aws"
  }

  assert {
    condition     = contains(output.origin_ids, "api")
    error_message = "Supplying an API origin should add it alongside the static origin."
  }

  assert {
    condition     = length(output.origin_ids) == 2
    error_message = "The distribution should serve from exactly the static and API origins."
  }
}

run "no_domain_name_creates_no_dns_and_no_certificate" {
  command = plan

  assert {
    condition     = length(module.certificate) == 0
    error_message = "A certificate should only be created when a domain name is supplied."
  }

  assert {
    condition     = length(module.zone) == 0
    error_message = "A hosted zone should only be created when a domain name is supplied."
  }

  assert {
    condition     = length(module.records) == 0
    error_message = "An alias record should only be created when a domain name is supplied."
  }

  assert {
    condition     = length(output.name_servers) == 0
    error_message = "Without a hosted zone there are no name servers to delegate to."
  }
}

run "a_domain_name_creates_the_zone_certificate_and_record" {
  command = plan

  variables {
    domain_name = "example.com"
  }

  assert {
    condition     = length(module.certificate) == 1
    error_message = "Supplying a domain name should create a certificate for it."
  }

  assert {
    condition     = length(module.zone) == 1
    error_message = "Supplying a domain name should create a hosted zone for it."
  }

  assert {
    condition     = length(module.records) == 1
    error_message = "Supplying a domain name should create an alias record pointing at the distribution."
  }
}

run "no_rate_limit_leaves_the_distribution_without_a_web_acl" {
  command = plan

  assert {
    condition     = length(module.web_acl) == 0
    error_message = "A web ACL should only be created when a rate limit is supplied."
  }

  assert {
    condition     = output.web_acl_arn == null
    error_message = "Without a web ACL there is no ACL ARN to report."
  }
}

run "a_rate_limit_creates_a_cloudfront_scoped_web_acl" {
  command = plan

  variables {
    waf_rate_limit = 2000
  }

  assert {
    condition     = length(module.web_acl) == 1
    error_message = "Supplying a rate limit should create a web ACL."
  }

  assert {
    condition     = module.web_acl[0].name == "serverless-edge"
    error_message = "The web ACL should be named from the prefix, alongside the distribution it protects."
  }
}

run "no_budget_amount_creates_no_budget" {
  command = plan

  assert {
    condition     = length(module.budget) == 0
    error_message = "A budget should only be created when a monthly amount is supplied."
  }

  assert {
    condition     = length(module.alerts.subscription_arns) == 0
    error_message = "Without an address the alarm topic should have no subscriptions."
  }
}

run "a_budget_amount_and_an_alarm_email_wire_both_to_the_topic" {
  command = plan

  variables {
    monthly_budget = "300"
    alarm_email    = "ops@example.com"
  }

  assert {
    condition     = length(module.budget) == 1
    error_message = "Supplying a monthly amount should create a budget."
  }

  assert {
    condition     = length(module.alerts.subscription_arns) == 1
    error_message = "Supplying an address should subscribe it to the alarm topic."
  }
}
