# Intune Backup & Restore Tool

A PowerShell 7 WinForms GUI for backing up and restoring Microsoft Intune
configurations via the Microsoft Graph API. Tested against the Microsoft.Graph
PowerShell SDK 2.x and Graph endpoints `v1.0` and `beta`.

Version: **1.1.0** &middot; manifest schema: **2.0**

## Quick start

```powershell
# From the IntuneBackupRestore folder, on Windows
pwsh -File Main.ps1

# Optional custom config
pwsh -File Main.ps1 -ConfigFile 'D:\MyConfig\AppConfig.json'
```

The first run uses the **Prerequisites** tab to detect missing modules. Click
**Connect** on the Connection tab to authenticate (browser window opens). The
**Permissions** grid shows which Graph scopes were granted vs required; use
**Request missing scopes** for step-up consent without restarting the app.

## Architecture overview

```
IntuneBackupRestore/
├── Main.ps1                          # Entry point: load config, modules, GUI
├── Config/
│   └── AppConfig.json                # Defaults (overrideable per user)
├── Modules/
│   ├── Logging.psm1                  # Thread-safe log + ConcurrentQueue UI bridge
│   ├── Helpers.psm1                  # Graph wrapper, paging, JSON utils,
│   │                                 # Get-GraphRoot (v1.0/beta resolver)
│   ├── Prerequisites.psm1            # Module detection / install
│   ├── GraphConnection.psm1          # Auth, scopes, tenant info, switch
│   ├── AssignmentEngine.psm1         # Per-workload /assign endpoints,
│   │                                 # group-by-name resolution for restore
│   ├── BackupEngine.psm1             # Backup orchestrator, manifest v2
│   ├── RestoreEngine.psm1            # Restore orchestrator, ConflictMode,
│   │                                 # DryRun, assignments hook
│   └── Workloads/
│       ├── CompliancePolicies.psm1
│       ├── ConfigProfiles.psm1
│       ├── SettingsCatalog.psm1
│       ├── EndpointSecurity.psm1
│       ├── DeviceScripts.psm1
│       ├── Autopilot.psm1
│       ├── EnrollmentConfigurations.psm1
│       ├── AppProtection.psm1
│       ├── AppConfiguration.psm1
│       ├── ProactiveRemediations.psm1     # beta endpoint
│       └── AdministrativeTemplates.psm1   # beta endpoint
└── GUI/
    ├── MainForm.ps1                  # Window, timer, runspace manager
    ├── Tab_Connection.ps1            # Connect, scope status, tenant switch
    ├── Tab_Prerequisites.ps1
    ├── Tab_Backup.ps1                # 11-category checkbox grid
    ├── Tab_Restore.ps1               # Conflict mode, dry-run, JSON preview
    ├── Tab_Log.ps1                   # Live log + filter / export
    └── Tab_Settings.ps1              # Endpoint toggle, conflict default,
                                      # naming pattern, retry tuning
```

Background runspaces are used for Connect / Backup / Restore so the UI stays
responsive. The `Microsoft.Graph.Authentication` token context is a process-wide
.NET singleton, so the runspace inherits the auth context made on the UI thread
without re-authentication.

## Supported categories

The tool ships with eleven workload modules. Each exports `Export-<Workload>`
and `Import-<Workload>` plus a `Get-Existing<Workload>` for conflict checks.

| Category | Endpoint family | Restorable | Notes |
|---|---|---|---|
| Compliance Policies | v1.0 | yes | Notification template IDs blanked on restore |
| Device Config Profiles | v1.0 | yes (with caveats) | `@odata.type` preserved; non-portable types flagged |
| Settings Catalog | v1.0 | yes | Settings embedded in POST body |
| Endpoint Security | v1.0 | yes | `templateReference` preserved |
| Device Management Scripts | v1.0 | yes | `scriptContent` decoded to `.ps1` for diff/review |
| Autopilot Deployment Profiles | v1.0 | partial | Hardware identifier uploads not transferred |
| Enrollment Configurations | v1.0 | yes | Default tenant configs are backup-only |
| App Protection (MAM) | v1.0 + beta | partial | Restore branches by derived `@odata.type` |
| App Configuration | v1.0 | yes | Two collections merged: MDM + MAM targeted |
| Proactive Remediations | **beta** | yes | Requires Endpoint Analytics license in target |
| Administrative Templates (ADMX) | **beta** | partial | Definition values restored individually; custom ADMX must exist in target |

### Categories that require beta endpoints

- `ProactiveRemediations` — `/beta/deviceManagement/deviceHealthScripts`
- `AdministrativeTemplates` — `/beta/deviceManagement/groupPolicyConfigurations`

These two are pinned to `beta` regardless of `UseBetaWherePossible`. Other
categories default to `v1.0` and can be promoted via the per-category
`EndpointVersions` map in `AppConfig.json` or the global `UseBetaWherePossible`
toggle on the Settings tab.

## Graph API scopes

Requested at sign-in (delegated). The Connection tab shows the live
**Granted vs Missing** status per scope and offers a **Request missing scopes**
button that triggers step-up consent.

| Scope | Used for |
|---|---|
| `Organization.Read.All` | Read tenant display name |
| `DeviceManagementConfiguration.Read.All` / `ReadWrite.All` | Most policy workloads |
| `DeviceManagementApps.Read.All` / `ReadWrite.All` | App Protection / App Configuration |
| `DeviceManagementServiceConfig.Read.All` / `ReadWrite.All` | Autopilot, Enrollment Configurations |
| `DeviceManagementManagedDevices.Read.All` | Backup context |
| `DeviceManagementScripts.ReadWrite.All` | Device scripts, Proactive Remediations |
| `DeviceManagementRBAC.Read.All` | Scope tag references |
| `Group.Read.All` | Resolve group displayNames for assignment export and restore |

Read-only scopes (`*.Read.All`) are sufficient for backup. The matching
`*.ReadWrite.All` scopes are required for restore.

## Backup folder layout

The folder pattern is configurable (`BackupFolderNamingPattern`, tokens
`{tenant}`, `{tenantId}`, `{timestamp}`). Default:

```
<BackupRoot>/
└── <TenantName>_<TenantId>/
    └── 2026-05-04_14-30-00/
        ├── Manifest/
        │   ├── manifest.json                # v2 schema, see below
        │   └── index.json                   # Flat list of every exported object
        ├── CompliancePolicies/
        │   ├── PolicyName_<id>.json             # Raw export package
        │   ├── PolicyName_<id>.import.json      # Normalized payload for restore
        │   └── PolicyName_<id>.assignments.json # Assignments sidecar (when present)
        ├── ConfigProfiles/
        ├── SettingsCatalog/
        ├── EndpointSecurity/
        ├── DeviceScripts/
        │   ├── ScriptName_<id>.json
        │   ├── ScriptName_<id>.import.json
        │   └── ScriptName_<id>.ps1              # Decoded script content
        ├── Autopilot/
        ├── EnrollmentConfigurations/
        ├── AppProtection/
        ├── AppConfiguration/
        ├── ProactiveRemediations/
        │   ├── ScriptName_<id>.json
        │   ├── ScriptName_<id>.import.json
        │   ├── ScriptName_<id>.detection.ps1
        │   └── ScriptName_<id>.remediation.ps1
        ├── AdministrativeTemplates/
        └── Logs/
            └── session.log
```

### `manifest.json` (schema 2.0)

```json
{
  "SchemaVersion": "2.0",
  "ToolVersion":   "1.1.0",
  "Status":        "Completed",
  "StartedAt":     "2026-05-04 14:30:00",
  "CompletedAt":   "2026-05-04 14:31:42",
  "Tenant":        { "DisplayName": "Contoso", "Id": "00000000-..." },
  "BackedUpBy":    "admin@contoso.onmicrosoft.com",
  "SelectedWorkloads":   [ "CompliancePolicies", "SettingsCatalog", "..." ],
  "TotalObjectCount":    47,
  "WorkloadSummary":     { "CompliancePolicies": { "ExportedCount": 8, "Warnings": [] }, "..." },
  "EndpointVersionsUsed":{ "CompliancePolicies": "v1.0", "ProactiveRemediations": "beta", "..." },
  "CategoriesBackupOnly":[ ],
  "ExportedAssignments": true,
  "SessionWarnings":     [ ]
}
```

### Normalization (raw vs `.import.json`)

For each object, two JSON files are written:
1. **Raw** — full Graph response, useful for diff and audit. Includes `id`,
   `createdDateTime`, `lastModifiedDateTime`, computed/status fields, and the
   embedded assignments array.
2. **Normalized** (`.import.json`) — the body that POST will accept. Stripped
   fields:
   - `id`, `createdDateTime`, `lastModifiedDateTime`, `version`
   - `@odata.context`, `@odata.etag`
   - tenant-specific `roleScopeTagIds`, computed counters (`isAssigned`,
     `deployedAppCount`, `enrolledDeviceCount`)
   - workload-specific status / summary fields
   - **kept**: `@odata.type` (required for polymorphic POSTs)

Assignments are written to a third file `<base>.assignments.json` with both
the raw response and a denormalized form that includes the resolved group
displayName. This sidecar is consumed by the AssignmentEngine during restore.

## Restore behaviour

The Restore tab loads a backup folder, lists every object in a grid, and
optionally restores a multi-select subset. The right-hand pane previews the
selected object's `.import.json` so you can audit the payload before sending it.

| Option | Default | Effect |
|---|---|---|
| **Conflict mode** | `Skip` | `Skip` leaves existing objects untouched. `CreateDuplicate` appends `" (restored YYYY-MM-DD HH:mm)"` to the displayName and POSTs as new. `UpdateExisting` PATCHes the existing object (only for workloads with `SupportsUpdate=$true`; others degrade to Skip with a warning). |
| **Restore assignments** | off | When on, the AssignmentEngine builds a group-by-name lookup of the target tenant and POSTs `/<workload>/{newId}/assign` after object creation. Assignments referencing groups that cannot be resolved are skipped per-assignment with a clear warning, not a hard fail. |
| **Dry run** | off | No Graph writes. Each item is validated (required fields present, conflict prediction, payload size, endpoint version) and a per-item report is written to `<backup>/Logs/restore-dryrun-<ts>.json`. |

`Test-RestoreConflicts` is called once before restore — one Graph list call per
distinct workload — to populate the **Conflict** column. Selecting a row loads
its `.import.json` into the preview pane (capped at 64 KB; larger files show a
hint to open in an editor).

## Configuration keys (`AppConfig.json`)

| Key | Type | Default | Description |
|---|---|---|---|
| `BackupRootPath` | string | `%USERPROFILE%\IntuneBackups` | Root folder for all backup snapshots |
| `BackupFolderNamingPattern` | string | `{tenant}_{tenantId}/{timestamp}` | Folder name template |
| `WriteChecksums` | bool | `false` | Write SHA-256 alongside backup files |
| `ConfirmRestore` | bool | `true` | Show confirmation dialog before restore |
| `ExportAssignments` | bool | `true` | Include assignment data + sidecar files |
| `RestoreAssignmentsByDefault` | bool | `false` | Pre-tick the Restore tab assignments checkbox |
| `DryRunByDefault` | bool | `false` | Pre-tick the Restore tab dry-run checkbox |
| `ConflictMode` | enum | `Skip` | One of `Skip`, `CreateDuplicate`, `UpdateExisting` |
| `UseBetaWherePossible` | bool | `false` | Promote all non-locked workloads to `/beta` |
| `EndpointVersions` | map | per-category | Per-workload override `v1.0` / `beta` |
| `LogLevel` | string | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `LogToFile` | bool | `true` | Persist session log to file |
| `MaxRetries` | int | `3` | Retry count on 429 / 5xx |
| `BaseDelaySeconds` | int | `2` | Initial backoff; doubles each retry |
| `PageSize` | int | `100` | `$top` value for Graph list requests |
| `ConfirmDisconnect` | bool | `true` | Prompt before disconnecting |
| `ShowDebugInUI` | bool | `false` | Show `DEBUG` entries in the Log tab |

## Known limitations

- **Tenant picker is best-effort.** Microsoft Graph does not expose every
  tenant a delegated admin can access from a single endpoint. The picker
  lists the current tenant; for cross-tenant work use **Switch Tenant** and
  enter the GUID or verified domain manually.
- **Assignments resolve groups by displayName.** Renamed groups in the source
  tenant cannot be matched. Ambiguous names (multiple groups sharing a
  displayName) are skipped per-assignment with a warning.
- **Autopilot profile restore is partial.** Profiles are recreated, but the
  hardware-hash uploads (`importedWindowsAutopilotDeviceIdentities`) attached
  in the source tenant are NOT carried over. Re-import device identifiers in
  the target tenant after restore.
- **Administrative Templates** require beta endpoints and have polymorphic
  settings. Restore is verified for Microsoft-published ADMX templates;
  custom ingested ADMX must already be uploaded in the target tenant before
  restore, otherwise individual `definitionValues` POSTs fail and are logged
  per-setting.
- **Proactive Remediations** require an Endpoint Analytics license in the
  target tenant; restore POST returns 403 with a clear license error if the
  license is missing.
- **App Protection polymorphism.** Derived types beyond the well-known iOS,
  Android, Windows MAM, and Targeted Managed App Configuration shapes are
  exported but flagged as not restorable; the corresponding rows are
  highlighted in the Restore grid.
- **Notification message templates** for compliance policies are blanked on
  restore because the template IDs are tenant-specific. Recreate the
  templates manually in the target tenant if you need the exact wording.
- **Windows domain join profiles** and other hardware/infrastructure-bound
  Device Configuration Profile types are flagged with a warning and may fail
  to restore depending on the target tenant's connectors and OUs.
- **`UpdateExisting` conflict mode** is implemented for the workloads that
  expose stable PATCH semantics (currently Autopilot Deployment Profiles).
  For all other workloads the operator's choice degrades to `Skip` with a
  log warning rather than risking a destructive in-place change.
- **PowerShell 5.1 is not supported.** Use `pwsh` (PowerShell 7+) — several
  modules use ternary operators and other 7+ syntax.

## Customization notes

- **Adding a new workload.** Create a new file under
  `Modules/Workloads/<Name>.psm1` following the
  `SettingsCatalog.psm1` template (set `$script:WorkloadKey`, expose
  `Export-<Name>` returning `@{ ExportedCount; Warnings; IndexEntries }`,
  expose `Import-<Name>` and `Get-Existing<Name>`). Register the workload
  in `BackupEngine.psm1::$WorkloadRegistry`, `RestoreEngine.psm1::$WorkloadMap`,
  `AssignmentEngine.psm1::$AssignmentMap`, and add it to `Main.ps1`'s
  `$moduleOrder` and `MainForm.ps1`'s runspace bootstrap.
- **Per-tenant scope tags** are stripped from import payloads
  (`roleScopeTagIds`). If you need to preserve them, remove the field from
  the workload's `_extra` array in `Get-*ImportData`.
- **Custom retry policy.** `Invoke-GraphRequestRetry` honours `Retry-After`
  on 429 responses and uses exponential backoff (`BaseDelaySeconds * 2^N`)
  on 5xx. Tune `MaxRetries` and `BaseDelaySeconds` in `AppConfig.json`.
- **Backup folder naming.** Use `BackupFolderNamingPattern` to keep
  per-environment trees, e.g. `Prod/{tenant}/{timestamp}` or
  `{timestamp}_{tenant}` for chronological sorting.

## License

MIT.
