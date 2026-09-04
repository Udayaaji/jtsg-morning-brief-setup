# JTSG Morning Brief: setup

This repository exists to host one thing: the installer for the JTSG Morning
Brief, published on the Releases page. It is public so that the download link
is clickable without a GitHub account, and because email providers block
`.exe` attachments.

Nothing here reveals how the brief is produced. The master prompt, the
verification gates and the PDF generator live in a separate private
repository, which the installed application fetches with a read-only token.

## Status

No release published yet. The installer is built in Stage 1; until then this
page is a placeholder.

## What the installer will do

- Install to `%LOCALAPPDATA%\JTSG Morning Brief\` with no administrator rights
  and no change to the system PATH.
- Fetch its own private Python and dependencies at install time, so nothing
  already on the machine is touched or upgraded.
- Ask one question: which folder the daily PDF should be delivered to.
- Register a scheduled task that catches up when the laptop is opened, rather
  than firing at a fixed time and missing the day.
- Finish with a single interactive step: signing in to Claude.

## A note on the Windows warning

The installer is not code-signed, so Windows SmartScreen shows "Windows
protected your PC" the first time it runs. Choose "More info", then "Run
anyway". A code-signing certificate costs a few hundred dollars a year and is
not justified for a single client.
