# games.postiz.com: browser games, plain static files (the postiz-games repository).
# A private S3 bucket behind its own CloudFront distribution: no servers or images,
# files served from the edge, and the traffic sits inside CloudFront's always-free
# tier (1 TB + 10M requests a month). Each game is ~40 MB of voice, music and video,
# so the edge cache is what keeps this cheap.
#
# Deploys: .github/workflows/deploy-games.yml (deploy role, through the deploy gate)
# uploads a commit of postiz-games' main and clears the CloudFront cache.

resource "aws_s3_bucket" "games" {
  bucket = "${local.name}-games-${var.aws_account_id}"
}

resource "aws_s3_bucket_ownership_controls" "games" {
  bucket = aws_s3_bucket.games.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "games" {
  bucket                  = aws_s3_bucket.games.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "games" {
  bucket = aws_s3_bucket.games.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A deploy replaces every file; keep the previous versions for a week so a bad
# upload can be put back by hand.
resource "aws_s3_bucket_versioning" "games" {
  bucket = aws_s3_bucket.games.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "games" {
  bucket     = aws_s3_bucket.games.id
  depends_on = [aws_s3_bucket_versioning.games]

  rule {
    id     = "old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_cloudfront_origin_access_control" "games" {
  name                              = "${local.name}-games"
  description                       = "CloudFront reads the games bucket, nobody else does"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Only this distribution reads the bucket. ListBucket makes a missing file a 404
# (served as /404.html) instead of S3's 403.
data "aws_iam_policy_document" "games_bucket" {
  statement {
    sid       = "CloudFrontReads"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.games.arn, "${aws_s3_bucket.games.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.games.arn]
    }
  }

  statement {
    sid       = "TlsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.games.arn, "${aws_s3_bucket.games.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "games" {
  bucket     = aws_s3_bucket.games.id
  policy     = data.aws_iam_policy_document.games_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.games]
}

resource "aws_acm_certificate" "games" {
  provider          = aws.us_east_1
  domain_name       = var.games_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "games" {
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.games.arn
  depends_on      = [cloudflare_dns_record.acm_validation]
}

# S3 has no directory index behind CloudFront: /game/ -> /game/index.html, and
# /game -> 301 /game/ so a game's relative asset paths resolve inside its folder.
resource "aws_cloudfront_function" "games_index" {
  name    = "${local.name}-games-index"
  runtime = "cloudfront-js-2.0"
  comment = "directory index for ${var.games_domain}"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
        return request;
      }
      if (uri.substring(uri.lastIndexOf('/') + 1).indexOf('.') === -1) {
        var q = request.querystring, parts = [];
        for (var k in q) {
          var vs = q[k].multiValue ? q[k].multiValue : [q[k]];
          for (var i = 0; i < vs.length; i++) parts.push(vs[i].value === '' ? k : k + '=' + vs[i].value);
        }
        return {
          statusCode: 301,
          statusDescription: 'Moved Permanently',
          headers: { location: { value: uri + '/' + (parts.length ? '?' + parts.join('&') : '') } },
        };
      }
      return request;
    }
  EOT
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "games" {
  enabled             = true
  comment             = var.games_domain
  aliases             = [var.games_domain]
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class         = "PriceClass_All"
  default_root_object = "index.html"

  origin {
    origin_id                = "games-bucket"
    domain_name              = aws_s3_bucket.games.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.games.id
  }

  # Files are cached at the edge until the next deploy clears the cache; browsers
  # follow each file's Cache-Control, set by the deploy (HTML revalidates, the rest
  # keeps an hour).
  default_cache_behavior {
    target_origin_id           = "games-bucket"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
    compress                   = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.games_index.arn
    }
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.games.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Not part of dns_cutover: the games site is new, there is nothing to cut over from.
resource "cloudflare_dns_record" "games" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.games_domain
  type    = "CNAME"
  content = aws_cloudfront_distribution.games.domain_name
  ttl     = 60
  proxied = false
  comment = "Postiz games on AWS, managed by postiz-aws"
}
