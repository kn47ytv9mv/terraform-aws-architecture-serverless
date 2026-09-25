variable "region" {
  default     = "us-east-1"
  description = "Region every regional resource in this architecture is created in. The CloudFront distribution, its ACM certificate, and its WAF web ACL are global and are always created in us-east-1 regardless of this value, because AWS accepts them nowhere else."
}

variable "name" {
  default     = "serverless"
  description = "Name prefix applied to every resource, so one account can hold several copies of this architecture without collision."
}

variable "runtime" {
  default     = "python3.13"
  description = "Language runtime both functions execute under. AWS deprecates runtimes on a published schedule, after which a function can no longer be updated, so this is worth revisiting rather than pinning forever."
}

variable "architectures" {
  default     = ["arm64"]
  description = "Instruction set both functions run on. arm64 costs materially less per millisecond than x86_64 and is the better default for anything whose dependencies compile for it."
}

variable "memory_size" {
  default     = 512
  description = "Memory available to each function, in mebibytes. Lambda allocates CPU in proportion, so raising this speeds up compute-bound work as well and a function can get cheaper at a higher setting by finishing proportionally faster."

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 mebibytes, the range AWS accepts."
  }
}

variable "timeout" {
  default     = 30
  description = "Seconds a function may run before AWS kills it. The Lambda default of 3 seconds is short enough to surprise anything doing real work, so this architecture sets its own."

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds, the maximum a Lambda function may run."
  }
}

variable "api_handler" {
  default     = "api.handler"
  description = "Entry point of the request-handling function, in the runtime's own convention."
}

variable "api_package_key" {
  default     = "api.zip"
  description = "Object key of the request-handling function's deployment archive within the artifacts bucket. The object must already exist when this architecture is applied, because Lambda reads it during creation."
}

variable "stream_handler" {
  default     = "stream.handler"
  description = "Entry point of the stream-processing function, in the runtime's own convention."
}

variable "stream_package_key" {
  default     = "stream.zip"
  description = "Object key of the stream-processing function's deployment archive within the artifacts bucket. The object must already exist when this architecture is applied, because Lambda reads it during creation."
}

variable "log_retention_days" {
  default     = 30
  description = "Days of function logs CloudWatch keeps before expiring them. Logs that never expire are the quietest recurring cost in a serverless account, so this architecture sets a finite retention rather than leaving AWS's indefinite default in place."

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the retention periods CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, or 3653."
  }
}

variable "table_hash_key" {
  default     = "pk"
  description = "Partition key of the state table. Changing it after the table exists replaces the table, and the data with it."
}

variable "table_range_key" {
  default     = "sk"
  description = "Sort key of the state table, which is what makes a single-table design able to hold several item collections under one partition. Changing it after the table exists replaces the table."
}

variable "table_ttl_attribute" {
  default     = "expires_at"
  description = "Item attribute holding an epoch timestamp after which DynamoDB deletes the item. If null, no expiry is applied and every item written is kept until something deletes it. DynamoDB removes expired items on its own schedule, typically within days, and they stay readable until it does."
}

variable "origin_access_control_id" {
  default     = null
  description = "ID of an existing CloudFront origin access control, which is how the distribution reads a private S3 bucket without the bucket being public. No module in this family manages an origin access control or the bucket policy that trusts it, so both are the caller's to create. If null, the distribution is wired to the bucket's REST endpoint as an ordinary custom origin, which only serves objects the bucket already makes readable — see the README before relying on that."
}

variable "api_origin_domain_name" {
  default     = null
  description = "Host name of an HTTPS origin serving the application's API, for example a Lambda function URL's host. Supplying one adds a second origin and a cache behavior routing /api/* to it with caching disabled. If null, the distribution serves static content only."
}

variable "default_root_object" {
  default     = "index.html"
  description = "Object CloudFront requests from the static origin when a viewer asks for the root URL."
}

variable "price_class" {
  default     = "PriceClass_100"
  description = "Edge locations that serve the distribution. PriceClass_100 covers North America and Europe and is the cheapest; PriceClass_All reaches every region at the lowest latency and costs the most."

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be 'PriceClass_100', 'PriceClass_200', or 'PriceClass_All'."
  }
}

variable "waf_rate_limit" {
  default     = null
  description = "Requests a single IP address may make in a five-minute window before the web ACL blocks it. Setting it creates a CloudFront-scoped WAF web ACL and attaches it to the distribution. If null, no web ACL is created and the distribution accepts whatever arrives."
}

variable "domain_name" {
  default     = null
  description = "Domain the distribution serves. Setting it creates a public hosted zone, an ACM certificate in us-east-1, and an alias record at the apex pointing to the distribution. If null, the distribution's own *.cloudfront.net name is the only entry point."
}

variable "alarm_email" {
  default     = null
  description = "Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then."
}

variable "monthly_budget" {
  default     = null
  description = "Monthly spend in USD to alarm on, as a string. If null, no budget is created."
}

variable "tags" {
  default     = null
  description = "A map of tags applied to every resource in the architecture."
}
