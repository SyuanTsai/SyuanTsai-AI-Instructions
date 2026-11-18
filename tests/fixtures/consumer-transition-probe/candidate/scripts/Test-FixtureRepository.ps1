# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
param([string]$RepositoryRoot,[switch]$ReadOnlySnapshot)
if([string]::IsNullOrWhiteSpace($RepositoryRoot)-or-not$ReadOnlySnapshot){throw 'Probe repository binding is incomplete.'}
exit 0
