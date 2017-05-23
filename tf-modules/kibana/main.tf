/**
 *## Kibana
 *
 * This module takes care of deployment of EC2 instances running Kibana using
 * an autoscaling group with a load balancer. It also adds an entry to Route53
 * for the Kibana load balancer. ISSUED SSL certificate must exist in ACM for
 * specified the `kibana_dns`.
 *
 */
data "aws_acm_certificate" "kibana-cert" {
  domain = "${var.kibana_dns_name}"
  statuses = ["ISSUED"]
}

resource "aws_elb" "kibana-elb" {
  name = "${var.name_prefix}-kibana"
  subnets       = ["${var.public_subnet_ids}"]
  security_groups = ["${aws_security_group.kibana-elb-sg.id}"]

  listener {
    instance_port = 5602
    instance_protocol = "http"
    lb_port = 443
    lb_protocol = "https"
    ssl_certificate_id = "${data.aws_acm_certificate.kibana-cert.arn}"
  }

  listener {
    instance_port = 80
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 10 # TODO lower it down
    timeout = 3
    target = "HTTP:5603/"
    interval = 60
  }

  cross_zone_load_balancing = true
  idle_timeout = 60
  connection_draining = true
  connection_draining_timeout = 60

  tags {
    Name = "${var.name_prefix}-kibana-elb"
  }
}


resource "aws_route53_record" "kibana-elb" {
  zone_id = "${var.route53_zone_id}"
  name = "${var.kibana_dns_name}"
  type = "A"

  alias {
    name = "${aws_elb.kibana-elb.dns_name}"
    zone_id = "${aws_elb.kibana-elb.zone_id}"
    evaluate_target_health = true
  }
}


data "template_file" "kibana-setup" {
  template = "${file("${path.module}/data/setup.tpl.sh")}"

  vars {
    elasticsearch_url = "${var.elasticsearch_url}"
  }
}

data "aws_vpc" "current" {
  id = "${var.vpc_id}"
}

resource "aws_security_group" "kibana-sg" {
  name        = "${var.name_prefix}-kibana-instance"
  vpc_id      = "${var.vpc_id}"
  description = "Allow ICMP, SSH, HTTP, Kibana port (5602), Kibana healthcheck (5603) from VPC CIDR. Also everything outbound."

  tags {
    Name = "${var.name_prefix}-kibana-nodes"
  }

  # Kibana
  ingress {
    from_port   = 5602
    to_port     = 5602
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.current.cidr_block}"]
  }

  # Kibana status
  ingress {
    from_port   = 5603
    to_port     = 5603
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.current.cidr_block}"]
  }

  # Used for proper redirect to https
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.current.cidr_block}"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.current.cidr_block}"]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["${data.aws_vpc.current.cidr_block}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_security_group" "kibana-elb-sg" {
  name        = "${var.name_prefix}-kibana-elb"
  vpc_id      = "${var.vpc_id}"
  description = "Allow ICMP, HTTPS and everything outbound."

  tags {
    Name = "${var.kibana_dns_name}"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_autoscaling_group" "kibana-asg" {
  count                = "${min(var.max_server_count, 1)}"
  availability_zones   = ["${var.vpc_azs}"]
  name                 = "${var.name_prefix}-kibana-asg"
  max_size             = "${var.max_server_count}"
  min_size             = "${var.min_server_count}"
  desired_capacity     = "${var.desired_server_count}"
  launch_configuration = "${aws_launch_configuration.kibana-lc.name}"
  health_check_type    = "ELB"
  vpc_zone_identifier  = ["${var.private_subnet_ids}"]
  load_balancers       = ["${aws_elb.kibana-elb.name}"]

  tag = [{
    key                 = "Name"
    value               = "${var.name_prefix}-kibana"
    propagate_at_launch = true
  }]

}


resource "aws_launch_configuration" "kibana-lc" {
  count           = "${min(var.max_server_count, 1)}"
  name_prefix     = "${var.name_prefix}-kibana-lc-"
  image_id        = "${var.ami}"
  instance_type   = "${var.instance_type}"
  key_name        = "${var.key_name}"
  security_groups = ["${aws_security_group.kibana-sg.id}"]
  user_data       = <<USER_DATA
#!/bin/bash
${data.template_file.kibana-setup.rendered}
USER_DATA

  lifecycle = {
    create_before_destroy = true
  }
}