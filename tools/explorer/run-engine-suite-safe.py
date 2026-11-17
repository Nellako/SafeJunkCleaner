"""Bounded offline, no-model engine suite. Retains fixtures and pre/post lock evidence.
Invoke with Python -I and explicit --repository / --evidence paths. No cleanup.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--repository', required=True)
parser.add_argument('--evidence', required=True)
parser.add_argument('--dotnet', default=os.environ.get('SJC_DOTNET_EXE') or shutil.which('dotnet'))
parser.add_argument('--nuget-config', default=os.environ.get('SJC_NUGET_CONFIG'))
options = parser.parse_args()
repo = Path(options.repository).resolve()
evidence = Path(options.evidence).resolve()
if not repo.is_dir() or not evidence.is_dir() or evidence == evidence.parent:
    raise SystemExit('Explicit existing repository and non-root evidence directory required')
if not options.dotnet:
    raise SystemExit('Provide --dotnet, SJC_DOTNET_EXE, or dotnet on PATH')
sdk = Path(options.dotnet).resolve()
config = Path(options.nuget_config).resolve() if options.nuget_config else None
if not sdk.is_file() or (config is not None and not config.is_file()):
    raise SystemExit('Explicit SDK executable and optional NuGet configuration must exist')
projects = [
    ('SelfTest', 'engine-tests/Explorer.SelfTest.csproj'),
    ('Space', 'engine-tests/Explorer.Space.Tests/Explorer.Space.Tests.csproj'),
    ('Analysis', 'engine-tests/Explorer.Analysis.Tests/Explorer.Analysis.Tests.csproj'),
    ('Analysis.Regression', 'engine-tests/Explorer.Analysis.RegressionTests/Explorer.Analysis.RegressionTests.csproj'),
    ('Application', 'engine-tests/Explorer.Application.Tests/Explorer.Application.Tests.csproj'),
    ('Execution.Tests', 'engine-tests/Explorer.Execution.Tests/Explorer.Execution.Tests.csproj'),
    ('Execution.Verification', 'engine-tests/Explorer.Execution.Verification/Explorer.Execution.Verification.csproj'),
    ('Host.Tests', 'engine-tests/Explorer.Host.Tests/Explorer.Host.Tests.csproj'),
    ('Storage.Tests', 'engine-tests/Explorer.Storage.Tests/Explorer.Storage.Tests.csproj'),
    ('ApprovalMaintenance.Tests', 'engine-tests/Explorer.ApprovalMaintenance.Tests/Explorer.ApprovalMaintenance.Tests.csproj'),
    ('SimpleCache.Tests', 'engine-tests/SimpleCache.Tests/SimpleCache.Tests.csproj'),
    ('ScanQueue.Tests', 'engine-tests/Explorer.ScanQueue.Tests/Explorer.ScanQueue.Tests.csproj'),
    ('Batch.Tests', 'engine-tests/Explorer.Batch.Tests/Explorer.Batch.Tests.csproj'),
    ('Progress.Tests', 'engine-tests/Explorer.Progress.Tests/Explorer.Progress.Tests.csproj'),
]
started = time.monotonic()
records = []
env = os.environ.copy()
for key, folder in [('TEMP', 'temp'), ('TMP', 'temp'), ('TMPDIR', 'temp'), ('NUGET_PACKAGES', 'nuget-packages'), ('NUGET_HTTP_CACHE_PATH', 'nuget-http-cache'), ('NUGET_PLUGINS_CACHE_PATH', 'nuget-plugins-cache'), ('DOTNET_CLI_HOME', 'dotnet-home')]:
    target = evidence / folder
    target.mkdir(exist_ok=True)
    env[key] = str(target)
env.update(DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1', DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true', MSBUILDDISABLENODEREUSE='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false', DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()

def snapshot(label, locks_only=False):
    result = []
    for tree in ['engine', 'engine-tests']:
        for path in sorted((repo / tree).rglob('*')):
            if not path.is_file() or any(part in ('bin', 'obj') for part in path.relative_to(repo).parts):
                continue
            if locks_only and path.name != 'packages.lock.json':
                continue
            if not locks_only and path.suffix not in ('.cs', '.csproj', '.props', '.json'):
                continue
            relative = path.relative_to(repo)
            result.append({'Path': str(path), 'Hash': digest(path)})
            if locks_only:
                target = evidence / label / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(path.read_bytes())
    (evidence / (label + '.json')).write_text(json.dumps(result, indent=2), encoding='utf-8')
    return result

def execute(name, phase, command, limit):
    remaining = 660 - (time.monotonic() - started)
    record = {'Name': name, 'Phase': phase, 'Command': [str(x) for x in command], 'Cwd': str(evidence), 'StartedUtc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    log = evidence / (name + '-' + phase + '.log')
    record['Log'] = str(log)
    if remaining <= 5:
        record.update(ExitCode=None, Status='BlockedBySuiteTimeBound')
    else:
        with log.open('wb') as output:
            try:
                completed = subprocess.run([str(x) for x in command], cwd=evidence, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=min(limit, remaining), check=False)
                record.update(ExitCode=completed.returncode, Status='Passed' if completed.returncode == 0 else 'Failed')
            except subprocess.TimeoutExpired:
                record.update(ExitCode=None, Status='Timeout')
    records.append(record)
    (evidence / 'results.json').write_text(json.dumps(records, indent=2), encoding='utf-8')
    print(name, phase, record['Status'], record['ExitCode'], flush=True)
    return record['Status'] == 'Passed'

locks_before = snapshot('locks-before', True)
source_before = snapshot('source-at-build')
(evidence / 'environment.json').write_text(json.dumps({'Sdk': str(sdk), 'NugetConfig': str(config) if config else None, 'NuGetAudit': False, 'OfflineAuditDisclosure': 'NuGetAudit disabled for this offline run; vulnerability audit NOT performed', 'RealCOMTested': False, 'RealRecycleTested': False, 'Environment': {key: env[key] for key in ('TEMP', 'TMP', 'NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'NUGET_PLUGINS_CACHE_PATH', 'DOTNET_CLI_HOME')}, 'NugetConfigContent': config.read_text(encoding='utf-8-sig') if config else None}, indent=2), encoding='utf-8')
built = []
for name, project in projects:
    command = [sdk, 'build', repo / project, '-c', 'Release', '--disable-build-servers', '-m:1', '-nodeReuse:false', '-p:NuGetAudit=false', '-p:UseSharedCompilation=false']
    if config is not None:
        command += ['--configfile', config]
    if name == 'ScanQueue.Tests':
        command += ['-p:ArtifactsDirectory=' + str(evidence / 'scanqueue-build')]
    if execute(name, 'build', command, 100):
        built.append((name, project))
# This manifest is generated only after all builds and binds actual source and DLL bytes.
frozen_paths = {item['Path'] for item in snapshot('source-after-build')}
for path in (repo / 'artifacts/explorer/bin').rglob('*.dll'):
    frozen_paths.add(str(path))
manifest = evidence / 'caller-build-manifest.json'
manifest.write_text(json.dumps([{'Path': path, 'Hash': digest(Path(path))} for path in sorted(frozen_paths)], indent=2), encoding='utf-8')
for name, project in built:
    assembly_name = Path(project).stem
    dll = repo / 'artifacts/explorer/bin' / assembly_name / 'Release/net10.0-windows' / (assembly_name + '.dll')
    args = [sdk, dll, evidence]
    if name == 'ScanQueue.Tests':
        case_evidence = evidence / 'ScanQueue.Tests'
        case_evidence.mkdir()
        args = [sdk, dll, case_evidence, repo / 'engine/Explorer.Core']
    if name == 'Analysis.Regression':
        args.append(manifest)
    if name in ('Storage.Tests', 'ApprovalMaintenance.Tests', 'SimpleCache.Tests', 'Batch.Tests', 'Progress.Tests'):
        case_evidence = evidence / name
        case_evidence.mkdir()
        args = [sdk, dll, case_evidence]
    execute(name, 'run', args, 120 if name == 'Storage.Tests' else 75)
    if name == 'Host.Tests':
        lifecycle = evidence / 'Lifecycle'
        lifecycle.mkdir()
        execute('Host.Lifecycle', 'run', [sdk, dll, lifecycle, '--lifecycle'], 120)
locks_after = snapshot('locks-after', True)
source_after = snapshot('source-after-run')
before_map = {item['Path']: item['Hash'] for item in locks_before}
after_map = {item['Path']: item['Hash'] for item in locks_after}
changes = [{'Path': path, 'Before': before_map.get(path), 'After': after_map.get(path)} for path in sorted(before_map.keys() | after_map.keys()) if before_map.get(path) != after_map.get(path)]
(evidence / 'lock-changes.json').write_text(json.dumps(changes, indent=2), encoding='utf-8')
source_changes = [item['Path'] for item in source_before if Path(item['Path']).suffix in ('.cs', '.csproj', '.props') and digest(Path(item['Path'])) != item['Hash']]
(evidence / 'completion.json').write_text(json.dumps({'ElapsedSeconds': time.monotonic() - started, 'LockChanges': len(changes), 'SourceChangesDuringBuildAndRun': source_changes, 'BuildCount': sum(r['Phase'] == 'build' for r in records), 'RunCount': sum(r['Phase'] == 'run' for r in records), 'NoCleanupPerformed': True}, indent=2), encoding='utf-8')
print('Evidence:', evidence, 'lock changes:', len(changes), 'source changes:', len(source_changes), flush=True)
raise SystemExit(0 if len(records) == len(projects) * 2 + 1 and all(r['Status'] == 'Passed' for r in records) and not source_changes else 1)
