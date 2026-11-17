"""One explicit local validation entry; synthetic fixtures retained, no downloads or publication.
Run with python -I and explicit --repository --host-exe --exe --runtime-cache --evidence.
Runs every declared Release case, including isolated N06 promotion fixtures.
"""
import argparse,hashlib,json,os,re,subprocess,sys,time
from pathlib import Path
p=argparse.ArgumentParser()
for name in ['repository','host-exe','exe','runtime-cache','evidence']:p.add_argument('--'+name,required=True)
a=p.parse_args();repo=Path(a.repository).resolve();out=Path(a.evidence).resolve()
if not repo.is_dir() or out.exists() or out==out.parent or repo==out or repo in out.parents:raise SystemExit('New independent evidence directory required')
runtime_cache=Path(a.runtime_cache).resolve()
pointer=json.loads((runtime_cache/'current.json').read_text(encoding='utf-8-sig'))
build_id=pointer.get('BuildId','')
if not re.fullmatch(r'[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}',build_id):raise SystemExit('Invalid runtime BuildId')
manifest_path=runtime_cache/build_id/'host-component-manifest.json'
if hashlib.sha256(manifest_path.read_bytes()).hexdigest().upper()!=str(pointer.get('ManifestSha256','')).upper():raise SystemExit('Runtime manifest differs from pointer')
host=Path(a.host_exe).resolve();expected_host=manifest_path.parent/'sjc-explorer.exe'
if not host.is_file() or not expected_host.is_file() or hashlib.sha256(host.read_bytes()).digest()!=hashlib.sha256(expected_host.read_bytes()).digest():raise SystemExit('Requested Host differs from the runtime cache actually used by tests')
manifest=json.loads(manifest_path.read_text(encoding='utf-8-sig'))
host_records=[x for x in manifest.get('Components',[]) if x.get('Path')=='sjc-explorer.exe']
if len(host_records)!=1 or hashlib.sha256(host.read_bytes()).hexdigest().upper()!=str(host_records[0].get('SHA256',host_records[0].get('Sha256',''))).upper():raise SystemExit('Host binary is not bound to its manifest')
if not Path(a.exe).is_file():raise SystemExit('Product EXE missing')
runner=(repo/'tests/run_all.ps1').read_text(encoding='utf-8-sig')
declaration=runner.split('$script:AllCases = @(',1)
if len(declaration)!=2:raise SystemExit('Unsupported case declaration')
expected_ids=re.findall(r"Id\s*=\s*'([^']+)'",declaration[1].split('\n)',1)[0])
if len(expected_ids)!=len(set(expected_ids)) or 'N06-local-promotion' not in expected_ids:raise SystemExit('Missing or duplicate full Release declarations')
out.mkdir();env=os.environ.copy();env['SJC_TEST_RUNTIME_CACHE']=str(runtime_cache)
env['DOTNET_GENERATE_ASPNET_CERTIFICATE']='false';env['DOTNET_ADD_GLOBAL_TOOLS_TO_PATH']='false'
temp=out/'temp';temp.mkdir();env['TEMP']=str(temp);env['TMP']=str(temp)
ps='C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';records=[]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest().upper()
files=[q for tree in ['engine','src','tests','tools','scripts'] for q in (repo/tree).rglob('*') if q.is_file() and not any(x in ['bin','obj','__pycache__'] for x in q.relative_to(repo).parts) and q.suffix in ['.cs','.csproj','.props','.ps1','.py','.json']]
before={str(q.relative_to(repo)):digest(q) for q in files}
(out/'source-before.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
def run(name,cmd,timeout):
 started=time.monotonic();log=out/(name+'.log')
 with log.open('wb') as stream:
  try:r=subprocess.run([str(x) for x in cmd],cwd=out,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout);code=r.returncode
  except subprocess.TimeoutExpired:code=None
 record={'Name':name,'Command':[str(x) for x in cmd],'ExitCode':code,'Passed':code==0,'Seconds':time.monotonic()-started,'Log':str(log)};records.append(record);(out/'steps.json').write_text(json.dumps(records,indent=2),encoding='utf-8');print(name,code,flush=True)
engine=out/'engine';engine.mkdir();run('Engine',[sys.executable,'-I',repo/'tools/explorer/run-engine-suite-safe.py','--repository',repo,'--evidence',engine],700)
run('Product',[ps,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',repo/'tests/run_all.ps1','-Scope','Release','-ExePath',a.exe,'-OutputDirectory',out/'product','-KeepSandbox'],3600)
run('Packaging',[ps,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',repo/'tests/release/Test-CandidatePackaging.ps1','-Repository',repo],900)
run('NativePublishInvocation',[ps,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',repo/'tests/release/Test-ExplorerNativeInvocation.ps1','-Repository',repo,'-FixtureParent',out],120)
changed=[rel for rel,h in before.items() if not (repo/rel).is_file() or digest(repo/rel)!=h]
# Dependency restore may rewrite RID lock grouping; record rather than silently approve a moving source set.
summary_path=out/'product/summary.json';covered=False;product=None
if summary_path.is_file():
 product=json.loads(summary_path.read_text(encoding='utf-8-sig'));actual=product.get('Results',[]);covered=product.get('Status')=='Passed' and product.get('Cases')==len(expected_ids) and sorted(x.get('Id','') for x in actual)==sorted(expected_ids) and all(x.get('Status')=='Passed' and x.get('Assertions',0)>0 and x.get('ExitCode')==0 and not x.get('CoverageGaps') for x in actual)
batch_path=out/'product/evidence/F01-explorer-completion/Test-ExplorerBatchPersistence-evidence/result.json'
batch_covered=False
if batch_path.is_file():
 batch=json.loads(batch_path.read_text(encoding='utf-8-sig'));batch_covered=batch.get('Passed') is True and batch.get('Assertions',0)>=17 and bool(batch.get('Checks')) and all(x.get('Passed') is True for x in batch['Checks'])
engine_path=out/'engine/results.json';engine_covered=False
if engine_path.is_file():
 engine_results=json.loads(engine_path.read_text(encoding='utf-8-sig'));engine_covered=any(x.get('Name')=='Batch.Tests' and x.get('Phase')=='build' and x.get('Status')=='Passed' for x in engine_results) and any(x.get('Name')=='Batch.Tests' and x.get('Phase')=='run' and x.get('Status')=='Passed' for x in engine_results)
progress_covered=False
if engine_path.is_file():
 progress_covered=all(any(x.get('Name')=='Progress.Tests' and x.get('Phase')==phase and x.get('Status')=='Passed' for x in engine_results) for phase in ('build','run'))
result={'Passed':all(r['Passed'] for r in records) and covered and batch_covered and engine_covered and progress_covered and not changed,'Steps':records,'ProductCoverageVerified':covered,'BatchPersistenceCovered':batch_covered,'BatchEngineCovered':engine_covered,'ProgressEngineCovered':progress_covered,'SourceChanges':changed,'ProductCases':product.get('Cases') if product else None,'N06FullPromotion':next((x.get('Status') for x in product.get('Results',[]) if x.get('Id')=='N06-local-promotion'),'NotRun') if product else 'NotRun','RequestedHost':str(host),'HostSHA256':digest(host),'RuntimeManifestSHA256':digest(manifest_path),'RealRecycleTested':False,'FixturesRetained':True}
(out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps({k:result[k] for k in ['Passed','ProductCoverageVerified','BatchPersistenceCovered','BatchEngineCovered','ProgressEngineCovered','SourceChanges','ProductCases','N06FullPromotion']},indent=2));raise SystemExit(0 if result['Passed'] else 1)
