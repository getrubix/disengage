# Disengage

Interactive CLI that fully offboards a Windows device from **Intune**, **Windows Autopilot**, **Entra ID** and **on-prem Active Directory**. It confirms the result by checking each system again.

```
./Disengage.ps1                              # wizard
./Disengage.ps1 -SerialNumber 5CG1234XYZ     # skip the lookup prompt
./Disengage.ps1 -DeviceName PC-001 -DryRun   # show the plan, change nothing
```

## What it does

1. **Preflight**: checks PowerShell, modules, folders, the backup certificate, the Graph connection and permissions, and AD reachability.
2. **Discovery**: finds the device by name or serial in every system. Records are tied together by hard IDs. The Intune and Autopilot device IDs map to the Entra `deviceId`. A hybrid device's Entra `deviceId` maps to its AD `objectGUID`. Anything matched **only by display name** (for example a stale registration or a reused name) is flagged, and you decide whether to include it.
3. **Review**: shows device details and a table of every record with its planned action. It warns if the device was active recently or if it's hybrid joined and AD can't be reached.
4. **Optional remote wipe**: a factory reset with enrollment data removed. The tool waits for the device to confirm it. If the device doesn't confirm in time, you choose: keep waiting, continue anyway, or stop.
5. **Typed confirmation**: you type the device name before anything is changed.
6. **Offboarding**, in this order:
   1. Back up BitLocker recovery keys and LAPS passwords from Entra and AD to an encrypted file.
   2. Wipe (if chosen).
   3. Delete the Intune managed device.
   4. Delete the Autopilot identity. This retries while the Intune removal propagates, then waits for the asynchronous delete to finish.
   5. Delete the AD computer object. This uses `-Recursive` so the BitLocker child objects go too, and clears accidental-deletion protection first if it's set.
   6. Optionally trigger an Entra Connect delta sync.
   7. Delete (or disable) the Entra device objects. Objects synced from AD are removed by Entra Connect, and the tool waits for that.
7. **Verification**: re-checks every record by ID, and searches Intune and Autopilot again to catch a device that re-enrolled mid-run. The result is one of:
   - **Fully offboarded**
   - **Pending**: Microsoft is still processing a delete; re-run later to confirm
   - **Not fully offboarded**
8. **Report**: a JSON report and a full transcript go to `Logs/`. The report never contains secrets.

If a step fails, the run stops there. Later steps depend on earlier ones, for example Autopilot rejects the delete while the device is still in Intune. **Re-running is safe:** records that are already gone count as success.

### Why the order matters

- Autopilot won't release a device that's still enrolled in Intune.
- For a **hybrid joined** device, deleting the Entra object while the AD computer is still in sync scope doesn't stick, because Entra Connect recreates it. The AD object has to go first.
- Deleting the Entra device **permanently deletes the BitLocker keys and the Windows LAPS password stored on it**. Deleting the AD computer deletes its BitLocker recovery info and its LAPS password. That's why the backup runs first, and why a partial backup needs you to type `CONTINUE` before the run goes on.

## Requirements

- PowerShell 7.2+
- `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`
- For domain-joined or hybrid devices: RSAT ActiveDirectory module, and rights to delete computer objects in the relevant OUs. Without it the tool still runs, but it warns and skips AD.
- For Entra Connect sync triggering: PowerShell remoting to the Entra Connect server.

## Setup

### 1. App registration / permissions

Microsoft Graph permissions (Application for certificate auth, Delegated for interactive):

| Permission | Used for |
|---|---|
| `DeviceManagementManagedDevices.ReadWrite.All` | Find and delete Intune devices |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | Remote wipe |
| `DeviceManagementServiceConfig.ReadWrite.All` | Find and delete Autopilot identities |
| `Device.ReadWrite.All` | Find, delete and disable Entra devices |
| `BitlockerKey.Read.All` | Back up BitLocker recovery keys |
| `DeviceLocalCredential.Read.All` | Back up Windows LAPS passwords |

With interactive sign-in, the operator also needs roles that allow these actions, such as **Intune Administrator** plus **Cloud Device Administrator**. Reading BitLocker keys and LAPS passwords needs a role that grants it.

### 2. Backup encryption (recommended)

Create or issue a certificate with the **Document Encryption** EKU and import it into `Cert:\CurrentUser\My` on the admin workstation. The public key is enough. Keep the private key in your escrow location and set `Backup.CertificateThumbprint`.

Without a certificate, backups fall back to **DPAPI**, which means only the same Windows account on the same machine can decrypt them. Preflight warns about this.

To read a backup:

```
./Read-DisengageBackup.ps1 -Path ./Backups/PC-001_5CG1234XYZ_20261001-142233.dgbackup
```

### 3. Config

Copy `config.example.json` to `config.json`. `config.json` is git-ignored.

| Setting | Meaning |
|---|---|
| `TenantId` | Tenant ID or primary domain |
| `Auth.Mode` | `Interactive` (delegated sign-in) or `Certificate` (app-only) |
| `Auth.ClientId` / `Auth.CertificateThumbprint` | Required for `Certificate`. `ClientId` is optional for `Interactive` (uses your own app instead of the Graph PowerShell app) |
| `EntraAction` | `Delete` (default) or `Disable` |
| `RecentActivityHours` | Warn if the device was seen within this many hours |
| `ActiveDirectory.Enabled` / `Server` | Turn AD handling on or off; optional DC to target |
| `ActiveDirectory.EntraConnectServer` | If set, a delta sync is triggered after the AD delete |
| `Backup.Path` / `Backup.CertificateThumbprint` | Where encrypted backups go; CMS recipient certificate |
| `Logging.Path` | Transcripts and JSON reports |
| `Timeouts.*` | How long to wait for the wipe, the Autopilot delete and Entra Connect, and the polling interval |

Relative paths are resolved against the config file's folder.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Fully offboarded (or dry run finished) |
| 1 | Not fully offboarded, cancelled, or device not found |
| 2 | Offboarded, but a Microsoft-side delete is still processing |
| 3 | Preflight or config failed |

## Notes and caveats

- **A wipe can lead to re-enrollment.** After a wipe the device restarts into the out-of-box setup screens. If it's online, it can re-register before its Autopilot record is deleted. Verification catches this and reports the new enrollment. To avoid it, keep the device offline after the wipe confirms.
- The Autopilot delete is asynchronous and can take up to an hour in busy tenants. The tool waits `Timeouts.AutopilotMinutes`, then reports **Pending**.
- Entra Connect's default sync cycle is 30 minutes. Set `EntraConnectServer` to speed this up, or re-run later to confirm.
- Only Windows devices are matched in Intune.

## Project layout

```
Disengage.ps1              entry point (wizard)
Read-DisengageBackup.ps1   decrypt a secrets backup
src/
  Ui.ps1         console rendering, prompts, step runner, polling
  Graph.ps1      Graph wrapper (retry/backoff, paging, 404 handling), auth
  Config.ps1     config loading, preflight
  Discovery.ps1  cross-system lookup and record linking
  Backup.ps1     BitLocker/LAPS escrow (CMS or DPAPI)
  Offboard.ps1   the destructive steps
  Verify.ps1     post-run verification
  Report.ps1     transcript and JSON report
  Workflow.ps1   the wizard flow and plan
tests/           Pester tests (Graph and AD are mocked)
```

Run the tests with `Invoke-Pester ./tests`.

## Roadmap

- Microsoft Defender for Endpoint offboarding and tagging
- Configuration Manager (co-managed devices)
- Bulk mode from a CSV file
- CMDB / asset system update (e.g. ServiceNow)
