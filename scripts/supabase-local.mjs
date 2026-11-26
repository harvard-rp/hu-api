import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { rename, rm, writeFile } from 'node:fs/promises';
import process from 'node:process';
import { fileURLToPath, URL } from 'node:url';

import { format, resolveConfig } from 'prettier';

const root = fileURLToPath(new URL('../', import.meta.url));
const project = 'hu-api';
const network = `supabase_network_${project}`;
const bindingOption = 'com.docker.network.bridge.host_binding_ipv4';
const commands = {
  start: ['start'],
  stop: ['stop', '--project-id', project],
  // CLI v3 targets the local stack when no --remote flag is supplied.
  reset: ['db', 'reset'],
  types: ['gen', 'types', '--lang', 'typescript', '--schema', 'public'],
  test: ['test', 'db'],
};

function docker(args) {
  return spawnSync('docker', args, { cwd: root, encoding: 'utf8' });
}

function ensureLocalNetwork() {
  const inspect = [
    'network',
    'inspect',
    '--format',
    `{{.Driver}}|{{index .Options "${bindingOption}"}}`,
    network,
  ];
  let current = docker(inspect);
  if (current.status !== 0) {
    docker([
      'network',
      'create',
      '--driver',
      'bridge',
      '--opt',
      `${bindingOption}=127.0.0.1`,
      network,
    ]);
    current = docker(inspect);
  }

  if (current.status !== 0 || current.stdout.trim() !== 'bridge|127.0.0.1') {
    throw new Error(
      `Docker network ${network} must be a bridge bound to 127.0.0.1.`,
    );
  }
}

function describeTypesFailure({ stdout, stderr, status, signal, error }) {
  if (error?.code === 'ENOBUFS')
    return 'CLI output exceeded the capture limit.';
  if (error) return 'The CLI process could not be run.';
  if (signal) return `The CLI process was terminated by ${signal}.`;

  // The CLI can write errors to either stream. Match known messages and log
  // only fixed text because the raw output can contain credentials.
  const reasons = [
    [
      /cannot join a Docker network via --network-id/i,
      'The CLI does not support --network-id for type generation.',
    ],
    [
      /supabase start is not running\./i,
      'The local database container is missing. Run pnpm supabase:start.',
    ],
    [
      /failed to inspect service/i,
      'The CLI could not inspect the local database container. Check Docker and pnpm supabase:status.',
    ],
    [
      /failed to connect to postgres|failed to generate typescript types/i,
      'The CLI could not read the local PostgreSQL schema. Check pnpm supabase:status and the local database configuration.',
    ],
  ];
  const reason = reasons.find(
    ([pattern]) => pattern.test(stdout) || pattern.test(stderr),
  )?.[1];
  return `CLI exited with code ${status}. ${reason ?? 'Check pnpm supabase:status and the local database configuration.'}`;
}

async function writeTypes(stdout) {
  const destination = fileURLToPath(
    new URL('../src/lib/supabase/database.types.ts', import.meta.url),
  );
  if (!stdout.includes('export type Database =')) {
    throw new Error('Supabase CLI did not return a TypeScript Database type.');
  }

  let contents;
  try {
    const options = await resolveConfig(destination);
    contents = await format(stdout, { ...options, filepath: destination });
  } catch {
    throw new Error(
      'Unable to format the generated Supabase TypeScript types.',
    );
  }
  const temporary = `${destination}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, contents, { flag: 'wx' });
    await rename(temporary, destination);
  } finally {
    await rm(temporary, { force: true });
  }
}

async function main([action, ...extra]) {
  if (
    (action !== 'status' && !Object.hasOwn(commands, action)) ||
    extra.length > 0
  ) {
    throw new Error(
      'Choose start, stop, status, reset, types, or test with no extra arguments.',
    );
  }

  if (docker(['info', '--format', '{{.ServerVersion}}']).status !== 0) {
    throw new Error(
      'Docker is unavailable. Start a local Docker Engine before running this command.',
    );
  }

  if (action === 'status') {
    const containers = docker([
      'ps',
      '--all',
      '--filter',
      `label=com.supabase.cli.project=${project}`,
      '--format',
      'table {{.Names}}\t{{.Status}}',
    ]);
    if (containers.status !== 0)
      throw new Error('Unable to list the local Supabase containers.');
    const status = containers.stdout.trim();
    process.stdout.write(
      status.includes('\n') ? `${status}\n` : 'Local Supabase is stopped.\n',
    );
    return;
  }

  if (action === 'start' || action === 'reset') ensureLocalNetwork();

  const cli = fileURLToPath(import.meta.resolve('supabase/dist/supabase.js'));
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([name]) => !name.startsWith('SUPABASE_'),
    ),
  );
  const args = [...commands[action], '--workdir', root];
  if (action === 'types') {
    // CLI 3.4 generates types in-process using the local PostgreSQL port.
    // Pin the host even if a project env file specifies a different host.
    env.SUPABASE_SERVICES_HOSTNAME = '127.0.0.1';
  } else {
    args.push('--network-id', network);
  }
  const result = spawnSync(process.execPath, [cli, ...args], {
    cwd: root,
    env,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });

  if (result.status !== 0) {
    if (action === 'types') {
      throw new Error(
        `Local Supabase types failed. ${describeTypesFailure(result)}`,
      );
    }
    throw new Error(
      `Local Supabase ${action} failed. Check Docker and the local stack.`,
    );
  }

  if (action === 'types') {
    await writeTypes(result.stdout);
  }

  // CLI output may include API keys and database URLs.
  process.stdout.write(`Local Supabase ${action} succeeded.\n`);
}

main(process.argv.slice(2)).catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
