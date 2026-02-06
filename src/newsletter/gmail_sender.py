
import smtplib
import logging
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

logger = logging.getLogger()

class GmailSender:
    """
    Helper class to send emails via Gmail SMTP using an App Password.
    This bypasses AWS SES and is useful for personal projects without a verified domain.
    """
    
    def __init__(self, sender_email: str, app_password: str):
        self.sender_email = sender_email
        self.app_password = app_password
        self.smtp_server = "smtp.gmail.com"
        self.smtp_port = 587

    def send_email(self, recipient: str, subject: str, html_body: str, text_body: str) -> bool:
        """
        Send an email using Gmail SMTP.
        """
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = self.sender_email
        msg["To"] = recipient

        # Attach parts (HTML has precedence in modern clients, typically last part)
        part1 = MIMEText(text_body, "plain")
        part2 = MIMEText(html_body, "html")
        
        msg.attach(part1)
        msg.attach(part2)

        try:
            logger.info(f"Connecting to Gmail SMTP ({self.smtp_server}:{self.smtp_port})...")
            with smtplib.SMTP(self.smtp_server, self.smtp_port) as server:
                server.starttls()
                server.login(self.sender_email, self.app_password)
                server.sendmail(self.sender_email, recipient, msg.as_string())
            
            logger.info(f"Email sent successfully via Gmail to {recipient}")
            return True
            
        except smtplib.SMTPAuthenticationError:
            logger.error("Gmail authentication failed. Check your email and App Password.")
            return False
        except Exception as e:
            logger.error(f"Failed to send email via Gmail: {e}", exc_info=True)
            return False
