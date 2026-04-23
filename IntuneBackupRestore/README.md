# Intune Backup & Restore Tool

A PowerShell 7 WinForms GUI for backing up and restoring Microsoft Intune configurations via the Microsoft Graph API.

## Requirements

| Requirement | Minimum |
|---|---|
| PowerShell | 7.0 (pwsh) |
| OS | Windows 10 / Windows Server 2019 or newer |
| PowerShell module | `Microsoft.Graph.Authentication` ≥ 2.0.0 |
| Permissions | See Graph Scopes below |

The **Prerequisites** tab inside the tool checks and installs the required module automatically (with your explicit consent).

## Quick Start

```powershell
# From the IntuneBackupRestore folder
pwsh -File Main.ps1

# Custom config file
pwsh -File Main.ps1 -ConfigFile 'D:\MyConfig\AppConfig.json'
```

## Folder Structure

```
IntuneBackupRestore/
├── Main.ps1                          # Entry point
├── Config/
│   └── AppConfig.json                # Default settings
├── Modules/
│   ├── Logging.psm1                  # Thread-safe logging
│   ├── Helpers.psm1                  # Graph wrapper, paging, JSON utils
│   ├── Prerequisites.psm1            # Module detection and install
│   ├── GraphConnection.psm1          # Auth, tenant info, live check
│   ├── BackupEngine.psm1             # Backup orchestrator
│   ├── RestoreEngine.psm1            # Restore orchestrator
│   └── Workloads/
│       ├── CompliancePolicies.psm1
│       ├── ConfigProfiles.psm1
│       ├── SettingsCatalog.psm1
│       ├── EndpointSecurity.psm1
│       └── DeviceScripts.psm1
└── GUI/
    ├── MainForm.ps1                  # Main window, timer, runspace manager
    ├── Tab_Connection.ps1
    ├── Tab_Prerequisites.ps1
    ├── Tab_Backup.ps1
    ├── Tab_Restore.ps1
    ├── Tab_Log.ps1
    └── Tab_Settings.ps1
```

## Graph API Scopes

The tool requests the following delegated permissions at sign-in:

| Scope | Used for |
|---|---|
| `DeviceManagementConfiguration.ReadWrite.All` | Config profiles, Settings Catalog, Endpoint Security |
| `DeviceManagementManagedDevices.ReadWrite.All` | Device Management Scripts |
| `DeviceManagementApps.ReadWrite.All` | App-related policies |
| `DeviceManagementServiceConfig.ReadWrite.All` | Compliance policies |
| `Directory.Read.All` | Tenant display name lookup |
| `User.Read` | Signed-in user info |

Read-only scopes (`*.Read.All`) are sufficient if you only need backup, not restore.

## Supported Workloads

| Workload | Graph Endpoint | Notes |
|---|---|---|
| Compliance Policies | `/v1.0/deviceManagement/deviceCompliancePolicies` | `scheduledActionsForRule` expanded; notification template IDs cleared on import |
| Device Config Profiles | `/v1.0/deviceManagement/deviceConfigurations` | `@odata.type` preserved; non-portable types flagged with a warning |
| Settings Catalog | `/v1.0/deviceManagement/configurationPolicies` | Filter: `templateFamily eq 'none'`; settings fetched via separate `/settings` endpoint |
| Endpoint Security | `/v1.0/deviceManagement/configurationPolicies` | Filter: `templateFamily ne 'none'`; `templateReference` preserved in POST body |
| Device Management Scripts | `/v1.0/deviceManagement/deviceManagementScripts` | `scriptContent` decoded to `.ps1` for readability; re-encoded on restore |

## Backup Structure

Each backup run creates a timestamped folder:

```
<BackupRootPath>/
└── <TenantName>_<TenantId>/
    └── 2025-06-01_14-30-00/
        ├── manifest.json              # Run metadata (status, counts, tenant)
        ├── index.json                 # Flat list of all exported objects
        ├── CompliancePolicies/
        │   ├── PolicyName.json          # Full policy JSON (assignments included)
        │   └── PolicyName.import.json   # Stripped version used for restore POST
        ├── ConfigProfiles/
        ├── SettingsCatalog/
        ├── EndpointSecurity/
        ├── DeviceScripts/
        │   ├── ScriptName.json
        │   ├── ScriptName.import.json
        │   └── ScriptName.ps1           # Decoded script content
        └── Logs/
            └── backup.log
```

`manifest.json` is written as `InProgress` at the start and updated to `Completed` or `Failed` when the run finishes.

## Restore Behaviour

- **Conflict detection** — one Graph call per workload (not per object) to fetch existing names
- **Conflicts skipped by default** — objects whose display name already exists are skipped; the checkbox can be unchecked to attempt import anyway
- **Dry run** — logs what would happen without creating anything in the tenant
- **Assignments are never restored** — group IDs are tenant-specific; assignments are exported for documentation only
- **Non-portable profile types** — certain Device Config Profile types (e.g. `windowsDomainJoinConfiguration`) are flagged with a warning icon in the Restore tab

## Configuration Keys (`AppConfig.json`)

| Key | Type | Default | Description |
|---|---|---|---|
| `BackupRootPath` | string | `%USERPROFILE%\IntuneBackups` | Root folder for all backup snapshots |
| `WriteChecksums` | bool | `false` | Write `.sha256` file next to each backup JSON |
| `ConfirmRestore` | bool | `true` | Show confirmation dialog before restore |
| `ExportAssignments` | bool | `true` | Include assignment data in backup (docs only) |
| `LogLevel` | string | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `LogToFile` | bool | `true` | Write log to `Logs\backup.log` inside the snapshot |
| `MaxRetries` | int | `3` | Retry attempts on HTTP 429 / 5xx |
| `BaseDelaySeconds` | int | `2` | Initial backoff delay; doubles each attempt |
| `PageSize` | int | `100` | `$top` value for Graph list requests |
| `ConfirmDisconnect` | bool | `true` | Prompt before disconnecting |
| `ShowDebugInUI` | bool | `false` | Show DEBUG entries in the Log tab |

## Architecture Notes

### Why WinForms (not WPF)?
WPF requires the PowerShell process to run in STA apartment mode. While this works in Windows PowerShell 5.1, PowerShell 7 defaults to MTA and restarting the process in STA from within a script is fragile. WinForms has no apartment-mode requirement.

### Background runspaces
Backup and restore operations run in a separate `[PowerShell]` runspace so the UI stays responsive. The Graph auth context (`Microsoft.Graph.Authentication`) is a static .NET singleton shared across all runspaces in the same process, so the connection made on the UI thread is immediately visible in the background runspace.

### Log queue
Background runspaces write `@{ Level; Timestamp; Message }` entries into a `[System.Collections.Concurrent.ConcurrentQueue[hashtable]]`. A 250 ms WinForms timer on the UI thread drains the queue and appends entries to the Log tab's RichTextBox.

### Settings Catalog vs Endpoint Security
Both workloads use the same Graph endpoint (`/deviceManagement/configurationPolicies`). They are differentiated by the `templateFamily` OData filter:
- Settings Catalog: `templateFamily eq 'none'`
- Endpoint Security: `templateFamily ne 'none'`

## Known Limitations

- **Assignments not restored** — group object IDs differ between tenants
- **Notification templates** — compliance policy notification template IDs are blanked on restore because they are tenant-specific
- **Windows domain join profiles** — require tenant-specific network/OU information and cannot be restored automatically
- **App-based conditional access policies** — not in scope for this tool
- **Intune Role assignments** — not exported

## License

MIT
