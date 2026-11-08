@ECHO off
REM Fake az for Windows CI. A plain batch file like the real az.cmd (which runs Python), not an npm shim, so the
REM launcher starts it through cmd.exe. node is looked up on PATH here.
SETLOCAL
FOR %%N IN (node.exe) DO SET "FAKE_NODE=%%~$PATH:N"
IF NOT DEFINED FAKE_NODE (
  ECHO fake az: node.exe not found on PATH 1>&2
  EXIT /b 9009
)
"%FAKE_NODE%" "%~dp0node_modules\fake-az\cli.js" %*
EXIT /b %ERRORLEVEL%
