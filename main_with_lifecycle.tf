# Terraform doesn't support expressions in the lifecycle block, so we have to create identical resources 
# (except for the lifecycle block) and conditionally determine at runtime which one to create.
resource "aws_security_group_rule" "trusted_egress_attachment_prevent_destroy" {
  for_each                 = { for route in local.ingress_targets : "${route["prefix"]}-${route["source_security_group_id"]}" => route if var.prevent_destroy }
  type                     = "egress"
  from_port                = each.value["from_port"]
  to_port                  = each.value["to_port"]
  protocol                 = "tcp"
  description              = "Attached from ${module.sg[0].this_security_group_name} (${each.value["prefix"]})"
  source_security_group_id = module.sg[0].this_security_group_id
  security_group_id        = each.value["source_security_group_id"]

  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

resource "aws_ecs_service" "prevent_destroy" {
  count                              = var.prevent_destroy ? 1 : 0
  cluster                            = var.cluster_id
  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  desired_count                      = var.desired_count
  enable_execute_command             = var.enable_execute_command
  force_new_deployment               = var.force_new_deployment
  health_check_grace_period_seconds  = var.health_check_grace_period_seconds
  launch_type                        = var.capacity_provider_strategy != null ? null : "FARGATE"
  name                               = var.service_name
  platform_version                   = var.platform_version
  propagate_tags                     = "SERVICE"
  tags                               = var.tags
  task_definition                    = "${aws_ecs_task_definition.this.family}:${max(aws_ecs_task_definition.this.revision, data.aws_ecs_task_definition.this.revision)}"

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy != null ? var.capacity_provider_strategy : []

    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = capacity_provider_strategy.value.base
    }
  }

  dynamic "deployment_circuit_breaker" {
    for_each = var.deployment_circuit_breaker != null ? [true] : []

    content {
      enable   = var.deployment_circuit_breaker.enable
      rollback = var.deployment_circuit_breaker.rollback
    }
  }

  dynamic "load_balancer" {
    for_each = aws_alb_target_group.main

    content {
      container_name   = local.container_name
      container_port   = load_balancer.value.port
      target_group_arn = load_balancer.value.arn
    }
  }

  network_configuration {
    assign_public_ip = var.assign_public_ip
    security_groups  = concat(concat(var.security_groups, [for sg in module.sg : sg.this_security_group_id]), [])
    subnets          = data.aws_subnets.selected.ids
  }

  dynamic "service_registries" {
    for_each = var.service_discovery_dns_namespace != "" ? [true] : []

    content {
      registry_arn   = aws_service_discovery_service.this[0].arn
      container_name = var.container_name
    }
  }

  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

##############
# AUTOSCALING
##############

resource "aws_appautoscaling_target" "ecs_prevent_destroy" {
  count = var.appautoscaling_settings != null ? 1 : 0

  max_capacity       = lookup(var.appautoscaling_settings, "max_capacity", var.desired_count)
  min_capacity       = lookup(var.appautoscaling_settings, "min_capacity", var.desired_count)
  resource_id        = "service/${var.cluster_id}/${aws_ecs_service.prevent_destroy[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

resource "aws_appautoscaling_policy" "ecs_prevent_destroy" {
  count = var.appautoscaling_settings != null ? 1 : 0

  name               = "${var.service_name}-auto-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_prevent_destroy[count.index].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_prevent_destroy[count.index].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_prevent_destroy[count.index].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = lookup(var.appautoscaling_settings, "target_value")
    disable_scale_in   = lookup(var.appautoscaling_settings, "disable_scale_in", false)
    scale_in_cooldown  = lookup(var.appautoscaling_settings, "scale_in_cooldown", 300)
    scale_out_cooldown = lookup(var.appautoscaling_settings, "scale_out_cooldown", 30)

    predefined_metric_specification {
      predefined_metric_type = lookup(var.appautoscaling_settings, "predefined_metric_type", "ECSServiceAverageCPUUtilization")
      resource_label         = lookup(var.appautoscaling_settings, "resource_label", null)
    }
  }
}
