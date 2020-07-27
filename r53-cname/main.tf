################################################################################################################
## Create a Route53 CNAME record to the Cloudfront distribution
################################################################################################################
resource "aws_route53_record" "cdn-cname" {

  for_each = [for cname in var.domain: {
    zone_id = var.route53_zone_id
    name    = cname
    type    = "CNAME"
    ttl     = "300"
    records = [var.target]    
  }]
  
}
