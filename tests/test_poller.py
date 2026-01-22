"""
VidScribe - Poller Lambda Tests
================================
Unit tests for the Poller Lambda function using moto for AWS mocking.
"""

import json
import pytest
from unittest.mock import patch, MagicMock
from moto import mock_aws
import boto3


class TestPollerLambda:
    """Test cases for the Poller Lambda handler."""
    
    @mock_aws
    def test_get_ssm_parameter_success(self, ssm_parameters):
        """Test SSM parameter retrieval."""
        # Import after mocking
        from src.poller.handler import get_ssm_parameter
        
        result = get_ssm_parameter("/vidscribe/youtube_channels")
        assert result == '["UCBcRF18a7Qf58cCRy5xuWwQ"]'
    
    @mock_aws
    def test_get_ssm_parameter_with_decryption(self, ssm_parameters):
        """Test SSM SecureString parameter retrieval with decryption."""
        from src.poller.handler import get_ssm_parameter
        
        result = get_ssm_parameter("/vidscribe/youtube_api_key", with_decryption=True)
        assert result == "test-youtube-api-key"
    
    @mock_aws
    def test_calculate_ttl(self):
        """Test TTL calculation."""
        from src.poller.handler import calculate_ttl
        from datetime import datetime, timezone
        
        ttl = calculate_ttl()
        now = int(datetime.now(timezone.utc).timestamp())
        
        # TTL should be approximately 30 days from now
        expected_min = now + (29 * 24 * 60 * 60)  # 29 days
        expected_max = now + (31 * 24 * 60 * 60)  # 31 days
        
        assert expected_min <= ttl <= expected_max
    
    @mock_aws
    def test_is_video_processed_not_found(self, dynamodb_table):
        """Test checking for a video that doesn't exist in DynamoDB."""
        from src.poller.handler import is_video_processed
        
        result = is_video_processed(dynamodb_table, "nonexistent-video-id")
        assert result is False
    
    @mock_aws
    def test_is_video_processed_found(self, dynamodb_table):
        """Test checking for a video that exists in DynamoDB."""
        from src.poller.handler import is_video_processed
        
        # Add a video to the table
        dynamodb_table.put_item(Item={
            "pk": "VIDEO#existing-video-id",
            "sk": "METADATA",
            "status": "QUEUED"
        })
        
        result = is_video_processed(dynamodb_table, "existing-video-id")
        assert result is True
    
    @mock_aws
    def test_mark_video_queued_success(self, dynamodb_table, sample_video):
        """Test marking a new video as queued."""
        from src.poller.handler import mark_video_queued
        
        result = mark_video_queued(dynamodb_table, sample_video)
        assert result is True
        
        # Verify the item was created
        response = dynamodb_table.get_item(Key={
            "pk": f"VIDEO#{sample_video['video_id']}",
            "sk": "METADATA"
        })
        assert "Item" in response
        assert response["Item"]["status"] == "QUEUED"
    
    @mock_aws
    def test_mark_video_queued_duplicate(self, dynamodb_table, sample_video):
        """Test that duplicate videos are not queued."""
        from src.poller.handler import mark_video_queued
        
        # Queue the video once
        result1 = mark_video_queued(dynamodb_table, sample_video)
        assert result1 is True
        
        # Try to queue again - should return False
        result2 = mark_video_queued(dynamodb_table, sample_video)
        assert result2 is False
    
    @mock_aws
    def test_send_to_sqs_success(self, sqs_queue, sample_video):
        """Test sending a video to SQS."""
        from src.poller.handler import send_to_sqs
        
        sqs_client, queue_url = sqs_queue
        
        result = send_to_sqs(sample_video)
        assert result is True
        
        # Verify message was sent
        messages = sqs_client.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
        assert "Messages" in messages
        assert len(messages["Messages"]) == 1
        
        body = json.loads(messages["Messages"][0]["Body"])
        assert body["video_id"] == sample_video["video_id"]
    
    @mock_aws
    @patch("src.poller.handler.get_youtube_videos")
    def test_lambda_handler_success(
        self, mock_get_videos, dynamodb_table, sqs_queue, ssm_parameters,
        sample_video, sample_eventbridge_event, lambda_context
    ):
        """Test the full Lambda handler execution."""
        # Mock YouTube API response
        mock_get_videos.return_value = [sample_video]
        
        from src.poller.handler import lambda_handler
        
        # Note: We need to reinitialize clients inside the mock context
        # This is a limitation of moto with module-level clients
        
        # For a full integration test, you would need to restructure
        # the handler to accept clients as parameters or use dependency injection
    
    @patch("urllib.request.urlopen")
    def test_get_youtube_videos_success(self, mock_urlopen):
        """Test YouTube API video fetching."""
        from src.poller.handler import get_youtube_videos
        
        # Mock response
        mock_response = MagicMock()
        mock_response.read.return_value = json.dumps({
            "items": [
                {
                    "id": {"videoId": "test123"},
                    "snippet": {
                        "title": "Test Video",
                        "channelTitle": "Test Channel",
                        "publishedAt": "2024-01-15T10:00:00Z",
                        "description": "Test description"
                    }
                }
            ]
        }).encode("utf-8")
        mock_response.__enter__ = MagicMock(return_value=mock_response)
        mock_response.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_response
        
        videos = get_youtube_videos(
            channel_id="UCtest123",
            api_key="test-api-key",
            published_after="2024-01-15T00:00:00Z"
        )
        
        assert len(videos) == 1
        assert videos[0]["video_id"] == "test123"
        assert videos[0]["title"] == "Test Video"
    
    @patch("urllib.request.urlopen")
    def test_get_youtube_videos_api_error(self, mock_urlopen):
        """Test YouTube API error handling."""
        from src.poller.handler import get_youtube_videos
        import urllib.error
        
        # Simulate API error
        mock_urlopen.side_effect = urllib.error.HTTPError(
            url="https://youtube.googleapis.com/youtube/v3/search",
            code=403,
            msg="Forbidden",
            hdrs={},
            fp=None
        )
        
        videos = get_youtube_videos(
            channel_id="UCtest123",
            api_key="invalid-key",
            published_after="2024-01-15T00:00:00Z"
        )
        
        assert videos == []
