#!/usr/bin/env python3
import argparse
import email
import imaplib
import json
import os
from datetime import date
from email import policy
from email.parser import BytesParser
from email.utils import parsedate_to_datetime


def message_body(message: email.message.EmailMessage) -> str:
    if message.is_multipart():
        for part in message.walk():
            if part.get_content_type() == "text/plain" and part.get_content_disposition() != "attachment":
                return part.get_content().strip()
        for part in message.walk():
            if part.get_content_type() == "text/html" and part.get_content_disposition() != "attachment":
                return part.get_content().strip()
    return message.get_content().strip()


def today_messages() -> list[dict[str, str]]:
    host = os.environ.get("IMAP_HOST", "mail-server")
    port = int(os.environ.get("IMAP_PORT", "3143"))
    user = os.environ["MAIL_USER"]
    password = os.environ["MAIL_PASSWORD"]
    messages: list[dict[str, str]] = []
    with imaplib.IMAP4(host, port) as mailbox:
        mailbox.login(user, password)
        mailbox.select("INBOX", readonly=True)
        status, rows = mailbox.uid("search", None, "ALL")
        if status != "OK":
            raise RuntimeError("IMAP search failed")
        for uid in rows[0].split():
            status, parts = mailbox.uid("fetch", uid, "(RFC822)")
            if status != "OK" or not parts or not isinstance(parts[0], tuple):
                continue
            message = BytesParser(policy=policy.default).parsebytes(parts[0][1])
            received = parsedate_to_datetime(message["Date"]).date() if message.get("Date") else date.today()
            if received != date.today():
                continue
            messages.append({
                "id": uid.decode(),
                "sender": str(message.get("From", "unknown")),
                "subject": str(message.get("Subject", "(no subject)")),
                "received_date": received.isoformat(),
                "body": message_body(message),
            })
    return messages


def main() -> None:
    parser = argparse.ArgumentParser(description="Read the demo mailbox")
    parser.add_argument("scope", choices=["today"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    messages = today_messages()
    if args.json:
        print(json.dumps({"messages": messages}, ensure_ascii=False))
    else:
        for message in messages:
            print(f'{message["id"]}\t{message["sender"]}\t{message["subject"]}')


if __name__ == "__main__":
    main()

