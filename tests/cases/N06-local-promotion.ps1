#requires -Version 5.1
# Full synthetic current + legacy promotion chains; no real sibling repositories.
param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$CaseId,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
. (Join-Path $RepoRoot 'tests\lib\release-support.ps1')
try {
    # Every child owns a NEW GUID directory underneath this case's evidence.
    # Synthetic commits/fast-forwards are authorized only in those repositories.
    # Runtime bytes/desktop records are deliberately artificial gate fixtures,
    # never evidence of the actual application's release/desktop acceptance.
    # Harness already confines every evidence path to the sibling area of this
    # exact copied RepoRoot. Allocate NEW marked GUID fixtures at that authorized
    # base, not below repeated case/TEMP/GUID layers. No existing path is reused,
    # no path guard is relaxed, and neither source nor target is a real repo.
    $fixtureParent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RepoRoot))
    foreach ($entry in @(
        @('legacy','scripts/test-local-promotion.ps1','l-*'),
        @('component','tests/release/Test-ComponentPromotion.ps1','c-*')
    )) {
        $group=$fixtureParent
        $beforeFixtures=@(Get-ChildItem -LiteralPath $group -Directory -Filter $entry[2] | ForEach-Object FullName)
        $arguments='-FixtureParent "'+$group+'"'
        if ($entry[0] -ceq 'component') { $arguments+=' -Repository "'+$RepoRoot+'"' }
        $timeout=if ($entry[0] -ceq 'legacy') { 300 } else { 600 }
        $run=Invoke-ReleasePowerShellScript -ScriptPath (Join-Path $RepoRoot $entry[1]) -ScriptArguments $arguments -Tag ('promotion-'+$entry[0]) -TimeoutSeconds $timeout
        [void](Save-Evidence ('promotion-'+$entry[0]+'-run') $run)
        Assert-True ($entry[0]+' full synthetic chain does not time out') (-not $run.TimedOut) $run.StderrPath
        Assert-Equal ($entry[0]+' full synthetic chain exits successfully') 0 $run.ExitCode ((Get-ReleaseTextFile $run.StderrPath)+'; '+$run.StdoutPath)
        $owned=@(Get-ChildItem -LiteralPath $group -Directory -Filter $entry[2] | Where-Object FullName -NotIn $beforeFixtures)
        Assert-Equal ($entry[0]+' exactly one new owned GUID fixture') 1 $owned.Count $group
        if ($owned.Count -eq 1 -and [IO.File]::Exists((Join-Path $owned[0].FullName 'result.json'))) {
            $proof=Get-Content -LiteralPath (Join-Path $owned[0].FullName 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-Equal ($entry[0]+' nested assertions all passed') 'Passed' $proof.Status $owned[0].FullName
            Assert-True ($entry[0]+' nested complete gate scenarios executed') ($proof.Assertions -ge 30 -and $proof.SyntheticOnly -and $proof.Retained) ([string]$proof.Assertions)
            [void](Save-Evidence ('promotion-'+$entry[0]+'-binding') $proof)
        } else { Assert-True ($entry[0]+' retained completion proof exists') $false $group }
    }

    # Empty artificial repositories have no inherited .git and require no commit.
    $fixtureRoot=Join-Path $EvidenceDirectory ('sjc-n06-empty-'+[guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $fixtureRoot) { throw 'Fixture root must be new.' }
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.test-fixture-owner'),'N06 empty repositories; '+[datetime]::UtcNow.ToString('o'),$script:Utf8Bom)
    $source=Join-Path $fixtureRoot 'develop'; $target=Join-Path $fixtureRoot 'main'
    foreach ($entry in @(@($source,'develop'),@($target,'main'))) {
        $output=@(& git --no-optional-locks init --quiet --initial-branch=$($entry[1]) $entry[0] 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ('Empty fixture init failed: '+($output -join ';')) }
    }
    [void](Save-Evidence 'promotion-owned-fixtures' @{Owner=$CaseId;Root=$fixtureRoot;Source=$source;Target=$target;CommitCount=0;Retained=$true})
    $wrapper=Join-Path $EvidenceDirectory 'promotion-empty-preflight.ps1'
    $wrapperSource=@'
param([string]$PromoteScript,[string]$Source,[string]$Target)
$ErrorActionPreference='Stop'
try { & $PromoteScript -SourceRepository $Source -TargetRepository $Target; exit 0 }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
    [IO.File]::WriteAllText($wrapper,$wrapperSource,$script:Utf8Bom)
    function Get-EmptyFixtureGitHashes {
        @($source,$target) | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_ '.git') -Recurse -File -Force | Sort-Object FullName | ForEach-Object { $_.FullName+' '+(Get-FileSha256 $_.FullName) }
        }
    }
    $before=@(Get-EmptyFixtureGitHashes) -join "`n"
    $arguments='-PromoteScript "'+(Join-Path $RepoRoot 'scripts\promote-local.ps1')+'" -Source "'+$source+'" -Target "'+$target+'"'
    $preflight=Invoke-ReleasePowerShellScript -ScriptPath $wrapper -ScriptArguments $arguments -Tag 'promotion-empty-preflight' -TimeoutSeconds 60
    $diagnostic=Get-ReleaseTextFile $preflight.StderrPath
    Assert-True 'empty preflight does not time out' (-not $preflight.TimedOut) $diagnostic
    Assert-Equal 'empty uncommitted repository is refused' 1 $preflight.ExitCode $diagnostic
    Assert-True 'refusal identifies missing commit HEAD' ($diagnostic -match 'git failed.*HEAD|unknown revision|ambiguous argument') $diagnostic
    Assert-Equal 'empty preflight changes neither repository git files' $before (@(Get-EmptyFixtureGitHashes) -join "`n") $fixtureRoot
    Assert-True 'all owned fixture directories retained' ([IO.Directory]::Exists($source) -and [IO.Directory]::Exists($target)) $fixtureRoot
    $common=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\local-promotion-common.ps1'))
    Assert-True 'cloud predicate excludes name-surrogate tags' ($common -match '(?i)name.surrogate') ''
    Assert-True 'reparse rejection precedes cloud allowance' ($common -match '(?is)ReparsePoint.*Test-LpCloudPlaceholder') ''
    Add-Limitation '已执行旧版与0.16.1完整安全合成晋级、封装、打包门禁链及无HEAD拒绝路径；所有commit/fast-forward仅在本用例新建GUID人工仓库。合成运行时/桌面材料不证明真实产品验收；未触真实main/库存，无递归清理，夹具和隔离对象库全部保留。'
}
catch { Assert-True ('case completed without unhandled exception: '+$_.Exception.Message) $false $_.ScriptStackTrace }
Complete-TestCase
