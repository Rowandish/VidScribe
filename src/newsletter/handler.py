"""
VidScribe - Newsletter Lambda Handler
======================================
Compiles and sends the weekly newsletter digest via Amazon SES.

This Lambda is triggered by EventBridge every Saturday at 09:00 UTC. It:
1. Queries DynamoDB for summaries created in the last 7 days
2. Formats them into a beautiful HTML email
3. Sends the email via AWS SES

Note: Both sender and recipient emails must be verified in SES sandbox mode.
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

try:
    import markdown
except ImportError:
    # Fallback for local testing if markdown is not installed
    markdown = None

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Environment variables
DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "vidscribe-videos")
SSM_DESTINATION_EMAIL = os.environ.get("SSM_DESTINATION_EMAIL", "/vidscribe/destination_email")
SSM_SENDER_EMAIL = os.environ.get("SSM_SENDER_EMAIL", "/vidscribe/sender_email")
AWS_SES_REGION = os.environ.get("AWS_SES_REGION", "eu-west-1")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

# Configure logging
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# AWS clients
ssm_client = boto3.client("ssm")
dynamodb = boto3.resource("dynamodb")
ses_client = boto3.client("ses", region_name=AWS_SES_REGION)

# -----------------------------------------------------------------------------
# HTML Email Template
# -----------------------------------------------------------------------------

EMAIL_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VidScribe Weekly Digest</title>
    <style>
        /* Reset and Base Styles */
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #f5f5f5;
        }}
        
        /* Container */
        .container {{
            max-width: 680px;
            margin: 0 auto;
            background-color: #ffffff;
        }}
        
        /* Header */
        .header {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px 30px;
            text-align: center;
        }}
        
        .header h1 {{
            font-size: 32px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: -0.5px;
        }}
        
        .header .subtitle {{
            font-size: 16px;
            opacity: 0.9;
        }}
        
        .header .date-range {{
            font-size: 14px;
            margin-top: 12px;
            padding: 8px 16px;
            background: rgba(255,255,255,0.2);
            border-radius: 20px;
            display: inline-block;
        }}
        
        /* Content */
        .content {{
            padding: 30px;
        }}
        
        .intro {{
            font-size: 16px;
            color: #555;
            margin-bottom: 30px;
            padding-bottom: 20px;
            border-bottom: 1px solid #eee;
        }}
        
        /* Video Card */
        .video-card {{
            background: #fafafa;
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 24px;
            border-left: 4px solid #667eea;
        }}
        
        .video-card:last-child {{
            margin-bottom: 0;
        }}
        
        .video-title {{
            font-size: 20px;
            font-weight: 600;
            color: #222;
            margin-bottom: 8px;
        }}
        
        .video-title a {{
            color: #667eea;
            text-decoration: none;
        }}
        
        .video-title a:hover {{
            text-decoration: underline;
        }}
        
        .video-meta {{
            font-size: 13px;
            color: #888;
            margin-bottom: 16px;
        }}
        
        .channel-name {{
            color: #667eea;
            font-weight: 500;
        }}
        
        .video-summary {{
            font-size: 15px;
            color: #444;
            line-height: 1.7;
        }}
        
        .video-summary p {{
            margin-bottom: 12px;
        }}
        
        .video-summary p:last-child {{
            margin-bottom: 0;
        }}
        
        .watch-link {{
            display: inline-block;
            margin-top: 16px;
            padding: 10px 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            text-decoration: none;
            border-radius: 6px;
            font-size: 14px;
            font-weight: 500;
        }}
        
        /* No Content */
        .no-content {{
            text-align: center;
            padding: 60px 30px;
            color: #888;
        }}
        
        .no-content-icon {{
            font-size: 48px;
            margin-bottom: 16px;
        }}
        
        /* Footer */
        .footer {{
            background: #f9f9f9;
            padding: 30px;
            text-align: center;
            border-top: 1px solid #eee;
        }}
        
        .footer p {{
            font-size: 13px;
            color: #888;
            margin-bottom: 8px;
        }}
        
        .footer a {{
            color: #667eea;
            text-decoration: none;
        }}
        
        /* Stats Badge */
        .stats-badge {{
            display: inline-block;
            background: #eef2ff;
            color: #667eea;
            padding: 6px 12px;
            border-radius: 16px;
            font-size: 13px;
            font-weight: 500;
            margin-bottom: 20px;
        }}
        
        /* Responsive */
        @media (max-width: 600px) {{
            .header {{
                padding: 30px 20px;
            }}
            .header h1 {{
                font-size: 26px;
            }}
            .content {{
                padding: 20px;
            }}
            .video-card {{
                padding: 18px;
            }}
            .video-title {{
                font-size: 18px;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📺 VidScribe</h1>
            <p class="subtitle">Your Weekly Video Digest</p>
            <span class="date-range">{date_range}</span>
        </div>
        
        <div class="content">
            {content}
        </div>
        
        <div class="footer">
            <p>Powered by <a href="https://github.com/yourusername/VidScribe">VidScribe</a></p>
            <p>You received this because you subscribed to video summaries.</p>
        </div>
    </div>
</body>
</html>
"""

VIDEO_CARD_TEMPLATE = """
<div class="video-card">
    <h2 class="video-title">
        <a href="https://youtube.com/watch?v={video_id}">{title}</a>
    </h2>
    <p class="video-meta">
        <span class="channel-name">{channel}</span> · {published_date}
    </p>
    <div class="video-summary">
        {summary}
    </div>
    <a href="https://youtube.com/watch?v={video_id}" class="watch-link">Watch Video →</a>
</div>
"""

NO_CONTENT_HTML = """
<div class="no-content">
    <div class="no-content-icon">📭</div>
    <h2>No New Videos This Week</h2>
    <p>None of your subscribed channels published new content with available transcripts.</p>
</div>
"""

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------


def get_ssm_parameter(name: str, with_decryption: bool = False) -> str:
    """Retrieve a parameter from AWS SSM Parameter Store."""
    try:
        response = ssm_client.get_parameter(Name=name, WithDecryption=with_decryption)
        return response["Parameter"]["Value"]
    except ClientError as e:
        logger.error(f"Failed to get SSM parameter {name}: {e}")
        raise


def get_weekly_summaries(table) -> list[dict]:
    """
    Query DynamoDB for summaries from the last 7 days.
    
    Uses the GSI1 index where:
    - gsi1pk = "SUMMARY"
    - gsi1sk = ISO timestamp (for range queries)
    
    Args:
        table: DynamoDB table resource
    
    Returns:
        List of summary records sorted by date (newest first)
    """
    # Calculate date range
    now = datetime.now(timezone.utc)
    week_ago = now - timedelta(days=7)
    week_ago_iso = week_ago.isoformat()
    
    logger.info(f"Querying summaries from {week_ago_iso} to now")
    
    try:
        response = table.query(
            IndexName="GSI1",
            KeyConditionExpression="gsi1pk = :pk AND gsi1sk >= :start_date",
            ExpressionAttributeValues={
                ":pk": "SUMMARY",
                ":start_date": week_ago_iso
            },
            ScanIndexForward=False  # Newest first
        )
        
        summaries = response.get("Items", [])
        logger.info(f"Found {len(summaries)} summaries")
        
        return summaries
        
    except ClientError as e:
        logger.error(f"Error querying summaries: {e}")
        return []


def format_summary_html(summary_text: str) -> str:
    """
    Convert Markdown summary to HTML.
    
    Args:
        summary_text: The Markdown format summary
    
    Returns:
        HTML formatted string
    """
    if markdown:
        # Convert markdown to HTML
        return markdown.markdown(summary_text)
    
    # Fallback if markdown library is missing
    # Split by double newlines or single newlines
    paragraphs = summary_text.strip().split("\n\n")
    if len(paragraphs) == 1:
        paragraphs = summary_text.strip().split("\n")
    
    html_parts = []
    for p in paragraphs:
        p = p.strip()
        if p:
            html_parts.append(f"<p>{p}</p>")
    return "\n".join(html_parts)


def format_date(iso_date: str) -> str:
    """
    Format an ISO date string for display.
    
    Args:
        iso_date: ISO 8601 date string
    
    Returns:
        Human-readable date string (e.g., "Jan 15, 2024")
    """
    try:
        dt = datetime.fromisoformat(iso_date.replace("Z", "+00:00"))
        return dt.strftime("%b %d, %Y")
    except Exception:
        return iso_date


def build_email_content(summaries: list[dict]) -> tuple[str, str]:
    """
    Build the HTML and plain text email content.
    
    Args:
        summaries: List of summary records from DynamoDB
    
    Returns:
        Tuple of (html_content, plain_text_content)
    """
    now = datetime.now(timezone.utc)
    week_ago = now - timedelta(days=7)
    date_range = f"{week_ago.strftime('%b %d')} - {now.strftime('%b %d, %Y')}"
    
    if not summaries:
        html = EMAIL_TEMPLATE.format(
            date_range=date_range,
            content=NO_CONTENT_HTML
        )
        plain = f"VidScribe Weekly Digest ({date_range})\n\nNo new videos this week."
        return html, plain
    
    # Build video cards
    cards = []
    plain_parts = [f"VidScribe Weekly Digest ({date_range})\n"]
    plain_parts.append(f"{len(summaries)} video(s) summarized this week:\n")
    
    for i, summary in enumerate(summaries, 1):
        # HTML card
        card = VIDEO_CARD_TEMPLATE.format(
            video_id=summary.get("video_id", ""),
            title=summary.get("title", "Untitled Video"),
            channel=summary.get("channel_title", "Unknown Channel"),
            published_date=format_date(summary.get("published_at", "")),
            summary=format_summary_html(summary.get("summary", "No summary available."))
        )
        cards.append(card)
        
        # Plain text version
        plain_parts.append(f"\n{i}. {summary.get('title', 'Untitled')}")
        plain_parts.append(f"   Channel: {summary.get('channel_title', 'Unknown')}")
        plain_parts.append(f"   Link: https://youtube.com/watch?v={summary.get('video_id', '')}")
        plain_parts.append(f"\n{summary.get('summary', 'No summary available.')}\n")
    
    # Stats badge
    stats = f'<span class="stats-badge">📊 {len(summaries)} video(s) summarized</span>'
    intro = f"{stats}\n<p class=\"intro\">Here's what you missed from your favorite YouTube channels this week. Enjoy your personalized video summaries!</p>"
    
    html = EMAIL_TEMPLATE.format(
        date_range=date_range,
        content=intro + "\n".join(cards)
    )
    
    plain = "\n".join(plain_parts)
    
    return html, plain


def send_email(sender: str, recipient: str, subject: str, 
               html_body: str, text_body: str) -> bool:
    """
    Send an email via Amazon SES.
    
    Args:
        sender: Verified sender email address
        recipient: Recipient email address
        subject: Email subject line
        html_body: HTML version of the email
        text_body: Plain text version of the email
    
    Returns:
        True if successful, False otherwise
    """
    try:
        response = ses_client.send_email(
            Source=sender,
            Destination={
                "ToAddresses": [recipient]
            },
            Message={
                "Subject": {
                    "Charset": "UTF-8",
                    "Data": subject
                },
                "Body": {
                    "Html": {
                        "Charset": "UTF-8",
                        "Data": html_body
                    },
                    "Text": {
                        "Charset": "UTF-8",
                        "Data": text_body
                    }
                }
            }
        )
        
        message_id = response.get("MessageId", "unknown")
        logger.info(f"Email sent successfully. Message ID: {message_id}")
        return True
        
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        error_msg = e.response.get("Error", {}).get("Message", str(e))
        logger.error(f"Failed to send email: {error_code} - {error_msg}")
        return False


# -----------------------------------------------------------------------------
# Lambda Handler
# -----------------------------------------------------------------------------


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Main Lambda handler function.
    
    Compiles and sends the weekly newsletter digest.
    
    Args:
        event: EventBridge event (or manual invocation payload)
        context: Lambda context object
    
    Returns:
        Dictionary with execution results
    """
    logger.info("Starting Newsletter Lambda execution")
    logger.debug(f"Event: {json.dumps(event)}")
    
    try:
        # Get email configuration from SSM
        sender_email = get_ssm_parameter(SSM_SENDER_EMAIL)
        destination_email = get_ssm_parameter(SSM_DESTINATION_EMAIL)
        
        if not sender_email or not destination_email:
            raise ValueError("Sender and destination emails must be configured in SSM")
        
        logger.info(f"Sending newsletter from {sender_email} to {destination_email}")
        
        # Get DynamoDB table
        table = dynamodb.Table(DYNAMODB_TABLE_NAME)
        
        # Query summaries from the last 7 days
        summaries = get_weekly_summaries(table)
        
        # Build email content
        html_body, text_body = build_email_content(summaries)
        
        # Generate subject line
        now = datetime.now(timezone.utc)
        subject = f"📺 VidScribe Weekly Digest - {now.strftime('%b %d, %Y')}"
        
        if summaries:
            # Add video count to subject
            subject = f"📺 VidScribe: {len(summaries)} New Video Summary{'s' if len(summaries) > 1 else ''} This Week"
        
        # Send the email
        success = send_email(
            sender=sender_email,
            recipient=destination_email,
            subject=subject,
            html_body=html_body,
            text_body=text_body
        )
        
        if success:
            return {
                "statusCode": 200,
                "body": json.dumps({
                    "message": "Newsletter sent successfully",
                    "summaries_count": len(summaries),
                    "recipient": destination_email
                })
            }
        else:
            return {
                "statusCode": 500,
                "body": json.dumps({
                    "error": "Failed to send email",
                    "summaries_count": len(summaries)
                })
            }
        
    except Exception as e:
        logger.error(f"Newsletter Lambda failed: {e}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({
                "error": str(e)
            })
        }
