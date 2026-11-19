# Independent QuickClean host checks

Build `QuickClean.Verification.csproj` with a .NET 10 SDK against the frozen host source. Put outputs and temporary files under the authorized work directory. The project reference checks the friend-assembly API; for release verification, stage **only** `QuickClean.Verification.dll`, its `.deps.json` and its `.runtimeconfig.json` into a fresh directory, together with `sjc-quickclean.dll` copied from the candidate being tested. Do not replace files in the candidate or in the original build output. The suite checks that the fixture subprocesses and published apphost use matching host assembly bytes.

```text
dotnet <staging>/QuickClean.Verification.dll suite <authorized GUID parent> <candidate>/sjc-quickclean.exe <expected EXE SHA256> --recycle-one
```

`--recycle-one` explicitly permits moving one new GUID-named fixture into the Windows Recycle Bin. The suite checks that Windows Shell lists the original name and directory; it leaves the item there and never empties the bin. Without the flag this check is skipped, and an otherwise passing suite exits `3` instead of `0`. Failures exit nonzero. No suite launches real UAC or DISM; it calls only `maintenance-check`. Production `query History` is read-only, and its rows are not persisted in test evidence. Fixture jobs exercise the real packaged assembly via its internal test constructor in fresh processes, not production caches or a production fixture CLI. `fixture <parent> <case>` runs a single fixture against the assembly beside the driver; the `Recycled` case also requires `--recycle-one`.

Read `summary.json` under the reported evidence directory for outcomes, and `inputs.json` for the hashes. `Test-QuickCleanCore.ps1` is the earlier PowerShell-path comparison; its results are not independent .NET Host evidence.
