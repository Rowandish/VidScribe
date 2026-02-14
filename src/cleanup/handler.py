"""
VidScribe - Cleanup Lambda Handler
====================================
Monthly cleanup of permanently failed records from DynamoDB.

This Lambda is triggered by EventBridge on the 1st of each month. It:
1. Scans for PERMANENTLY_FAILED videos (retries exhausted)
2. Deletes both VIDEO#/METADATA and SUMMARY#/DATA records
3. Reports cleanup statistics
"""

import json
import logging
import os
from datetime import datetime, timezone, timedelta
from typing import Any

import boto3
from botocore.exceptions import ClientError

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "vidscribe-videos")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

# How old a PERMANENTLY_FAILED record must be before cleanup (days)
CLEANUP_AGE_DAYS = int(os.environ.get("CLEANUP_AGE_DAYS", "30"))

# Configure logging
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# AWS clients
dynamodb = boto3.resource("dynamodb")


# -----------------------------------------------------------------------------
# Cleanup Logic
# -----------------------------------------------------------------------------


def cleanup_permanently_failed(table) -> dict:
    """
    Scan DynamoDB for PERMANENTLY_FAILED records and delete them.

    Only deletes records where first_failed_at is older than CLEANUP_AGE_DAYS.

    Returns:
        Dict with cleanup statistics
    """
    stats = {
        "scanned": 0,
        "deleted": 0,
        "errors": 0
    }

    try:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=CLEANUP_AGE_DAYS)).isoformat()

        # Scan for permanently failed records
        scan_kwargs = {
            "FilterExpression": "#s = :status",
            "ExpressionAttributeNames": {"#s": "status"},
            "ExpressionAttributeValues": {
                ":status": "PERMANENTLY_FAILED"
            },
            "ProjectionExpression": "pk, sk, video_id, first_failed_at, failure_reason"
        }

        # Handle pagination
        while True:
            response = table.scan(**scan_kwargs)
            items = response.get("Items", [])

            for item in items:
                stats["scanned"] += 1
                video_id = item.get("video_id", "")
                first_failed = item.get("first_failed_at", "")

                # Only delete records older than the cutoff
                if first_failed and first_failed > cutoff:
                    logger.debug(
                        f"Skipping video {video_id}: failed at {first_failed}, "
                        f"cutoff is {cutoff}"
                    )
                    continue

                try:
                    # Delete the VIDEO#<id>/METADATA record
                    table.delete_item(
                        Key={
                            "pk": f"VIDEO#{video_id}",
                            "sk": "METADATA"
                        }
                    )

                    # Also delete the SUMMARY#<id>/DATA record if it exists
                    try:
                        table.delete_item(
                            Key={
                                "pk": f"SUMMARY#{video_id}",
                                "sk": "DATA"
                            }
                        )
                    except ClientError:
                        pass  # Summary might not exist for failed videos

                    stats["deleted"] += 1
                    logger.info(
                        f"Deleted permanently failed video: {video_id} "
                        f"(reason: {item.get('failure_reason', 'unknown')})"
                    )

                except ClientError as e:
                    logger.error(f"Error deleting video {video_id}: {e}")
                    stats["errors"] += 1

            # Check for pagination
            if "LastEvaluatedKey" in response:
                scan_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
            else:
                break

    except Exception as e:
        logger.error(f"Error during cleanup scan: {e}")
        stats["errors"] += 1

    return stats


# -----------------------------------------------------------------------------
# Lambda Handler
# -----------------------------------------------------------------------------


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Main Lambda handler for monthly cleanup.

    Deletes PERMANENTLY_FAILED records from DynamoDB that are older
    than CLEANUP_AGE_DAYS.

    Args:
        event: EventBridge event (scheduled)
        context: Lambda context object

    Returns:
        Dictionary with cleanup results
    """
    logger.info("Starting Cleanup Lambda execution")
    logger.debug(f"Event: {json.dumps(event)}")

    table = dynamodb.Table(DYNAMODB_TABLE_NAME)

    stats = cleanup_permanently_failed(table)

    logger.info(f"Cleanup complete: {json.dumps(stats)}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Cleanup complete",
            "stats": stats
        })
    }
