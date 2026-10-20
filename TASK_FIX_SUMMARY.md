# Task.json Serialization Bug Fix Summary

## Root Cause
The bug was in the PowerShell implementation (`ralph-loop-runner.ps1`) where hashtables (`@{ ... }`) were being piped to `ConvertTo-Json` for serialization. When a hashtable is passed to a `[string]` parameter in PowerShell, it gets converted to its type name `"System.Collections.Hashtable"`. Additionally, `ConvertTo-Json` with piped hashtables can have inconsistent behavior in PowerShell 5.1.

The specific issue occurred when:
1. The MCP client sent a task parameter that was parsed as a hashtable/PSObject instead of a string
2. The `Set-Task` function received this as the `$Task` parameter (declared as `[string]`)
3. PowerShell converted the hashtable to its type name string `"System.Collections.Hashtable"`
4. The resulting JSON contained `"task": "System.Collections.Hashtable"` instead of the actual task

## Fix Applied (PowerShell)
Changed all state-writing functions to use `[PSCustomObject]` with explicit string casting and `ConvertTo-Json -InputObject` instead of piping hashtables:

### Functions Fixed:
1. **Set-Task** (line 250) - Primary fix for task.json
2. **Set-Config** (line 189) - Config serialization
3. **Set-Work** (line 269) - Work submission serialization
4. **Set-Review** (line 297) - Review serialization (3 places)
5. **Apply-Profile** (line 696) - Profile application serialization

### Pattern Used:
```powershell
# Before (buggy):
$hash = @{ key = $Value; ... }
$json = $hash | ConvertTo-Json -Depth 10

# After (fixed):
$obj = [PSCustomObject]@{
    key = [string]$Value
    ...
}
$json = ConvertTo-Json -InputObject $obj -Depth 10
```

## Bash Implementation
The bash implementation (`ralph-loop-runner.sh`) uses `jq` for all JSON serialization, which properly handles string escaping and JSON object creation. No changes were needed.

## Verification
Tested the fix by:
1. Calling `Set-Task` with a test task
2. Verifying `task.json` contains proper JSON: `{"task": "Test task description", "createdAt": "2026-09-12T23:03:06.3802116-04:00"}`
3. Calling `Handle-GetTask` MCP handler and verifying it returns correct task data
4. Calling `Handle-Initialize` and verifying task.json is created correctly

## Expected Behavior After Fix
- `task.json` contains: `{"task": "actual task description", "createdAt": "2026-09-12T19:57:40.6109988-04:00"}`
- `Get-Task` / `Handle-GetTask` returns the task string for the worker
- All state files (config.json, work.json, review.json, etc.) serialize correctly