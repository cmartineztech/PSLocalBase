# PSLocalBase Playground

An interactive Windows desktop visual playground for **PSLocalBase** inspired by Danny Connell's Localbase Playground and built with the clean Windows enterprise design system from `LiteDeploy.DynamicDrivers`.

Features a modern dual-pane desktop workspace built entirely with native **PowerShell + WPF**:
* **Left Pane (Interactive Code Cards):** Interactive tutorial cards for **Adding Data**, **Getting Data**, **Updating Data**, **Deleting Data**, and **Custom PowerShell Script** with live editable code snippets, target collection synchronization, and `RUN CODE ▶` buttons.
* **Right Pane (Database Explorer & Execution Console):**
  * **Database Explorer:** Multi-collection inspector (`users`, `products`, `orders`), live DataGrid with `#`, `Document ID / Key`, and formatted JSON payloads, real-time search by key or text value, and double-click document inspection.
  * **Execution Console:** Real-time log stream showing formatted JSON representations, execution timestamps, status badges, and sub-millisecond execution times.
  * **Live CLI Prompt:** Type any ad-hoc `$db` expression at the bottom `>` prompt and press <kbd>Enter</kbd> to execute immediately!

---

## Quick Launch

From PowerShell 7+ or Windows PowerShell 5.1:

```powershell
# In PowerShell Core 7+
pwsh -ExecutionPolicy Bypass -File .\Playground\Playground.ps1

# In Windows PowerShell 5.1
powershell.exe -ExecutionPolicy Bypass -File .\Playground\Playground.ps1
```

---

## Features

1. **Interactive Database Operations:**
   - **Adding Data:** Test `.add()` (auto-GUID) and `.set()` (custom key) directly against the active collection.
   - **Getting Data:** Test `.get()`, `.where()`, `.orderBy()`, and `.limit()`.
   - **Updating Data:** Test `.update()` recursive deep merge and `.set()` complete document replacement.
   - **Deleting Data:** Test single document deletion and collection purging.
   - **Custom PowerShell:** An open script editor with full access to `$db` for custom pipelines, filters, and loops.

2. **Database Explorer:**
   - **Collection Switcher:** Instant switching between `users`, `products`, `orders`, or newly created collections.
   - **Live Search Filter:** High-speed filter by document key or any substring inside the document JSON.
   - **Double-Click Inspection:** Double-click any row in the DataGrid to inspect its full JSON payload in the console.
   - **Toolbar Actions:** Seed Demo Data, Flush WAL Checkpoint (`PRAGMA wal_checkpoint(TRUNCATE)`), Refresh, Clear Collection, and Delete Selected Document.

3. **Execution Output & Console:**
   - **Real-Time Logging:** Color-coded execution badges (`Success` in forest green, `Error` in crimson) with execution duration in milliseconds.
   - **Text Wrapping & Formatting:** Clean, multi-line wrapped JSON viewer in Consolas font.
   - **Ad-Hoc REPL Input:** Execute commands directly at the `>` prompt.

4. **Zero Dependencies & Native Integration:**
   - 100% native Windows: Runs directly on Windows `winsqlite3.dll` without any external NuGet packages, binaries, or C++ runtimes.
   - Compatible across both Windows PowerShell 5.1 and PowerShell 7+.

---

## Automated Verification

To run automated headless verification of all UI elements, XAML controls, and database operations:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Playground\verify-playground.ps1
# or
powershell.exe -ExecutionPolicy Bypass -File .\Playground\verify-playground.ps1
```
