"""
VidScribe - Retry Logic Tests
=============================
Tests for NO_TRANSCRIPT retry logic in processor and poller.
"""

import json
import boto3
from moto import mock_aws
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

from tests.conftest import MockLambdaContext


class TestRetryLogic:
    """Tests for the retry mechanism."""

    @mock_aws
    def test_mark_video_failed_no_transcript_first_attempt(self):
        """Test first failure for NO_TRANSCRIPT sets up retry."""
        # Setup DynamoDB
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "S"}],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        
        # Import
        from src.processor.handler import mark_video_failed, RETRY_SCHEDULE_DAYS

        # Initial state: QUEUED
        video_id = "test_vid_1"
        table.put_item(Item={
            "pk": f"VIDEO#{video_id}",
            "sk": "METADATA",
            "video_id": video_id,
            "status": "QUEUED"
        })

        # Call mark_video_failed
        now_utc = datetime.now(timezone.utc)
        mark_video_failed(table, video_id, "NO_TRANSCRIPT", "No transcript available")

        # Verify state
        item = table.get_item(Key={"pk": f"VIDEO#{video_id}", "sk": "METADATA"})["Item"]
        assert item["status"] == "FAILED"
        assert item["failure_reason"] == "NO_TRANSCRIPT"
        assert item["retry_count"] == 1
        
        # Check first_failed_at is recent
        first_failed = datetime.fromisoformat(item["first_failed_at"])
        assert abs((first_failed - now_utc).total_seconds()) < 10

        # Check next_retry_at is scheduled correctly (Day 1 retry = +1 day from failed_at)
        # RETRY_SCHEDULE_DAYS = [1, 3, 5]
        # retry_count was 0, now became 1. Scheduling for attempt 1 (index 0 in array? No.)
        # Logic in handler:
        #   current_retry_count = item.get('retry_count', 0)
        #   new_retry_count = current_retry_count + 1
        #   days_wait = RETRY_SCHEDULE_DAYS[current_retry_count]  (index 0 -> 1 day)
        next_retry = datetime.fromisoformat(item["next_retry_at"])
        wait_seconds = (next_retry - first_failed).total_seconds()
        
        # Expect ~1 day (86400 seconds)
        assert 86300 < wait_seconds < 86500

    @mock_aws
    def test_mark_video_failed_retry_exhausted(self):
        """Test final failure marks as PERMANENTLY_FAILED."""
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "S"}],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        
        from src.processor.handler import mark_video_failed, MAX_TRANSCRIPT_RETRIES

        video_id = "test_vid_max"
        
        # Set explicitly to MAX_TRANSCRIPT_RETRIES to trigger exhaustion logic
        # If current retry_count == MAX_TRANSCRIPT_RETRIES, next attempt fails -> PERMANENTLY_FAILED
        table.put_item(Item={
            "pk": f"VIDEO#{video_id}",
            "sk": "METADATA",
            "video_id": video_id,
            "status": "FAILED",
            "retry_count": MAX_TRANSCRIPT_RETRIES, 
            "first_failed_at": "2026-01-01T00:00:00+00:00"
        })

        mark_video_failed(table, video_id, "NO_TRANSCRIPT", "Still no transcript")

        item = table.get_item(Key={"pk": f"VIDEO#{video_id}", "sk": "METADATA"})["Item"]
        assert item["status"] == "PERMANENTLY_FAILED"
        assert item["failure_reason"] == "NO_TRANSCRIPT_EXHAUSTED"

    @mock_aws
    def test_requeue_retryable_videos(self):
        """Test poller requeues eligible videos."""
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        sqs = boto3.resource("sqs", region_name="eu-west-1")
        
        table = dynamodb.create_table(
            TableName="vidscribe-test-videos",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "S"}],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        )
        queue = sqs.create_queue(QueueName="vidscribe-test-video-queue")
        
        from src.poller.handler import requeue_retryable_videos

        # 1. Eligible video (retry time passed)
        past_time = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
        table.put_item(Item={
            "pk": "VIDEO#retry_ready",
            "sk": "METADATA",
            "video_id": "retry_ready",
            "status": "FAILED",
            "failure_reason": "NO_TRANSCRIPT",
            "next_retry_at": past_time,
            "retry_count": 1
        })

        # 2. Not eligible (retry time in future)
        future_time = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        table.put_item(Item={
            "pk": "VIDEO#retry_future",
            "sk": "METADATA",
            "video_id": "retry_future",
            "status": "FAILED",
            "failure_reason": "NO_TRANSCRIPT",
            "next_retry_at": future_time,
            "retry_count": 1
        })
        
        # 3. Not eligible (wrong reason)
        table.put_item(Item={
            "pk": "VIDEO#other_fail",
            "sk": "METADATA",
            "video_id": "other_fail",
            "status": "FAILED",
            "failure_reason": "API_ERROR",
            "next_retry_at": past_time 
        })

        requeued_count = requeue_retryable_videos(table, queue)

        assert requeued_count == 1
        
        # Verify message in SQS
        messages = queue.receive_messages()
        assert len(messages) == 1
        body = json.loads(messages[0].body)
        assert body["video_id"] == "retry_ready"
        
        # Verify status update in DynamoDB
        item = table.get_item(Key={"pk": "VIDEO#retry_ready", "sk": "METADATA"})["Item"]
        assert item["status"] == "QUEUED"
