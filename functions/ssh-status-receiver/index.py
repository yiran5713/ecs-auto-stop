# -*- coding: utf-8 -*-
"""
SSH Status Receiver Function
Receives SSH connection status from ECS instances and stores in Table Store

HTTP Trigger: POST /ssh-status
"""

import json
import time
import logging
import os

# Alibaba Cloud SDK imports
from tablestore import OTSClient, Row, Condition, RowExistenceExpectation

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)


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
    
    logger.info(f"OTS endpoint: {endpoint}, instance: {instance_name}")
    logger.info(f"Credentials available: AK={'yes' if access_key_id else 'no'}, SK={'yes' if access_key_secret else 'no'}, Token={'yes' if security_token else 'no'}")
    
    if not access_key_id or not access_key_secret:
        raise ValueError("ALIBABA_CLOUD credentials not available in environment")
    
    return OTSClient(
        endpoint,
        access_key_id,
        access_key_secret,
        instance_name,
        sts_token=security_token
    )


def validate_auth_token(request_headers):
    """Validate the authentication token from request headers"""
    expected_token = os.environ.get('AUTH_TOKEN')
    if not expected_token:
        logger.warning("AUTH_TOKEN not configured, skipping authentication")
        return True
    
    # Get token from header (case-insensitive)
    request_token = None
    for key, value in request_headers.items():
        if key.lower() == 'x-auth-token':
            request_token = value
            break
    
    if not request_token:
        logger.warning("No X-Auth-Token header provided")
        return False
    
    return request_token == expected_token


def validate_instance_id(instance_id):
    """Validate that the instance ID is in the allowed list"""
    allowed_instances = os.environ.get('ALLOWED_INSTANCE_IDS', '')
    if not allowed_instances:
        logger.warning("ALLOWED_INSTANCE_IDS not configured, allowing all instances")
        return True
    
    allowed_list = [i.strip() for i in allowed_instances.split(',')]
    return instance_id in allowed_list


def update_status(ots_client, instance_id, ssh_count, timestamp):
    """Update SSH status in Table Store"""
    table_name = os.environ.get('OTS_TABLE_NAME', 'ecs_ssh_status')
    current_time = int(time.time())
    
    # Primary key
    primary_key = [('instance_id', instance_id)]
    
    # Attribute columns to update (name, value, timestamp) or (name, value)
    attribute_columns = [
        ('last_report_time', current_time),
        ('ssh_count', ssh_count),
        ('report_timestamp', timestamp)
    ]
    
    # Only update last_active_time if there are active SSH connections
    if ssh_count > 0:
        attribute_columns.append(('last_active_time', current_time))
    
    try:
        # Use put_row with primary_key and attribute_columns directly
        row = Row(primary_key, attribute_columns)
        condition = Condition(RowExistenceExpectation.IGNORE)
        consumed, return_row = ots_client.put_row(table_name, row, condition)
        logger.info(f"Updated status for instance {instance_id}: ssh_count={ssh_count}, consumed={consumed}")
        return True
    except Exception as e:
        logger.error(f"Failed to update status for {instance_id}: {type(e).__name__}: {str(e)}")
        raise


def handler(environ, start_response):
    """
    HTTP trigger handler for Function Compute
    
    Expected request body:
    {
        "instance_id": "i-xxxxx",
        "ssh_count": 0,
        "timestamp": 1234567890
    }
    """
    context = environ.get('fc.context')
    request_uri = environ.get('fc.request_uri', '')
    request_method = environ.get('REQUEST_METHOD', '')
    
    # Only accept POST requests
    if request_method != 'POST':
        status = '405 Method Not Allowed'
        response_body = json.dumps({'error': 'Only POST method is allowed'})
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
    
    # Get request headers
    request_headers = {}
    for key, value in environ.items():
        if key.startswith('HTTP_'):
            header_name = key[5:].replace('_', '-')
            request_headers[header_name] = value
    
    # Validate authentication token
    if not validate_auth_token(request_headers):
        status = '401 Unauthorized'
        response_body = json.dumps({'error': 'Invalid or missing authentication token'})
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
    
    # Read request body
    try:
        request_body_size = int(environ.get('CONTENT_LENGTH', 0))
        request_body = environ['wsgi.input'].read(request_body_size)
        data = json.loads(request_body.decode('utf-8'))
    except Exception as e:
        logger.error(f"Failed to parse request body: {str(e)}")
        status = '400 Bad Request'
        response_body = json.dumps({'error': 'Invalid JSON in request body'})
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
    
    # Validate required fields
    instance_id = data.get('instance_id')
    ssh_count = data.get('ssh_count')
    timestamp = data.get('timestamp')
    
    if not instance_id or ssh_count is None or timestamp is None:
        status = '400 Bad Request'
        response_body = json.dumps({'error': 'Missing required fields: instance_id, ssh_count, timestamp'})
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
    
    # Validate instance ID
    if not validate_instance_id(instance_id):
        logger.warning(f"Rejected report from unauthorized instance: {instance_id}")
        status = '403 Forbidden'
        response_body = json.dumps({'error': 'Instance ID not in allowed list'})
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
    
    # Update status in Table Store
    try:
        ots_client = get_ots_client()
        update_status(ots_client, instance_id, int(ssh_count), int(timestamp))
        
        status = '200 OK'
        response_body = json.dumps({
            'success': True,
            'message': 'Status updated successfully',
            'instance_id': instance_id,
            'ssh_count': ssh_count
        })
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
        
    except Exception as e:
        logger.error(f"Internal error: {str(e)}")
        status = '500 Internal Server Error'
        response_body = json.dumps({'error': 'Internal server error'})
        response_headers = [('Content-Type', 'application/json')]
        start_response(status, response_headers)
        return [response_body.encode()]
