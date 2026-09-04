# 外部來源與工具邊界

本文件區分「同一維護者拆分的 Skill source」、「執行時下載的第三方工具」及「文件引用」。列出來源不表示把它們重新授權為 Apache-2.0。

## 同源拆分的 Skill source

- [Skill-General](https://github.com/SyuanTsai/Skill-General)
- [Skill-Code-Collaboration](https://github.com/SyuanTsai/Skill-Code-Collaboration)
- [Skill-Knowledge-Content](https://github.com/SyuanTsai/Skill-Knowledge-Content)
- [Skill-Atlassian-Ecosystem](https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem)

精確引用版本見 `catalog/skills-catalog.sources.json` 與 lock。這些是同一維護者的獨立來源，不應因目錄外部化就推定為第三方作者；但各來源仍須記錄自己的授權版本、來源與後續新增內容。本次不更新 pins，也不透過本文件為所有舊 pin 新增授權。

## 驗證與執行工具

| 工具 | 授權查證與限制 |
| --- | --- |
| [NVIDIA/SkillSpector](https://github.com/NVIDIA/SkillSpector/blob/main/LICENSE) | 上游 main 為 Apache-2.0；動態解析的 release 及 Python 依賴須按實際版本另核對 |
| [agent-ecosystem/skill-validator](https://github.com/agent-ecosystem/skill-validator/blob/main/LICENSE) | 上游 main 為 MIT；實際 Go module 及依賴版本另核對 |
| [Pester 3.4.0](https://github.com/pester/Pester/blob/3.4.0/LICENSE)／[4.10.1](https://github.com/pester/Pester/blob/4.10.1/LICENSE) | 這兩個 CI 使用版本明示 Apache-2.0；其他動態解析版本另核對 |
| [actions/checkout](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/LICENSE) | 目前 workflow pin 的 LICENSE 為 MIT |
| [actions/setup-go](https://github.com/actions/setup-go/blob/b7ad1dad31e06c5925ef5d2fc7ad053ef454303e/LICENSE) | 目前 workflow pin 的 LICENSE 為 MIT |
| npm:skill-tools | 本次未完成精確解析版本及依賴的授權確認；不在本 Repository 授權範圍 |
| PowerShell、Python、Git、Node、Go、.NET | 外部執行環境，維持各自授權；本次未建立完整環境 SBOM |

這些依賴的 source／binary 不因被執行或引用而成為本 Repository 原創內容。若未來將其 vendor 或重新封裝，必須補齊實際版本的授權、attribution 及適用 NOTICE；本表不是完整依賴閉包的授權放行證明。

## 文件與資料

產品、API、網站及文件連結維持各自來源權利。連結、整合介面或操作命令不代表整份供應商文件可由本專案重新授權。使用者資料、憑證、下載素材與執行結果亦不自動受本專案 Apache-2.0 授權。

目前 LICENSE／NOTICE 的安裝遞送仍待補齊；不要把本次根目錄文件當成所有安裝產物的聲明已完整保留。
