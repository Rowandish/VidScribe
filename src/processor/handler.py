"""
VidScribe - Processor Lambda Handler
=====================================
Downloads video transcripts and generates summaries using an LLM API.

This Lambda is triggered by SQS when new videos are queued. It:
1. Receives video metadata from SQS
2. Downloads the transcript using youtube-transcript-api
3. Sends the transcript to an LLM (Gemini or Groq) for summarization
4. Stores the summary in DynamoDB

Dependencies are provided via a Lambda Layer.
"""

import json
import logging
import os
import urllib.request
import urllib.parse
from datetime import datetime, timezone, timedelta
from typing import Any, Optional

import boto3
from botocore.exceptions import ClientError

# Import youtube-transcript-api from Lambda Layer
try:
    from youtube_transcript_api import YouTubeTranscriptApi
    from youtube_transcript_api.proxies import WebshareProxyConfig, GenericProxyConfig
    from youtube_transcript_api._errors import (
        NoTranscriptFound,
        TranscriptsDisabled,
        VideoUnavailable,
        IpBlocked,
        RequestBlocked,
    )
except ImportError:
    # Fallback for local testing
    YouTubeTranscriptApi = None
    WebshareProxyConfig = None
    GenericProxyConfig = None
    NoTranscriptFound = Exception
    TranscriptsDisabled = Exception
    VideoUnavailable = Exception

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Environment variables
DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "vidscribe-videos")
SSM_LLM_CONFIG = os.environ.get("SSM_LLM_CONFIG", "/vidscribe/llm_config")
SSM_LLM_API_KEY = os.environ.get("SSM_LLM_API_KEY", "/vidscribe/llm_api_key")
TTL_DAYS = int(os.environ.get("TTL_DAYS", "30"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

# Retry configuration for NO_TRANSCRIPT failures
# Retry schedule: attempt 1 (day 1), attempt 2 (day 3), attempt 3 (day 5)
MAX_TRANSCRIPT_RETRIES = 3
RETRY_SCHEDULE_DAYS = [1, 3, 5]  # days to wait after each attempt

# Proxy configuration
# PROXY_TYPE: 'webshare', 'generic', or 'none'
PROXY_TYPE = os.environ.get("PROXY_TYPE", "none").lower()
WEBSHARE_USERNAME = os.environ.get("WEBSHARE_USERNAME", "")
WEBSHARE_PASSWORD = os.environ.get("WEBSHARE_PASSWORD", "")
GENERIC_PROXY_HTTP_URL = os.environ.get("GENERIC_PROXY_HTTP_URL", "")
GENERIC_PROXY_HTTPS_URL = os.environ.get("GENERIC_PROXY_HTTPS_URL", "")

# Configure logging
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# AWS clients
ssm_client = boto3.client("ssm")
dynamodb = boto3.resource("dynamodb")

# LLM API endpoints
LLM_ENDPOINTS = {
    "gemini": "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
    "groq": "https://api.groq.com/openai/v1/chat/completions"
}

# Default summarization prompt
SUMMARIZATION_PROMPT = """You are a professional content curator and newsletter writer. 
Your goal is to transform YouTube transcripts into clear, structured, and highly readable summaries.

STRUCTURE REQUIREMENTS:
1. **Title**: Start with a catchy and descriptive headline (relevant to the video).
2. **TL;DR**: A single, impactful sentence summarizing the core value proposition.
3. **Key Takeaways**: A bulleted list of 3-5 main points using bold headers.
4. **Summary**: A brief, conversational paragraph giving more context.

FORMATTING RULES:
- Use Markdown for structure (headers, bolding, lists).
- Ensure there is double spacing between sections.
- Avoid "walls of text"; keep paragraphs short.
- Be written in {language}.

Video Title: {title}
Channel: {channel}

Transcript:
{transcript}

Please provide the newsletter-ready summary in {language}:"""

class TranscriptBlockedError(Exception):
    """Raised when YouTube blocks transcript requests from the current IP/network."""

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
    """
    try:
        response = ssm_client.get_parameter(Name=name, WithDecryption=with_decryption)
        return response["Parameter"]["Value"]
    except ClientError as e:
        logger.error(f"Failed to get SSM parameter {name}: {e}")
        raise


def calculate_ttl() -> int:
    """Calculate TTL timestamp for DynamoDB records."""
    expiry_time = datetime.now(timezone.utc) + timedelta(days=TTL_DAYS)
    return int(expiry_time.timestamp())


def get_transcript(video_id: str) -> Optional[str]:
    """
    Download the transcript for a YouTube video using youtube-transcript-api.

    Supports multiple proxy configurations via PROXY_TYPE env var:
    - 'webshare': Use Webshare rotating residential proxy
    - 'generic': Use any HTTP/HTTPS proxy (e.g. PacketStream, IPRoyal, Proxy-Cheap)
    - 'none': Direct connection (likely to be blocked from cloud IPs)

    Attempts to get transcripts in order of preference:
    1. Manually created English transcript
    2. Auto-generated English transcript
    3. Any available transcript (auto-translated to English)

    Returns:
        The transcript text, or None if unavailable.
        Raises TranscriptBlockedError if YouTube blocks requests from this IP/network.
    """
    if YouTubeTranscriptApi is None:
        logger.error("youtube-transcript-api not available")
        return None

    try:
        # Select proxy configuration based on PROXY_TYPE
        proxy_config = None
        
        if PROXY_TYPE == "webshare" and WEBSHARE_USERNAME and WEBSHARE_PASSWORD:
            logger.info(f"Using Webshare proxy for video {video_id}")
            proxy_config = WebshareProxyConfig(
                proxy_username=WEBSHARE_USERNAME,
                proxy_password=WEBSHARE_PASSWORD,
            )
        elif PROXY_TYPE == "generic" and (GENERIC_PROXY_HTTP_URL or GENERIC_PROXY_HTTPS_URL):
            logger.info(f"Using generic proxy for video {video_id}")
            proxy_config = GenericProxyConfig(
                http_url=GENERIC_PROXY_HTTP_URL or None,
                https_url=GENERIC_PROXY_HTTPS_URL or None,
            )
        else:
            logger.warning(f"No proxy configured (PROXY_TYPE={PROXY_TYPE}). Direct connection may be blocked.")
        
        # Create API instance with or without proxy
        if proxy_config:
            ytt_api = YouTubeTranscriptApi(proxy_config=proxy_config)
        else:
            ytt_api = YouTubeTranscriptApi()

        # New API: list available transcripts
        transcript_list = ytt_api.list(video_id)

        transcript = None

        try:
            transcript = transcript_list.find_manually_created_transcript(["en", "en-US", "en-GB"])
        except NoTranscriptFound:
            try:
                transcript = transcript_list.find_generated_transcript(["en", "en-US", "en-GB"])
            except NoTranscriptFound:
                # Try any transcript and translate to English
                try:
                    for t in transcript_list:
                        transcript = t.translate("en")
                        break
                except Exception as e:
                    logger.warning(f"Could not translate transcript: {e}")

        if transcript is None:
            logger.warning(f"No usable transcript found for video {video_id}")
            return None

        # New API: fetch() returns snippet objects with a .text attribute
        transcript_snippets = transcript.fetch()
        full_text = " ".join([s.text for s in transcript_snippets])

        # Truncate for LLM context limits
        max_chars = 30000
        if len(full_text) > max_chars:
            logger.info(f"Truncating transcript from {len(full_text)} to {max_chars} chars")
            full_text = full_text[:max_chars] + "... [transcript truncated]"

        logger.info(f"Successfully retrieved transcript for video {video_id} ({len(full_text)} chars)")
        return full_text

    except (IpBlocked, RequestBlocked) as e:
        # This is the important part for AWS Lambda: cloud IPs often get blocked
        msg = f"YouTube blocked transcript requests from this environment: {e}"
        logger.warning(msg)
        raise TranscriptBlockedError(msg) from e

    except TranscriptsDisabled:
        logger.warning(f"Transcripts are disabled for video {video_id}")
        return None

    except VideoUnavailable:
        logger.warning(f"Video {video_id} is unavailable")
        return None

    except Exception as e:
        logger.error(f"Error getting transcript for video {video_id}: {e}")
        return None



def summarize_with_gemini(transcript: str, title: str, channel: str, 
                          api_key: str, model: str, language: str) -> Optional[str]:
    """
    Generate a summary using Google's Gemini API.
    
    Args:
        transcript: The video transcript text
        title: Video title
        channel: Channel name
        api_key: Gemini API key
        model: Model name (e.g., "gemini-flash-latest")
        language: The language for the summary
    
    Returns:
        The generated summary, or None on error
    """
    prompt = SUMMARIZATION_PROMPT.format(
        title=title,
        channel=channel,
        transcript=transcript,
        language=language
    )
    
    url = LLM_ENDPOINTS["gemini"].format(model=model) + f"?key={api_key}"
    
    payload = {
        "contents": [{
            "parts": [{
                "text": prompt
            }]
        }],
        "generationConfig": {
            "temperature": 0.7,
            "maxOutputTokens": 1024
        }
    }
    
    try:
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(url, data=data)
        request.add_header("Content-Type", "application/json")
        
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.loads(response.read().decode("utf-8"))
        
        # Extract text from Gemini response
        candidates = result.get("candidates", [])
        if candidates:
            content = candidates[0].get("content", {})
            parts = content.get("parts", [])
            if parts:
                return parts[0].get("text", "")
        
        logger.warning(f"Unexpected Gemini response format: {result}")
        return None
        
    except urllib.error.HTTPError as e:
        logger.error(f"Gemini API HTTP error: {e.code} - {e.reason}")
        try:
            error_body = e.read().decode("utf-8")
            logger.error(f"Error details: {error_body}")
        except Exception:
            pass
        return None
    except Exception as e:
        logger.error(f"Error calling Gemini API: {e}")
        return None


def summarize_with_groq(transcript: str, title: str, channel: str,
                        api_key: str, model: str, language: str) -> Optional[str]:
    """
    Generate a summary using Groq's API.
    
    Args:
        transcript: The video transcript text
        title: Video title
        channel: Channel name
        api_key: Groq API key
        model: Model name (e.g., "llama-3.1-70b-versatile")
        language: The language for the summary
    
    Returns:
        The generated summary, or None on error
    """
    prompt = SUMMARIZATION_PROMPT.format(
        title=title,
        channel=channel,
        transcript=transcript,
        language=language
    )
    
    url = LLM_ENDPOINTS["groq"]
    
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "You are a helpful assistant that creates concise, informative summaries."
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.7,
        "max_tokens": 1024
    }
    
    try:
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(url, data=data)
        request.add_header("Content-Type", "application/json")
        request.add_header("Authorization", f"Bearer {api_key}")
        
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.loads(response.read().decode("utf-8"))
        
        # Extract text from Groq/OpenAI-compatible response
        choices = result.get("choices", [])
        if choices:
            message = choices[0].get("message", {})
            return message.get("content", "")
        
        logger.warning(f"Unexpected Groq response format: {result}")
        return None
        
    except urllib.error.HTTPError as e:
        logger.error(f"Groq API HTTP error: {e.code} - {e.reason}")
        try:
            error_body = e.read().decode("utf-8")
            logger.error(f"Error details: {error_body}")
        except Exception:
            pass
        return None
    except Exception as e:
        logger.error(f"Error calling Groq API: {e}")
        return None


def generate_summary(transcript: str, title: str, channel: str,
                     llm_config: dict, api_key: str) -> Optional[str]:
    """
    Generate a summary using the configured LLM provider.
    
    Args:
        transcript: The video transcript
        title: Video title
        channel: Channel name
        llm_config: Configuration dict with provider and model
        api_key: LLM API key
    
    Returns:
        The generated summary, or None on error
    """
    provider = llm_config.get("provider", "gemini").lower()
    model = llm_config.get("model", "gemini-flash-latest")
    language = llm_config.get("language", "English")
    
    logger.info(f"Generating summary using {provider} ({model}) in {language}")
    
    if provider == "gemini":
        return summarize_with_gemini(transcript, title, channel, api_key, model, language)
    elif provider == "groq":
        return summarize_with_groq(transcript, title, channel, api_key, model, language)
    else:
        logger.error(f"Unknown LLM provider: {provider}")
        return None


def save_summary(table, video: dict, summary: str) -> bool:
    """
    Save the video summary to DynamoDB.
    
    Creates two records:
    1. Updates the video METADATA record with status "PROCESSED"
    2. Creates a SUMMARY record for efficient querying by date
    
    Args:
        table: DynamoDB table resource
        video: Video metadata dictionary
        summary: The generated summary text
    
    Returns:
        True if successful, False otherwise
    """
    try:
        now = datetime.now(timezone.utc)
        now_iso = now.isoformat()
        ttl = calculate_ttl()
        
        # Update the video metadata to mark as processed
        table.update_item(
            Key={
                "pk": f"VIDEO#{video['video_id']}",
                "sk": "METADATA"
            },
            UpdateExpression="SET #status = :status, processed_at = :processed_at, summary = :summary",
            ExpressionAttributeNames={
                "#status": "status"
            },
            ExpressionAttributeValues={
                ":status": "PROCESSED",
                ":processed_at": now_iso,
                ":summary": summary
            }
        )
        
        # Create a summary record for GSI querying (for newsletter)
        table.put_item(
            Item={
                "pk": f"SUMMARY#{video['video_id']}",
                "sk": "DATA",
                "gsi1pk": "SUMMARY",  # Partition key for GSI
                "gsi1sk": now_iso,     # Sort key for date range queries
                "video_id": video["video_id"],
                "title": video["title"],
                "channel_id": video["channel_id"],
                "channel_title": video["channel_title"],
                "published_at": video["published_at"],
                "summary": summary,
                "summarized_at": now_iso,
                "ttl": ttl
            }
        )
        
        logger.info(f"Saved summary for video {video['video_id']}")
        return True
        
    except ClientError as e:
        logger.error(f"Error saving summary for video {video['video_id']}: {e}")
        return False


def get_retry_state(table, video_id: str) -> dict:
    """
    Get the current retry state for a video from DynamoDB.

    Returns:
        Dict with retry_count, first_failed_at, failure_reason, or empty dict if not found.
    """
    try:
        response = table.get_item(
            Key={
                "pk": f"VIDEO#{video_id}",
                "sk": "METADATA"
            },
            ProjectionExpression="retry_count, first_failed_at, failure_reason, #s",
            ExpressionAttributeNames={"#s": "status"}
        )
        item = response.get("Item", {})
        return {
            "retry_count": int(item.get("retry_count", 0)),
            "first_failed_at": item.get("first_failed_at", ""),
            "failure_reason": item.get("failure_reason", ""),
            "status": item.get("status", "")
        }
    except ClientError as e:
        logger.error(f"Error getting retry state for video {video_id}: {e}")
        return {}


def mark_video_failed(table, video_id: str, error: str, failure_reason: str = "FAILED") -> None:
    """
    Mark a video as failed in DynamoDB.

    For NO_TRANSCRIPT failures, implements a retry mechanism:
    - Up to MAX_TRANSCRIPT_RETRIES attempts (3)
    - Retry schedule: day 1, day 3, day 5
    - After exhausting retries: PERMANENTLY_FAILED / NO_TRANSCRIPT_EXHAUSTED

    failure_reason examples:
      - YOUTUBE_BLOCKED
      - NO_TRANSCRIPT
      - TRANSCRIPTS_DISABLED
      - VIDEO_UNAVAILABLE
      - UNKNOWN
    """
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()

    try:
        if failure_reason == "NO_TRANSCRIPT":
            # Get current retry state
            state = get_retry_state(table, video_id)
            current_retry = state.get("retry_count", 0)
            first_failed = state.get("first_failed_at", "") or now_iso

            new_retry_count = current_retry + 1

            if new_retry_count >= MAX_TRANSCRIPT_RETRIES:
                # Exhausted all retries → mark as permanently failed
                logger.warning(
                    f"Video {video_id} exhausted {MAX_TRANSCRIPT_RETRIES} transcript retries. "
                    f"Marking as PERMANENTLY_FAILED."
                )
                table.update_item(
                    Key={"pk": f"VIDEO#{video_id}", "sk": "METADATA"},
                    UpdateExpression=(
                        "SET #status = :status, #error = :error, "
                        "failure_reason = :reason, failed_at = :failed_at, "
                        "retry_count = :retry_count, first_failed_at = :first_failed"
                    ),
                    ExpressionAttributeNames={
                        "#status": "status",
                        "#error": "error"
                    },
                    ExpressionAttributeValues={
                        ":status": "PERMANENTLY_FAILED",
                        ":error": error[:500],
                        ":reason": "NO_TRANSCRIPT_EXHAUSTED",
                        ":failed_at": now_iso,
                        ":retry_count": new_retry_count,
                        ":first_failed": first_failed
                    }
                )
            else:
                # Schedule next retry
                days_until_retry = RETRY_SCHEDULE_DAYS[min(new_retry_count - 1, len(RETRY_SCHEDULE_DAYS) - 1)]
                next_retry = now + timedelta(days=days_until_retry)
                next_retry_iso = next_retry.isoformat()

                logger.info(
                    f"Video {video_id} NO_TRANSCRIPT attempt {new_retry_count}/{MAX_TRANSCRIPT_RETRIES}. "
                    f"Next retry at {next_retry_iso}"
                )
                table.update_item(
                    Key={"pk": f"VIDEO#{video_id}", "sk": "METADATA"},
                    UpdateExpression=(
                        "SET #status = :status, #error = :error, "
                        "failure_reason = :reason, failed_at = :failed_at, "
                        "retry_count = :retry_count, first_failed_at = :first_failed, "
                        "next_retry_at = :next_retry"
                    ),
                    ExpressionAttributeNames={
                        "#status": "status",
                        "#error": "error"
                    },
                    ExpressionAttributeValues={
                        ":status": "FAILED",
                        ":error": error[:500],
                        ":reason": "NO_TRANSCRIPT",
                        ":failed_at": now_iso,
                        ":retry_count": new_retry_count,
                        ":first_failed": first_failed,
                        ":next_retry": next_retry_iso
                    }
                )
        else:
            # Non-retryable failure — mark immediately
            table.update_item(
                Key={"pk": f"VIDEO#{video_id}", "sk": "METADATA"},
                UpdateExpression=(
                    "SET #status = :status, #error = :error, "
                    "failure_reason = :reason, failed_at = :failed_at"
                ),
                ExpressionAttributeNames={
                    "#status": "status",
                    "#error": "error"
                },
                ExpressionAttributeValues={
                    ":status": "FAILED",
                    ":error": error[:500],
                    ":reason": failure_reason[:100],
                    ":failed_at": now_iso
                }
            )
    except ClientError as e:
        logger.error(f"Error marking video {video_id} as failed: {e}")


# -----------------------------------------------------------------------------
# Lambda Handler
# -----------------------------------------------------------------------------


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Main Lambda handler function.
    
    Processes a single video from the SQS queue:
    1. Downloads the transcript
    2. Generates a summary using an LLM
    3. Stores the result in DynamoDB
    
    Args:
        event: SQS event containing the video message
        context: Lambda context object
    
    Returns:
        Dictionary with batch item failures for partial batch reporting
    """
    logger.info("Starting Processor Lambda execution")
    logger.debug(f"Event: {json.dumps(event)}")
    
    # Track failed items for partial batch reporting
    batch_item_failures = []
    
    # Get DynamoDB table
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)
    
    # Load LLM configuration
    try:
        llm_config_json = get_ssm_parameter(SSM_LLM_CONFIG)
        llm_config = json.loads(llm_config_json)
        llm_api_key = get_ssm_parameter(SSM_LLM_API_KEY, with_decryption=True)
        
        # Log proxy configuration
        logger.info(f"Proxy configuration: PROXY_TYPE={PROXY_TYPE}")

    except Exception as e:
        logger.error(f"Failed to load LLM configuration: {e}")
        # Fail all items if we can't get configuration
        for record in event.get("Records", []):
            batch_item_failures.append({
                "itemIdentifier": record["messageId"]
            })
        return {"batchItemFailures": batch_item_failures}
    
    # Process each SQS message
    for record in event.get("Records", []):
        message_id = record["messageId"]
        
        try:
            # Parse the video data from the SQS message
            video = json.loads(record["body"])
            video_id = video["video_id"]
            
            logger.info(f"Processing video: {video['title']} ({video_id})")
            
            # Step 1: Download the transcript
            try:
                transcript = get_transcript(video_id)
            except TranscriptBlockedError as e:
                # Cloud IP blocked: don't retry forever; classify explicitly
                logger.warning(f"Transcript blocked for video {video_id}: {e}")
                mark_video_failed(table, video_id, str(e), failure_reason="YOUTUBE_BLOCKED")
                continue

            if transcript is None:
                error_msg = "Failed to retrieve transcript"
                logger.warning(f"{error_msg} for video {video_id}")
                mark_video_failed(table, video_id, error_msg, failure_reason="NO_TRANSCRIPT")
                continue

            
            # Step 2: Generate summary with LLM
            summary = generate_summary(
                transcript=transcript,
                title=video["title"],
                channel=video["channel_title"],
                llm_config=llm_config,
                api_key=llm_api_key
            )
            
            if summary is None:
                error_msg = "Failed to generate summary"
                logger.error(f"{error_msg} for video {video_id}")
                # Add to failures to retry
                batch_item_failures.append({
                    "itemIdentifier": message_id
                })
                continue
            
            # Step 3: Save to DynamoDB
            if not save_summary(table, video, summary):
                batch_item_failures.append({
                    "itemIdentifier": message_id
                })
                continue
            
            logger.info(f"Successfully processed video: {video_id}")
            
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in SQS message: {e}")
            # Don't retry malformed messages
            continue
        except Exception as e:
            logger.error(f"Error processing message {message_id}: {e}", exc_info=True)
            batch_item_failures.append({
                "itemIdentifier": message_id
            })
    
    # Return batch item failures for SQS to requeue
    if batch_item_failures:
        logger.warning(f"Returning {len(batch_item_failures)} failed items for retry")
    
    return {"batchItemFailures": batch_item_failures}
