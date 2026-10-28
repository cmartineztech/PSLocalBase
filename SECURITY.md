# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

---

## Threat Model & Scope

**PSLocalBase** is an in-process, embedded document database engine designed for local PowerShell execution on Windows. 

- **Local Execution Boundary:** PSLocalBase runs entirely inside the caller's PowerShell process and communicates with Windows' native `C:\Windows\System32\winsqlite3.dll`. It does not expose network ports, sockets, or remote listening endpoints.
- **Operating System Access Control (ACL):** Physical file access security is governed by the host operating system's NTFS permissions and user Access Control Lists (ACLs).

---

## Defensive Security Architecture

### 1. Zero External Dependencies
- Relies exclusively on `winsqlite3.dll`, a trusted native Windows system binary maintained and patched directly by Microsoft via Windows Update.
- Eliminates software supply chain risks associated with third-party NuGet packages, external binaries, or unsigned dependencies.

### 2. Complete Anti-SQL Injection Defense (10/10)
- **Parameterized Query Binding:** All document writes (`.set()`, `.add()`, `.update()`) and filter queries (`.where()`) utilize parameterized `?` placeholders bound via native `sqlite3_bind_text16` in unmanaged memory.
- **Strict Identifier Whitelisting:**
  - Collection names: enforced via regex `^[a-zA-Z0-9_]+$`
  - Field paths: enforced via regex `^[a-zA-Z0-9_.]+$`
  - Query operators: restricted to a strict whitelist (`=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IN`)
  - Sorting directions: restricted strictly to `ASC` or `DESC`
- **Payload Safety:** Arbitrary user strings (including SQL syntax such as `' OR '1'='1` or `'; DROP TABLE; --`) are treated strictly as harmless literal text.

### 3. Source Code & Complex Payload Integrity
- Field values containing complex scripts, code snippets (PowerShell, Python, SQL), nested quotes, backslashes, dollar signs, and multiline strings are stored and retrieved byte-for-byte identical without interpretation or corruption.

### 4. Memory Safety & Handle Lifecycle
- **Native Unicode Marshaling:** Dynamic P/Invoke layer uses UTF-16 Unicode variants (`sqlite3_open16`, `sqlite3_prepare16_v2`, `sqlite3_bind_text16`, `sqlite3_column_text16`) matching Windows' and .NET's native string format to prevent encoding desynchronization or buffer overflows.
- **Leak Prevention:** All prepared SQLite statement pointers are scoped inside `try { ... } finally { [WinSqlite3]::Finalize($stmt) }` blocks to guarantee immediate destruction of unmanaged structures.
- **Non-blocking Concurrency:** Implements Write-Ahead Logging (`WAL`), `synchronous = NORMAL`, and a 5,000 ms busy handler to eliminate locking deadlocks across concurrent scripts.

---

## Reporting a Vulnerability

If you discover a security vulnerability or unexpected behavior in PSLocalBase, please report it responsibly:

1. **Do not create a public issue** on GitHub.
2. Please submit a private vulnerability report via **GitHub Security Advisories** or contact the author **[@cmartineztech](https://github.com/cmartineztech)** directly.
3. Include a description of the issue, minimal reproduction steps, and your PowerShell environment details.
4. The maintainer will review, verify, and release a patch in a timely manner.
