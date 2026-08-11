#!/usr/bin/env python3
"""Diagnose the Python/SQLite runtime without touching Jellyfin data.

READ ONLY with respect to Jellyfin. This script only creates an in-memory
SQLite database and reports which runtime Python is actually using.
"""

import ctypes
import os
import platform
import sqlite3
import sys


def loaded_sqlite_dll_path():
    if os.name != "nt":
        return "<not Windows>"
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        get_module_handle = kernel32.GetModuleHandleW
        get_module_handle.argtypes = [ctypes.c_wchar_p]
        get_module_handle.restype = ctypes.c_void_p
        get_module_filename = kernel32.GetModuleFileNameW
        get_module_filename.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint]
        get_module_filename.restype = ctypes.c_uint

        handle = get_module_handle("sqlite3.dll")
        if not handle:
            return "<sqlite3.dll not found as a separately loaded module>"

        buffer = ctypes.create_unicode_buffer(32768)
        length = get_module_filename(handle, buffer, len(buffer))
        if not length:
            return "<GetModuleFileNameW failed: {0}>".format(ctypes.get_last_error())
        return buffer.value
    except Exception as exc:
        return "<unable to inspect: {0}>".format(exc)


def run_test(label, sql):
    connection = sqlite3.connect(":memory:")
    try:
        connection.executescript(sql)
        print("PASS: {0}".format(label))
        return True
    except Exception as exc:
        print("FAIL: {0}".format(label))
        print("      {0}: {1}".format(type(exc).__name__, exc))
        return False
    finally:
        connection.close()


def main():
    print("=== Python / SQLite Runtime Diagnosis ===")
    print("Python version:          {0}".format(sys.version.replace("\n", " ")))
    print("Python executable:       {0}".format(sys.executable))
    print("Platform:                {0}".format(platform.platform()))
    print("sqlite3 module:          {0}".format(getattr(sqlite3, "__file__", "<built-in>")))
    print("SQLite runtime version:  {0}".format(sqlite3.sqlite_version))
    print("SQLite version tuple:    {0}".format(sqlite3.sqlite_version_info))
    print("Loaded sqlite3.dll:      {0}".format(loaded_sqlite_dll_path()))
    print()

    try:
        connection = sqlite3.connect(":memory:")
        try:
            runtime = connection.execute("select sqlite_version()").fetchone()[0]
            options = [row[0] for row in connection.execute("pragma compile_options")]
        finally:
            connection.close()
        print("SELECT sqlite_version(): {0}".format(runtime))
        print("Compile options count:   {0}".format(len(options)))
    except Exception as exc:
        print("Unable to inspect SQLite runtime: {0}: {1}".format(type(exc).__name__, exc))
        return 2

    print()
    print("=== Feature Tests ===")
    basic_ok = run_test(
        "basic table/index",
        'CREATE TABLE Peoples (Name TEXT);\nCREATE INDEX IX_Normal ON Peoples (Name);',
    )
    expression_ok = run_test(
        "expression index used by Jellyfin 12",
        'CREATE TABLE Peoples (Name TEXT);\nCREATE INDEX IX_Peoples_NameLower ON Peoples (lower("Name"));',
    )

    print()
    print("=== Interpretation ===")
    if not basic_ok:
        print("The Python SQLite runtime is fundamentally broken.")
        return 3
    if not expression_ok:
        print("The Python interpreter works, but its SQLite runtime cannot parse")
        print("the expression-index syntax used by Jellyfin 12.")
        print("This is an abnormal Python/SQLite runtime combination.")
        return 4

    print("The Python SQLite runtime can parse Jellyfin's expression index.")
    print("If jellyfin.db still reports IX_Peoples_NameLower as malformed,")
    print("the next suspects are the exact database file/path or database contents,")
    print("not Python syntax support.")
    print()
    print("No Jellyfin files or databases were opened or modified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
