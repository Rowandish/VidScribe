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
    
    # Check for proxy configuration
    proxy_type = os.environ.get("PROXY_TYPE", "none")
    
    if proxy_type == "webshare":
        username = os.environ.get("WEBSHARE_USERNAME")
        password = os.environ.get("WEBSHARE_PASSWORD")
        if username and password:
            print(f"Using Webshare proxy: {username}")
        else:
            print("PROXY_TYPE=webshare but credentials missing!")
    elif proxy_type == "generic":
        http_url = os.environ.get("GENERIC_PROXY_HTTP_URL", "")
        https_url = os.environ.get("GENERIC_PROXY_HTTPS_URL", "")
        if http_url or https_url:
            print(f"Using generic proxy")
        else:
            print("PROXY_TYPE=generic but URLs missing!")
    else:
        print(f"No proxy configured (PROXY_TYPE={proxy_type}). Testing direct connection.")

    transcript = get_transcript(video_id)
    
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
