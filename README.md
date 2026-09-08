# JTSG Morning Brief: setup

Public repository holding only the installer for the JTSG Morning Brief. The
installer is a bootstrapper: it carries the launcher and the setup logic, and
fetches everything else (a private Python, the pipeline from a private
repository using an access key typed at install time, Claude Code) when it
runs. It contains no secret and no pipeline code.

Download: https://github.com/Udayaaji/jtsg-morning-brief-setup/releases/latest/download/JTSG-Morning-Brief-Setup.exe

Guide: docs/INSTALL_GUIDE.md

Build: `powershell -File build_installer.ps1 -Version 1.0.0 -Publish`
(needs Inno Setup 6 and a signed-in `gh`).
