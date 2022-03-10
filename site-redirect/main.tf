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
  tags = merge(
    var.tags,
    {
      "domain" = replace(var.domain, "*", "star")
    },
  )
  bucket_name = "site-${replace(replace(var.domain, ".", "-"), "*", "star")}-redirect"
}

data "template_file" "bucket_policy_oai" {
  template = file("${path.module}/website_bucket_policy_oai.json")

  vars = {
    bucket  = local.bucket_name
    secret  = var.duplicate-content-penalty-secret
    iam_arn = aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn
  }
}

################################################################################################################
## Configure the bucket and static website hosting
################################################################################################################
data "template_file" "bucket_policy" {
  template = file("${path.module}/website_redirect_bucket_policy.json")

  vars = {
    bucket = "site.${replace(replace(var.domain, ".", "-"), "*", "star")}"
    secret = var.duplicate-content-penalty-secret
  }
}

resource "aws_s3_bucket" "website_bucket" {
  bucket = local.bucket_name
  policy = data.template_file.bucket_policy_oai.rendered
  acl    = "private"

  website {
    redirect_all_requests_to = "https://${var.target}"
  }

  server_side_encryption_configuration {
    rule {
      bucket_key_enabled = false
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  //  logging {
  //    target_bucket = "${var.log_bucket}"
  //    target_prefix = "${var.log_bucket_prefix}"
  //  }

  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.website_bucket.id

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

  origin {
    origin_id   = "origin-bucket-${aws_s3_bucket.website_bucket.id}"
    domain_name = aws_s3_bucket.website_bucket.website_endpoint

    custom_origin_config {
      origin_protocol_policy = "http-only"
      http_port              = "80"
      https_port             = "443"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "User-Agent"
      value = var.duplicate-content-penalty-secret
    }
  }

  default_root_object = var.default_root_object

  custom_error_response {
    error_code            = "404"
    error_caching_min_ttl = "360"
    response_code         = "200"
    response_page_path    = "/404.html"
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

    forwarded_values {
      query_string = var.forward-query-string

      cookies {
        forward = "none"
      }
    }

    min_ttl          = "0"
    default_ttl      = "300"  //3600
    max_ttl          = "1200" //86400
    target_origin_id = "origin-bucket-${aws_s3_bucket.website_bucket.id}"

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

  aliases = [var.domain]

  tags = local.tags
}

################################################################################################################
## Create Cloudfront OAI
################################################################################################################

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "Create OAI to use in CF: ${var.target}"
}
