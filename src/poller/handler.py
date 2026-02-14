"""
VidScribe - Poller Lambda Handler
=================================
Polls YouTube channels for new videos and sends them to SQS for processing.

This Lambda is triggered by EventBridge every 12 hours. It:
1. Reads the list of YouTube channels from SSM Parameter Store
2. Uses the YouTube Data API to find videos published in the last 24 hours
3. Checks DynamoDB to avoid processing duplicate videos
4. Sends new video IDs to SQS for the Processor Lambda

Anti-flood protection: Only processes videos from the last 24 hours to prevent
processing entire channel history on first deployment.
"""

import json
import logging
import os
import urllib.request
import urllib.parse
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Environment variables
DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "vidscribe-videos")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
SSM_YOUTUBE_CHANNELS = os.environ.get("SSM_YOUTUBE_CHANNELS", "/vidscribe/youtube_channels")
SSM_YOUTUBE_API_KEY = os.environ.get("SSM_YOUTUBE_API_KEY", "/vidscribe/youtube_api_key")
TTL_DAYS = int(os.environ.get("TTL_DAYS", "30"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

# Configure logging
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# AWS clients
ssm_client = boto3.client("ssm")
dynamodb = boto3.resource("dynamodb")
sqs_client = boto3.client("sqs")

# YouTube API base URL
YOUTUBE_API_BASE = "https://www.googleapis.com/youtube/v3"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------


def get_ssm_parameter(name: str, with_decryption: bool = False) -> str:
    """
    Retrieve a parameter from AWS SSM Parameter Store.
    
    Args:
        name: The parameter name/path
        with_decryption: Whether to decrypt SecureString parameters
    
    Returns:
        The parameter value as a string
    
    Raises:
        ClientError: If the parameter cannot be retrieved
    """
    try:
        response = ssm_client.get_parameter(Name=name, WithDecryption=with_decryption)
        return response["Parameter"]["Value"]
    except ClientError as e:
        logger.error(f"Failed to get SSM parameter {name}: {e}")
        raise


def calculate_ttl() -> int:
    """
    Calculate the TTL timestamp for DynamoDB records.
    
    Returns:
        Unix timestamp for when the record should expire
    """
    expiry_time = datetime.now(timezone.utc) + timedelta(days=TTL_DAYS)
    return int(expiry_time.timestamp())


def get_youtube_videos(channel_id: str, api_key: str, published_after: str) -> list[dict]:
    """
    Fetch recent videos from a YouTube channel using the Data API v3.
    
    Args:
        channel_id: The YouTube channel ID
        api_key: YouTube Data API key
        published_after: ISO 8601 timestamp to filter videos
    
    Returns:
        List of video dictionaries with id, title, channelTitle, and publishedAt
    """
    videos = []
    
    # Build the API URL for searching videos
    params = {
        "part": "snippet",
        "channelId": channel_id,
        "type": "video",
        "order": "date",
        "publishedAfter": published_after,
        "maxResults": 50,  # Maximum allowed per request
        "key": api_key
    }
    
    url = f"{YOUTUBE_API_BASE}/search?{urllib.parse.urlencode(params)}"
    
    try:
        logger.info(f"Fetching videos for channel {channel_id} published after {published_after}")
        
        request = urllib.request.Request(url)
        request.add_header("Accept", "application/json")
        
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
        
        for item in data.get("items", []):
            video_id = item.get("id", {}).get("videoId")
            snippet = item.get("snippet", {})
            
            if video_id:
                videos.append({
                    "video_id": video_id,
                    "title": snippet.get("title", "Untitled"),
                    "channel_id": channel_id,
                    "channel_title": snippet.get("channelTitle", "Unknown Channel"),
                    "published_at": snippet.get("publishedAt", ""),
                    "description": snippet.get("description", "")[:500]  # Truncate description
                })
        
        logger.info(f"Found {len(videos)} videos for channel {channel_id}")
        
    except urllib.error.HTTPError as e:
        logger.error(f"YouTube API HTTP error for channel {channel_id}: {e.code} - {e.reason}")
        # Read error response body if available
        try:
            error_body = e.read().decode("utf-8")
            logger.error(f"Error details: {error_body}")
        except Exception:
            pass
    except urllib.error.URLError as e:
        logger.error(f"YouTube API URL error for channel {channel_id}: {e.reason}")
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse YouTube API response: {e}")
    
    return videos


def is_video_processed(table, video_id: str) -> bool:
    """
    Check if a video has already been processed or is queued for processing.
    
    Args:
        table: DynamoDB table resource
        video_id: The YouTube video ID
    
    Returns:
        True if the video exists in DynamoDB, False otherwise
    """
    try:
        response = table.get_item(
            Key={
                "pk": f"VIDEO#{video_id}",
                "sk": "METADATA"
            }
        )
        return "Item" in response
    except ClientError as e:
        logger.error(f"Error checking if video {video_id} exists: {e}")
        return False


def mark_video_queued(table, video: dict) -> bool:
    """
    Mark a video as queued in DynamoDB to prevent duplicate processing.
    
    Args:
        table: DynamoDB table resource
        video: Video dictionary with id, title, etc.
    
    Returns:
        True if successfully marked, False otherwise
    """
    try:
        now = datetime.now(timezone.utc).isoformat()
        ttl = calculate_ttl()
        
        table.put_item(
            Item={
                "pk": f"VIDEO#{video['video_id']}",
                "sk": "METADATA",
                "video_id": video["video_id"],
                "title": video["title"],
                "channel_id": video["channel_id"],
                "channel_title": video["channel_title"],
                "published_at": video["published_at"],
                "description": video["description"],
                "status": "QUEUED",
                "queued_at": now,
                "ttl": ttl
            },
            # Only write if the item doesn't already exist (idempotency)
            ConditionExpression="attribute_not_exists(pk)"
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info(f"Video {video['video_id']} already exists in DynamoDB")
            return False
        logger.error(f"Error marking video {video['video_id']} as queued: {e}")
        return False


def send_to_sqs(video: dict) -> bool:
    """
    Send a video to the SQS queue for processing.
    
    Args:
        video: Video dictionary to send
    
    Returns:
        True if successfully sent, False otherwise
    """
    try:
        message_body = json.dumps({
            "video_id": video["video_id"],
            "title": video["title"],
            "channel_id": video["channel_id"],
            "channel_title": video["channel_title"],
            "published_at": video["published_at"]
        })
        
        sqs_client.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=message_body,
            MessageGroupId=video["channel_id"] if ".fifo" in SQS_QUEUE_URL else None
        ) if ".fifo" in SQS_QUEUE_URL else sqs_client.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=message_body
        )
        
        logger.info(f"Sent video {video['video_id']} to SQS")
        return True
    except ClientError as e:
        logger.error(f"Error sending video {video['video_id']} to SQS: {e}")
        return False


# -----------------------------------------------------------------------------
# Retry Logic for NO_TRANSCRIPT Failures
# -----------------------------------------------------------------------------


def requeue_retryable_videos(table) -> dict:
    """
    Scan DynamoDB for NO_TRANSCRIPT failures eligible for retry and re-queue them.

    A video is eligible for retry if:
    - status == "FAILED"
    - failure_reason == "NO_TRANSCRIPT"
    - next_retry_at <= now (retry window has passed)

    Returns:
        Dict with requeue statistics
    """
    stats = {"scanned": 0, "requeued": 0, "errors": 0}

    try:
        now_iso = datetime.now(timezone.utc).isoformat()

        # Scan for retryable NO_TRANSCRIPT failures
        response = table.scan(
            FilterExpression=(
                "#s = :status AND failure_reason = :reason AND next_retry_at <= :now"
            ),
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":status": "FAILED",
                ":reason": "NO_TRANSCRIPT",
                ":now": now_iso
            },
            ProjectionExpression="pk, video_id, title, channel_id, channel_title, published_at, retry_count"
        )

        items = response.get("Items", [])
        stats["scanned"] = len(items)

        if not items:
            logger.info("No retryable NO_TRANSCRIPT videos found")
            return stats

        logger.info(f"Found {len(items)} retryable NO_TRANSCRIPT videos")

        for item in items:
            video_id = item.get("video_id", "")
            retry_count = int(item.get("retry_count", 0))

            video_data = {
                "video_id": video_id,
                "title": item.get("title", f"Retry: {video_id}"),
                "channel_id": item.get("channel_id", "RETRY"),
                "channel_title": item.get("channel_title", "Retry"),
                "published_at": item.get("published_at", now_iso)
            }

            logger.info(
                f"Re-queuing video {video_id} for transcript retry "
                f"(attempt {retry_count + 1})"
            )

            if send_to_sqs(video_data):
                stats["requeued"] += 1
            else:
                stats["errors"] += 1

    except Exception as e:
        logger.error(f"Error scanning for retryable videos: {e}")
        stats["errors"] += 1

    return stats


# -----------------------------------------------------------------------------
# Lambda Handler
# -----------------------------------------------------------------------------


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Main Lambda handler function.
    
    Polls YouTube channels for new videos and queues them for processing.
    Also re-queues retryable NO_TRANSCRIPT failures whose retry window has passed.
    
    Args:
        event: EventBridge event (or manual invocation payload)
        context: Lambda context object
    
    Returns:
        Dictionary with execution results
    """
    logger.info("Starting Poller Lambda execution")
    logger.debug(f"Event: {json.dumps(event)}")
    
    # Statistics for the response
    stats = {
        "channels_checked": 0,
        "videos_found": 0,
        "videos_queued": 0,
        "videos_skipped": 0,
        "errors": 0,
        "retries_requeued": 0
    }
    
    try:
        # Get configuration from SSM Parameter Store
        logger.info("Fetching configuration from SSM")
        youtube_channels_json = get_ssm_parameter(SSM_YOUTUBE_CHANNELS)
        youtube_api_key = get_ssm_parameter(SSM_YOUTUBE_API_KEY, with_decryption=True)
        
        # Parse channel list
        try:
            channel_ids = json.loads(youtube_channels_json)
            if not isinstance(channel_ids, list):
                raise ValueError("youtube_channels must be a JSON array")
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in youtube_channels parameter: {e}")
            return {
                "statusCode": 500,
                "body": json.dumps({"error": "Invalid youtube_channels configuration"})
            }
        
        logger.info(f"Monitoring {len(channel_ids)} channels")
        
        # Calculate the cutoff time (24 hours ago in ISO 8601 format)
        published_after = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        
        # Get DynamoDB table
        table = dynamodb.Table(DYNAMODB_TABLE_NAME)
        
        # Process each channel
        for channel_id in channel_ids:
            stats["channels_checked"] += 1
            
            try:
                # Fetch recent videos from YouTube
                videos = get_youtube_videos(channel_id, youtube_api_key, published_after)
                stats["videos_found"] += len(videos)
                
                # Process each video
                for video in videos:
                    # Check if already processed (idempotency)
                    if is_video_processed(table, video["video_id"]):
                        logger.debug(f"Skipping already processed video: {video['video_id']}")
                        stats["videos_skipped"] += 1
                        continue
                    
                    # Mark as queued in DynamoDB
                    if mark_video_queued(table, video):
                        # Send to SQS for processing
                        if send_to_sqs(video):
                            stats["videos_queued"] += 1
                            logger.info(f"Queued video: {video['title']} ({video['video_id']})")
                        else:
                            stats["errors"] += 1
                    else:
                        stats["videos_skipped"] += 1
                        
            except Exception as e:
                logger.error(f"Error processing channel {channel_id}: {e}")
                stats["errors"] += 1

        # Re-queue retryable NO_TRANSCRIPT failures
        retry_stats = requeue_retryable_videos(table)
        stats["retries_requeued"] = retry_stats.get("requeued", 0)
        if retry_stats.get("errors", 0) > 0:
            stats["errors"] += retry_stats["errors"]
        
        logger.info(f"Poller execution complete: {json.dumps(stats)}")
        
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Polling complete",
                "stats": stats
            })
        }
        
    except Exception as e:
        logger.error(f"Poller Lambda failed: {e}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({
                "error": str(e),
                "stats": stats
            })
        }

