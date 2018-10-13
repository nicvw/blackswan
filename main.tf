provider "aws" {
  version = "~> 1.40"
  region  = "us-east-1"
}

# Create a vpc with a cidr 10.0.0.0/16
resource "aws_vpc" "nicvw" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.nicvw.id}"
}

# create 2 subnets within the VPC in 2 different AZ's
resource "aws_subnet" "primary_subnet" {
  vpc_id            = "${aws_vpc.nicvw.id}"
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "secondary_subnet" {
  vpc_id            = "${aws_vpc.nicvw.id}"
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1b"
}

# Elastic load balancer with port 80 and 443 exposed and a public ip address
resource "aws_lb" "frontend" {
  name_prefix        = "lb-",
  internal           = false
  load_balancer_type = "application"
  subnets	           = ["${aws_subnet.primary_subnet.id}", "${aws_subnet.secondary_subnet.id}"]
  depends_on         = ["aws_internet_gateway.gw"]
}

resource "aws_lb_target_group" "frontend" {
  name_prefix = "lb-tg-"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = "${aws_vpc.nicvw.id}"

  health_check {
  }
}

resource "aws_lb_listener" "frontend_https" {
  load_balancer_arn = "${aws_lb.frontend.arn}"
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = "${aws_acm_certificate_validation.cert.certificate_arn}"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.frontend.arn}"
  }
}

resource "aws_lb_listener" "frontend_http" {
  load_balancer_arn = "${aws_lb.frontend.arn}"
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.frontend.arn}"
  }
}

# create a domain in route 53 (any will do, private won't need registration) and get a cert for the domain to apply to the ELB
resource "aws_route53_zone" "zone" {
  name   = "nicvw.com"
  vpc_id = "${aws_vpc.nicvw.id}"
}

resource "aws_acm_certificate" "cert" {
  domain_name       = "nicvw.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "www" {
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name    = "nicvw.com"
  type    = "A"

  alias {
    name                   = "${aws_lb.frontend.dns_name}"
    zone_id                = "${aws_lb.frontend.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "cert_validation" {
  name    = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_name}"
  type    = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_type}"
  zone_id = "${aws_route53_zone.zone.id}"
  records = ["${aws_acm_certificate.cert.domain_validation_options.0.resource_record_value}"]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = "${aws_acm_certificate.cert.arn}"
  validation_record_fqdns = ["${aws_route53_record.cert_validation.fqdn}"]
}

# an EC2 instance with nginx installed , using amazon linux (automatically)
# Mysql instance with configurable DB name , username and password accessible by the vpc only
# output the ELB IP , mysql url, username and password at end of run
# ec2 instance size and root block size aswell as mysql dbname , username,password , instance size and space configurable with a TF vars file .
# terraform state file to be saved in a s3 bucket
