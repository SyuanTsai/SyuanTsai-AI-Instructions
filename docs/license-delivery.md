# 授權文件遞送

安裝工具從已驗證的 immutable source 收集授權文件，保留原始 bytes，並將文件與來源收據一起納入既有檔案 inventory。消費端自己的根目錄 `LICENSE`、`NOTICE` 不屬於遞送目標。

| 安裝產物 | 授權文件位置 | Ownership／完整性證據 |
| --- | --- | --- |
| Codex Home runtime | `hooks/ai-instructions-runtime/licenses/` | `runtime-bundle.json` v2 inventory |
| Codex Instructions | `.codex/ai-instructions-licenses/<commit>/` | `.codex/ai-instructions.manifest.json` v2 |
| Copilot Instructions | `.github/ai-instructions-licenses/<commit>/` | 同一份 managed manifest v2 |
| Repository 中選取的外部 Skill | `.agents/skills/<id>/.ai-instructions-licenses/<commit>/` | Repository manifest v2 |
| 使用者層級的外部 Skill | `.agents/skills/<id>/.ai-instructions-licenses/` | User Skills manifest v1 |

每個目錄包含 `source/<原始 Repository-relative path>` 與 `delivery.json`。只選取一個 Skill 時，仍會包含該 Skill 的來源根目錄與祖先目錄授權，以及選取內容之下適用的 local notices，不會安裝其他 Skill。

## 收集與來源證據

`scripts/license-delivery.psm1` 收集每個選取檔案的祖先目錄中的 `LICENSE`、`LICENCE`、`COPYING`、`NOTICE`、`THIRD_PARTY_NOTICES`、`PROVENANCE`、`licensing-scope.json`，以及 `LICENSES/**`。文字檔名可使用 `-`／`_` 後綴與 `.md`、`.txt`、`.rst`、`.html` 副檔名。`LICENSE-SCOPE.md` 亦會保留。符號連結、junction、escaping path 與不支援的根目錄 scope schema 會停止封裝。

收據 schemaVersion 1 包含 `sourceRepository`、完整 `sourceCommit`、`artifactId`、`status`、選取來源 `artifacts`，以及逐份 `documents` 的 `sourcePath`、封裝內 `relativePath`、SHA-256。收據不包含產生時間；相同來源可重複同步而不產生內容變更。

- `documents-present`：已保留來源聲明，不代表工具已判定授權法律效力。沒有逐檔 scope 時，收據不猜測 SPDX 授權，artifact 的 `license` 為 `NOASSERTION`。
- `unconfirmed`：來源根目錄 scope 將選取檔案列為 `NOASSERTION` 或未列入，或只有 attribution／scope 而沒有授權本文。工具保留聲明並輸出警告，不新增授權。
- `missing`：沒有找到來源聲明。工具輸出包含 artifact、來源與 commit 的警告，允許既有舊 pin 繼續安裝，不把中央 Repository 的新授權套用到舊 commit。此情況沒有可遞送的檔案。

User Skills updater 的警告放在結果的 `licenseWarnings` 陣列；文字模式逐項顯示，JSON 模式保留單一可解析的結果，不在 JSON 前混入警告文字。

Git-checkout runtime 安裝先從 `git ls-tree` 找出精確 HEAD 的文件路徑，再從該 commit 建立 snapshot；不採用 dirty worktree 的授權內容。Codeload 與 Skill source 使用已驗證 archive SHA-256 的解壓內容。Skill 原始 content hash 在新增遞送包前完成驗證。

Repository managed manifest 的 Skill `sourcePath` 沿用既有 flat composition 契約；授權文件真正的外部來源路徑記錄在受 hash 保護的收據。User manifest 可直接記錄原始 `sourcePath`。產生的收據使用 `.ai-instructions-generated/delivery.json` 作為 synthetic source path，不冒充來源 Repository 的既有檔案。

## 更新、移除與回復

授權檔案沿用所屬 runtime 或 Skill 的 transaction、backup、rollback 與檔案 ownership。Repository 的授權目錄也納入精確 local ignore、reserved artifact remediation 與 cleanup；不擴大到專案根目錄授權文件。

Repository manifest 會保留 customized／unmanaged 檔案並列出略過路徑；user Skills updater 遇到受管內容修改時沿用既有拒絕更新與明確重裝流程。收據描述封裝時的來源，實際本機內容仍須對照 managed manifest 與檔案 hash；收到 customized 警告時，不應宣稱本機已完整符合新來源收據。

Repository Instructions 與 Skill 的授權副本依完整來源 commit 分目錄保存。若仍有同一 Instructions family 或 Skill 的舊版受管檔案，保留其舊版授權與收據；包括來源已移除、但本機仍保留自訂內容的檔案。最後一個舊版檔案退場後，才依既有 ownership 規則清除未修改的舊授權副本。Runtime 採整包替換；user Skills updater 遇到受管檔案修改會拒絕整次更新，因此這兩種安裝沿用單一授權目錄，授權與所屬內容在同一交易中更新。

不提升既有 runtime bundle v2、Repository manifest v2 或 user manifest v1 的 schema，也不強迫舊 bundle 具有新目錄。新 installer 會把實際遞送檔案加入 inventory；舊來源聲明缺失的問題仍須在對應 source Repository 完成來源審查、授權與 pin 更新。本功能不修改 production Catalog／Lock pins，也不解決既有八個 `NOASSERTION` 歷史檔案的權利確認。
