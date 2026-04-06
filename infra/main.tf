# Terraform Configuration for ECS Auto-Stop Automation
# This configuration creates all required Alibaba Cloud resources

terraform {
  required_version = ">= 1.0.0"
  
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"
    }
  }
}

# Variables
variable "region" {
  description = "Alibaba Cloud region"
  type        = string
  default     = "ap-northeast-1"
}

variable "use_ecs_ram_role" {
  description = "Use ECS instance RAM role for authentication (set to true when running on ECS with attached RAM role)"
  type        = bool
  default     = false
}

variable "ecs_ram_role_name" {
  description = "ECS RAM role name (only used when use_ecs_ram_role is true)"
  type        = string
  default     = ""
}

variable "target_instance_id" {
  description = "ECS instance ID to monitor"
  type        = string
}

variable "auth_token" {
  description = "Authentication token for HTTP endpoint"
  type        = string
  sensitive   = true
}

variable "dingtalk_webhook" {
  description = "DingTalk webhook URL for notifications (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

# Provider configuration
# When running on ECS with RAM role, credentials are obtained automatically from instance metadata
provider "alicloud" {
  region = var.region
  
  # Use ECS RAM role for authentication when running on ECS instance
  # This fetches temporary credentials from the instance metadata service
  # If ecs_ram_role_name is empty, the provider will auto-detect the role
  ecs_role_name = var.use_ecs_ram_role ? (var.ecs_ram_role_name != "" ? var.ecs_ram_role_name : null) : null
}

# Get current account ID
data "alicloud_account" "current" {}

# Local variables
locals {
  project_name     = "ecs-auto-stop"
  ots_instance     = "ssh-monitor"
  ots_table        = "ecs_ssh_status"
  fc_service       = "ecs-auto-stop"
  log_project      = "ecs-auto-stop-logs"
  log_store        = "fc-logs"
}

#######################################
# Table Store (OTS) Resources
#######################################

resource "alicloud_ots_instance" "ssh_monitor" {
  name        = local.ots_instance
  description = "SSH monitor status storage"
  accessed_by = "Any"
  instance_type = "Capacity"
}

resource "alicloud_ots_table" "ecs_ssh_status" {
  instance_name = alicloud_ots_instance.ssh_monitor.name
  table_name    = local.ots_table
  
  primary_key {
    name = "instance_id"
    type = "String"
  }
  
  time_to_live = -1  # Never expire
  max_version  = 1
  
  depends_on = [alicloud_ots_instance.ssh_monitor]
}

#######################################
# Log Service Resources
#######################################

resource "alicloud_log_project" "fc_logs" {
  name        = local.log_project
  description = "Log project for ECS auto-stop functions"
}

resource "alicloud_log_store" "fc_logs" {
  project               = alicloud_log_project.fc_logs.name
  name                  = local.log_store
  retention_period      = 30
  shard_count           = 1
  auto_split            = true
  max_split_shard_count = 2
}

#######################################
# RAM Role and Policy
#######################################

resource "alicloud_ram_role" "fc_role" {
  name        = "fc-ecs-auto-stop-role"
  document    = file("${path.module}/ram-trust-policy.json")
  description = "Role for ECS Auto-Stop Function Compute service"
  force       = true
}

resource "alicloud_ram_policy" "fc_policy" {
  policy_name     = "fc-ecs-auto-stop-policy"
  policy_document = templatefile("${path.module}/ram-policy-template.json", {
    region            = var.region
    account_id        = data.alicloud_account.current.id
    instance_id       = var.target_instance_id
    ots_instance_name = local.ots_instance
    ots_table_name    = local.ots_table
    log_project       = local.log_project
    log_store         = local.log_store
  })
  description = "Policy for ECS Auto-Stop Function Compute service"
  force       = true
}

resource "alicloud_ram_role_policy_attachment" "fc_attachment" {
  role_name   = alicloud_ram_role.fc_role.name
  policy_name = alicloud_ram_policy.fc_policy.policy_name
  policy_type = "Custom"
}

#######################################
# Function Compute Resources
#######################################

resource "alicloud_fc_service" "ecs_auto_stop" {
  name        = local.fc_service
  description = "ECS Auto-Stop Service"
  role        = alicloud_ram_role.fc_role.arn
  
  log_config {
    project  = alicloud_log_project.fc_logs.name
    logstore = alicloud_log_store.fc_logs.name
  }
  
  depends_on = [
    alicloud_ram_role_policy_attachment.fc_attachment,
    alicloud_log_store.fc_logs
  ]
}

# Function: SSH Status Receiver
resource "alicloud_fc_function" "ssh_status_receiver" {
  service     = alicloud_fc_service.ecs_auto_stop.name
  name        = "ssh-status-receiver"
  description = "Receives SSH connection status from ECS instances"
  
  runtime     = "python3.9"
  handler     = "index.handler"
  memory_size = 128
  timeout     = 30
  
  filename = data.archive_file.ssh_status_receiver.output_path
  
  environment_variables = {
    OTS_ENDPOINT         = "https://${local.ots_instance}.${var.region}.ots.aliyuncs.com"
    OTS_INSTANCE_NAME    = local.ots_instance
    OTS_TABLE_NAME       = local.ots_table
    AUTH_TOKEN           = var.auth_token
    ALLOWED_INSTANCE_IDS = var.target_instance_id
  }
}

# Function: SSH Idle Checker
resource "alicloud_fc_function" "ssh_idle_checker" {
  service     = alicloud_fc_service.ecs_auto_stop.name
  name        = "ssh-idle-checker"
  description = "Checks for idle ECS instances and stops them"
  
  runtime     = "python3.9"
  handler     = "index.handler"
  memory_size = 256
  timeout     = 60
  
  filename = data.archive_file.ssh_idle_checker.output_path
  
  environment_variables = {
    OTS_ENDPOINT       = "https://${local.ots_instance}.${var.region}.ots.aliyuncs.com"
    OTS_INSTANCE_NAME  = local.ots_instance
    OTS_TABLE_NAME     = local.ots_table
    TARGET_INSTANCE_ID = var.target_instance_id
    REGION_ID          = var.region
    DINGTALK_WEBHOOK   = var.dingtalk_webhook
  }
}

# Package function code
data "archive_file" "ssh_status_receiver" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/ssh-status-receiver"
  output_path = "${path.module}/.terraform/ssh-status-receiver.zip"
}

data "archive_file" "ssh_idle_checker" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/ssh-idle-checker"
  output_path = "${path.module}/.terraform/ssh-idle-checker.zip"
}

#######################################
# HTTP Trigger for Status Receiver
#######################################

resource "alicloud_fc_trigger" "http_trigger" {
  service  = alicloud_fc_service.ecs_auto_stop.name
  function = alicloud_fc_function.ssh_status_receiver.name
  name     = "http-trigger"
  type     = "http"
  
  config = jsonencode({
    authType = "anonymous"
    methods  = ["POST"]
  })
}

#######################################
# Timer Trigger for Idle Checker
#######################################

resource "alicloud_fc_trigger" "timer_trigger" {
  service  = alicloud_fc_service.ecs_auto_stop.name
  function = alicloud_fc_function.ssh_idle_checker.name
  name     = "timer-trigger"
  type     = "timer"
  
  config = jsonencode({
    cronExpression = "0 0/5 * * * *"  # Every 5 minutes
    enable         = true
    payload        = jsonencode({ source = "timer-scheduler" })
  })
}

#######################################
# Outputs
#######################################

output "fc_http_endpoint" {
  description = "HTTP endpoint for SSH status receiver"
  value       = "https://${data.alicloud_account.current.id}.${var.region}.fc.aliyuncs.com/2016-08-15/proxy/${local.fc_service}/${alicloud_fc_function.ssh_status_receiver.name}/"
}

output "ots_instance_name" {
  description = "Table Store instance name"
  value       = local.ots_instance
}

output "ots_table_name" {
  description = "Table Store table name"
  value       = local.ots_table
}

output "fc_service_name" {
  description = "Function Compute service name"
  value       = local.fc_service
}

output "ram_role_arn" {
  description = "RAM role ARN for Function Compute"
  value       = alicloud_ram_role.fc_role.arn
}

output "log_project" {
  description = "Log Service project name"
  value       = local.log_project
}
