# 固定候選的授權後續查證

這份中央查證與 ASTRA 惡意內容結論分開；不修改原始 ASTRA 報告，也不宣稱具備未證實的 rights。原始 `LICENSE`（MIT）與 `THIRD_PARTY_LICENSES.md` 按 exact bytes/hash 保存並交付。完整再散布／第三方 notice 確認尚未完成，descriptor 維持 pending。

## 精確來源的補充證據

固定 commit 的 [scripts/build-icons.py](https://github.com/cathrynlavery/diagram-design/blob/d1376371965f513d99cc9ec388835d255c5c88d5/scripts/build-icons.py#L147) 第 147～149 行補出以下原始 URL。該根目錄 script 僅作文字證據讀取，未執行，也不納入採用 Skill。[實際比對](brand-glyph-provenance.json) 確認三份來源的 ordered path d 與 bundled glyph 一致（只正規化空白）；這不證明變色、其他屬性或再散布權利。

| 圖示 | 固定 builder 記錄的來源 | 2026-10-07 抓取 SHA-256 |
| --- | --- | --- |
| Apache Hop | [hop-logo.svg](https://hop.apache.org/img/hop-logo.svg) | `290b8cca6b42580f7ac04c128ec3e2e700ce4c0da81e3f919b586c93575c80ba` |
| Pentaho | [pentaho-2.svg](https://cdn.worldvectorlogo.com/logos/pentaho-2.svg) | `68f969a00a534867e13e476f68aa7916cdd0d8688603085ef95655e4f5a9e4ae` |
| Dagster | [Dagster Icon.svg](https://cdn.prod.website-files.com/681399f654933b29e12fb8bd/6a04996c4dd28c8ad73bbf3d_Dagster%20Icon.svg) | `96fbbaad6a3da77722aa0d9d27f999c75a83bc5a5eca71f29d4c7e1020a2f87f` |

## 權利與條款

- [Apache 官方商標政策](https://www.apache.org/foundation/marks/) 分開處理圖形 logo 的 Apache copyright license 與 trademark 使用條件。它不能直接證明本套件的特定重色／重繪版本及預定使用已符合全部條件。
- [Dagster 官方 brand kit](https://dagster.io/brand) 有可下載 SVG 與使用條件；需確認本套件所用圖形對應以及所需 notice/使用方式。沒有把 Dagster code 的開源 license 自動套用品牌素材。
- Pentaho 的抓取來源 [Worldvectorlogo Terms](https://worldvectorlogo.com/terms-of-use) 限定個人非商業使用，並限制修改／發布／轉移；其 [About](https://worldvectorlogo.com/about) 同時描述較寬鬆的分享用途，條款間的適用關係仍不明。沒有據此證實再散布權利。[Pentaho Community Logo](https://pentaho-public.atlassian.net/wiki/spaces/COM/pages/190188625) 的允許使用說明禁止修改，且尚未證明是本套件那份 glyph。此為具體證據缺口，不能只靠 root MIT 解除。
- 原始第三方文件引用的 Tabler、Simple Icons、log-z、Devicon、Instrument Serif notices／licenses 已保存查證快照；完整套件內圖示／範例所需 notices、精確來源及相容再散布方式仍須核對。若補中央 notice，必須保存中央來源與引用證據，不能偽裝成上游檔案。

## 下一步與需決策的路徑

優先保持完整原始 Skill：補足確切來源／可用授權與必要 notices，完成實際 license review，通過原路徑門檻。可準備授權釐清文字供使用者審查；本案未授權聯絡上游或品牌 owner，未傳送任何訊息。

如果固定原始候選無法補足權利，完整 raw package 的正式採用保持阻擋。最小替代方案是上游在新 commit 修正 provenance／notice／素材，再重新固定與稽核；需要上游變更。若改採 Fork 去除／替換素材，則將改變 source bytes、ownership、hash 與維護責任，需先由使用者選擇該方案後才建立或修改。沒有自行裁切原始完整 Skill、建立 wrapper 或以禁用 UI 偽裝解決再散布權利。
