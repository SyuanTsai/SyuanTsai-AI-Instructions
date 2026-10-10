# SYP-214 USER-only delivery and recovery

共用 Catalog Skills 只安裝／更新 USER。Consumer bootstrap 同步 Instructions，不安裝、更新或重建共用 REPO Skills；USER 不可用也不回退。專案自有 Skills、客製、未受管、tracked/staged、額外資源及來源不明的舊副本保留。此交付承接 SYP-215 的驗收缺口；正式 runtime／真實 USER 整批部署及 Codex/Copilot UI discovery 由 SYP-259 承接，保留 `notify-only`。

## Review and reproducibility

在另一台 Windows 主機以 disposable clone 檢查完整 candidate commit，確認工作樹與 index 乾淨後才執行 fixture lane。先依 `.github/workflows/pr8-powershell-validation.yml` 使用相同的 PowerShell 7.6.6 portable archive SHA-256 pin 驗證套件，並從中性位置（例如 `<portable-pwsh-root>\pwsh.exe`）啟動 PowerShell Core 7.6.6；不要用 Windows 內建 PowerShell 5.1 或本機已安裝的舊 runtime 證明 candidate。fresh clone 不含 ignored `.tools/Pester`，需使用既有 CI 相同的 Pester 4.10.1。以下命令是操作範本，需填入 PR 的完整 commit SHA；不代表本文件已執行測試。記錄 candidate commit、tree、測試檔 blob 及兩種測試輸出的實際數量。

```powershell
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -ne [version]'7.6.6') {
    throw 'Use the SHA-256-verified portable PowerShell Core 7.6.6 runtime.'
}
$expectedCommit = '<full-candidate-commit-sha>'
$repo = (Resolve-Path .).Path
$head = (git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $expectedCommit) { throw 'Not at the requested candidate commit.' }
$dirty = @(git -C $repo status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Candidate checkout is not clean.' }
$tree = (git -C $repo rev-parse 'HEAD^{tree}').Trim()
$testBlob = (git -C $repo rev-parse 'HEAD:tests/syp214-user-only.Tests.ps1').Trim()
Import-Module Pester -RequiredVersion 4.10.1 -Force -ErrorAction Stop
if ((Get-Module Pester).Version -ne [version]'4.10.1') { throw 'Pester 4.10.1 is required.' }

$previousEvidenceRoot = $env:SYP214_FIXTURE_EVIDENCE_ROOT
$privateEvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('syp214-evidence-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $privateEvidenceRoot 'fixtures'
$nunitPath = Join-Path $privateEvidenceRoot 'fixtures.xml'
$transcriptPath = Join-Path $privateEvidenceRoot 'fixture-console.log'
$transcriptStarted = $false
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
try {
    $env:SYP214_FIXTURE_EVIDENCE_ROOT = $fixtureRoot
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $transcriptStarted = $true
    $pester = Invoke-Pester -Script (Join-Path $repo 'tests/syp214-user-only.Tests.ps1') `
        -Tag 'Syp214FixtureEvidence' -PassThru -OutputFile $nunitPath -OutputFormat NUnitXml
    [xml]$nunit = [IO.File]::ReadAllText($nunitPath)
    $nunitSummary = $nunit.'test-results'
    Stop-Transcript | Out-Null
    $transcriptStarted = $false
    $actualFiles = @(Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' |
        ForEach-Object { $_.Name } | Sort-Object)
    $artifactPaths = @($nunitPath, $transcriptPath)
    $artifactPaths += @(Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' | ForEach-Object { $_.FullName })
    $hashes = @($artifactPaths | ForEach-Object {
        [ordered]@{ name = (Split-Path -Leaf $_); sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $runRecord = [ordered]@{
        candidateCommit = $head; tree = $tree; testBlob = $testBlob; pesterVersion = (Get-Module Pester).Version.ToString()
        pesterCounts = [ordered]@{ total = $pester.TotalCount; passed = $pester.PassedCount; failed = $pester.FailedCount; skipped = $pester.SkippedCount; pending = $pester.PendingCount; inconclusive = $pester.InconclusiveCount }
        nunitCounts = [ordered]@{ total = $nunitSummary.total; errors = $nunitSummary.errors; failures = $nunitSummary.failures; inconclusive = $nunitSummary.inconclusive; ignored = $nunitSummary.ignored }
        fixtureFiles = $actualFiles; evidenceSha256 = $hashes
    }
    [IO.File]::WriteAllText((Join-Path $privateEvidenceRoot 'run-metadata.json'),
        ($runRecord | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))

    $problems = @()
    if ($pester.TotalCount -ne 6 -or $pester.PassedCount -ne 6 -or
        $pester.FailedCount -ne 0 -or $pester.SkippedCount -ne 0 -or
        $pester.PendingCount -ne 0 -or $pester.InconclusiveCount -ne 0) {
        $problems += 'Pester must report exactly six passed cases and no failures, skips, pending, or inconclusive cases.'
    }
    if ([int]$nunitSummary.total -ne 6 -or [int]$nunitSummary.errors -ne 0 -or
        [int]$nunitSummary.failures -ne 0 -or [int]$nunitSummary.inconclusive -ne 0 -or
        [int]$nunitSummary.ignored -ne 0) {
        $problems += 'NUnit XML must report six cases and no errors, failures, inconclusive, or ignored cases.'
    }
    $expectedFiles = @('migration.json','failure-rollback.json','recovery-exact.json',
        'recovery-later-edit.json','recovery-corrupt-backup.json','recovery-pending-intent.json')
    if (Compare-Object ($expectedFiles | Sort-Object) $actualFiles) { $problems += 'Fixture evidence file set is not the expected six cases.' }
    foreach ($name in $actualFiles) {
        try {
            $item = Get-Content -LiteralPath (Join-Path $fixtureRoot $name) -Raw | ConvertFrom-Json
            if ($item.schemaVersion -ne 2 -or $item.scope -ne 'disposable integration fixture') {
                $problems += "Invalid fixture evidence metadata: $name"
            }
        }
        catch { $problems += "Fixture evidence is missing or invalid JSON: $name" }
    }
    $afterHead = (git -C $repo rev-parse HEAD).Trim()
    $afterTree = (git -C $repo rev-parse 'HEAD^{tree}').Trim()
    $afterTestBlob = (git -C $repo rev-parse 'HEAD:tests/syp214-user-only.Tests.ps1').Trim()
    $afterDirty = @(git -C $repo status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $afterHead -ne $head -or $afterTree -ne $tree -or
        $afterTestBlob -ne $testBlob -or $afterDirty.Count -ne 0) { $problems += 'Candidate changed during fixture run.' }
    if ($problems.Count -ne 0) { throw ($problems -join ' ') }
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    if ($null -eq $previousEvidenceRoot) { Remove-Item Env:SYP214_FIXTURE_EVIDENCE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SYP214_FIXTURE_EVIDENCE_ROOT = $previousEvidenceRoot }
}
```

Fixture lane 只由外層 `Describe` 的 `Syp214FixtureEvidence` tag 選出，預期展開為六個實際案例；零案例、只匹配 tag 的空跑或任何 skipped/pending/inconclusive 都是失敗。六份 schema-v2 JSON 依情境記錄 point inventory 與 missing-file witness、disposable consumer／USER 全檔案樹的 relative path/type/length/raw SHA-256；inventory 以明確 `relativePath` key 排序，再以完整 records 精確比較；全樹盤點排除 `.git` 內部控制檔，並另以 regular-file/type/length/SHA-256 記錄 `.git/info/exclude`，同時保留 Git HEAD/index/status/stash。Migration report 保存實際 `-WhatIf` 輸出與 migration eligibility 行，並以包含 stash 的完整 Git state 對 dry-run 前後作零變更比較；套用後則比較 HEAD/index/status，記錄實際 PersonalAgent stash evidence，並確認它在後續 no-op／branch runs 中保留。套用階段另記錄 exclude 前後狀態，因 managed block 的預期更新不作為失敗。`failure-rollback.json` 由實際 child failure output 的 retained-workspace 路徑找出交易所保留的 journal，再讀取真實 rolled-back journal 與 backup objects，驗證 regular-file/type/length/raw SHA-256 與 journal hash；不合成 journal、backup 或成功旗標，也不輸出原始檔案 bytes／完整 journal。Recovery reports 依結果語意比較：exact/pending-intent 成功復原對照 apply 前 snapshot；later-edit 以 apply 前 snapshot 為基礎，overlay recovery 前已捕獲的 full-tree／point-inventory drift record，並逐欄核對 recovery 後 raw type／length／SHA-256 未變、其他原始檔案及 manifest 已復原；corrupt-backup 拒絕復原對照 recovery 前 snapshot。Recovery 的 HEAD/index/status 通常以 recovery 前狀態為基準；pending-intent 在 exclude 更新前中斷，成功 recovery 會復原原始 Git status，因此此情境以 apply-before snapshot 為基準，並保存 pre-recovery 差異與完整 before/after records；stash history 不會由 recovery 復原，報告記錄並核對 recovery 前後保留的 stash evidence。Recovery 的 `.git/info/exclude` 依實際階段選擇預期 inventory：exact/pending-intent 比對 apply-before 原始 inventory；later-edit 因 target drift 使 recovery 在 exclude restore 前停止，保留 pre-recovery inventory；corrupt-backup 因 preflight 拒絕復原，也比對 pre-recovery inventory。報告保存 basis 及 recovery 前後完整 type/regular-file/length/SHA-256 records。損壞 backup 的 witness 逐欄對照實際 journal inventory 並保留量測到的不匹配值。手動 fixture lane 的 `run-metadata.json`、NUnit XML、transcript 與六份實際 JSON reports 一起綁定 candidate commit/tree/test blob、Pester/NUnit counts 和輸出 artifact hashes。CI 另以 `pester-summary.json` 與 `process-result.json` 記錄觀察到的案例名稱/counts、source 與 checkout identity、runtime/script hashes、child exit status 及 stdout/stderr hashes。跨主機 Review 必須檢查同一 run/attempt 的實際 reports、sidecars 與 logs、核對 hash/identity/count/exit，並確認完整正常 gate run；預期檔名或單一 JSON 不足以驗收。Disposable CI fixture/smoke JSON 與 logs 可用其精確 artifact path 提供 portable review，例如 Windows Core artifact 中的 `syp214-fixture-evidence/reports/*.json`、`pester-summary.json`、`process-result.json` 和 `child.stdout.log`／`child.stderr.log`。真實 USER／consumer 的私人 bytes、真實路徑及 raw reports 必須私有保存；對外只提供去識別化摘要與 digest，不分享私人路徑或原始內容。

完成 targeted lane 並恢復原本的 `SYP214_FIXTURE_EVIDENCE_ROOT` 後，在獨立正常 gate run 中另行執行完整 suite 與既有驗證命令，分開記錄結果；fixture lane 不替代 full suite 或 gate。

```powershell
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -ne [version]'7.6.6') {
    throw 'Use the SHA-256-verified portable PowerShell Core 7.6.6 runtime.'
}
Import-Module Pester -RequiredVersion 4.10.1 -Force -ErrorAction Stop
if ((Get-Module Pester).Version -ne [version]'4.10.1') { throw 'Pester 4.10.1 is required.' }
Invoke-Pester -Script ./tests -PassThru
./scripts/update-skills-catalog-lock.ps1 -Check
git diff --check
$smokeEvidencePath = Join-Path ([IO.Path]::GetTempPath()) ('syp214-smoke-' + [guid]::NewGuid().ToString('N') + '.json')
./scripts/test-syp101-production-smoke.ps1 -EvidencePath $smokeEvidencePath
```

CI 的 bounded Windows Core Pester 與既有 authority gate 仍使用中央入口；不要改數量或略過失敗讓 gate 通過。Smoke 在系統 temp 建立 Codex Home、disposable USER 與 consumer，先經 verified installed USER updater 套用真實 immutable archives，再執行兩次 installed bootstrap；schema-v2 smoke JSON 記錄量測到的 managed consumer、USER/manifest 與 project Skill inventories、Git state、candidate/source identity、runtime/catalog/script hashes，以及 bytes、manifest、HEAD/index/status/recovery evidence 的實際比較。`syp101-production-smoke-evidence-<run_id>-<attempt>` artifact 同時保存 `smoke-evidence.json`、`process-result.json` 與 stdout/stderr logs；以同一 run/attempt 的 evidence hash、sidecar exit/identity/log hashes 交叉核對，再連同 Windows Core 的六份 fixture reports、Pester summary、shard sidecars 與完整正常 gates Review。這些都是 disposable smoke/fixture 的 portable evidence，不等於真實 client UI 或正式 USER 部署驗收。六個 tagged fixture cases 與 smoke 均不執行 process kill；bounded full regression 另包含受控的 disposable child process-death recovery cases，不會終止 live process，也不代表真實斷電或 SYP-259 部署驗收。正式 runtime／真實 USER 部署與 UI discovery 由 SYP-259 承接；候選通知維持 `notify-only`。`realUserDeployment` 與 `codexCopilotUiDiscovery` 未有實際結果前維持 `not-run-SYP-259`。真實 USER／consumer 的私人 bytes、路徑與 raw reports 只在私有位置保存，對外僅分享去識別化 digest。此目錄的驗證紀錄依實際結果填寫 Red/Green、回歸、exit/skip 與 installed smoke；未執行項目明列 `not-run`，不得只依 evidence JSON 宣稱 Green。

## Operator sequence for SYP-259

1. 核對 PR／candidate 的 review、正常 CI 與精確 commit；依既有部署分工選定 runtime。保存原 runtime commit/config、USER manifest 及完整 raw-byte inventory。保持 `notify-only`；candidate notification 不代表已安裝。
2. 依既有 installer/updater 的獨立核准部署步驟安裝 verified runtime；先執行 USER updater `-Apply -WhatIf`／`-VerifyOnly`，再依 SYP-259 明確授權執行 `-Apply`。若 USER 有 recovery journal，先 `-Recover`；客製檔案不可直接 force，須依原 USER 流程確認備份與 ownership。
3. 只對明確指定 consumer 執行盤點及 bootstrap。以下 `$deploymentCodexHome`、`$consumerRoot`、`$userRoot` 必須由該主機真實路徑提供，不使用此開發主機的絕對路徑。

```powershell
$consumerHook = Join-Path $deploymentCodexHome 'hooks/bootstrap-ai-instructions.ps1'
& $consumerHook -TargetRoot $consumerRoot -UserHome $userRoot -WhatIf
# After reviewing the inventory and USER verification:
& $consumerHook -TargetRoot $consumerRoot -UserHome $userRoot -SkipUpdateCheck
& $consumerHook -TargetRoot $consumerRoot -UserHome $userRoot -SkipUpdateCheck
```

4. 保存 migration dry-run 原因、舊／新 consumer manifest、REPO/USER 全部檔案 inventory、journal/backup、兩次 bootstrap 及 branch 切換後的 bytes、HEAD/index/status。只允許預期 Instructions 更新與已證明可退休的舊副本變更。
5. 在真實 Codex 與 Copilot client 驗證共用 Skill 的 USER discovery、無 REPO 重複項、專案自有 Skill 仍可發現，以及 Instructions 仍生效。記錄 client/version、所用 commit 與具體觀察；無法操作 client 就維持未驗收。殘留 UI cache 推測不得寫成根因已證實或通過。

## Whole-Skill migration rules

刪除資格以整個 stable ID 為單位，從 supported 舊 REPO manifest 取得來源與逐檔 raw SHA-256，並核對全部實體檔案、ignored/untracked/HEAD/index 狀態。USER manifest 的 Catalog identity、來源 identity/version/immutable pin、完整選定來源 inventory、payload 和 license delivery bytes 必須各自可信；較新 USER bytes 不拿來當舊 REPO hash。任一必要證據缺失就保留整個 Skill 及原 entries，回報 USER 修復或人工處理。沒有 manifest，即使同名或同 hash 也不接管。

新 consumer desired set 永遠不含共用 Skills；direct/legacy archive 亦受最終寫入邊界限制。既有 schema v1 未具來源 ownership 的 Skills 保留；v2/v3 可只移除已驗證副本 entries。原 Instructions remediation 保留，Skills 明確排除於 reserved remediation 與舊 pollution cleanup；retired 名稱本身不是刪除證據。

`-WhatIf` 不建立 operation/index lock，不做 remediation，也不改 payload、manifest、Git exclude、index 或 USER；來源 acquisition 的暫存目錄會清除。Apply 在每個精確刪除前重驗完整 inventory、USER bytes、Git state 與 ignore state；mutation handle 再核對實際 bytes 及 root confinement。

## Recovery

成功遷移及故障均保留 Repository 外的 `target-backup/skill-migration.json` 與 raw-byte backups；輸出會提供實際位置。將這些證據安全保存，不把 consumer 的私人 bytes 提交到公共來源 PR。一般例外自動 rollback；需要人工恢復时使用同一 verified candidate 的 runtime script：

```powershell
$runtimeBootstrap = Join-Path $deploymentCodexHome 'hooks/ai-instructions-runtime/bootstrap-ai-instructions.ps1'
& $runtimeBootstrap -TargetRoot $consumerRoot -RecoverSkillMigration $retainedJournalPath
```

Recovery 核對 journal root/schema、backup hashes、HEAD/index、安全路徑及當前 applied/original bytes。Schema v2 記錄原始 DACL、read-only flag、檔案 identity，以及 same-parent staged publication 的 identity/hash；schema v1 保留原 whole-file byte-CAS 相容性，但也使用 staged publisher。V1 未記錄的歷史 DACL、read-only flag 與 file identity 保持未知：若 applied file 仍存在，只在完整 bytes 比對成功後量測當下 handle 的 metadata 並保留於這次 staged restore；若 journal 明確記錄 `appliedType=missing`，則須先驗證 backup/hash、root 與 Git state，透過 absent-old CAS、parent guard 和 no-replace stage 還原 original bytes，不宣稱知道原 ACL。缺少必要 backup/hash 或 missing-state 證據時 fail closed；不轉換成虛構 v2 歷史。合法的 missing state 也適用於 schema-v2 restore intent，其 old-file identity/hash 必須為 null 且 length 為零，new stage 仍綁定已驗證 backup。

新檔先寫入唯一的 same-parent stage，在寫入任何 payload 前套用並讀回可證明的 DACL，完成 bytes 驗證後才套用相應 read-only flag。Durable publication intent 寫入 journal 後，以兩次 no-replace rename 將舊檔移至 tombstone，再把完整 stage 移到 final。若中止於兩次 rename 之間，恢復會核對 journaled stage/tombstone，先還原舊 final 再重試；若恢復又在 first rename 或 verified stage cleanup 後中止，下一次 recovery 只會在舊 final identity/hash/DACL/read-only 完整吻合且 stage、tombstone 都不存在時 reconciliation stale intent。Final 缺失、stage 已消耗而 final 後來又消失，或 final 被無關檔案占用時，會拒絕猜測並保留現場供人工處理。早期 writer fault 若尚未記錄 stage identity，partial stage 不會被當成可刪除的交易內容。它只恢復本交易列出的路徑，後續編輯原樣保留並回報失敗；其他未 drift 路徑仍可各自恢復。 對原本缺席、已完成 apply 的本交易新建 target，若 stage／tombstone 均缺席，且 final 的 native identity、完整 hash／length 與已記錄 DACL 精確吻合，僅外部將 ReadOnly 從 false 設為 true 不阻止 rollback 恢復缺席；刪除前重核 publication parent identity，並持有 root／parent guard 至完成，再以同一 guarded held handle 重驗 bytes／identity／DACL。此例外不適用於既有檔案、exclude、未知 ownership 或其他內容／identity／DACL drift。不要以 `reset --hard`、整目錄刪除或 journal 刪除代替恢復。若 process 強制中止留下 Git `index.lock`，先由 operator 確認沒有持有該 lock 的 Git/bootstrap 程序，再依 Git lock recovery 處理；本入口不推定 stale lock 可刪。

日誌在刪除、Instructions/manifest 寫入及 exclude 寫入前保存 intent。回歸涵蓋 target/exclude staged writer prefix fault、writer process death、old-to-tombstone gap recovery retry、recovery first-rename death 與 re-interruption、verified cleanup 後 stale-journal re-entry、manifest durable publication intent 後於 first rename 前受控退出，以及 schema-v2 missing-to-original intent、schema-v1 file/missing state 的 full-file recovery retry 和 unknown-metadata boundary、DACL protected/unprotected 與 read-only preservation，以及 stage 消耗後 final 遺失或被無關 final 占用時 fail-closed。這些是可重現程序中斷案例，不代表真實斷電或儲存裝置故障注入；本次候選的 runtime/Pester 結果應在實際執行後記錄，不可依靜態檢查宣稱通過。Recovery 不修改 USER 安裝，也不復原 Git stash history；保留的 Instructions recovery stash 仍可作為歷史證據。

如需 runtime rollback，依既有 transactional updater/installer 恢復已驗證舊 pin。舊 runtime 可能再次 fan out REPO Skills，必須記錄這個限制並停止宣稱 USER-only 已生效；consumer 檔案恢復只限本交易清單。

## English scope

Shared Catalog Skills are installed and updated only by the USER reconciler. Consumer bootstrap synchronizes Instructions and never falls back to REPO installation. Complete historical ownership, unchanged raw bytes, ignored/untracked Git state and an independently verified full USER installation are required before retiring an entire old shared Skill. Project-owned, customized, unmanaged, tracked/staged, extra-file and ambiguous copies are preserved. Dry-run is read-only; apply revalidates before precise deletion and retains a durable backup/journal outside the consumer. Schema-v2 recovery records file identity, DACL/read-only metadata and staged publication evidence; schema-v1 recovery preserves whole-file byte-CAS compatibility while using the staged publisher and leaving unrecorded historical metadata unknown. Both versions preserve durable restore intent across rename gaps and re-entry; missing-final ambiguity and competing finals fail closed. Recovery preserves later edits. Setting readonly from false to true does not prevent rollback deletion of an originally absent, fully published transaction-created target when stage and tombstone are absent and final native identity, complete hash/length and recorded DACL match exactly; deletion rechecks the publication parent identity, retains the root/parent guard until completion and rechecks bytes, identity and DACL through the same held file handle. This exception excludes existing files, exclude, unknown ownership and other content/identity/DACL drift. Regression cases cover staged-writer faults and process death but do not simulate power loss. SYP-259 owns real runtime/USER deployment and client discovery; source tests and isolated smoke do not pass those acceptance items.
