# PSLocalBase Quick Start

A five-minute introduction. Every method used here is described in detail, with all options and edge cases, in the [Full Documentation](README.md).

PSLocalBase runs on Windows only, in Windows PowerShell 5.1 or PowerShell 7+, and has no dependencies beyond the `winsqlite3.dll` that ships with Windows.

---

## 1. Import and open a database

```powershell
# Install from PowerShell Gallery:
Install-Module -Name PSLocalBase -Scope CurrentUser
Import-Module PSLocalBase

# Or import from source: Import-Module .\PSLocalBase.psd1

# File on disk (parent folders are created automatically); ':memory:' for a throwaway database
$db = New-LocalBase -Path ".\app.db"
```

Always close the database when you are done, ideally in a `finally` block:

```powershell
$db = New-LocalBase -Path ".\app.db"
try {
    # ... work with $db ...
} finally {
    $db.close()
}
```

## 2. Write documents

```powershell
# Create or overwrite a document with a key you choose
$db.collection("users").doc("usr-100").set(@{
    name   = "Carlos Martinez"
    role   = "Admin"
    active = $true
    skills = @("PowerShell", "SQLite")
})

# Let PSLocalBase generate the key
$key = $db.collection("audit_logs").add(@{ action = "Login"; at = (Get-Date) })

# Merge fields into an existing document
$db.collection("users").doc("usr-100").update(@{ role = "Lead Architect" })

# Add to an array without duplicates
$db.collection("users").doc("usr-100").update(@{ skills = [PSLocalBase]::ArrayUnion("Security") })
```

Collections are created by the first write; navigating to a collection or document never creates a table. Dates are stored as ISO-8601 UTC text.

## 3. Read and query

```powershell
# One document by key ($null if it does not exist)
$user = $db.collection("users").doc("usr-100").get()
$user.name

# Filter, sort and paginate
$admins = $db.collection("users").
    where("active", "==", $true).
    where("role", "IN", @("Admin", "Lead Architect")).
    orderBy("name", "asc").
    limit(10).
    get()

# Counts and aggregates run inside SQLite
$total  = $db.collection("users").count()
$recent = $db.collection("audit_logs").where("at", ">=", (Get-Date).AddDays(-1)).count()
```

Queries are immutable: `where()`, `orderBy()`, `limit()` and the other modifiers return a new query, and writing through a query does not change it, so you can keep and reuse them.

## 4. Delete

```powershell
$db.collection("users").doc("usr-100").delete()             # one document
$db.collection("audit_logs").where("action", "=", "Login").delete()   # matching documents
$db.collection("audit_logs").drop()                           # the whole collection
```

## 5. Transactions

```powershell
$db.beginTransaction()
try {
    $db.collection("accounts").doc("a").update(@{ balance = 400 })
    $db.collection("accounts").doc("b").update(@{ balance = 600 })
    $db.commit()
} catch {
    $db.rollback()
    throw
}
```

`beginTransaction()` takes the write lock immediately, so other processes writing to the same file wait (up to `busyTimeout`, 5 seconds by default) instead of failing.

---

## Next steps

- [Full Documentation](README.md): every method, operator and option.
- [Technical Specification](SPECIFICATION.md): storage model and API contract.
- [Security Policy](../SECURITY.md): threat model and safe use of `query()`.
- [Playground](../Playground/README.md): a WPF app to explore a database visually.
- [Changelog](../CHANGELOG.md): what changed in 2.0.0.
