provider "aws" {
  version = "~> 1.40"
  region  = "us-east-1"
}

provider "dns" {
  version = "~> 2.0"
}

# Create a vpc with a cidr 10.0.0.0/16
resource "aws_vpc" "nicvw" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.nicvw.id}"
}

# create 2 subnets within the VPC in 2 different AZ's
resource "aws_subnet" "public-1a" {
  vpc_id            = "${aws_vpc.nicvw.id}"
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "public-1b" {
  vpc_id            = "${aws_vpc.nicvw.id}"
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1b"
}

# Elastic load balancer with port 80 and 443 exposed and a public ip address
resource "aws_alb" "frontend" {
  name        = "frontend-alb-www",
  internal           = false
  subnets	           = ["${aws_subnet.public-1a.id}", "${aws_subnet.public-1b.id}"]
  depends_on         = ["aws_internet_gateway.gw"]
}

resource "aws_security_group" "inbound" {
  name = "sec_group_inbound"
  description = "Inbound Internet traffic"
  vpc_id = "${aws_vpc.nicvw.id}"

  ingress {
    from_port = 0
    to_port = 443
    protocol = "tcp"
  }

  ingress {
    from_port = 0
    to_port = 80
    protocol = "tcp"
  }

  ingress {
    from_port = 0
    to_port = 22
    protocol = "tcp"
  }
}

resource "aws_security_group" "web-servers" {
  name   = "sec_group-www"
  vpc_id = "${aws_vpc.nicvw.id}"
}

resource "aws_alb_target_group" "frontend_web" {
  name = "lb-tg-frontend"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = "${aws_vpc.nicvw.id}"

  health_check {
  }
}

resource "aws_alb_listener" "frontend_web" {
  load_balancer_arn = "${aws_alb.frontend.arn}"
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = "${aws_acm_certificate_validation.default.certificate_arn}"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.frontend_web.arn}"
  }
}

resource "aws_alb_listener" "frontend_http" {
  load_balancer_arn = "${aws_alb.frontend.arn}"
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.frontend_web.arn}"
  }
}

# create a domain in route 53 (any will do, private won't need registration) and get a cert for the domain to apply to the ELB
resource "aws_route53_zone" "zone" {
  name   = "aws.sigterm.co.za"
}

resource "aws_acm_certificate" "default" {
  domain_name       = "aws.sigterm.co.za"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "www" {
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name    = "aws.sigterm.co.za"
  type    = "A"

  alias {
    name                   = "${aws_alb.frontend.dns_name}"
    zone_id                = "${aws_alb.frontend.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "validation" {
  name    = "${aws_acm_certificate.default.domain_validation_options.0.resource_record_name}"
  type    = "${aws_acm_certificate.default.domain_validation_options.0.resource_record_type}"
  zone_id = "${aws_route53_zone.zone.id}"
  records = ["${aws_acm_certificate.default.domain_validation_options.0.resource_record_value}"]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "default" {
  certificate_arn         = "${aws_acm_certificate.default.arn}"
  validation_record_fqdns = ["${aws_route53_record.validation.fqdn}"]
}

# an EC2 instance with nginx installed , using amazon linux (automatically)
data "aws_ami" "amazon_linux" {
  most_recent      = true

  filter {
    name = "name"
    values = ["amzn2-ami-minimal-hvm-2.0.*-x86_64-ebs"]
  }
}

data "dns_a_record_set" "www" {
  host = "${aws_alb.frontend.dns_name}"
}

output "LB IP" {
  value = "${data.dns_a_record_set.www.addrs}"
}

resource "aws_instance" "nginx" {
  ami           = "${data.aws_ami.amazon_linux.image_id}"
  instance_type = "t2.micro"
  subnet_id     = "${aws_subnet.public-1a.id}"


  provisioner "remote-exec" {

    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
    ]

    connection {
      host = "${aws_eip.nginx-bootstrap-ip.public_ip}"
    }
  }
}

resource "aws_eip" "nginx-bootstrap-ip" {
  vpc	     = true
}

resource "aws_eip_association" "nginx-bootstrap-ip" {
  allocation_id = "${aws_eip.nginx-bootstrap-ip.id}"
  instance_id = "${aws_instance.nginx.id}"

}


resource "aws_lb_target_group_attachment" "frontend_www" {
  target_group_arn = "${aws_alb_target_group.frontend_web.arn}"
  target_id        = "${aws_instance.nginx.id}"
  port             = 80
}

# Mysql instance with configurable DB name , username and password accessible by the vpc only
# output the ELB IP , mysql url, username and password at end of run
# ec2 instance size and root block size aswell as mysql dbname , username,password , instance size and space configurable with a TF vars file .
# terraform state file to be saved in a s3 bucket

