import os
import sys
import logging
from typing import Optional

# Add src to path
sys.path.append(os.path.join(os.path.dirname(__file__), '..', 'src'))

try:
    from processor.handler import get_transcript
except ImportError:
    print("Error: Could not import get_transcript from src/processor/handler.py")
    sys.exit(1)

# Configure logging
logging.basicConfig(level=logging.INFO)

def test_video(video_id: str):
    print(f"\n--- Testing Video: {video_id} ---")
    
    # Check for credentials or proxy URL
    username = os.environ.get("WEBSHARE_USERNAME")
    password = os.environ.get("WEBSHARE_PASSWORD")
    proxy_url = os.environ.get("WEBSHARE_PROXY_URL")

    if proxy_url:
        print(f"Using direct proxy URL: {proxy_url[:15]}...")
    elif username and password:
        print(f"Using Webshare credentials: {username}")
    else:
        print("No proxy credentials found in environment. Testing without proxy.")

    transcript = get_transcript(
        video_id, 
        proxy_username=username, 
        proxy_password=password,
        proxy_url=proxy_url
    )
    
    if transcript:
        print("SUCCESS: Transcript downloaded!")
        print(f"Preview: {transcript[:200]}...")
    else:
        print("FAILED: Could not download transcript.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python scripts/test_transcript.py <video_id>")
        sys.exit(1)
    
    test_video(sys.argv[1])
