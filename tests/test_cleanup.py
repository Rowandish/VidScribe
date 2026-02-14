"""
VidScribe - Cleanup Lambda Tests
==================================
Tests for the monthly cleanup Lambda.
"""

import json
import os
import pytest
import boto3
from moto import mock_aws
from datetime import datetime, timezone, timedelta

from tests.conftest import MockLambdaContext


class TestCleanupHandler:
    """Tests for the cleanup Lambda handler."""

    @mock_aws
    def test_cleanup_permanently_failed_records(self):
        """Test that PERMANENTLY_FAILED records older than 30 days are deleted."""
        # Setup
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"}
            ],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        table.meta.client.get_waiter("table_exists").wait(TableName="vidscribe-test-videos")

        # Insert old PERMANENTLY_FAILED record (90 days old)
        old_failed = (datetime.now(timezone.utc) - timedelta(days=90)).isoformat()
        table.put_item(Item={
            "pk": "VIDEO#old_video",
            "sk": "METADATA",
            "video_id": "old_video",
            "status": "PERMANENTLY_FAILED",
            "failure_reason": "NO_TRANSCRIPT_EXHAUSTED",
            "first_failed_at": old_failed,
            "retry_count": 3
        })

        # Insert recent PERMANENTLY_FAILED record (5 days old)
        recent_failed = (datetime.now(timezone.utc) - timedelta(days=5)).isoformat()
        table.put_item(Item={
            "pk": "VIDEO#new_video",
            "sk": "METADATA",
            "video_id": "new_video",
            "status": "PERMANENTLY_FAILED",
            "failure_reason": "NO_TRANSCRIPT_EXHAUSTED",
            "first_failed_at": recent_failed,
            "retry_count": 3
        })

        from src.cleanup.handler import cleanup_permanently_failed
        stats = cleanup_permanently_failed(table)

        # Old record should be deleted, recent should be kept
        assert stats["deleted"] == 1

        # Verify old record is gone
        response = table.get_item(Key={"pk": "VIDEO#old_video", "sk": "METADATA"})
        assert "Item" not in response

        # Verify recent record still exists
        response = table.get_item(Key={"pk": "VIDEO#new_video", "sk": "METADATA"})
        assert "Item" in response

    @mock_aws
    def test_cleanup_skips_active_records(self):
        """Test that QUEUED and PROCESSED records are not deleted."""
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"}
            ],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        table.meta.client.get_waiter("table_exists").wait(TableName="vidscribe-test-videos")

        # Insert PROCESSED record
        table.put_item(Item={
            "pk": "VIDEO#good_video",
            "sk": "METADATA",
            "video_id": "good_video",
            "status": "PROCESSED"
        })

        # Insert QUEUED record
        table.put_item(Item={
            "pk": "VIDEO#queued_video",
            "sk": "METADATA",
            "video_id": "queued_video",
            "status": "QUEUED"
        })

        from src.cleanup.handler import cleanup_permanently_failed
        stats = cleanup_permanently_failed(table)

        assert stats["deleted"] == 0
        assert stats["scanned"] == 0  # Filter should exclude these

    @mock_aws
    def test_cleanup_deletes_summary_records(self):
        """Test that SUMMARY records are also cleaned up."""
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"}
            ],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        table.meta.client.get_waiter("table_exists").wait(TableName="vidscribe-test-videos")

        old_failed = (datetime.now(timezone.utc) - timedelta(days=60)).isoformat()

        # Insert VIDEO and SUMMARY records
        table.put_item(Item={
            "pk": "VIDEO#vid_with_summary",
            "sk": "METADATA",
            "video_id": "vid_with_summary",
            "status": "PERMANENTLY_FAILED",
            "failure_reason": "NO_TRANSCRIPT_EXHAUSTED",
            "first_failed_at": old_failed,
            "retry_count": 3
        })
        table.put_item(Item={
            "pk": "SUMMARY#vid_with_summary",
            "sk": "DATA",
            "video_id": "vid_with_summary",
            "summary": "partial summary content"
        })

        from src.cleanup.handler import cleanup_permanently_failed
        stats = cleanup_permanently_failed(table)

        assert stats["deleted"] == 1

        # Both records should be gone
        r1 = table.get_item(Key={"pk": "VIDEO#vid_with_summary", "sk": "METADATA"})
        assert "Item" not in r1
        r2 = table.get_item(Key={"pk": "SUMMARY#vid_with_summary", "sk": "DATA"})
        assert "Item" not in r2

    @mock_aws
    def test_lambda_handler(self):
        """Test the cleanup Lambda handler end-to-end."""
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"}
            ],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        table.meta.client.get_waiter("table_exists").wait(TableName="vidscribe-test-videos")

        old_failed = (datetime.now(timezone.utc) - timedelta(days=45)).isoformat()
        table.put_item(Item={
            "pk": "VIDEO#handler_test",
            "sk": "METADATA",
            "video_id": "handler_test",
            "status": "PERMANENTLY_FAILED",
            "failure_reason": "NO_TRANSCRIPT_EXHAUSTED",
            "first_failed_at": old_failed,
            "retry_count": 3
        })

        from src.cleanup.handler import lambda_handler
        event = {"source": "manual", "detail-type": "Test"}
        context = MockLambdaContext()

        result = lambda_handler(event, context)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["stats"]["deleted"] == 1
