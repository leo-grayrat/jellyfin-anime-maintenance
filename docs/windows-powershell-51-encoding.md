# Windows PowerShell 5.1 encoding issue

The main script must stay ASCII-only because Windows PowerShell 5.1 may misread UTF-8 files without BOM when they contain non-ASCII source text. The rules JSON may still contain Chinese/Japanese text because it is read explicitly as UTF-8.
