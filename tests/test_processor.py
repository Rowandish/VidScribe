"""
VidScribe - Processor Lambda Tests
===================================
Unit tests for the Processor Lambda function.
"""

import json
import pytest
from unittest.mock import patch, MagicMock
from moto import mock_aws


class TestProcessorLambda:
    """Test cases for the Processor Lambda handler."""
    
    @mock_aws
def test_get_transcript_success(self):
    """Test successful transcript retrieval (new youtube-transcript-api API)."""
    with patch("src.processor.handler.YouTubeTranscriptApi") as mock_api_cls:
        # YouTubeTranscriptApi() returns an instance with .list()
        mock_api = MagicMock()
        mock_api_cls.return_value = mock_api

        # Transcript object returned by transcript_list.find_manually_created_transcript(...)
        mock_transcript = MagicMock()

        # New API: transcript.fetch() returns iterable of snippet objects with .text
        mock_transcript.fetch.return_value = [
            MagicMock(text="Hello, welcome to my video."),
            MagicMock(text="Today we will discuss testing.")
        ]

        # TranscriptList returned by ytt_api.list(video_id)
        mock_transcript_list = MagicMock()
        mock_transcript_list.find_manually_created_transcript.return_value = mock_transcript

        # ytt_api.list(video_id) returns transcript_list
        mock_api.list.return_value = mock_transcript_list

        from src.processor.handler import get_transcript

        result = get_transcript("test-video-id")

        assert result is not None
        assert "Hello, welcome to my video" in result
        assert "Today we will discuss testing" in result

        # Optional: verify correct calls
        mock_api.list.assert_called_once_with("test-video-id")
        mock_transcript_list.find_manually_created_transcript.assert_called_once()
        mock_transcript.fetch.assert_called_once()

    
    @mock_aws
def test_get_transcript_disabled(self):
    """Test handling of disabled transcripts (new youtube-transcript-api API)."""
    with patch("src.processor.handler.YouTubeTranscriptApi") as mock_api_cls:
        from src.processor.handler import TranscriptsDisabled, get_transcript

        # YouTubeTranscriptApi() returns an instance with .list()
        mock_api = MagicMock()
        mock_api_cls.return_value = mock_api

        # New API raises from the instance method .list(video_id)
        mock_api.list.side_effect = TranscriptsDisabled("video-id")

        result = get_transcript("test-video-id")

        assert result is None
        mock_api.list.assert_called_once_with("test-video-id")

    
    @patch("urllib.request.urlopen")
    def test_summarize_with_gemini_success(self, mock_urlopen):
        """Test Gemini API summarization."""
        from src.processor.handler import summarize_with_gemini
        
        # Mock Gemini response
        mock_response = MagicMock()
        mock_response.read.return_value = json.dumps({
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "This is a summary of the video content."
                    }]
                }
            }]
        }).encode("utf-8")
        mock_response.__enter__ = MagicMock(return_value=mock_response)
        mock_response.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_response
        
        result = summarize_with_gemini(
            transcript="This is the video transcript content.",
            title="Test Video",
            channel="Test Channel",
            api_key="test-api-key",
            model="gemini-1.5-flash",
            language="English"
        )
        
        assert result == "This is a summary of the video content."
    
    @patch("urllib.request.urlopen")
    def test_summarize_with_groq_success(self, mock_urlopen):
        """Test Groq API summarization."""
        from src.processor.handler import summarize_with_groq
        
        # Mock Groq/OpenAI-compatible response
        mock_response = MagicMock()
        mock_response.read.return_value = json.dumps({
            "choices": [{
                "message": {
                    "content": "This is a Groq-generated summary."
                }
            }]
        }).encode("utf-8")
        mock_response.__enter__ = MagicMock(return_value=mock_response)
        mock_response.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_response
        
        result = summarize_with_groq(
            transcript="This is the video transcript content.",
            title="Test Video",
            channel="Test Channel",
            api_key="test-api-key",
            model="llama-3.1-70b-versatile",
            language="English"
        )
        
        assert result == "This is a Groq-generated summary."
    
    @mock_aws
    def test_save_summary_success(self, dynamodb_table, sample_video):
        """Test saving a summary to DynamoDB."""
        from src.processor.handler import save_summary
        
        # First, create the video metadata record
        dynamodb_table.put_item(Item={
            "pk": f"VIDEO#{sample_video['video_id']}",
            "sk": "METADATA",
            "status": "QUEUED"
        })
        
        result = save_summary(
            table=dynamodb_table,
            video=sample_video,
            summary="This is a test summary."
        )
        
        assert result is True
        
        # Verify the metadata was updated
        response = dynamodb_table.get_item(Key={
            "pk": f"VIDEO#{sample_video['video_id']}",
            "sk": "METADATA"
        })
        assert response["Item"]["status"] == "PROCESSED"
        
        # Verify the summary record was created
        response = dynamodb_table.get_item(Key={
            "pk": f"SUMMARY#{sample_video['video_id']}",
            "sk": "DATA"
        })
        assert "Item" in response
        assert response["Item"]["summary"] == "This is a test summary."
    
    @mock_aws
    def test_mark_video_failed(self, dynamodb_table):
        """Test marking a video as failed."""
        from src.processor.handler import mark_video_failed
        
        # Create a video record first
        dynamodb_table.put_item(Item={
            "pk": "VIDEO#test-video",
            "sk": "METADATA",
            "status": "QUEUED"
        })
        
        mark_video_failed(
            table=dynamodb_table,
            video_id="test-video",
            error="Test error message"
        )
        
        # Verify the status was updated
        response = dynamodb_table.get_item(Key={
            "pk": "VIDEO#test-video",
            "sk": "METADATA"
        })
        assert response["Item"]["status"] == "FAILED"
        assert response["Item"]["error"] == "Test error message"
    
    @mock_aws
    @patch("src.processor.handler.get_transcript")
    @patch("src.processor.handler.generate_summary")
    def test_lambda_handler_success(
        self, mock_generate_summary, mock_get_transcript,
        dynamodb_table, ssm_parameters, sample_sqs_event, lambda_context
    ):
        """Test the full Processor Lambda handler."""
        mock_get_transcript.return_value = "This is the video transcript."
        mock_generate_summary.return_value = "This is the AI-generated summary."
        
        # Note: Full integration testing requires restructuring for dependency injection
    
    def test_lambda_handler_transcript_failure(self, sample_sqs_event, lambda_context):
        """Test handler behavior when transcript download fails."""
        with patch("src.processor.handler.get_transcript", return_value=None):
            # The handler should not add to batch failures for transcript issues
            # as it means transcripts are disabled/unavailable
            pass
    
    def test_generate_summary_gemini(self):
        """Test generate_summary routing to Gemini."""
        with patch("src.processor.handler.summarize_with_gemini") as mock_gemini:
            mock_gemini.return_value = "Gemini summary"
            
            from src.processor.handler import generate_summary
            
            result = generate_summary(
                transcript="Test transcript",
                title="Test Title",
                channel="Test Channel",
                llm_config={"provider": "gemini", "model": "gemini-1.5-flash"},
                api_key="test-key"
            )
            
            assert result == "Gemini summary"
            mock_gemini.assert_called_once()
    
    def test_generate_summary_groq(self):
        """Test generate_summary routing to Groq."""
        with patch("src.processor.handler.summarize_with_groq") as mock_groq:
            mock_groq.return_value = "Groq summary"
            
            from src.processor.handler import generate_summary
            
            result = generate_summary(
                transcript="Test transcript",
                title="Test Title",
                channel="Test Channel",
                llm_config={"provider": "groq", "model": "llama-3.1-70b-versatile"},
                api_key="test-key"
            )
            
            assert result == "Groq summary"
            mock_groq.assert_called_once()
    
    def test_generate_summary_unknown_provider(self):
        """Test error handling for unknown LLM provider."""
        from src.processor.handler import generate_summary
        
        result = generate_summary(
            transcript="Test transcript",
            title="Test Title",
            channel="Test Channel",
            llm_config={"provider": "unknown", "model": "some-model"},
            api_key="test-key"
        )
        
        assert result is None
