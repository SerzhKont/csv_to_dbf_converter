@echo off
setlocal

rem Use UTF-8 so the Russian UI and box-drawing characters render correctly.
chcp 65001 >nul
title CSV to DBF Converter
cd /d "%~dp0"

where ruby >nul 2>&1
if errorlevel 1 (
    echo Ruby was not found in PATH.
    echo Install Ruby from https://rubyinstaller.org/ and try again.
    echo.
    pause
    exit /b 1
)

ruby "%~dp0csv_to_dbf_converter.rb"

if errorlevel 1 (
    echo.
    echo The program exited with an error.
    pause
)

endlocal
