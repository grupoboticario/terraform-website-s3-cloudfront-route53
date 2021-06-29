variable "region" {
  type    = string
  default = "us-east-1"
}

variable "domain" {
  type = string
}

variable "target" {
  type = string
}

variable "duplicate-content-penalty-secret" {
  type = string
}

variable "deployer" {
  type = string
}

variable "acm-certificate-arn" {
  type = string
}

variable "tags" {
  type        = map(string)
  description = "Optional Tags"
  default     = {}
}

variable "price_class" {
  type        = string
  description = "CloudFront price class"
  default     = "PriceClass_200"
}

variable "default_root_object" {
  type        = string
  description = "CloudFront default root object"
  default     = "index.html"
}

variable "forward-query-string" {
  type        = bool
  description = "Forward the query string to the origin"
  default     = true
}

variable "enable_lambda_sec_headers" {
  type = list(object({
    event_type = string
    lambda_arn = string
  }))
  default = null

  description = "Specifies the lambda function of security headers"
}