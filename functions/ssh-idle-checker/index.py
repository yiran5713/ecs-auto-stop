# -*- coding: utf-8 -*-
"""
SSH Idle Checker Function
Checks for idle ECS instances and stops them if no SSH connections for over 1 hour

Trigger: FC Timer Trigger (every 5 minutes)
"""

import json
import time
import logging
import os

# Alibaba Cloud SDK imports
from tablestore import OTSClient, Row, Condition, RowExistenceExpectation
from tablestore import INF_MIN, INF_MAX, Direction

# International Alibaba Cloud ECS SDK (alibabacloud.com)
from alibabacloud_ecs20140526.client import Client as EcsClient
from alibabacloud_ecs20140526 import models as ecs_models
from alibabacloud_tea_openapi import models as open_api_models

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Constants
IDLE_THRESHOLD_SECONDS = 3600  # 1 hour
HEALTH_CHECK_THRESHOLD_SECONDS = 600  # 10 minutes


def get_ots_client():
    """Initialize Table Store client using FC service role credentials"""
    endpoint = os.environ.get('OTS_ENDPOINT')
    instance_name = os.environ.get('OTS_INSTANCE_NAME')
    
    if not endpoint or not instance_name:
        raise ValueError("OTS_ENDPOINT and OTS_INSTANCE_NAME environment variables are required")
    
    # Use FC built-in credentials (from service role)
    access_key_id = os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID')
    access_key_secret = os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
    security_token = os.environ.get('ALIBABA_CLOUD_SECURITY_TOKEN')
    
    return OTSClient(
        endpoint,
        access_key_id,
        access_key_secret,
        instance_name,
        sts_token=security_token
    )


def get_ecs_client(region_id):
    """Initialize ECS client using FC service role credentials (International SDK)"""
    access_key_id = os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID')
    access_key_secret = os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
    security_token = os.environ.get('ALIBABA_CLOUD_SECURITY_TOKEN')
    
    config = open_api_models.Config(
        access_key_id=access_key_id,
        access_key_secret=access_key_secret,
        security_token=security_token,
        region_id=region_id,
        endpoint=f'ecs.{region_id}.aliyuncs.com'
    )
    
    return EcsClient(config)


def get_instance_status(ecs_client, instance_id):
    """Get the current status of an ECS instance (International SDK)"""
    request = ecs_models.DescribeInstanceStatusRequest(
        instance_id=[instance_id]
    )
    
    try:
        response = ecs_client.describe_instance_status(request)
        instance_statuses = response.body.instance_statuses.instance_status
        if instance_statuses:
            return instance_statuses[0].status
        return None
    except Exception as e:
        logger.error(f"Failed to get instance status: {str(e)}")
        return None


def stop_instance(ecs_client, instance_id):
    """Stop an ECS instance (International SDK)"""
    request = ecs_models.StopInstanceRequest(
        instance_id=instance_id,
        stopped_mode='StopCharging'  # Stop charging when stopped (if supported)
    )
    
    try:
        response = ecs_client.stop_instance(request)
        logger.info(f"Stop instance request sent for {instance_id}: {response.body}")
        return True
    except Exception as e:
        logger.error(f"Failed to stop instance {instance_id}: {str(e)}")
        return False


def get_ssh_status(ots_client, instance_id):
    """Get SSH status for an instance from Table Store"""
    table_name = os.environ.get('OTS_TABLE_NAME', 'ecs_ssh_status')
    
    primary_key = [('instance_id', instance_id)]
    
    try:
        consumed, return_row, next_token = ots_client.get_row(
            table_name,
            primary_key,
            columns_to_get=['last_active_time', 'last_report_time', 'ssh_count']
        )
        
        if return_row is None:
            logger.warning(f"No status record found for instance {instance_id}")
            return None
        
        # Convert row to dict
        result = {}
        for col in return_row.attribute_columns:
            result[col[0]] = col[1]
        
        return result
    except Exception as e:
        logger.error(f"Failed to get SSH status: {str(e)}")
        return None


def send_notification(message, notification_type='info'):
    """
    Send notification (implement based on your needs)
    Options: DingTalk, SMS, Email, etc.
    """
    webhook_url = os.environ.get('DINGTALK_WEBHOOK')
    if webhook_url:
        try:
            import urllib.request
            data = json.dumps({
                'msgtype': 'text',
                'text': {
                    'content': f'[ECS Auto-Stop] {message}'
                }
            }).encode('utf-8')
            
            req = urllib.request.Request(
                webhook_url,
                data=data,
                headers={'Content-Type': 'application/json'}
            )
            urllib.request.urlopen(req, timeout=10)
            logger.info(f"Notification sent: {message}")
        except Exception as e:
            logger.error(f"Failed to send notification: {str(e)}")
    else:
        logger.info(f"Notification (no webhook configured): {message}")


def handler(event, context):
    """
    EventBridge scheduled trigger handler
    
    This function is triggered every 5 minutes to check for idle instances
    """
    logger.info("SSH Idle Checker started")
    
    # Get configuration
    target_instance_id = os.environ.get('TARGET_INSTANCE_ID')
    region_id = os.environ.get('REGION_ID', 'ap-northeast-1')
    
    if not target_instance_id:
        logger.error("TARGET_INSTANCE_ID environment variable is required")
        return {'success': False, 'error': 'Missing TARGET_INSTANCE_ID'}
    
    current_time = int(time.time())
    
    # Initialize clients
    ots_client = get_ots_client()
    ecs_client = get_ecs_client(region_id)
    
    # Get current SSH status
    status = get_ssh_status(ots_client, target_instance_id)
    
    if status is None:
        # No status record - either first run or ECS agent not reporting
        logger.warning(f"No status record for instance {target_instance_id}")
        send_notification(
            f"Warning: No SSH status record found for instance {target_instance_id}. "
            "The monitoring agent may not be installed or running.",
            'warning'
        )
        return {
            'success': True,
            'action': 'none',
            'reason': 'no_status_record'
        }
    
    last_active_time = status.get('last_active_time', 0)
    last_report_time = status.get('last_report_time', 0)
    ssh_count = status.get('ssh_count', 0)
    
    logger.info(f"Instance {target_instance_id}: last_active={last_active_time}, "
                f"last_report={last_report_time}, ssh_count={ssh_count}")
    
    # Health check: Check if ECS agent is reporting
    time_since_last_report = current_time - last_report_time
    if time_since_last_report > HEALTH_CHECK_THRESHOLD_SECONDS:
        # Check if instance is actually running
        instance_status = get_instance_status(ecs_client, target_instance_id)
        
        if instance_status == 'Running':
            # Instance is running but not reporting - potential issue
            send_notification(
                f"Warning: Instance {target_instance_id} is running but has not "
                f"reported SSH status for {time_since_last_report} seconds. "
                "The monitoring agent may have stopped.",
                'warning'
            )
        else:
            logger.info(f"Instance {target_instance_id} is not running (status: {instance_status})")
        
        return {
            'success': True,
            'action': 'none',
            'reason': 'no_recent_report',
            'instance_status': instance_status
        }
    
    # Check idle time
    idle_time = current_time - last_active_time
    logger.info(f"Instance {target_instance_id} idle time: {idle_time} seconds")
    
    if idle_time >= IDLE_THRESHOLD_SECONDS:
        # Instance has been idle for over 1 hour - stop it
        logger.info(f"Instance {target_instance_id} has been idle for {idle_time} seconds, "
                    f"exceeding threshold of {IDLE_THRESHOLD_SECONDS} seconds. Stopping...")
        
        # Verify instance is still running before stopping
        instance_status = get_instance_status(ecs_client, target_instance_id)
        
        if instance_status != 'Running':
            logger.info(f"Instance {target_instance_id} is not running (status: {instance_status}), "
                        "skipping stop operation")
            return {
                'success': True,
                'action': 'skipped',
                'reason': 'not_running',
                'instance_status': instance_status
            }
        
        # Stop the instance
        if stop_instance(ecs_client, target_instance_id):
            send_notification(
                f"Instance {target_instance_id} has been stopped due to no SSH connections "
                f"for {idle_time // 60} minutes.",
                'info'
            )
            return {
                'success': True,
                'action': 'stopped',
                'idle_time': idle_time,
                'instance_id': target_instance_id
            }
        else:
            send_notification(
                f"Failed to stop instance {target_instance_id} after {idle_time // 60} minutes "
                "of idle time. Please check manually.",
                'error'
            )
            return {
                'success': False,
                'action': 'stop_failed',
                'idle_time': idle_time,
                'instance_id': target_instance_id
            }
    else:
        # Instance is not idle long enough
        remaining_time = IDLE_THRESHOLD_SECONDS - idle_time
        logger.info(f"Instance {target_instance_id} will be stopped in {remaining_time} seconds "
                    "if no SSH connections are detected")
        return {
            'success': True,
            'action': 'none',
            'reason': 'not_idle_enough',
            'idle_time': idle_time,
            'remaining_time': remaining_time
        }
