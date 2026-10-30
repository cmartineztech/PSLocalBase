@{
    # Script module or binary module file associated with this manifest.
    RootModule           = 'PSLocalBase.psm1'

    # Version number of this module.
    ModuleVersion        = '2.0.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID                 = 'a4d52bc0-6e3e-4b71-9f9b-6435c24e819b'

    # Author of this module
    Author               = 'Carlos Martinez (@cmartineztech)'

    # Company or vendor of this module
    CompanyName          = 'cmartineztech'

    # Copyright statement for this module
    Copyright            = '(c) 2026 Carlos Martinez (@cmartineztech). All rights reserved.'

    # Description of the functionality provided by this module
    Description          = 'Lightweight, zero-dependency embedded document database for PowerShell powered by native Windows winsqlite3.dll.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion    = '5.1'

    # Script files (.ps1) that are run in the caller's environment prior to importing this module.
    ScriptsToProcess     = @('InitWinSqlite3Native.ps1')

    # Functions to export from this module
    FunctionsToExport    = @('New-LocalBase')

    # Cmdlets to export from this module
    CmdletsToExport      = @()

    # Variables to export from this module
    VariablesToExport    = @()

    # Aliases to export from this module
    AliasesToExport      = @()

    # Private data to pass to the module specified in RootModule
    PrivateData          = @{
        PSData = @{
            Tags         = @('Database', 'NoSQL', 'LocalDB', 'DocumentDB', 'SQLite', 'EmbeddedDB', 'Windows', 'JSON', 'DocumentStore', 'WinSqlite3')
            ProjectUri   = 'https://github.com/cmartineztech/PSLocalBase'
            LicenseUri   = 'https://github.com/cmartineztech/PSLocalBase/blob/main/LICENSE'
            ReleaseNotes = '2.0.0: data-safety, query-semantics and connection-lifecycle hardening with breaking changes. See CHANGELOG.md.'
        }
    }
}
