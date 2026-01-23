"""
VidScribe - Pytest Configuration and Fixtures
==============================================
Shared fixtures for testing Lambda functions with mocked AWS services.
"""

import json
import os
import pytest
import boto3
from moto import mock_aws
from datetime import datetime, timezone


# -----------------------------------------------------------------------------
# Environment Variables Fixture
# -----------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def aws_credentials():
    """Set fake AWS credentials for moto."""
    os.environ["AWS_ACCESS_KEY_ID"] = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_SECURITY_TOKEN"] = "testing"
    os.environ["AWS_SESSION_TOKEN"] = "testing"
    os.environ["AWS_DEFAULT_REGION"] = "eu-west-1"


@pytest.fixture(autouse=True)
def environment_variables():
    """Set environment variables for Lambda functions."""
    os.environ["DYNAMODB_TABLE_NAME"] = "vidscribe-test-videos"
    os.environ["SQS_QUEUE_URL"] = "https://sqs.eu-west-1.amazonaws.com/123456789012/vidscribe-test-queue"
    os.environ["SSM_YOUTUBE_CHANNELS"] = "/vidscribe/youtube_channels"
    os.environ["SSM_YOUTUBE_API_KEY"] = "/vidscribe/youtube_api_key"
    os.environ["SSM_LLM_CONFIG"] = "/vidscribe/llm_config"
    os.environ["SSM_LLM_API_KEY"] = "/vidscribe/llm_api_key"
    os.environ["SSM_DESTINATION_EMAIL"] = "/vidscribe/destination_email"
    os.environ["SSM_SENDER_EMAIL"] = "/vidscribe/sender_email"
    os.environ["TTL_DAYS"] = "30"
    os.environ["LOG_LEVEL"] = "DEBUG"


# -----------------------------------------------------------------------------
# DynamoDB Fixtures
# -----------------------------------------------------------------------------

@pytest.fixture
def dynamodb_table():
    """Create a mocked DynamoDB table."""
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
                {"AttributeName": "gsi1pk", "AttributeType": "S"},
                {"AttributeName": "gsi1sk", "AttributeType": "S"}
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "GSI1",
                    "KeySchema": [
                        {"AttributeName": "gsi1pk", "KeyType": "HASH"},
                        {"AttributeName": "gsi1sk", "KeyType": "RANGE"}
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                    "ProvisionedThroughput": {
                        "ReadCapacityUnits": 5,
                        "WriteCapacityUnits": 5
                    }
                }
            ],
            ProvisionedThroughput={
                "ReadCapacityUnits": 5,
                "WriteCapacityUnits": 5
            }
        )
        
        table.meta.client.get_waiter("table_exists").wait(TableName="vidscribe-test-videos")
        
        yield table


# -----------------------------------------------------------------------------
# SQS Fixtures
# -----------------------------------------------------------------------------

@pytest.fixture
def sqs_queue():
    """Create a mocked SQS queue."""
    with mock_aws():
        sqs = boto3.client("sqs", region_name="eu-west-1")
        
        # Create main queue
        response = sqs.create_queue(QueueName="vidscribe-test-queue")
        queue_url = response["QueueUrl"]
        
        # Update environment variable
        os.environ["SQS_QUEUE_URL"] = queue_url
        
        yield sqs, queue_url


# -----------------------------------------------------------------------------
# SSM Parameter Store Fixtures
# -----------------------------------------------------------------------------

@pytest.fixture
def ssm_parameters():
    """Create mocked SSM parameters."""
    with mock_aws():
        ssm = boto3.client("ssm", region_name="eu-west-1")
        
        # Create test parameters
        ssm.put_parameter(
            Name="/vidscribe/youtube_channels",
            Value='["UCBcRF18a7Qf58cCRy5xuWwQ"]',
            Type="String"
        )
        
        ssm.put_parameter(
            Name="/vidscribe/youtube_api_key",
            Value="test-youtube-api-key",
            Type="SecureString"
        )
        
        ssm.put_parameter(
            Name="/vidscribe/llm_config",
            Value='{"provider": "gemini", "model": "gemini-flash-latest"}',
            Type="String"
        )
        
        ssm.put_parameter(
            Name="/vidscribe/llm_api_key",
            Value="test-llm-api-key",
            Type="SecureString"
        )
        
        ssm.put_parameter(
            Name="/vidscribe/destination_email",
            Value="test@example.com",
            Type="String"
        )
        
        ssm.put_parameter(
            Name="/vidscribe/sender_email",
            Value="sender@example.com",
            Type="String"
        )
        
        yield ssm


# -----------------------------------------------------------------------------
# SES Fixtures
# -----------------------------------------------------------------------------

@pytest.fixture
def ses_client():
    """Create a mocked SES client with verified identities."""
    with mock_aws():
        ses = boto3.client("ses", region_name="eu-west-1")
        
        # Verify email identities
        ses.verify_email_identity(EmailAddress="sender@example.com")
        ses.verify_email_identity(EmailAddress="test@example.com")
        
        yield ses


# -----------------------------------------------------------------------------
# Sample Data Fixtures
# -----------------------------------------------------------------------------

@pytest.fixture
def sample_video():
    """Return a sample video dictionary."""
    return {
        "video_id": "abc123xyz",
        "title": "Test Video Title",
        "channel_id": "UCBcRF18a7Qf58cCRy5xuWwQ",
        "channel_title": "Test Channel",
        "published_at": datetime.now(timezone.utc).isoformat(),
        "description": "This is a test video description."
    }


@pytest.fixture
def sample_sqs_event(sample_video):
    """Return a sample SQS event for testing."""
    return {
        "Records": [
            {
                "messageId": "msg-12345",
                "receiptHandle": "receipt-handle-123",
                "body": json.dumps({
                    "video_id": sample_video["video_id"],
                    "title": sample_video["title"],
                    "channel_id": sample_video["channel_id"],
                    "channel_title": sample_video["channel_title"],
                    "published_at": sample_video["published_at"]
                }),
                "attributes": {
                    "ApproximateReceiveCount": "1"
                },
                "messageAttributes": {},
                "md5OfBody": "abc123",
                "eventSource": "aws:sqs",
                "eventSourceARN": "arn:aws:sqs:eu-west-1:123456789012:vidscribe-test-queue",
                "awsRegion": "eu-west-1"
            }
        ]
    }


@pytest.fixture
def sample_eventbridge_event():
    """Return a sample EventBridge scheduled event."""
    return {
        "version": "0",
        "id": "12345678-1234-1234-1234-123456789012",
        "detail-type": "Scheduled Event",
        "source": "aws.events",
        "account": "123456789012",
        "time": datetime.now(timezone.utc).isoformat(),
        "region": "eu-west-1",
        "resources": [
            "arn:aws:events:eu-west-1:123456789012:rule/vidscribe-poller-schedule"
        ],
        "detail": {}
    }


@pytest.fixture
def sample_summary():
    """Return a sample summary dictionary for DynamoDB."""
    now = datetime.now(timezone.utc)
    return {
        "pk": "SUMMARY#abc123xyz",
        "sk": "DATA",
        "gsi1pk": "SUMMARY",
        "gsi1sk": now.isoformat(),
        "video_id": "abc123xyz",
        "title": "Test Video Title",
        "channel_id": "UCBcRF18a7Qf58cCRy5xuWwQ",
        "channel_title": "Test Channel",
        "published_at": now.isoformat(),
        "summary": "This is a test summary of the video content.",
        "summarized_at": now.isoformat(),
        "ttl": int((now.timestamp()) + 30 * 24 * 60 * 60)
    }


# -----------------------------------------------------------------------------
# Lambda Context Mock
# -----------------------------------------------------------------------------

class MockLambdaContext:
    """Mock Lambda context object for testing."""
    
    def __init__(self):
        self.function_name = "test-function"
        self.function_version = "$LATEST"
        self.invoked_function_arn = "arn:aws:lambda:eu-west-1:123456789012:function:test-function"
        self.memory_limit_in_mb = 256
        self.aws_request_id = "test-request-id-12345"
        self.log_group_name = "/aws/lambda/test-function"
        self.log_stream_name = "2024/01/15/[$LATEST]abc123"
        self._remaining_time_ms = 30000
    
    def get_remaining_time_in_millis(self):
        return self._remaining_time_ms


@pytest.fixture
def lambda_context():
    """Return a mock Lambda context."""
    return MockLambdaContext()
