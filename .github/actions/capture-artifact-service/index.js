// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0
'use strict'

const {execFileSync, spawnSync} = require('node:child_process')

const runId = process.env.GITHUB_RUN_ID || ''
const runAttempt = process.env.GITHUB_RUN_ATTEMPT || ''
if (!/^[0-9]+$/.test(runId) || !/^[0-9]+$/.test(runAttempt)) {
  throw new Error('The GitHub run identity is missing or invalid.')
}

const supervisorRoot = `/var/lib/syp154-evidence-${runId}-${runAttempt}`
const authorityPath = `${supervisorRoot}/artifact-service.env`
const nodeRuntimePath = `${supervisorRoot}/node24`
const rootStat = execFileSync(
  '/usr/bin/sudo',
  ['-n', '/usr/bin/stat', '-c', '%u:%g:%a', '--', supervisorRoot],
  {encoding: 'utf8'}
).trim()
if (rootStat !== '0:0:755') {
  throw new Error('The artifact-service authority root is not root-owned and immutable.')
}

execFileSync('/usr/bin/sudo', ['-n', '/usr/bin/test', '!', '-e', nodeRuntimePath])
execFileSync(
  '/usr/bin/sudo',
  ['-n', '/usr/bin/install', '-m', '0555', '-o', 'root', '-g', 'root', '--', process.execPath, nodeRuntimePath]
)
const nodeRuntimeStat = execFileSync(
  '/usr/bin/sudo',
  ['-n', '/usr/bin/stat', '-c', '%u:%g:%a', '--', nodeRuntimePath],
  {encoding: 'utf8'}
).trim()
if (nodeRuntimeStat !== '0:0:555') {
  throw new Error('The captured Node runtime is not root-owned and immutable.')
}

execFileSync('/usr/bin/sudo', ['-n', '/usr/bin/test', '!', '-e', authorityPath])
const authorityNames = [
  'ACTIONS_RESULTS_URL',
  'ACTIONS_RUNTIME_URL',
  'ACTIONS_RUNTIME_TOKEN'
]
const authorityLines = authorityNames.map(name => {
  const value = process.env[name] || ''
  if (value.length === 0 || value.includes('\r') || value.includes('\n')) {
    throw new Error(`Runner-injected artifact service value ${name} is missing or invalid.`)
  }
  return `${name}=${value}`
})

const writeResult = spawnSync(
  '/usr/bin/sudo',
  ['-n', '/usr/bin/tee', '--', authorityPath],
  {
    input: `${authorityLines.join('\n')}\n`,
    encoding: 'utf8',
    stdio: ['pipe', 'ignore', 'pipe']
  }
)
if (writeResult.status !== 0) {
  throw new Error('Could not preserve runner-injected artifact service authority.')
}
execFileSync('/usr/bin/sudo', ['-n', '/usr/bin/chmod', '0400', '--', authorityPath])
const authorityStat = execFileSync(
  '/usr/bin/sudo',
  ['-n', '/usr/bin/stat', '-c', '%u:%g:%a', '--', authorityPath],
  {encoding: 'utf8'}
).trim()
if (authorityStat !== '0:0:400') {
  throw new Error('The artifact-service authority snapshot is not root-only.')
}
