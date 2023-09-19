################################################################################################################
## Creates a setup to serve a static website from an AWS S3 bucket, with a Cloudfront CDN and
## certificates from AWS Certificate Manager.
##
## Bucket name restrictions:
##    http://docs.aws.amazon.com/AmazonS3/latest/dev/BucketRestrictions.html
## Duplicate Content Penalty protection:
##    Description: https://support.google.com/webmasters/answer/66359?hl=en
##    Solution: http://tuts.emrealadag.com/post/cloudfront-cdn-for-s3-static-web-hosting/
##        Section: Restricting S3 access to Cloudfront
## Deploy remark:
##    Do not push files to the S3 bucket with an ACL giving public READ access, e.g s3-sync --acl-public
##
## 2016-05-16
##    AWS Certificate Manager supports multiple regions. To use CloudFront with ACM certificates, the
##    certificates must be requested in region us-east-1
################################################################################################################


locals {
  origin_domain_name     = var.create_bucket == true ? aws_s3_bucket.website_bucket[0].website_endpoint : "${var.bucket_name}.s3.amazonaws.com"
  origin_domain_name_oai = var.create_bucket == true ? aws_s3_bucket.website_bucket[0].bucket_regional_domain_name : "${var.bucket_name}.s3.amazonaws.com"
  origin_access_identity = var.enable_oai == true ? [aws_cloudfront_origin_access_identity.origin_access_identity[0].cloudfront_access_identity_path] : []
  forwarded_values       = [{ query_string = var.forward-query-string, cookies = { forward = "none" } }]

  custom_origin_config = var.enable_oai == false ? [{
    origin_protocol_policy = "http-only"
    http_port              = "80"
    https_port             = "443"
    origin_ssl_protocols   = ["TLSv1.2"]
  }] : []
}

resource "aws_s3_bucket" "website_bucket" {
  count  = var.create_bucket == true ? 1 : 0
  bucket = var.bucket_name

  tags = var.tags
}

resource "aws_s3_bucket_policy" "website_bucket" {
  count  = var.create_bucket == true ? 1 : 0
  bucket = aws_s3_bucket.website_bucket[0].id
  policy = templatefile("${path.module}/website_bucket_policy_oai.tftpl", { iam_arn = aws_cloudfront_origin_access_identity.origin_access_identity[0].iam_arn, bucket = var.bucket_name })
}

resource "aws_s3_bucket_website_configuration" "website_bucket" {
  count  = var.create_bucket == true ? 1 : 0
  bucket = aws_s3_bucket.website_bucket[0].id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }

  dynamic "routing_rule" {
    for_each = var.routing_rules
    content {
      condition {
        key_prefix_equals = routing_rule.routing_rules_condition
      }
      redirect {
        replace_key_prefix_with = routing_rule.routing_rules_redirect
      }
    }
  }
}

resource "aws_s3_bucket_versioning" "website_bucket" {
  count  = var.create_bucket == true ? 1 : 0
  bucket = aws_s3_bucket.website_bucket[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "website_bucket" {
  count  = var.create_bucket == true ? 1 : 0
  bucket = aws_s3_bucket.website_bucket[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "website_bucket" {
  count  = var.create_bucket == true && length(var.cors_rule_inputs) != 0 ? 1 : 0
  bucket = aws_s3_bucket.website_bucket[0].id

  dynamic "cors_rule" {
    for_each = var.cors_rule_inputs == null ? [] : var.cors_rule_inputs

    content {
      allowed_headers = cors_rule.value.allowed_headers
      allowed_methods = cors_rule.value.allowed_methods
      allowed_origins = cors_rule.value.allowed_origins
      expose_headers  = cors_rule.value.expose_headers
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  count = var.create_bucket == true ? 1 : 0

  # Chain resources (s3_bucket -> s3_bucket_policy -> s3_bucket_public_access_block)
  # to prevent "A conflicting conditional operation is currently in progress against this resource."
  # Ref: https://github.com/hashicorp/terraform-provider-aws/issues/7628

  bucket = aws_s3_bucket.website_bucket[0].id

  block_public_policy     = true
  block_public_acls       = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################################################
## Create a Cloudfront distribution for the static website
################################################################################################################
resource "aws_cloudfront_distribution" "website_cdn" {
  enabled      = true
  price_class  = var.price_class
  http_version = "http2"
  web_acl_id   = var.web_acl_id != null ? var.web_acl_id : null

  origin {
    origin_id   = var.create_bucket == true ? "origin-bucket-${aws_s3_bucket.website_bucket[0].id}" : "origin-bucket-${var.bucket_name}"
    domain_name = var.enable_oai == true ? local.origin_domain_name_oai : local.origin_domain_name

    dynamic "s3_origin_config" {
      for_each = local.origin_access_identity == null ? [] : local.origin_access_identity
      content {
        origin_access_identity = s3_origin_config.value
      }
    }

    dynamic "custom_origin_config" {
      for_each = local.custom_origin_config == null ? [] : local.custom_origin_config
      content {
        origin_protocol_policy = custom_origin_config.value.origin_protocol_policy
        http_port              = custom_origin_config.value.http_port
        https_port             = custom_origin_config.value.https_port
        origin_ssl_protocols   = custom_origin_config.value.origin_ssl_protocols
      }
    }

    custom_header {
      name  = "User-Agent"
      value = var.duplicate-content-penalty-secret
    }
  }

  default_root_object = var.default-root-object

  custom_error_response {
    error_code            = "404"
    error_caching_min_ttl = "360"
    response_code         = "200"
    response_page_path    = var.not-found-response-path
  }

  custom_error_response {
    error_code            = "403"
    error_caching_min_ttl = "360"
    response_code         = "200"
    response_page_path    = var.not-found-response-path
  }

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD", "DELETE", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]

    dynamic "lambda_function_association" {
      for_each = var.enable_lambda_sec_headers == null ? [] : var.enable_lambda_sec_headers
      content {
        event_type = lambda_function_association.value.event_type
        lambda_arn = lambda_function_association.value.lambda_arn
      }
    }

    dynamic "function_association" {
      for_each = var.enable_function_association == null ? [] : var.enable_function_association
      content {
        event_type   = function_association.value.event_type
        function_arn = function_association.value.function_arn
      }
    }

    cache_policy_id          = var.enable_cache_policy == true ? var.cache_policy_id : null
    origin_request_policy_id = var.enable_cache_policy == true ? var.origin_request_policy_id : null

    dynamic "forwarded_values" {
      for_each = var.enable_cache_policy == false ? local.forwarded_values : []

      content {
        query_string = lookup(local.forwarded_values[0], "query_string", true)
        cookies {
          forward = lookup(local.forwarded_values[0].cookies, "forward", "none")
        }
      }
    }

    trusted_signers = var.trusted_signers

    min_ttl          = var.enable_cache_policy == false ? var.min_ttl : null
    default_ttl      = var.enable_cache_policy == false ? var.default_ttl : null
    max_ttl          = var.enable_cache_policy == false ? var.max_ttl : null
    target_origin_id = var.create_bucket == true ? "origin-bucket-${aws_s3_bucket.website_bucket[0].id}" : "origin-bucket-${var.bucket_name}"

    // This redirects any HTTP request to HTTPS. Security first!
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm-certificate-arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  aliases = var.domain

  tags = var.tags
}

################################################################################################################
## Create Cloudfront OAI
################################################################################################################

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  count   = var.enable_oai == true ? 1 : 0
  comment = "Create OAI to use in CF: ${var.domain[0]}"
}
